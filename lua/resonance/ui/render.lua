local M = {}
local st = require('resonance.ui.state')
local api = vim.api

local string_rep = string.rep
local table_concat = table.concat
local table_clear = require('table.clear')
local math_max = math.max
local math_min = math.min
local string_format = string.format
local type = type
local pairs = pairs
local vim_list_slice = vim.list_slice
local vim_schedule = vim.schedule
local vbo = vim.bo

local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_win_get_width = api.nvim_win_get_width
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_buf_set_lines = api.nvim_buf_set_lines
local nvim_buf_clear_namespace = api.nvim_buf_clear_namespace
local nvim_buf_set_extmark = api.nvim_buf_set_extmark
local nvim_buf_line_count = api.nvim_buf_line_count
local nvim_win_set_cursor = api.nvim_win_set_cursor
local pcall = pcall

M.render_scheduled = false

local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local _spaces_cache
_spaces_cache = setmetatable({}, {
  __index = function(t, n)
    if n < 0 then n = 0 end
    local s = string_rep(' ', n)
    t[n] = s
    return s
  end,
})

-- Pre-computed type labels
local TYPE_LABELS = {
  start = '󰜎 start',
  opt = '󰢱 opt',
  core = '󰒇 core',
}

-- Static button definitions (never change)
local BUTTONS = {
  { 'r', '󱑽 Resonate', 'ResoBtnResonateKey', 'ResoBtnResonateText' },
  { 'A', 'DAG', 'ResoBtnDAGKey', 'ResoBtnDAGText' },
  { 'u', 'Update', 'ResoBtnUpdateKey', 'ResoBtnUpdateText' },
  { 'U', 'Update All', 'ResoBtnUpdateAllKey', 'ResoBtnUpdateAllText' },
  { 'dd', 'Uninstall', 'ResoBtnUninstallKey', 'ResoBtnUninstallText' },
  { 'c', 'Checkout', 'ResoBtnCheckoutKey', 'ResoBtnCheckoutText' },
  { 'C', 'Review', 'ResoBtnReviewKey', 'ResoBtnReviewText' },
  { 's', 'Skip', 'ResoBtnSkipKey', 'ResoBtnSkipText' },
  { 'S', 'Search', 'ResoBtnSearchKey', 'ResoBtnSearchText' },
  { 'D', 'Dir', 'ResoBtnDirKey', 'ResoBtnDirText' },
  { 'q', 'Quit', 'ResoBtnQuitKey', 'ResoBtnQuitText' },
}

-- Cached stats
local _cached_stats = nil
local function get_stats()
  if not _cached_stats then
    _cached_stats = require('resonance').stats()
  end
  return _cached_stats
end

-- Module-level render state (reused across calls)
local line_parts = {}
local lines = {}
local hls = {}
local line_idx = 0
local cur_col = 0

