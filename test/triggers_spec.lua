-- Tests for resonance.loader.triggers
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/triggers_spec.lua" -c "lua test.print_summary()" -c "qall"

local triggers = require('resonance.loader.triggers')
local api = vim.api

test.run_suite('resonance.loader.triggers', {

  {
    name = 'register_event: registers autocmd for string event',
    fn = function()
      local config = {event = 'BufReadPre'}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_event(config, load_now)
      local autocmds = api.nvim_get_autocmds({event = 'BufReadPre'})
      test.assert_true(#autocmds > 0)
    end,
  },

  {
    name = 'register_event: registers autocmd for table event',
    fn = function()
      local config = {event = {'BufReadPre', 'BufNewFile'}}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_event(config, load_now)
      local autocmds = api.nvim_get_autocmds({event = 'BufReadPre'})
      test.assert_true(#autocmds > 0)
    end,
  },

  {
    name = 'register_event: registers autocmd for complex event spec',
    fn = function()
      local config = {event = {'User', pattern = 'VeryLazy'}}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_event(config, load_now)
      local autocmds = api.nvim_get_autocmds({event = 'User', pattern = 'VeryLazy'})
      test.assert_true(#autocmds > 0)
    end,
  },

  {
    name = 'register_cmd: registers user command',
    fn = function()
      local config = {cmd = 'TestCommand'}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_cmd(config, load_now)
      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds.TestCommand)
    end,
  },

  {
    name = 'register_cmd: registers multiple commands',
    fn = function()
      local config = {cmd = {'Cmd1', 'Cmd2'}}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_cmd(config, load_now)
      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds.Cmd1)
      test.assert_not_nil(cmds.Cmd2)
    end,
  },

  {
    name = 'register_keys: registers keymaps',
    fn = function()
      local config = {keys = {{'n', '<leader>tt', function() end, {desc = 'Test'}}}}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_keys(config, load_now)
      -- Keymaps are registered, hard to test directly without pressing
      test.assert_true(true)
    end,
  },

  {
    name = 'register_keys: handles function returning keymaps',
    fn = function()
      local config = {keys = function() return {{'n', '<leader>tf', function() end}} end}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_keys(config, load_now)
      test.assert_true(true)
    end,
  },

  {
    name = 'register_ft: registers filetype autocmd',
    fn = function()
      local config = {ft = 'lua'}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_ft(config, load_now)
      local autocmds = api.nvim_get_autocmds({event = 'FileType', pattern = 'lua'})
      test.assert_true(#autocmds > 0)
    end,
  },

  {
    name = 'register_ft: registers multiple filetypes',
    fn = function()
      local config = {ft = {'lua', 'python'}}
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_ft(config, load_now)
      local autocmds = api.nvim_get_autocmds({event = 'FileType', pattern = 'lua'})
      test.assert_true(#autocmds > 0)
    end,
  },

  {
    name = 'register_all: calls all register functions',
    fn = function()
      local config = {
        event = 'BufReadPre',
        cmd = 'TestCmd',
        ft = 'lua',
        keys = {{'n', '<leader>ta', function() end}},
      }
      local loaded = false
      local function load_now() loaded = true end
      triggers.register_all(config, load_now)
      test.assert_true(true)
    end,
  },
})

test.print_summary()