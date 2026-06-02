local M = {}

---@diagnostic disable-next-line: undefined-field
M._start_time = _G.start_time or vim.uv.hrtime()
M._end_time = nil
M._cached_stats = nil

---@class ResonanceUIConfig
---@field border? string|table
---@field title? string
---@field width? number
---@field height? number
---@field backdrop? number

---@class ResonanceConfig
---@field ui? ResonanceUIConfig

M.config = {
  ui = {
    border = 'rounded',
    title = ' 󱑽 Resonance 󱑽 ',
    width = 0.65,
    height = 0.75,
    backdrop = 60,
  }
}

---@param opts? ResonanceConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  vim.api.nvim_create_user_command('Resonance', function()
    M.open_ui()
  end, { desc = 'Open Resonance UI' })
end

---@class ResonanceKeyDef
---@field [1]? string|string[]
---@field [2]? string
---@field [3]? string|function
---@field [4]? table
---@field mode? string|string[]
---@field lhs? string
---@field rhs? string|function
---@field opts? table

---@class ResonancePluginDef
---@field src? string
---@field url? string
---@field name? string
---@field build? string|function
---@field [1]? string

---@alias ResonancePlugin string|ResonancePluginDef

---@class ResonanceLoadSpec
---@field plugin ResonancePlugin|ResonancePlugin[]
---@field event? string|string[]|table
---@field cmd? string|string[]
---@field ft? string|string[]
---@field keys? ResonanceKeyDef[]
---@field build? string|function
---@field setup? function
---@field restore_keys? boolean

---@param spec ResonanceLoadSpec
function M.load(spec)
  require('resonance.loader').load(spec)
end

---@return table
function M.stats()
  if M._cached_stats then
    return M._cached_stats
  end

  local info = require('resonance.scanner').get_info()
  local ms = 0

  if M._start_time then
    M._end_time = M._end_time or vim.uv.hrtime()
    ms = (M._end_time - M._start_time) / 1e6
  end

  M._cached_stats = {
    count = info.total,
    loaded = info.loaded,
    startuptime = ms,
    times = info.load_times,
  }

  return M._cached_stats
end

function M.trigger_verylazy()
  vim.api.nvim_create_autocmd('UIEnter', {
    once = true,
    callback = function()
      M._end_time = M._end_time or vim.uv.hrtime()
      vim.cmd('redrawstatus')
      vim.schedule(function()
        vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
      end)
    end,
  })

  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = function()
      if #vim.api.nvim_list_uis() == 0 then
        M._end_time = M._end_time or vim.uv.hrtime()
        vim.schedule(function()
          vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
        end)
      end
    end
  })
end

function M.open_ui()
  require('resonance.ui').open(M.config.ui)
end

return M
