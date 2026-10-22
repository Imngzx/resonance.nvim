local M = {}

local pcall = pcall
local type = type
local string_match = string.match
local table_concat = table.concat
local vim_notify = vim.notify

local _snacks_checked = false
local _snacks_notifier = nil

M.is_windows = function() return jit.os == 'Windows' end

M.fast_normalize = function(path)
  if not path then return path end
  return vim.fs.normalize(path)
end

---@param msg string
---@param level integer
---@param opts table|nil
function M.notify(msg, level, opts)
  -- Always defer notification to avoid fast event context (vim.system callbacks, PackChanged, etc.)
  -- Both vim.notify and snacks.notifier.notify can fail with E5560 in fast event contexts
  vim.schedule(function()
    if not _snacks_checked then
      local ok, snacks = pcall(require, 'snacks')
      if ok and type(snacks) == 'table' and snacks.notifier then
        _snacks_notifier = snacks.notifier
      end
      _snacks_checked = true
    end
    if _snacks_notifier then
      _snacks_notifier.notify(msg, level, opts)
    else
      vim_notify(msg, level, opts)
    end
  end)
end

-- Extract plugin name from URL or path
---@param url string
---@return string|nil
function M.extract_name(url)
  if not url then return nil end
  return string_match(url, '([^/]+)%.git$') or string_match(url, '([^/]+)$')
end

-- Normalize a plugin spec to vim.pack.Spec format
---@param plugin string|table
---@return string|table
function M.normalize_pack_spec(plugin)
  if type(plugin) ~= 'table' then return plugin end
  return {
    src = plugin.src or plugin.url or plugin[1],
    name = plugin.name,
    version = plugin.version,
    data = plugin.data,
  }
end

-- Parse trigger type from config (with display icons)
---@param config table
---@return string|nil
function M.parse_trigger(config)
  if config.event then
    return '󰻃 ' .. (type(config.event) == 'table' and config.event[1] or config.event)
  end
  if config.cmd then
    return '󰘳 ' .. (type(config.cmd) == 'table' and config.cmd[1] or config.cmd)
  end
  if config.keys then
    return '󰌌 keys'
  end
  if config.ft then
    return '󰈔 ' .. (type(config.ft) == 'table' and config.ft[1] or config.ft)
  end
  return nil
end

-- Parse dependencies from config
---@param config table
---@return table[]
function M.parse_dependencies(config)
  local deps = {}
  if config.dependencies then
    local dep_list = type(config.dependencies) == 'table' and config.dependencies or
      { config.dependencies }
    for i = 1, #dep_list do
      local dep = M.normalize_pack_spec(dep_list[i])
      local target_url = type(dep) == 'string' and dep or (dep.src or dep[1])
      local dep_name = (type(dep) == 'table' and dep.name) or M.extract_name(target_url)
      if dep_name then
        deps[#deps + 1] = { name = dep_name, raw = dep }
      end
    end
  end
  return deps
end

-- Resolve a plugin spec to name, url, and normalized pack_spec
---@param plugin string|table
---@return string|nil name, string|nil url, table|string pack_spec
function M.resolve_plugin_spec(plugin)
  local pack_spec = M.normalize_pack_spec(plugin)
  local target_url = type(pack_spec) == 'string' and pack_spec or
    (pack_spec.src or pack_spec[1])
  local name = (type(pack_spec) == 'table' and pack_spec.name) or
    M.extract_name(target_url)
  return name, target_url, pack_spec
end

return M