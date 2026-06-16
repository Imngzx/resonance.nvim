---@diagnostic disable: undefined-field
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

local type = type
local tostring = tostring
local ipairs = ipairs
local pcall = pcall
local string_match = string.match
local table_concat = table.concat
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

  local fast_path = core_opt_base .. name
  if fs_stat(fast_path) then
    _plugin_dir_cache[name] = fast_path
    return fast_path
  end

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
        for _, v in ipairs(config.event) do
          if type(v) == 'string' then evs[#evs + 1] = v end
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
      for _, k in ipairs(config.keys) do
        local val = k[2] or k.lhs
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

local function get_event_chain(event, buf, data)
  local chain = {}
  local event_triggers = { FileType = 'BufReadPost', BufReadPost = 'BufReadPre' }
  while event do
    local groups = {}
    if event ~= 'FileType' then
      for _, autocmd in ipairs(get_autocmds({ event = event })) do
        if autocmd.group_name then groups[autocmd.group_name] = true end
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
    for _, spec in ipairs(config) do
      if type(spec) == 'table' then
        M.load(spec)
      end
    end
    return
  end

  config.plugin = config.plugin or config[1] or config.url
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
  local trig_str = parse_trigger(config)
  local parsed_names = {}
  local parsed_deps = {}

  if config.dependencies then
    local deps = type(config.dependencies) == 'table' and config.dependencies or
      { config.dependencies }
    for _, dep in ipairs(deps) do
      local target_url = type(dep) == 'string' and dep or (dep.src or dep.url or dep[1])
      local dep_name = (type(dep) == 'table' and dep.name) or
        (target_url and (string_match(target_url, '([^/]+)%.git$') or string_match(target_url, '([^/]+)$')))
      if dep_name then
        parsed_deps[#parsed_deps + 1] = { name = dep_name, raw = dep }
      end
    end
  end

  for _, plugin in ipairs(plugins) do
    local target_url = type(plugin) == 'string' and plugin or (plugin.src or plugin.url or plugin[1])
    local name = (type(plugin) == 'table' and plugin.name) or
      (target_url and (string_match(target_url, '([^/]+)%.git$') or string_match(target_url, '([^/]+)$')))

    if name and trig_str then M.plugin_triggers[name] = trig_str end

    if name then
      parsed_names[#parsed_names + 1] = name
      M.specs[name] = config
    end

    local specific_build = type(plugin) == 'table' and plugin.build
    local build_cmd = specific_build or config.build

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

  local function load_now(ev)
    if config._loaded then return end
    config._loaded = true

    for i = 1, #parsed_deps do
      local dep = parsed_deps[i]
      if M.specs[dep.name] then
        if not M.specs[dep.name]._loaded then
          M.specs[dep.name]._force_load()
        end
      else
        pcall(pack_add, { dep.raw }, { confirm = false, load = false })
        pcall(function() vim.cmd('packadd ' .. dep.name) end)
      end
    end

    local start_ms = hrtime()

    if #plugins > 0 then
      pcall(pack_add, plugins, { confirm = false, load = false })
    end

    for i = 1, #parsed_names do
      pcall(function() vim.cmd('packadd ' .. parsed_names[i]) end)
    end

    if config.setup then
      local ok, err = pcall(config.setup)
      if not ok then utils.notify('Setup error: ' .. tostring(err), vim_log_levels.ERROR) end
    end

    local duration = (hrtime() - start_ms) / 1e6
    local scanner = package.loaded['resonance.scanner']
    if not scanner then scanner = require('resonance.scanner') end

    for i = 1, #parsed_names do
      scanner.load_times[parsed_names[i]] = duration
    end

    if ev and type(ev) == 'table' and ev.event and not config._replay_done then
      config._replay_done = true
      local chain = ev.event ~= 'User' and get_event_chain(ev.event, ev.buf, ev.data) or {}
      for _, opts in ipairs(chain) do
        if next(opts.exclude) == nil then
          exec_autocmds(opts.event, { buf = opts.buf, modeline = false, data = opts.data })
        else
          local done = {}
          for _, autocmd in ipairs(get_autocmds({ event = opts.event })) do
            local id = autocmd.event .. ':' .. tostring(autocmd.group or '')
            if autocmd.group and not done[id] and not opts.exclude[autocmd.group_name] then
              done[id] = true
              exec_autocmds(opts.event,
                { buf = opts.buf, group = autocmd.group_name, modeline = false, data = opts.data })
            end
          end
        end
      end
    end
  end

  config._force_load = load_now

  if config.event then
    local ev = type(config.event) == 'string' and { config.event } or config.event
    local event_name = ev[1]
    local pattern = ev[2] or ev.pattern
    local opts = { once = true, callback = load_now }
    if event_name == 'User' and pattern then opts.pattern = pattern end
    create_autocmd(event_name == 'User' and 'User' or ev, opts)
  end

  if config.cmd then
    local cmds = type(config.cmd) == 'string' and { config.cmd } or config.cmd
    for _, cmd in ipairs(cmds) do
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
        local ok, err = pcall(nvim_cmd, cmd_opts, {})
        if not ok then
          require('resonance.utils').notify('Execution failed: ' .. tostring(err),
            vim.log.levels.ERROR)
        end
      end, { nargs = '*', bang = true, range = true, complete = 'file' })
    end
  end

  if config.keys then
    for _, key_cfg in ipairs(config.keys) do
      local mode = key_cfg[1] or key_cfg.mode or 'n'
      local lhs = key_cfg[2] or key_cfg.lhs
      local rhs = key_cfg[3] or key_cfg.rhs
      local opts = key_cfg[4] or key_cfg.opts or {}

      if lhs then
        set_keymap(mode, lhs, function()
          local target_buf = opts.buf or opts.buffer
          local del_opts = target_buf and { buf = target_buf } or {}
          if opts.buffer then
            opts.buf = opts.buffer; opts.buffer = nil
          end

          pcall(del_keymap, mode, lhs, del_opts)
          load_now(nil)

          if rhs then
            if type(rhs) == 'function' then
              rhs()
            elseif type(rhs) == 'string' then
              local k = replace_termcodes(rhs, true, false, true)
              feedkeys(k, 'm', false)
            end
            if config.restore_keys ~= false then set_keymap(mode, lhs, rhs, opts) end
          else
            local k = replace_termcodes(lhs, true, false, true)
            feedkeys(k, 'i', false)
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
