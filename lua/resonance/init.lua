local M = {}
local loader = require('resonance.loader')
local ui = require('resonance.ui')
local scanner = require('resonance.scanner')

M._start_time = _G.start_time or vim.uv.hrtime()
M._end_time = nil

M._cached_stats = nil

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

  vim.api.nvim_create_user_command('Resonance', function()
    M.open_ui()
  end, { desc = 'Open Resonance UI' })
end

function M.load(spec)
  loader.load(spec)
end

function M.stats()
  if M._cached_stats then
    return M._cached_stats
  end

  local info = scanner.get_info()
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
  ui.open(M.config.ui)
end

return M
