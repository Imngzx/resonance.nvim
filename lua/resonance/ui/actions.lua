local M = {}
local st = require('resonance.ui.state')
local render_mod = require('resonance.ui.render')
local utils = require('resonance.utils')

local schedule = vim.schedule
local system = vim.system
local pcall = pcall
local type = type
local tostring = tostring
local table_concat = table.concat
local uv_fs_stat = vim.uv.fs_stat
local vim_trim = vim.trim
local fn_confirm = vim.fn.confirm
local ui_input = vim.ui.input
local vim_log_levels = vim.log.levels
local string_format = string.format

local spinner_timer = nil
local function stop_spinner()
  if spinner_timer and not spinner_timer:is_closing() then
    spinner_timer:close()
  end
  spinner_timer = nil
end

local function finish_check()
  st.state.checking = false
  stop_spinner()
  render_mod.schedule_render()
end

local function start_spinner()
  stop_spinner()
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(0, 100, function()
    schedule(function()
      st.state.spinner_frame = (st.state.spinner_frame % 8) + 1
      render_mod.schedule_render()
    end)
  end)
end

function M.check_updates_network()
  if st.state.checking then return end
  st.state.checking = true
  start_spinner()
  render_mod.render()

  vim.defer_fn(function()
    if not (vim.pack and vim.pack.get) then
      finish_check()
      return
    end

    local ok, packs = pcall(vim.pack.get, nil, { info = true, offline = false })
    if not ok or type(packs) ~= 'table' then
      finish_check()
      return
    end

    local pending_count = 0
    local log_completed = 0
    for p = 1, #packs do
      local pk = packs[p]
      if pk.rev and pk.rev_to and pk.rev ~= pk.rev_to then
        pending_count = pending_count + 1
        local name = pk.spec.name
        system({ 'git', 'log', '--oneline', pk.rev .. '..' .. pk.rev_to },
          { cwd = pk.path, text = true },
          function(out)
            if out.code == 0 and out.stdout and vim_trim(out.stdout) ~= '' then
              local lines = {}
              for line in out.stdout:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
              st.state.updates[name] = lines
            end
            log_completed = log_completed + 1
            if log_completed >= pending_count then
              finish_check()
            end
          end)
      end
    end

    if pending_count == 0 then
      -- Allow spinner to animate for a bit even when no updates
      vim.defer_fn(finish_check, 200)
    end
  end, 1)
end

function M.toggle_details()
  local name = st.plugin_at_cursor()
  if not name then return end
  st.state.expanded[name] = not st.state.expanded[name]
  render_mod.render()
end

function M.update_plugins(names)
  if #names == 0 or st.state.updating then return end

  if vim.pack and vim.pack.update then
    st.state.updating = true
    utils.notify('Updating ' .. table_concat(names, ', ') .. '...', vim_log_levels.INFO)

    schedule(function()
      local ok, err = pcall(vim.pack.update, names, { force = true, offline = false })
      st.state.updating = false

      if not ok then
        utils.notify('Pack update failed: ' .. tostring(err), vim_log_levels.ERROR)
      else
        for i = 1, #names do
          local n = names[i]
          st.state.updates[n] = nil
          for j = 1, st.state.info.total do
            if st.state.info.plugins.name[j] == n then
              st.state.commits[n] = st.get_local_hash(st.state.info.plugins.path[j])
              break
            end
          end
        end
        render_mod.schedule_render()
        utils.notify('Update complete. Please restart Nvim to apply changes.', vim_log_levels.INFO)
      end
    end)
  else
    utils.notify('Triggering plugin update for ' .. names[1], vim_log_levels.INFO)
  end
end

function M.uninstall_plugin(name)
  if not name then return end
  local choice = fn_confirm('Uninstall ' .. name .. ' from disk?', '&Yes\n&No', 2)
  if choice ~= 1 then return end

  if vim.pack and vim.pack.del then
    utils.notify('Uninstalling ' .. name .. '...', vim_log_levels.INFO)
    local ok, err = pcall(vim.pack.del, { name }, { force = true })
    if ok then
      utils.notify('Uninstalled ' .. name, vim_log_levels.INFO)
    else
      utils.notify('Uninstall failed: ' .. tostring(err), vim_log_levels.ERROR)
    end
    render_mod.schedule_render()
  end
end

function M.checkout_plugin(name)
  if type(name) ~= 'string' then return end

  local state = st.state
  local info = state.info
  if not info or not info.plugins then return end

  local names = info.plugins.name
  local paths = info.plugins.path
  local total = info.total
  local path = nil

  for i = 1, total do
    if names[i] == name then
      path = paths[i]
      break
    end
  end

  if not path then
    utils.notify('Cannot find path for ' .. name, 3)
    return
  end

  if not uv_fs_stat(path .. '/.git') then
    utils.notify("Plugin '" .. name .. "' is not a Git repository!", 3)
    return
  end

  ui_input({ prompt = 'Checkout (Branch/Tag/Commit) for ' .. name .. ': ' }, function(input)
    if not input then return end
    local target = input:match('^%s*(.-)%s*$')
    if target == '' then return end

    utils.notify('Checking out ' .. name .. ' -> ' .. target, 2)

    system({ 'git', 'checkout', target }, { cwd = path, text = true }, function(out)
      schedule(function()
        if out.code == 0 then
          state.commits[name] = st.get_local_hash(path)
          state.updates[name] = nil
          render_mod.schedule_render()
          utils.notify(
            string_format("Checked out '%s' to '%s'.\nUpdate 'version' in config to persist.", name,
              target), 2)
        else
          local err_msg = out.stderr and out.stderr ~= '' and out.stderr or
            (out.stdout or 'Unknown Git Error')
          utils.notify('Checkout failed for ' .. name .. ':\n' .. err_msg, 3)
        end
      end)
    end)
  end)
end

return M