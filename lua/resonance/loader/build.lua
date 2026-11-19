local M = {}
local utils = require('resonance.utils')
local builds = require('resonance.builds')

local uv = vim.uv
local fs_open = uv.fs_open
local fs_fstat = uv.fs_fstat
local fs_read = uv.fs_read
local fs_write = uv.fs_write
local fs_close = uv.fs_close
local fs_stat = uv.fs_stat
local fs_unlink = uv.fs_unlink
local system = vim.system
local schedule = vim.schedule
local type = type
local tostring = tostring
local fn_stdpath = vim.fn.stdpath
local nvim_echo = vim.api.nvim_echo
local math_floor = math.floor

-- How many build commands run at once. Set by configure().
local DEFAULT_CONCURRENCY = 2
local concurrency = DEFAULT_CONCURRENCY

-- Report each build as a progress message. Set by configure().
local progress_enabled = true

-- Built on first use; see get_semaphore() below.
local build_semaphore = nil

-- The child process of the build that is running, keyed by plugin name.
--
-- The hard timeout has to kill the child, and the lock file has to hold
-- its PID. The SystemObj is what carries both.
local running_objects = {}

-- How often a build waiting on another session's lock checks it again.
M.LOCK_POLL_MS = 500

-- vim.async costs ~1.4 ms to load: it pulls in seven submodules. The
-- loader requires this module at setup time, but a build only runs for
-- a plugin that has a build hook and whose hash changed -- rarely, and
-- never at startup for most setups.
--
-- So the async machinery is built on first use rather than at require
-- time. The cost then lands on the build that needs it, not on every
-- Neovim startup.
--
-- @return table The vim.async module.
local function get_async()
  return vim.async
end

-- Read through this function, never through the upvalue: configure() drops
-- the semaphore to apply a new limit, and a build that was waiting on a
-- lock when that happened must still find one.
local function get_semaphore()
  if not build_semaphore then
    build_semaphore = get_async().semaphore(concurrency)
  end
  return build_semaphore
end

--- Apply the `build` section of the user config.
---
--- A semaphore cannot be resized, so a new limit replaces it. Builds that
--- already hold a slot keep it; the limit applies to the builds that start
--- after this call.
---@param opts? { concurrency?: integer, progress?: boolean }
function M.configure(opts)
  opts = opts or {}
  local n = opts.concurrency
  if n == nil then n = DEFAULT_CONCURRENCY end
  if type(n) ~= 'number' or n < 1 or n ~= math_floor(n) or n == math.huge then
    utils.notify('build.concurrency must be a positive integer, got ' .. tostring(n) ..
      '; using ' .. DEFAULT_CONCURRENCY, vim.log.levels.WARN)
    n = DEFAULT_CONCURRENCY
  end
  if n ~= concurrency then
    concurrency = n
    build_semaphore = nil
  end
  progress_enabled = opts.progress ~= false
end

--- The number of build commands allowed to run at once.
---@return integer
function M.concurrency()
  return concurrency
end

-- The builds in flight, reported as one progress message
-- (|progress-message|) with a count, the way vim.pack reports an install:
-- "Building (1/3) blink.cmp". A batch is every build that starts while
-- another is still running; the first build after a batch settles starts
-- a new one, and the count starts over.
--
-- The message says only what is happening. The result -- which plugin
-- built, which failed and why -- is the notification's job; repeating it
-- here would show it twice. The last update still carries a final status,
-- because a progress message left on "running" is a spinner that never
-- stops. Its text only sums the batch up: "Build done", "Build failed", or
-- "Build failed partially"; the notifications name the plugins.
local batch = { total = 0, done = 0, failed = 0 }

-- Scheduled: the build task runs in a fast-event context, where nvim_echo
-- is not allowed. The schedule queue is FIFO, so the updates arrive in the
-- order they were sent. pcall, because the progress fields are recent and
-- a nightly that predates them raises on them.
---@param status 'running'|'success'|'failed'
---@param text string
local function report(status, text, name)
  if not progress_enabled then return end
  local total, done, failed = batch.total, batch.done, batch.failed
  schedule(function()
    pcall(nvim_echo, { { text } }, false, {
      id = 'resonance.build',
      kind = 'progress',
      status = status,
      percent = math_floor(done / total * 100),
      title = 'Resonance',
      source = 'resonance',
      data = { plugin = name, done = done, total = total, failed = failed },
    })
  end)
