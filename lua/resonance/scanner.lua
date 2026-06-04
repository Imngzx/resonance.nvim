local M = {}
local utils = require('resonance.utils')

local uv = vim.uv
local fs_scandir = uv.fs_scandir
local fs_scandir_next = uv.fs_scandir_next
local fn_stdpath = vim.fn.stdpath
local nvim_list_runtime_paths = vim.api.nvim_list_runtime_paths
local table_sort = table.sort
local string_lower = string.lower
local ipairs = ipairs

M.load_times = {}

local pack_dir_base = utils.fast_normalize(fn_stdpath('data') .. '/site/pack')
local sub_dirs = { 'start', 'opt' }

function M.get_info()
  local loader = require('resonance.loader')
  local plugin_triggers = loader.plugin_triggers or {}
  local plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {} }
  local loaded_set = {}
  local loaded_count, total_count = 0, 0

  for _, p in ipairs(nvim_list_runtime_paths()) do
    loaded_set[utils.fast_normalize(p)] = true
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

return M
