local M = {}
local utils = require('resonance.utils')
local spec = require('resonance.loader.spec')
local triggers = require('resonance.loader.triggers')
local build = require('resonance.loader.build')
local dag = require('resonance.loader.dag')

local api = vim.api
local uv = vim.uv
local pack_add = vim.pack and vim.pack.add or nil
local function pack_add_safe(...)
  if pack_add then return pack_add(...) end
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

-- Internal plugin state (keyed by plugin name, not config table, to avoid memory leaks)
local plugin_state = {}

-- Force-load functions keyed by plugin name
local force_load_fns = {}
-- Plugins disabled by a false cond predicate
local disabled_plugins = {}


local _plugin_dir_cache = nil

local function populate_plugin_dir_cache()
  if _plugin_dir_cache then return end
  _plugin_dir_cache = {}

  if vim.pack and vim.pack.get then
    local packs = vim.pack.get(nil, { info = false, offline = true })
    for i = 1, #packs do
      local p = packs[i]
      if p.path and p.spec and p.spec.name then
        _plugin_dir_cache[p.spec.name] = p.path
      end
    end
    return
  end

  -- Fallback: filesystem scan
  local req = fs_scandir(pack_dir_base)
  if req then
    while true do
      local name, typ = fs_scandir_next(req)
      if not name then break end
      if typ == 'directory' then
        local sub = fs_scandir(pack_dir_base .. '/' .. name)
        if sub then
          while true do
            local pname, ptyp = fs_scandir_next(sub)
            if not pname then break end
            if ptyp == 'directory' then
              _plugin_dir_cache[pname] = pack_dir_base .. '/' .. name .. '/' .. pname
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

-- Public API: get_plugin_dir for build module
M.get_plugin_dir = get_plugin_dir

M.build_hooks = build.build_hooks
M.run_build = build.run_build
M.check_and_build = build.check_and_build
M.mark_build_success = build.mark_build_success
M.setup_packchanged_autocmd = build.setup_packchanged_autocmd
build.setup_packchanged_autocmd(get_plugin_dir)

M.plugin_triggers = {}
M.specs = {}
M.spec_urls = {} -- URL -> spec name mapping
M.disabled_plugins = disabled_plugins

-- Reset all internal state (for testing)
function M._reset()
  for k in pairs(plugin_state) do plugin_state[k] = nil end
  for k in pairs(force_load_fns) do force_load_fns[k] = nil end
  for k in pairs(disabled_plugins) do disabled_plugins[k] = nil end
  for k in pairs(M.specs) do M.specs[k] = nil end
  for k in pairs(M.plugin_triggers) do M.plugin_triggers[k] = nil end
  for k in pairs(M.spec_urls) do M.spec_urls[k] = nil end
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
    if name then M.specs[name] = config end
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

  -- Create a single load_now function that loads all plugins in the group
  -- This ensures force_load_fns works for dependency resolution for any plugin in the group
  local current_name = parsed_names[1]

  local function load_now(ev, visiting_path)
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
        return
      end
    end

    if all_loaded then return end
    state.loaded = true

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
        if fn then fn(nil, visiting_path) end
      else
        pcall(pack_add_safe, { dep.raw }, { confirm = false, load = false })
        pcall(nvim_cmd, { cmd = 'packadd', args = { dep.name } })
      end
    end

    local start_ms = hrtime()

    if #pack_plugins > 0 then
      pcall(pack_add_safe, pack_plugins, { confirm = false, load = false })
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
      config._replay_done = true
      local chain = ev.event ~= 'User' and dag._get_event_chain_internal(ev.event, ev.buf, ev.data) or
        {}
      for c = 1, #chain do
        local c_opts = chain[c]
        if next(c_opts.exclude) == nil then
          exec_autocmds(c_opts.event, { buf = c_opts.buf, modeline = false, data = c_opts.data })
        else
          local done = {}
          local autocmds = get_autocmds({ event = c_opts.event })
          for a = 1, #autocmds do
            local autocmd = autocmds[a]
            local id = autocmd.event .. ':' .. tostring(autocmd.group or '')
            -- Replay ungrouped autocmds (no group) and grouped ones not in exclude
            if not autocmd.group then
              if not c_opts.exclude[''] then
                exec_autocmds(c_opts.event,
                  { buf = c_opts.buf, modeline = false, data = c_opts.data })
              end
            elseif not done[id] and not c_opts.exclude[autocmd.group_name] then
              done[id] = true
              exec_autocmds(c_opts.event,
                { buf = c_opts.buf, group = autocmd.group_name, modeline = false, data = c_opts.data })
            end
          end
        end
      end
    end
  end

  -- Store force_load for ALL plugins in the group (so dependency resolution works for any of them)
  for i = 1, #parsed_names do
    force_load_fns[parsed_names[i]] = load_now
  end

  triggers.register_all(config, load_now)
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
