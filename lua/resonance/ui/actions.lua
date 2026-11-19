local M = {}
local st = require('resonance.ui.state')
local render_mod = require('resonance.ui.render')
local utils = require('resonance.utils')

local schedule = vim.schedule
local system = vim.system
local async = vim.async
local _system_async = async.wrap(3, system)
---@param cmd string[]
---@param opts table
---@return vim.SystemCompleted
local function system_async(cmd, opts)
  return _system_async(cmd, opts) --[[@as vim.SystemCompleted]]
end
local pcall = pcall
local type = type
local tostring = tostring
local math_floor = math.floor
local math_huge = math.huge
local table_concat = table.concat
local uv_fs_stat = vim.uv.fs_stat
local fn_confirm = vim.fn.confirm
local ui_input = vim.ui.input
local vim_log_levels = vim.log.levels
local string_format = string.format

-- How many `git fetch` run at once while Resonating. A fetch is almost all
-- network round trip (~0.5 s to GitHub) and next to no CPU, so the limit,
-- not the machine, sets the total time: at 5, 49 plugins took ten rounds.
-- The default is the one vim.pack uses for its own update.
local DEFAULT_FETCH_CONCURRENCY = 2 * (vim.uv.available_parallelism() or 1)
local fetch_concurrency = DEFAULT_FETCH_CONCURRENCY

--- Apply the `resonate` section of the user config.
---
--- A check builds its semaphore when it starts, so a new limit applies to
--- the next check, never to one in flight.
---@param opts? { concurrency?: integer }
function M.configure(opts)
  opts = opts or {}
  local n = opts.concurrency
  if n == nil then n = DEFAULT_FETCH_CONCURRENCY end
  if type(n) ~= 'number' or n < 1 or n ~= math_floor(n) or n == math_huge then
    utils.notify('resonate.concurrency must be a positive integer, got ' .. tostring(n) ..
      '; using ' .. DEFAULT_FETCH_CONCURRENCY, vim_log_levels.WARN)
    n = DEFAULT_FETCH_CONCURRENCY
  end
  fetch_concurrency = n
end

--- The number of `git fetch` allowed to run at once during a check.
---@return integer
function M.fetch_concurrency()
  return fetch_concurrency
end

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
      st.state.spinner_frame = (st.state.spinner_frame % 10) + 1
      render_mod.update_spinner() -- Use targeted redraw
    end)
  end)
end

-- Check for updates over the network.
--
-- Returns true when this call initiated a check, false when a check was
-- already running or there was nothing to check at all. The caller uses the
-- return value to decide whether to notify: the `r` key must stay quiet
-- while a check is in flight, otherwise holding the key stacks one
-- notification per press.
---@return boolean started
function M.check_updates_network()
  if st.state.checking then return false end
  st.state.checking = true
  st.state.updates = {} -- Clear stale state
  st.state.pending_count = 0 -- Clear the count left over from a previous check
  start_spinner()
  render_mod.render()

  local info = st.state.info
  if not info or not info.plugins then
    finish_check()
    return false
  end

  local names = info.plugins.name
  local paths = info.plugins.path

  -- A plugin disabled via `cond = false` has no directory on disk. Fetching
  -- it would spawn `git fetch` with an empty cwd, so only count the plugins
  -- that actually have a path.
  local valid_total = 0
  for i = 1, info.total do
    local path = paths[i]
    if path and path ~= '' then valid_total = valid_total + 1 end
  end

  -- Nothing to fetch. The check still started (the spinner is up), so the
  -- caller may report it, but it completes on the next tick.
  if valid_total == 0 then
    vim.defer_fn(finish_check, 200)
    return true
  end

  local completed_fetches = 0
  local check_semaphore = async.semaphore(fetch_concurrency)

  for i = 1, info.total do
    local path = paths[i]
    if path and path ~= '' then
      local run = async.run('resonance_fetch:' .. names[i], function()
        check_semaphore:with(function()
          -- Fetch all branches and tags silently in the background
          system_async({ 'git', 'fetch', '--tags', '--force' }, { cwd = path, text = true })
          return true
        end)
      end)

      run:on_complete(function(_)
        completed_fetches = completed_fetches + 1
        if completed_fetches >= valid_total then
          schedule(function()
            -- Network fetches are done. Ask native vim.pack to calculate rev_to offline
            local pack = utils.get_pack()
            if not pack then
              finish_check()
              return
            end

            local ok, packs = pcall(pack.get, nil, { info = true, offline = true })
            if not ok or type(packs) ~= 'table' then
              finish_check()
              return
            end

            local pending_logs = 0
            local logs_completed = 0

            for p = 1, #packs do
              local pk = packs[p]
              if pk.rev and pk.rev_to and pk.rev ~= pk.rev_to then
                pending_logs = pending_logs + 1
                local p_name = pk.spec.name
                -- The spinner shows how many updates are waiting.
                st.state.pending_count = st.state.pending_count + 1

                -- Local git log is fast enough for standard callbacks
                system({ 'git', 'log', '--oneline', pk.rev .. '..' .. pk.rev_to },
                  { cwd = pk.path, text = true }, function(out)
                    local lines = {}
                    if out.code == 0 and out.stdout then
                      for line in out.stdout:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
                    end
                    -- The revisions differ, so this is an update even when
                    -- `rev..rev_to` lists no commit -- a downgrade, a pin, a
                    -- force-pushed branch -- or the log failed. It used to be
                    -- left out: counted in the spinner, missing from the list,
                    -- and skipped by U.
                    if #lines == 0 then
                      lines[1] = string_format('%s -> %s', pk.rev:sub(1, 7), pk.rev_to:sub(1, 7))
                    end
                    st.state.updates[p_name] = lines
                    schedule(function() render_mod.schedule_render() end)

                    logs_completed = logs_completed + 1
                    if logs_completed >= pending_logs then
                      schedule(finish_check)
                    end
                  end)
              end
            end

            if pending_logs == 0 then
              finish_check()
            end
          end)
        end
      end)
    end
  end

  return true
