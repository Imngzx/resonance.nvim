local M = {}
local st = require('resonance.ui.state')
local render_mod = require('resonance.ui.render')
local utils = require('resonance.utils')
local scanner = require('resonance.scanner')

function M.check_updates_network()
  if st.state.checking then return end
  st.state.checking = true
  render_mod.schedule_render()

  local completed = 0
  local total = st.state.info.total

  for i = 1, total do
    local p_path = st.state.info.plugins.path[i]
    vim.system({ 'git', 'fetch', '--quiet' }, { cwd = p_path }, function(_)
      completed = completed + 1
      if completed >= total then
        vim.schedule(function()
          if vim.pack and vim.pack.get then
            local ok, packs = pcall(vim.pack.get, nil, { offline = true })
            if ok and type(packs) == 'table' then
              local pending_count = 0
              local log_completed = 0

              for _, pk in ipairs(packs) do
                if pk.rev and pk.rev_to and pk.rev ~= pk.rev_to then
                  pending_count = pending_count + 1
                  local name = pk.spec.name
                  vim.system({ 'git', 'log', '--oneline', pk.rev .. '..' .. pk.rev_to },
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
    end)
  end
end

function M.toggle_details()
  local name = st.plugin_at_cursor()
  if not name then return end
  st.state.expanded[name] = not st.state.expanded[name]
  st.state.restore_cursor_name = name
  render_mod.schedule_render()
end

function M.update_plugins(names)
  if #names == 0 then return end
  if vim.pack and vim.pack.update then
    utils.notify('Updating ' .. table.concat(names, ', ') .. '...', vim.log.levels.INFO)
    vim.schedule(function()
      local ok, err = pcall(vim.pack.update, names, { force = true, offline = true })
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
    utils.notify('Triggering DIY plugin update for ' .. names[1], vim.log.levels.INFO)
  end
end

function M.uninstall_plugin(name)
  if not name then return end
  local choice = vim.fn.confirm('Uninstall ' .. name .. ' from disk?', '&Yes\n&No', 2)
  if choice ~= 1 then return end

  if vim.pack and vim.pack.del then
    utils.notify('Uninstalling ' .. name .. '...', vim.log.levels.INFO)
    vim.schedule(function()
      local ok, err = pcall(vim.pack.del, { name }, { force = true })
      if not ok then
        utils.notify('Uninstall failed: ' .. tostring(err), vim.log.levels.ERROR)
      else
        st.state.updates[name] = nil
        st.state.commits[name] = nil
        st.state.expanded[name] = nil
        st.state.urls[name] = nil
        st.state.info = scanner.get_info()
        render_mod.schedule_render()
        utils.notify('Uninstalled ' .. name .. '. Please restart Nvim to apply changes.',
          vim.log.levels.WARN)
      end
    end)
  else
    utils.notify('Triggering DIY plugin uninstall for ' .. name, vim.log.levels.INFO)
  end
end

return M
