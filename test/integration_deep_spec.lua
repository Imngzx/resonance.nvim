-- Deep integration tests for resonance.loader
-- Tests actual plugin loading behavior, not just spec parsing
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/integration_deep_spec.lua" -c "lua test.print_summary()" -c "qall"

local resonance = require('resonance')
local loader = require('resonance.loader')
local utils = require('resonance.utils')

test.run_suite('resonance.loader.deep', {

  {
    name = 'lazy load: event trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      resonance.load({
        src = 'https://github.com/test/event-plugin',
        event = { 'User', pattern = 'TestEvent' },
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- Fire the event
      vim.api.nvim_exec_autocmds('User', { pattern = 'TestEvent', modeline = false })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: VeryLazy trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      resonance.load({
        src = 'https://github.com/test/verylazy-plugin',
        lazy = true,
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- Fire VeryLazy
      vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy', modeline = false })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: keymap trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      resonance.load({
        src = 'https://github.com/test/keymap-plugin',
        keys = {{'n', '<leader>testload', function() table.insert(load_order, 'rhs') end}},
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- In headless mode, feedkeys doesn't trigger keymaps.
      -- Directly call the registered keymap callback.
      vim.wait(50)
      local keymaps = vim.api.nvim_get_keymap('n')
      for _, km in ipairs(keymaps) do
        if km.lhs:match('testload') and km.callback then
          km.callback()
          break
        end
      end
      vim.wait(100)

      test.assert_eq(#load_order, 2)
      test.assert_eq(load_order[1], 'setup')
      test.assert_eq(load_order[2], 'rhs')
    end,
  },

  {
    name = 'lazy load: cmd trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      resonance.load({
        src = 'https://github.com/test/cmd-plugin',
        cmd = 'TestLoadPlugin',
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- Execute the command
      vim.cmd('TestLoadPlugin')
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: ft trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      resonance.load({
        src = 'https://github.com/test/ft-plugin',
        ft = 'testft',
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- Set filetype
      vim.bo.filetype = 'testft'
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: plugin loads only once regardless of multiple triggers',
    fn = function()
      local load_count = 0
      resonance.load({
        src = 'https://github.com/test/multi-trigger',
        event = { 'User', pattern = 'MultiTrigger1' },
        cmd = 'MultiTriggerCmd',
        setup = function() load_count = load_count + 1 end,
      })

      -- Fire both triggers
      vim.api.nvim_exec_autocmds('User', { pattern = 'MultiTrigger1', modeline = false })
      vim.wait(50)
      vim.cmd('MultiTriggerCmd')
      vim.wait(50)

      test.assert_eq(load_count, 1)
    end,
  },

  {
    name = 'dependency: loads dependencies before plugin',
    fn = function()
      local load_order = {}
      resonance.load({
        src = 'https://github.com/test/plugin-a',
        dependencies = {
          'https://github.com/test/dep-b',
          'https://github.com/test/dep-c',
        },
        event = { 'User', pattern = 'DepTestEvent' },
        setup = function() table.insert(load_order, 'plugin-a') end,
      })

      resonance.load({
        src = 'https://github.com/test/dep-b',
        setup = function() table.insert(load_order, 'dep-b') end,
      })

      resonance.load({
        src = 'https://github.com/test/dep-c',
        setup = function() table.insert(load_order, 'dep-c') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'DepTestEvent', modeline = false })
      vim.wait(100)

      -- Dependencies should load before plugin
      local dep_b_idx = 0
      local dep_c_idx = 0
      local plugin_a_idx = 0
      for i, name in ipairs(load_order) do
        if name == 'dep-b' then dep_b_idx = i end
        if name == 'dep-c' then dep_c_idx = i end
        if name == 'plugin-a' then plugin_a_idx = i end
      end
      test.assert_true(dep_b_idx > 0 and dep_b_idx < plugin_a_idx)
      test.assert_true(dep_c_idx > 0 and dep_c_idx < plugin_a_idx)
    end,
  },

  {
    name = 'dependency: transitive dependencies work',
    fn = function()
      local load_order = {}
      resonance.load({
        src = 'https://github.com/test/top-plugin',
        dependencies = {'https://github.com/test/mid-plugin'},
        event = { 'User', pattern = 'TransitiveTest' },
        setup = function() table.insert(load_order, 'top-plugin') end,
      })

      resonance.load({
        src = 'https://github.com/test/mid-plugin',
        dependencies = {'https://github.com/test/bottom-plugin'},
        setup = function() table.insert(load_order, 'mid-plugin') end,
      })

      resonance.load({
        src = 'https://github.com/test/bottom-plugin',
        setup = function() table.insert(load_order, 'bottom-plugin') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'TransitiveTest', modeline = false })
      vim.wait(100)

      local bottom_idx = 0
      local mid_idx = 0
      local top_idx = 0
      for i, name in ipairs(load_order) do
        if name == 'bottom-plugin' then bottom_idx = i end
        if name == 'mid-plugin' then mid_idx = i end
        if name == 'top-plugin' then top_idx = i end
      end
      test.assert_true(bottom_idx > 0 and bottom_idx < mid_idx)
      test.assert_true(mid_idx > 0 and mid_idx < top_idx)
    end,
  },

  {
    name = 'cond: function returning false skips plugin entirely',
    fn = function()
      local load_count = 0
      resonance.load({
        src = 'https://github.com/test/cond-false',
        cond = function() return false end,
        setup = function() load_count = load_count + 1 end,
      })

      -- Try to trigger load
      resonance.load({src = 'https://github.com/test/cond-fake-trigger', event = { 'User', pattern = 'CondTest' }})
      vim.api.nvim_exec_autocmds('User', { pattern = 'CondTest', modeline = false })
      vim.wait(100)

      test.assert_eq(load_count, 0)
    end,
  },

  {
    name = 'cond: function returning true loads plugin',
    fn = function()
      local load_count = 0
      resonance.load({
        src = 'https://github.com/test/cond-true',
        cond = function() return true end,
        event = { 'User', pattern = 'CondTrueTest' },
        setup = function() load_count = load_count + 1 end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'CondTrueTest', modeline = false })
      vim.wait(100)

      test.assert_eq(load_count, 1)
    end,
  },

  {
    name = 'eager load: lazy=false loads on VimEnter',
    fn = function()
      local load_count = 0
      resonance.load({
        src = 'https://github.com/test/eager-plugin',
        lazy = false,
        setup = function() load_count = load_count + 1 end,
      })

      -- VimEnter already fired, but we can simulate
      vim.api.nvim_exec_autocmds('VimEnter', { modeline = false })
      vim.wait(100)

      test.assert_eq(load_count, 1)
    end,
  },

  {
    name = 'version pinning: tag version works',
    fn = function()
      resonance.load({src = 'https://github.com/test/version-plugin', version = 'v1.0.0'})
      local spec = loader.specs['version-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'v1.0.0')
    end,
  },

  {
    name = 'version pinning: branch version works',
    fn = function()
      resonance.load({src = 'https://github.com/test/version-plugin2', version = 'main'})
      local spec = loader.specs['version-plugin2']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'main')
    end,
  },

  {
    name = 'version pinning: commit hash version works',
    fn = function()
      resonance.load({src = 'https://github.com/test/version-plugin3', version = 'abc1234'})
      local spec = loader.specs['version-plugin3']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'abc1234')
    end,
  },

  {
    name = 'fallback mode: works when vim.pack is nil',
    fn = function()
      -- Save original vim.pack
      local orig_pack = vim.pack
      vim.pack = nil

      -- Re-require to trigger fallback
      package.loaded['resonance.scanner'] = nil
      local scanner = require('resonance.scanner')

      local info = scanner.get_info()
      test.assert_not_nil(info)
      test.assert_true(info.total >= 0)

      -- Restore
      vim.pack = orig_pack
      package.loaded['resonance.scanner'] = nil
    end,
  },
})

test.print_summary()