local M = {}
local utils = require('resonance.utils')
local spec = require('resonance.loader.spec')
local triggers = require('resonance.loader.triggers')
local build = require('resonance.loader.build')
local dag = require('resonance.loader.dag')

local api = vim.api
local uv = vim.uv

-- The cached plugin directories. Built once and then reused.
local _plugin_dir_cache = nil

-- Drop the cached plugin directories.
--
-- The cache is built once and then reused, so a plugin installed or
-- removed during the session was not in it: get_plugin_dir returned nil
-- for a plugin that was on disk, and the build hook was skipped.
local function invalidate_plugin_dir_cache()
  _plugin_dir_cache = nil
end

-- Install specs with vim.pack. `pack.add` raises when an install fails, so
-- the error is captured and returned instead of propagating. When vim.pack is
-- unavailable there is nothing to install and the call succeeds.
---@param specs table[]
---@return boolean ok, string|nil err
local function pack_install(specs)
  local pack = utils.get_pack()
  if not (pack and pack.add) then return true end
  local ok, err = pcall(pack.add, specs, { confirm = false, load = false })
  -- A fresh install is not in the cached plugin directories, so the cache
  -- has to go before anything looks the plugin up.
  invalidate_plugin_dir_cache()
  if not ok then return false, tostring(err) end
  return true
end

local nvim_cmd = api.nvim_cmd
local get_autocmds = api.nvim_get_autocmds
local exec_autocmds = api.nvim_exec_autocmds
local next = next
local table_concat = table.concat

local fs_scandir = uv.fs_scandir
local fs_scandir_next = uv.fs_scandir_next
local hrtime = uv.hrtime

local fn_stdpath = vim.fn.stdpath
local vim_log_levels = vim.log.levels
local pcall = pcall

local pack_dir_base = utils.fast_normalize(fn_stdpath('data') .. '/site/pack')

-- Pack layout segments: <data>/site/pack/<group>/<opt|start>/<plugin>
local SUB_DIRS = { 'opt', 'start' }

-- Internal plugin state (keyed by plugin name, not config table, to avoid memory leaks)
local plugin_state = {}

-- Force-load functions keyed by plugin name
local force_load_fns = {}

-- Plugins disabled by a false cond predicate
local disabled_plugins = {}

-- Plugin triggers registered by loader
local plugin_triggers = {}

-- Specs registered by loader
local specs = {}

-- The spec fields the loader keeps for the whole session. The setup
-- closure is deliberately dropped: it is called once, when the plugin
-- loads, and keeping it reachable would retain everything it captured for
-- the rest of the session.
--
-- The rest of the spec is copied as it is, because the spec table is
-- readable state -- get_dag_data, get_replay_info and the build hooks all
-- read from it.
local function retained_spec(config)
  local copy = {}
  for k, v in pairs(config) do
    if k ~= 'setup' and k ~= 'config' then
      copy[k] = v
    end
  end
  return copy
end

-- URL -> spec name mapping
local spec_urls = {}

-- Guards against recursive event replay. Replaying an event re-fires the
-- autocmds for it, which can re-enter load_now and start another replay.
-- Per-plugin `replay_done` is not enough: two plugins on the same event
-- replay each other indefinitely.
local replay_depth = 0
local MAX_REPLAY_DEPTH = 2

-- Events that have already fired, per buffer. The replay must not re-fire an
-- event that has already run for the buffer being loaded: a handler that
-- opens a file would recurse until Neovim aborts with E218.
--
-- Keyed by buffer so that a mark from an earlier read does not suppress the
-- events still pending for the current one.
local fired_events = {}

-- Which trigger groups have already run for a buffer.
--
-- The per-event table above answers "has this event fired for this buffer?".
-- That is the wrong question for a trigger: a group registered AFTER the
-- event fired has not seen the event yet, even though the event is in the
-- past. Tracking the groups separately lets the replay give a late-registered
-- trigger its chance, while still skipping the groups that already ran.
--
-- Keyed by buffer, then by group name.
local fired_groups = {}