end

-- For tests: a build an earlier test left unsettled would hold its batch
-- open, and the next test's count would include it.
function M._reset_batch()
  batch.total, batch.done, batch.failed = 0, 0, 0
end

local function count()
  return '(' .. batch.done .. '/' .. batch.total .. ')'
end

-- A build has started: it joins the running batch, or opens a new one.
---@param name string
local function batch_start(name)
  if batch.done == batch.total then
    batch.total, batch.done, batch.failed = 0, 0, 0
  end
  batch.total = batch.total + 1
  report('running', 'Building ' .. count() .. ' ' .. name, name)
end

-- A build has settled. The last one of the batch closes the message.
---@param ok boolean
local function batch_settle(ok)
  batch.done = batch.done + 1
  if not ok then batch.failed = batch.failed + 1 end
  if batch.done < batch.total then
    report('running', 'Building ' .. count())
    return
  end
  if batch.failed == 0 then
    report('success', 'Build done')
  elseif batch.failed == batch.total then
    report('failed', 'Build failed')
  else
    report('failed', 'Build failed partially')
  end
end

--- Run a command, and wait for it without blocking the editor.
---
--- The wait yields to the event loop, so other work -- other builds, the
--- UI, the user's keystrokes -- keeps running while the command runs.
---
--- The result is the completed command: its exit code, and its output.
--- A command that fails is not an error here: the exit code is the
--- verdict, and the caller decides what to do with it.
---
--- The child process's PID is reported through `on_start`, so the caller
--- can write it into the lock file and kill it on a timeout.
---@param cmd string[]
---@param opts table
---@param on_start? fun(handle: table) Called once the child process exists.
---@return table result { code, stdout, stderr }
local function run_command(cmd, opts, on_start)
  local async = get_async()

  -- The awaitable starts the process and returns its handle. The handle is
  -- a closable, so async closes it if the task is cancelled -- which is
  -- how a cancelled build kills its child.
  local ok, result = async.pawait(1, function(callback)
    local handle = system(cmd, opts, callback)
    if on_start then on_start(handle) end
    return handle
  end)

  if not ok then
    return { code = -1, stdout = '', stderr = tostring(result) }
  end
  return result or { code = -1, stdout = '', stderr = 'command did not run' }
end

M.build_hooks = {}

-- The directory the build markers live in.
--
-- The marker used to be written into the plugin's own directory, which
-- dirtied its git working tree -- a file the plugin's own tooling did not
-- put there, showing up in `git status` and in every diff. The markers
-- belong to Resonance, so they live in Resonance's state directory.
local marker_dir = nil

---@return string
local function get_marker_dir()
  if marker_dir then return marker_dir end
  marker_dir = fn_stdpath('state') .. '/resonance/builds'
  return marker_dir
end

--- The marker file for a plugin.
---
--- The name is used as a file name, so it is reduced to its last path
--- segment. A name with a slash in it used to build a path in a
--- directory that does not exist, and the write was silently dropped --
--- the build cache was lost, and the plugin rebuilt on every check.
--- A name with a traversal in it was worse: it wrote outside the marker
--- directory.
---
--- vim.pack already reduces a name this way, so the two agree for every
--- plugin that came through it.
---@param name string
---@return string
local function marker_path(name)
  local safe = tostring(name):match('[^/]+$') or ''
  -- A name that reduces to a path traversal would write outside the marker
  -- directory, so the two relative names are replaced as well.
  if safe == '' or safe == '.' or safe == '..' then safe = '_' end
  return get_marker_dir() .. '/' .. safe
end

