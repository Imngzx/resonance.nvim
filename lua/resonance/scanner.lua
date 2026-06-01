local M = {}

M.load_times = {}

local pack_dir_base = vim.fs.normalize(vim.fn.stdpath('data') .. '/site/pack')
local sub_dirs = { 'start', 'opt' }

function M.get_info()
  -- 【SOA 优化保留】: 只创建 4 个 Table，极低 GC 压力
  local plugins = { name = {}, type = {}, path = {}, loaded = {} }
  local loaded_set = {}
  local loaded_count, total_count = 0, 0

  for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
    loaded_set[vim.fs.normalize(p)] = true
  end

  local stat = vim.uv.fs_stat(pack_dir_base)
  if stat and stat.type == 'directory' then
    -- 换回安全的 vim.fs.dir，完美解决底层 d_type 丢失导致的插件不可见问题
    for pkg_name, pkg_type in vim.fs.dir(pack_dir_base) do
      if pkg_type == 'directory' or pkg_type == 'link' then
        for i = 1, #sub_dirs do
          local sub = sub_dirs[i]
          local target_dir = pack_dir_base .. '/' .. pkg_name .. '/' .. sub
          local t_stat = vim.uv.fs_stat(target_dir)

          if t_stat and (t_stat.type == 'directory' or t_stat.type == 'link') then
            for p_name, p_type in vim.fs.dir(target_dir) do
              if p_type == 'directory' or p_type == 'link' then
                total_count = total_count + 1
                local p_path = target_dir .. '/' .. p_name

                -- 严格校验路径匹配
                local is_loaded = loaded_set[p_path] or loaded_set[vim.fs.normalize(p_path)] or false
                if is_loaded then loaded_count = loaded_count + 1 end

                plugins.name[total_count] = p_name
                plugins.type[total_count] = sub
                plugins.path[total_count] = p_path
                plugins.loaded[total_count] = is_loaded
              end
            end
          end
        end
      end
    end
  end

  local indices = {}
  for i = 1, total_count do indices[i] = i end
  table.sort(indices, function(a, b)
    if plugins.loaded[a] ~= plugins.loaded[b] then return plugins.loaded[a] end
    return plugins.name[a]:lower() < plugins.name[b]:lower()
  end)

  local sorted_plugins = { name = {}, type = {}, path = {}, loaded = {} }
  for i = 1, total_count do
    local idx = indices[i]
    sorted_plugins.name[i] = plugins.name[idx]
    sorted_plugins.type[i] = plugins.type[idx]
    sorted_plugins.path[i] = plugins.path[idx]
    sorted_plugins.loaded[i] = plugins.loaded[idx]
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