-- BufRead and BufReadPost are aliases in Neovim: an autocmd registered for
-- one fires for the other, and get_autocmds matches them together. The
-- tracker only registers BufReadPost, so map BufRead onto it.
local function event_fired_key(event)
  if event == 'BufRead' then return 'BufReadPost' end
  return event
end

local function has_fired(event, buf)
  local per_buf = fired_events[buf]
  if not per_buf then return false end
  return per_buf[event_fired_key(event)] == true
end

local function mark_fired(event, buf)
  local per_buf = fired_events[buf]
  if not per_buf then
    per_buf = {}
    fired_events[buf] = per_buf
  end
  per_buf[event_fired_key(event)] = true
end

-- Whether a trigger group has already run for a buffer.
local function group_has_fired(group_name, buf)
  if not group_name then return false end
  local per_buf = fired_groups[buf]
  if not per_buf then return false end
  return per_buf[group_name] == true
end

-- Record that a trigger group has run for a buffer.
local function mark_group_fired(group_name, buf)
  if not group_name then return end
  local per_buf = fired_groups[buf]
  if not per_buf then
    per_buf = {}
    fired_groups[buf] = per_buf
  end
  per_buf[group_name] = true
end

local function populate_plugin_dir_cache()
  if _plugin_dir_cache then return end
  _plugin_dir_cache = {}

  local pack = utils.get_pack()
  if pack then
    local packs = pack.get(nil, { info = false, offline = true })
    for i = 1, #packs do
      local p = packs[i]
      if p.path and p.spec and p.spec.name then
        _plugin_dir_cache[p.spec.name] = p.path
      end
    end
    return
  end

  -- Fallback: filesystem scan of <data>/site/pack/<group>/<opt|start>/<plugin>
  local req = fs_scandir(pack_dir_base)
  if req then
    while true do
      local group, group_type = fs_scandir_next(req)
      if not group then break end
      if group_type == 'directory' or group_type == 'link' then
        for i = 1, #SUB_DIRS do
          local target_dir = pack_dir_base .. '/' .. group .. '/' .. SUB_DIRS[i]
          local sub = fs_scandir(target_dir)
          if sub then
            while true do
              local pname, ptyp = fs_scandir_next(sub)
              if not pname then break end
              if ptyp == 'directory' or ptyp == 'link' then
                _plugin_dir_cache[pname] = target_dir .. '/' .. pname
              end
            end
          end
        end
      end
    end
  end
end

local function get_plugin_dir(name)
  local cache = _plugin_dir_cache
  if not cache then
    populate_plugin_dir_cache()
    cache = _plugin_dir_cache
  end
  return cache and cache[name] or nil
end

-- A plugin counts as installed only when its directory exists on disk.
-- `:packadd` reports success for a plugin that was never installed, so it
-- cannot be used to detect a failed install.
---@param name string
---@return boolean
local function is_installed(name)
  local pack = utils.get_pack()
  if pack and pack.get then
    local ok, packs = pcall(pack.get, { name }, { info = false, offline = true })
    if ok and type(packs) == 'table' and packs[1] and packs[1].path then
      return uv.fs_stat(packs[1].path) ~= nil
    end
    return false
  end
  -- No vim.pack: fall back to the filesystem scan.
  local dir = get_plugin_dir(name)
  return dir ~= nil and uv.fs_stat(dir) ~= nil
end

