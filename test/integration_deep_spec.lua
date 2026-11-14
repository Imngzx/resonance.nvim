-- Deep integration tests for resonance.loader
-- Tests actual plugin loading behavior, not just spec parsing
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/integration_deep_spec.lua" -c "lua test.print_summary()" -c "qall"

test.run_suite('resonance.loader.deep', {

  {
    name = 'lazy load: event trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      _G.resonance.load({
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
      _G.resonance.load({
        src = 'https://github.com/test/verylazy-plugin',
        lazy = true,
        setup = function() table.insert(load_order, 'setup') end,
      })

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
      _G.resonance.load({
        src = 'https://github.com/test/keymap-plugin',
        keys = function()
          return {{'n', '<leader>test', function() table.insert(load_order, 'setup') end}}
        end,
      })

      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<leader>test', true, false, true), 'n', false)
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: cmd trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/cmd-plugin',
        cmd = 'TestLoadPlugin',
        setup = function() table.insert(load_order, 'setup') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'TestLoadPlugin', modeline = false })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: ft trigger fires and loads plugin',
    fn = function()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/ft-plugin',
        ft = 'testfiletype',
        setup = function() table.insert(load_order, 'setup') end,
      })

      vim.api.nvim_set_option_value('filetype', 'testfiletype', { buf = 0 })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: plugin loads only once regardless of multiple triggers',
    fn = function()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/multi-trigger',
        event = { 'User', pattern = 'MultiTrigger1' },
        cmd = 'MultiTriggerCmd',
        setup = function() table.insert(load_order, 'setup') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'MultiTrigger1', modeline = false })
      vim.wait(100)
      vim.api.nvim_exec_autocmds('User', { pattern = 'MultiTrigger1', modeline = false })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'dependency: loads dependencies before plugin',
    fn = function()
      local load_order = {}
      _G.resonance.load({src = 'https://github.com/test/dep-b', setup = function() table.insert(load_order, 'dep-b') end})
      _G.resonance.load({src = 'https://github.com/test/dep-c', setup = function() table.insert(load_order, 'dep-c') end})
      _G.resonance.load({
        src = 'https://github.com/test/plugin-a',
        dependencies = {'https://github.com/test/dep-b', 'https://github.com/test/dep-c'},
        setup = function() table.insert(load_order, 'plugin-a') end,
      })

      vim.wait(100)

      test.assert_eq(load_order[1], 'dep-b')
      test.assert_eq(load_order[2], 'dep-c')
      test.assert_eq(load_order[3], 'plugin-a')
    end,
  },

  {
    name = 'dependency: transitive dependencies work',
    fn = function()
      local load_order = {}
      _G.resonance.load({src = 'https://github.com/test/bottom-plugin', setup = function() table.insert(load_order, 'bottom') end})
      _G.resonance.load({
        src = 'https://github.com/test/mid-plugin',
        dependencies = {'https://github.com/test/bottom-plugin'},
        setup = function() table.insert(load_order, 'mid') end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/top-plugin',
        dependencies = {'https://github.com/test/mid-plugin'},
        setup = function() table.insert(load_order, 'top') end,
      })

      vim.wait(100)

      test.assert_eq(load_order[1], 'bottom')
      test.assert_eq(load_order[2], 'mid')
      test.assert_eq(load_order[3], 'top')
    end,
  },

  {
    name = 'cond: function returning false skips plugin entirely',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/cond-fake-trigger', event = 'BufReadPre', cond = function() return false end})
      local info = _G.scanner.get_info()
      local found = false
      for i = 1, info.total do
        if info.plugins.name[i] == 'cond-fake-trigger' then
          found = true
        end
      end
      test.assert_false(found)
    end,
  },

  {
    name = 'cond: function returning true loads plugin',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/cond-true', event = 'BufReadPre', cond = function() return true end})
      test.assert_not_nil(_G.loader.specs['cond-true'])
    end,
  },

  {
    name = 'eager load: lazy=false loads on VimEnter',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/eager-plugin', lazy = false})
      local spec = _G.loader.specs['eager-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.event, 'VimEnter')
    end,
  },

  {
    name = 'grouped plugins: setup and loaded state apply to every member',
    fn = function()
      local setup_a, setup_b = 0, 0
      _G.resonance.load({
        {src = 'https://github.com/test/group-a', event = { 'User', pattern = 'GroupedPluginTest' }, setup = function() setup_a = setup_a + 1 end},
        {src = 'https://github.com/test/group-b', event = { 'User', pattern = 'GroupedPluginTest' }, setup = function() setup_b = setup_b + 1 end},
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'GroupedPluginTest', modeline = false })
      vim.wait(100)

      local nodes = _G.loader.get_dag_data()
      test.assert_eq(setup_a, 1)
      test.assert_eq(setup_b, 1)
      test.assert_true(nodes['group-a'].loaded)
      test.assert_true(nodes['group-b'].loaded)
    end,
  },

  {
    name = 'version pinning: tag version works',
    fn = function()
      _G.resonance.load({ src = 'https://github.com/test/version-plugin', version = 'v1.0.0' })
      local spec = _G.loader.specs['version-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'v1.0.0')
    end,
  },

  {
    name = 'version pinning: branch version works',
    fn = function()
      _G.resonance.load({ src = 'https://github.com/test/version-plugin', version = 'main' })
      local spec = _G.loader.specs['version-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'main')
    end,
  },

  {
    name = 'version pinning: commit hash version works',
    fn = function()
      _G.resonance.load({ src = 'https://github.com/test/version-plugin', version = 'abc1234' })
      local spec = _G.loader.specs['version-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'abc1234')
    end,
  },

  {
    name = 'fallback mode: works when vim.pack is nil',
    fn = function()
      local original_pack = vim.pack
      vim.pack = nil
      _G.resonance.setup({})
      _G.resonance.load({src = 'https://github.com/test/fallback', event = 'BufReadPre'})
      local info = _G.scanner.get_info()
      test.assert_true(info.total > 0)
      vim.pack = original_pack
    end,
  },
})

test.print_summary()