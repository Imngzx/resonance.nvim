local M = {}

local vim_api = vim.api
local create_autocmd = vim_api.nvim_create_autocmd
local exec_autocmds = vim_api.nvim_exec_autocmds
local create_user_command = vim_api.nvim_create_user_command
local list_uis = vim_api.nvim_list_uis
local hrtime = vim.uv.hrtime
local schedule = vim.schedule
local vim_cmd = vim.cmd
local vim_tbl_deep_extend = vim.tbl_deep_extend

---@diagnostic disable-next-line: undefined-field
M._start_time = _G.start_time or hrtime()
M._end_time = nil
M._cached_stats = nil
local loader_mod = nil

---@class ResonanceUIConfig
---@field border? string|table
---@field title? string
---@field width? number
---@field height? number
---@field backdrop? number

---@class ResonanceConfig
---@field ui? ResonanceUIConfig

---@class ResonanceKeyDef
---@field [1]? string|string[] Mode (e.g., "n", "i", {"n", "v"}). Default: "n"
---@field [2]? string LHS (Key mapping, e.g., "<leader>ff")
---@field [3]? string|function RHS (Command string or Lua function)
---@field [4]? table Options (e.g., { desc = "Find files" })
---@field mode? string|string[]
---@field lhs? string
---@field rhs? string|function
---@field opts? table

---@class ResonancePluginDef
---@field [1]? string Plugin Full URL (e.g., "https://github.com/user/repo")
---@field src? string Alias for URL
---@field url? string Alias for URL
---@field version? string Branch, tag, or commit hash to checkout
---@field name? string Custom name for the plugin directory
---@field build? string|function Build command (e.g., "make") or Lua function

---@alias ResonancePlugin string|ResonancePluginDef

---@class ResonanceLoadSpec : ResonancePluginDef
---@field plugin? ResonancePlugin|ResonancePlugin[] Main plugin(s) to load. Can be omitted if URL is passed as `[1]`
---@field dependencies? ResonancePlugin|ResonancePlugin[] Plugins to load before this plugin
---@field event? string|string[]|table Lazy load on Neovim events (e.g., "BufReadPre", {"User", pattern = "VeryLazy"})
---@field cmd? string|string[] Lazy load on Ex commands (e.g., "Telescope")
---@field ft? string|string[] Lazy load on FileTypes (e.g., "markdown")
---@field keys? ResonanceKeyDef[] Lazy load on key mappings
---@field setup? function Callback executed immediately after the plugin is loaded via `vim.pack`
---@field config? function Alias for `setup`, perfectly compatible with lazy.nvim
---@field restore_keys? boolean Restore the original key mapping after lazy loading (default: true)

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
  M.config = vim_tbl_deep_extend('force', M.config, opts or {})
  create_user_command('Resonance', function()
    M.open_ui()
  end, { desc = 'Open Resonance UI' })
end

---@param spec ResonanceLoadSpec|ResonanceLoadSpec[]
function M.load(spec)
  if not loader_mod then
    loader_mod = require('resonance.loader')
  end
  loader_mod.load(spec)
end

---@return table
function M.stats()
  if not M._cached_stats then
    local ms = 0
    if M._start_time then
      M._end_time = M._end_time or hrtime()
      ms = (M._end_time - M._start_time) / 1e6
    end

    local info = require('resonance.scanner').get_info()

    M._cached_stats = {
      count = info.total,
      loaded = info.loaded,
      startuptime = ms,
      times = info.load_times,
    }
  end

  return M._cached_stats
end

function M.trigger_verylazy()
  create_autocmd('UIEnter', {
    once = true,
    callback = function()
      M._end_time = M._end_time or hrtime()
      vim_cmd('redrawstatus')
      schedule(function()
        exec_autocmds('User', { pattern = 'VeryLazy' })
      end)
    end,
  })

  create_autocmd('VimEnter', {
    once = true,
    callback = function()
      if #list_uis() == 0 then
        M._end_time = M._end_time or hrtime()
        schedule(function()
          exec_autocmds('User', { pattern = 'VeryLazy' })
        end)
      end
    end
  })
end

function M.open_ui()
  require('resonance.ui').open(M.config.ui)
end

return M

-- "Powered by Solaris-3 Terminal and Resonator of NVIM".