-- Record which events have fired, per buffer. The replay uses this to avoid
-- re-firing an event that already ran for the buffer being loaded: when a
-- plugin loads on BufReadPre, BufRead and BufReadPost are still to come for
-- the same read and will fire naturally.
--
-- Note: nvim_create_autocmd('BufRead') registers a BufReadPost autocmd (the
-- two are aliases), so BufRead is tracked via BufReadPost.
local TRACKED_EVENTS = { 'BufReadPre', 'BufReadPost', 'BufNewFile', 'BufEnter', 'FileType' }
local tracker_group = nil
local function setup_event_tracker()
  if tracker_group then return end
  tracker_group = api.nvim_create_augroup('ResonanceEventTracker', { clear = true })
  for i = 1, #TRACKED_EVENTS do
    local name = TRACKED_EVENTS[i]
    api.nvim_create_autocmd(name, {
      group = tracker_group,
      callback = function(args)
        mark_fired(name, args.buf)
        -- Mark every trigger group that existed when this event fired: they
        -- have seen the event, so the replay must not fire them again.
        --
        -- A group registered AFTER the event is not marked here, which is
        -- exactly what lets a late-registered trigger still load.
        local autocmds = get_autocmds({ event = name })
        for a = 1, #autocmds do
          local autocmd = autocmds[a]
          if autocmd.event == name and autocmd.group_name then
            mark_group_fired(autocmd.group_name, args.buf)
          end
        end
      end,
    })
  end

  -- The fired state is keyed by buffer id, so it has to be pruned when a
  -- buffer goes away. Without this, every buffer a user ever opened stayed
  -- in the tables for the whole session.
  api.nvim_create_autocmd('BufWipeout', {
    group = tracker_group,
    callback = function(args)
      fired_events[args.buf] = nil
      fired_groups[args.buf] = nil
    end,
  })
end

setup_event_tracker()

-- Whether an event has already fired for a buffer.
--
-- A user config that replays missed events can use this to skip the events
-- that already ran, instead of firing them a second time.
---@param event string
---@param buf integer
---@return boolean
function M.has_fired(event, buf)
  if not event or not buf then return false end
  return has_fired(event, buf)
end