--- Mark build as successful by writing hash to file
---@param name string Plugin name.
---@param hash string
function M.mark_build_success(name, hash)
  local dir = get_marker_dir()
  if not fs_stat(dir) then
    vim.fn.mkdir(dir, 'p')
  end
  local fd = fs_open(marker_path(name), 'w', 438)
  if fd then
    fs_write(fd, hash, 0)
    fs_close(fd)
  end
end

--- Read the hash a plugin was last built at.
---@param name string Plugin name.
---@return string
local function read_marker(name)
  local fd = fs_open(marker_path(name), 'r', 438)
  if not fd then return '' end
  local stat = fs_fstat(fd)
  local content = stat and (fs_read(fd, stat.size, 0) or '') or ''
  fs_close(fd)
  return content
end

--- Forget that a plugin was built.
---
--- The marker has to go when the plugin itself goes. The build artifacts
--- live inside the plugin directory, so uninstalling the plugin deletes
--- them -- but the marker is in Resonance's own state directory and
--- outlives the plugin.
---
--- A reinstall of the same version then lands on the same commit, so the
--- marker still matched and the build was skipped. The plugin came back
--- without its artifacts: no compiled native module, no installed
--- dependencies, no generated files.
---@param name string Plugin name.
function M.clear_build_marker(name)
  local path = marker_path(name)
  local ok, err = fs_unlink(path)
  if ok then return end
  -- The file may not be there, which is the normal case: the plugin was
  -- never built, or its marker was already dropped. Anything else is
  -- worth saying out loud.
  if type(err) == 'string' and err:find('ENOENT', 1, true) then return end
  schedule(function()
    utils.notify('Could not remove the build marker for ' .. name .. ': ' .. tostring(err), vim.log.levels.WARN)
  end)
end

