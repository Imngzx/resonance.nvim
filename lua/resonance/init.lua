local M = {}

local vim_api = vim.api
local create_autocmd = vim_api.nvim_create_autocmd
local exec_autocmds = vim_api.nvim_exec_autocmds
local create_user_command = vim_api.nvim_create_user_command
local list_uis = vim_api.nvim_list_uis
local create_augroup = vim_api.nvim_create_augroup
local list_bufs = vim_api.nvim_list_bufs
local buf_is_loaded = vim_api.nvim_buf_is_loaded
local buf_get_name = vim_api.nvim_buf_get_name
local hrtime = vim.uv.hrtime
local schedule = vim.schedule
local vim_tbl_deep_extend = vim.tbl_deep_extend

---@diagnostic disable-next-line: undefined-field
M._start_time = _G.start_time or hrtime()
M._end_time = nil
local loader_mod = nil

-- The startup time is a one-shot measurement: it is the time from the
-- start of Neovim to the moment the UI became usable. It is latched once
-- and never changes afterwards.
--
-- The plugin counts are not: a plugin can load at any point, so they are
-- read live from the scanner on every call.
local function startup_ms()
  if not M._start_time then return 0 end
  M._end_time = M._end_time or hrtime()
  return (M._end_time - M._start_time) / 1e6
end

---@class ResonanceUIConfig
---@field border? string|table
---@field title? string
---@field width? number
---@field height? number
---@field backdrop? number
---@field icons? ResonanceUIConfigIcons Glyphs for loaded / not loaded / disabled plugins

---@class ResonanceBuildConfig
---@field concurrency? integer How many build commands run at once (default: 2)
---@field progress? boolean Report builds as progress messages (default: true)

---@class ResonanceResonateConfig
---@field concurrency? integer How many `git fetch` run at once on Resonate (default: 2 x CPU threads, like vim.pack)

---@class ResonanceConfig
---@field ui? ResonanceUIConfig
---@field build? ResonanceBuildConfig
---@field resonate? ResonanceResonateConfig
---@field replay? boolean Replay the read events for open buffers after VeryLazy (default: true)

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
---@field priority? integer Registration order within one import() call, highest first (default 0). Used by import() only

M.config = {
  ui = {
    border = 'rounded',
    title = ' 󱑽 Resonance 󱑽 ',
    width = 0.65,
    height = 0.75,
    backdrop = 60,
  },
  replay = true,
  build = {
    concurrency = 2,
    progress = true,
  },
  -- `concurrency` is left unset on purpose: the default depends on the
  -- machine (2 x CPU threads) and is filled in by ui/actions.lua.
  resonate = {},
}

-- VeryLazy is armed by setup() and load() themselves. It used to need a
-- trigger_verylazy() call at the end of init.lua, and a config that forgot
-- it never loaded a single VeryLazy plugin.
--
-- The generation guards against a module instance that is no longer
-- current: _reset() bumps it, so a callback armed before the reset sees a
-- different number and does nothing. The test runner builds a fresh module
-- for every test, and each one arms VeryLazy again.
local verylazy_generation = 0
local verylazy_armed = false
local verylazy_fired = false

-- Give the trigger groups registered during VeryLazy their chance at the
-- buffers that were read before them. `nvim <file>` reads the file before
-- UIEnter, so a plugin that registers its BufReadPost trigger in VeryLazy
-- would otherwise never see that file.
local function replay_loaded_buffers()
  loader_mod = loader_mod or require('resonance.loader')
  local bufs = list_bufs()
  for i = 1, #bufs do
    local buf = bufs[i]
    if buf_is_loaded(buf) and buf_get_name(buf) ~= '' then
      pcall(loader_mod.replay_for_buffer, buf)
    end
  end
end

