local M = {}
local loader = require('resonance.loader')
local ui = require('resonance.ui')

M.config = {
  ui = {
    border = 'rounded',
    title = ' 󱑽 Resonance 󱑽 ',
    width = 0.65,
    height = 0.75,
    backdrop = 60, -- 仅对 Snacks 适用
  }
}

--- 插件配置初始化
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

--- 加载插件 (支持 Event, Cmd, Key, Ft, 自动 Build)
---@param spec table
function M.load(spec)
  loader.load(spec)
end

--- 触发生态系统的 VeryLazy (通常在 UIEnter / VimEnter 时触发)
function M.trigger_verylazy()
  vim.api.nvim_create_autocmd('UIEnter', {
    once = true,
    callback = function()
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
        vim.schedule(function()
          vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
        end)
      end
    end
  })
end

--- 打开插件面板 UI
function M.open_ui()
  ui.open(M.config.ui)
end

return M
