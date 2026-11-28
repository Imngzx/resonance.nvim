local M = {}
local api = vim.api
local uv = vim.uv

local string_match = string.match
local vim_trim = vim.trim
local uv_fs_open = uv.fs_open
local uv_fs_close = uv.fs_close
local uv_fs_read = uv.fs_read
local uv_fs_fstat = uv.fs_fstat

local nvim_create_namespace = api.nvim_create_namespace
local nvim_get_hl = api.nvim_get_hl
local nvim_set_hl = api.nvim_set_hl
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_win_get_cursor = api.nvim_win_get_cursor

M.ns = nvim_create_namespace('resonance_ui')

---Default glyphs for plugin state. Overridable via `setup({ ui = { icons = { ... } } })`.
---@class ResonanceUIConfigIcons
---@field loaded string Glyph for a loaded plugin
---@field not_loaded string Glyph for a plugin that is not loaded
---@field disabled string Glyph for a plugin disabled by `cond`

---@type ResonanceUIConfigIcons
M.DEFAULT_ICONS = {
  loaded = '●',
  not_loaded = '○',
  disabled = '\u{F057}',
}

---Copy of the defaults, so callers cannot mutate the shared table.
---@return ResonanceUIConfigIcons
function M.default_icons()
  return {
    loaded = M.DEFAULT_ICONS.loaded,
    not_loaded = M.DEFAULT_ICONS.not_loaded,
    disabled = M.DEFAULT_ICONS.disabled,
  }
end

---Default keybindings for the UI panel. Overridable via `setup({ ui = { keys = { ... } } })`.
---Each entry is a key string, a list of key strings, or `false` to disable the binding.
---@alias ResonanceUIKey string|string[]|false

---@class ResonanceUIConfigKeys
---@field close? ResonanceUIKey Close the UI (default: `{ 'q', '<Esc>' }`)
---@field toggle_details? ResonanceUIKey Expand/collapse plugin details (default: `'<CR>'`)
---@field resonate? ResonanceUIKey Check for updates over the network (default: `'r'`)
---@field update? ResonanceUIKey Update plugin at cursor (default: `'u'`)
---@field update_all? ResonanceUIKey Update all pending plugins (default: `'U'`)
---@field skip? ResonanceUIKey Skip pending update for plugin at cursor (default: `'s'`)
---@field uninstall? ResonanceUIKey Uninstall plugin at cursor (default: `'dd'`)
---@field search? ResonanceUIKey Search plugin sources (default: `'S'`)
---@field open_dir? ResonanceUIKey Open pack directory (default: `'D'`)
---@field review? ResonanceUIKey Open native vim.pack update review (default: `'C'`)
---@field checkout? ResonanceUIKey Checkout branch/tag/commit for plugin at cursor (default: `'c'`)
---@field dag? ResonanceUIKey Toggle DAG view (default: `'A'`)

---@type table<string, ResonanceUIKey>
M.DEFAULT_KEYS = {
  close = { 'q', '<Esc>' },
  toggle_details = '<CR>',
  resonate = 'r',
  update = 'u',
  update_all = 'U',
  skip = 's',
  uninstall = 'dd',
  search = 'S',
  open_dir = 'D',
  review = 'C',
  checkout = 'c',
  dag = 'A',
}

---Copy of the default keybindings, so callers cannot mutate the shared table.
---@return table<string, ResonanceUIKey>
function M.default_keys()
  local copy = {}
  for k, v in pairs(M.DEFAULT_KEYS) do
    if type(v) == 'table' then
      local list = {}
      for i = 1, #v do list[i] = v[i] end
      copy[k] = list
    else
      copy[k] = v
    end
  end
  return copy
end

---@class ResonancePluginSOA
---@field name string[]
---@field type string[]
---@field path string[]
---@field loaded boolean[]
---@field disabled boolean[]
---@field trigger string[]

---@class ResonanceScannerInfo
---@field plugins ResonancePluginSOA
---@field total integer
---@field loaded integer
---@field pack_dir string
---@field load_times table<string, number>
---@class ResonanceUIState
---@field buf? integer
---@field win? integer
---@field win_width integer
---@field info? ResonanceScannerInfo
---@field commits table<string, string>
---@field updates table<string, string[]>
---@field urls table<string, string>
---@field expanded table<string, boolean>
---@field checking boolean
---@field updating boolean
---@field spinner_frame integer
---@field spinner_line_idx? integer
---@field pending_count integer
---@field fetch_done integer
---@field fetch_total integer
---@field restore_cursor_name? string
---@field pack_details table<string, table>
---@field line_to_name table<number, string>
---@field name_to_line table<string, number>
---@field view_mode string  -- 'list' | 'dag'
---@field dag_data table    -- { nodes: table<string, {name:string, deps:string[], trigger:string, loaded:boolean}>, edges: table<string, string[]> }
---@field replay_info table<string, {event:string, chain:string[], replayed:boolean}>
---@field icons ResonanceUIConfigIcons
---@field keys table<string, ResonanceUIKey>
---@field details_task? vim.async.Task  -- cancellable task for the deferred details pass
M.state = {
  buf = nil,
  win = nil,
  details_task = nil,
  win_width = 80,
  info = nil,
  commits = {},
  updates = {},
  urls = {},
  expanded = {},
  pack_details = {},
  checking = false,
  updating = false,
  spinner_frame = 1,
  spinner_line_idx = nil,
  pending_count = 0,
  fetch_done = 0,
  fetch_total = 0,
  line_to_name = {},
  name_to_line = {},
  restore_cursor_name = nil,
  view_mode = 'list',
  dag_data = { nodes = {}, edges = {} },
  icons = M.default_icons(),
  keys = M.default_keys(),
}