-- Run build command for a plugin
---@param name string
---@param dir string
---@param build_task string|function
---@param curr_hash string
---@param on_done? fun(ok: boolean, err: string|nil) Called once the build settles.
function M.run_build(name, dir, build_task, curr_hash, on_done)
  if not dir or dir == '' then return end

  -- Check if already built at this hash (early return)
  local last_hash = read_marker(name)

  if last_hash == curr_hash then
    if on_done then on_done(true, nil) end
    return
  end

  -- A build that is already running is not started again.
  --
  -- check_and_build() is called from two places: the loader, when it
  -- registers the build hook, and the PackChanged handler, when the
  -- plugin is installed. The second call landed while the first was
  -- still running, so two builds of the same plugin wrote into the same
  -- directory at the same time, and two "Build succeeded" notifications
  -- said the same thing twice.
  if builds.is_building(name) then
    -- The caller waits for the build that is already running, rather than
    -- starting a second one.
    if on_done then
      builds.on_complete(name, function(ok, err) on_done(ok, err) end)
    end
    return
  end

  -- The build is marked as pending before it is scheduled to run, so a
  -- caller that checks the status right after this call already sees that
  -- a build is coming. The loader uses that to decide whether the
  -- plugin's setup has to wait for the build.
  builds.mark_pending(name)

  -- The first verdict wins. On a hard timeout the timer reports the
  -- failure, and then the killed child exits and the task reports a second
  -- one: two notifications, the timeout reason overwritten by the exit
  -- code, and -- for a Lua hook the timer cannot kill -- a late success
  -- that wrote the marker after the failure. A late second report could
  -- also overwrite the state of a newer build of the same plugin.
  local settled = false
  local started = false

  ---@param quiet? boolean settle without a notification
  local function finish(ok, err, output_tail, quiet)
    if settled then return end
    settled = true

    -- The verdict is the exit code, and nothing else.
    --
    -- stderr being non-empty is not a failure: yarn, npm, cargo and make
    -- all write warnings and progress to stderr on a successful build.
    -- The output is kept as the tail of both streams so a swallowed
    -- error is still visible to the user.
    builds.finish(name, ok, err, output_tail)

    -- The lock is released, so another session can build the plugin once
    -- this build is done. It is also disarmed: a build that is over must
    -- not be killed by a timer that is still armed.
    builds.disarm_hard_timeout(name)
    -- Only a lock this session holds is released. A build that gave up
    -- waiting on another session's lock must not delete that lock.
    if builds.holds_lock(name) then builds.release_lock(name) end
    running_objects[name] = nil

    -- `started` is false for a build that never got past builds.start():
    -- it sent no running message, so there is nothing to close.
    if started then batch_settle(ok) end

    if ok then
      M.mark_build_success(name, curr_hash)
      if quiet then
        if on_done then on_done(ok, err) end
        return
      end
      schedule(function()
        utils.notify('Build succeeded for ' .. name, vim.log.levels.INFO)
      end)
    else
      schedule(function()
        local msg = 'Build failed for ' .. name .. ': ' .. tostring(err)
        local status = builds.status(name)
        local tail = status and status.output_tail
        if tail and tail ~= '' then
          msg = msg .. '\n' .. tail
        end
        utils.notify(msg, vim.log.levels.ERROR)
      end)
    end
    if on_done then on_done(ok, err) end
  end

  schedule(function()
    local build_run = get_async().run('resonance_build:' .. name, function()
      -- The build is marked as running before the command starts, so a
      -- second check_and_build() in the same tick sees it and does not
      -- start a second build.
      if not builds.start(name) then return end
      started = true
      batch_start(name)

      -- The lock keeps a second Neovim session from building the same
      -- plugin at the same time. The PID is the child process, so a
      -- session that was killed leaves a lock whose PID is gone -- the
      -- lock is stale, and the build goes ahead again.
      --
      -- The lock is taken without a PID first, because the child process
      -- does not exist yet. It is rewritten with the PID once the command
      -- starts, so a second session can tell that the build is alive.
      local locked = builds.acquire_lock(name, nil)
      if not locked then
        -- Another session is building this plugin right now. Two builds of
        -- the same plugin must not write into the same directory, so this
        -- one waits for the lock -- and stays "running" meanwhile.
        --
        -- It used to report the build as succeeded straight away. The
        -- loader took that as "the build is done" and ran setup() against
        -- the tree the other session was still building.
        report('running', 'Building ' .. count() .. ' ' .. name .. ': waiting for another Neovim session', name)
        local async = get_async()
        local deadline = uv.hrtime() + builds.HARD_TIMEOUT_MS * 1e6
        while not locked do
          if uv.hrtime() >= deadline then
            error('another Neovim session is still building ' .. name, 0)
          end
          async.sleep(M.LOCK_POLL_MS)
          locked = builds.acquire_lock(name, nil)
        end
        -- The other session may have finished the same build. The marker
        -- directory is shared, so its marker says whether it did.
        if read_marker(name) == curr_hash then
          finish(true, nil, nil, true)
          return
        end
      end

      -- The hard timeout kills the build if it runs too long. A build that
      -- runs for ten minutes is stuck, not slow.
      builds.arm_hard_timeout(name, function(timeout_name)
        local handle = running_objects[timeout_name]
        if handle then
          pcall(function() handle:kill(15) end)
        end
        finish(false, 'the build timed out after ' ..
          tostring(builds.HARD_TIMEOUT_MS / 1000) .. ' seconds')
      end)

      if type(build_task) == 'function' then
        -- A Lua build hook may be synchronous, or it may hand back an
        -- object for work it started itself. Marking the build as
        -- successful before that work finishes would make the next check
        -- skip a build that never completed.
        --
        -- Two shapes are understood: a promise with await() (as returned by
        -- vim.async), and a vim.SystemObj with wait() (as returned by
        -- vim.system).
        local result = build_task(dir)
        if result and type(result.await) == 'function' then
          local ok, err = result:await()
          if not ok then
            error(err or 'build failed', 0)
          end
        elseif result and type(result.wait) == 'function' then
          local obj = result:wait()
          -- The output is captured even on success: a build that exits 0
          -- while printing errors is a success by the exit code, but the
          -- output is what shows the user what happened.
          if obj then
            builds.append_output(name, obj.stdout)
            builds.append_output(name, obj.stderr)
          end
          if obj and obj.code ~= 0 then
            local msg = obj.stderr
            if not msg or msg == '' then msg = obj.stdout end
            if not msg or msg == '' then msg = 'command failed with code ' .. tostring(obj.code) end
            error(msg, 0)
          end
        end
      else
        local obj = get_semaphore():with(function()
          return run_command({ 'sh', '-c', build_task }, { cwd = dir, text = true }, function(handle)
            -- The handle is kept so the hard timeout can kill the child,
            -- and the PID is recorded as soon as the child exists, so the
            -- lock file names a process that can be probed for liveness.
            running_objects[name] = handle
            builds.set_pid(name, handle.pid)
            builds.update_lock_pid(name, handle.pid)
          end)
        end)
        -- The output is captured before the exit code is checked, so a
        -- failure has the output that caused it.
        builds.append_output(name, obj.stdout)
        builds.append_output(name, obj.stderr)
        if obj.code ~= 0 then
          error(obj.stderr and obj.stderr ~= '' and obj.stderr or obj.stdout or 'command failed', 0)
        end
      end
      finish(true, nil)
    end)
    build_run:on_complete(function(err)
      if not err then return end
      finish(false, err)
    end)
  end)
