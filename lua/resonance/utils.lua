local M = {}

local pcall = pcall
local type = type
local string_match = string.match
local table_concat = table.concat
local table_sort = table.sort
local string_lower = string.lower
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
      _snacks_notifier.notify(msg, level, opts or { title = 'Resonance' })
    else
      vim_notify('[Resonance] ' .. msg, level, opts)
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
    src = plugin.src or plugin[1] or plugin.url,
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
    if type(config.event) == 'table' then
      local ev = config.event
      if ev[1] == 'User' then
        return '󱐋 User(' .. (ev.pattern or ev[2] or 'Unknown') .. ')'
      end
      return '󱐋 ' .. table_concat(ev, ', ')
    end
    return '󱐋 ' .. config.event
  end
  if config.cmd then
    local cmds = type(config.cmd) == 'string' and { config.cmd } or config.cmd
    return '󰘳 ' .. table_concat(cmds, ', ')
  end
  if config.keys then
    return '󰌌 keys'
  end
  if config.ft then
    local fts = type(config.ft) == 'string' and { config.ft } or config.ft
    return '󰈔 ' .. table_concat(fts, ', ')
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

-- Sort plugins: loaded first, then alphabetically by name (case-insensitive)
---@param plugins table SOA table with name[], loaded[] arrays
---@param total integer number of plugins
---@return table sorted indices
function M.sort_plugins(plugins, total)
  local indices = {}
  local lower_names = {}
  for i = 1, total do
    indices[i] = i
    lower_names[i] = string_lower(plugins.name[i])
  end

  table_sort(indices, function(a, b)
    if plugins.loaded[a] ~= plugins.loaded[b] then return plugins.loaded[a] end
    return lower_names[a] < lower_names[b]
  end)

  return indices
end

-- Apply sorted indices to plugin SOA table
---@param plugins table SOA table
---@param indices table sorted indices
---@param total integer
---@param fields table list of field names to sort
---@return table new sorted plugins table
function M.apply_sort(plugins, indices, total, fields)
  local sorted = {}
  for _, field in ipairs(fields) do
    sorted[field] = {}
    for i = 1, total do
      sorted[field][i] = plugins[field][indices[i]]
    end
  end
  return sorted
end

return M

