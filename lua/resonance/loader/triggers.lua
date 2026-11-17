local M = {}
local utils = require('resonance.utils')

local api = vim.api
local create_autocmd = api.nvim_create_autocmd
local create_augroup = api.nvim_create_augroup
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
local gsub = string.gsub

local vim_log_levels = vim.log.levels

-- Every trigger is registered in its own augroup. The replay selects
-- autocmds group by group, so an ungrouped trigger cannot be excluded from
-- a replay and cannot be replayed individually. Grouping makes the
-- exclusion set meaningful and keeps the triggers addressable.
--
-- The group name is derived from the plugin name so it stays stable across
-- registrations and unique per plugin.
local function trigger_group(name)
  return create_augroup(M.trigger_group_name(name), { clear = false })
end

-- The augroup name for a plugin. The loader needs the name as well as the
-- group handle: the replay addresses trigger groups by name, and the fired
-- state is tracked per group.
function M.trigger_group_name(name)
  local safe = gsub(tostring(name or 'plugin'), '[^%w_.-]', '_')
  return 'Resonance_' .. safe
end

M.trigger_group = trigger_group

-- Register event trigger autocmds
---@param config table
---@param load_now function
---@param group integer|nil augroup for the trigger autocmds
---@return function[] teardown callbacks that remove the registered triggers
function M.register_event(config, load_now, group)
  local teardown = {}
  if not config.event then return teardown end

  local events = utils.normalize_events(config.event)
  if #events == 0 then return teardown end

  -- A User event carries its own pattern, so it needs its own autocmd. The
  -- native event names in the list share one autocmd.
  local native = utils.native_event_names(events)
  if #native > 0 then
    local opts = { once = true, callback = load_now }
    if group then opts.group = group end
    local pattern
    for i = 1, #events do
      if not events[i].user and events[i].pattern then
        pattern = events[i].pattern
        break
      end
    end
    if pattern then opts.pattern = pattern end
    create_autocmd(native, opts)
  end

  for i = 1, #events do
    local e = events[i]
    if e.user then
      local opts = { once = true, callback = load_now }
      if group then opts.group = group end
      if e.pattern then opts.pattern = e.pattern end
      create_autocmd('User', opts)
    end
  end

  -- The whole trigger group goes away once the plugin is loaded: the
  -- sibling triggers of the same plugin are stubs that have done their
  -- job, and leaving them in place means they keep firing.
  if group then
    teardown[#teardown + 1] = function()
      pcall(api.nvim_del_augroup_by_id, group)
    end
  end

  return teardown
end

-- Register command trigger user commands
---@param config table
---@param load_now function
---@return function[] teardown callbacks that remove the registered commands
function M.register_cmd(config, load_now)
  local teardown = {}
  if not config.cmd then return teardown end

  local cmds = type(config.cmd) == 'string' and { config.cmd } or config.cmd
  for c = 1, #cmds do
    local cmd = cmds[c]
    -- A command spec can supply its own nargs/range/bang/complete. The
    -- defaults are permissive, but a command that expects exactly one
    -- argument would reject a valid invocation under a wildcard nargs.
    local cmd_opts = { nargs = '*', bang = true, range = true, complete = 'file' }
    if type(cmd) == 'table' then
      cmd_opts = vim.tbl_extend('force', cmd_opts, cmd.opts or {})
      cmd = cmd.name or cmd[1]
    end

    if cmd then
      create_user_command(cmd, function(args)
        del_user_command(cmd)
        load_now(nil)
        local run_opts = { cmd = cmd, args = args.fargs, bang = args.bang }
        if args.mods and args.mods ~= '' then
          run_opts.mods = parse_cmd(args.mods .. ' ' .. cmd, {}).mods
        end
        if args.range == 1 then
          run_opts.range = { args.line1 }
        elseif args.range == 2 then
          run_opts.range = { args.line1, args.line2 }
        elseif args.count and args.count >= 0 then
          run_opts.count = args.count
        end
        local ok, err = pcall(nvim_cmd, run_opts)
        if not ok then
          utils.notify('Execution failed: ' .. tostring(err), vim_log_levels.ERROR)
        end
      end, cmd_opts)

      teardown[#teardown + 1] = function()
        pcall(del_user_command, cmd)
      end
    end
  end
  return teardown
end

-- Register keymap trigger keymaps
---@param config table
---@param load_now function
---@return function[] teardown callbacks that remove the registered keymaps
function M.register_keys(config, load_now)
  local teardown = {}
  if not config.keys then return teardown end

  local keys = config.keys
  if type(keys) == 'function' then
    keys = keys()
  end
  for k = 1, #keys do
    local key_cfg = keys[k]
    local mode = key_cfg[1] or key_cfg.mode or 'n'
    local lhs = key_cfg[2] or key_cfg.lhs
    local rhs = key_cfg[3] or key_cfg.rhs
    local opts = key_cfg[4] or key_cfg.opts or {}

    if lhs then
      -- Preserve original opts for restoration (including buffer-local info)
      local restore_opts = vim.tbl_extend('keep', {}, opts)
      -- opts.buffer can be true, meaning "the current buffer". The delete
      -- API wants a buffer id, so true has to be resolved to one.
      local is_buffer = opts.buffer ~= nil or opts.buf ~= nil
      local target_buf = opts.buf or opts.buffer
      if target_buf == true then
        target_buf = api.nvim_get_current_buf()
        -- The resolved id has to go back into the options, so the keymap is
        -- set and deleted against the same buffer.
        opts = vim.tbl_extend('force', {}, opts, { buffer = target_buf })
        restore_opts = vim.tbl_extend('force', {}, restore_opts, { buffer = target_buf })
      end

      set_keymap(mode, lhs, function()
        local del_opts = is_buffer and { buf = target_buf } or {}

        pcall(del_keymap, mode, lhs, del_opts)
        load_now(nil)

        if rhs then
          if type(rhs) == 'function' then
            rhs()
          elseif type(rhs) == 'string' then
            local term_key = replace_termcodes(rhs, true, false, true)
            -- 'noremap' means the keys must not be remapped. The mode
            -- string is the first flag: 'n' for noremap, 'm' for remap.
            local feed_mode = opts.noremap and 'n' or 'm'
            feedkeys(term_key, feed_mode, false)
          end
          if config.restore_keys ~= false then set_keymap(mode, lhs, rhs, restore_opts) end
        else
          local term_key = replace_termcodes(lhs, true, false, true)
          feedkeys(term_key, 'i', false)
        end
      end, opts)

      teardown[#teardown + 1] = function()
        local del_opts = is_buffer and { buf = target_buf } or {}
        pcall(del_keymap, mode, lhs, del_opts)
      end
    end
  end
  return teardown
end

-- Register filetype trigger autocmds
---@param config table
---@param load_now function
---@param group integer|nil augroup for the trigger autocmds
---@return function[] teardown callbacks that remove the registered autocmds
function M.register_ft(config, load_now, group)
  local teardown = {}
  if not config.ft then return teardown end

  local fts = type(config.ft) == 'string' and { config.ft } or config.ft
  local opts = { pattern = fts, once = true, callback = load_now }
  if group then opts.group = group end
  create_autocmd('FileType', opts)
  return teardown
end

-- Register all triggers
---@param config table
---@param load_now function
---@param group integer|nil augroup for the trigger autocmds
---@return function[] teardown callbacks that remove every registered trigger
function M.register_all(config, load_now, group)
  local teardown = {}

  local function collect(list)
    for i = 1, #list do
      teardown[#teardown + 1] = list[i]
    end
  end

  collect(M.register_event(config, load_now, group))
  collect(M.register_cmd(config, load_now))
  collect(M.register_keys(config, load_now))
  collect(M.register_ft(config, load_now, group))

  return teardown
end

return M
