local M = {}

M.load_times = {}

local pack_dir_base = vim.fs.normalize(vim.fn.stdpath('data') .. '/site/pack')

function M.get_info()
  local plugins = {}
  local loaded_set = {}
  local loaded_count, total_count = 0, 0
  local sub_dirs = { 'start', 'opt' }
  local pack_stat = vim.uv.fs_stat(pack_dir_base)

  for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
    loaded_set[vim.fs.normalize(p)] = true
  end

  if pack_stat and pack_stat.type == 'directory' then
    for pkg_name, pkg_type in vim.fs.dir(pack_dir_base) do
      if pkg_type == 'directory' then
        for i = 1, #sub_dirs do
          local sub = sub_dirs[i]
          local target_dir = pack_dir_base .. '/' .. pkg_name .. '/' .. sub
          local stat = vim.uv.fs_stat(target_dir)
          if stat and stat.type == 'directory' then
            for plugin_name, p_type in vim.fs.dir(target_dir) do
              if p_type == 'directory' then
                total_count = total_count + 1
                local p_path = target_dir .. '/' .. plugin_name
                local is_loaded = loaded_set[p_path] or false
                if is_loaded then loaded_count = loaded_count + 1 end
                plugins[#plugins + 1] = {
                  name = plugin_name,
                  type = sub,
                  path = p_path,
                  loaded =
                    is_loaded
                }
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

  return {
    plugins = plugins,
    total = total_count,
    loaded = loaded_count,
    pack_dir = pack_dir_base,
    load_times = M.load_times
  }
end

return M
