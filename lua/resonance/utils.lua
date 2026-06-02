local M = {}

M.is_windows = function()
  return jit.os == 'Windows'
end

M.fast_normalize = function(path)
  if not path then return path end
  return M.is_windows() and string.gsub(path, '\\', '/') or path
end

---@param msg string
---@param level integer
---@param opts table|nil
function M.notify(msg, level, opts)
  local ok, snacks = pcall(require, 'snacks')
  if ok and snacks.notifier then
    snacks.notifier.notify(msg, level, opts or { title = 'Resonance' })
  else
    vim.notify('[Resonance] ' .. msg, level, opts)
  end
end

return M
