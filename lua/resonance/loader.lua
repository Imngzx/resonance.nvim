local M = {}
local utils = require('resonance.utils')

local api = vim.api
local uv = vim.uv
local system = vim.system
local schedule = vim.schedule
local pack_add = vim.pack and vim.pack.add or nil

local create_autocmd = api.nvim_create_autocmd
local create_user_command = api.nvim_create_user_command
local del_user_command = api.nvim_del_user_command
local nvim_cmd = api.nvim_cmd
local set_keymap = vim.keymap.set
local del_keymap = vim.keymap.del
local replace_termcodes = api.nvim_replace_termcodes
local feedkeys = api.nvim_feedkeys
local parse_cmd = api.nvim_parse_cmd
local get_autocmds = api.nvim_get_autocmds
local exec_autocmds = api.nvim_exec_autocmds

local table_insert = table.insert
local next = next
local type = type
local tostring = tostring
local pcall = pcall
local string_match = string.match
local table_concat = table.concat

local fs_stat = uv.fs_stat
local fs_scandir = uv.fs_scandir
local fs_scandir_next = uv.fs_scandir_next
local fs_open = uv.fs_open
local fs_read = uv.fs_read
local fs_write = uv.fs_write
local fs_close = uv.fs_close
local fs_fstat = uv.fs_fstat
local hrtime = uv.hrtime

local fn_stdpath = vim.fn.stdpath
local vim_trim = vim.trim
local vim_log_levels = vim.log.levels

local SUB_DIRS = { 'opt', 'start' }
local pack_dir_base = utils.fast_normalize(fn_stdpath('data') .. '/site/pack')
local core_opt_base = pack_dir_base .. '/core/opt/'

M.build_hooks = {}
M.plugin_triggers = {}
M.specs = {}

local _plugin_dir_cache = nil

local function get_plugin_dir(name)
  if _plugin_dir_cache then
    if _plugin_dir_cache[name] then return _plugin_dir_cache[name] end
  else
    _plugin_dir_cache = {}
  end

  -- Fast path: check core/opt first (most plugins live here)
  local fast_path = core_opt_base .. name
  if fs_stat(fast_path) then
    _plugin_dir_cache[name] = fast_path
    return fast_path
  end

  -- Try vim.pack.get() for O(1) lookup (Neovim 0.13+)
  if vim.pack and vim.pack.get then
    local ok, packs = pcall(vim.pack.get, nil, { info = false, offline = true })
    if ok and type(packs) == 'table' then
      for i = 1, #packs do
        local p = packs[i]
        _plugin_dir_cache[p.spec.name] = p.path
      end
      if _plugin_dir_cache[name] then return _plugin_dir_cache[name] end
    end
  end

  -- Fallback: original filesystem scan (populates cache for all plugins)
  local req = fs_scandir(pack_dir_base)
  if req then
    while true do
      local group_name, f_type = fs_scandir_next(req)
      if not group_name then break end
      if f_type == 'directory' or f_type == 'link' then
        for i = 1, #SUB_DIRS do
          local target_dir = pack_dir_base .. '/' .. group_name .. '/' .. SUB_DIRS[i]
          local t_req = fs_scandir(target_dir)
          if t_req then
            while true do
              local p_name, p_type = fs_scandir_next(t_req)
              if not p_name then break end
              if p_type == 'directory' or p_type == 'link' then
                _plugin_dir_cache[p_name] = target_dir .. '/' .. p_name
              end
            end
          end
        end
      end
    end
  end
  return _plugin_dir_cache[name]
end

local function mark_build_success(dir, hash)
  local fd = fs_open(dir .. '/.resonance_built', 'w', 438)
  if fd then
    fs_write(fd, hash or 'done', 0)
    fs_close(fd)
  end
end

function M.run_build(name, dir, build_task, curr_hash)
  if not dir or dir == '' then return end
  utils.notify('[Resonance] Building ' .. name .. '...', vim_log_levels.INFO)

  if type(build_task) == 'string' then
    local shell = utils.is_windows() and 'cmd' or 'sh'
    local flag = utils.is_windows() and '/c' or '-c'
    system({ shell, flag, build_task }, { cwd = dir, text = true }, function(out)
      schedule(function()
        if out.code == 0 then
          mark_build_success(dir, curr_hash)
          utils.notify('[Resonance] Build success: ' .. name, vim_log_levels.INFO)
        else
          utils.notify('[Resonance] Build failed: ' .. name .. '\n' .. (out.stderr or ''),
            vim_log_levels.ERROR)
        end
      end)
    end)
  elseif type(build_task) == 'function' then
    schedule(function()
      local ok, err = pcall(build_task, dir)
      if ok then
        mark_build_success(dir, curr_hash)
        utils.notify('[Resonance] Build executed: ' .. name, vim_log_levels.INFO)
      else
        utils.notify('[Resonance] Build failed: ' .. name .. '\n' .. tostring(err),
          vim_log_levels.ERROR)
      end
    end)
  end
end

