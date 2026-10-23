-- Tests for resonance.loader.init (main loader)
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/loader_spec.lua" -c "lua test.print_summary()" -c "qall"

local loader = require('resonance.loader')
local utils = require('resonance.utils')

test.run_suite('resonance.loader.init', {

  {
    name = 'get_plugin_dir: returns path for installed plugin',
    fn = function()
      local dir = loader.get_plugin_dir('resonance.nvim')
      test.assert_not_nil(dir)
      test.assert_true(type(dir) == 'string')
      test.assert_true(dir:match('resonance.nvim'))
    end,
  },

  {
    name = 'get_plugin_dir: returns nil for non-existent plugin',
    fn = function()
      local dir = loader.get_plugin_dir('nonexistent-plugin-xyz')
      test.assert_nil(dir)
    end,
  },

  {
    name = 'plugin_triggers: table exists',
    fn = function()
      test.assert_not_nil(loader.plugin_triggers)
      test.assert_eq(type(loader.plugin_triggers), 'table')
    end,
  },

  {
    name = 'specs: table exists',
    fn = function()
      test.assert_not_nil(loader.specs)
      test.assert_eq(type(loader.specs), 'table')
    end,
  },

  {
    name = 'build_hooks: table exists',
    fn = function()
      test.assert_not_nil(loader.build_hooks)
      test.assert_eq(type(loader.build_hooks), 'table')
    end,
  },

  {
    name = 'get_dag_data: returns nodes and edges',
    fn = function()
      local nodes, edges = loader.get_dag_data()
      test.assert_not_nil(nodes)
      test.assert_not_nil(edges)
      test.assert_eq(type(nodes), 'table')
      test.assert_eq(type(edges), 'table')
    end,
  },

  {
    name = 'get_replay_info: returns replay info',
    fn = function()
      local info = loader.get_replay_info()
      test.assert_not_nil(info)
      test.assert_eq(type(info), 'table')
    end,
  },

  {
    name = '_get_event_chain_internal: returns chain for event',
    fn = function()
      local chain = loader._get_event_chain_internal('BufReadPre', 0, {})
      test.assert_not_nil(chain)
      test.assert_eq(type(chain), 'table')
    end,
  },
})

test.print_summary()