---@param generation integer the generation that armed this fire
local function fire_verylazy(generation)
  if generation ~= verylazy_generation or verylazy_fired then return end
  verylazy_fired = true
  -- The loader reads this for a spec registered from now on: its VeryLazy
  -- trigger has nothing left to wait for.
  require('resonance.registry').verylazy_fired = true

  -- The startup time is latched here as well as at UIEnter/VimEnter: when
  -- Resonance is loaded after startup, those events never come, and the
  -- time kept growing until the first stats() call.
  M._end_time = M._end_time or hrtime()

  -- The exec is synchronous: every VeryLazy callback has registered its
  -- triggers by the time it returns, which is the one moment the replay
  -- can see them all. A scheduled replay runs after the `once` triggers
  -- were consumed and fires into nothing.
  local ok, err = pcall(exec_autocmds, 'User', { pattern = 'VeryLazy' })

  -- Read when firing, not when arming: load() can arm VeryLazy before the
  -- user's setup({ replay = false }) has run.
  if M.config.replay ~= false then
    replay_loaded_buffers()
  end

  if not ok then
    require('resonance.utils').notify('VeryLazy failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function arm_verylazy()
  if verylazy_armed then return end
  verylazy_armed = true
  local generation = verylazy_generation

  -- Startup is already over -- Resonance itself was loaded late. The
  -- events below will not come again, so VeryLazy fires now.
  if vim.v.vim_did_enter == 1 then
    schedule(function() fire_verylazy(generation) end)
    return
  end

  local group = create_augroup('ResonanceVeryLazy', { clear = true })

  create_autocmd('UIEnter', {
    group = group,
    once = true,
    callback = function()
      if generation ~= verylazy_generation then return end
      M._end_time = M._end_time or hrtime()
      vim.cmd.redrawstatus()
      schedule(function() fire_verylazy(generation) end)
    end,
  })

  -- Headless: there is no UI to wait for, so VimEnter is the end of startup.
  create_autocmd('VimEnter', {
    group = group,
    once = true,
    callback = function()
      if generation ~= verylazy_generation then return end
      if #list_uis() == 0 then
        M._end_time = M._end_time or hrtime()
        schedule(function() fire_verylazy(generation) end)
      end
    end,
  })
end

---@param opts? ResonanceConfig
function M.setup(opts)
  M.config = vim_tbl_deep_extend('force', M.config, opts or {})
  arm_verylazy()
  create_user_command('Resonance', function()
    M.open_ui()
  end, { desc = 'Open Resonance UI' })

  -- The loader's event tracker has to be in place before the first read
  -- event fires, or the events that already fired are not recorded and
  -- the replay fires them a second time.
  if not loader_mod then
    loader_mod = require('resonance.loader')
  end
  loader_mod.setup()
  -- The loader has already required the build module, so this costs
  -- nothing extra at startup.
  require('resonance.loader.build').configure(M.config.build)
end

---@param spec ResonanceLoadSpec|ResonanceLoadSpec[]
function M.load(spec)
  arm_verylazy()
  if not loader_mod then
    loader_mod = require('resonance.loader')
  end
  loader_mod.load(spec)
end

--- Import a folder of spec modules (optional, lazy.nvim style).
---
--- Requires every top-level module under <root>/<mod>/ -- `*.lua` files and
--- folders with an init.lua -- and registers the spec or list of specs each
--- one returns, highest `priority` first. Nothing is scanned unless this is
--- called, so listing specs by hand with load() costs nothing extra.
---@param mod string module path, e.g. 'plugins' for lua/plugins/
---@param opts? ResonanceImportOpts
function M.import(mod, opts)
  arm_verylazy()
  require('resonance.scandir').import(mod, opts)
end

--- Whether an event has already fired for a buffer.
---
--- Use this to avoid replaying an event that already ran: firing it twice
--- makes every handler run twice.
---@param event string
---@param buf integer
---@return boolean
function M.has_fired(event, buf)
  if not loader_mod then
    loader_mod = require('resonance.loader')
  end
  return loader_mod.has_fired(event, buf)
end

--- Replay the read events a buffer has already missed.
---
--- Fires only the events that have not run for the buffer yet, so a handler
--- is not invoked twice for the same read. Events still pending for the
--- current read are left alone: Neovim fires them naturally.
---@param buf integer
---@return string[] fired the events that were replayed
function M.replay_for_buffer(buf)
  if not loader_mod then
    loader_mod = require('resonance.loader')
  end
  return loader_mod.replay_for_buffer(buf)
end

---Plugin statistics.
---
---`startuptime` is latched at UIEnter/VimEnter (or on the first call, if
---that comes first) and never changes: it is the time from startup to the
---moment the UI became usable.
---
---`count`, `loaded` and `times` are read live, because a plugin can load
---at any point -- after the first call, or never.
---@return table
function M.stats()
  local info = require('resonance.scanner').get_info()

  return {
    count = info.total,
    loaded = info.loaded,
    startuptime = startup_ms(),
    times = info.load_times,
  }
end

---Reset the module state (for testing).
---
---Clears the latched startup time and the cached loader module, so a
---fresh `stats()` call measures from the start again.
function M._reset()
  M._end_time = nil
  loader_mod = nil
  -- A callback armed before the reset must not fire into the next state.
  verylazy_generation = verylazy_generation + 1
  verylazy_armed = false
  verylazy_fired = false
  require('resonance.registry').verylazy_fired = false
end

function M.open_ui()
  -- Applied here, not in setup(): the panel modules are not loaded at
  -- startup, and the limit is only read when `r` starts a check.
  require('resonance.ui.actions').configure(M.config.resonate)
  require('resonance.ui').open(M.config.ui)
end

return M

-- "Powered by Solaris-3 Terminal and Resonator of NVIM".
