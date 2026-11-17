local M = {}

local pcall = pcall
local type = type
local string_match = string.match
local string_sub = string.sub
local string_gsub = string.gsub
local table_concat = table.concat
local table_sort = table.sort
local string_lower = string.lower
local vim_notify = vim.notify
local uv = vim.uv
local uv_fs_open = uv.fs_open
local uv_fs_fstat = uv.fs_fstat
local uv_fs_read = uv.fs_read
local uv_fs_close = uv.fs_close

local _snacks_checked = false
local _snacks_notifier = nil

M.is_windows = function() return jit.os == 'Windows' end

M.fast_normalize = function(path)
  if not path then return path end
  return vim.fs.normalize(path)
end

--- Read the commit a git working tree is on, without spawning a subprocess.
---
--- `git rev-parse HEAD` costs a process per call, and the build check runs it
--- for every plugin at startup. Reading the git files directly costs a few
--- file reads instead.
---
--- The hash is truncated to seven characters, like `git rev-parse --short`.
---@param path string The plugin directory.
---@return string|nil
function M.get_local_hash(path)
  if not path or path == '' then return nil end
  local git_dir = path .. '/.git'

  local function fast_read(file_path)
    local fd = uv_fs_open(file_path, 'r', 438)
    if not fd then return nil end
    local stat = uv_fs_fstat(fd)
    local content = stat and uv_fs_read(fd, stat.size, 0) or uv_fs_read(fd, 65536, 0)
    uv_fs_close(fd)
    return content
  end

  local head = fast_read(git_dir .. '/HEAD')
  if not head then return nil end

  local ref = string_match(head, 'ref:%s*(%S+)')
  if ref then
    local ref_content = fast_read(git_dir .. '/' .. ref)
    if ref_content then
      local hash = string_match(ref_content, '^(%x+)')
      return hash and string_sub(hash, 1, 7) or nil
    else
      local packed = fast_read(git_dir .. '/packed-refs')
      if packed then
        local escaped_ref = string_gsub(ref, '[%-%.%+%[%]%(%)%$%^%%%?%*]', '%%%1')
        local hash = string_match(packed, '(%x+)%s+' .. escaped_ref)
        if hash then
          return string_sub(hash, 1, 7)
        end
      end
    end
  else
    local hash = string_match(head, '^(%x+)')
    return hash and string_sub(hash, 1, 7) or nil
  end
  return nil
end

--- Resolve the native vim.pack module, if available.
--- `vim.pack` is lazily rehydrated by the `vim` metatable's __index, so assigning
--- nil to it is silently undone on the next read. Reading the raw field avoids
--- that rehydration: a raw nil means vim.pack was explicitly disabled and the
--- caller should use the filesystem fallback.
---@return table|nil
function M.get_pack()
  local pack = rawget(vim, 'pack')
  if type(pack) ~= 'table' or type(pack.get) ~= 'function' then return nil end
  return pack
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

---@class ResonanceEventSpec
---@field event string The event name.
---@field pattern? string The pattern, for a User event.
---@field user boolean True when the event is a User event with a pattern.

--- Normalize an event spec into a flat list of event descriptors.
---
--- The accepted shapes are:
---   'BufReadPost'                          -- one native event
---   { 'BufReadPost', 'BufNewFile' }        -- several native events
---   { 'User', pattern = 'VeryLazy' }       -- one User event
---
--- A User event carries its own pattern, so it cannot be represented as a
--- bare string in a list of event names. Keeping the pattern in a separate
--- field is what stops a User entry from being read as the pattern of the
--- event before it -- and it is why the User entries are appended to the
--- list separately instead of being mixed into it.
---
--- The result is always a list of descriptors: {event=..., pattern=...}.
---
--- The function is idempotent: a list that is already in the descriptor form
--- is returned unchanged. The spec is normalized once, in parse_config, and
--- the result is stored in config.event -- so every later reader sees the
--- normalized form and has to accept it.
---@param event string|table|nil
---@return ResonanceEventSpec[]
function M.normalize_events(event)
  local out = {}
  if event == nil then return out end

  if type(event) == 'string' then
    return { { event = event } }
  end

  if type(event) ~= 'table' then return out end

  -- Already normalized: a list of descriptors. Every entry is a table with
  -- an `event` field. The check has to scan the whole list, because a
  -- normalized list can mix native events and User events -- and the first
  -- entry alone does not tell the two forms apart.
  local all_descriptors = #event > 0
  for i = 1, #event do
    local e = event[i]
    if type(e) ~= 'table' or type(e.event) ~= 'string' then
      all_descriptors = false
      break
    end
  end
  if all_descriptors then
    for i = 1, #event do
      out[#out + 1] = event[i]
    end
    return out
  end

  -- A User event: { 'User', pattern = 'X' }. The pattern may also be given
  -- positionally as ev[2], which is what the native autocmd API accepts.
  if event[1] == 'User' then
    local pattern = event.pattern or event[2]
    if type(pattern) == 'string' then
      return { { event = 'User', pattern = pattern, user = true } }
    end
    -- A User event without a pattern matches every User event.
    return { { event = 'User', user = true } }
  end

  for i = 1, #event do
    local name = event[i]
    if type(name) == 'string' then
      out[#out + 1] = { event = name }
    elseif type(name) == 'table' and type(name.event) == 'string' then
      -- A descriptor mixed into a raw list. Keep it as it is, so a list
      -- that is partly normalized does not lose entries.
      out[#out + 1] = name
    end
  end

  -- A pattern on the list itself applies to the native events in it.
  if type(event.pattern) == 'string' then
    for i = 1, #out do
      out[i].pattern = event.pattern
    end
  end

  return out
end

--- The native event names in a normalized event list, without User entries.
---@param events ResonanceEventSpec[]
---@return string[]
function M.native_event_names(events)
  local out = {}
  for i = 1, #events do
    if not events[i].user then
      out[#out + 1] = events[i].event
    end
  end
  return out
end

--- The User event patterns in a normalized event list.
---@param events ResonanceEventSpec[]
---@return string[] patterns, 'nil' for a User event without one
function M.user_event_patterns(events)
  local out = {}
  for i = 1, #events do
    if events[i].user then
      out[#out + 1] = events[i].pattern
    end
  end
  return out
end

-- Parse trigger type from config (with display icons)
---@param config table
---@return string|nil
function M.parse_trigger(config)
  if config.event then
    local events = M.normalize_events(config.event)
    if #events > 0 then
      local parts = {}
      for i = 1, #events do
        local e = events[i]
        if e.user then
          parts[#parts + 1] = 'User(' .. (e.pattern or 'Unknown') .. ')'
        else
          parts[#parts + 1] = e.event
        end
      end
      return '󱐋 ' .. table_concat(parts, ', ')
    end
    return '󱐋 ' .. tostring(config.event)
  end
  if config.cmd then
    local cmds = type(config.cmd) == 'string' and { config.cmd } or config.cmd
    local parts = {}
    for i = 1, #cmds do
      local c = cmds[i]
      if type(c) == 'table' then
        parts[#parts + 1] = c.name or c[1] or '?'
      else
        parts[#parts + 1] = c
      end
    end
    return '󰘳 ' .. table_concat(parts, ', ')
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
    local a_disabled = plugins.disabled and plugins.disabled[a] or false
    local b_disabled = plugins.disabled and plugins.disabled[b] or false
    if a_disabled ~= b_disabled then return not a_disabled end
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
  for i = 1, #fields do
    local field = fields[i]
    sorted[field] = {}
    for j = 1, total do
      sorted[field][j] = plugins[field][indices[j]]
    end
  end
  return sorted
end

return M
