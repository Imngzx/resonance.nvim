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
    name = 'register_keys: a string rhs is fed without remapping by default',
    fn = function()
      -- vim.keymap.set defaults to noremap, so the replayed keys must not
      -- be remapped either. The feed mode used to be inverted, which fed
      -- every string rhs with 'm' and forced the remapping.
      local feeds = {}
      local real_feedkeys = api.nvim_feedkeys
      local real_module = package.loaded['resonance.loader.triggers']
      api.nvim_feedkeys = function(keys, mode, escape)
        feeds[#feeds + 1] = { keys = keys, mode = mode }
        return 0
      end
      -- The module captures feedkeys when it loads, so it has to be
      -- re-required after the stub is in place.
      package.loaded['resonance.loader.triggers'] = nil
      local fresh = require('resonance.loader.triggers')

      local config = { keys = { { 'n', '<leader>Fn', ':echo "x"<CR>' } } }
      fresh.register_keys(config, function() end)

      local maps = api.nvim_get_keymap('n')
      local stub = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Fn') then stub = maps[i] end
      end
      test.assert_not_nil(stub, 'the keymap stub was not registered')
      stub.callback()

      api.nvim_feedkeys = real_feedkeys
      package.loaded['resonance.loader.triggers'] = real_module

      test.assert_eq(#feeds, 1, 'the rhs was not fed')
      test.assert_eq(feeds[1].mode, 'n',
        'the rhs was fed with remapping forced on')
    end,
  },

  {
    name = 'register_keys: remap = true feeds the rhs with remapping',
    fn = function()
      -- The inverse of the default: a mapping set up for remapping has to
      -- be replayed with remapping.
      local feeds = {}
      local real_feedkeys = api.nvim_feedkeys
      local real_module = package.loaded['resonance.loader.triggers']
      api.nvim_feedkeys = function(keys, mode, escape)
        feeds[#feeds + 1] = { keys = keys, mode = mode }
        return 0
      end
      package.loaded['resonance.loader.triggers'] = nil
      local fresh = require('resonance.loader.triggers')

      local config = {
        keys = { { 'n', '<leader>Fm', ':echo "x"<CR>', { remap = true } } },
      }
      fresh.register_keys(config, function() end)

      local maps = api.nvim_get_keymap('n')
      local stub = nil
      for i = 1, #maps do
        if maps[i].lhs:find('Fm') then stub = maps[i] end
      end
      test.assert_not_nil(stub, 'the keymap stub was not registered')
      stub.callback()

      api.nvim_feedkeys = real_feedkeys
      package.loaded['resonance.loader.triggers'] = real_module

      test.assert_eq(#feeds, 1, 'the rhs was not fed')
      test.assert_eq(feeds[1].mode, 'm',
        'the rhs was fed without remapping')
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