local M = {}
local utils = require('resonance.utils')

local type = type
local pairs = pairs

---@param t table
---@return boolean
local function has_string_key(t)
  for k in pairs(t) do
    if type(k) ~= 'number' then return true end
  end
  return false
end

--- Whether a table given to load() is a list of specs rather than one spec.
---
--- A list has specs in its array part and nothing else. Any named field --
--- lazy, dependencies, cond, build, version, ... -- makes it a single spec
--- whose plugin is written as its first element. The old check looked for
--- a fixed handful of keys, so { { 'url' }, lazy = false, dependencies =
--- { ... } } was split into specs and its options were silently dropped.
---
--- Shared by the loader and parse_config, so the two cannot disagree.
---@param config table
---@return boolean
function M.is_plugin_list(config)
  return type(config) == 'table' and type(config[1]) == 'table'
    and not has_string_key(config)
end

-- Parse and normalize plugin configuration
--
-- The caller's table is never modified. A spec is the user's own table,
-- and it stays theirs: the normalization happens on a copy, so a config
-- that is loaded twice, inspected afterwards, or shared between two
-- plugin managers sees exactly what it was written as.
---@param config table
---@return table|nil parsed the normalized copy; nil when the spec is rejected
---@return string|nil reason why it was rejected ('disabled')
---@return table|nil rejected the normalized copy of a rejected spec
function M.parse_config(config)
  if M.is_plugin_list(config) then
    return nil -- handled by caller
  end

  -- Work on a copy from here on. The shallow copy is enough for the
  -- fields this function rewrites; the one nested table it rewrites (the
  -- keys list) is copied separately below.
  local parsed = {}
  for k, v in pairs(config) do
    parsed[k] = v
  end
  config = parsed

  -- Normalize plugin field
  if not config.plugin and (config.src or config.url or type(config[1]) == 'string') then
    config.plugin = {
      src = config.src or config.url or config[1],
      name = config.name,
      version = config.version,
      data = config.data,
    }
  else
    config.plugin = config.plugin or config[1]
  end
  config.setup = config.setup or config.config

  -- lazy field: false = eager (VimEnter), true = VeryLazy default
  if config.lazy ~= nil then
    if config.lazy == false then
      -- Eager: must not have explicit load triggers (event/cmd/ft)
      -- keys is allowed since keymaps work after eager load
      if config.event or config.cmd or config.ft then
        error('lazy=false cannot be used with event/cmd/ft')
      end
      config.event = 'VimEnter'
    elseif config.lazy == true then
      -- Default lazy = VeryLazy (add as additional trigger, not replacement).
      --
      -- The VeryLazy trigger is a User event with its own pattern, so it
      -- cannot be appended to a list of native event names: a User entry
      -- read as ev[2] would be taken as the pattern of the event before it.
      -- The event list is normalized into descriptors first, and the User
      -- entry is kept separate from the native names.
      local has_triggers = config.event or config.cmd or config.keys or config.ft
      if has_triggers then
        local events = utils.normalize_events(config.event)
        -- VeryLazy is an additional trigger, not a replacement: the primary
        -- event stays and the plugin can still load on it.
        events[#events + 1] = { event = 'User', pattern = 'VeryLazy', user = true }
        config.event = events
      else
        config.event = { { event = 'User', pattern = 'VeryLazy', user = true } }
      end
    end
  elseif not (config.event or config.cmd or config.keys or config.ft) then
    -- A spec with no trigger and no lazy field registered nothing at all:
    -- no autocmd, no keymap, no command. The plugin was never installed
    -- and never loaded, with no error to explain why.
    --
    -- The README documents this shape for version pinning --
    -- { src = ..., version = 'v1.0.0' } -- where the user wants the
    -- plugin, just pinned. So a triggerless spec loads eagerly on
    -- VimEnter, the same as lazy = false.
    config.event = 'VimEnter'
  end

  -- cond field: boolean or function() -> boolean (lazy.nvim parity)
  if config.cond ~= nil then
    local ok
    if type(config.cond) == 'function' then
      ok = config.cond()
    else
      ok = config.cond
    end
    if not ok then return nil, 'disabled', config end
  end

  -- Normalize keys: convert shorthand strings to full key spec tables
  if config.keys then
    local keys = config.keys
    if type(keys) == 'function' then
      -- Function returning keymaps: keep as-is, will be called at registration time
    else
      -- The list is the user's own, so the shorthand entries are rewritten
      -- in a copy of it.
      local normalized = {}
      for i = 1, #keys do
        normalized[i] = keys[i]
      end
      for i = 1, #normalized do
        if type(normalized[i]) == 'string' then
          -- Shorthand: "<leader>x" -> {"n", "<leader>x"}
          normalized[i] = { 'n', normalized[i] }
        end
      end
      config.keys = normalized
    end
  end

  -- Normalize cmd: a string becomes a one-element list, and a command spec
  -- table (with its own nargs/range/complete) becomes a one-element list
  -- too. Without this, a spec table has no [1] and no command is ever
  -- registered.
  if config.cmd then
    local cmds = config.cmd
    if type(cmds) == 'string' then
      config.cmd = { cmds }
    elseif type(cmds) == 'table' and cmds[1] == nil then
      config.cmd = { cmds }
    end
  end

  local plugins = config.plugin
  if type(plugins) == 'string' then
    plugins = { plugins }
  elseif type(plugins) == 'table' then
    if plugins[1] == nil and (plugins.src or plugins.url or plugins.name) then
      plugins = { plugins }
    elseif type(plugins[1]) == 'string' and has_string_key(plugins) then
      -- { 'url', version = 'v1.0.0' } is one plugin with its options, not a
      -- list of plugins: it was read as a list, and the version, name and
      -- build were silently dropped. A list of URLs -- { 'url1', 'url2' } --
      -- has no named fields and stays a list.
      if #plugins == 1 then
        plugins = { plugins }
      else
        utils.notify('Plugin options such as version or name apply to one plugin. ' ..
          "Write each plugin as its own table: { { 'url1', version = ... }, 'url2' }",
          vim.log.levels.WARN)
      end
    end
  end
  config.plugin = plugins or {}

  return config
end

-- Extract plugin names from config
---@param plugins table[]
---@return string[], table[]
function M.extract_names(plugins)
  local pack_plugins = {}
  local parsed_names = {}

  for p = 1, #plugins do
    local name, _, pack_spec = utils.resolve_plugin_spec(plugins[p])
    pack_plugins[p] = pack_spec
    if name then
      parsed_names[#parsed_names + 1] = name
    end
  end

  return parsed_names, pack_plugins
end

return M