local M = {}
local api = vim.api

M.ns = api.nvim_create_namespace('resonance_ui')

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
  local cl = api.nvim_get_hl(0, { name = 'CursorLine' })
  local fn = api.nvim_get_hl(0, { name = 'Function' })
  local cm = api.nvim_get_hl(0, { name = 'Comment' })
  api.nvim_set_hl(0, 'ResoBtnKey', { fg = fn.fg, bg = cl.bg, default = true })
  api.nvim_set_hl(0, 'ResoBtnText', { fg = cm.fg, bg = cl.bg, default = true })
end

function M.is_valid()
  return M.state.buf and api.nvim_buf_is_valid(M.state.buf)
end

function M.plugin_at_cursor()
  if not M.state.win or not api.nvim_win_is_valid(M.state.win) then return nil end
  local row = api.nvim_win_get_cursor(M.state.win)[1]
  return M.state.line_to_name[row]
end

function M.get_src_url(path)
  local file = io.open(path .. '/.git/config', 'r')
  if not file then return 'unknown' end
  local content = file:read('*a')
  file:close()
  local url = content:match('%[remote%s+"origin"%][^%[]-url%s*=%s*([^\n]+)')
  return url and vim.trim(url) or 'unknown'
end

function M.get_local_hash(path)
  local git_dir = path .. '/.git'
  local head_file = io.open(git_dir .. '/HEAD', 'r')
  if not head_file then return nil end
  local head = head_file:read('*l')
  head_file:close()
  if not head then return nil end

  local ref = head:match('ref: (.*)')
  if ref then
    local ref_file = io.open(git_dir .. '/' .. ref, 'r')
    if ref_file then
      local hash = ref_file:read('*l')
      ref_file:close()
      return hash and hash:sub(1, 7) or nil
    else
      local packed = io.open(git_dir .. '/packed-refs', 'r')
      if packed then
        for line in packed:lines() do
          if line:find(ref, 1, true) then
            packed:close()
            return line:sub(1, 7)
          end
        end
        packed:close()
      end
    end
  else
    return head:sub(1, 7)
  end
  return nil
end

return M
