local M = {}
local utils = require('resonance.utils')

-- Parse and normalize plugin configuration
---@param config table
---@return table|nil
function M.parse_config(config)
  local is_plugin_list = type(config[1]) == 'table'
    and not config.plugin and not config.url and not config.src
    and not config.event and not config.cmd and not config.keys
    and not config.ft and not config.config and not config.setup

  if is_plugin_list then
    return nil -- handled by caller
  end

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
      -- Eager: must not have explicit triggers
      if config.event or config.cmd or config.keys or config.ft then
        error('lazy=false cannot be used with event/cmd/keys/ft')
      end
      config.event = 'VimEnter'
    elseif config.lazy == true then
      -- Default lazy = VeryLazy
      if config.event or config.cmd or config.keys or config.ft then
        error('lazy=true cannot be used with event/cmd/keys/ft (use VeryLazy instead)')
      end
      config.event = { 'User', pattern = 'VeryLazy' }
    end
  end

  -- cond field: boolean or function() -> boolean (lazy.nvim parity)
  if config.cond ~= nil then
    local ok
    if type(config.cond) == 'function' then
      ok = config.cond()
    else
      ok = config.cond
    end
    if not ok then return nil end
  end

  local plugins = config.plugin
  if type(plugins) == 'string' then
    plugins = { plugins }
  elseif type(plugins) == 'table' then
    if plugins[1] == nil and (plugins.src or plugins.url or plugins.name) then
      plugins = { plugins }
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