local M = {}
local utils = require('resonance.utils')

local uv = vim.uv
local fs_scandir = uv.fs_scandir
local fs_scandir_next = uv.fs_scandir_next
local fn_stdpath = vim.fn.stdpath
local nvim_list_runtime_paths = vim.api.nvim_list_runtime_paths
local string_lower = string.lower
M.load_times = {}

local pack_dir_base = utils.fast_normalize(fn_stdpath('data') .. '/site/pack')

-- Build a set of normalized runtime paths for loaded detection
local function build_loaded_set()
  local loaded_set = {}
  local rtps = nvim_list_runtime_paths()
  for i = 1, #rtps do
    loaded_set[utils.fast_normalize(rtps[i])] = true
  end
  return loaded_set
end

local function append_disabled(plugins, total, disabled_plugins, loader)
  local seen = {}
  for i = 1, total do
    seen[plugins.name[i]] = true
  end

  for name, disabled in pairs(disabled_plugins) do
    if not seen[name] then
      total = total + 1
      plugins.name[total] = name
      plugins.type[total] = 'opt'
      plugins.path[total] = loader.get_plugin_dir(name) or ''
      plugins.loaded[total] = false
      plugins.disabled[total] = true
      plugins.trigger[total] = disabled.trigger or 'none'
      if plugins.rev then
        plugins.rev[total] = nil
        plugins.rev_to[total] = nil
        plugins.manifest[total] = nil
      end
    end
  end

  return total
end

local function fallback_scan(plugin_triggers, disabled_plugins)
  local plugins = { name = {}, type = {}, path = {}, loaded = {}, disabled = {}, trigger = {} }

  local loaded_set = build_loaded_set()
  local loaded_count, total_count = 0, 0

  -- Layout is <data>/site/pack/<group>/<opt|start>/<plugin>.
  local req = fs_scandir(pack_dir_base)
  if req then
    while true do
      local group, group_type = fs_scandir_next(req)
      if not group then break end
      if group_type == 'directory' then
        local group_dir = pack_dir_base .. '/' .. group
        local group_req = fs_scandir(group_dir)
        if group_req then
          while true do
            local kind, kind_type = fs_scandir_next(group_req)
            if not kind then break end
            if kind_type == 'directory' and (kind == 'opt' or kind == 'start') then
              local kind_dir = group_dir .. '/' .. kind
              local kind_req = fs_scandir(kind_dir)
              if kind_req then
                while true do
                  local pname, ptype = fs_scandir_next(kind_req)
                  if not pname then break end
                  if ptype == 'directory' or ptype == 'link' then
                    local ppath = kind_dir .. '/' .. pname
                    total_count = total_count + 1
                    plugins.name[total_count] = pname
                    plugins.path[total_count] = ppath
                    plugins.type[total_count] = kind
                    local is_disabled = disabled_plugins[pname] ~= nil
                    local is_loaded = not is_disabled and loaded_set[utils.fast_normalize(ppath)] or false
                    plugins.loaded[total_count] = is_loaded
                    plugins.disabled[total_count] = is_disabled
                    if is_loaded then loaded_count = loaded_count + 1 end

                    plugins.trigger[total_count] = plugin_triggers[pname] or
                      (is_disabled and disabled_plugins[pname].trigger or
                        (kind == 'start' and '󰜎 start' or '󰢱 opt'))
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  total_count = append_disabled(plugins, total_count, disabled_plugins, require('resonance.loader'))
  local indices = utils.sort_plugins(plugins, total_count)

  local sorted_plugins = utils.apply_sort(plugins, indices, total_count,
    { 'name', 'type', 'path', 'loaded', 'disabled', 'trigger' })

  return {
    plugins = sorted_plugins,
    total = total_count,
    loaded = loaded_count,
    pack_dir = pack_dir_base,
    load_times = M.load_times
  }
end

function M.get_info(opts)
  opts = opts or {}
  local info_mode = opts.info == true
  local offline = opts.offline ~= false
  local loader = require('resonance.loader')
  local plugin_triggers = loader.plugin_triggers or {}
  local disabled_plugins = loader.disabled_plugins or {}

  local pack = utils.get_pack()
  if pack then
    local ok, packs = pcall(pack.get, nil, { info = info_mode, offline = offline })
    if ok and type(packs) == 'table' then
      local plugins = { name = {}, type = {}, path = {}, loaded = {}, disabled = {}, trigger = {}, rev = {}, rev_to = {}, manifest = {} }
      local loaded_count, total_count = 0, 0

      local loaded_set = build_loaded_set()

      for i = 1, #packs do
        local p = packs[i]
        local spec = p.spec
        local name = spec.name
        total_count = total_count + 1

        plugins.name[total_count] = name
        plugins.path[total_count] = p.path
        local is_disabled = disabled_plugins[name] ~= nil
        local is_loaded = not is_disabled and loaded_set[utils.fast_normalize(p.path)] or false
        plugins.loaded[total_count] = is_loaded
        plugins.disabled[total_count] = is_disabled
        plugins.rev[total_count] = p.rev
        plugins.rev_to[total_count] = info_mode and p.rev_to or nil
        plugins.manifest[total_count] = info_mode and p.manifest or nil

        local path_lower = string_lower(p.path)
        if path_lower:match('/core/opt/') then
          plugins.type[total_count] = 'opt'
        elseif path_lower:match('/core/start/') then
          plugins.type[total_count] = 'start'
        else
          if path_lower:match('/opt/') then
            plugins.type[total_count] = 'opt'
          else
            plugins.type[total_count] = 'start'
          end
        end

        plugins.trigger[total_count] = plugin_triggers[name] or
          (is_disabled and disabled_plugins[name].trigger or
            (plugins.type[total_count] == 'start' and '󰜎 start' or '󰢱 opt'))

        if plugins.loaded[total_count] then loaded_count = loaded_count + 1 end
      end

      total_count = append_disabled(plugins, total_count, disabled_plugins, loader)
      local indices = utils.sort_plugins(plugins, total_count)
      local sorted_plugins = utils.apply_sort(plugins, indices, total_count,
        { 'name', 'type', 'path', 'loaded', 'disabled', 'trigger', 'rev', 'rev_to', 'manifest' })

      return {
        plugins = sorted_plugins,
        total = total_count,
        loaded = loaded_count,
        pack_dir = pack_dir_base,
        load_times = M.load_times
      }
    end
  end

  return fallback_scan(plugin_triggers, disabled_plugins)
end

-- Get detailed info for update checking (slow, fetches rev_to, manifest, branches, tags)
function M.get_detailed_info()
  return M.get_info({ info = true, offline = false })
end

return M

