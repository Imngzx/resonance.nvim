-- Tests for resonance.import (lua/resonance/scandir.lua)
-- Run with: test/dev_env.sh test test/scandir_spec.lua

local uv = vim.uv
local helpers = dofile('test/helpers.lua')

-- A throwaway lua/ root on the runtimepath, so require() finds its modules.
-- `MOD/` in a path stands for the module name.
local function make_root(mod, files)
  local base = vim.fn.tempname()
  local root = base .. '/lua'
  for path, body in pairs(files) do
    local full = root .. '/' .. path:gsub('^MOD/', mod .. '/')
    vim.fn.mkdir(vim.fs.dirname(full), 'p')
    local f = assert(io.open(full, 'w'))
    f:write(body)
    f:close()
  end
  vim.opt.rtp:prepend(base)
  return root, base
end

local function cleanup(base, mod)
  vim.opt.rtp:remove(base)
  for name in pairs(package.loaded) do
    if name == mod or name:sub(1, #mod + 1) == mod .. '.' then
      package.loaded[name] = nil
    end
  end
  vim.fn.delete(base, 'rf')
end

-- Run import() with resonance.load stubbed: record what would be loaded.
local function import(mod, files, opts)
  local root, base = make_root(mod, files)
  local resonance = require('resonance')
  local orig = resonance.load
  local loaded = {}
  resonance.load = function(spec) loaded[#loaded + 1] = spec end
  opts = opts or {}
  opts.root = root
  local ok, err = pcall(resonance.import, mod, opts)
  resonance.load = orig
  cleanup(base, mod)
  if not ok then error(err) end
  return loaded
end

local function names(loaded)
  local out = {}
  for i = 1, #loaded do out[i] = loaded[i].name end
  return table.concat(out, ',')
end

local uniq = 0
local function modname()
  uniq = uniq + 1
  return 'rs_import_' .. uniq .. '_' .. uv.hrtime()
end

test.run_suite('resonance.import', {

  {
    name = 'import: a single spec and a list of specs are both registered',
    fn = function()
      local loaded = import(modname(), {
        ['MOD/a.lua'] = "return { 'https://x.invalid/a', name = 'a' }",
        ['MOD/b.lua'] = "return { { src = 'https://x.invalid/b1', name = 'b1' }, { url = 'https://x.invalid/b2', name = 'b2' } }",
      })
      test.assert_eq(names(loaded), 'a,b1,b2')
    end,
  },

  {
    name = 'import: a folder counts through init.lua only; its helpers are not imported',
    fn = function()
      local loaded = import(modname(), {
        ['MOD/c/init.lua'] = "return { 'https://x.invalid/c', name = 'c' }",
        ['MOD/c/helper.lua'] = "return { 'https://x.invalid/helper', name = 'helper' }",
        ['MOD/d/only.lua'] = "return { 'https://x.invalid/d', name = 'd' }",
      })
      test.assert_eq(names(loaded), 'c')
    end,
  },

  {
    name = 'import: highest priority first, ties in file order, priority stripped',
    fn = function()
      local loaded = import(modname(), {
        ['MOD/a.lua'] = "return { 'https://x.invalid/a', name = 'a' }",
        ['MOD/b.lua'] = "return { 'https://x.invalid/b', name = 'b', priority = 1000 }",
        ['MOD/c.lua'] = "return { 'https://x.invalid/c', name = 'c' }",
        ['MOD/d.lua'] = "return { 'https://x.invalid/d', name = 'd', priority = 10 }",
      })
      test.assert_eq(names(loaded), 'b,d,a,c')
      for i = 1, #loaded do
        test.assert_nil(loaded[i].priority, 'priority reached load()')
      end
    end,
  },

  {
    name = 'import: a failing module goes to on_error and the rest still register',
    fn = function()
      local errors = {}
      local loaded = import(modname(), {
        ['MOD/a.lua'] = "error('boom')",
        ['MOD/b.lua'] = "return { 'https://x.invalid/b', name = 'b' }",
      }, { on_error = function(name, err) errors[#errors + 1] = name .. ':' .. tostring(err) end })
      test.assert_eq(names(loaded), 'b')
      test.assert_eq(#errors, 1)
      test.assert_contains(errors[1], 'boom')
    end,
  },

  {
    name = 'import: a non-spec return is ignored',
    fn = function()
      local loaded = import(modname(), {
        ['MOD/helper.lua'] = "return { foo = 1 }",
        ['MOD/nothing.lua'] = "local x = 1",
        ['MOD/a.lua'] = "return { 'https://x.invalid/a', name = 'a' }",
      })
      test.assert_eq(names(loaded), 'a')
    end,
  },

  {
    name = 'import: a folder imported on its own is skipped by the parent import',
    fn = function()
      local mod = modname()
      local root, base = make_root(mod, {
        ['MOD/a.lua'] = "return { 'https://x.invalid/a', name = 'a' }",
        ['MOD/core/init.lua'] = "return { 'https://x.invalid/core', name = 'core' }",
        ['MOD/core/theme.lua'] = "return { 'https://x.invalid/theme', name = 'theme' }",
      })
      local resonance = require('resonance')
      local orig = resonance.load
      local loaded = {}
      resonance.load = function(spec) loaded[#loaded + 1] = spec end
      local ok, err = pcall(function()
        resonance.import(mod .. '.core', { root = root })
        resonance.import(mod, { root = root })
      end)
      resonance.load = orig
      cleanup(base, mod)
      if not ok then error(err) end
      -- core/init.lua is registered once, by the core import, not again by the parent.
      test.assert_eq(names(loaded), 'core,theme,a')
    end,
  },

  {
    name = 'import: a spec written as { { url }, opts } keeps its options',
    fn = function()
      -- is_spec() used to look at [1] only, took this for a list of specs,
      -- and registered { url } alone: lazy and cmd were dropped.
      local loaded = import(modname(), {
        ['MOD/a.lua'] = "return { { 'https://x.invalid/a' }, name = 'a', lazy = true, cmd = 'ACmd' }",
        ['MOD/b.lua'] = "return { { 'https://x.invalid/b1', name = 'b1' }, { 'https://x.invalid/b2', name = 'b2' } }",
      })
      test.assert_eq(names(loaded), 'a,b1,b2')
      test.assert_eq(loaded[1].lazy, true)
      test.assert_eq(loaded[1].cmd, 'ACmd')
      test.assert_eq(loaded[1][1][1], 'https://x.invalid/a')
    end,
  },

  {
    name = 'import: a folder init.lua that imports its own folder runs once',
    fn = function()
      local mod = modname()
      local root, base = make_root(mod, {
        ['MOD/init.lua'] = table.concat({
          "_G.RS_INIT_RUNS = (_G.RS_INIT_RUNS or 0) + 1",
          "require('resonance').import(..., { root = _G.RS_IMPORT_ROOT, on_error = _G.RS_ON_ERROR })",
          "return { 'https://x.invalid/init', name = 'init' }",
        }, '\n'),
        ['MOD/a.lua'] = "return { 'https://x.invalid/a', name = 'a' }",
      })
      local errors = {}
      _G.RS_INIT_RUNS, _G.RS_IMPORT_ROOT = 0, root
      _G.RS_ON_ERROR = function(name, err) errors[#errors + 1] = name .. ':' .. tostring(err) end
      local resonance = require('resonance')
      local orig = resonance.load
      local loaded = {}
      resonance.load = function(spec) loaded[#loaded + 1] = spec end
      local ok, err = pcall(require, mod)
      resonance.load = orig
      local runs = _G.RS_INIT_RUNS
      _G.RS_INIT_RUNS, _G.RS_IMPORT_ROOT, _G.RS_ON_ERROR = nil, nil, nil
      cleanup(base, mod)
      if not ok then error(err) end
      -- Required as '<mod>.init' it ran twice, hit require's loop error,
      -- and the nested import registered 'a' a second time.
      test.assert_eq(runs, 1)
      test.assert_eq(#errors, 0, table.concat(errors, '; '))
      test.assert_eq(names(loaded), 'a')
    end,
  },

  {
    name = 'import: a non-table entry in a list is reported, the rest still register',
    fn = function()
      local errors = {}
      local loaded = import(modname(), {
        ['MOD/a.lua'] = "return { { 'https://x.invalid/a1', name = 'a1' }, 42, { 'https://x.invalid/a2', name = 'a2' } }",
        ['MOD/b.lua'] = "return { 'https://x.invalid/b', name = 'b' }",
      }, { on_error = function(name, err) errors[#errors + 1] = name .. ':' .. tostring(err) end })
      test.assert_eq(names(loaded), 'a1,a2,b')
      test.assert_eq(#errors, 1)
      test.assert_contains(errors[1], 'not a plugin spec')
    end,
  },

  {
    name = 'import: a non-numeric priority is reported and counts as 0',
    fn = function()
      -- Compared as-is, 'high' > 10 raised inside table.sort, outside any
      -- pcall, and aborted the whole import.
      local errors = {}
      local loaded = import(modname(), {
        ['MOD/a.lua'] = "return { 'https://x.invalid/a', name = 'a', priority = 'high' }",
        ['MOD/b.lua'] = "return { 'https://x.invalid/b', name = 'b', priority = 10 }",
        ['MOD/c.lua'] = "return { 'https://x.invalid/c', name = 'c' }",
      }, { on_error = function(name, err) errors[#errors + 1] = name .. ':' .. tostring(err) end })
      test.assert_eq(names(loaded), 'b,a,c')
      test.assert_eq(#errors, 1)
      test.assert_contains(errors[1], 'priority must be a number')
    end,
  },

  {
    name = 'import: a missing folder notifies instead of raising',
    fn = function()
      local notices = helpers.capture_and_wait(function()
        require('resonance').import('rs_import_missing', { root = vim.fn.tempname() })
      end, 50)
      test.assert_eq(#notices, 1)
      test.assert_contains(notices[1], 'cannot scan')
    end,
  },
})
