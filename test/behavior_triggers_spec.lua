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
})

test.print_summary()
