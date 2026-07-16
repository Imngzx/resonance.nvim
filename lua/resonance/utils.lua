local M = {}

local pcall = pcall
local type = type
local string_gsub = string.gsub
local string_lower = string.lower
local vim_notify = vim.notify
local jit_os = jit and jit.os or nil

local _snacks_checked = false
local _snacks_notifier = nil

M.is_windows = function() return jit_os == 'Windows' end

M.fast_normalize = function(path)
  if not path then return path end
  return vim.fs.normalize(path)
end

---@param msg string
---@param level integer
---@param opts table|nil
function M.notify(msg, level, opts)
  if not _snacks_checked then
    local ok, snacks = pcall(require, 'snacks')
    if ok and type(snacks) == 'table' and snacks.notifier then
      _snacks_notifier = snacks.notifier
    end
    _snacks_checked = true
  end

  if _snacks_notifier then
    _snacks_notifier.notify(msg, level, opts or { title = 'Resonance' })
  else
    vim_notify('[Resonance] ' .. msg, level, opts)
  end
end

return M
