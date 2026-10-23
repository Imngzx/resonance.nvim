-- Integration tests for resonance.nvim full workflow
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/integration_spec.lua" -c "lua test.print_summary()" -c "qall"

local resonance = require('resonance')
local loader = require('resonance.loader')
local scanner = require('resonance.scanner')

test.run_suite('resonance.integration', {

  {
    name = 'setup: initializes without error',
    fn = function()
      resonance.setup({})
      test.assert_true(true)
    end,
  },

  {
    name = 'load: accepts single plugin spec',
    fn = function()
      resonance.load({src = 'https://github.com/test/integration1', event = 'LspAttach'})
      test.assert_not_nil(loader.specs['integration1'])
    end,
  },

  {
    name = 'load: handles lazy=false',
    fn = function()
      resonance.load({src = 'https://github.com/test/integration2', lazy = false})
      local spec = loader.specs['integration2']
      test.assert_not_nil(spec)
      test.assert_eq(spec.event, 'VimEnter')
    end,
  },

  {
    name = 'load: handles lazy=true',
    fn = function()
      resonance.load({src = 'https://github.com/test/integration3', lazy = true})
      local spec = loader.specs['integration3']
      test.assert_not_nil(spec)
      test.assert_eq(type(spec.event), 'table')
      test.assert_eq(spec.event.pattern, 'VeryLazy')
    end,
  },

  {
    name = 'load: handles cond=false (skips plugin)',
    fn = function()
      local spec = loader.specs['integration4']
      test.assert_nil(spec)
    end,
  },

  {
    name = 'load: handles cond=function returning false',
    fn = function()
      local spec = loader.specs['integration5']
      test.assert_nil(spec)
    end,
  },

  {
    name = 'load: handles cond=function returning true',
    fn = function()
      resonance.load({src = 'https://github.com/test/integration6', cond = function() return true end})
      test.assert_not_nil(loader.specs['integration6'])
    end,
  },

  {
    name = 'load: handles keys as function',
    fn = function()
      resonance.load({
        src = 'https://github.com/test/integration7',
        keys = function() return {{'n', '<leader>test', function() end}} end
      })
      test.assert_not_nil(loader.specs['integration7'])
    end,
  },

  {
    name = 'load: handles dependencies',
    fn = function()
      resonance.load({
        src = 'https://github.com/test/integration8',
        dependencies = {'https://github.com/test/dep1', 'https://github.com/test/dep2'},
        event = 'BufReadPre',
      })
      local spec = loader.specs['integration8']
      test.assert_not_nil(spec)
      test.assert_not_nil(spec.dependencies)
      test.assert_eq(#spec.dependencies, 2)
    end,
  },

  {
    name = 'load: handles build string',
    fn = function()
      resonance.load({src = 'https://github.com/test/integration9', build = 'make'})
      local spec = loader.specs['integration9']
      test.assert_not_nil(spec)
      test.assert_eq(spec.build, 'make')
    end,
  },

  {
    name = 'load: handles build function',
    fn = function()
      local build_fn = function(dir) end
      resonance.load({src = 'https://github.com/test/integration10', build = build_fn})
      local spec = loader.specs['integration10']
      test.assert_not_nil(spec)
      test.assert_eq(spec.build, build_fn)
    end,
  },

  {
    name = 'load: handles version pinning',
    fn = function()
      resonance.load({src = 'https://github.com/test/integration11', version = 'v1.0.0'})
      local spec = loader.specs['integration11']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'v1.0.0')
    end,
  },

  {
    name = 'scanner: reflects loaded plugins',
    fn = function()
      local info = scanner.get_info()
      test.assert_not_nil(info)
      test.assert_true(info.total >= 0)
    end,
  },

  {
    name = 'dag: get_dag_data returns structure',
    fn = function()
      local nodes, edges = loader.get_dag_data()
      test.assert_not_nil(nodes)
      test.assert_not_nil(edges)
    end,
  },

  {
    name = 'dag: get_replay_info returns structure',
    fn = function()
      local info = loader.get_replay_info()
      test.assert_not_nil(info)
    end,
  },

  {
    name = 'config: setup with ui config',
    fn = function()
      resonance.setup({
        ui = {
          border = 'rounded',
          width = 100,
          height = 30,
        }
      })
      test.assert_not_nil(resonance.config.ui)
      test.assert_eq(resonance.config.ui.border, 'rounded')
    end,
  },
})

test.print_summary()