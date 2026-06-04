local M = {}
local api = vim.api

local string_match = string.match
local string_gsub = string.gsub
local string_sub = string.sub
local vim_trim = vim.trim
local io_open = io.open

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
  local file = io_open(path .. '/.git/config', 'r')
  if not file then return 'unknown' end
  local content = file:read('*a')
  file:close()
  local url = string_match(content, '%[remote%s+"origin"%][^%[]-url%s*=%s*([^\n]+)')
  return url and vim_trim(url) or 'unknown'
end

function M.get_local_hash(path)
  local git_dir = path .. '/.git'
  local head_file = io_open(git_dir .. '/HEAD', 'r')
  if not head_file then return nil end
  local head = head_file:read('*l')
  head_file:close()
  if not head then return nil end

  local ref = string_match(head, 'ref:%s*(%S+)')
  if ref then
    local ref_file = io_open(git_dir .. '/' .. ref, 'r')
    if ref_file then
      local hash = ref_file:read('*l')
      ref_file:close()
      return hash and string_sub(hash, 1, 7) or nil
    else
      local packed = io_open(git_dir .. '/packed-refs', 'r')
      if packed then
        local content = packed:read('*a')
        packed:close()
        local escaped_ref = string_gsub(ref, '[%-%.%+%[%]%(%)%$%^%%%?%*]', '%%%1')
        local hash = string_match(content, '(%x+)%s+' .. escaped_ref)
        if hash then
          return string_sub(hash, 1, 7)
        end
      end
    end
  else
    return string_sub(head, 1, 7)
  end
  return nil
end

return M
