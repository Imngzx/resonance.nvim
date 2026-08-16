local M = {}
local utils = require('resonance.utils')

local spec = require('resonance.loader.spec')
local triggers = require('resonance.loader.triggers')
local build = require('resonance.loader.build')
local dag = require('resonance.loader.dag')

local api = vim.api
local uv = vim.uv
local schedule = vim.schedule
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

local pack_dir_base = utils.fast_normalize(fn_stdpath('data') .. '/site/pack')

-- Internal plugin state (separate from user config to avoid mutation)
local plugin_state = {}

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
  if not _plugin_dir_cache then
    populate_plugin_dir_cache()
  end
  return _plugin_dir_cache[name]
end

-- Public API: get_plugin_dir for build module
M.get_plugin_dir = get_plugin_dir

-- Expose build hooks and setup
M.build_hooks = build.build_hooks
M.run_build = build.run_build
build.setup_packchanged_autocmd(get_plugin_dir)

M.plugin_triggers = {}
M.specs = {}

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

  local parsed_config = spec.parse_config(config)
  if not parsed_config then return end
  config = parsed_config

  local plugins = config.plugin
  local parsed_deps = utils.parse_dependencies(config)
  local trig_str = utils.parse_trigger(config)
  local parsed_names, pack_plugins = spec.extract_names(plugins)

  for i = 1, #parsed_names do
    local name = parsed_names[i]
    if name and trig_str then M.plugin_triggers[name] = trig_str end
    if name then M.specs[name] = config end
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

  local function load_now(ev, visiting_path)
    local state = plugin_state[config]
    if not state then
      state = { loaded = false }
      plugin_state[config] = state
    end

    -- Initialize visiting_path if nil
    if not visiting_path then visiting_path = {} end

    -- Use ordered list for cycle detection to preserve path order
    local path_order = visiting_path._order
    if not path_order then
      path_order = {}
      visiting_path._order = path_order
    end
    local current_name = parsed_names[1]

    if current_name then
      if visiting_path[current_name] then
        -- Build cycle path in order
        local cycle = {}
        for _, n in ipairs(path_order) do
          cycle[#cycle + 1] = n
        end
        cycle[#cycle + 1] = current_name
        utils.notify(
          'Circular dependency detected: ' .. table_concat(cycle, ' -> ') .. ' (aborting)',
          vim_log_levels.ERROR
        )
        return
      end
      visiting_path[current_name] = true
      path_order[#path_order + 1] = current_name
    end

    if state.loaded then
      if current_name then
        visiting_path[current_name] = nil
        -- Remove from path_order (last element)
        if path_order[#path_order] == current_name then
          path_order[#path_order] = nil
        end
      end
      return
    end
    state.loaded = true

    for i = 1, #parsed_deps do
      local dep = parsed_deps[i]
      if M.specs[dep.name] then
        -- Always call _force_load to check visiting_path for cycles
        -- load_now will early-return if already loaded
        M.specs[dep.name]._force_load(nil, visiting_path)
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

    if config.setup then
      local ok, err = pcall(config.setup)
      if not ok then utils.notify('Setup error: ' .. tostring(err), vim_log_levels.ERROR) end
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
      local chain = ev.event ~= 'User' and dag._get_event_chain_internal(ev.event) or {}
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
            if autocmd.group and not done[id] and not c_opts.exclude[autocmd.group_name] then
              done[id] = true
              exec_autocmds(c_opts.event,
                { buf = c_opts.buf, group = autocmd.group_name, modeline = false, data = c_opts.data })
            end
          end
        end
      end
    end
  end

  config._force_load = function(ev, visiting_path)
    load_now(ev, visiting_path)
  end

  -- Register all triggers
  triggers.register_all(config, load_now)
end

---@return table<string, {name:string, deps:string[], trigger:string, loaded:boolean}>, table<string, string[]>
function M.get_dag_data()
  return dag.get_dag_data(M.specs, plugin_state)
end

---@return table<string, {event:string, chain:string[], replayed:boolean}>
function M.get_replay_info()
  return dag.get_replay_info(M.specs, M.plugin_triggers)
end

function M._get_event_chain_internal(event)
  return dag._get_event_chain_internal(event)
end

return M