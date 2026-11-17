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
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
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
      api.nvim_exec_autocmds('BufNewFile', { buffer = buf, modeline = false })
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
})

test.print_summary()
