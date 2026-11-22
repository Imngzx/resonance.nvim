local M = {}
local utils = require('resonance.utils')
local registry = require('resonance.registry')
local spec = require('resonance.loader.spec')
local triggers = require('resonance.loader.triggers')
local build = require('resonance.loader.build')
local builds = require('resonance.builds')
local replay = require('resonance.loader.replay')

local api = vim.api
local uv = vim.uv

local nvim_cmd = api.nvim_cmd
local table_concat = table.concat

local hrtime = uv.hrtime
local fn_stdpath = vim.fn.stdpath

local vim_log_levels = vim.log.levels
local pcall = pcall
local schedule = vim.schedule

local mark_group_fired = replay.mark_group_fired

local fs_scandir = uv.fs_scandir
local fs_scandir_next = uv.fs_scandir_next

local pack_dir_base = utils.fast_normalize(fn_stdpath('data') .. '/site/pack')

-- Pack layout segments: <data>/site/pack/<group>/<opt|start>/<plugin>
local SUB_DIRS = { 'opt', 'start' }

-- The cached plugin directories. Built once and then reused.
--
-- The cache is built once and then reused, so a plugin installed or
-- removed during the session was not in it: get_plugin_dir returned nil
-- for a plugin that was on disk, and the build hook was skipped.
local function invalidate_plugin_dir_cache()
  registry.invalidate_plugin_dirs()
end

-- How many vim.pack installs are running, and what waits for them to end.
--
-- vim.pack.add waits for its git clones by running the event loop, so
-- anything scheduled meanwhile runs in the middle of the install. On a first
-- start that included VeryLazy: it fired while the `lazy = false` plugins
-- were still cloning, so VeryLazy plugins were set up before the colorscheme.
-- Worse, an eager install runs inside a VimEnter handler, and Neovim does not
-- fire autocommands from inside another one: a file opened during the
-- install never fired its BufReadPost, its plugin never loaded, and the
-- VeryLazy replay that would have caught it had already run.
local installs_running = 0
local after_installs = {}

-- Run what waited for the installs, unless another one has started since.
local function run_after_installs()
  if installs_running > 0 or #after_installs == 0 then return end
  local list = {}
  for i = 1, #after_installs do
    list[i] = after_installs[i]
    after_installs[i] = nil
  end
  for i = 1, #list do
    local ok, err = pcall(list[i])
    if not ok then
      utils.notify('Callback after install failed: ' .. tostring(err), vim_log_levels.ERROR)
    end
  end
end

--- Whether a vim.pack install is running.
---@return boolean
function M.installing()
  return installs_running > 0
end

