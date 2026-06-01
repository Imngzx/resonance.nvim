local M = {}
local scanner = require('resonance.scanner')
local utils = require('resonance.utils')
local api = vim.api

local buf_set_lines = api.nvim_buf_set_lines
local buf_clear_namespace = api.nvim_buf_clear_namespace
local buf_set_extmark = api.nvim_buf_set_extmark
local win_is_valid = api.nvim_win_is_valid
local win_get_width = api.nvim_win_get_width
local win_get_cursor = api.nvim_win_get_cursor

local ns = api.nvim_create_namespace('resonance_ui')

local state = {
  buf = nil,
  win = nil,
  win_width = 80,
  info = nil,
  commits = {},
  updates = {},
  urls = {},
  expanded = {},
  checking = false,
  line_to_name = {},
  name_to_line = {},
  restore_cursor_name = nil,
}

local render_scheduled = false

local function init_hls()
  local cl = api.nvim_get_hl(0, { name = 'CursorLine' })
  local fn = api.nvim_get_hl(0, { name = 'Function' })
  local cm = api.nvim_get_hl(0, { name = 'Comment' })

  api.nvim_set_hl(0, 'ResoBtnKey', { fg = fn.fg, bg = cl.bg, default = true })
  api.nvim_set_hl(0, 'ResoBtnText', { fg = cm.fg, bg = cl.bg, default = true })
end

local function is_valid()
  return state.buf and api.nvim_buf_is_valid(state.buf)
end

local function plugin_at_cursor()
  if not state.win or not win_is_valid(state.win) then return nil end
  local row = win_get_cursor(state.win)[1]
  return state.line_to_name[row]
end

local function get_src_url(path)
  local file = io.open(path .. '/.git/config', 'r')
  if not file then return 'unknown' end
  local content = file:read('*a')
  file:close()
  local url = content:match('%[remote%s+"origin"%][^%[]-url%s*=%s*([^\n]+)')
  return url and vim.trim(url) or 'unknown'
end

