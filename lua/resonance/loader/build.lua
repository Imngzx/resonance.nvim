local M = {}
local utils = require('resonance.utils')

local uv = vim.uv
local fs_open = uv.fs_open
local fs_fstat = uv.fs_fstat
local fs_read = uv.fs_read
local fs_write = uv.fs_write
local fs_close = uv.fs_close
local async = vim.async
local system = vim.system
local schedule = vim.schedule
local type = type
local tostring = tostring
local _system_async = async.wrap(3, system)
---@param cmd string[]
---@param opts table
---@return vim.SystemCompleted
local function system_async(cmd, opts)
  return _system_async(cmd, opts) --[[@as vim.SystemCompleted]]
end
local build_semaphore = async.semaphore(2)

M.build_hooks = {}

-- Mark build as successful by writing hash to file
---@param dir string
---@param hash string
function M.mark_build_success(dir, hash)
  local fd = fs_open(dir .. '/.resonance_built', 'w', 438)
  if fd then
    fs_write(fd, hash, 0)
    fs_close(fd)
  end
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
  local last_hash = ''
  local fd = fs_open(dir .. '/.resonance_built', 'r', 438)
  if fd then
    local stat = fs_fstat(fd)
    if stat then last_hash = fs_read(fd, stat.size, 0) or '' end
    fs_close(fd)
  end

  if last_hash == curr_hash then
    if on_done then on_done(true, nil) end
    return
  end

  local function finish(ok, err)
    if ok then
      M.mark_build_success(dir, curr_hash)
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
    local build_run = async.run('resonance_build:' .. name, function()
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

  local last_hash = ''
  local fd = fs_open(dir .. '/.resonance_built', 'r', 438)
  if fd then
    local stat = fs_fstat(fd)
    if stat then last_hash = fs_read(fd, stat.size, 0) or '' end
    fs_close(fd)
  end

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
