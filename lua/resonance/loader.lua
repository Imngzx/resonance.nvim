local M = {}
local utils = require('resonance.utils')

M.build_hooks = {}

-- 🛠️ 底层 PackChanged 监听器：拦截安装/更新事件并自动 Build
vim.api.nvim_create_autocmd('PackChanged', {
  group = vim.api.nvim_create_augroup('ResonanceBuilder', { clear = true }),
  callback = function(args)
    local data = args.data
    if not data or (data.kind ~= 'install' and data.kind ~= 'update') then return end

    local name = (data.spec and data.spec.name) or data.name or args.match
    local build_task = M.build_hooks[name]
    if not build_task then return end

    local dir = (data.spec and data.spec.dir) or data.dir
    if not dir or dir == '' then
      local found = vim.api.nvim_get_runtime_file('pack/*/*/' .. name, false)
      if #found > 0 then dir = found[1] end
    end

    if not dir or dir == '' then
      vim.notify('[Resonance] Build failed: Cannot resolve directory for ' .. name,
        vim.log.levels.ERROR)
      return
    end

    utils.notify('[Resonance] Building ' .. name .. '...', vim.log.levels.INFO)

    if type(build_task) == 'string' then
      local shell = utils.is_windows() and 'cmd' or 'sh'
      local flag = utils.is_windows() and '/c' or '-c'

      vim.system({ shell, flag, build_task }, { cwd = dir, text = true }, function(out)
        vim.schedule(function()
          if out.code == 0 then
            utils.notify('[Resonance] Build success: ' .. name, vim.log.levels.INFO)
          else
            utils.notify('[Resonance] Build failed: ' .. name .. '\n' .. (out.stderr or ''),
              vim.log.levels
              .ERROR)
          end
        end)
      end)
    elseif type(build_task) == 'function' then
      vim.schedule(function()
        local ok, err = pcall(build_task, dir)
        if ok then
          utils.notify('[Resonance] Build function executed: ' .. name, vim.log.levels.INFO)
        else
          utils.notify('[Resonance] Build failed: ' .. name .. '\n' .. tostring(err),
            vim.log.levels.ERROR)
        end
      end)
    end
  end,
})

-- 核心加载触发逻辑
function M.load(config)
  local plugins = config.plugin
  if type(plugins) == 'string' then plugins = { plugins } end
  plugins = plugins or {}

  -- 注册 Build Hook
  if config.build then
    for _, plugin in ipairs(plugins) do
      local target_url = type(plugin) == 'string' and plugin or
        (plugin.src or plugin.url or plugin[1])
      local name = (type(plugin) == 'table' and plugin.name) or
        (target_url and vim.fn.fnamemodify(target_url, ':t'):gsub('%.git$', ''))
      if name then M.build_hooks[name] = config.build end
    end
  end

  local loaded = false
  local function load_now()
    if loaded then return end
    loaded = true

    -- 开始毫秒级计时
    local start_ms = vim.uv.hrtime()

    if #plugins > 0 then vim.pack.add(plugins) end
    if config.setup then config.setup() end

    -- 结算耗时
    local end_ms = vim.uv.hrtime()
    local duration = (end_ms - start_ms) / 1e6

    -- 将耗时存入 scanner，供 UI 读取
    for _, plugin in ipairs(plugins) do
      local target_url = type(plugin) == 'string' and plugin or
        (plugin.src or plugin.url or plugin[1])
      local name = (type(plugin) == 'table' and plugin.name) or
        (target_url and vim.fn.fnamemodify(target_url, ':t'):gsub('%.git$', ''))
      if name then
        require('resonance.scanner').load_times[name] = duration
      end
    end
  end

  -- Event 触发
  if config.event then
    local ev = type(config.event) == 'string' and { config.event } or config.event
    local event_name = ev[1]
    local pattern = ev[2] or ev.pattern
    local opts = { once = true, callback = load_now }
    if event_name == 'User' and pattern then opts.pattern = pattern end
    vim.api.nvim_create_autocmd(event_name == 'User' and 'User' or ev, opts)
  end

  -- Cmd 触发
  if config.cmd then
    local cmds = type(config.cmd) == 'string' and { config.cmd } or config.cmd
    for _, cmd in ipairs(cmds) do
      vim.api.nvim_create_user_command(cmd, function(args)
        vim.api.nvim_del_user_command(cmd)
        load_now()
        local cmd_opts = { cmd = cmd, args = args.fargs, bang = args.bang }

        if args.range == 1 then
          cmd_opts.range = { args.line1 }
        elseif args.range == 2 then
          cmd_opts.range = { args.line1, args.line2 }
        elseif args.count and args.count >= 0 then
          cmd_opts.count = args.count
        end

        vim.cmd(cmd_opts)
      end, { nargs = '*', bang = true, range = true, complete = 'file' })
    end
  end

  -- Key 触发
  if config.keys then
    for _, key_cfg in ipairs(config.keys) do
      local mode = key_cfg[1] or key_cfg.mode or 'n'
      local lhs = key_cfg[2] or key_cfg.lhs
      local rhs = key_cfg[3] or key_cfg.rhs
      local opts = key_cfg[4] or key_cfg.opts or {}

      if lhs then
        vim.keymap.set(mode, lhs, function()
          vim.keymap.del(mode, lhs)
          load_now()
          if rhs then
            if type(rhs) == 'function' then
              rhs()
            elseif type(rhs) == 'string' then
              local k = vim.api.nvim_replace_termcodes(rhs, true, false, true)
              vim.api.nvim_feedkeys(k, 'm', false)
            end
            if config.restore_keys ~= false then vim.keymap.set(mode, lhs, rhs, opts) end
          else
            local k = vim.api.nvim_replace_termcodes(lhs, true, false, true)
            vim.api.nvim_feedkeys(k, 'i', false)
          end
        end, opts)
      end
    end
  end

  -- FileType 触发
  if config.ft then
    local fts = type(config.ft) == 'string' and { config.ft } or config.ft
    vim.api.nvim_create_autocmd('FileType', { pattern = fts, once = true, callback = load_now })
  end
end

return M