local function build_content()
  state.line_to_name = {}
  state.name_to_line = {}

  local lines, hls = {}, {}
  local line_parts = {}
  local line_idx, cur_col = 0, 0

  local function add(text, hl)
    if not text or text == '' then return end
    if hl then hls[#hls + 1] = { line_idx, cur_col, cur_col + #text, hl } end
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
    state.line_to_name[line_idx + 1] = name
    if not is_detail then state.name_to_line[name] = line_idx + 1 end
  end

  local function btn(key, text)
    add(' [' .. key .. '] ', 'ResoBtnKey')
    add(text .. ' ', 'ResoBtnText')
  end

  nl()
  local buttons = {
    { 'H', 'Home' }, { 'u', 'Update' }, { 'U', 'Update All' },
    { 'r', 'Fetch' }, { 'S', 'Search' }, { 'D', 'Dir' }, { 'q', 'Quit' }
  }

  local cur_w = 2
  add('  ')
  for i = 1, #buttons do
    local b = buttons[i]
    local k, t = b[1], b[2]
    local b_len = 8 + #t
    if cur_w + b_len > state.win_width - 2 then
      nl(); nl(); add('  '); cur_w = 2
    end
    btn(k, t)
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

  local pending_list, clean_list = {}, {}
  local max_name_len = 0
  for i = 1, #state.info.plugins do
    local p = state.info.plugins[i]
    if #p.name > max_name_len then max_name_len = #p.name end
    if state.updates[p.name] then
      pending_list[#pending_list + 1] = p
    else
      clean_list[#clean_list + 1] = p
    end
  end

  local function draw_plugin(p, is_pending)
    mark_row(p.name, false)
    if p.loaded then add('  ● ', 'Statement') else add('  ○ ', 'Comment') end
    add('󰏗 ', p.loaded and 'Function' or 'Comment')

    add(p.name, is_pending and 'DiagnosticWarn' or (p.loaded and 'Normal' or 'Comment'))
    add(string.rep(' ', max_name_len - #p.name + 2))

    add(string.format('[%s]', p.type), 'Comment')
    add(string.rep(' ', 7 - #p.type))

    local ms = state.info.load_times[p.name]
    if ms then
      local t_str = string.format('%.2f ms', ms)
      add(string.rep(' ', 10 - #t_str))
      add(t_str, 'WarningMsg')
    else
      add(string.rep(' ', 10))
    end
    add('   ')

    if is_pending then
      add('󰚰 pending', 'DiagnosticWarn')
    elseif state.commits[p.name] then
      add(state.commits[p.name], 'Number')
    end
    nl()

    if is_pending and type(state.updates[p.name]) == 'table' then
      local commits = state.updates[p.name]
      for c = 1, math.min(#commits, 12) do
        local hash, msg = commits[c]:match('^(%x+)%s+(.*)$')
        if hash then
          mark_row(p.name, true)
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
        mark_row(p.name, true)
        add('      ... ' .. tostring(#commits - 12) .. ' more commits', 'Comment')
        nl()
      end
    end

    if state.expanded[p.name] then
      mark_row(p.name, true)
      add('      status: ', 'Comment')
      if p.loaded then add('active', 'String') else add('inactive', 'Comment') end
      nl()

      mark_row(p.name, true)
      add('      path:   ', 'Comment')
      add(p.path, 'Normal')
      nl()

      mark_row(p.name, true)
      add('      src:    ', 'Comment')
      if not state.urls[p.name] then state.urls[p.name] = get_src_url(p.path) end
      add(state.urls[p.name], 'Underlined')
      nl()

      if state.commits[p.name] then
        mark_row(p.name, true)
        add('      commit: ', 'Comment')
        add(state.commits[p.name], 'Number')
        nl()
      end
      nl()
    end
  end

  add(string.format('  Updates (%d)', #pending_list), 'Title')
  if state.checking then
    add(' (checking...)', 'DiagnosticInfo')
  end
  nl()

  if #pending_list == 0 then
    if not state.checking then
      add('    no pending updates', 'Comment')
      nl()
    end
  else
    for i = 1, #pending_list do draw_plugin(pending_list[i], true) end
  end

  nl()
  add(string.format('  Up to date (%d)', #clean_list), 'Title')
  nl()
  for i = 1, #clean_list do draw_plugin(clean_list[i], false) end

  return lines, hls
end

local function render()
  if not is_valid() then return end

  if state.win and win_is_valid(state.win) then
    state.win_width = win_get_width(state.win)
  end

  local lines, hls = build_content()

  vim.bo[state.buf].modifiable = true
  buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified = false

  buf_clear_namespace(state.buf, ns, 0, -1)
  for i = 1, #hls do
    local hl = hls[i]
    buf_set_extmark(state.buf, ns, hl[1], hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
      priority = 100
    })
  end

  if state.restore_cursor_name and state.win and win_is_valid(state.win) then
    local target_line = state.name_to_line[state.restore_cursor_name]
    if target_line then
      local line_count = api.nvim_buf_line_count(state.buf)
      target_line = math.max(1, math.min(target_line, line_count))
      pcall(api.nvim_win_set_cursor, state.win, { target_line, 0 })
    end
    state.restore_cursor_name = nil
  end
end

local function schedule_render()
  if render_scheduled then return end
  render_scheduled = true
  vim.schedule(function()
    render()
    render_scheduled = false
  end)
end

local function sync_local_state()
  for i = 1, #state.info.plugins do
    local p = state.info.plugins[i]
    vim.system({ 'git', 'rev-parse', '--short', 'HEAD' }, { cwd = p.path, text = true },
      function(out)
        if out.code == 0 and out.stdout then
          state.commits[p.name] = vim.trim(out.stdout)
          schedule_render()
        end
      end)
  end

  if vim.pack and vim.pack.get then
    local ok, packs = pcall(vim.pack.get, nil, { offline = true })
    if ok and type(packs) == 'table' then
      for _, pk in ipairs(packs) do
        local name = pk.spec.name
        if pk.rev and pk.rev_to and pk.rev ~= pk.rev_to then
          vim.system({ 'git', 'log', '--oneline', pk.rev .. '..' .. pk.rev_to },
            { cwd = pk.path, text = true },
            function(out)
              if out.code == 0 and out.stdout and vim.trim(out.stdout) ~= '' then
                local lines = {}
                for line in out.stdout:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
                state.updates[name] = lines
                schedule_render()
              end
            end)
        end
      end
    end
  end
end

local function check_updates_network()
  if state.checking then return end
  state.checking = true
  schedule_render()

  local completed = 0
  local total = #state.info.plugins

  for i = 1, total do
    local p = state.info.plugins[i]
    vim.system({ 'git', 'fetch', '--quiet' }, { cwd = p.path }, function(_)
      completed = completed + 1
      if completed >= total then
        state.checking = false
        sync_local_state()
      end
    end)
  end
end

local function toggle_details()
  local name = plugin_at_cursor()
  if not name then return end
  state.expanded[name] = not state.expanded[name]
  state.restore_cursor_name = name
  schedule_render()
end

local function update_plugins(names)
  if #names == 0 then return end
  if vim.pack and vim.pack.update then
    utils.notify('Updating ' .. table.concat(names, ', ') .. '...', vim.log.levels.INFO)
    vim.schedule(function()
      local ok, err = pcall(vim.pack.update, names, { force = true, offline = true })
      if not ok then
        utils.notify('Pack update failed: ' .. tostring(err), vim.log.levels.ERROR)
      else
        for _, n in ipairs(names) do state.updates[n] = nil end
        schedule_render()
      end
    end)
  else
    utils.notify('Triggering DIY plugin update for ' .. names[1], vim.log.levels.INFO)
  end
end

local function bind_keys(win_close_fn)
  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buf = state.buf, nowait = true, silent = true, desc = desc })
  end

  map('q', win_close_fn, 'Close')
  map('<Esc>', win_close_fn, 'Close')
  map('<CR>', toggle_details, 'Toggle Details')
  map('H', 'gg', 'Home')

  map('r', function()
    check_updates_network()
    utils.notify('Fetching remotes in background...', vim.log.levels.INFO)
  end, 'Fetch Updates')

  map('u', function()
    local name = plugin_at_cursor()
    if name then update_plugins({ name }) end
  end, 'Update Current Plugin')

  map('U', function()
    local names = {}
    for name, _ in pairs(state.updates) do names[#names + 1] = name end
    if #names > 0 then
      update_plugins(names)
    else
      utils.notify('No pending updates.', vim.log.levels.INFO)
    end
  end, 'Update All Pending')

  map('S', function()
    win_close_fn()
    local dir = state.info.pack_dir
    local ok_snacks, snacks = pcall(require, 'snacks')
    local ok_tele, tele = pcall(require, 'telescope.builtin')
    if ok_snacks then
      snacks.picker.grep({ cwd = dir, title = '  Plugins Source ' })
    elseif ok_tele then
      tele.live_grep({ cwd = dir })
    else
      vim.cmd('vimgrep /.*/j ' .. dir .. '/**/* | copen')
    end
  end, 'Search Sources')

  map('D', function()
    win_close_fn()
    local dir = state.info.pack_dir
    if pcall(require, 'snacks') then
      require('snacks').explorer({ cwd = dir })
    else
      vim.cmd('Explore ' .. dir)
    end
  end, 'Open Dir')
end

function M.open(ui_config)
  if state.win and win_is_valid(state.win) then
    api.nvim_set_current_win(state.win)
    return
  end

  init_hls()
  state.info = scanner.get_info()
  state.buf = api.nvim_create_buf(false, true)

  vim.bo[state.buf].buftype = 'nofile'
  vim.bo[state.buf].filetype = 'resonance'
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].bufhidden = 'wipe'

  state.win_width = math.floor(vim.o.columns * ui_config.width)

  state.updates = {}
  state.commits = {}
  render()
  sync_local_state()

  local ok_snacks, snacks = pcall(require, 'snacks')
  local ok_nui, Popup = pcall(require, 'nui.popup')

  local function on_close()
    if state.win and win_is_valid(state.win) then
      pcall(api.nvim_win_close, state.win, true)
    end
    state.win, state.buf = nil, nil
  end

  if ok_snacks then
    local win = snacks.win({
      buf = state.buf,
      position = 'float',
      width = ui_config.width,
      height = ui_config.height,
      border = ui_config.border,
      backdrop = ui_config.backdrop,
      title = ui_config.title,
      title_pos = 'center',
      enter = true,
      wo = { cursorline = true, wrap = false, signcolumn = 'no' }
    })
    state.win = win.win
    bind_keys(function()
      win:close(); state.win = nil; state.buf = nil
    end)
  elseif ok_nui then
    local popup = Popup({
      bufnr = state.buf,
      enter = true,
      focusable = true,
      border = { style = ui_config.border, text = { top = ui_config.title, top_align = 'center' } },
      position = '50%',
      size = { width = state.win_width, height = math.floor(vim.o.lines * ui_config.height) },
      win_options = { cursorline = true, wrap = false, signcolumn = 'no' }
    })
    popup:mount()
    state.win = popup.winid
    bind_keys(function()
      popup:unmount(); state.win = nil; state.buf = nil
    end)
  else
    local h = math.floor(vim.o.lines * ui_config.height)
    state.win = api.nvim_open_win(state.buf, true, {
      relative = 'editor',
      row = math.floor((vim.o.lines - h) / 2),
      col = math.floor((vim.o.columns - state.win_width) / 2),
      width = state.win_width,
      height = h,
      style = 'minimal',
      border = ui_config.border,
      title = ui_config.title,
      title_pos = 'center',
      zindex = 50
    })
    vim.wo[state.win].cursorline = true; vim.wo[state.win].wrap = false; vim.wo[state.win].signcolumn =
    'no'
    bind_keys(on_close)
  end

  schedule_render()
end

return M
