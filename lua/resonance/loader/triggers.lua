local M = {}
local utils = require('resonance.utils')

local api = vim.api
local create_autocmd = api.nvim_create_autocmd
local create_user_command = api.nvim_create_user_command
local del_user_command = api.nvim_del_user_command
local nvim_cmd = api.nvim_cmd
local set_keymap = vim.keymap.set
local del_keymap = vim.keymap.del
local replace_termcodes = api.nvim_replace_termcodes
local feedkeys = api.nvim_feedkeys
local parse_cmd = api.nvim_parse_cmd

local type = type
local pcall = pcall
local tostring = tostring

local vim_log_levels = vim.log.levels

-- Register event trigger autocmds
---@param config table
---@param load_now function
function M.register_event(config, load_now)
  if not config.event then return end

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

-- Register command trigger user commands
---@param config table
---@param load_now function
function M.register_cmd(config, load_now)
  if not config.cmd then return end

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

-- Register keymap trigger keymaps
---@param config table
---@param load_now function
function M.register_keys(config, load_now)
  if not config.keys then return end

  for k = 1, #config.keys do
    local key_cfg = config.keys[k]
    local mode = key_cfg[1] or key_cfg.mode or 'n'
    local lhs = key_cfg[2] or key_cfg.lhs
    local rhs = key_cfg[3] or key_cfg.rhs
    local opts = key_cfg[4] or key_cfg.opts or {}

    if lhs then
      -- Preserve original opts for restoration (including buffer-local info)
      local restore_opts = vim.tbl_extend('keep', {}, opts)
      local is_buffer = opts.buffer ~= nil or opts.buf ~= nil
      local target_buf = opts.buf or opts.buffer

      set_keymap(mode, lhs, function()
        local del_opts = is_buffer and { buf = target_buf } or {}

        pcall(del_keymap, mode, lhs, del_opts)
        load_now(nil)

        if rhs then
          if type(rhs) == 'function' then
            rhs()
          elseif type(rhs) == 'string' then
            local term_key = replace_termcodes(rhs, true, false, true)
            feedkeys(term_key, 'm', false)
          end
          if config.restore_keys ~= false then set_keymap(mode, lhs, rhs, restore_opts) end
        else
          local term_key = replace_termcodes(lhs, true, false, true)
          feedkeys(term_key, 'i', false)
        end
      end, opts)
    end
  end
end

-- Register filetype trigger autocmds
---@param config table
---@param load_now function
function M.register_ft(config, load_now)
  if not config.ft then return end

  local fts = type(config.ft) == 'string' and { config.ft } or config.ft
  create_autocmd('FileType', { pattern = fts, once = true, callback = load_now })
end

-- Register all triggers
---@param config table
---@param load_now function
function M.register_all(config, load_now)
  M.register_event(config, load_now)
  M.register_cmd(config, load_now)
  M.register_keys(config, load_now)
  M.register_ft(config, load_now)
end

return M