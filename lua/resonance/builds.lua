-- The build tracker.
--
-- This module owns the state of the builds: which plugin is building, how
-- long it has been running, what it printed, and whether it succeeded. The
-- mechanics -- running the command, writing the marker -- live in
-- `loader/build.lua`. This module holds state and answers questions about
-- it, and nothing else.
--
-- It is a separate module, and not part of the loader, for the same reason
-- `registry.lua` is: the state has to be reachable without dragging in the
-- control plane. A user script or a UI panel can ask "is this plugin still
-- building?" without requiring the loader, and without the loader's
-- require-time side effects.
--
-- There is no require-time side effect here either: no autocmds, no I/O,
-- no vim.async. The module is a plain table.

local M = {}

local uv = vim.uv
local hrtime = uv.hrtime
local fs_open = uv.fs_open
local fs_write = uv.fs_write
local fs_close = uv.fs_close
local fs_mkdir = uv.fs_mkdir
local fs_stat = uv.fs_stat
local fs_unlink = uv.fs_unlink
local fs_scandir = uv.fs_scandir
local fs_scandir_next = uv.fs_scandir_next
local kill = uv.kill
local schedule = vim.schedule
local type = type
local tostring = tostring
local tonumber = tonumber
local table_concat = table.concat
local fn_stdpath = vim.fn.stdpath

-- How long a build may run before it is killed. A build that runs for ten
-- minutes is stuck, not slow: the dependencies are not going to arrive.
-- The build is killed and marked failed, and no marker is written, so the
-- next check tries again.
M.HARD_TIMEOUT_MS = 10 * 60 * 1000

-- How long a build may run before the user is told that it is still going.
-- A build that finishes in a fraction of a second never says anything --
-- the notification would be noise.
M.NOTIFY_THRESHOLD_MS = 4000

-- The states a build goes through.
--
--   pending  the build is queued but has not started
--   running  the build is running
--   ok       the build finished and the exit code was 0
--   failed   the build finished with a non-zero exit code, or the Lua
--            hook raised
--
M.STATES = { pending = true, running = true, ok = true, failed = true }

-- Stop and close a hard-timeout timer.
--
-- A luv handle stays registered with the event loop until it is closed:
-- stopping it alone leaks one timer per build for the whole session.
local function close_timer(timer)
  if not timer then return end
  pcall(uv.timer_stop, timer)
  if not timer:is_closing() then timer:close() end
end

-- The build state, keyed by plugin name.
local builds = {}

-- The callbacks waiting for a build to settle, keyed by plugin name.
local waiters = {}

-- The cross-session lock files, keyed by plugin name.
--
-- A lock holds the PID of the build's child process. The PID is checked
-- for liveness before the lock is trusted: a Neovim that was killed leaves
-- the lock behind, and a lock that is trusted forever would skip the
-- build for good.
--
-- The PID is `false` while the build has started but the child process
-- does not exist yet. A lock in that state is still held.
local locks = {}

-- The locks this session holds, whether or not they have a PID yet.
local held_locks = {}

-- The directory the lock files live in.
local lock_dir = nil

---@return string
local function get_lock_dir()
  if lock_dir then return lock_dir end
  lock_dir = fn_stdpath('state') .. '/resonance/locks'
  return lock_dir
end

-- The tail of the output is kept, not the whole output. A build that prints
-- a megabyte of progress does not need it all kept alive for the rest of
-- the session.
local OUTPUT_TAIL_BYTES = 4096

--- Keep the last part of a stream, so the useful part survives.
---
--- A build that prints a lot keeps growing the tail until it is trimmed.
--- The trim is cheap and only happens when the tail is over the limit, so
--- the common case -- a short build -- never copies anything.
---@param tail string|nil
---@param chunk string|nil
---@return string
local function append_output(tail, chunk)
  if not chunk or chunk == '' then return tail or '' end
  local out = (tail or '') .. chunk
  if #out <= OUTPUT_TAIL_BYTES then return out end
  -- Keep the tail end: the error is at the end of the output.
  return out:sub(-OUTPUT_TAIL_BYTES)
end

---@param name string
---@return table
local function ensure_build(name)
  local b = builds[name]
  if not b then
    b = {
      state = 'pending',
      started_at = nil,
      finished_at = nil,
      error = nil,
      output_tail = nil,
      pid = nil,
      notified = false,
      hard_timeout = nil,
    }
    builds[name] = b
  end
  return b
end

