local M = {}
local st = require('resonance.ui.state')
local render_mod = require('resonance.ui.render')
local utils = require('resonance.utils')

local last_toggle_time = 0
local schedule = vim.schedule
local system = vim.system

function M.check_updates_network()
  if st.state.checking then return end
  st.state.checking = true
  render_mod.schedule_render()

  local completed = 0
  local total = st.state.info.total
  local MAX_CONCURRENT = 8
  local running = 0
  local queue = {}

  local function on_all_completed()
    schedule(function()
      if vim.pack and vim.pack.get then
        local ok, packs = pcall(vim.pack.get, nil, { offline = true })
        if ok and type(packs) == 'table' then
          local pending_count = 0
          local log_completed = 0
          for _, pk in ipairs(packs) do
            if pk.rev and pk.rev_to and pk.rev ~= pk.rev_to then
              pending_count = pending_count + 1
              local name = pk.spec.name
              system({ 'git', 'log', '--oneline', pk.rev .. '..' .. pk.rev_to },
                { cwd = pk.path, text = true },
                function(out)
                  if out.code == 0 and out.stdout and vim.trim(out.stdout) ~= '' then
                    local lines = {}
                    for line in out.stdout:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
                    st.state.updates[name] = lines
                  end
                  log_completed = log_completed + 1
                  if log_completed >= pending_count then
                    st.state.checking = false
                    render_mod.schedule_render()
                  end
                end)
            end
          end
          if pending_count == 0 then
            st.state.checking = false; render_mod.schedule_render()
          end
        else
          st.state.checking = false; render_mod.schedule_render()
        end
      end
    end)
  end

  local queue_idx = 1
  local function process_queue()
    while running < MAX_CONCURRENT and queue_idx <= #queue do
      local p_path = queue[queue_idx]
      queue_idx = queue_idx + 1
      running = running + 1
      system({ 'git', 'fetch', '--quiet' }, { cwd = p_path }, function(_)
        running = running - 1
        completed = completed + 1
        if completed >= total then
          on_all_completed()
        else
          process_queue()
        end
      end)
    end
  end

  for i = 1, total do
    local p_path = st.state.info.plugins.path[i]
    if vim.uv.fs_stat(p_path .. '/.git') then
      queue[#queue + 1] = p_path
    else
      completed = completed + 1
    end
  end

  if #queue > 0 then
    process_queue()
  else
    on_all_completed()
  end
end

function M.toggle_details()
  local now = vim.uv.hrtime() / 1e6
  if now - last_toggle_time < 200 then return end
  last_toggle_time = now

  local name = st.plugin_at_cursor()
  if not name then return end
  st.state.expanded[name] = not st.state.expanded[name]
  st.state.restore_cursor_name = name

  if st.state.expanded[name] and not st.state.pack_details[name] and vim.pack and vim.pack.get then
    local ok, packs = pcall(vim.pack.get, { name }, { info = true, offline = true })
    if ok and type(packs) == 'table' and packs[1] then
      st.state.pack_details[name] = packs[1]
    end
  end

  render_mod.schedule_render()
end

function M.update_plugins(names)
  if #names == 0 or st.state.updating then return end

  if vim.pack and vim.pack.update then
    st.state.updating = true
    utils.notify('Updating ' .. table.concat(names, ', ') .. '...', vim.log.levels.INFO)

    schedule(function()
      local ok, err = pcall(vim.pack.update, names, { force = true, offline = true })
      st.state.updating = false

      if not ok then
        utils.notify('Pack update failed: ' .. tostring(err), vim.log.levels.ERROR)
      else
        for _, n in ipairs(names) do
          st.state.updates[n] = nil
          for i = 1, st.state.info.total do
            if st.state.info.plugins.name[i] == n then
              st.state.commits[n] = st.get_local_hash(st.state.info.plugins.path[i])
              break
            end
          end
        end
        render_mod.schedule_render()
        utils.notify('Update complete. Please restart Nvim to apply changes.', vim.log.levels.INFO)
      end
    end)
  else
    utils.notify('Triggering plugin update for ' .. names[1], vim.log.levels.INFO)
  end
end

function M.uninstall_plugin(name)
  if not name then return end
  local choice = vim.fn.confirm('Uninstall ' .. name .. ' from disk?', '&Yes\n&No', 2)
  if choice ~= 1 then return end

  if vim.pack and vim.pack.del then
    utils.notify('Uninstalling ' .. name .. '...', vim.log.levels.INFO)
    schedule(function()
      local ok, err = pcall(vim.pack.del, { name }, { force = true })
      if not ok then
        utils.notify('Uninstall failed: ' .. tostring(err), vim.log.levels.ERROR)
      else
        st.state.updates[name] = nil
        st.state.commits[name] = nil
        st.state.expanded[name] = nil
        st.state.urls[name] = nil
        st.state.info = require('resonance.scanner').get_info()
        render_mod.schedule_render()
        utils.notify('Uninstalled ' .. name .. '. Please restart Nvim to apply changes.',
          vim.log.levels.WARN)
      end
    end)
  else
    utils.notify('Triggering plugin uninstall for ' .. name, vim.log.levels.INFO)
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

  if not vim.uv.fs_stat(path .. '/.git') then
    utils.notify("Plugin '" .. name .. "' is not a Git repository!", 3)
    return
  end

  vim.ui.input({ prompt = 'Checkout (Branch/Tag/Commit) for ' .. name .. ': ' }, function(input)
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
            string.format("Checked out '%s' to '%s'.\nUpdate 'version' in config to persist.", name,
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
