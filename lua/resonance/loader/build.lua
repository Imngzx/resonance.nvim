local M = {}
local utils = require('resonance.utils')

local uv = vim.uv
local fs_open = uv.fs_open
local fs_fstat = uv.fs_fstat
local fs_read = uv.fs_read
local fs_write = uv.fs_write
local fs_close = uv.fs_close
local system = vim.system
local schedule = vim.schedule
local vim_trim = vim.trim

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
function M.run_build(name, dir, build_task, curr_hash)
  if not dir or dir == '' then return end

  local function do_build()
    local ok, err = pcall(function()
      if type(build_task) == 'function' then
        build_task(dir)
      else
        system({ 'sh', '-c', build_task }, { cwd = dir, text = true }, function(obj)
          if obj.code ~= 0 then
            utils.notify('Build failed for ' .. name .. ': ' .. (obj.stderr or ''),
              vim.log.levels.ERROR)
          else
            schedule(function() M.mark_build_success(dir, curr_hash) end)
          end
        end)
        return
      end
      schedule(function() M.mark_build_success(dir, curr_hash) end)
    end)
    if not ok then
      utils.notify('Build error for ' .. name .. ': ' .. tostring(err), vim.log.levels.ERROR)
    end
  end

  schedule(do_build)
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

  system({ 'git', 'rev-parse', 'HEAD' }, { cwd = dir, text = true }, function(obj)
    local curr_hash = (obj.code == 0 and obj.stdout) and vim_trim(obj.stdout) or 'done'
    if last_hash ~= curr_hash then
      M.run_build(name, dir, build_task, curr_hash)
    end
  end)
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

      system({ 'git', 'rev-parse', 'HEAD' }, { cwd = dir, text = true }, function(obj)
        local curr_hash = (obj.code == 0 and obj.stdout) and vim_trim(obj.stdout) or 'done'
        schedule(function() M.run_build(name, dir, build_task, curr_hash) end)
      end)
    end,
  })
end

return M
