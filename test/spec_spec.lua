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
      test.assert_eq(type(result.event), 'table')
      test.assert_eq(result.event[1], 'User')
      test.assert_eq(result.event.pattern, 'VeryLazy')
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
      end, 'lazy=false cannot be used with event/cmd/keys/ft')
    end,
  },

  {
    name = 'parse_config: lazy=true allows coexistence with event',
    fn = function()
      local config = {src = 'test/repo', lazy = true, event = 'LspAttach'}
      local result = spec.parse_config(config)
      test.assert_not_nil(result)
      test.assert_eq(type(result.event), 'table')
      test.assert_eq(result.event[1], 'LspAttach')
      test.assert_eq(result.event[2][1], 'User')
      test.assert_eq(result.event[2].pattern, 'VeryLazy')
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
})

test.print_summary()