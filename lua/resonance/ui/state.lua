local M = {}
local api = vim.api

local string_match = string.match
local string_gsub = string.gsub
local string_sub = string.sub
local vim_trim = vim.trim
local uv_fs_open = vim.uv.fs_open
local uv_fs_close = vim.uv.fs_close
local uv_fs_read = vim.uv.fs_read

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
---@field pack_details table<string, table>
---@field updating boolean
---@field line_to_name table<number, string>
---@field name_to_line table<string, number>
---@field restore_cursor_name? string

---@type ResonanceUIState
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
  line_to_name = {},
  updating = false,
  name_to_line = {},
  restore_cursor_name = nil,
}

function M.init_hls()
  local cl = nvim_get_hl(0, { name = 'CursorLine' })
  local fn = nvim_get_hl(0, { name = 'Function' })
  local cm = nvim_get_hl(0, { name = 'Comment' })
  nvim_set_hl(0, 'ResoBtnKey', { fg = fn.fg, bg = cl.bg, default = true })
  nvim_set_hl(0, 'ResoBtnText', { fg = cm.fg, bg = cl.bg, default = true })
end

function M.is_valid()
  return M.state.buf and nvim_buf_is_valid(M.state.buf)
end

function M.plugin_at_cursor()
  if not M.state.win or not nvim_win_is_valid(M.state.win) then return nil end
  local row = nvim_win_get_cursor(M.state.win)[1]
  return M.state.line_to_name[row]
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

return M
