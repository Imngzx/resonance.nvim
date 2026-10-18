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
  if not spinner_timer then return end
  spinner_timer:start(0, 100, function()
    schedule(function()
      st.state.spinner_frame = (st.state.spinner_frame % 8) + 1
      render_mod.update_spinner() -- Use targeted redraw
    end)
  end)
end

function M.check_updates_network()
  if st.state.checking then return end
  st.state.checking = true
  st.state.updates = {} -- Clear stale state
  start_spinner()
  render_mod.render()

  -- Use offline info (which comes from vim.pack cache) for paths
  local info = st.state.info
  if not info or not info.plugins then
    finish_check()
    return
  end

  local total = info.total
  local names = info.plugins.name
  local paths = info.plugins.path
  local completed = 0

  if total == 0 then
    vim.defer_fn(finish_check, 200)
    return
  end

  -- Background async git queue to prevent UI blocking
  local max_concurrent = 5
  local idx = 1

  local function next_task()
    if idx > total then return end
    local i = idx
    idx = idx + 1

    local name = names[i]
    local path = paths[i]

    system({ 'git', 'ls-remote', 'origin', 'HEAD' }, { cwd = path, text = true }, function(out1)
      if out1.code == 0 and out1.stdout then
        local remote_hash = out1.stdout:match('^(%x+)')
        if remote_hash then
          local local_hash = st.state.commits[name]
          if local_hash and not vim.startswith(remote_hash, local_hash) then
            system({ 'git', 'fetch', 'origin' }, { cwd = path, text = true }, function(out2)
              if out2.code == 0 then
                system({ 'git', 'log', '--oneline', 'HEAD..FETCH_HEAD' }, { cwd = path, text = true },
                  function(out3)
                    if out3.code == 0 and out3.stdout and vim_trim(out3.stdout) ~= '' then
                      local lines = {}
                      for line in out3.stdout:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
                      st.state.updates[name] = lines
                      render_mod.schedule_render()
                    end
                    completed = completed + 1
                    if completed >= total then finish_check() else next_task() end
                  end)
              else
                completed = completed + 1
                if completed >= total then finish_check() else next_task() end
              end
            end)
            return
          end
        end
      end

      completed = completed + 1
      if completed >= total then finish_check() else next_task() end
    end)
  end

  for _ = 1, max_concurrent do
    next_task()
  end
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
        st.state.info = require('resonance.scanner').get_info()
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
      st.state.info = require('resonance.scanner').get_info()
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