-- Replay the read events a buffer has already missed.
--
-- Fires only the trigger groups that have not yet run for the buffer, so a
-- handler is not invoked twice for the same read. Events that are still
-- pending for the current read are left alone: Neovim fires them naturally.
--
-- The unit of "already ran" is the trigger group, not the event. A group
-- registered after the event already fired has not seen it yet, and must
-- still get its chance to load: that is the `nvim <file>` path, where
-- BufReadPost and BufEnter fire before UIEnter -> VeryLazy, and the UI
-- plugins register their triggers in VeryLazy.
---@param buf integer
---@return string[] fired the events that were replayed
function M.replay_for_buffer(buf)
  local fired = {}
  if not buf then return fired end
  if not api.nvim_buf_is_valid(buf) then return fired end
  local api_exec = exec_autocmds

  -- A buffer with a name that exists on disk was read; one without was
  -- created new.
  local name = api.nvim_buf_get_name(buf)
  local is_file = false
  if name ~= '' then
    local stat = uv.fs_stat(name)
    is_file = stat ~= nil and stat.type == 'file'
  end

  -- Fire one event once per trigger group that has not run for this buffer.
  --
  -- Firing the whole event would re-run the groups that already saw it,
  -- which is what caused the duplicate handlers and the E218 recursion. So
  -- the event is fired once per pending group, scoped to that group.
  local function fire_groups(event)
    local autocmds = get_autocmds({ event = event })
    local done = {}
    local any = false
    for a = 1, #autocmds do
      local autocmd = autocmds[a]
      -- get_autocmds matches BufRead and BufReadPost together, so filter to
      -- the event actually being replayed.
      if autocmd.event == event then
        local group_name = autocmd.group_name
        if group_name and not done[group_name] and not group_has_fired(group_name, buf) then
          done[group_name] = true
          mark_group_fired(group_name, buf)
          api_exec(event, { buf = buf, group = group_name, modeline = false })
          any = true
        end
      end
    end
    if any then fired[#fired + 1] = event end
  end

  -- The is_file split decides between the events that genuinely differ for
  -- an existing file versus a new one. BufEnter fires for every buffer, so
  -- it is replayed either way -- putting it in the "not a file" branch left
  -- a BufEnter-only trigger group permanently unreplayed on the
  -- `nvim <file>` path.
  if is_file then
    fire_groups('BufReadPre')
    fire_groups('BufReadPost')
  else
    fire_groups('BufNewFile')
  end

  fire_groups('BufEnter')
  fire_groups('FileType')

  return fired
end

-- Public API: get_plugin_dir for build module
M.get_plugin_dir = get_plugin_dir

M.build_hooks = build.build_hooks
M.run_build = build.run_build
M.check_and_build = build.check_and_build
M.mark_build_success = build.mark_build_success
M.setup_packchanged_autocmd = build.setup_packchanged_autocmd
build.setup_packchanged_autocmd(get_plugin_dir)

-- A plugin installed or removed during the session was not in the cached
-- plugin directories, so the cache has to go when one is.
api.nvim_create_autocmd('PackChanged', {
  group = api.nvim_create_augroup('ResonancePluginDirCache', { clear = true }),
  callback = function()
    invalidate_plugin_dir_cache()
  end,
})

M.plugin_triggers = plugin_triggers
M.specs = specs
M.spec_urls = spec_urls
M.disabled_plugins = disabled_plugins
M.force_load_fns = force_load_fns

-- Reset all internal state (for testing)
function M._reset()
  for k in pairs(plugin_state) do plugin_state[k] = nil end
  for k in pairs(force_load_fns) do force_load_fns[k] = nil end
  for k in pairs(disabled_plugins) do disabled_plugins[k] = nil end
  for k in pairs(M.specs) do M.specs[k] = nil end
  for k in pairs(M.plugin_triggers) do M.plugin_triggers[k] = nil end
  for k in pairs(M.spec_urls) do M.spec_urls[k] = nil end
  for k in pairs(fired_events) do fired_events[k] = nil end
  for k in pairs(fired_groups) do fired_groups[k] = nil end
  replay_depth = 0
  _plugin_dir_cache = nil
end

-- Export module table for testing state
M._internal = {
  plugin_state = plugin_state,
  force_load_fns = force_load_fns,
  disabled_plugins = disabled_plugins,
}


---@param config table
function M.load(config)
  local is_plugin_list = type(config[1]) == 'table'
    and not config.plugin and not config.url and not config.src
    and not config.event and not config.cmd and not config.keys
    and not config.ft and not config.config and not config.setup

  if is_plugin_list then
    for i = 1, #config do
      if type(config[i]) == 'table' then
        M.load(config[i])
      end
    end
    return
  end

  local parsed_config, parse_reason, rejected_config = spec.parse_config(config)
  if not parsed_config then
    if parse_reason == 'disabled' and rejected_config then
      local rejected_plugins = rejected_config.plugin
      if type(rejected_plugins) == 'string' then
        rejected_plugins = { rejected_plugins }
      elseif type(rejected_plugins) == 'table' and rejected_plugins[1] == nil then
        rejected_plugins = { rejected_plugins }
      end
      local disabled_trigger = utils.parse_trigger(rejected_config) or 'none'
      local disabled_names, disabled_specs = spec.extract_names(rejected_plugins or {})
      for i = 1, #disabled_names do
        local name = disabled_names[i]
        local disabled_spec = disabled_specs[i]
        local disabled_url = type(disabled_spec) == 'string' and disabled_spec or
          (disabled_spec and (disabled_spec.src or disabled_spec.url or disabled_spec[1]))
        disabled_plugins[name] = {
          trigger = disabled_trigger,
          reason = 'cond',
          url = disabled_url,
        }
      end
    end
    return
  end
  config = parsed_config


  local plugins = config.plugin
  local parsed_deps = utils.parse_dependencies(config)
  local trig_str = utils.parse_trigger(config)
  local parsed_names, pack_plugins = spec.extract_names(plugins)

  for i = 1, #parsed_names do
    local name = parsed_names[i]
    disabled_plugins[name] = nil
    if name and trig_str then M.plugin_triggers[name] = trig_str end
    if name then M.specs[name] = retained_spec(config) end
    -- Map URL to name for dependency resolution
    local target_url = type(pack_plugins[i]) == 'string' and pack_plugins[i] or
      (pack_plugins[i].src or pack_plugins[i][1])
    if target_url then
      M.spec_urls[target_url] = name
    end
  end

  -- Register build hooks
  for p = 1, #plugins do
    local plugin = plugins[p]
    local build_cmd = (type(plugin) == 'table' and plugin.build) or config.build
    local name = parsed_names[p]

    if name and build_cmd then
      M.build_hooks[name] = build_cmd
      build.check_and_build(name, get_plugin_dir(name), build_cmd)
    end
  end

  -- The name of the augroup that holds this spec's triggers. The replay
  -- addresses trigger groups individually, so the loader has to know which
  -- group belongs to which spec.
  local group_name = parsed_names[1]
  if not group_name then
    local first = config.plugin
    if type(first) == 'string' then
      group_name = utils.extract_name(first)
    elseif type(first) == 'table' then
      local src = first.src or first[1] or first.url
      group_name = first.name or (src and utils.extract_name(src))
    end
  end
  local trigger_group_name = triggers.trigger_group_name(group_name)

  -- Create a single load_now function that loads all plugins in the group
  -- This ensures force_load_fns works for dependency resolution for any plugin in the group
  local current_name = parsed_names[1]

  -- The teardown callbacks for this spec's triggers. They are filled in by
  -- register_all below, which runs after load_now is defined. Once the
  -- plugin is loaded, every trigger of this spec is removed -- not just the
  -- one that fired. The others are stubs that have done their job, and
  -- leaving them in place means they keep firing.
  local trigger_teardown = {}

  local function teardown_triggers()
    for i = 1, #trigger_teardown do
      pcall(trigger_teardown[i])
    end
    trigger_teardown = {}
  end

  --- Load this spec's plugins now.
  ---
  --- Returns true when the plugins are loaded (or were already loaded), and
  --- false when the load failed: an install error, or a dependency cycle
  --- that was aborted. A dependency that returns false stops its parent:
  --- running the parent's setup() with a broken dependency is worse than
  --- not running it at all.
  ---@return boolean ok
  local function load_now(ev, visiting_path)
    -- This trigger group has now seen the event. Record it so a later replay
    -- does not fire it a second time for the same buffer.
    if ev and type(ev) == 'table' and ev.buf then
      mark_group_fired(trigger_group_name, ev.buf)
    end

    -- Track each member independently while sharing one group load callback.
    local state = plugin_state[current_name]
    if not state then
      state = { loaded = false }
      plugin_state[current_name] = state
    end
    local member_loaded = {}
    local all_loaded = true
    for i = 1, #parsed_names do
      local member_state = plugin_state[parsed_names[i]]
      local loaded = member_state and member_state.loaded or false
      member_loaded[i] = loaded
      if not loaded then all_loaded = false end
    end

    -- Initialize visiting_path if nil
    if not visiting_path then visiting_path = {} end

    -- Use ordered list for cycle detection to preserve path order
    local path_order = visiting_path._order
    if not path_order then
      path_order = {}
      visiting_path._order = path_order
    end

    -- Cycle check MUST happen before early return on state.loaded
    -- This ensures recursive loads (A->B->A) are detected even if A was already loaded
    if current_name then
      if visiting_path[current_name] then
        local msg = table_concat(path_order, ' -> ') .. ' -> ' .. current_name
        utils.notify('Circular dependency detected: ' .. msg .. ' (aborting)', vim_log_levels.ERROR)
        return false
      end
    end

    if all_loaded then return true end
    state.loaded = true

    -- Abort the load when an install fails. The plugin is left unloaded so a
    -- later attempt can try again, and the error is reported: a silent
    -- failure leaves a plugin that never loads and never loads again.
    local function fail_install(message)
      state.loaded = false
      if current_name then
        visiting_path[current_name] = nil
        if path_order[#path_order] == current_name then
          path_order[#path_order] = nil
        end
      end
      utils.notify(message, vim_log_levels.ERROR)
      return false
    end

    if current_name then
      visiting_path[current_name] = true
      path_order[#path_order + 1] = current_name
    end

    for i = 1, #parsed_deps do
      local dep = parsed_deps[i]
      local dep_url = type(dep.raw) == 'string' and dep.raw or
        (dep.raw.src or dep.raw[1] or dep.raw.url)
      local spec_name = M.specs[dep.name] and dep.name or
        (dep_url and M.spec_urls[dep_url])
      if spec_name and M.specs[spec_name] then
        local fn = force_load_fns[spec_name]
        -- The dependency's loader reports its own failure. A dependency
        -- that failed to install must stop the parent: running the
        -- parent's setup() with a broken dependency is worse than not
        -- running it at all.
        if fn and fn(nil, visiting_path) == false then
          return fail_install('Dependency failed to load: ' .. dep.name)
        end
      else
        local dep_ok, dep_err = pack_install({ dep.raw })
        if not dep_ok then
          return fail_install('Dependency install failed for ' .. dep.name .. ': ' .. dep_err)
        end
        if not is_installed(dep.name) then
          return fail_install('Dependency install failed for ' .. dep.name ..
            ': plugin directory not found')
        end
        pcall(nvim_cmd, { cmd = 'packadd', args = { dep.name } })
      end
    end

    local start_ms = hrtime()

    if #pack_plugins > 0 then
      local ok, err = pack_install(pack_plugins)
      if not ok then
        return fail_install('Install failed for ' .. table_concat(parsed_names, ', ') ..
          ': ' .. err)
      end
    end

    -- `:packadd` reports success for a plugin that was never installed, so
    -- verify the install landed before loading it.
    for i = 1, #parsed_names do
      if not is_installed(parsed_names[i]) then
        return fail_install('Install failed for ' .. parsed_names[i] ..
          ': plugin directory not found')
      end
    end

    for i = 1, #parsed_names do
      pcall(nvim_cmd, { cmd = 'packadd', args = { parsed_names[i] } })
    end

    -- Call setup once per member that was not already loaded.
    for pi = 1, #parsed_names do
      if not member_loaded[pi] then
        local plugin_spec = plugins[pi]
        local plugin_setup = type(plugin_spec) == 'table' and plugin_spec.setup
        if plugin_setup then
          local ok, err = pcall(plugin_setup)
          if not ok then
            utils.notify('Setup error for ' .. parsed_names[pi] .. ': ' .. tostring(err),
              vim_log_levels.ERROR)
          end
        elseif config.setup and pi == 1 then
          -- Only call config.setup once (for first plugin) as fallback
          local ok, err = pcall(config.setup)
          if not ok then utils.notify('Setup error: ' .. tostring(err), vim_log_levels.ERROR) end
        end
      end
    end

    for i = 1, #parsed_names do
      local member_state = plugin_state[parsed_names[i]]
      if not member_state then
        member_state = {}
        plugin_state[parsed_names[i]] = member_state
      end
      member_state.loaded = true
    end

    -- The plugin is loaded, so every trigger of this spec is done. Remove
    -- the ones that did not fire too: they are stubs that would otherwise
    -- keep firing against a plugin that is already loaded.
    teardown_triggers()

    if current_name then
      visiting_path[current_name] = nil
      if path_order[#path_order] == current_name then
        path_order[#path_order] = nil
      end
    end

    local duration = (hrtime() - start_ms) / 1e6
    local scanner = package.loaded['resonance.scanner'] or require('resonance.scanner')
    for i = 1, #parsed_names do
      scanner.load_times[parsed_names[i]] = duration
    end

    if ev and type(ev) == 'table' and ev.event and not state.replay_done then
      state.replay_done = true
      -- The retained spec is a copy, so the replay flag is set on it.
      -- get_replay_info reads the copy; the user's own table is not
      -- touched.
      local retained = specs[current_name]
      if retained then retained._replay_done = true end
      -- A replay re-fires autocmds, which can re-enter load_now. Bound the
      -- nesting so a plugin whose handler triggers the same event cannot
      -- recurse until Neovim aborts with E218.
      if replay_depth >= MAX_REPLAY_DEPTH then return true end

      -- Only replay events that have already fired for this buffer. When a
      -- plugin loads from BufReadPre, Neovim still has BufRead and BufReadPost
      -- to fire for this same read; replaying them here would run them twice,
      -- and a handler that opens a file (snacks picker, for one) would recurse
      -- until Neovim aborts with E218.
      --
      -- The check is per buffer: a mark left by an earlier read must not
      -- suppress the events still pending for the current one.
      local origin_event = event_fired_key(ev.event)
      if not has_fired(ev.event, ev.buf) then
        -- The trigger is the first event of its group, so nothing has fired
        -- yet and there is nothing to replay.
        return true
      end

      local chain = ev.event ~= 'User' and dag._get_event_chain_internal(ev.event, ev.buf, ev.data) or
        {}
      replay_depth = replay_depth + 1
      local replay_ok, replay_err = pcall(function()
        for c = 1, #chain do
          local c_opts = chain[c]
          -- Skip the origin event: it is the one currently being handled.
          -- Skip events that have not fired for this buffer yet: they will
          -- fire naturally.
          if event_fired_key(c_opts.event) ~= origin_event and has_fired(c_opts.event, ev.buf) then
            local autocmds = get_autocmds({ event = c_opts.event })
            local done = {}
            for a = 1, #autocmds do
              local autocmd = autocmds[a]
              -- get_autocmds matches BufRead and BufReadPost together, so
              -- filter to the event actually being replayed.
              if autocmd.event == c_opts.event then
                local group_name = autocmd.group_name
                -- Ungrouped autocmds cannot be selected individually, and
                -- firing the whole event would re-run the autocmd we are
                -- executing. Only grouped autocmds can be replayed safely.
                if group_name and not c_opts.exclude[group_name] and not done[group_name] then
                  done[group_name] = true
                  exec_autocmds(c_opts.event,
                    { buf = c_opts.buf, group = group_name, modeline = false, data = c_opts.data })
                end
              end
            end
          end
        end
      end)
      replay_depth = replay_depth - 1
      if not replay_ok then error(replay_err) end
    end

    return true
  end

  -- Store force_load for ALL plugins in the group (so dependency resolution works for any of them)
  for i = 1, #parsed_names do
    force_load_fns[parsed_names[i]] = load_now
  end

  -- Register the triggers in a group named after the plugin, so the replay
  -- can address them individually and exclude the ones that already ran.
  trigger_teardown = triggers.register_all(config, load_now, triggers.trigger_group(group_name))
end

---@return table<string, {name:string, deps:string[], trigger:string, loaded:boolean}>, table<string, string[]>
function M.get_dag_data()
  local scanner = package.loaded['resonance.scanner'] or require('resonance.scanner')
  local scanner_info = scanner.get_info()
  return dag.get_dag_data(M.specs, plugin_state, scanner_info, disabled_plugins)
end

---@return table<string, {event:string, chain:string[], replayed:boolean}>
function M.get_replay_info()
  return dag.get_replay_info(M.specs, M.plugin_triggers)
end

function M._get_event_chain_internal(event, buf, data)
  return dag._get_event_chain_internal(event, buf, data)
end

return M
