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

local function fallback_scan(plugin_triggers)
  local plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {} }
  local loaded_set = build_loaded_set()
  local loaded_count, total_count = 0, 0

  local req = fs_scandir(pack_dir_base)
  if req then
    while true do
      local name = fs_scandir_next(req)
      if not name then break end
      local pack_subdir = pack_dir_base .. '/' .. name
      local sub_req = fs_scandir(pack_subdir)
      if sub_req then
        while true do
          local pname, ptyp2 = fs_scandir_next(sub_req)
          if not pname then break end
          if ptyp2 == 'directory' then
            local ppath = pack_subdir .. '/' .. pname
            total_count = total_count + 1
            plugins.name[total_count] = pname
            plugins.path[total_count] = ppath
            plugins.type[total_count] = name
            local is_loaded = loaded_set[utils.fast_normalize(ppath)]
            plugins.loaded[total_count] = is_loaded or false
            if is_loaded then loaded_count = loaded_count + 1 end
            plugins.trigger[total_count] = plugin_triggers[pname] or
              (name == 'start' and '󰜎 start' or '󰢱 opt')
          end
        end
      end
    end
  end

  local indices = utils.sort_plugins(plugins, total_count)
  local sorted_plugins = utils.apply_sort(plugins, indices, total_count,
    { 'name', 'type', 'path', 'loaded', 'trigger' })

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

  if vim.pack and vim.pack.get then
    local ok, packs = pcall(vim.pack.get, nil, { info = info_mode, offline = offline })
    if ok and type(packs) == 'table' then
      local plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {}, rev = {}, rev_to = {}, manifest = {} }
      local loaded_count, total_count = 0, 0

      local loaded_set = build_loaded_set()

      for i = 1, #packs do
        local p = packs[i]
        local spec = p.spec
        local name = spec.name
        total_count = total_count + 1

        plugins.name[total_count] = name
        plugins.path[total_count] = p.path
        local is_loaded = loaded_set[utils.fast_normalize(p.path)]
        plugins.loaded[total_count] = is_loaded or false
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
          (plugins.type[total_count] == 'start' and '󰜎 start' or '󰢱 opt')

        if plugins.loaded[total_count] then loaded_count = loaded_count + 1 end
      end

      local indices = utils.sort_plugins(plugins, total_count)
      local sorted_plugins = utils.apply_sort(plugins, indices, total_count,
        { 'name', 'type', 'path', 'loaded', 'trigger', 'rev', 'rev_to', 'manifest' })

      return {
        plugins = sorted_plugins,
        total = total_count,
        loaded = loaded_count,
        pack_dir = pack_dir_base,
        load_times = M.load_times
      }
    end
  end

  return fallback_scan(plugin_triggers)
end

-- Get detailed info for update checking (slow, fetches rev_to, manifest, branches, tags)
function M.get_detailed_info()
  return M.get_info({ info = true, offline = false })
end

return M