create_autocmd('PackChanged', {
  group = api.nvim_create_augroup('ResonanceBuilder', { clear = true }),
  callback = function(args)
    local data = args.data
    if not data or (data.kind ~= 'install' and data.kind ~= 'update') then return end

    local name = (data.spec and data.spec.name) or data.name or args.match
    local build_task = M.build_hooks[name]
    if not build_task then return end

    local dir = data.path or get_plugin_dir(name)
    if not dir then return end

    system({ 'git', 'rev-parse', 'HEAD' }, { cwd = dir, text = true }, function(obj)
      local curr_hash = (obj.code == 0 and obj.stdout) and vim_trim(obj.stdout) or 'done'
      schedule(function() M.run_build(name, dir, build_task, curr_hash) end)
    end)
  end,
})

local function parse_trigger(config)
  if config.event then
    if type(config.event) == 'table' then
      if config.event[1] == 'User' then
        return '󱐋 ' .. (config.event.pattern or config.event[2] or 'User')
      else
        local evs = {}
        for i = 1, #config.event do
          if type(config.event[i]) == 'string' then evs[#evs + 1] = config.event[i] end
        end
        return '󱐋 ' .. table_concat(evs, ', ')
      end
    end
    return '󱐋 ' .. tostring(config.event)
  elseif config.cmd then
    if type(config.cmd) == 'table' then
      return ' ' .. table_concat(config.cmd, ', ')
    end
    return ' ' .. tostring(config.cmd)
  elseif config.keys then
    if type(config.keys) == 'table' then
      local keys = {}
      for i = 1, #config.keys do
        local val = config.keys[i][2] or config.keys[i].lhs
        if val then keys[#keys + 1] = val end
      end
      if #keys > 0 then return ' ' .. table_concat(keys, ', ') end
    end
    return ' key'
  elseif config.ft then
    if type(config.ft) == 'table' then
      return ' ' .. table_concat(config.ft, ', ')
    end
    return ' ' .. tostring(config.ft)
  end
  return nil
end

local function normalize_pack_spec(plugin)
  if type(plugin) ~= 'table' then return plugin end

  local src = plugin.src or plugin.url or plugin[1]
  if not src then return plugin end

  return {
    src = src,
    name = plugin.name,
    version = plugin.version,
    data = plugin.data,
  }
end


local function get_event_chain(event, buf, data)
  local chain = {}
  local event_triggers = { FileType = 'BufReadPost', BufReadPost = 'BufReadPre' }
  while event do
    local groups = {}
    if event ~= 'FileType' then
      local autocmds = get_autocmds({ event = event })
      for i = 1, #autocmds do
        if autocmds[i].group_name then groups[autocmds[i].group_name] = true end
      end
    end
    table_insert(chain, 1, { event = event, buf = buf, exclude = groups, data = data })
    data = nil
    event = event_triggers[event]
  end
  return chain
end

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

  if not config.plugin and (config.src or config.url or type(config[1]) == 'string') then
    config.plugin = {
      src = config.src or config.url or config[1],
      name = config.name,
      version = config.version,
      data = config.data,
    }
  else
    config.plugin = config.plugin or config[1]
  end
  config.setup = config.setup or config.config

  local plugins = config.plugin
  if type(plugins) == 'string' then
    plugins = { plugins }
  elseif type(plugins) == 'table' then
    if plugins[1] == nil and (plugins.src or plugins.url or plugins.name) then
      plugins = { plugins }
    end
  end
  plugins = plugins or {}
  local pack_plugins = {}

  local trig_str = parse_trigger(config)
  local parsed_names = {}
  local parsed_deps = {}

  if config.dependencies then
    local deps = type(config.dependencies) == 'table' and config.dependencies or
      { config.dependencies }
    for i = 1, #deps do
      local dep = normalize_pack_spec(deps[i])
      local target_url = type(dep) == 'string' and dep or (dep.src or dep[1])
      local dep_name = (type(dep) == 'table' and dep.name) or
        (target_url and (string_match(target_url, '([^/]+)%.git$') or string_match(target_url, '([^/]+)$')))
      if dep_name then
        parsed_deps[#parsed_deps + 1] = { name = dep_name, raw = dep }
      end
    end
  end

  for p = 1, #plugins do
    local plugin = plugins[p]
    local pack_plugin = normalize_pack_spec(plugin)
    pack_plugins[p] = pack_plugin
    local target_url = type(pack_plugin) == 'string' and pack_plugin or (pack_plugin.src or pack_plugin[1])
    local name = (type(pack_plugin) == 'table' and pack_plugin.name) or
      (target_url and (string_match(target_url, '([^/]+)%.git$') or string_match(target_url, '([^/]+)$')))

    if name and trig_str then M.plugin_triggers[name] = trig_str end

    if name then
      parsed_names[#parsed_names + 1] = name
      M.specs[name] = config
    end

    local build_cmd = (type(plugin) == 'table' and plugin.build) or config.build

    if name and build_cmd then
      M.build_hooks[name] = build_cmd
      schedule(function()
        local dir = get_plugin_dir(name)
        if not dir then return end

        local last_hash = ''
        local fd = fs_open(dir .. '/.resonance_built', 'r', 438)
        if fd then
          local stat = fs_fstat(fd)
          if stat then last_hash = fs_read(fd, stat.size, 0) or '' end
          fs_close(fd)
        end

        system({ 'git', 'rev-parse', 'HEAD' }, { cwd = dir, text = true }, function(obj)
          local curr_hash = (obj.code == 0 and obj.stdout) and vim_trim(obj.stdout) or 'done'
          if last_hash ~= curr_hash then
            schedule(function() M.run_build(name, dir, build_cmd, curr_hash) end)
          end
        end)
      end)
    end
  end

  local function load_now(ev, visiting_path)
    if config._loaded then return end
    config._loaded = true

    visiting_path = visiting_path or {}
    local current_name = parsed_names[1]

    if current_name then
      if visiting_path[current_name] then
        require('resonance.utils').notify(
          'Circular dependency safely broken: ' .. current_name,
          vim_log_levels.WARN
        )
        return
      end
      visiting_path[current_name] = true
    end

    for i = 1, #parsed_deps do
      local dep = parsed_deps[i]
      if M.specs[dep.name] then
        if not M.specs[dep.name]._loaded then
          M.specs[dep.name]._force_load(nil, visiting_path)
        end
      else
        pcall(pack_add, { dep.raw }, { confirm = false, load = false })
        pcall(nvim_cmd, { cmd = 'packadd', args = { dep.name } })
      end
    end

    local start_ms = hrtime()

    if #pack_plugins > 0 then
      pcall(pack_add, pack_plugins, { confirm = false, load = false })
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
    end

    local duration = (hrtime() - start_ms) / 1e6
    local scanner = package.loaded['resonance.scanner'] or require('resonance.scanner')
    for i = 1, #parsed_names do
      scanner.load_times[parsed_names[i]] = duration
    end

    if ev and type(ev) == 'table' and ev.event and not config._replay_done then
      config._replay_done = true
      local chain = ev.event ~= 'User' and get_event_chain(ev.event, ev.buf, ev.data) or {}
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

  if config.event then
    local ev = type(config.event) == 'string' and { config.event } or config.event
    local event_name = ev[1]
    local opts = { once = true, callback = load_now }

    if event_name == 'User' then
      opts.pattern = ev[2] or ev.pattern
      create_autocmd('User', opts)
    else
      if ev.pattern then opts.pattern = ev.pattern end
      local events = {}
      for i = 1, #ev do
        if type(ev[i]) == 'string' then
          events[#events + 1] = ev[i]
        end
      end
      create_autocmd(events, opts)
    end
  end

  if config.cmd then
    local cmds = type(config.cmd) == 'string' and { config.cmd } or config.cmd
    for c = 1, #cmds do
      local cmd = cmds[c]
      create_user_command(cmd, function(args)
        del_user_command(cmd)
        load_now(nil)
        local cmd_opts = { cmd = cmd, args = args.fargs, bang = args.bang }
        if args.mods and args.mods ~= '' then
          cmd_opts.mods = parse_cmd(args.mods .. ' ' .. cmd, {}).mods
        end
        if args.range == 1 then
          cmd_opts.range = { args.line1 }
        elseif args.range == 2 then
          cmd_opts.range = { args.line1, args.line2 }
        elseif args.count and args.count >= 0 then
          cmd_opts.count = args.count
        end
        local ok, err = pcall(nvim_cmd, cmd_opts)
        if not ok then
          utils.notify('Execution failed: ' .. tostring(err), vim_log_levels.ERROR)
        end
      end, { nargs = '*', bang = true, range = true, complete = 'file' })
    end
  end

  if config.keys then
    for k = 1, #config.keys do
      local key_cfg = config.keys[k]
      local mode = key_cfg[1] or key_cfg.mode or 'n'
      local lhs = key_cfg[2] or key_cfg.lhs
      local rhs = key_cfg[3] or key_cfg.rhs
      local opts = key_cfg[4] or key_cfg.opts or {}

      if lhs then
        set_keymap(mode, lhs, function()
          local target_buf = opts.buf or opts.buffer
          local del_opts = target_buf and { buf = target_buf } or {}
          if opts.buffer then
            opts.buf = opts.buffer
            opts.buffer = nil
          end

          pcall(del_keymap, mode, lhs, del_opts)
          load_now(nil)

          if rhs then
            if type(rhs) == 'function' then
              rhs()
            elseif type(rhs) == 'string' then
              local term_key = replace_termcodes(rhs, true, false, true)
              feedkeys(term_key, 'm', false)
            end
            if config.restore_keys ~= false then set_keymap(mode, lhs, rhs, opts) end
          else
            local term_key = replace_termcodes(lhs, true, false, true)
            feedkeys(term_key, 'i', false)
          end
        end, opts)
      end
    end
  end

  if config.ft then
    local fts = type(config.ft) == 'string' and { config.ft } or config.ft
    create_autocmd('FileType', { pattern = fts, once = true, callback = load_now })
  end
end

return M