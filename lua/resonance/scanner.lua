local M = {}

-- 用于存储各个插件的加载耗时 (毫秒)
M.load_times = {}

function M.get_info()
  local pack_dir = vim.fs.normalize(vim.fn.stdpath('data') .. '/site/pack')
  local plugins = {}
  local loaded_set = {}
  local loaded_count, total_count = 0, 0
  local sub_dirs = { 'start', 'opt' }
  local pack_stat = vim.uv.fs_stat(pack_dir)

  for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
    loaded_set[vim.fs.normalize(p)] = true
  end

  if pack_stat and pack_stat.type == 'directory' then
    for pkg_name, pkg_type in vim.fs.dir(pack_dir) do
      if pkg_type == 'directory' then
        for _, sub in ipairs(sub_dirs) do
          local target_dir = pack_dir .. '/' .. pkg_name .. '/' .. sub
          local stat = vim.uv.fs_stat(target_dir)
          if stat and stat.type == 'directory' then
            for plugin_name, p_type in vim.fs.dir(target_dir) do
              if p_type == 'directory' then
                total_count = total_count + 1
                local p_path = target_dir .. '/' .. plugin_name
                local is_loaded = loaded_set[p_path] or false
                if is_loaded then loaded_count = loaded_count + 1 end
                table.insert(plugins,
                  { name = plugin_name, type = sub, path = p_path, loaded = is_loaded })
              end
            end
          end
        end
      end
    end
  end

  table.sort(plugins, function(a, b)
    if a.loaded ~= b.loaded then return a.loaded end
    return a.name:lower() < b.name:lower()
  end)

  -- 把 load_times 也一并返回给 UI
  return {
    plugins = plugins,
    total = total_count,
    loaded = loaded_count,
    pack_dir = pack_dir,
    load_times = M.load_times
  }
end

return M
