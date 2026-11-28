-- triggers
--
-- Part of the resonance.nvim behavioral suite. Split out of the former
-- behavior_spec.lua to keep each file focused.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_triggers_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local live = h.live
local with_capture = h.with_capture
local capture_and_wait = h.capture_and_wait
local noticed = h.noticed
local scratch_group = h.scratch_group
local recorder = h.recorder
local count = h.count
local make_git_repo = h.make_git_repo

-- The lhs Neovim stores for a <leader> mapping. <leader> expands to
-- g:mapleader at set time, and that is a backslash unless a config changed
-- it -- the isolated test env has no config, so it must not be assumed.
local function leader_lhs(rest)
  local leader = vim.g.mapleader
  if leader == nil or leader == '' then leader = '\\' end
  return leader .. rest
end

test.run_suite('resonance.behavior.triggers', {

  {
    name = 'triggers: a cmd trigger creates the command',
    fn = function()
      local l = live()
      _G.resonance.load({
        src = 'https://github.com/test/cmd-trigger',
        cmd = 'ResonanceTestCmd',
        setup = function() end,
      })

      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds['ResonanceTestCmd'])
    end,
  },

  {
    name = 'triggers: a cmd trigger runs the plugin setup when invoked',
    fn = function()
      test.stub_pack()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cmd-trigger-run',
        cmd = 'ResonanceTestCmdRun',
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceTestCmdRun', modeline = false })
      -- The command itself is what loads the plugin.
      vim.cmd('ResonanceTestCmdRun')
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  {
    name = 'triggers: firing one trigger tears down the sibling triggers',
    fn = function()
      -- Each trigger used to tear down only itself. A plugin with a cmd, a
      -- keymap and an event kept the other two alive as stubs after one
      -- of them fired, so the stale stubs still ran.
      test.stub_pack()
      local rhs = function() end
      _G.resonance.load({
        src = 'https://github.com/test/sibling-triggers',
        cmd = 'ResonanceSiblingCmd',
        keys = { { 'n', '<leader>Rs', rhs } },
        event = { 'User', pattern = 'ResonanceSiblingEvent' },
        setup = function() end,
      })

      -- The cmd fires, which loads the plugin.
      vim.cmd('ResonanceSiblingCmd')
      vim.wait(200)

      local cmds = api.nvim_get_commands({})
      test.assert_nil(cmds['ResonanceSiblingCmd'],
        'the command stub survived the load')

      -- Global maps are listed by nvim_get_keymap; buffer-local ones need
      -- nvim_buf_get_keymap. This keymap is global.
      --
      -- The keymap itself is not torn down: it is the binding the user
      -- asked for, and only the part of it that loaded the plugin was
      -- temporary. So the stub is replaced by the real mapping.
      --
      -- nvim_get_keymap reports the expanded lhs, so <leader>Rs comes
      -- back as ' Rs'.
      local maps = api.nvim_get_keymap('n')
      local found = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Rs') then found = maps[i] end
      end
      test.assert_not_nil(found, 'the keymap was removed instead of restored')
      test.assert_eq(found.callback, rhs,
        'the keymap is still the loading stub, not the real mapping')

      -- The event trigger is an autocmd in the plugin's trigger group.
      local group = 'Resonance_sibling-triggers'
      local pending = 0
      for _, a in ipairs(api.nvim_get_autocmds({ event = 'User' })) do
        if a.group_name == group then pending = pending + 1 end
      end
      test.assert_eq(pending, 0, 'the event trigger survived the load')
    end,
  },

  {
    name = 'triggers: an event trigger leaves the keymap working',
    fn = function()
      -- The keymap was torn down with the sibling triggers when the plugin
      -- loaded through some other trigger. The user was left with a dead
      -- keybinding and no error.
      test.stub_pack()
      local rhs = function() end
      _G.resonance.load({
        src = 'https://github.com/test/event-then-keys',
        event = { 'User', pattern = 'ResonanceEventFirst' },
        keys = { { 'n', '<leader>Re', rhs } },
        setup = function() end,
      })

      -- The event fires, which loads the plugin.
      api.nvim_exec_autocmds('User', { pattern = 'ResonanceEventFirst', modeline = false })
      vim.wait(200)

      local maps = api.nvim_get_keymap('n')
      local found = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Re') then found = maps[i] end
      end
      test.assert_not_nil(found, 'the keymap was removed when the plugin loaded')
      test.assert_eq(found.callback, rhs,
        'the keymap is still the loading stub, not the real mapping')
    end,
  },

  {
    name = 'triggers: the command stub is gone before the plugin defines its command',
    fn = function()
      -- A command stub is a real user command, so it owns the name. The
      -- plugin's own nvim_create_user_command() for that name failed while
      -- the stub was there, and the command was gone once the stub was
      -- torn down.
      --
      -- The trigger that loads the plugin has to be a different one: when
      -- the command itself is the trigger, the stub removes itself on the
      -- way in, and the name is free anyway.
      test.stub_pack()
      _G.resonance.load({
        src = 'https://github.com/test/cmd-stub-name',
        cmd = 'ResonanceCmdName',
        keys = { { 'n', '<leader>Rc', function() end } },
        setup = function()
          -- The plugin defines the command the stub was holding.
          api.nvim_create_user_command('ResonanceCmdName', function() end, { nargs = 0 })
        end,
      })

      -- The keymap fires, which loads the plugin.
      local maps = api.nvim_get_keymap('n')
      local stub = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Rc') then stub = maps[i] end
      end
      test.assert_not_nil(stub, 'the keymap stub was not registered')
      stub.callback()
      vim.wait(200)

      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds['ResonanceCmdName'],
        'the command was removed instead of being defined by the plugin')
      test.assert_eq(cmds['ResonanceCmdName'].nargs, '0',
        'the command is still the stub, not the one the plugin defined')
    end,
  },

  {
    name = 'triggers: an ft trigger fires on the matching filetype',
    fn = function()
      test.stub_pack()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/ft-trigger',
        ft = 'resonancebehaviortest',
        setup = function() ran = true end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(buf, 'x.resonancebehaviortest')
      vim.bo[buf].filetype = 'resonancebehaviortest'
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  {
    name = 'triggers: a cond that is false skips the plugin entirely',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cond-false',
        event = 'User',
        cond = function() return false end,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceCondTest', modeline = false })
      vim.wait(100)

      test.assert_false(ran)
    end,
  },

  {
    name = 'triggers: a cond that is true loads the plugin',
    fn = function()
      test.stub_pack()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cond-true',
        event = { 'User', pattern = 'ResonanceCondTrueTest' },
        cond = function() return true end,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceCondTrueTest', modeline = false })
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  {
    name = 'triggers: lazy=true with a string event keeps the primary event working',
    fn = function()
      -- lazy=true adds a VeryLazy User trigger alongside the primary
      -- event. The two used to share one list, so the User entry was
      -- dropped and the primary event was registered without it.
      test.stub_pack()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/lazy-string-event',
        event = 'BufReadPost',
        lazy = true,
        setup = function() ran = true end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_exec_autocmds('BufReadPost', { buf = buf, modeline = false })
      vim.wait(200)

      test.assert_true(ran, 'the primary BufReadPost event did not load the plugin')
    end,
  },

  {
    name = 'triggers: lazy=true with a string event also loads on VeryLazy',
    fn = function()
      test.stub_pack()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/lazy-string-event-vl',
        event = 'BufReadPost',
        lazy = true,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'VeryLazy', modeline = false })
      vim.wait(200)

      test.assert_true(ran, 'the VeryLazy trigger did not load the plugin')
    end,
  },

  {
    name = 'triggers: lazy=true with an array event keeps every primary event working',
    fn = function()
      test.stub_pack()
      local ran_bread = false
      _G.resonance.load({
        src = 'https://github.com/test/lazy-array-event',
        event = { 'BufReadPost', 'BufNewFile' },
        lazy = true,
        setup = function() ran_bread = true end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_exec_autocmds('BufNewFile', { buf = buf, modeline = false })
      vim.wait(200)

      test.assert_true(ran_bread, 'the BufNewFile event did not load the plugin')
    end,
  },

  {
    name = 'triggers: lazy=true with a User event keeps the custom pattern working',
    fn = function()
      -- A User event carries its own pattern. Adding VeryLazy to the same
      -- list used to corrupt it: the pattern was read as ev[2], which the
      -- VeryLazy entry had overwritten.
      test.stub_pack()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/lazy-user-event',
        event = { 'User', pattern = 'ResonanceLazyUserTest' },
        lazy = true,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceLazyUserTest', modeline = false })
      vim.wait(200)

      test.assert_true(ran, 'the custom User pattern did not load the plugin')
    end,
  },

  {
    name = 'triggers: a buffer-local keymap with buffer=true is removed on load',
    fn = function()
      -- opts.buffer can be true, meaning "the current buffer".
      -- vim.keymap.set understands that, but vim.keymap.del does not: it
      -- wants a buffer id and rejects a boolean with "Invalid 'buf':
      -- Expected Lua number". The delete is wrapped in pcall, so the
      -- failure was silent and the stub keymap stayed in place.
      test.stub_pack()
      -- The keymap is registered against the current buffer, so the test
      -- has to be looking at the same buffer the loader saw.
      local buf = api.nvim_get_current_buf()

      -- One spec, so the keymap and the event are siblings: loading the
      -- plugin through the event has to take the keymap stub with it.
      _G.resonance.load({
        src = 'https://github.com/test/buffer-local-key',
        keys = { { 'n', '<leader>Rb', nil, { buffer = true, desc = 'buffer local' } } },
        event = { 'User', pattern = 'ResonanceBufLocalEvent' },
        setup = function() end,
      })

      -- The keymap is set, buffer-local.
      local set_count = 0
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == leader_lhs('Rb') then set_count = set_count + 1 end
      end
      test.assert_eq(set_count, 1, 'the buffer-local keymap was not set on the current buffer')

      -- Loading the plugin must remove it. The delete has to name the
      -- buffer by id, not by true.
      api.nvim_exec_autocmds('User', { pattern = 'ResonanceBufLocalEvent', modeline = false })
      vim.wait(200)

      local left = 0
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == leader_lhs('Rb') then left = left + 1 end
      end
      test.assert_eq(left, 0, 'the buffer-local keymap stub survived the load')
    end,
  },

  {
    name = 'triggers: a command spec can supply its own nargs',
    fn = function()
      -- The stub hardcoded nargs = '*'. A command that expects exactly one
      -- argument rejects a valid invocation under a wildcard nargs, so the
      -- stub has to accept the real command's own options.
      _G.resonance.load({
        src = 'https://github.com/test/cmd-opts',
        cmd = { name = 'ResonanceCmdOpts', opts = { nargs = 1 } },
        setup = function() end,
      })

      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds['ResonanceCmdOpts'])
      test.assert_eq(cmds['ResonanceCmdOpts'].nargs, '1')
    end,
  },

  {
    name = 'triggers: a command that takes no arguments is registered',
    fn = function()
      -- The stub defaulted to complete = 'file', and Neovim rejects a
      -- completion on a command that takes no arguments: "'complete' used
      -- without 'nargs'". The error escaped resonance.load(), so the
      -- command was never registered and the spec's other triggers were
      -- never set up either.
      local ok, err = pcall(_G.resonance.load, {
        src = 'https://github.com/test/cmd-zero-args',
        cmd = { name = 'ResonanceCmdZeroArgs', opts = { nargs = 0 } },
        setup = function() end,
      })
      test.assert_true(ok, 'the load failed: ' .. tostring(err))

      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds['ResonanceCmdZeroArgs'],
        'the command was not registered')
      test.assert_eq(cmds['ResonanceCmdZeroArgs'].nargs, '0')
    end,
  },

  {
    name = 'triggers: a command that takes no arguments keeps the other triggers',
    fn = function()
      -- The error used to abort the whole load, so a spec with a bad
      -- command never got its event trigger either.
      test.stub_pack()
      local ran = false
      local ok, err = pcall(_G.resonance.load, {
        src = 'https://github.com/test/cmd-zero-with-event',
        cmd = { name = 'ResonanceCmdZeroWithEvent', opts = { nargs = 0 } },
        event = { 'User', pattern = 'ResonanceEventAfterZeroCmd' },
        setup = function() ran = true end,
      })
      test.assert_true(ok, 'the load failed: ' .. tostring(err))

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceEventAfterZeroCmd', modeline = false })
      vim.wait(200)
      test.assert_true(ran, 'the event trigger never fired')
    end,
  },

  {
    name = 'triggers: a command that takes no arguments is invoked',
    fn = function()
      -- The registered command has to work, not just exist.
      test.stub_pack()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cmd-zero-invoke',
        cmd = { name = 'ResonanceCmdZeroInvoke', opts = { nargs = 0 } },
        setup = function() ran = true end,
      })

      vim.cmd('ResonanceCmdZeroInvoke')
      vim.wait(200)
      test.assert_true(ran, 'the command did not load the plugin')
    end,
  },

  {
    name = 'triggers: a User event keeps its own pattern next to the VeryLazy one',
    fn = function()
      -- The defect was that adding VeryLazy to a User event list corrupted
      -- the custom pattern: the VeryLazy entry landed at ev[2], which is
      -- where the pattern is read from, so the custom pattern was lost.
      --
      -- The two User triggers must end up as two separate autocmds, each
      -- with its own pattern.
      test.stub_pack()
      _G.resonance.load({
        src = 'https://github.com/test/lazy-user-pattern-kept',
        event = { 'User', pattern = 'ResonanceLazyUserKept' },
        lazy = true,
        setup = function() end,
      })

      local patterns = {}
      for _, a in ipairs(api.nvim_get_autocmds({ event = 'User' })) do
        if a.group_name == 'Resonance_lazy-user-pattern-kept' then
          patterns[a.pattern] = true
        end
      end

      test.assert_true(patterns['ResonanceLazyUserKept'],
        'the custom User pattern was lost')
      test.assert_true(patterns['VeryLazy'],
        'the VeryLazy trigger was not registered alongside it')
    end,
  },

  {
    name = 'triggers: an event keeps a list of patterns',
    fn = function()
      -- Neovim accepts a list of patterns. The list used to be dropped
      -- during the normalization, so the trigger matched every file
      -- instead of the ones the user listed.
      --
      -- Neovim creates one autocmd per pattern, and each one reports its
      -- own pattern as a string.
      test.stub_pack()
      _G.resonance.load({
        src = 'https://github.com/test/event-list-pattern',
        event = { 'BufReadPost', pattern = { '*.lua', '*.vim' } },
        setup = function() end,
      })

      local patterns = {}
      for _, a in ipairs(api.nvim_get_autocmds({ event = 'BufReadPost' })) do
        if a.group_name == 'Resonance_event-list-pattern' then
          patterns[a.pattern] = true
        end
      end

      test.assert_true(patterns['*.lua'],
        'the first pattern of the list was lost')
      test.assert_true(patterns['*.vim'],
        'the second pattern of the list was lost')
    end,
  },

  {
    name = 'triggers: a key shorthand without an rhs keeps the plugin own mapping',
    fn = function()
      -- A key shorthand without an rhs means "the plugin defines this
      -- mapping itself". The teardown used to delete the mapping
      -- unconditionally, so the plugin's own mapping was taken with it and
      -- the user's shortcut was silently dead.
      test.stub_pack()
      local plugin_rhs = function() end
      _G.resonance.load({
        src = 'https://github.com/test/key-shorthand-own-mapping',
        keys = { { 'n', '<leader>Ro', nil } },
        event = { 'User', pattern = 'ResonanceOwnMappingTrigger' },
        setup = function()
          -- The plugin installs the mapping the user asked for.
          vim.keymap.set('n', '<leader>Ro', plugin_rhs, { desc = 'plugin mapping' })
        end,
      })

      -- A sibling trigger loads the plugin, so the teardown runs while the
      -- plugin's mapping is already in place.
      api.nvim_exec_autocmds('User', { pattern = 'ResonanceOwnMappingTrigger', modeline = false })
      vim.wait(200)

      -- The plugin's mapping must still be there, and it must be the
      -- plugin's mapping, not the loading stub.
      local maps = api.nvim_get_keymap('n')
      local found = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Ro') then found = maps[i] end
      end
      test.assert_not_nil(found, "the plugin's own mapping was deleted")
      test.assert_eq(found.callback, plugin_rhs,
        "the mapping is not the one the plugin installed")
    end,
  },

  {
    name = 'triggers: a key shorthand without an rhs keeps its mapping when the key fires',
    fn = function()
      -- The same defect, reached through the other path: the keymap itself
      -- fires, so the stub removes itself on the way in and the teardown
      -- runs afterwards.
      test.stub_pack()
      local plugin_rhs = function() end
      _G.resonance.load({
        src = 'https://github.com/test/key-shorthand-own-mapping-fire',
        keys = { { 'n', '<leader>Rf', nil } },
        setup = function()
          vim.keymap.set('n', '<leader>Rf', plugin_rhs, { desc = 'plugin mapping' })
        end,
      })

      local maps = api.nvim_get_keymap('n')
      local stub = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Rf') then stub = maps[i] end
      end
      test.assert_not_nil(stub, 'the keymap stub was not registered')
      stub.callback()
      vim.wait(200)

      local after = api.nvim_get_keymap('n')
      local found = nil
      for i = 1, #after do
        if after[i].lhs:find('Rf') then found = after[i] end
      end
      test.assert_not_nil(found, "the plugin's own mapping was deleted")
      test.assert_eq(found.callback, plugin_rhs,
        "the mapping is not the one the plugin installed")
    end,
  },

  {
    name = 'triggers: a keymap with an rhs is still restored after the load',
    fn = function()
      -- The conditional delete must not change the normal case: a keymap
      -- with an rhs is the user's binding, and it has to survive the load
      -- with that rhs in place.
      test.stub_pack()
      local rhs = function() end
      _G.resonance.load({
        src = 'https://github.com/test/key-with-rhs-restored',
        event = { 'User', pattern = 'ResonanceRestoreKeyRhs' },
        keys = { { 'n', '<leader>Rr', rhs } },
        setup = function() end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceRestoreKeyRhs', modeline = false })
      vim.wait(200)

      local maps = api.nvim_get_keymap('n')
      local found = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Rr') then found = maps[i] end
      end
      test.assert_not_nil(found, 'the keymap was removed instead of restored')
      test.assert_eq(found.callback, rhs,
        'the keymap is still the loading stub, not the real mapping')
    end,
  },

  {
    name = 'triggers: a keymap with buffer=false is treated as a global mapping',
    fn = function()
      -- A buffer of false means the mapping is global. Treating it as
      -- buffer-local made the teardown look for the keymap of a buffer
      -- that does not exist, which raised inside the lookup.
      test.stub_pack()
      local rhs = function() end
      _G.resonance.load({
        src = 'https://github.com/test/key-buffer-false',
        event = { 'User', pattern = 'ResonanceKeyBufferFalse' },
        keys = { { 'n', '<leader>Rg', rhs, { buffer = false } } },
        setup = function() end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceKeyBufferFalse', modeline = false })
      vim.wait(200)

      local maps = api.nvim_get_keymap('n')
      local found = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Rg') then found = maps[i] end
      end
      test.assert_not_nil(found, 'the global keymap was removed instead of restored')
      test.assert_eq(found.callback, rhs,
        'the keymap is still the loading stub, not the real mapping')
    end,
  },

  {
    name = 'triggers: a keymap with buf=0 is deleted from the buffer it was set on',
    fn = function()
      -- A buffer of 0 means the current buffer when the mapping is set.
      -- The teardown has to delete from that same buffer, and not from
      -- whatever happens to be current later.
      test.stub_pack()
      local buf = api.nvim_get_current_buf()
      _G.resonance.load({
        src = 'https://github.com/test/key-buf-zero',
        event = { 'User', pattern = 'ResonanceKeyBufZero' },
        keys = { { 'n', '<leader>Rz', nil, { buf = 0 } } },
        setup = function() end,
      })

      -- The mapping is on the buffer that was current at registration.
      local set_count = 0
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == leader_lhs('Rz') then set_count = set_count + 1 end
      end
      test.assert_eq(set_count, 1, 'the buffer-local keymap was not set on the current buffer')

      -- Switch away, so a teardown that used the current buffer would
      -- delete from the wrong one.
      local other = api.nvim_create_buf(false, true)
      api.nvim_set_current_buf(other)

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceKeyBufZero', modeline = false })
      vim.wait(200)

      local left = 0
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == leader_lhs('Rz') then left = left + 1 end
      end
      test.assert_eq(left, 0, 'the buffer-local keymap stub survived the load')
    end,
  },

  {
    name = 'triggers: a User event with a list of patterns does not crash the load',
    fn = function()
      -- A User event's pattern may be a list -- Neovim accepts a list of
      -- patterns on an autocmd -- and normalize_events keeps it as a list.
      -- The trigger string built for the display concatenated the pattern
      -- as if it were a string, which raised
      -- "attempt to concatenate a table value" and took the whole load
      -- down with it.
      test.stub_pack()
      local ran = false
      local ok, err = pcall(_G.resonance.load, {
        src = 'https://github.com/test/user-list-pattern',
        event = { 'User', pattern = { 'ResonanceUserA', 'ResonanceUserB' } },
        setup = function() ran = true end,
      })
      test.assert_true(ok, 'the load failed: ' .. tostring(err))

      -- The trigger still has to work: the list is the autocmd's pattern.
      api.nvim_exec_autocmds('User', { pattern = 'ResonanceUserB', modeline = false })
      vim.wait(200)
      test.assert_true(ran, 'the User trigger with a list of patterns never fired')
    end,
  },

  {
    name = 'triggers: a User event with a list of patterns has a readable trigger string',
    fn = function()
      -- The display string is what the user sees in the UI and in the
      -- notifications. A list of patterns is joined, not dropped.
      local utils = require('resonance.utils')
      local trig = utils.parse_trigger({
        event = { 'User', pattern = { 'ResonanceUserA', 'ResonanceUserB' } },
      })
      test.assert_not_nil(trig)
      test.assert_true(trig:find('ResonanceUserA', 1, true) ~= nil,
        'the first pattern is missing from the trigger string')
      test.assert_true(trig:find('ResonanceUserB', 1, true) ~= nil,
        'the second pattern is missing from the trigger string')
    end,
  },

  {
    name = 'triggers: a command spec may give nargs as the string "0"',
    fn = function()
      -- Neovim only accepts the number 0 for nargs; the string '0' is
      -- rejected with "Invalid 'nargs': '0'". The value is normalized, so
      -- the command registers and the default completion is dropped -- a
      -- completion on a command that takes no arguments is an error.
      local ok, err = pcall(_G.resonance.load, {
        src = 'https://github.com/test/cmd-zero-args-string',
        cmd = { name = 'ResonanceCmdZeroArgsString', opts = { nargs = '0' } },
        setup = function() end,
      })
      test.assert_true(ok, 'the load failed: ' .. tostring(err))

      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds['ResonanceCmdZeroArgsString'],
        'the command was not registered')
      test.assert_eq(cmds['ResonanceCmdZeroArgsString'].nargs, '0')
      test.assert_eq(cmds['ResonanceCmdZeroArgsString'].complete, nil,
        "the default completion was left on a command that takes no arguments")
    end,
  },
})

test.print_summary()
