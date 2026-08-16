local M = {}
local utils = require('resonance.utils')

local uv = vim.uv
local fs_scandir = uv.fs_scandir
local fs_scandir_next = uv.fs_scandir_next
local fn_stdpath = vim.fn.stdpath
local nvim_list_runtime_paths = vim.api.nvim_list_runtime_paths
local table_sort = table.sort
local string_lower = string.lower

M.load_times = {}

local pack_dir_base = utils.fast_normalize(fn_stdpath('data') .. '/site/pack')
local sub_dirs = { 'start', 'opt' }

local function fallback_scan(plugin_triggers)
  local plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {} }
  local loaded_set = {}
  local loaded_count, total_count = 0, 0

  local rtps = nvim_list_runtime_paths()
  for i = 1, #rtps do
    loaded_set[utils.fast_normalize(rtps[i])] = true
  end

  local req = fs_scandir(pack_dir_base)
  if req then
    while true do
      local pkg_name, pkg_type = fs_scandir_next(req)
      if not pkg_name then break end
      if pkg_type == 'directory' or pkg_type == 'link' then
        for i = 1, #sub_dirs do
          local sub = sub_dirs[i]
          local target_dir = pack_dir_base .. '/' .. pkg_name .. '/' .. sub
          local t_req = fs_scandir(target_dir)
          if t_req then
            while true do
              local p_name, p_type = fs_scandir_next(t_req)
              if not p_name then break end
              if p_type == 'directory' or p_type == 'link' then
                total_count = total_count + 1
                local p_path = target_dir .. '/' .. p_name
                local is_loaded = loaded_set[p_path] or loaded_set[utils.fast_normalize(p_path)] or
                false
                if is_loaded then loaded_count = loaded_count + 1 end
                plugins.name[total_count] = p_name
                plugins.type[total_count] = sub
                plugins.path[total_count] = p_path
                plugins.loaded[total_count] = is_loaded
                plugins.trigger[total_count] = plugin_triggers[p_name] or
                  (sub == 'start' and '󰜎 start' or '󰢱 opt')
              end
            end
          end
        end
      end
    end
  end

  local indices = {}
  local lower_names = {}
  for i = 1, total_count do
    indices[i] = i
    lower_names[i] = string_lower(plugins.name[i])
  end

  table_sort(indices, function(a, b)
    if plugins.loaded[a] ~= plugins.loaded[b] then return plugins.loaded[a] end
    return lower_names[a] < lower_names[b]
  end)

  local sorted_plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {} }
  for i = 1, total_count do
    local idx = indices[i]
    sorted_plugins.name[i] = plugins.name[idx]
    sorted_plugins.type[i] = plugins.type[idx]
    sorted_plugins.path[i] = plugins.path[idx]
    sorted_plugins.loaded[i] = plugins.loaded[idx]
    sorted_plugins.trigger[i] = plugins.trigger[idx]
  end

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
  local info_mode = opts.info == true -- default to false for speed
  local offline = opts.offline ~= false -- default to true for speed
  local loader = require('resonance.loader')
  local plugin_triggers = loader.plugin_triggers or {}

  -- Try vim.pack.get() first (Neovim 0.13+)
  if vim.pack and vim.pack.get then
    local ok, packs = pcall(vim.pack.get, nil, { info = info_mode, offline = offline })
    if ok and type(packs) == 'table' then
      local plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {}, rev = {}, rev_to = {}, manifest = {} }
      local loaded_count, total_count = 0, 0

      for i = 1, #packs do
        local p = packs[i]
        local spec = p.spec
        local name = spec.name
        total_count = total_count + 1

        plugins.name[total_count] = name
        plugins.path[total_count] = p.path
        plugins.loaded[total_count] = p.active or false
        plugins.rev[total_count] = p.rev
        plugins.rev_to[total_count] = info_mode and p.rev_to or nil
        plugins.manifest[total_count] = info_mode and p.manifest or nil

        -- Infer type from path: core/opt -> 'opt', else check parent dir name
        local path_lower = string_lower(p.path)
        if path_lower:match('/core/opt/') then
          plugins.type[total_count] = 'opt'
        elseif path_lower:match('/core/start/') then
          plugins.type[total_count] = 'start'
        else
          -- Fallback: check if path contains /opt/ or /start/
          if path_lower:match('/opt/') then
            plugins.type[total_count] = 'opt'
          else
            plugins.type[total_count] = 'start'
          end
        end

        -- Use trigger from loader, fallback to type-based icon
        plugins.trigger[total_count] = plugin_triggers[name] or
          (plugins.type[total_count] == 'start' and '󰜎 start' or '󰢱 opt')

        if plugins.loaded[total_count] then loaded_count = loaded_count + 1 end
      end

      -- Sort: loaded first, then alphabetically
      local indices = {}
      local lower_names = {}
      for i = 1, total_count do
        indices[i] = i
        lower_names[i] = string_lower(plugins.name[i])
      end

      table_sort(indices, function(a, b)
        if plugins.loaded[a] ~= plugins.loaded[b] then return plugins.loaded[a] end
        return lower_names[a] < lower_names[b]
      end)

      local sorted_plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {}, rev = {}, rev_to = {}, manifest = {} }
      for i = 1, total_count do
        local idx = indices[i]
        sorted_plugins.name[i] = plugins.name[idx]
        sorted_plugins.type[i] = plugins.type[idx]
        sorted_plugins.path[i] = plugins.path[idx]
        sorted_plugins.loaded[i] = plugins.loaded[idx]
        sorted_plugins.trigger[i] = plugins.trigger[idx]
        sorted_plugins.rev[i] = plugins.rev[idx]
        sorted_plugins.rev_to[i] = plugins.rev_to[idx]
        sorted_plugins.manifest[i] = plugins.manifest[idx]
      end

      return {
        plugins = sorted_plugins,
        total = total_count,
        loaded = loaded_count,
        pack_dir = pack_dir_base,
        load_times = M.load_times
      }
    end
  end

  -- Fallback to original filesystem scan
  return fallback_scan(plugin_triggers)
end

-- Get detailed info for update checking (slow, fetches rev_to, manifest, branches, tags)
function M.get_detailed_info()
  return M.get_info({ info = true, offline = false })
end

return M

