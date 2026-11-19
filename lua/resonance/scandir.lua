-- Optional lazy.nvim-style import (resonance.import): scan a folder of
-- spec modules, require each one, and register the specs it returns.
--
-- Nothing calls this unless the user does (`require('resonance').import()`),
-- so a config that lists its specs by hand never requires this module.
local M = {}

local utils = require('resonance.utils')

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

-- A single spec: a URL as [1], or an explicit src/url/plugin field.
local function is_spec(t)
  if type(t) ~= 'table' then return false end
  local first = t[1]
  return (type(first) == 'string' and first:find('://', 1, true) ~= nil)
    or type(t.src) == 'string' or type(t.url) == 'string'
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

    local entry
    if kind == 'file' or kind == 'link' then
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
  imported[root .. '/' .. mod:gsub('%.', '/')] = true

  local names = M.scan(mod, root)
  local entries, n = {}, 0
  local function add(name, spec)
    n = n + 1
    entries[n] = { name = name, spec = spec, priority = spec.priority or 0, order = n }
  end

  for i = 1, #names do
    local name = mod .. '.' .. names[i]
    local ok, ret = pcall(require, name)
    if not ok then
      report(name, ret, on_error)
    elseif is_spec(ret) then
      add(name, ret)
    elseif type(ret) == 'table' and is_spec(ret[1]) then
      for j = 1, #ret do
        add(name, ret[j])
      end
    end
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