local function add(text, hl)
  if not text or text == '' then return end
  line_parts[#line_parts + 1] = text
  if hl then
    hls[#hls + 1] = line_idx
    hls[#hls + 1] = cur_col
    hls[#hls + 1] = cur_col + #text
    hls[#hls + 1] = hl
  end
  cur_col = cur_col + #text
end

local function nl()
  line_idx = line_idx + 1
  lines[line_idx] = table_concat(line_parts)
  line_parts = {}
  cur_col = 0
end

local function mark_row(name, is_detail)
  st.state.line_to_name[line_idx + 1] = name
  if not is_detail then st.state.name_to_line[name] = line_idx + 1 end
end

local function reset_render_state()
  table_clear(lines)
  table_clear(hls)
  table_clear(line_parts)
  line_idx = 0
  cur_col = 0
  st.state.line_to_name = {}
  st.state.name_to_line = {}
end

-- DAG view rendering (must be before build_content for upvalue reference)
local function build_dag_content()
  reset_render_state()

  -- Clear spinner line index for DAG view (prevents stale spinner from list view)
  st.state.spinner_line_idx = nil

  local nodes = st.state.dag_data.nodes or {}
  local edges = st.state.dag_data.edges or {}
  local replay_info = st.state.replay_info or {}

  -- Collect all plugin names from nodes, edges, and replay_info
  local all_names = {}
  for name, _ in pairs(nodes) do all_names[name] = true end
  for name, _ in pairs(edges) do all_names[name] = true end
  for name, _ in pairs(replay_info) do all_names[name] = true end

  -- Convert to sorted array
  local sorted_names = {}
  local sn_idx = 0
  for name, _ in pairs(all_names) do
    sn_idx = sn_idx + 1
    sorted_names[sn_idx] = name
  end
  table.sort(sorted_names)

  if sn_idx == 0 then
    add('  No plugin specs loaded yet.', 'Comment')
    nl()
    return lines, hls
  end

  -- Header
  nl()
  add('  Dependency Graph (DAG) & Event Replay', 'Title')
  nl()
  add('  Press A to return to list view', 'Comment')
  nl(); nl()

  for i = 1, #sorted_names do
    local name = sorted_names[i]
    local node = nodes[name]
    local deps = edges[name]
    local replay = replay_info[name]

    mark_row(name, false)

    -- Plugin node
    local loaded = node and node.loaded or false
    local disabled = node and node.disabled or false
    local icons = st.state.icons or st.DEFAULT_ICONS
    add('  ', 'Normal')
    add((loaded and icons.loaded or icons.not_loaded) .. ' ', loaded and 'Statement' or 'Comment')
    add(name, disabled and 'Comment' or (loaded and 'Normal' or 'Comment'))

    local trigger = node and node.trigger or 'none'
    add('  [' .. trigger .. ']', 'Special')
    if disabled then
      add(' disabled (cond)', 'Comment')
    end
    nl()

    -- Dependencies (edges)
    if deps and #deps > 0 then
      for j = 1, #deps do
        local dep = deps[j]
        add('    ├─ ', 'Comment')
        add(dep, 'Function')
        if nodes[dep] and nodes[dep].loaded then
          add(' (loaded)', 'String')
        else
          add(' (not loaded)', 'Comment')
        end
        nl()
      end
    else
      add('    └─ (no dependencies)', 'Comment')
      nl()
    end

    -- Event replay info
    if replay then
      add('    ⏪ Replay: ', 'Comment')
      add('yes', 'DiagnosticOk')
      add('  [event: ' .. replay.event .. ']', 'Comment')
      local chain = replay.chain
      if chain and #chain > 0 then
        add('  → chain: ' .. table_concat(chain, ' → '), 'Special')
      end
      nl()
    end

    nl()
  end

  return lines, hls
end

local function build_content()
  reset_render_state()
  local icons = st.state.icons or st.DEFAULT_ICONS

  -- Static header (buttons + startuptime)
  nl()
  local cur_w = 2
  add('  ')
  for i = 1, #BUTTONS do
    local btn = BUTTONS[i]
    local k, t, hl_k, hl_t = btn[1], btn[2], btn[3], btn[4]
    local b_len = 8 + #t
    if cur_w + b_len > st.state.win_width - 2 then
      nl(); nl(); add('  '); cur_w = 2
    end
    add(' [' .. k .. '] ', hl_k)
    add(t .. ' ', hl_t)
    add('  ')
    cur_w = cur_w + b_len
  end
  nl(); nl()

  local stats = get_stats()
  if stats.startuptime > 0 then
    add('  Startuptime: ', 'Title')
    add(string_format('%.2f ms', stats.startuptime), 'WarningMsg')
    add(' (Till UIEnter/Dashboard)', 'Comment')
    nl(); nl()
  end

  -- DAG view mode
  if st.state.view_mode == 'dag' then
    return build_dag_content()
  end

  local pending_idx = {}
  local clean_idx = {}
  local disabled_idx = {}
  local p_idx = 0
  local c_idx = 0
  local d_idx = 0
  local max_name_len = 0


  local info = st.state.info
  if not info then return {}, {} end
  if not info.plugins then return {}, {} end
  local names = info.plugins.name
  local types = info.plugins.type
  local paths = info.plugins.path
  local loadeds = info.plugins.loaded
  local disableds = info.plugins.disabled or {}
  local triggers = info.plugins.trigger
  local updates = st.state.updates
  if not info.total then return {}, {} end

  for i = 1, info.total do
    local n = names[i]
    local nlen = #n
    if nlen > max_name_len then max_name_len = nlen end
    if disableds[i] then
      d_idx = d_idx + 1
      disabled_idx[d_idx] = i
    elseif updates[n] then
      p_idx = p_idx + 1
      pending_idx[p_idx] = i
    else
      c_idx = c_idx + 1
      clean_idx[c_idx] = i
    end
  end

  local function draw_plugin(idx, is_pending, is_disabled)
    local p_name = names[idx]
    local p_type = types[idx]
    local p_path = paths[idx]
    local is_loaded = loadeds[idx]
    local p_trigger = triggers[idx]

    mark_row(p_name, false)

    if is_disabled then
      add('  ' .. icons.disabled .. ' ', 'DiagnosticError')
    else
      add('  ' .. (is_loaded and icons.loaded or icons.not_loaded) .. ' ', is_loaded and 'Statement' or 'Comment')
    end
    add('󰏗 ', is_disabled and 'Comment' or (is_loaded and 'Function' or 'Comment'))

    add(p_name,
      is_disabled and 'Comment' or
      (is_pending and 'DiagnosticWarn' or (is_loaded and 'Normal' or 'Comment')))

    add(_spaces_cache[math_max(0, max_name_len - #p_name + 2)])
    local type_label = TYPE_LABELS[p_type]
    -- The scanner's type array can be shorter than its name array, so p_type
    -- may be nil. Falling back keeps one malformed entry from taking down
    -- the whole render.
    local type_text = type_label or (p_type and string_format('[%s]', p_type) or '[?]')
    add(type_text, 'Comment')
    add(_spaces_cache[math_max(0, 7 - #type_text)])

    local ms = info and info.load_times and info.load_times[p_name]
    if ms then
      local t_str = string_format('%.2f ms', ms)
      add(_spaces_cache[math_max(0, 10 - #t_str)])
      add(t_str, 'WarningMsg')
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

    if is_pending then
      local commits = updates[p_name]
      if type(commits) == 'table' then
        local max_show = #commits < 12 and #commits or 12
        for c = 1, max_show do
          local line = commits[c]
          local hash, msg = line:match('^(%x+)%s+(.*)$')
          if hash then
            add('      ' .. hash .. ' ', 'Number')
            local c_type, c_rest = msg:match('^([%w_-]+!?:)(.*)$')
            if c_type then
              add(c_type, 'Function')
              add(c_rest, 'Comment')
            else
              add(msg, 'Comment')
            end
            nl()
          end
        end
        if #commits > 12 then
          add('      ... ' .. tostring(#commits - 12) .. ' more commits', 'Comment')
          nl()
        end
      end
    end

    if st.state.expanded[p_name] then
      add('      status: ', 'Comment')
      if is_disabled then
        add('disabled(cond)', 'DiagnosticError')
      else
        add(is_loaded and 'active' or 'inactive', is_loaded and 'String' or 'Comment')
      end
      nl()


      local pk = st.state.pack_details[p_name]
      if pk then
        if pk.branches and #pk.branches > 0 then
          add('      branch: ', 'Comment')
          add(table_concat(pk.branches, ', '), 'String')
          nl()
        end
        if pk.tags and #pk.tags > 0 then
          local display_tags
          if #pk.tags > 5 then
            display_tags = table_concat(vim_list_slice(pk.tags, 1, 5), ', ') .. ' ...'
          else
            display_tags = table_concat(pk.tags, ', ')
          end
          add('      tags:   ', 'Comment')
          add(display_tags, 'Type')
          nl()
        end
      end

      add('      path:   ', 'Comment')
      add(p_path, 'Normal')
      nl()

      add('      src:    ', 'Comment')
      local urls = st.state.urls
      if not urls[p_name] then urls[p_name] = st.get_src_url(p_path) end
      add(urls[p_name], 'Underlined')
      nl()

      local commits = st.state.commits
      if commits[p_name] then
        add('      commit: ', 'Comment')
        add(commits[p_name], 'Number')
        nl()
      end
      nl()
    end
  end

  if p_idx == 0 then
    if st.state.checking then
      add('  Updates Available (0)', 'Title')
      st.state.spinner_line_idx = line_idx
      add('  ' .. SPINNER_FRAMES[st.state.spinner_frame] .. ' Resonating...', 'DiagnosticInfo')
      nl()
    else
      add('  No pending updates.', 'Comment')
      nl()
    end
  else
    add(string_format('  Updates Available (%d)', p_idx), 'Title')
    st.state.spinner_line_idx = line_idx
    if st.state.checking then
      add('  ' .. SPINNER_FRAMES[st.state.spinner_frame] .. ' Resonating...', 'DiagnosticInfo')
    end
    nl()
    for i = 1, p_idx do draw_plugin(pending_idx[i], true) end
  end

  nl()
  add(string_format('  Up To Date (%d)', c_idx), 'Title')
  add('    ' .. icons.loaded .. ' ', 'Statement')
  add(string_format('Loaded: %d', info.loaded), 'Comment')
  if d_idx > 0 then
    add('    ' .. icons.disabled .. ' ', 'DiagnosticError')
    add(string_format('disabled: %d', d_idx), 'Comment')
  end
  nl()

  for i = 1, c_idx do draw_plugin(clean_idx[i], false, false) end
  for i = 1, d_idx do draw_plugin(disabled_idx[i], false, true) end

  return lines, hls
end

function M.render()
  if not st.is_valid() then return end
  if st.state.win and nvim_win_is_valid(st.state.win) then
    st.state.win_width = nvim_win_get_width(st.state.win)
  end

  -- Remember which plugin the cursor is on. Rebuilding can re-sort the list
  -- (pending updates move to the top) or shift rows, so the cursor would
  -- otherwise end up on a different plugin and the next action would hit
  -- the wrong one.
  local cursor_name = st.plugin_at_cursor()

  local l, h = build_content()
  local buf = st.state.buf
  if not buf then return end
  local ns = st.ns

  vbo[buf].modifiable = true
  nvim_buf_set_lines(buf, 0, -1, false, l)
  vbo[buf].modifiable = false
  vbo[buf].modified = false

  nvim_buf_clear_namespace(buf, ns, 0, -1)

  for i = 1, #h, 4 do
    nvim_buf_set_extmark(buf, ns, h[i], h[i + 1],
      { end_col = h[i + 2], hl_group = h[i + 3], priority = 100 })
  end

  -- Put the cursor back on the plugin it was on. An explicit request wins,
  -- so a caller that wants a specific plugin can still steer the cursor.
  local restore_name = st.state.restore_cursor_name or cursor_name
  if restore_name and st.state.win and nvim_win_is_valid(st.state.win) then
    local target_line = st.state.name_to_line[restore_name]
    if target_line then
      local line_count = nvim_buf_line_count(buf)
      target_line = math_max(1, math_min(target_line, line_count))
      pcall(nvim_win_set_cursor, st.state.win, { target_line, 0 })
    end
  end
  st.state.restore_cursor_name = nil
end

function M.schedule_render()
  if M.render_scheduled then return end
  M.render_scheduled = true
  vim_schedule(function()
    M.render()
    M.render_scheduled = false
  end)
end

function M.update_spinner()
  if not st.is_valid() or not st.state.checking then return end
  local buf = st.state.buf
  local row = st.state.spinner_line_idx
  if not buf or not nvim_buf_is_valid(buf) then return end
  if not row then return end

  local p_idx = st.state.pending_count or 0

  local text = string_format('  Updates Available (%d)', p_idx)
  local title_len = #text
  text = text .. '  ' .. SPINNER_FRAMES[st.state.spinner_frame] .. ' Resonating...'

  vbo[buf].modifiable = true
  nvim_buf_set_lines(buf, row, row + 1, false, { text })
  vbo[buf].modifiable = false

  local ns = st.ns
  nvim_buf_clear_namespace(buf, ns, row, row + 1)
  nvim_buf_set_extmark(buf, ns, row, 0, {
    end_col = title_len,
    hl_group = 'Title',
    priority = 100,
  })
  nvim_buf_set_extmark(buf, ns, row, title_len, {
    end_col = #text,
    hl_group = 'DiagnosticInfo',
    priority = 100,
  })
end

return M
