-- Tests for resonance.loader.spec
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/spec_spec.lua" -c "lua test.print_summary()" -c "qall"

local spec = require('resonance.loader.spec')
local utils = require('resonance.utils')

test.run_suite('resonance.loader.spec', {

  -- parse_config tests
  {
    name = 'parse_config: returns nil for plugin list',
    fn = function()
      local config = {{src = 'test/repo'}}
      local result = spec.parse_config(config)
      test.assert_nil(result)
    end,
  },

  {
    name = 'parse_config: normalizes src/url to plugin table',
    fn = function()
      local config = {src = 'https://github.com/user/repo', name = 'myrepo'}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
      test.assert_eq(result.plugin[1].src, 'https://github.com/user/repo')
      test.assert_eq(result.plugin[1].name, 'myrepo')
    end,
  },

  {
    name = 'parse_config: normalizes url field',
    fn = function()
      local config = {url = 'https://github.com/user/repo'}
      local result = spec.parse_config(config)
      test.assert_eq(result.plugin[1].src, 'https://github.com/user/repo')
    end,
  },

  {
    name = 'parse_config: normalizes first string element to plugin',
    fn = function()
      local config = {'https://github.com/user/repo'}
      local result = spec.parse_config(config)
      test.assert_eq(result.plugin[1].src, 'https://github.com/user/repo')
    end,
  },

  {
    name = 'parse_config: config alias for setup',
    fn = function()
      local config = {src = 'test/repo', config = function() end}
      local result = spec.parse_config(config)
      test.assert_not_nil(result.setup)
    end,
  },

  {
    name = 'parse_config: lazy=false sets VimEnter event',
    fn = function()
      local config = {src = 'test/repo', lazy = false}
      local result = spec.parse_config(config)
      test.assert_eq(result.event, 'VimEnter')
    end,
  },

  {
    name = 'parse_config: lazy=true sets VeryLazy event',
    fn = function()
      local config = {src = 'test/repo', lazy = true}
      local result = spec.parse_config(config)
      -- The event list is normalized into descriptors: a User event keeps
      -- its pattern in its own field, so it cannot be mistaken for the
      -- pattern of the entry before it.
      test.assert_eq(type(result.event), 'table')
      test.assert_eq(#result.event, 1)
      test.assert_eq(result.event[1].event, 'User')
      test.assert_eq(result.event[1].pattern, 'VeryLazy')
      test.assert_true(result.event[1].user)
    end,
  },

  {
    name = 'parse_config: lazy=false errors with explicit event',
    fn = function()
      local config = {src = 'test/repo', lazy = false, event = 'LspAttach'}
      test.assert_error(function()
        spec.parse_config(config)
      end, 'lazy=false cannot be used with event')
    end,
  },

  {
    name = 'parse_config: lazy=false errors with explicit cmd',
    fn = function()
      local config = {src = 'test/repo', lazy = false, cmd = 'TestCmd'}
      test.assert_error(function()
        spec.parse_config(config)
      end, 'lazy=false cannot be used with event/cmd/ft')
    end,
  },

  {
    name = 'parse_config: lazy=false allows keys',
    fn = function()
      local config = {src = 'test/repo', lazy = false, keys = {'<leader>x'}}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
      test.assert_eq(result.event, 'VimEnter')
      test.assert_eq(result.keys[1][1], 'n')
      test.assert_eq(result.keys[1][2], '<leader>x')
    end,
  },

  {
    name = 'parse_config: lazy=true allows coexistence with event',
    fn = function()
      local config = {src = 'test/repo', lazy = true, event = 'LspAttach'}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
      -- VeryLazy is an additional trigger, not a replacement: the primary
      -- event stays, and the User entry is a separate descriptor.
      test.assert_eq(type(result.event), 'table')
      test.assert_eq(#result.event, 2)
      test.assert_eq(result.event[1].event, 'LspAttach')
      test.assert_false(result.event[1].user)
      test.assert_eq(result.event[2].event, 'User')
      test.assert_eq(result.event[2].pattern, 'VeryLazy')
      test.assert_true(result.event[2].user)
    end,
  },

  {
    name = 'parse_config: cond=false returns nil',
    fn = function()
      local config = {src = 'test/repo', cond = false}
      local result = spec.parse_config(config)
      test.assert_nil(result)
    end,
  },

  {
    name = 'parse_config: cond=true passes through',
    fn = function()
      local config = {src = 'test/repo', cond = true}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
    end,
  },

  {
    name = 'parse_config: cond=function returning true passes',
    fn = function()
      local config = {src = 'test/repo', cond = function() return true end}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
    end,
  },

  {
    name = 'parse_config: cond=function returning false returns nil',
    fn = function()
      local config = {src = 'test/repo', cond = function() return false end}
      local result = spec.parse_config(config)
      test.assert_nil(result)
    end,
  },

  {
    name = 'parse_config: wraps single plugin in array',
    fn = function()
      local config = {src = 'test/repo', plugin = {src = 'test/repo'}}
      local result = spec.parse_config(config)
      test.assert_eq(type(result.plugin), 'table')
      test.assert_eq(#result.plugin, 1)
    end,
  },

  -- extract_names tests
  {
    name = 'extract_names: extracts name from URL',
    fn = function()
      local plugins = {{src = 'https://github.com/user/repo.git'}}
      local names, _ = spec.extract_names(plugins)
      test.assert_eq(names[1], 'repo')
    end,
  },

  {
    name = 'extract_names: extracts name from URL without .git',
    fn = function()
      local plugins = {{src = 'https://github.com/user/repo'}}
      local names, _ = spec.extract_names(plugins)
      test.assert_eq(names[1], 'repo')
    end,
  },

  {
    name = 'extract_names: uses explicit name over derived',
    fn = function()
      local plugins = {{src = 'https://github.com/user/repo', name = 'custom'}}
      local names, _ = spec.extract_names(plugins)
      test.assert_eq(names[1], 'custom')
    end,
  },

  {
    name = 'extract_names: returns pack_spec for each plugin',
    fn = function()
      local plugins = {{src = 'test/repo'}}
      local _, pack_plugins = spec.extract_names(plugins)
      test.assert_eq(#pack_plugins, 1)
      test.assert_eq(pack_plugins[1].src, 'test/repo')
    end,
  },

  -- cond edge cases
  {
    name = 'parse_config: cond=function returning nil returns nil',
    fn = function()
      local config = {src = 'test/repo', cond = function() return nil end}
      local result = spec.parse_config(config)
      test.assert_nil(result)
    end,
  },

  {
    name = 'parse_config: cond=false with lazy=false skips lazy validation',
    fn = function()
      local config = {src = 'test/repo', lazy = false, cond = false}
      local result = spec.parse_config(config)
      test.assert_nil(result)
    end,
  },

  {
    name = 'parse_config: cond=false with lazy=true returns nil',
    fn = function()
      local config = {src = 'test/repo', lazy = true, cond = false}
      local result = spec.parse_config(config)
      test.assert_nil(result)
    end,
  },

  {
    name = 'parse_config: cond=false preserves trigger for disabled tracking',
    fn = function()
      local config = {src = 'test/repo', event = 'LspAttach', cond = false}
      local result = spec.parse_config(config)
      test.assert_nil(result)
      -- Original config should still have event for loader to extract trigger
      test.assert_eq(config.event, 'LspAttach')
    end,
  },

  {
    name = 'parse_config: cond=false with cmd preserves trigger',
    fn = function()
      local config = {src = 'test/repo', cmd = 'TestCmd', cond = false}
      local result = spec.parse_config(config)
      test.assert_nil(result)
      test.assert_eq(config.cmd, 'TestCmd')
    end,
  },

  {
    name = 'parse_config: cond=false with ft preserves trigger',
    fn = function()
      local config = {src = 'test/repo', ft = 'lua', cond = false}
      local result = spec.parse_config(config)
      test.assert_nil(result)
      test.assert_eq(config.ft, 'lua')
    end,
  },

  {
    name = 'parse_config: cond=false with keys function preserves trigger',
    fn = function()
      local config = {src = 'test/repo', keys = function() return {{'n', '<leader>x', function() end}} end, cond = false}
      local result = spec.parse_config(config)
      test.assert_nil(result)
      test.assert_true(type(config.keys) == 'function')
    end,
  },

  {
    name = 'parse_config: a spec with no trigger and no lazy loads on VimEnter',
    fn = function()
      -- Without this, the spec registered no trigger at all: the plugin was
      -- never installed and never loaded, with no error to explain why.
      local config = {src = 'test/repo', version = 'v1.0.0'}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
      test.assert_eq(result.event, 'VimEnter')
    end,
  },

  {
    name = 'parse_config: a spec with a trigger keeps it',
    fn = function()
      local config = {src = 'test/repo', event = 'LspAttach'}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
      test.assert_eq(result.event, 'LspAttach')
    end,
  },

  {
    name = 'parse_config: a spec with only keys keeps the triggerless default away',
    fn = function()
      local config = {src = 'test/repo', keys = {'<leader>x'}}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
      -- keys is a trigger, so no VimEnter event is added.
      test.assert_nil(result.event)
    end,
  },

  -- normalize_events tests
  {
    name = 'normalize_events: a string becomes one descriptor',
    fn = function()
      local events = utils.normalize_events('BufReadPost')
      test.assert_eq(#events, 1)
      test.assert_eq(events[1].event, 'BufReadPost')
      test.assert_false(events[1].user)
    end,
  },

  {
    name = 'normalize_events: a list of strings becomes one descriptor each',
    fn = function()
      local events = utils.normalize_events({ 'BufReadPost', 'BufNewFile' })
      test.assert_eq(#events, 2)
      test.assert_eq(events[1].event, 'BufReadPost')
      test.assert_eq(events[2].event, 'BufNewFile')
    end,
  },

  {
    name = 'normalize_events: a User event keeps its pattern in its own field',
    fn = function()
      local events = utils.normalize_events({ 'User', pattern = 'VeryLazy' })
      test.assert_eq(#events, 1)
      test.assert_eq(events[1].event, 'User')
      test.assert_eq(events[1].pattern, 'VeryLazy')
      test.assert_true(events[1].user)
    end,
  },

  {
    name = 'normalize_events: a User pattern may be positional',
    fn = function()
      local events = utils.normalize_events({ 'User', 'VeryLazy' })
      test.assert_eq(#events, 1)
      test.assert_eq(events[1].event, 'User')
      test.assert_eq(events[1].pattern, 'VeryLazy')
      test.assert_true(events[1].user)
    end,
  },

  {
    name = 'normalize_events: is idempotent',
    fn = function()
      local once = utils.normalize_events({ 'BufReadPost', { event = 'User', pattern = 'VeryLazy', user = true } })
      local twice = utils.normalize_events(once)
      test.assert_eq(#twice, #once)
      test.assert_eq(twice[1].event, 'BufReadPost')
      test.assert_eq(twice[2].event, 'User')
      test.assert_eq(twice[2].pattern, 'VeryLazy')
      test.assert_true(twice[2].user)
    end,
  },

  {
    name = 'normalize_events: native_event_names skips User entries',
    fn = function()
      local events = utils.normalize_events({
        'BufReadPost',
        { event = 'User', pattern = 'VeryLazy', user = true },
      })
      local names = utils.native_event_names(events)
      test.assert_eq(#names, 1)
      test.assert_eq(names[1], 'BufReadPost')
    end,
  },
})

test.print_summary()