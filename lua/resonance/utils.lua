local M = {}

M.is_windows = function()
  return jit.os == 'Windows'
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
