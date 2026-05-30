local M = {}

--- 判断是否为 Windows 系统
M.is_windows = function()
  return jit.os == 'Windows'
end

--- 自适应的通知器 (优先 Snacks，否则原生)
---@param msg string
---@param level integer
---@param opts table|nil
function M.notify(msg, level, opts)
  local ok, snacks = pcall(require, 'snacks')
  if ok and snacks.notifier then
    -- 如果有 Snacks，通过 snacks.notifier 渲染
    snacks.notifier.notify(msg, level, opts or { title = 'Resonance' })
  else
    -- 否则使用原生通知
    vim.notify('[Resonance] ' .. msg, level, opts)
  end
end

return M
