-- Tests for resonance.builds -- the build tracker.
--
-- The tracker owns the state of the builds: which plugin is building, how
-- long it has been running, what it printed, and the cross-session lock.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/builds_spec.lua" -c "lua test.print_summary()" -c "qall"

local builds = require('resonance.builds')
local uv = vim.uv

-- A unique name per test, so a test never sees another test's state.
local counter = 0
local function fresh_name(prefix)
  counter = counter + 1
  return prefix .. '-' .. os.time() .. '-' .. counter
end

test.run_suite('resonance.builds', {

  {
    name = 'status: a plugin that was never built has no status',
    fn = function()
      test.assert_nil(builds.status(fresh_name('never')))
    end,
  },

  {
    name = 'start: a build is marked as running',
    fn = function()
      local name = fresh_name('start')
      test.assert_true(builds.start(name))
      test.assert_true(builds.is_running(name))
      test.assert_true(builds.is_building(name))
      test.assert_eq(builds.status(name).state, 'running')
    end,
  },

  {
    name = 'start: a build that is already running is not started again',
    fn = function()
      -- Two concurrent builds of the same plugin write into the same
      -- directory, and two notifications say the same thing twice.
      local name = fresh_name('dup')
      test.assert_true(builds.start(name))
      test.assert_false(builds.start(name), 'a second build was started')
      test.assert_eq(builds.status(name).state, 'running')
    end,
  },

  {
    name = 'finish: the exit code decides the verdict',
    fn = function()
      local ok_name = fresh_name('ok')
      builds.start(ok_name)
      builds.finish(ok_name, true, nil)
      test.assert_eq(builds.status(ok_name).state, 'ok')
      test.assert_nil(builds.status(ok_name).error)

      local fail_name = fresh_name('fail')
      builds.start(fail_name)
      builds.finish(fail_name, false, 'boom')
      test.assert_eq(builds.status(fail_name).state, 'failed')
      test.assert_eq(builds.status(fail_name).error, 'boom')
    end,
  },

  {
    name = 'finish: the output tail is kept',
    fn = function()
      -- The output is what shows a swallowed error: a build that exits 0
      -- while printing errors is a success by the exit code, but the
      -- output is still visible.
      local name = fresh_name('tail')
      builds.start(name)
      builds.append_output(name, 'npm error something\n')
      builds.finish(name, true, nil)
      local status = builds.status(name)
      test.assert_eq(status.state, 'ok')
      test.assert_eq(status.output_tail, 'npm error something\n')
    end,
  },

  {
    name = 'on_complete: the callback fires when the build settles',
    fn = function()
      local name = fresh_name('complete')
      local got = nil
      builds.on_complete(name, function(ok, err) got = { ok = ok, err = err } end)
      builds.start(name)
      builds.finish(name, true, nil)
      test.assert_not_nil(got, 'the callback never fired')
      test.assert_true(got.ok)
    end,
  },

  {
    name = 'on_complete: a callback registered after the build is called right away',
    fn = function()
      -- A caller that registers late must not be left waiting for an
      -- event that already happened.
      local name = fresh_name('late')
      builds.start(name)
      builds.finish(name, true, nil)
      local got = nil
      builds.on_complete(name, function(ok) got = ok end)
      test.assert_not_nil(got, 'the callback never fired')
      test.assert_true(got)
    end,
  },

  {
    name = 'wait: returns when the build settles',
    fn = function()
      local name = fresh_name('wait')
      builds.start(name)
      vim.defer_fn(function() builds.finish(name, true, nil) end, 50)
      local ok, err = builds.wait(name, 3000)
      test.assert_true(ok, 'the wait failed: ' .. tostring(err))
      test.assert_eq(builds.status(name).state, 'ok')
    end,
  },

  {
    name = 'wait: gives up after the timeout, and the build keeps running',
    fn = function()
      -- The wait is bounded. Giving up does not cancel the build: the
      -- build keeps running and still writes its marker when it finishes.
      local name = fresh_name('timeout')
      builds.start(name)
      local ok, err = builds.wait(name, 100)
      test.assert_false(ok, 'the wait did not time out')
      test.assert_not_nil(err)
      test.assert_true(builds.is_running(name), 'the build was cancelled by the wait')
      builds.finish(name, true, nil)
    end,
  },

  {
    name = 'pid_is_alive: a process that does not exist is not alive',
    fn = function()
      test.assert_false(builds.pid_is_alive(nil))
      test.assert_false(builds.pid_is_alive(0))
      test.assert_false(builds.pid_is_alive(-1))
      -- A PID that is almost certainly not in use.
      test.assert_false(builds.pid_is_alive(999999))
    end,
  },

  {
    name = 'pid_is_alive: this process is alive',
    fn = function()
      test.assert_true(builds.pid_is_alive(uv.os_getpid()))
    end,
  },

  {
    name = 'the lock: a lock with a live PID is not taken over',
    fn = function()
      -- Another session is building the plugin. The build must not start
      -- a second one.
      local name = fresh_name('lock-live')
      -- The lock is written with this process's PID, which is alive.
      local acquired = builds.acquire_lock(name, uv.os_getpid())
      test.assert_true(acquired, 'the first lock was not taken')

      -- A second attempt, from another session, sees the live PID.
      builds._reset()
      local second = builds.acquire_lock(name, uv.os_getpid())
      test.assert_false(second, 'a live lock was taken over')
      test.assert_true(builds.is_locked(name))
      builds.release_lock(name)
    end,
  },

  {
    name = 'the lock: a lock with a dead PID is taken over',
    fn = function()
      -- The session that took the lock was killed. The orphaned build
      -- finished without anyone to write its marker, so the next check
      -- has to build again -- a stale lock must not skip the build for
      -- good.
      local name = fresh_name('lock-dead')
      builds.acquire_lock(name, 999999)
      builds._reset()

      local acquired = builds.acquire_lock(name, uv.os_getpid())
      test.assert_true(acquired, 'a stale lock was not taken over')
      test.assert_true(builds.is_locked(name),
        'the lock was not held after it was taken over')
      builds.release_lock(name)
    end,
  },

  {
    name = 'the lock: a lock without a PID is still held',
    fn = function()
      -- The build has started but the child process does not exist yet.
      -- The lock is held all the same.
      local name = fresh_name('lock-nopid')
      test.assert_true(builds.acquire_lock(name, nil))
      test.assert_true(builds.is_locked(name))
      test.assert_true(builds.holds_lock(name))
      builds.release_lock(name)
      test.assert_false(builds.is_locked(name))
    end,
  },

  {
    name = 'the lock: the PID can be written after the lock is taken',
    fn = function()
      -- The lock is taken before the child process exists, and the PID is
      -- written once it does.
      local name = fresh_name('lock-update')
      test.assert_true(builds.acquire_lock(name, nil))
      test.assert_true(builds.update_lock_pid(name, uv.os_getpid()))
      test.assert_true(builds.is_locked(name))
      builds.release_lock(name)
    end,
  },

  {
    name = 'wait: a Ctrl-C ends the wait instead of running to the deadline',
    fn = function()
      -- vim.wait() does not raise on Ctrl-C: it returns false, -2. The
      -- loop ignored the return value, so an interrupted wait carried on
      -- until the deadline. The interrupt is simulated by a vim.wait that
      -- reports it.
      local name = fresh_name('wait-interrupt')
      builds.mark_pending(name)

      local orig_wait = vim.wait
      vim.wait = function() return false, -2 end
      local started = uv.hrtime()
      local ok, ret_ok, err = pcall(builds.wait, name, 2000)
      local elapsed = (uv.hrtime() - started) / 1e6
      vim.wait = orig_wait

      test.assert_true(ok, 'builds.wait raised: ' .. tostring(ret_ok))
      test.assert_false(ret_ok, 'an interrupted wait reported success')
      test.assert_true(tostring(err):find('interrupted', 1, true) ~= nil,
        'the error does not say the wait was interrupted: ' .. tostring(err))
      test.assert_true(elapsed < 500,
        'the interrupted wait ran on for ' .. elapsed .. ' ms')

      builds.forget(name)
    end,
  },
})

test.print_summary()
