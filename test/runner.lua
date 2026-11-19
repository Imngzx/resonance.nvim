-- Test runner for resonance.nvim
-- Usage: nvim --headless -c "luafile test/runner.lua" -c "qall"

local uv = vim.uv
local api = vim.api

local test_results = {
  passed = 0,
  failed = 0,
  errors = {},
}

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s\n  Expected: %s\n  Actual: %s", msg or "Assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(val, msg)
  if not val then
    error(msg or "Expected truthy value")
  end
end

local function assert_not_eq(actual, expected, msg)
  if actual == expected then
    error(string.format("%s\n  Expected: anything but %s", msg or "Assertion failed", vim.inspect(expected)))
  end
end

local function assert_false(val, msg)
  if val then
    error(msg or "Expected falsy value")
  end
end

local function assert_nil(val, msg)
  if val ~= nil then
    error(string.format("%s\n  Expected: nil\n  Actual: %s", msg or "Expected nil", vim.inspect(val)))
  end
end

local function assert_not_nil(val, msg)
  if val == nil then
    error(msg or "Expected non-nil value")
  end
end

local function assert_error(fn, msg)
  local ok, err = pcall(fn)
  if ok then
    error(msg or "Expected function to error")
  end
  if msg and type(msg) == 'string' then
    if not tostring(err):find(msg, 1, true) then
      error(string.format("Expected error containing %q, got: %s", msg, err))
    end
  end
  return err
end

local function assert_contains(haystack, needle, msg)
  if not tostring(haystack):find(tostring(needle), 1, true) then
    error(string.format("%s\n  Expected to contain: %s\n  Actual: %s", msg or "Assertion failed", vim.inspect(needle), vim.inspect(haystack)))
  end
end

local function assert_not_contains(haystack, needle, msg)
  if tostring(haystack):find(tostring(needle), 1, true) then
    error(string.format("%s\n  Expected NOT to contain: %s\n  Actual: %s", msg or "Assertion failed", vim.inspect(needle), vim.inspect(haystack)))
  end
end

-- Load resonance from installed location
local function load_installed()
  -- The isolated env has no user config to packadd it, and the submodules
  -- are found through the runtimepath, so add it the way a config would.
  vim.cmd.packadd('resonance.nvim')
  local ok, r = pcall(dofile, vim.fn.stdpath('data') .. '/site/pack/core/opt/resonance.nvim/lua/resonance/init.lua')
  if not ok then error('Failed to load installed resonance: ' .. r) end
  r.setup()
  _G.resonance = r
  _G.loader = require('resonance.loader')
  _G.scanner = require('resonance.scanner')
  _G.utils = require('resonance.utils')
end

-- The suite exercises the installed copy, not this repo. A stale sync means the
-- tests silently validate old code, so fail loudly instead.
local MODULE_FILES = {
  'init.lua', 'scanner.lua', 'utils.lua', 'registry.lua', 'builds.lua',
  'scandir.lua',
  'loader/init.lua', 'loader/spec.lua', 'loader/triggers.lua',
  'loader/build.lua', 'loader/dag.lua', 'loader/replay.lua',
  'ui/init.lua', 'ui/state.lua', 'ui/render.lua', 'ui/actions.lua',
}

local function installed_root()
  return vim.fn.stdpath('data') .. '/site/pack/core/opt/resonance.nvim'
end

