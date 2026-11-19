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
-- The capture is installed on two levels:
--
--   - resonance.utils.notify, which is the module's own entry point. The
--     message is recorded the moment the caller reports it, before the
--     deferral, so a test that asserts right after the call sees it.
--
--   - vim.notify, which is the last step of the notification. A module
--     that was loaded in an earlier test holds the utils table of that
--     generation, so patching only the current generation's utils would
--     miss its notifications.
--
-- utils.notify defers through vim.schedule, so a capture that restores the
-- stub immediately would miss anything reported asynchronously. The stub
-- stays installed until the caller is done with it.
function M.with_capture(fn)
  local notices = {}
  local u = M.live().utils
  local orig_utils_notify = u.notify
  local orig_vim_notify = vim.notify

  u.notify = function(msg, ...)
    notices[#notices + 1] = msg
  end
  vim.notify = function(msg, ...)
    notices[#notices + 1] = msg
  end

  local function restore()
    u.notify = orig_utils_notify
    vim.notify = orig_vim_notify
  end

  local ok, err = pcall(fn)
  if not ok then
    restore()
    error(err)
  end
  return notices, restore
end

-- The modules that copy vim.system into a local when they load. A stub
-- installed after they loaded is never seen, so with_system() drops them
-- from package.loaded and the next require builds them against the stub.
-- `resonance.ui` is listed because it requires the actions at load time.
M.SYSTEM_USERS = { 'resonance.ui.actions', 'resonance.ui' }

-- A finished process, shaped like vim.SystemCompleted.
function M.completed(code, stdout, stderr)
  return { code = code or 0, signal = 0, stdout = stdout or '', stderr = stderr or '' }
end

-- Run fn with vim.system replaced by a stub, and always restore it.
--
-- handler(cmd, opts, cb) sees every spawn. It decides what happens to
-- the callback: call it to finish the process, keep it to hold the
-- process open, or ignore it. With no handler, every command succeeds at
-- once with empty output. The stub returns a SystemObj whose wait()
-- reports success.
--
-- fn receives live() modules built against the stub. The real vim.system
-- is put back even when fn raises -- a test that fails half-way used to
-- leave the stub in place for every later test -- and the modules that
-- captured the stub are dropped again so later requires get the real one.
--
--   h.with_system(function(cmd, opts, cb)
--     if cmd[2] == 'fetch' then held[#held + 1] = cb return end
--     cb(h.completed(0))
--   end, function(l)
--     l.actions.check_updates_network()
--   end)
function M.with_system(handler, fn)
  local orig = vim.system
  vim.system = function(cmd, opts, cb)
    if handler then
      handler(cmd, opts, cb)
    elseif cb then
      cb(M.completed(0))
    end
    return {
      pid = 0,
      wait = function() return M.completed(0) end,
      kill = function() end,
      is_closing = function() return false end,
    }
  end
  for i = 1, #M.SYSTEM_USERS do package.loaded[M.SYSTEM_USERS[i]] = nil end

  local ok, err = pcall(fn, M.live())

  vim.system = orig
  for i = 1, #M.SYSTEM_USERS do package.loaded[M.SYSTEM_USERS[i]] = nil end
  if not ok then error(err, 0) end
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

-- The number of entries in a map, whatever the keys are.
--
-- The length operator only counts the array part, so it reports 0 for a
-- table whose keys are all strings, and the wrong number for a sparse
-- integer-keyed table. A map needs to be walked.
function M.map_count(map)
  local n = 0
  for _ in pairs(map or {}) do
    n = n + 1
  end
  return n
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
