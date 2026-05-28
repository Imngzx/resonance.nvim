local M = {}
local loader = require('resonance.loader')
local ui = require('resonance.ui')

_G.start_time = _G.start_time or vim.uv.hrtime()
_G.end_time = _G.end_time or nil

M.config = {
  ui = {
    border = 'rounded',
    title = ' 󱑽 Resonance 󱑽 ',
    width = 0.65,
    height = 0.75,
    backdrop = 60,
  }
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

function M.load(spec)
  loader.load(spec)
end

function M.trigger_verylazy()
  vim.api.nvim_create_autocmd('UIEnter', {
    once = true,
    callback = function()
      _G.end_time = vim.uv.hrtime()
      vim.cmd('redrawstatus')

      vim.schedule(function()
        vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
      end)
    end,
  })

  -- Fallback for headless or already opened UI
  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = function()
      if #vim.api.nvim_list_uis() == 0 then
        _G.end_time = vim.uv.hrtime()
        vim.schedule(function()
          vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
        end)
      end
    end
  })
end

function M.open_ui()
  ui.open(M.config.ui)
end

return M
