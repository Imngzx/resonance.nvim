local M = {}
local api = vim.api
local uv = vim.uv

local string_match = string.match
local string_gsub = string.gsub
local string_sub = string.sub
local vim_trim = vim.trim
local uv_fs_open = uv.fs_open
local uv_fs_close = uv.fs_close
local uv_fs_read = uv.fs_read

local nvim_create_namespace = api.nvim_create_namespace
local nvim_get_hl = api.nvim_get_hl
local nvim_set_hl = api.nvim_set_hl
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_win_get_cursor = api.nvim_win_get_cursor

M.ns = nvim_create_namespace('resonance_ui')

---@class ResonancePluginSOA
---@field name string[]
---@field type string[]
---@field path string[]
---@field loaded boolean[]
---@field trigger string[]

---@class ResonanceScannerInfo
---@field plugins ResonancePluginSOA
---@field total integer
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
---@field restore_cursor_name? string
---@field pack_details table<string, table>
---@field line_to_name table<number, string>
---@field name_to_line table<string, number>
---@field view_mode string  -- 'list' | 'dag'
---@field dag_data table    -- { nodes: table<string, {name:string, deps:string[], trigger:string, loaded:boolean}>, edges: table<string, string[]> }
---@field replay_info table<string, {event:string, chain:string[], replayed:boolean}>
M.state = {
  buf = nil,
  win = nil,
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
  line_to_name = {},
  name_to_line = {},
  restore_cursor_name = nil,
  view_mode = 'list',
  dag_data = { nodes = {}, edges = {} },
  replay_info = {},
}

function M.init_hls()
  local cl = nvim_get_hl(0, { name = 'CursorLine' })
  local fn = nvim_get_hl(0, { name = 'Function' })
  local cm = nvim_get_hl(0, { name = 'Comment' })
  local di = nvim_get_hl(0, { name = 'DiagnosticInfo' })
  local er = nvim_get_hl(0, { name = 'DiagnosticError' })

  nvim_set_hl(0, 'ResoBtnKey', { fg = fn.fg, bg = cl.bg, default = true })
  nvim_set_hl(0, 'ResoBtnText', { fg = cm.fg, bg = cl.bg, default = true })

  nvim_set_hl(0, 'ResoBtnResonateKey', { fg = di.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnResonateText', { fg = di.fg, bg = cl.bg, default = true, bold = true })

  nvim_set_hl(0, 'ResoBtnDAGKey', { fg = er.fg, bg = cl.bg, default = true, bold = true })
  nvim_set_hl(0, 'ResoBtnDAGText', { fg = er.fg, bg = cl.bg, default = true, bold = true })
end

function M.is_valid()
  return M.state.buf and nvim_buf_is_valid(M.state.buf)
end

function M.plugin_at_cursor()
  if not M.state.win or not nvim_win_is_valid(M.state.win) then return nil end
  local row = nvim_win_get_cursor(M.state.win)[1]
  local name = M.state.line_to_name[row]
  -- If cursor on detail line, search upward for nearest plugin
  if not name then
    for r = row - 1, 1, -1 do
      name = M.state.line_to_name[r]
      if name then break end
    end
  end
  return name
end

function M.get_src_url(path)
  local fd = uv_fs_open(path .. '/.git/config', 'r', 438)
  if not fd then return 'unknown' end

  local content = uv_fs_read(fd, 65536, 0) or ''
  uv_fs_close(fd)

  local url = string_match(content, '%[remote%s+"origin"%][^%[]-url%s*=%s*([^\n]+)')
  return url and vim_trim(url) or 'unknown'
end

function M.get_local_hash(path)
  local git_dir = path .. '/.git'

  local function fast_read(file_path)
    local fd = uv_fs_open(file_path, 'r', 438)
    if not fd then return nil end
    local content = uv_fs_read(fd, 65536, 0)
    uv_fs_close(fd)
    return content
  end

  local head = fast_read(git_dir .. '/HEAD')
  if not head then return nil end

  local ref = string_match(head, 'ref:%s*(%S+)')
  if ref then
    local ref_content = fast_read(git_dir .. '/' .. ref)
    if ref_content then
      local hash = string_match(ref_content, '^(%x+)')
      return hash and string_sub(hash, 1, 7) or nil
    else
      local packed = fast_read(git_dir .. '/packed-refs')
      if packed then
        local escaped_ref = string_gsub(ref, '[%-%.%+%[%]%(%)%$%^%%%?%*]', '%%%1')
        local hash = string_match(packed, '(%x+)%s+' .. escaped_ref)
        if hash then
          return string_sub(hash, 1, 7)
        end
      end
    end
  else
    local hash = string_match(head, '^(%x+)')
    return hash and string_sub(hash, 1, 7) or nil
  end
  return nil
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
