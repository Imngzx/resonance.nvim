local M = {}
local utils = require('resonance.utils')

local api = vim.api
local get_autocmds = api.nvim_get_autocmds

local type = type
local pairs = pairs

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
function M.get_dag_data(specs, plugin_state)
  local nodes = {}
  local edges = {}

  for name, spec in pairs(specs) do
    local deps = {}
    if spec.dependencies then
      local dep_list = type(spec.dependencies) == 'table' and spec.dependencies or
        { spec.dependencies }
      for i = 1, #dep_list do
        local dep = utils.normalize_pack_spec(dep_list[i])
        local target_url = type(dep) == 'string' and dep or (dep.src or dep[1])
        local dep_name = (type(dep) == 'table' and dep.name) or utils.extract_name(target_url)
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

  return nodes, edges
end

---@return table<string, {event:string, chain:string[], replayed:boolean}>
function M.get_replay_info(specs, plugin_triggers)
  local info = {}
  for name, spec in pairs(specs) do
    if spec._replay_done then
      local trigger = plugin_triggers[name] or 'none'
      local chain = {}
      if trigger ~= 'none' and trigger ~= 'Cmd' and trigger ~= 'Keys' and trigger ~= 'FileType' then
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
