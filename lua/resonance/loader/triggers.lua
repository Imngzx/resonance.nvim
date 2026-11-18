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
local get_keymap = api.nvim_get_keymap
local buf_get_keymap = api.nvim_buf_get_keymap

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
---@param before_setup? function[] list the removal callback is added to, for
---   stubs that must go before the plugin's setup runs
---@return function[] teardown callbacks that remove the registered commands
function M.register_cmd(config, load_now, before_setup)
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

      -- The stub owns the command name, so it has to go before the
      -- plugin's setup runs -- otherwise the plugin's own
      -- nvim_create_user_command() for that name fails.
      local remove = function()
        pcall(del_user_command, cmd)
      end
      if before_setup then
        before_setup[#before_setup + 1] = remove
      else
        teardown[#teardown + 1] = remove
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
      --
      -- A buffer of false means the mapping is global, so it is not a
      -- buffer-local mapping at all. Treating it as one would make the
      -- lookup below ask for the keymap of a buffer that does not exist.
      local target_buf = opts.buf or opts.buffer
      if target_buf == true or target_buf == 0 then
        -- A buffer of 0 means the current buffer as well. It has to be
        -- resolved to an id here: the mapping is set against the buffer
        -- that is current now, so the teardown has to delete from that
        -- same buffer and not from whatever is current later.
        target_buf = api.nvim_get_current_buf()
        -- The resolved id has to go back into the options, so the keymap is
        -- set and deleted against the same buffer.
        if opts.buffer ~= nil then
          opts = vim.tbl_extend('force', {}, opts, { buffer = target_buf })
          restore_opts = vim.tbl_extend('force', {}, restore_opts, { buffer = target_buf })
        else
          opts = vim.tbl_extend('force', {}, opts, { buf = target_buf })
          restore_opts = vim.tbl_extend('force', {}, restore_opts, { buf = target_buf })
        end
      end
      local is_buffer = type(target_buf) == 'number'

      -- Put the real mapping back in place, and drop the loading stub.
      --
      -- The keymap is not a stub to discard once the plugin has loaded: it
      -- is the binding the user asked for. Only the part of it that loaded
      -- the plugin was temporary. So the stub is replaced by the real
      -- mapping, whether the keymap itself fired or some other trigger
      -- loaded the plugin first.
      --
      -- The delete has to be conditional. A key shorthand without an rhs
      -- means "the plugin defines this mapping itself", so by the time the
      -- teardown runs the plugin has already installed its own mapping and
      -- an unconditional delete would take the user's shortcut with it.
      -- The stub is only removed while it is still the stub: the installed
      -- mapping is looked up and its callback compared against the stub.
      local stub_callback

      -- The modes the mapping was installed for. A mode list is expanded
      -- here because the lookup below has to walk the modes one by one.
      local modes = type(mode) == 'table' and mode or { mode }

      -- True while the installed mapping is still the loading stub.
      --
      -- The callback is the identity of the stub, so the comparison does
      -- not depend on how the lhs is spelled. That matters: the keymap
      -- API reports an lhs in its own notation, so '<C-x>' comes back as
      -- '<C-X>' and '<Space>' as a plain space. Comparing the callback
      -- sidesteps the notation entirely.
      local function stub_is_installed()
        if not stub_callback then return false end
        for i = 1, #modes do
          local maps = is_buffer and buf_get_keymap(target_buf, modes[i]) or get_keymap(modes[i])
          for m = 1, #maps do
            if maps[m].callback == stub_callback then return true end
          end
        end
        return false
      end

      local function restore_keymap()
        -- Only the stub may be deleted. If the plugin already took the
        -- mapping over, it owns it now and has to be left alone.
        if not stub_is_installed() then return end

        local del_opts = is_buffer and { buf = target_buf } or {}
        pcall(del_keymap, mode, lhs, del_opts)
        if rhs and config.restore_keys ~= false then
          set_keymap(mode, lhs, rhs, restore_opts)
        end
      end

      stub_callback = function()
        pcall(del_keymap, mode, lhs, is_buffer and { buf = target_buf } or {})

        -- The plugin may already be loaded -- another trigger of the same
        -- spec may have loaded it first. load_now returns without loading
        -- anything in that case, and the mapping still has to be restored.
        load_now(nil)

        if rhs then
          if type(rhs) == 'function' then
            rhs()
          elseif type(rhs) == 'string' then
            local term_key = replace_termcodes(rhs, true, false, true)
            -- The keys must be remapped only when the mapping was set up
            -- for remapping. vim.keymap.set defaults to noremap, and
            -- { remap = true } is its inverse, so the feed mode follows
            -- the same rule: 'n' for noremap, 'm' for remap.
            local feed_mode = (opts.remap == true or opts.noremap == false) and 'm' or 'n'
            feedkeys(term_key, feed_mode, false)
          end
          if config.restore_keys ~= false then set_keymap(mode, lhs, rhs, restore_opts) end
        else
          local term_key = replace_termcodes(lhs, true, false, true)
          feedkeys(term_key, 'i', false)
        end
      end

      set_keymap(mode, lhs, stub_callback, opts)

      teardown[#teardown + 1] = restore_keymap
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
---@return function[] before_setup teardown callbacks that must run before the
---   plugin's setup, because they hold a name the plugin wants to define
---@return function[] teardown callbacks that remove every registered trigger
function M.register_all(config, load_now, group)
  local before_setup = {}
  local teardown = {}

  local function collect(list)
    for i = 1, #list do
      teardown[#teardown + 1] = list[i]
    end
  end

  -- The command stubs have to go before the plugin's setup runs. A stub is
  -- a real user command, so it owns the name: the plugin's own
  -- nvim_create_user_command() for that name would fail, and the command
  -- would be gone once the stub was torn down.
  collect(M.register_cmd(config, load_now, before_setup))

  collect(M.register_event(config, load_now, group))
  collect(M.register_keys(config, load_now))
  collect(M.register_ft(config, load_now, group))

  return before_setup, teardown
end

return M
