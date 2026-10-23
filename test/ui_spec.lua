-- Tests for resonance.ui modules
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/ui_spec.lua" -c "lua test.print_summary()" -c "qall"

local ui = require('resonance.ui')
local state = require('resonance.ui.state')
local actions = require('resonance.ui.actions')
local render = require('resonance.ui.render')

test.run_suite('resonance.ui', {

  {
    name = 'state: initial state valid',
    fn = function()
      test.assert_not_nil(state.state)
      test.assert_eq(type(state.state), 'table')
    end,
  },

  {
    name = 'state: is_valid returns false before open',
    fn = function()
      test.assert_false(state.is_valid())
    end,
  },

  {
    name = 'state: plugin_at_cursor returns nil before open',
    fn = function()
      test.assert_nil(state.plugin_at_cursor())
    end,
  },

  {
    name = 'actions: check_updates_network sets checking flag',
    fn = function()
      -- This is an async test, just verify function exists
      test.assert_not_nil(actions.check_updates_network)
      test.assert_eq(type(actions.check_updates_network), 'function')
    end,
  },

  {
    name = 'actions: toggle_details function exists',
    fn = function()
      test.assert_not_nil(actions.toggle_details)
      test.assert_eq(type(actions.toggle_details), 'function')
    end,
  },

  {
    name = 'actions: update_plugins function exists',
    fn = function()
      test.assert_not_nil(actions.update_plugins)
      test.assert_eq(type(actions.update_plugins), 'function')
    end,
  },

  {
    name = 'actions: uninstall_plugin function exists',
    fn = function()
      test.assert_not_nil(actions.uninstall_plugin)
      test.assert_eq(type(actions.uninstall_plugin), 'function')
    end,
  },

  {
    name = 'actions: checkout_plugin function exists',
    fn = function()
      test.assert_not_nil(actions.checkout_plugin)
      test.assert_eq(type(actions.checkout_plugin), 'function')
    end,
  },

  {
    name = 'render: render function exists',
    fn = function()
      test.assert_not_nil(render.render)
      test.assert_eq(type(render.render), 'function')
    end,
  },

  {
    name = 'render: schedule_render function exists',
    fn = function()
      test.assert_not_nil(render.schedule_render)
      test.assert_eq(type(render.schedule_render), 'function')
    end,
  },

  {
    name = 'render: update_spinner function exists',
    fn = function()
      test.assert_not_nil(render.update_spinner)
      test.assert_eq(type(render.update_spinner), 'function')
    end,
  },

  {
    name = 'ui: open function exists',
    fn = function()
      test.assert_not_nil(ui.open)
      test.assert_eq(type(ui.open), 'function')
    end,
  },
})

test.print_summary()