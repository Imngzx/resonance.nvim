local M = {}
local st = require('resonance.ui.state')
local api = vim.api

M.render_scheduled = false

local _spaces_cache = setmetatable({}, {
  __index = function(t, k)
    local v = string.rep(' ', k)
    rawset(t, k, v)
    return v
  end
})

local function build_content()
  st.state.line_to_name = {}
  st.state.name_to_line = {}
  local lines, hls = {}, {}
  local line_parts, line_idx, cur_col = {}, 0, 0

  local function add(text, hl)
    if not text or text == '' then return end
    if hl then
      local idx = #hls
      hls[idx + 1] = line_idx
      hls[idx + 2] = cur_col
      hls[idx + 3] = cur_col + #text
      hls[idx + 4] = hl
    end
    line_parts[#line_parts + 1] = text
    cur_col = cur_col + #text
  end

  local function nl()
    lines[#lines + 1] = table.concat(line_parts)
    line_idx = line_idx + 1
    line_parts = {}
    cur_col = 0
  end

  local function mark_row(name, is_detail)
    st.state.line_to_name[line_idx + 1] = name
    if not is_detail then st.state.name_to_line[name] = line_idx + 1 end
  end

  nl()
  local buttons = { { 'H', 'Home' }, { 'u', 'Update' }, { 'U', 'Update All' }, { 's', 'Skip' }, { 'c', 'Checkout' }, { 'C', 'Review' }, { 'dd', 'Uninstall' }, { 'r', '󱑽 Resonate' }, { 'S', 'Search' }, { 'D', 'Dir' }, { 'q', 'Quit' } }
  local cur_w = 2
  add('  ')
  for i = 1, #buttons do
    local k, t = buttons[i][1], buttons[i][2]
    local b_len = 8 + #t
    if cur_w + b_len > st.state.win_width - 2 then
      nl(); nl(); add('  '); cur_w = 2
    end
    add(' [' .. k .. '] ', 'ResoBtnKey')
    add(t .. ' ', 'ResoBtnText')
    add('  ')
    cur_w = cur_w + b_len
  end
  nl(); nl()

  local stats = require('resonance').stats()
  if stats.startuptime > 0 then
    add('  Startuptime: ', 'Title')
    add(string.format('%.2f ms', stats.startuptime), 'WarningMsg')
    add(' (Till UIEnter/Dashboard)', 'Comment')
    nl(); nl()
  end

  local pending_idx, clean_idx = {}, {}
  local max_name_len = 0

  local names, types, paths, loadeds, triggers = st.state.info.plugins.name,
    st.state.info.plugins.type,
    st.state.info.plugins.path, st.state.info.plugins.loaded, st.state.info.plugins.trigger

  for i = 1, st.state.info.total do
    local n = names[i]
    if #n > max_name_len then max_name_len = #n end
    if st.state.updates[n] then pending_idx[#pending_idx + 1] = i else clean_idx[#clean_idx + 1] = i end
  end

  local function draw_plugin(idx, is_pending)
    local p_name, p_type, p_path, is_loaded, p_trigger = names[idx], types[idx], paths[idx],
      loadeds[idx], triggers[idx]
    mark_row(p_name, false)
    add(is_loaded and '  ● ' or '  ○ ', is_loaded and 'Statement' or 'Comment')
    add('󰏗 ', is_loaded and 'Function' or 'Comment')

    add(p_name, is_pending and 'DiagnosticWarn' or (is_loaded and 'Normal' or 'Comment'))
    add(_spaces_cache[math.max(0, max_name_len - #p_name + 2)])
    add(string.format('[%s]', p_type), 'Comment')
    add(_spaces_cache[math.max(0, 7 - #p_type)])

    local ms = st.state.info.load_times[p_name]
    if ms then
      local t_str = string.format('%.2f ms', ms)
      add(_spaces_cache[math.max(0, 10 - #t_str)]); add(t_str, 'WarningMsg')
    else
      add(_spaces_cache[10])
    end
    add('   ')

    if is_pending then
      add('󰚰 pending', 'DiagnosticWarn')
    else
      add(p_trigger, 'Special')
    end
    nl()

    if is_pending and type(st.state.updates[p_name]) == 'table' then
      local commits = st.state.updates[p_name]
      for c = 1, math.min(#commits, 12) do
        local hash, msg = commits[c]:match('^(%x+)%s+(.*)$')
        if hash then
          mark_row(p_name, true)
          add('      ' .. hash .. ' ', 'Number')
          local c_type, c_rest = msg:match('^([%w_-]+!?:)(.*)$')
          if c_type then
            add(c_type, 'Function'); add(c_rest, 'Comment')
          else
            add(msg, 'Comment')
          end
          nl()
        end
      end
      if #commits > 12 then
        mark_row(p_name, true); add('      ... ' .. tostring(#commits - 12) .. ' more commits',
          'Comment'); nl()
      end
    end

    if st.state.expanded[p_name] then
      mark_row(p_name, true); add('      status: ', 'Comment'); add(
        is_loaded and 'active' or 'inactive', is_loaded and 'String' or 'Comment'); nl()
      local pk = st.state.pack_details[p_name]
      if pk then
        if pk.branches and #pk.branches > 0 then
          mark_row(p_name, true); add('      branch: ', 'Comment'); add(
            table.concat(pk.branches, ', '), 'String'); nl()
        end
        if pk.tags and #pk.tags > 0 then
          local display_tags = #pk.tags > 5
            and (table.concat(vim.list_slice(pk.tags, 1, 5), ', ') .. ' ...')
            or table.concat(pk.tags, ', ')
          mark_row(p_name, true); add('      tags:   ', 'Comment'); add(display_tags, 'Type'); nl()
        end
      end

      mark_row(p_name, true); add('      path:   ', 'Comment'); add(p_path, 'Normal'); nl()
      mark_row(p_name, true); add('      src:    ', 'Comment')
      if not st.state.urls[p_name] then st.state.urls[p_name] = st.get_src_url(p_path) end
      add(st.state.urls[p_name], 'Underlined'); nl()

      if st.state.commits[p_name] then
        mark_row(p_name, true); add('      commit: ', 'Comment'); add(st.state.commits[p_name],
          'Number'); nl()
      end
      nl()
    end
  end

  add(string.format('  Updates Available (%d)', #pending_idx), 'Title')
  if st.state.checking then add(' (󱑽 Resonating...)', 'DiagnosticInfo') end
  nl()

  if #pending_idx == 0 then
    if not st.state.checking then
      add('    no pending updates', 'Comment'); nl()
    end
  else
    for i = 1, #pending_idx do draw_plugin(pending_idx[i], true) end
  end

  nl()
  add(string.format('  Up To Date (%d)', #clean_idx), 'Title')
  add('    ● ', 'Statement')
  add(string.format('Loaded: %d', st.state.info.loaded), 'Comment')
  nl()

  for i = 1, #clean_idx do draw_plugin(clean_idx[i], false) end

  return lines, hls
end

function M.render()
  if not st.is_valid() then return end
  if st.state.win and api.nvim_win_is_valid(st.state.win) then
    st.state.win_width = api.nvim_win_get_width(st.state.win)
  end

  local lines, hls = build_content()
  local buf = st.state.buf
  if not buf then return end
  local ns = st.ns

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local set_extmark = api.nvim_buf_set_extmark
  for i = 1, #hls, 4 do
    set_extmark(buf, ns, hls[i], hls[i + 1],
      { end_col = hls[i + 2], hl_group = hls[i + 3], priority = 100 })
  end

  if st.state.restore_cursor_name and st.state.win and api.nvim_win_is_valid(st.state.win) then
    local target_line = st.state.name_to_line[st.state.restore_cursor_name]
    if target_line then
      local line_count = api.nvim_buf_line_count(buf)
      target_line = math.max(1, math.min(target_line, line_count))
      pcall(api.nvim_win_set_cursor, st.state.win, { target_line, 0 })
    end
    st.state.restore_cursor_name = nil
  end
end

function M.schedule_render()
  if M.render_scheduled then return end
  M.render_scheduled = true
  vim.schedule(function()
    M.render()
    M.render_scheduled = false
  end)
end

return M
