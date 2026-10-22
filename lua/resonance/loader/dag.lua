local M = {}
local utils = require('resonance.utils')

local api = vim.api
local get_autocmds = api.nvim_get_autocmds

local type = type
local pairs = pairs
local string_gmatch = string.gmatch
local vim_trim = vim.trim
local table_insert = table.insert

local function get_event_chain(event, buf, data)
  local chain = {}
  local current = event
  local visited = {}

  while current and not visited[current] do
    visited[current] = true
    local autocmds = get_autocmds({ event = current, buf = buf })
    if #autocmds > 0 then
      local exclude = {}
      for a = 1, #autocmds do
        local autocmd = autocmds[a]
        if autocmd.group then
          exclude[autocmd.group_name] = true
        end
      end
      chain[#chain + 1] = { event = current, buf = buf, exclude = exclude, data = data }
    end

    if current == 'BufReadPre' then
      current = 'BufRead'
    elseif current == 'BufRead' then
      current = 'BufReadPost'
    elseif current == 'BufNewFile' then
      current = 'BufRead'
    else
      break
    end
  end

  return chain
end

---@return table<string, {name:string, deps:string[], trigger:string, loaded:boolean}>, table<string, string[]>
function M.get_dag_data(specs, plugin_state, scanner_info)
  local nodes = {}
  local edges = {}

  -- Build a set of all dependency names from specs
  local all_dep_names = {}
  for _, spec in pairs(specs) do
    if spec.dependencies then
      local dep_list = type(spec.dependencies) == 'table' and spec.dependencies or
        { spec.dependencies }
      for i = 1, #dep_list do
        local dep_name = utils.resolve_plugin_spec(dep_list[i])
        if dep_name then
          all_dep_names[dep_name] = true
        end
      end
    end
  end

  -- Build scanner lookup maps if scanner_info provided
  local scanner_loaded = {}
  local scanner_trigger = {}
  local scanner_type = {}
  if scanner_info and scanner_info.plugins then
    local sp = scanner_info.plugins
    for i = 1, scanner_info.total do
      local name = sp.name[i]
      scanner_loaded[name] = sp.loaded[i]
      scanner_trigger[name] = sp.trigger[i]
      scanner_type[name] = sp.type[i]
    end
  end

  -- First pass: add all spec nodes
  for name, spec in pairs(specs) do
    local deps = {}
    if spec.dependencies then
      local dep_list = type(spec.dependencies) == 'table' and spec.dependencies or
        { spec.dependencies }
      for i = 1, #dep_list do
        local dep_name = utils.resolve_plugin_spec(dep_list[i])
        if dep_name then
          deps[#deps + 1] = dep_name
        end
      end
    end

    local trig_str = utils.parse_trigger(spec)
    local state = plugin_state[spec]
    nodes[name] = {
      name = name,
      deps = deps,
      trigger = trig_str or 'none',
      loaded = state and state.loaded or false,
    }
    edges[name] = deps
  end

  -- Second pass: add dependency nodes that are installed but not in specs
  -- These are plugins that are dependencies of other plugins but not explicitly configured
  if scanner_info and scanner_info.plugins then
    for i = 1, scanner_info.total do
      local name = scanner_info.plugins.name[i]
      if not nodes[name] and (all_dep_names[name] or scanner_loaded[name]) then
        -- This is a dependency plugin not explicitly in specs
        nodes[name] = {
          name = name,
          deps = {},
          trigger = scanner_trigger[name] or (scanner_type[name] == 'start' and '󰜎 start' or '󰢱 opt'),
          loaded = scanner_loaded[name] or false,
        }
        edges[name] = {}
      end
    end
  end

  return nodes, edges
end

---@return table<string, {event:string, chain:string[], replayed:boolean}>
function M.get_replay_info(specs, plugin_triggers)
  local info = {}
  for name, spec in pairs(specs) do
    -- Only process actual specs (those with _replay_done field)
    -- Dependency nodes from scanner don't have this field
    if spec._replay_done then
      local trigger = plugin_triggers[name] or 'none'
      local chain = {}
      -- Only process event triggers (󱐋 prefix), not cmd/keys/ft
      if trigger:match('^󱐋') then
        local ev = type(spec.event) == 'string' and { spec.event } or spec.event
        if ev and ev[1] then
          local event_name = ev[1]
          if event_name ~= 'User' then
            local autocmds = get_autocmds({ event = event_name })
            for a = 1, #autocmds do
              local autocmd = autocmds[a]
              if autocmd.group then
                chain[#chain + 1] = autocmd.group_name
              end
            end
          end
        end
      end
      info[name] = {
        event = trigger,
        chain = chain,
        replayed = spec._replay_done == true,
      }
    end
  end
  return info
end

-- Internal helper to get event chain
function M._get_event_chain_internal(event, buf, data)
  return get_event_chain(event, buf, data)
end

return M