-- Shared helpers for the resonance.nvim test suites.
--
-- These are behavioral helpers, not assertions: they set up state and record
-- what happened, so a test can assert on an observable outcome.
--
-- Loaded by the spec files that need them. The runner resets
-- package.loaded between tests, so module tables captured here can be a
-- different generation than the one under test -- always re-require inside a
-- test (via `live()`) when touching module state.

local api = vim.api

local M = {}

-- The module tables under test, re-required at call time.
--
-- The runner clears package.loaded between tests, so module tables captured
-- at file scope can be a different generation than the one under test.
function M.live()
  return {
    resonance = require('resonance'),
    loader = require('resonance.loader'),
    dag = require('resonance.loader.dag'),
    scanner = require('resonance.scanner'),
    state = require('resonance.ui.state'),
    actions = require('resonance.ui.actions'),
    utils = require('resonance.utils'),
  }
end

-- Capture notifications emitted by the module under test.
--
-- utils.notify defers through vim.schedule, so a capture that restores the
-- stub immediately would miss anything reported asynchronously. The stub
-- stays installed until the caller is done with it.
function M.with_capture(fn)
  local u = M.live().utils
  local notices = {}
  local orig_notify = u.notify
  u.notify = function(msg, ...)
    notices[#notices + 1] = msg
  end
  local ok, err = pcall(fn)
  if not ok then
    u.notify = orig_notify
    error(err)
  end
  return notices, function()
    u.notify = orig_notify
  end
end

-- Wait for scheduled notifications to arrive, then release the capture.
function M.capture_and_wait(fn, ms)
  local notices, release = M.with_capture(fn)
  vim.wait(ms or 1000)
  release()
  return notices
end

-- True when any captured notice contains the given text.
function M.noticed(notices, text)
  for i = 1, #notices do
    if notices[i]:find(text, 1, true) then return true end
  end
  return false
end

-- A scratch group for autocmds created by a test.
function M.scratch_group(name)
  return api.nvim_create_augroup(name, { clear = true })
end

-- Events recorded by a handler, in the order they fire.
function M.recorder(event, opts)
  opts = opts or {}
  local seen = {}
  local group = opts.group or M.scratch_group(opts.group_name or 'ResonanceBehavior')
  api.nvim_create_autocmd(event, {
    group = group,
    buffer = opts.buffer,
    callback = function(args)
      seen[#seen + 1] = { event = args.event, buf = args.buf, match = args.match }
    end,
  })
  return seen
end

function M.count(seen)
  return #seen
end

-- A throwaway git repository with one commit. check_updates_network runs a
-- real `git fetch`, which only completes against a real repository.
function M.make_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.system({ 'git', 'init', '-q', dir })
  vim.fn.writefile({ 'x' }, dir .. '/file.txt')
  vim.fn.system({ 'git', '-C', dir, 'add', '.' })
  vim.fn.system({
    'git', '-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
    'commit', '-q', '-m', 'initial',
  })
  return dir
end

return M