end

-- Check and run build if hash changed
---@param name string
---@param dir string
---@param build_task string|function
function M.check_and_build(name, dir, build_task)
  if not dir or dir == '' then return end

  local last_hash = read_marker(name)

  -- The commit is read from the git files directly rather than by running
  -- `git rev-parse HEAD`. This check runs for every plugin with a build
  -- hook at startup, and a subprocess per plugin is a process per plugin.
  --
  -- A directory that is not a git working tree has no commit to read. The
  -- old subprocess fallback used 'done' for that case, and the marker
  -- still holds it, so such a plugin is built once and not again.
  local curr_hash = utils.get_local_hash(dir) or 'done'
  if last_hash == curr_hash then return end

  M.run_build(name, dir, build_task, curr_hash)
end

--- Whether a build is pending or running for a plugin.
---
--- The loader uses this to decide whether the plugin's setup has to wait
--- for the build. A build that is running means the plugin's tree is
--- incomplete, and a setup that runs against an incomplete tree fails.
---@param name string
---@return boolean
function M.is_building(name)
  return builds.is_building(name)
end

--- Wait for a plugin's build to settle.
---
--- The wait pumps the event loop, so the editor stays responsive while it
--- waits. It gives up after `timeout_ms`; the build keeps running, and the
--- caller decides what to do about that.
---@param name string
---@param timeout_ms number|nil defaults to 30 seconds
---@return boolean ok, string|nil err
function M.wait_for_build(name, timeout_ms)
  return builds.wait(name, timeout_ms)
end

-- Setup PackChanged autocmd for automatic builds
---@param get_plugin_dir function
function M.setup_packchanged_autocmd(get_plugin_dir)
  local api = vim.api
  local create_autocmd = api.nvim_create_autocmd

  create_autocmd('PackChanged', {
    group = api.nvim_create_augroup('ResonanceBuilder', { clear = true }),
    callback = function(args)
      local data = args.data
      if not data then return end
      local kind = data.kind
      if kind ~= 'install' and kind ~= 'update' and kind ~= 'delete' then return end

      local spec = data.spec
      if not spec or not spec.name then return end
      local name = spec.name

      -- The marker outlives the plugin: it is in Resonance's state
      -- directory, while the build artifacts were in the plugin's own,
      -- which is gone. A reinstall at the same commit then matched the
      -- marker and skipped the build. The panel's uninstall cleared it,
      -- but vim.pack.del() and :packdel did not.
      if kind == 'delete' then
        M.clear_build_marker(name)
        return
      end
      -- A fresh install has no artifacts, whatever the marker says: the
      -- directory may have been removed by hand rather than through
      -- vim.pack.del().
      if kind == 'install' then
        M.clear_build_marker(name)
      end

      local build_task = M.build_hooks[name]
      if not build_task then return end

      local dir = data.path or get_plugin_dir(name)
      if not dir then return end

      M.check_and_build(name, dir, build_task)
    end,
  })
end

return M
