local M = {}
local utils = require('resonance.utils')

local uv = vim.uv
local fs_open = uv.fs_open
local fs_fstat = uv.fs_fstat
local fs_read = uv.fs_read
local fs_write = uv.fs_write
local fs_close = uv.fs_close
local fs_mkdir = uv.fs_mkdir
local fs_stat = uv.fs_stat
local fs_unlink = uv.fs_unlink
local system = vim.system
local schedule = vim.schedule
local type = type
local tostring = tostring
local fn_stdpath = vim.fn.stdpath

-- Built on first use; see get_async() below.
local _system_async = nil
local build_semaphore = nil

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
  local async = vim.async
  if not _system_async then
    _system_async = async.wrap(3, system)
    build_semaphore = async.semaphore(2)
  end
  return async
end

---@param cmd string[]
---@param opts table
---@return vim.SystemCompleted
local function system_async(cmd, opts)
  get_async()
  return _system_async(cmd, opts) --[[@as vim.SystemCompleted]]
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
    -- uv.fs_mkdir is not recursive, so the two levels are made in turn.
    local parent = fn_stdpath('state') .. '/resonance'
    if not fs_stat(parent) then fs_mkdir(parent, 493) end
    if not fs_stat(dir) then fs_mkdir(dir, 493) end
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

  local function finish(ok, err)
    if ok then
      M.mark_build_success(name, curr_hash)
      schedule(function()
        utils.notify('Build succeeded for ' .. name, vim.log.levels.INFO)
      end)
    else
      schedule(function()
        utils.notify('Build failed for ' .. name .. ': ' .. tostring(err), vim.log.levels.ERROR)
      end)
    end
    if on_done then on_done(ok, err) end
  end

  schedule(function()
    local build_run = get_async().run('resonance_build:' .. name, function()
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
          if obj and obj.code ~= 0 then
            local msg = obj.stderr
            if not msg or msg == '' then msg = obj.stdout end
            if not msg or msg == '' then msg = 'command failed with code ' .. tostring(obj.code) end
            error(msg, 0)
          end
        end
      else
        local obj = build_semaphore:with(function()
          return system_async({ 'sh', '-c', build_task }, { cwd = dir, text = true })
        end)
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

-- Setup PackChanged autocmd for automatic builds
---@param get_plugin_dir function
function M.setup_packchanged_autocmd(get_plugin_dir)
  local api = vim.api
  local create_autocmd = api.nvim_create_autocmd

  create_autocmd('PackChanged', {
    group = api.nvim_create_augroup('ResonanceBuilder', { clear = true }),
    callback = function(args)
      local data = args.data
      if not data or (data.kind ~= 'install' and data.kind ~= 'update') then return end

      local spec = data.spec
      if not spec or not spec.name then return end
      local name = spec.name

      local build_task = M.build_hooks[name]
      if not build_task then return end

      local dir = data.path or get_plugin_dir(name)
      if not dir then return end

      M.check_and_build(name, dir, build_task)
    end,
  })
end

return M