-- Reset all UI state (for testing)
function M._reset()
  M.state.buf = nil
  M.state.win = nil
  M.state.details_task = nil
  M.state.win_width = 80
  M.state.info = nil
  for k in pairs(M.state.commits) do M.state.commits[k] = nil end
  for k in pairs(M.state.updates) do M.state.updates[k] = nil end
  for k in pairs(M.state.urls) do M.state.urls[k] = nil end
  for k in pairs(M.state.expanded) do M.state.expanded[k] = nil end
  for k in pairs(M.state.pack_details) do M.state.pack_details[k] = nil end
  M.state.checking = false
  M.state.updating = false
  M.state.spinner_frame = 1
  M.state.spinner_line_idx = nil
  M.state.pending_count = 0
  M.state.fetch_done = 0
  M.state.fetch_total = 0
  for k in pairs(M.state.line_to_name) do M.state.line_to_name[k] = nil end
  for k in pairs(M.state.name_to_line) do M.state.name_to_line[k] = nil end
  M.state.restore_cursor_name = nil
  M.state.view_mode = 'list'
  M.state.dag_data = { nodes = {}, edges = {} }
  M.state.replay_info = {}
  M.state.icons = M.default_icons()
  M.state.keys = M.default_keys()
end

function M.init_hls()
  local cl = nvim_get_hl(0, { name = 'CursorLine' })
  local fn = nvim_get_hl(0, { name = 'Function' })
  local cm = nvim_get_hl(0, { name = 'Comment' })
  local di = nvim_get_hl(0, { name = 'DiagnosticInfo' })
  local er = nvim_get_hl(0, { name = 'DiagnosticError' })
  ---@diagnostic disable-next-line: unused-local
  local wa = nvim_get_hl(0, { name = 'DiagnosticWarn' })
  ---@diagnostic disable-next-line: unused-local
  local ok = nvim_get_hl(0, { name = 'DiagnosticOk' })
  local hi = nvim_get_hl(0, { name = 'DiagnosticHint' })
  local st = nvim_get_hl(0, { name = 'Statement' })
  local ty = nvim_get_hl(0, { name = 'Type' })
  ---@diagnostic disable-next-line: unused-local
  local co = nvim_get_hl(0, { name = 'Constant' })
  local sp = nvim_get_hl(0, { name = 'Special' })

  nvim_set_hl(0, 'ResoBtnKey', { fg = fn.fg, bg = cl.bg, default = true })
  nvim_set_hl(0, 'ResoBtnText', { fg = cm.fg, bg = cl.bg, default = true })

  nvim_set_hl(0, 'ResoBtnResonateKey', { fg = di.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnResonateText', { fg = di.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnDAGKey', { fg = ty.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnDAGText', { fg = ty.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnUpdateKey', { fg = st.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnUpdateText', { fg = st.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnUpdateAllKey', { fg = st.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnUpdateAllText', { fg = st.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnSkipKey', { fg = hi.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnSkipText', { fg = hi.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnCheckoutKey', { fg = sp.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnCheckoutText', { fg = sp.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnReviewKey', { fg = hi.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnReviewText', { fg = hi.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnUninstallKey', { fg = er.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnUninstallText', { fg = er.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnSearchKey', { fg = di.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnSearchText', { fg = di.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnDirKey', { fg = di.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnDirText', { fg = di.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnQuitKey', { fg = fn.fg, bg = cl.bg, default = true })
  nvim_set_hl(0, 'ResoBtnQuitText', { fg = cm.fg, bg = cl.bg, default = true })
end

function M.is_valid()
  return M.state.buf and nvim_buf_is_valid(M.state.buf)
end

function M.plugin_at_cursor()
  if not M.state.win or not nvim_win_is_valid(M.state.win) then return nil end
  local row = nvim_win_get_cursor(M.state.win)[1]
  -- The renderer marks a plugin's row and every detail line under it. A
  -- line it did not mark -- a blank line, a section title, the header --
  -- belongs to no plugin. Walking up to the nearest plugin from such a
  -- line made `u` on "Up To Date (3)" update the plugin above it, and `dd`
  -- offer to uninstall it.
  return M.state.line_to_name[row]
end

function M.get_src_url(path)
  -- A disabled plugin has no directory; '' .. '/.git/config' read the
  -- config of a repository at the filesystem root.
  if not path or path == '' then return 'unknown' end
  local fd = uv_fs_open(path .. '/.git/config', 'r', 438)
  if not fd then return 'unknown' end

  local stat = uv_fs_fstat(fd)
  local content = stat and uv_fs_read(fd, stat.size, 0) or uv_fs_read(fd, 65536, 0) or ''
  uv_fs_close(fd)

  local url = string_match(content, '%[remote%s+"origin"%][^%[]-url%s*=%s*([^\n]+)')
  return url and vim_trim(url) or 'unknown'
end

function M.get_local_hash(path)
  return require('resonance.utils').get_local_hash(path)
end

function M.refresh_dag_data()
  local loader = package.loaded['resonance.loader'] or require('resonance.loader')
  local nodes, edges = loader.get_dag_data()
  local replay_info = loader.get_replay_info()
  M.state.dag_data.nodes = nodes
  M.state.dag_data.edges = edges
  M.state.replay_info = replay_info
end

return M