end

--- Fetch the branches and tags for one plugin.
---
--- The UI used to ask pack.get for info = true across every installed
--- plugin when it opened. That is ~420 ms at 49 plugins and a ~2.5 s
--- main-thread freeze at 300 -- all of it for the branches and tags,
--- which are only shown on an expanded row. Now only the row that is
--- expanded is asked about.
---
--- The query runs as a cancellable task: it writes into st.state, which
--- the UI owns, and a deferred callback has no way to know the UI is
--- gone.
---@param name string
local function fetch_plugin_details(name)
  local details = st.state.pack_details[name]
  -- Already fetched: nothing to do.
  if details and (details.branches or details.tags) then return end

  local pack = utils.get_pack()
  if not pack then return end

  -- Only one details fetch is useful at a time. Expanding a second row
  -- makes the first fetch pointless, so it is cancelled instead of left
  -- to run: the two fetches would otherwise both hit pack.get with
  -- info = true, which is the expensive part.
  local previous = st.state.details_task
  if previous then
    st.state.details_task = nil
    pcall(previous.close, previous)
  end

  local task = async.run('resonance_ui_details', function()
    -- Yield once so the UI stays interactive.
    async.sleep(50)
    local ok, packs = pcall(pack.get, { name }, { offline = true, info = true })
    if not ok or type(packs) ~= 'table' or not packs[1] then return end
    -- The UI may have been closed while the fetch was running.
    if not st.state.buf then return end
    local pk = packs[1]
    local entry = st.state.pack_details[name] or {}
    if pk.branches then entry.branches = pk.branches end
    if pk.tags then entry.tags = pk.tags end
    st.state.pack_details[name] = entry
    render_mod.schedule_render()
  end)
  task:on_complete(function(err)
    if not err then return end
    -- A cancelled task reports the cancellation as the error "closed".
    -- That is expected: the task was replaced by a newer one, or the UI
    -- was closed. Only a task that is still the current one has a real
    -- failure to report.
    if st.state.details_task ~= task then return end
    if st.state.buf then
      utils.notify('Failed to load plugin details: ' .. tostring(err), vim_log_levels.ERROR)
    end
  end)
  st.state.details_task = task
end

function M.toggle_details()
  local name = st.plugin_at_cursor()
  if not name then return end
  local expanding = not st.state.expanded[name]
  st.state.expanded[name] = expanding or nil
  if expanding then
    fetch_plugin_details(name)
  end
  render_mod.render()
end

function M.update_plugins(names)
  if #names == 0 or st.state.updating then return end

  local pack = utils.get_pack()
  if pack and pack.update then
    st.state.updating = true
    utils.notify('Updating ' .. table_concat(names, ', ') .. '...', vim_log_levels.INFO)

    schedule(function()
      local ok, err = pcall(pack.update, names, { force = true, offline = false })
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
    -- It used to say "Triggering plugin update" and then do nothing.
    utils.notify('Updating needs vim.pack; nothing was updated', vim_log_levels.WARN)
  end
end

function M.uninstall_plugin(name)
  if not name then return end
  -- Checked before asking: without vim.pack the confirmation was asked
  -- for, and then nothing was uninstalled.
  local pack = utils.get_pack()
  if not (pack and pack.del) then
    utils.notify('Uninstalling needs vim.pack; ' .. name .. ' was left in place', vim_log_levels.WARN)
    return
  end
  local choice = fn_confirm('Uninstall ' .. name .. ' from disk?', '&Yes\n&No', 2)
  if choice ~= 1 then return end

  utils.notify('Uninstalling ' .. name .. '...', vim_log_levels.INFO)
  local ok, err = pcall(pack.del, { name }, { force = true })
  if ok then
    utils.notify('Uninstalled ' .. name, vim_log_levels.INFO)
    -- Forget that this plugin was built. The build artifacts live inside
    -- the plugin directory, so uninstalling the plugin deleted them --
    -- but the marker is in Resonance's own state directory and outlives
    -- the plugin. A reinstall of the same version lands on the same
    -- commit, so the marker still matched and the build was skipped. The
    -- plugin came back without its artifacts.
    require('resonance.loader.build').clear_build_marker(name)
    -- Drop everything the UI cached for this plugin. Otherwise the
    -- details of a plugin that is no longer on disk stay reachable for
    -- the rest of the session.
    st.state.pack_details[name] = nil
    st.state.urls[name] = nil
    st.state.commits[name] = nil
    st.state.updates[name] = nil
    st.state.expanded[name] = nil
    local scanner = require('resonance.scanner')
    scanner.load_times[name] = nil
    st.state.info = scanner.get_info()
  else
    utils.notify('Uninstall failed: ' .. tostring(err), vim_log_levels.ERROR)
  end
  render_mod.schedule_render()
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