local function assert_trees_in_sync()
  -- Escape hatch for mutation testing, which intentionally edits the installed
  -- copy only. Never set this in normal runs.
  if vim.env.RESONANCE_TEST_ALLOW_STALE == '1' then return end
  local repo_root = vim.fn.getcwd()
  local inst_root = installed_root()
  local stale = {}
  for i = 1, #MODULE_FILES do
    local rel = MODULE_FILES[i]
    local repo_file = repo_root .. '/lua/resonance/' .. rel
    local inst_file = inst_root .. '/lua/resonance/' .. rel
    -- A module missing from the installed copy is as stale as one that
    -- differs: the suite would load whatever else is on the runtimepath.
    if vim.uv.fs_stat(repo_file) and not vim.uv.fs_stat(inst_file) then
      stale[#stale + 1] = rel .. ' (missing)'
    elseif vim.uv.fs_stat(repo_file) then
      local a = table.concat(vim.fn.readfile(repo_file, 'b'), '\n')
      local b = table.concat(vim.fn.readfile(inst_file, 'b'), '\n')
      if a ~= b then stale[#stale + 1] = rel end
    end
  end
  if #stale > 0 then
    error(string.format(
      'Installed resonance is stale for: %s\nInstalled copy: %s\nSync with: test/dev_env.sh sync',
      table.concat(stale, ', '), inst_root))
  end
end

-- The suite installs, builds and overwrites plugins under stdpath('data').
-- Run outside test/dev_env.sh, that is the user's real plugin directory --
-- the copy their editor actually runs -- and their whole config is loaded
-- into the test process. Refuse unless the isolated env is active.
local function assert_isolated_env()
  if vim.env.RESONANCE_TEST_ALLOW_REAL_ENV == '1' then return end
  local dev = vim.env.RESONANCE_DEV_ENV
  local data = vim.fn.stdpath('data')
  if dev and dev ~= '' and data:find(dev, 1, true) == 1 then return end
  error(string.format(
    'Refusing to run the suite against a non-isolated environment (stdpath data: %s).\n'
      .. 'Run it through test/dev_env.sh test, or set RESONANCE_TEST_ALLOW_REAL_ENV=1 to override.',
    data))
end

-- Stub vim.pack so a test can exercise the load path without installing
-- anything. `add` records the specs it was asked to install and reports the
-- plugin as present, so the loader proceeds to packadd and setup.
--
-- Without this, a test that loads a plugin with a fake URL would hit the
-- real vim.pack, fail to install, and the load would abort.
--
-- Only `add` is replaced. `get` delegates to the real vim.pack so the
-- scanner and the fallback tests keep seeing the real plugin set.
--
-- @param opts table|nil { installed = table<string,boolean>, add_error = string|function, add_error_message = string }
-- @return table stub, function restore
local function stub_pack(opts)
  opts = opts or {}
  local installed = opts.installed or {}
  local calls = {}
  local utils = require('resonance.utils')
  local real = utils.get_pack()
  -- The loader verifies an install by stat'ing the plugin directory, so the
  -- stub has to produce a directory that really exists.
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local paths = {}
  local function path_for(name)
    if not paths[name] then
      local dir = root .. '/' .. name
      vim.fn.mkdir(dir, 'p')
      paths[name] = dir
    end
    return paths[name]
  end
  -- The loader looks a plugin up by its extracted name, while `pack.add`
  -- receives the raw spec. Derive the same name the loader would.
  local function spec_name(spec)
    if type(spec) == 'string' then return spec end
    if type(spec) ~= 'table' then return nil end
    if spec.name then return spec.name end
    local src = spec.src or spec[1] or spec.url
    if type(src) ~= 'string' then return nil end
    return src:match('([^/]+)$')
  end
  local stub = {
    calls = calls,
    add = function(specs)
      calls[#calls + 1] = specs
      if opts.add_error then
        -- A function is a predicate: it decides per plugin name, so a test
        -- can fail one install and let the others through.
        if type(opts.add_error) == 'function' then
          for _, spec in ipairs(specs) do
            local name = spec_name(spec)
            if name and opts.add_error(name) then
              error(opts.add_error_message or 'install failed for ' .. name)
            end
          end
        else
          error(opts.add_error)
        end
      end
      for _, spec in ipairs(specs) do
        local name = spec_name(spec)
        if name then
          installed[name] = true
          path_for(name)
        end
      end
      -- The loader caches the plugin directories, and the cache was
      -- built before this install. It has to go, or the loader looks
      -- the plugin up in a cache that does not have it -- and a build
      -- hook for it never finds a directory to build in.
      local registry = package.loaded['resonance.registry']
      if registry and registry.invalidate_plugin_dirs then
        registry.invalidate_plugin_dirs()
      end
    end,
  }
  if real then
    for key, value in pairs(real) do
      if stub[key] == nil then stub[key] = value end
    end
    -- `get` must report the stubbed plugins as installed.
    -- `names` is a flat list of plugin names, or nil for every plugin.
    local real_get = real.get
    stub.get = function(names, opts2)
      if not names then
        -- Every plugin: the real ones, plus the stubbed ones. The
        -- loader's plugin directory cache is built from this call, so a
        -- stubbed plugin that is missing here has no directory -- and a
        -- build hook for it never finds a directory to build in.
        local out = real_get(names, opts2)
        for name in pairs(installed) do
          local known = false
          for i = 1, #out do
            if out[i].spec and out[i].spec.name == name then known = true break end
          end
          if not known then
            out[#out + 1] = {
              spec = { name = name },
              path = path_for(name),
            }
          end
        end
        return out
      end
      local out = {}
      for _, name in ipairs(names) do
        if installed[name] then
          out[#out + 1] = {
            spec = { name = name },
            path = path_for(name),
          }
        end
      end
      return out
    end
  end
  local orig = utils.get_pack
  utils.get_pack = function() return stub end
  return stub, function()
    utils.get_pack = orig
    vim.fn.delete(root, 'rf')
  end
end

local function reset_state()
  if _G.loader and _G.loader._reset then _G.loader._reset() end
  if _G.resonance and _G.resonance._reset then _G.resonance._reset() end
  -- Close any open UI window from the previous test.
  --
  -- The window can belong to an older generation of the state module: the
  -- runner resets package.loaded between tests, so the current instance
  -- knows nothing about a window the previous one created. Reading only
  -- the current instance leaves that window open, and the next open_ui()
  -- then sees a valid window and returns early -- so the test would not
  -- exercise the UI at all. Closing every floating window is the reliable
  -- way to make each test start from a clean slate.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config and config.relative ~= '' then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  package.loaded['resonance.ui.state'] = nil
  local state = require('resonance.ui.state')
  if state._reset then state._reset() end
  package.loaded['resonance'] = nil
  package.loaded['resonance.loader'] = nil
  -- The loader's state lives partly in the replay module, which holds the
  -- fired state. Kept across tests, it would keep the fired state after
  -- the reset.
  package.loaded['resonance.loader.replay'] = nil
  package.loaded['resonance.ui'] = nil
  package.loaded['resonance.ui.state'] = nil
  package.loaded['resonance.ui.render'] = nil
  package.loaded['resonance.ui.actions'] = nil
  package.loaded['resonance.scanner'] = nil
  package.loaded['resonance.scandir'] = nil
  package.loaded['resonance.utils'] = nil
  -- The registry holds the shared state, so it has to start empty. The
  -- loader's _reset() clears most of it, but the load times live there
  -- too, and a leftover entry would show up in the next test.
  package.loaded['resonance.registry'] = nil
  load_installed()
end

local function run_test(name, fn)
  reset_state()
  local ok, err = pcall(fn)
  if ok then
    test_results.passed = test_results.passed + 1
    print(string.format("✓ %s", name))
  else
    test_results.failed = test_results.failed + 1
    table.insert(test_results.errors, {name = name, error = err})
    print(string.format("✗ %s\n  %s", name, err))
  end
end

local function run_suite(name, tests)
  print(string.format("\n=== %s ===", name))
  for _, t in ipairs(tests) do
    run_test(t.name, t.fn)
  end
end

local function print_summary()
  print(string.format("\n=== SUMMARY ==="))
  print(string.format("Passed: %d", test_results.passed))
  print(string.format("Failed: %d", test_results.failed))
  if test_results.failed > 0 then
    print("\nFailures:")
    for _, e in ipairs(test_results.errors) do
      print(string.format("  %s: %s", e.name, e.error))
    end
  else
    print("\nAll tests passed!")
  end
end

local function exit_with_status()
  if test_results.failed > 0 then
    os.exit(1)
  else
    os.exit(0)
  end
end

-- Global test API
_G.test = {
  assert_eq = assert_eq,
  assert_not_eq = assert_not_eq,
  assert_true = assert_true,
  assert_false = assert_false,
  assert_nil = assert_nil,
  assert_not_nil = assert_not_nil,
  assert_error = assert_error,
  assert_contains = assert_contains,
  assert_not_contains = assert_not_contains,
  run_test = run_test,
  run_suite = run_suite,
  print_summary = print_summary,
  exit_with_status = exit_with_status,
  assert_trees_in_sync = assert_trees_in_sync,
  stub_pack = stub_pack,
}

assert_isolated_env()
assert_trees_in_sync()
load_installed()