--- Run fn once no vim.pack install is running: now if none is, otherwise on
--- the main loop after the last one ends.
---@param fn function
function M.after_installs(fn)
  if installs_running == 0 then
    fn()
    return
  end
  after_installs[#after_installs + 1] = fn
end

-- Install specs with vim.pack. `pack.add` raises when an install fails, so
-- the error is captured and returned instead of propagating. When vim.pack is
-- unavailable there is nothing to install and the call succeeds.
---@param specs table[]
---@return boolean ok, string|nil err
local function pack_install(specs)
  local pack = utils.get_pack()
  if not (pack and pack.add) then return true end
  installs_running = installs_running + 1
  local ok, err = pcall(pack.add, specs, { confirm = false, load = false })
  installs_running = installs_running - 1
  -- Scheduled, not run here: the load that installed has its setup still
  -- to run, and what waited -- VeryLazy -- has to come after it.
  if installs_running == 0 and #after_installs > 0 then
    schedule(run_after_installs)
  end
  -- A fresh install is not in the cached plugin directories, so the cache
  -- has to go before anything looks the plugin up.
  invalidate_plugin_dir_cache()
  if not ok then return false, tostring(err) end
  return true
end

local function populate_plugin_dir_cache()
  if registry.plugin_dirs then return end

  -- The table is built in a local and published at the end.
  --
  -- pack.get() can fire PackChanged, which invalidates the cache and
  -- sets registry.plugin_dirs back to nil. Writing into the registry
  -- table directly would then write into a table nobody holds any more,
  -- and the cache would stay empty.
  local dirs = {}

  local pack = utils.get_pack()
  if pack then
    local packs = pack.get(nil, { info = false, offline = true })
    for i = 1, #packs do
      local p = packs[i]
      if p.path and p.spec and p.spec.name then
        dirs[p.spec.name] = p.path
      end
    end
    registry.plugin_dirs = dirs
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
                dirs[pname] = target_dir .. '/' .. pname
              end
            end
          end
        end
      end
    end
  end
  registry.plugin_dirs = dirs
end

---@param name string
---@return string|nil
local function get_plugin_dir(name)
  local cache = registry.plugin_dirs
  if not cache then
    populate_plugin_dir_cache()
    cache = registry.plugin_dirs
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

-- Internal plugin state (keyed by plugin name, not config table, to avoid memory leaks)
local plugin_state = {}

-- Force-load functions keyed by plugin name
local force_load_fns = {}

-- The shared, pure-data state lives in the registry, so the scanner can
-- read it without requiring the loader -- which would close a cycle and
-- drag the whole control plane into the read-only UI panel.
local disabled_plugins = registry.disabled_plugins
local plugin_triggers = registry.plugin_triggers
local specs = registry.specs
local spec_urls = registry.spec_urls

-- The spec fields the loader keeps for the whole session. The setup
-- closure is deliberately dropped: it is called once, when the plugin
-- loads, and keeping it reachable would retain everything it captured for
-- the rest of the session.
--
-- The rest of the spec is copied as it is, because the spec table is
-- readable state -- get_dag_data, get_replay_info and the build hooks all
-- read from it.
-- The DAG and event-chain data are read by the panel, never on the
-- startup path, so the module is required on first use.
local function get_dag()
  return require('resonance.loader.dag')
end

local function retained_spec(config)
  local copy = {}
  for k, v in pairs(config) do
    if k ~= 'setup' and k ~= 'config' then
      copy[k] = v
    end
  end
  return copy
end

M.has_fired = replay.has_fired
M.replay_for_buffer = replay.replay_for_buffer

-- Public API: get_plugin_dir for build module
M.get_plugin_dir = get_plugin_dir

M.build_hooks = build.build_hooks
M.run_build = build.run_build
M.check_and_build = build.check_and_build
M.mark_build_success = build.mark_build_success
M.setup_packchanged_autocmd = build.setup_packchanged_autocmd

M.plugin_triggers = plugin_triggers
M.specs = specs
M.spec_urls = spec_urls
M.disabled_plugins = disabled_plugins
M.force_load_fns = force_load_fns

-- The autocmds the loader needs are installed on first use, not when the
-- module is required. Requiring the loader used to register two
-- PackChanged handlers and five event-tracker autocmds as a side effect,
-- so anything that merely touched the loader -- the scanner, for one --
-- installed a control plane it never asked for.
--
-- The guard is a flag rather than the tracker group, because the two
-- halves are installed independently.
local autocmds_installed = false
local function ensure_autocmds()
  if autocmds_installed then return end
  autocmds_installed = true

  build.setup_packchanged_autocmd(get_plugin_dir)

  -- A plugin installed or removed during the session was not in the cached
  -- plugin directories, so the cache has to go when one is.
  api.nvim_create_autocmd('PackChanged', {
    group = api.nvim_create_augroup('ResonancePluginDirCache', { clear = true }),
    callback = function()
      invalidate_plugin_dir_cache()
    end,
  })
end

-- Reset all internal state (for testing)
function M._reset()
  for k in pairs(plugin_state) do plugin_state[k] = nil end
  for k in pairs(force_load_fns) do force_load_fns[k] = nil end
  for k in pairs(disabled_plugins) do disabled_plugins[k] = nil end
  for k in pairs(M.specs) do M.specs[k] = nil end
  for k in pairs(M.plugin_triggers) do M.plugin_triggers[k] = nil end
  for k in pairs(M.spec_urls) do M.spec_urls[k] = nil end
  for k in pairs(registry.load_times) do registry.load_times[k] = nil end
  replay._reset()
  for i = #after_installs, 1, -1 do after_installs[i] = nil end
  registry.invalidate_plugin_dirs()
  -- The autocmds are still installed, so the guard stays set: reinstalling
  -- them would create a second copy of every handler.
end

-- Install the control plane.
--
-- The event tracker has to be in place before the first read event fires,
-- or the events that already fired are not recorded and the replay fires
-- them a second time. So this is called from resonance.setup(), which is
-- the first thing a config does.
--
-- It is a separate call, not a require-time side effect, because anything
-- that merely touches the loader -- the scanner, for one -- must not
-- install autocmds it never asked for.
function M.setup()
  ensure_autocmds()
  replay.ensure_tracker()
end

-- Export module table for testing state
M._internal = {
  plugin_state = plugin_state,
  force_load_fns = force_load_fns,
  disabled_plugins = disabled_plugins,
  fired_events = replay.fired_events,
  fired_groups = replay.fired_groups,
}


-- A spec switched off by its `cond` is still listed in the panel, with the
-- trigger it would have had.
local function record_disabled(rejected_config)
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

-- Record the spec's members in the shared state: the trigger the panel
-- shows, the retained spec, and the URL -> name map that dependency
-- resolution reads.
local function register_members(config, parsed_names, pack_plugins, trig_str)
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
end

-- Register the build hooks, and start the builds that are due.
local function register_builds(config, plugins, parsed_names)
  for p = 1, #plugins do
    local plugin = plugins[p]
    local build_cmd = (type(plugin) == 'table' and plugin.build) or config.build
    local name = parsed_names[p]

    if name and build_cmd then
      M.build_hooks[name] = build_cmd
      build.check_and_build(name, get_plugin_dir(name), build_cmd)
    end
  end
end

-- The name of the augroup that holds this spec's triggers. The replay
-- addresses trigger groups individually, so the loader has to know which
-- group belongs to which spec.
local function spec_group_name(config, parsed_names)
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
  return group_name
end

-- Take a spec off the dependency path once its load is over, whether it
-- succeeded or failed.
local function leave_path(visiting_path, path_order, name)
  if not name then return end
  visiting_path[name] = nil
  if path_order[#path_order] == name then
    path_order[#path_order] = nil
  end
end

-- Load a spec's dependencies: a dependency with a spec of its own through
-- that spec's loader, any other one installed and added directly.
---@return string|nil err why a dependency failed; nil when all loaded
local function load_dependencies(parsed_deps, visiting_path)
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
        return 'Dependency failed to load: ' .. dep.name
      end
    else
      local dep_ok, dep_err = pack_install({ dep.raw })
      if not dep_ok then
        return 'Dependency install failed for ' .. dep.name .. ': ' .. dep_err
      end
      if not is_installed(dep.name) then
        return 'Dependency install failed for ' .. dep.name ..
          ': plugin directory not found'
      end
      pcall(nvim_cmd, { cmd = 'packadd', args = { dep.name } })
    end
  end
  return nil
end

-- Start the builds of the members that need one, and report which members
-- are building.
--
-- The build is started here because the plugin may have been installed by
-- this very load: the PackChanged handler starts the build, but that
-- happens after the install, and the load that triggered it is already on
-- its way to the setup.
---@return table<integer, true> building the indexes of the building members
local function start_builds(parsed_names)
  local building = {}
  for pi = 1, #parsed_names do
    local plugin_name = parsed_names[pi]
    local build_cmd = M.build_hooks[plugin_name]
    if build_cmd then
      -- The build is started if it is not running already. A plugin
      -- that was just installed has no build running yet, and the
      -- setup must not race it.
      --
      -- A build that already failed in this session is not started again
      -- here. It would fail the same way, and a cmd/keys load would block
      -- for up to BUILD_WAIT_MS waiting for it. An install or update
      -- (PackChanged) still retries it.
      local status = builds.status(plugin_name)
      if not (status and status.state == 'failed') then
        build.check_and_build(plugin_name, get_plugin_dir(plugin_name), build_cmd)
      end
      if build.is_building(plugin_name) then
        building[pi] = true
      end
    end
  end
  return building
end

-- Whether VimEnter has happened. A field of the module so a test can stand
-- in for a started session: the suite runs from `-c` commands, which come
-- before VimEnter, and v:vim_did_enter cannot be written.
function M._startup_over()
  return vim.v.vim_did_enter == 1
end

-- Whether the spec waits for a startup event that is already over.
--
-- VimEnter comes once, and VeryLazy fires once. A spec registered after
-- them -- a load() call from a command, a mapping or a late-loaded config --
-- got a trigger that could never fire: an eager spec, a spec with no
-- trigger and a `lazy = true` spec were registered and then never loaded,
-- with no message.
---@param config table the parsed spec
---@return boolean
local function startup_trigger_passed(config)
  local entered = M._startup_over()
  local verylazy_fired = registry.verylazy_fired
  if not entered and not verylazy_fired then return false end
  local events = utils.normalize_events(config.event)
  for i = 1, #events do
    local e = events[i]
    if e.user then
      if verylazy_fired and e.pattern == 'VeryLazy' then return true end
    elseif entered and e.event == 'VimEnter' then
      return true
    end
  end
  return false
end

-- How long an explicit user action waits for a build before giving up
-- and letting the build finish in the background.
local BUILD_WAIT_MS = 30000

---@param config table
function M.load(config)
  -- This is the first thing a user does with Resonance, so it is where
  -- the control plane is installed.
  ensure_autocmds()
  replay.ensure_tracker()

  if spec.is_plugin_list(config) then
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
      record_disabled(rejected_config)
    end
    return
  end
  config = parsed_config

  local plugins = config.plugin
  local parsed_deps = utils.parse_dependencies(config)
  local trig_str = utils.parse_trigger(config)
  local parsed_names, pack_plugins = spec.extract_names(plugins)

  -- A spec with no plugin in it -- { event = ..., setup = fn } -- has nothing
  -- to load. Its trigger used to be registered anyway, and crashed with
  -- "table index is nil" when it fired; even without the crash, a spec with
  -- no members counts as loaded, so its setup never ran.
  if #parsed_names == 0 then
    utils.notify('Spec has no plugin (src, url or a URL as [1]), skipped: ' ..
      (utils.parse_trigger(config) or 'no trigger'), vim_log_levels.ERROR)
    return
  end

  register_members(config, parsed_names, pack_plugins, trig_str)
  register_builds(config, plugins, parsed_names)

  local group_name = spec_group_name(config, parsed_names)
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

  -- The command stubs have to go before the plugin's setup runs. A stub is
  -- a real user command, so it owns the name: the plugin's own
  -- nvim_create_user_command() for that name would fail while the stub is
  -- still there.
  local trigger_teardown_before_setup = {}

  local function run_teardown(list)
    for i = 1, #list do
      pcall(list[i])
      list[i] = nil
    end
  end

  -- The setup closures, kept until the build is done.
  --
  -- A deferred setup has to hold on to the closure until the build
  -- finishes. It is dropped as soon as it has run, so the closure does not
  -- stay reachable for the rest of the session.
  local deferred_setups = nil

  -- Drop the setup closures once they have all run.
  --
  -- They are the only part of the spec that holds onto the user's state,
  -- and the load_now closure keeps the spec alive for the whole session.
  local function release_setups()
    config.setup = nil
    config.config = nil
    for i = 1, #plugins do
      local plugin_spec = plugins[i]
      if type(plugin_spec) == 'table' then
        plugin_spec.setup = nil
        plugin_spec.config = nil
      end
    end
  end

  -- Run the setups of the members `from` .. `upto`.
  --
  -- The setups run in the order the plugins were listed, so a plugin that
  -- depends on an earlier one still sees it set up. Each member is set up
  -- by exactly one call: the callers split the members into disjoint
  -- ranges. Running 1..upto twice set every member up twice.
  ---@param member_loaded boolean[] which members were already loaded
  ---@param from integer the first member to set up
  ---@param upto integer the last member to set up
  local function run_setups(member_loaded, from, upto)
    for pi = from, upto do
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
  end

  -- Set the members `from` .. #parsed_names up once every build is done.
  --
  -- The setup of a plugin whose build is still running is deferred: the
  -- build finishes in the background, and the setup runs when it is done.
  -- The editor is never blocked by a build it did not ask for.
  --
  -- Every deferred build is waited for, not only the last one: builds
  -- finish in any order, and waiting for the last one alone set up a
  -- member whose own build was still running.
  ---@param deferred integer[] the indexes of the members whose build is running
  ---@param member_loaded boolean[] which members were already loaded
  ---@param from integer the first member still to set up
  local function defer_setups_until_build(deferred, member_loaded, from)
    local token = {}
    deferred_setups = token
    local remaining = #deferred

    local function settled()
      -- A failed build is set up anyway -- the setup may still work. The
      -- failure is reported by the build itself; reporting it here as well
      -- showed the same "Build failed" twice.
      remaining = remaining - 1
      if remaining > 0 or deferred_setups ~= token then return end
      -- The setups run on the main loop: the build callback may fire from
      -- a fast context. deferred_setups stays set until they have run --
      -- a build that had already settled calls back synchronously, and
      -- clearing it here would let load_now release the closures first.
      schedule(function()
        if deferred_setups ~= token then return end
        deferred_setups = nil
        run_setups(member_loaded, from, #parsed_names)
        release_setups()
      end)
    end

    for i = 1, #deferred do
      builds.on_complete(parsed_names[deferred[i]], settled)
    end
  end

  -- Call setup once per member that was not already loaded.
  --
  -- The setup must not run while a build is still going: the plugin's
  -- tree is incomplete, and a setup that expects the build's output
  -- fails against a half-built tree. markdown-preview2.nvim is the
  -- clear case -- its setup starts a node server that needs
  -- node_modules, and without them the server dies.
  --
  -- How long the setup waits depends on how the plugin was loaded:
  --
  --   - an explicit user action (a command or a keymap) waits for the
  --     build, because the user asked for the plugin and wants it now.
  --     The wait pumps the event loop, so the editor stays responsive.
  --
  --   - an automatic load (an event, a filetype, an eager load) does
  --     not wait. A plugin with a 60-second build would freeze the
  --     editor on startup. The setup is deferred until the build is
  --     done instead, and the editor carries on.
  --
  -- The trigger that fired decides, not the triggers the spec has. The
  -- check used to be "the spec has cmd or keys", so a spec with `event` and
  -- `keys` blocked the editor when its event loaded it, and `lazy = false`
  -- with `keys` blocked at startup -- with nobody waiting for the plugin.
  ---@param member_loaded boolean[] which members were already loaded
  ---@param building table<integer, true> the indexes of the building members
  ---@param user_initiated boolean whether a command or a keymap started the load
  local function setup_members(member_loaded, building, user_initiated)
    -- The members waiting for a build, and the first of them.
    --
    -- The setups run in the order the plugins were listed, so a plugin
    -- that depends on an earlier one still sees it set up. Everything
    -- before the first building member is set up now; everything from it
    -- on waits, ready members included, so the order is kept. The two
    -- ranges are disjoint: no member is set up twice.
    local deferred = {}
    for pi = 1, #parsed_names do
      if building[pi] then deferred[#deferred + 1] = pi end
    end
    local first_deferred = deferred[1] or (#parsed_names + 1)

    run_setups(member_loaded, 1, first_deferred - 1)

    if #deferred > 0 then
      if user_initiated then
        -- The user asked for this plugin, so the setup waits for the
        -- build. The wait is bounded: if the build takes too long, the
        -- setup is deferred instead, and the build carries on in the
        -- background.
        --
        -- A build that failed is not a build that is still running. The
        -- wait reports both the same way -- it did not succeed -- but
        -- they mean different things: a failed build is over, and the
        -- plugin has to be set up now.
        local still_building = nil
        for i = 1, #deferred do
          local name = parsed_names[deferred[i]]
          local ok = builds.wait(name, BUILD_WAIT_MS)
          if not ok then
            local status = builds.status(name)
            if not (status and status.state == 'failed') then
              still_building = name
              break
            end
          end
        end
        if not still_building then
          run_setups(member_loaded, first_deferred, #parsed_names)
        else
          -- The build is taking too long. The setup is deferred, and the
          -- user is told why.
          defer_setups_until_build(deferred, member_loaded, first_deferred)
          utils.notify('Still building ' .. still_building ..
            ' -- the plugin will be set up when the build finishes',
            vim_log_levels.WARN)
        end
      else
        -- An automatic load does not wait. The setup runs when the build
        -- is done.
        defer_setups_until_build(deferred, member_loaded, first_deferred)
      end
    end

    -- The setup closures have run, so nothing needs them any more.
    --
    -- They are the only part of the spec that holds onto the user's
    -- state: everything the closure captured stays reachable through it.
    -- The load_now closure keeps the spec alive for the whole session,
    -- so a setup that captured a large table would keep that table alive
    -- too. Clearing the references here lets it be collected.
    --
    -- A deferred setup has not run yet, so its closure is still needed.
    -- It is cleared when the deferred setup runs instead.
    if not deferred_setups then
      release_setups()
    end
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

    -- A command or a keymap started this load: the user is waiting for the
    -- plugin. The path carries it down to the dependencies, which are loaded
    -- on the same user's behalf -- the parent's setup runs right after
    -- theirs and usually needs them set up.
    if ev == triggers.USER_ACTION then visiting_path._user_action = true end
    local user_initiated = visiting_path._user_action == true

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

    -- The groups on the trigger event before anything of this spec loads,
    -- so the replay can tell the plugin's own handlers from the ones that
    -- already ran. Taken before the dependencies load: their handlers have
    -- not seen the event either.
    local snap
    if ev and type(ev) == 'table' and ev.event and not state.replay_done then
      snap = replay.snapshot(ev.event)
    end

    -- Abort the load when an install fails. The plugin is left unloaded so a
    -- later attempt can try again, and the error is reported: a silent
    -- failure leaves a plugin that never loads and never loads again.
    local function fail_install(message)
      -- `state` is the first member's. It was already loaded before this
      -- call -- another spec loaded it -- then it stays loaded: the failure
      -- belongs to the other members.
      if not member_loaded[1] then
        state.loaded = false
      end
      leave_path(visiting_path, path_order, current_name)
      utils.notify(message, vim_log_levels.ERROR)
      return false
    end

    if current_name then
      visiting_path[current_name] = true
      path_order[#path_order + 1] = current_name
    end

    local dep_err = load_dependencies(parsed_deps, visiting_path)
    if dep_err then return fail_install(dep_err) end

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

    -- The command stubs own the command names, so they have to go before
    -- the plugin is loaded at all. A plugin may define its command when
    -- its module is required (:packadd), or when its setup() runs -- and
    -- either way nvim_create_user_command() fails while the stub holds
    -- the name. The command would then be gone once the stub was torn
    -- down.
    run_teardown(trigger_teardown_before_setup)

    for i = 1, #parsed_names do
      pcall(nvim_cmd, { cmd = 'packadd', args = { parsed_names[i] } })
    end

    setup_members(member_loaded, start_builds(parsed_names), user_initiated)

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
    run_teardown(trigger_teardown)

    leave_path(visiting_path, path_order, current_name)

    local duration = (hrtime() - start_ms) / 1e6
    for i = 1, #parsed_names do
      registry.load_times[parsed_names[i]] = duration
    end

    if snap then
      state.replay_done = true
      -- The retained spec is a copy, so the replay flag is set on it.
      -- get_replay_info reads the copy; the user's own table is not
      -- touched.
      local retained = specs[current_name]
      if retained then retained._replay_done = true end
      replay.after_load(ev, snap)
    end

    return true
  end

  -- Store force_load for ALL plugins in the group (so dependency resolution works for any of them)
  for i = 1, #parsed_names do
    force_load_fns[parsed_names[i]] = load_now
  end

  -- Register the triggers in a group named after the plugin, so the replay
  -- can address them individually and exclude the ones that already ran.
  --
  -- register_all returns two lists: the command stubs, which have to go
  -- before the plugin is loaded, and everything else, which is torn down
  -- once it has loaded.
  trigger_teardown_before_setup, trigger_teardown =
    triggers.register_all(config, load_now, triggers.trigger_group(group_name), group_name)

  -- The spec's startup event is over, so it loads now instead of never. On
  -- the next tick, as at startup: load() returns before anything loads, and
  -- a list of specs is registered as a whole first. Should the event still
  -- reach the trigger after all -- load() called from inside a VimEnter
  -- callback -- the second load finds the plugin loaded and does nothing.
  --
  -- The check against force_load_fns drops a callback whose spec was reset
  -- or registered again in the meantime.
  if startup_trigger_passed(config) then
    schedule(function()
      if force_load_fns[current_name] == load_now then load_now(nil) end
    end)
  end
end

---@return table<string, {name:string, deps:string[], trigger:string, loaded:boolean, disabled:boolean}>, table<string, string[]>
function M.get_dag_data()
  local scanner = package.loaded['resonance.scanner'] or require('resonance.scanner')
  local scanner_info = scanner.get_info()
  return get_dag().get_dag_data(M.specs, plugin_state, scanner_info, disabled_plugins)
end

---@return table<string, {event:string, chain:string[], replayed:boolean}>
function M.get_replay_info()
  return get_dag().get_replay_info(M.specs, M.plugin_triggers)
end

function M._get_event_chain_internal(event, buf, data)
  return get_dag()._get_event_chain_internal(event, buf, data)
end

return M
