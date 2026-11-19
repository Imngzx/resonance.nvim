-- Optional lazy.nvim-style import (resonance.import): scan a folder of
-- spec modules, require each one, and register the specs it returns.
--
-- Nothing calls this unless the user does (`require('resonance').import()`),
-- so a config that lists its specs by hand never requires this module.
local M = {}

local utils = require('resonance.utils')
local is_plugin_list = require('resonance.loader.spec').is_plugin_list

local uv = vim.uv
local uv_fs_scandir = uv.fs_scandir
local uv_fs_scandir_next = uv.fs_scandir_next
local uv_fs_stat = uv.fs_stat
local table_sort = table.sort
local vim_log_levels = vim.log.levels

-- Every folder passed to import(), keyed by its directory. A scan never
-- returns a folder that is imported on its own (plugins/core/), even when
-- it has an init.lua -- otherwise import('plugins') would register its
-- specs a second time.
local imported = {}

local function default_root()
  return vim.fn.stdpath('config') .. '/lua'
end

-- A single spec: a URL as [1], an explicit src/url/plugin field, or the
-- plugin written as a table in [1] with the options beside it
-- ({ { 'url' }, lazy = false }). A list of specs is told apart by
-- is_plugin_list() first, the same check load() uses, so the two cannot
-- disagree about which shape is which.
local function is_spec(t)
  if type(t) ~= 'table' then return false end
  local first = t[1]
  if type(first) == 'string' then return first:find('://', 1, true) ~= nil end
  if type(first) == 'table' then return is_spec(first) end
  return type(t.src) == 'string' or type(t.url) == 'string'
    or t.plugin ~= nil
end

local function report(name, err, on_error)
  if on_error then
    on_error(name, err)
    return
  end
  utils.notify('import ' .. name .. ' failed: ' .. tostring(err), vim_log_levels.ERROR)
end

--- Module names directly under <root>/<mod>/, sorted.
---
--- Top level only: a subfolder counts only through its init.lua, so the
--- helper files inside it are never imported on their own. Sorted, because
--- scandir order depends on the filesystem.
---@param mod string e.g. 'plugins'
---@param root? string lua directory, default stdpath('config')/lua
---@return string[]
function M.scan(mod, root)
  local dir = (root or default_root()) .. '/' .. mod:gsub('%.', '/')
  local handle, err = uv_fs_scandir(dir)
  if not handle then
    utils.notify('import: cannot scan ' .. dir .. ': ' .. tostring(err), vim_log_levels.ERROR)
    return {}
  end

  local list, n = {}, 0
  while true do
    local name, kind = uv_fs_scandir_next(handle)
    if not name then break end

    -- init.lua is the folder's own module, '<mod>' itself, and import()
    -- requires it under that name. Listed here it would be required as
    -- '<mod>.init': a second run of the same file under another name.
    local entry
    if (kind == 'file' or kind == 'link') and name ~= 'init.lua' then
      entry = name:match('^(.+)%.lua$')
    end
    if not entry and (kind == 'directory' or kind == 'link')
      and not imported[dir .. '/' .. name]
      and uv_fs_stat(dir .. '/' .. name .. '/init.lua') then
      entry = name
    end

    if entry then
      n = n + 1
      list[n] = entry
    end
  end

  table_sort(list)
  return list
end

local function by_priority(a, b)
  if a.priority ~= b.priority then return a.priority > b.priority end
  return a.order < b.order
end

---@class ResonanceImportOpts
---@field root? string lua directory to scan, default stdpath('config')/lua
---@field on_error? fun(mod: string, err: any) called instead of notifying

--- Require every module under <root>/<mod>/ and register what it returns.
---
--- A module returns a spec or a list of specs. Anything else it returns
--- (a helper table, nothing) is ignored, so a module may still call
--- resonance.load() itself.
---
--- Specs are registered after every module is required, highest
--- `priority` first (default 0), ties in file order. `priority` is
--- stripped before resonance.load(). Each require and each load runs under
--- its own pcall: one broken file does not stop the rest.
---@param mod string e.g. 'plugins', 'plugins.core'
---@param opts? ResonanceImportOpts
function M.import(mod, opts)
  opts = opts or {}
  local root = opts.root or default_root()
  local on_error = opts.on_error
  local dir = root .. '/' .. mod:gsub('%.', '/')
  imported[dir] = true

  local names = M.scan(mod, root)
  local entries, n = {}, 0
  -- A bad entry is reported and skipped here, before the sort: a
  -- non-table entry or a non-numeric priority would otherwise raise
  -- outside any pcall and abort the whole import.
  local function add(name, spec)
    if not is_spec(spec) then
      report(name, 'not a plugin spec: ' .. vim.inspect(spec), on_error)
      return
    end
    local priority = spec.priority
    if priority ~= nil and type(priority) ~= 'number' then
      report(name, 'priority must be a number, got ' .. type(priority), on_error)
      priority = 0
    end
    n = n + 1
    entries[n] = { name = name, spec = spec, priority = priority or 0, order = n }
  end

  local function take(name, ok, ret)
    if ok == nil then ok, ret = pcall(require, name) end
    if not ok then
      report(name, ret, on_error)
    elseif is_plugin_list(ret) then
      if is_spec(ret[1]) then
        for j = 1, #ret do
          add(name, ret[j])
        end
      end
    elseif is_spec(ret) then
      add(name, ret)
    end
  end

  -- The folder's own init.lua first, as the module '<mod>'. Already in
  -- package.loaded, its value is used as it is: either what it returned,
  -- or -- while it is still running, because it is the file that called
  -- import('<mod>') -- require()'s in-progress marker, which is not a
  -- table and so is ignored. Requiring it then would only raise "loop or
  -- previous error loading module".
  if uv_fs_stat(dir .. '/init.lua') then
    local cur = package.loaded[mod]
    if cur ~= nil then
      take(mod, true, cur)
    else
      take(mod)
    end
  end

  for i = 1, #names do
    take(mod .. '.' .. names[i])
  end

  table_sort(entries, by_priority)

  local load = require('resonance').load
  for i = 1, n do
    local e = entries[i]
    local spec = e.spec
    if spec.priority ~= nil then
      local copy = {}
      for k, v in pairs(spec) do copy[k] = v end
      copy.priority = nil
      spec = copy
    end
    local ok, err = pcall(load, spec)
    if not ok then report(e.name, err, on_error) end
  end
end

return M
