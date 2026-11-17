local M = {}
local utils = require('resonance.utils')

local api = vim.api
local get_autocmds = api.nvim_get_autocmds

local type = type
local pairs = pairs

-- BufRead and BufReadPost are aliases in Neovim: an autocmd registered for
-- one fires for the other, and get_autocmds matches them together. Canonicalise
-- to BufReadPost, which is the name Neovim reports, so a chain entry always
-- reflects the autocmds that actually run for it.
local function canonical_event(event)
  if event == 'BufRead' then return 'BufReadPost' end
  return event
end

local function autocmds_for(event)
  local all = get_autocmds({ event = event })
  local exact = {}
  local want = canonical_event(event)
  for i = 1, #all do
    if canonical_event(all[i].event) == want then exact[#exact + 1] = all[i] end
  end
  return exact
end

local function get_event_chain(event, buf, data)
  local chain = {}
  local current = canonical_event(event)
  local visited = {}

  -- Groups that already ran for the originating event. They have seen the
  -- event, so replaying them would duplicate their work.
  local origin_exclude = {}
  local origin_autocmds = autocmds_for(current)
  for a = 1, #origin_autocmds do
    local group_name = origin_autocmds[a].group_name
    if group_name then origin_exclude[group_name] = true end
  end

  while current and not visited[current] do
    visited[current] = true
    -- Query without a buffer filter: global autocmds are excluded by the
    -- `buf` option, and most plugin triggers are global.
    local autocmds = autocmds_for(current)
    if #autocmds > 0 then
      chain[#chain + 1] = {
        event = current,
        buf = buf,
        exclude = current == event and origin_exclude or {},
        data = data,
      }
    end

    if current == 'BufReadPre' then
      current = 'BufReadPost'
    elseif current == 'BufNewFile' then
      current = 'BufReadPost'
    else
      break
    end
  end

  return chain
end

---@return table<string, {name:string, deps:string[], trigger:string, loaded:boolean, disabled:boolean}>, table<string, string[]>
function M.get_dag_data(specs, plugin_state, scanner_info, disabled_plugins)

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
  local scanner_disabled = {}

  if scanner_info and scanner_info.plugins then
    local sp = scanner_info.plugins
    for i = 1, scanner_info.total do
      local name = sp.name[i]
      scanner_loaded[name] = sp.loaded[i]
      scanner_trigger[name] = sp.trigger[i]
      scanner_type[name] = sp.type[i]
      scanner_disabled[name] = sp.disabled and sp.disabled[i] or false
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
    local state = plugin_state[name]
    local disabled = disabled_plugins and disabled_plugins[name] ~= nil or false
    nodes[name] = {
      name = name,
      deps = deps,
      trigger = trig_str or 'none',
      loaded = state and state.loaded or false,
      disabled = disabled,
    }
    edges[name] = deps

  end
  for name, disabled in pairs(disabled_plugins or {}) do
    if not nodes[name] then
      nodes[name] = {
        name = name,
        deps = {},
        trigger = disabled.trigger or 'none',
        loaded = false,
        disabled = true,
      }
      edges[name] = {}
    end
  end


  -- Second pass: add dependency nodes that are installed but not in specs
  -- These are plugins that are dependencies of other plugins but not explicitly configured
  if scanner_info and scanner_info.plugins then
    for i = 1, scanner_info.total do
      local name = scanner_info.plugins.name[i]
      if not nodes[name] and (all_dep_names[name] or scanner_loaded[name] or scanner_disabled[name]) then
        -- This is a dependency plugin not explicitly in specs
        nodes[name] = {
          name = name,
          deps = {},
          trigger = scanner_trigger[name] or (scanner_type[name] == 'start' and '󰜎 start' or '󰢱 opt'),
          loaded = scanner_loaded[name] or false,
          disabled = scanner_disabled[name] or false,
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
        local events = utils.normalize_events(spec.event)
        for i = 1, #events do
          local e = events[i]
          -- A User event has no successor chain: it is fired by name, not
          -- by an event that triggers it.
          if not e.user then
            local autocmds = autocmds_for(e.event)
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