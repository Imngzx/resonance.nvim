local M = {}

local pcall = pcall
local type = type
local string_match = string.match
local vim_notify = vim.notify

local _snacks_checked = false
local _snacks_notifier = nil

M.is_windows = function() return jit_os == 'Windows' end

M.fast_normalize = function(path)
  if not path then return path end
  return vim.fs.normalize(path)
end

---@param msg string
---@param level integer
---@param opts table|nil
function M.notify(msg, level, opts)
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

-- Parse trigger type from config
---@param config table
---@return string|nil
function M.parse_trigger(config)
  if config.event then return 'Event' end
  if config.cmd then return 'Cmd' end
  if config.keys then return 'Keys' end
  if config.ft then return 'FileType' end
  return nil
end

-- Parse dependencies from config
---@param config table
---@return table[]
function M.parse_dependencies(config)
  local deps = {}
  if config.dependencies then
    local dep_list = type(config.dependencies) == 'table' and config.dependencies or { config.dependencies }
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



return M
