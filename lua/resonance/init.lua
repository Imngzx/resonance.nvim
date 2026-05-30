local M = {}
local loader = require('resonance.loader')
local ui = require('resonance.ui')
local scanner = require('resonance.scanner')

---@diagnostic disable-next-line: undefined-field
M._start_time = _G.start_time or vim.uv.hrtime()
M._end_time = nil

M._cached_stats = nil

---@class ResonanceUIConfig
---@field border? string|table Border style for the UI window
---@field title? string Title of the UI window
---@field width? number Width ratio of the UI window (0 to 1)
---@field height? number Height ratio of the UI window (0 to 1)
---@field backdrop? number Backdrop opacity for snacks.win (0 to 100)

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

--- Setup Resonance global configuration
---@param opts? ResonanceConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})

  vim.api.nvim_create_user_command('Resonance', function()
    M.open_ui()
  end, { desc = 'Open Resonance UI' })
end

---@class ResonanceKeyDef
---@field [1]? string|string[] Mode (e.g., 'n', 'v', {'n', 'v'})
---@field [2]? string Left-hand side (LHS) mapping (e.g., '<leader>f')
---@field [3]? string|function Right-hand side (RHS) mapping action
---@field [4]? table Options (e.g., { desc = "Find file" })
---@field mode? string|string[] Mode (Alternative to [1])
---@field lhs? string LHS (Alternative to [2])
---@field rhs? string|function RHS (Alternative to [3])
---@field opts? table Options (Alternative to [4])

---@class ResonancePluginDef
---@field src? string Plugin URL or Git path
---@field url? string Plugin URL or Git path
---@field name? string Custom name of the plugin
---@field build? string|function Specific build command/hook for this plugin
---@field [1]? string Plugin URL or Git path (Alternative to src/url)

---@alias ResonancePlugin string|ResonancePluginDef

---@class ResonanceLoadSpec
---@field plugin ResonancePlugin|ResonancePlugin[] The plugin(s) to load
---@field event? string|string[]|table Native Neovim event or User event (e.g., "BufReadPre", { "User", pattern = "VeryLazy" })
---@field cmd? string|string[] Command(s) that trigger the plugin load
---@field ft? string|string[] Filetype(s) that trigger the plugin load
---@field keys? ResonanceKeyDef[] Keymaps that trigger the plugin load
---@field build? string|function Global build command (shell string) or Lua function hook
---@field setup? function Callback to execute immediately after plugin is loaded
---@field restore_keys? boolean Whether to restore the mapping after key-triggered load (default: true)

--- Register and conditionally lazy-load a plugin spec
---@param spec ResonanceLoadSpec
function M.load(spec)
  loader.load(spec)
end

--- Get Resonance statistics
---@return table { count: number, loaded: number, startuptime: number, times: table<string, number> }
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

--- Trigger the "VeryLazy" User autocmd (Should be placed at the very end of init.lua)
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

--- Open the Resonance interactive UI panel
function M.open_ui()
  ui.open(M.config.ui)
end

return M
