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
  local ok, r = pcall(dofile, vim.fn.stdpath('data') .. '/site/pack/core/opt/resonance.nvim/lua/resonance/init.lua')
  if not ok then error('Failed to load installed resonance: ' .. r) end
  r.setup()
  _G.resonance = r
  _G.loader = require('resonance.loader')
  _G.scanner = require('resonance.scanner')
  _G.utils = require('resonance.utils')
end

local function reset_state()
  if _G.loader and _G.loader._reset then _G.loader._reset() end
  if _G.resonance and _G.resonance._reset then _G.resonance._reset() end
  -- Close any open UI window from previous test
  local state = package.loaded['resonance.ui.state']
  if state and state.state and state.state.win and vim.api.nvim_win_is_valid(state.state.win) then
    pcall(vim.api.nvim_win_close, state.state.win, true)
  end
  package.loaded['resonance.ui.state'] = nil
  local state = require('resonance.ui.state')
  if state._reset then state._reset() end
  package.loaded['resonance'] = nil
  package.loaded['resonance.loader'] = nil
  package.loaded['resonance.ui'] = nil
  package.loaded['resonance.ui.state'] = nil
  package.loaded['resonance.ui.render'] = nil
  package.loaded['resonance.ui.actions'] = nil
  package.loaded['resonance.scanner'] = nil
  package.loaded['resonance.utils'] = nil
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
}

load_installed()