--- The status of a build.
---
--- A plugin that has never been built has no status: the function returns
--- nil rather than a made-up "pending" entry.
---@param name string
---@return table|nil status { state, started_at, elapsed, error, output_tail, pid }
function M.status(name)
  local b = builds[name]
  if not b then return nil end
  local elapsed = nil
  if b.started_at then
    local end_at = b.finished_at or hrtime()
    elapsed = (end_at - b.started_at) / 1e6
  end
  return {
    state = b.state,
    started_at = b.started_at,
    elapsed = elapsed,
    error = b.error,
    output_tail = b.output_tail,
    pid = b.pid,
  }
end

--- Whether a build is running right now.
---@param name string
---@return boolean
function M.is_running(name)
  local b = builds[name]
  return b ~= nil and b.state == 'running'
end

--- Whether any build is running.
---@return boolean
function M.is_busy()
  for _, b in pairs(builds) do
    if b.state == 'running' then return true end
  end
  return false
end

--- The names of the plugins whose build is running.
---@return string[]
function M.running()
  local out = {}
  for name, b in pairs(builds) do
    if b.state == 'running' then out[#out + 1] = name end
  end
  return out
end

--- Register a callback for when a build settles.
---
--- The callback is called with the result. If the build has already
--- settled, it is called right away -- a caller that registers late must
--- not be left waiting for an event that already happened.
---@param name string
---@param fn fun(ok: boolean, err: string|nil)
function M.on_complete(name, fn)
  if type(fn) ~= 'function' then return end
  local b = builds[name]
  if b and b.state ~= 'pending' and b.state ~= 'running' then
    fn(b.state == 'ok', b.error)
    return
  end
  local list = waiters[name]
  if not list then
    list = {}
    waiters[name] = list
  end
  list[#list + 1] = fn
end

--- Mark a build as pending.
---
--- The build is marked as pending before it is scheduled to run, so a
--- caller that checks the status between the call and the start already
--- sees that a build is coming. The loader uses this to decide whether
--- the plugin's setup has to wait.
---@param name string
---@return boolean marked false when a build was already pending or running
function M.mark_pending(name)
  local b = builds[name]
  if b and (b.state == 'pending' or b.state == 'running') then return false end
  b = ensure_build(name)
  b.state = 'pending'
  b.started_at = nil
  b.finished_at = nil
  b.error = nil
  b.output_tail = nil
  b.pid = nil
  b.notified = false
  close_timer(b.hard_timeout)
  b.hard_timeout = nil
  return true
end

--- Whether a build is pending or running for a plugin.
---@param name string
---@return boolean
function M.is_building(name)
  local b = builds[name]
  return b ~= nil and (b.state == 'pending' or b.state == 'running')
end

--- Mark a build as started.
---
--- A build that is already running is not started again: two concurrent
--- builds of the same plugin write into the same directory, and two
--- notifications say the same thing twice.
---@param name string
---@param pid number|nil The child process id, when there is one.
---@return boolean started false when a build was already running
function M.start(name, pid)
  local b = builds[name]
  if b and b.state == 'running' then return false end
  b = ensure_build(name)
  b.state = 'running'
  b.started_at = hrtime()
  b.finished_at = nil
  b.error = nil
  b.output_tail = nil
  b.pid = pid
  b.notified = false
  close_timer(b.hard_timeout)
  b.hard_timeout = nil
  return true
end

--- Mark a build as finished.
---@param name string
---@param ok boolean
---@param err string|nil
---@param output_tail string|nil
function M.finish(name, ok, err, output_tail)
  local b = builds[name]
  if not b then b = ensure_build(name) end
  b.state = ok and 'ok' or 'failed'
  b.finished_at = hrtime()
  b.error = err
  b.output_tail = output_tail or b.output_tail
  b.pid = nil
  if b.hard_timeout then
    close_timer(b.hard_timeout)
    b.hard_timeout = nil
  end

  local list = waiters[name]
  waiters[name] = nil
  if list then
    for i = 1, #list do
      local ok_call, call_err = pcall(list[i], ok, err)
      if not ok_call then
        schedule(function()
          vim.notify('Build callback error for ' .. name .. ': ' .. tostring(call_err),
            vim.log.levels.ERROR)
        end)
      end
    end
  end
end

--- Append to a build's output tail.
---@param name string
---@param chunk string|nil
function M.append_output(name, chunk)
  local b = builds[name]
  if not b then b = ensure_build(name) end
  b.output_tail = append_output(b.output_tail, chunk)
end

--- Set the child process id of a running build.
---@param name string
---@param pid number|nil
function M.set_pid(name, pid)
  local b = builds[name]
  if not b then b = ensure_build(name) end
  b.pid = pid
end

--- Start the hard timeout for a build.
---
--- The timer kills the build when it fires. The callback is given so the
--- caller can do the killing -- this module does not run processes.
---@param name string
---@param on_timeout fun(name: string)
---@param timeout_ms number|nil defaults to HARD_TIMEOUT_MS
function M.arm_hard_timeout(name, on_timeout, timeout_ms)
  local b = builds[name]
  if not b then b = ensure_build(name) end
  if b.hard_timeout then close_timer(b.hard_timeout) end
  local timer = uv.new_timer()
  if not timer then return end
  b.hard_timeout = timer
  timer:start(timeout_ms or M.HARD_TIMEOUT_MS, 0, function()
    -- A one-shot timer is done once it fires. It is closed here unless a
    -- newer timer has replaced it, which closed this one already.
    if b.hard_timeout == timer then b.hard_timeout = nil end
    close_timer(timer)
    -- The timer runs on the libuv thread, so the kill has to be scheduled
    -- onto the main loop.
    schedule(function()
      local current = builds[name]
      if not current or current.state ~= 'running' then return end
      on_timeout(name)
    end)
  end)
end

--- Stop the hard timeout of a build.
---@param name string
function M.disarm_hard_timeout(name)
  local b = builds[name]
  if b and b.hard_timeout then
    close_timer(b.hard_timeout)
    b.hard_timeout = nil
  end
end

--- Wait for a build to settle.
---
--- The event loop is pumped while waiting, so the editor stays responsive.
--- The wait is bounded: it gives up after `timeout_ms`, and the build
--- keeps running. Cancelling the wait does not cancel the build.
---
--- A Ctrl-C ends the wait. vim.wait() does not raise on an interrupt: it
--- returns `false, -2`, so the return value has to be checked, or the loop
--- carries on until the deadline. The build is left running -- the user
--- cancelled the wait, not the build.
---@param name string
---@param timeout_ms number|nil defaults to 30 seconds
---@return boolean ok, string|nil err
function M.wait(name, timeout_ms)
  local b = builds[name]
  if not b then return true, nil end
  if b.state ~= 'pending' and b.state ~= 'running' then
    return b.state == 'ok', b.error
  end

  local deadline = hrtime() + (timeout_ms or 30000) * 1e6
  while true do
    local current = builds[name]
    if not current then return true, nil end
    if current.state ~= 'pending' and current.state ~= 'running' then
      return current.state == 'ok', current.error
    end
    if hrtime() >= deadline then
      return false, 'timed out waiting for the build of ' .. name
    end
    -- vim.wait pumps the event loop, so the build's completion callback
    -- gets to run while the wait is in progress.
    local _, reason = vim.wait(50, function()
      local c = builds[name]
      return c == nil or (c.state ~= 'pending' and c.state ~= 'running')
    end, 10)
    if reason == -2 then
      return false, 'interrupted waiting for the build of ' .. name
    end
  end
end

--- Forget a build's state.
---
--- The state of a finished build is not needed any more, and keeping it
--- for the rest of the session holds onto the output tail.
---@param name string
function M.forget(name)
  local b = builds[name]
  if b and b.hard_timeout then
    close_timer(b.hard_timeout)
  end
  builds[name] = nil
  waiters[name] = nil
end

--------------------------------------------------------------------------------
-- The cross-session lock
--------------------------------------------------------------------------------

--- The lock file for a plugin.
---@param name string
---@return string
local function lock_path(name)
  local safe = tostring(name):match('[^/]+$') or ''
  if safe == '' or safe == '.' or safe == '..' then safe = '_' end
  return get_lock_dir() .. '/' .. safe
end

--- Whether a process is alive.
---
--- `kill(pid, 0)` does not send a signal; it only asks whether the process
--- exists. A process that exists but belongs to another user reports
--- EPERM -- that is still alive, so it counts as alive.
---@param pid number|nil
---@return boolean
function M.pid_is_alive(pid)
  if not pid or pid <= 0 then return false end
  local ok, _, code = kill(pid, 0)
  if ok == 0 then return true end
  -- ESRCH means the process is gone. EPERM means it is there but owned by
  -- someone else. Anything else is treated as alive, so a lock is not
  -- dropped on a transient error.
  return code == 'EPERM'
end

--- Take the build lock for a plugin.
---
--- The lock holds the PID of the build's child process. A second Neovim
--- session sees the lock, checks that the PID is still alive, and skips
--- the build if it is: two sessions building the same plugin at the same
--- time write into the same directory.
---
--- A lock whose PID is gone is stale -- the session that took it was
--- killed -- and is taken over. The marker is not written in that case,
--- because the orphaned build finished without anyone to record it, so
--- the next check has to build again.
---@param name string
---@param pid number|nil
---@return boolean acquired
function M.acquire_lock(name, pid)
  local path = lock_path(name)

  if held_locks[name] then
    -- This session already holds the lock. The PID is simply updated.
    return M.update_lock_pid(name, pid)
  end

  -- The lock may be left over from another session.
  local fd = fs_open(path, 'r', 438)
  if fd then
    local stat = uv.fs_fstat(fd)
    local content = stat and (uv.fs_read(fd, stat.size, 0) or '') or ''
    fs_close(fd)
    local locked_pid = tonumber(content)
    if locked_pid and M.pid_is_alive(locked_pid) then
      -- Another session is building this plugin right now.
      locks[name] = locked_pid
      return false
    end
    -- The lock is stale -- the process that held it is gone. It is
    -- removed, and the build goes ahead: the orphaned build finished
    -- without anyone to write its marker, so the next check has to
    -- build again.
    pcall(fs_unlink, path)
  end

  local dir = get_lock_dir()
  if not fs_stat(dir) then
    local parent = fn_stdpath('state') .. '/resonance'
    if not fs_stat(parent) then fs_mkdir(parent, 493) end
    if not fs_stat(dir) then fs_mkdir(dir, 493) end
  end

  local out = fs_open(path, 'w', 438)
  if not out then return false end
  fs_write(out, tostring(pid or ''), 0)
  fs_close(out)
  locks[name] = pid or false
  held_locks[name] = true
  return true
end

--- Release the build lock for a plugin.
---@param name string
function M.release_lock(name)
  locks[name] = nil
  held_locks[name] = nil
  pcall(fs_unlink, lock_path(name))
end

--- Record the child process id in a lock that is already held.
---
--- The lock is taken before the child process exists, because the build
--- has to decide whether to start at all. The PID is written once the
--- child is running, so another session can probe it for liveness.
---@param name string
---@param pid number|nil
---@return boolean updated
function M.update_lock_pid(name, pid)
  -- The lock has to be held already. A lock that is not held means another
  -- session owns the build, and writing to it would steal it.
  if not held_locks[name] then return false end
  local path = lock_path(name)
  local fd = fs_open(path, 'w', 438)
  if not fd then return false end
  fs_write(fd, tostring(pid or ''), 0)
  fs_close(fd)
  locks[name] = pid or false
  return true
end

--- Whether this session holds the lock for a plugin.
---
--- A lock that was taken without a PID is held too: the build has started
--- but the child process does not exist yet.
---@param name string
---@return boolean
function M.holds_lock(name)
  return held_locks[name] == true
end

--- Whether the plugin is locked by a live build.
---@param name string
---@return boolean
function M.is_locked(name)
  -- A lock this session holds is live by definition: the build is
  -- running, or is about to run.
  if held_locks[name] then return true end
  local fd = fs_open(lock_path(name), 'r', 438)
  if not fd then return false end
  local stat = uv.fs_fstat(fd)
  local content = stat and (uv.fs_read(fd, stat.size, 0) or '') or ''
  fs_close(fd)
  local locked_pid = tonumber(content)
  if not locked_pid then
    -- The lock has no PID yet: the build started but the child process
    -- does not exist. It is live.
    return content ~= ''
  end
  if not M.pid_is_alive(locked_pid) then
    -- Stale: the process that held the lock is gone.
    pcall(fs_unlink, lock_path(name))
    return false
  end
  return true
end

--- List the lock files that are left over, for diagnostics.
---@return string[]
function M.stale_locks()
  local out = {}
  local dir = get_lock_dir()
  local entries = fs_scandir(dir)
  if not entries then return out end
  while true do
    local entry = fs_scandir_next(entries)
    if not entry then break end
    local fd = fs_open(dir .. '/' .. entry, 'r', 438)
    if fd then
      local stat = uv.fs_fstat(fd)
      local content = stat and (uv.fs_read(fd, stat.size, 0) or '') or ''
      fs_close(fd)
      local pid = tonumber(content)
      if pid and not M.pid_is_alive(pid) then
        out[#out + 1] = entry
      end
    end
  end
  return out
end

--- Forget everything.
---
--- For testing.
function M._reset()
  for name, b in pairs(builds) do
    if b.hard_timeout then close_timer(b.hard_timeout) end
  end
  builds = {}
  waiters = {}
  locks = {}
  held_locks = {}
end

return M
