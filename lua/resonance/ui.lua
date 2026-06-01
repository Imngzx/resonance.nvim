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
  info = nil, -- { plugins, total, loaded, pack_dir, load_times }
  commits = {}, -- SOA: [name] -> Git Hash string
  updates = {}, -- SOA: [name] -> boolean (pending update)
  expanded = {}, -- SOA: [name] -> boolean (is expanded)
  checking = false,
  line_to_name = {},
  name_to_line = {},
}

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

local function build_content()
  local lines, hls = {}, {}
  local line_parts = {}
  local line_idx, cur_col = 0, 0

  local function add(text, hl)
    if not text or text == '' then return end
    if hl then
      hls[#hls + 1] = { line_idx, cur_col, cur_col + #text, hl }
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

  local function mark_row(name)
    state.line_to_name[line_idx + 1] = name
    state.name_to_line[name] = line_idx + 1
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
      nl()
      nl()
      add('  ')
      cur_w = 2
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

  local update_count = 0
  for _, v in pairs(state.updates) do if v then update_count = update_count + 1 end end

  add(
    string.format('  Total: %d plugins  Loaded: %d  Updates: ', state.info.total, state.info
    .loaded),
    'Comment')
  add(tostring(update_count), update_count > 0 and 'DiagnosticWarn' or 'Comment')

  if state.checking then
    add(' (checking...)', 'DiagnosticInfo')
  end
  nl(); nl()

  local max_name_len = 0
  for i = 1, #state.info.plugins do
    local n_len = #state.info.plugins[i].name
    if n_len > max_name_len then max_name_len = n_len end
  end

  for i = 1, #state.info.plugins do
    local p = state.info.plugins[i]
    mark_row(p.name)
    local is_pending = state.updates[p.name]

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

    if state.expanded[p.name] then
      mark_row(p.name)
      add('      status: ', 'Comment')
      if p.loaded then add('active', 'String') else add('inactive', 'Comment') end
      nl()

      mark_row(p.name)
      add('      path:   ', 'Comment')
      add(p.path, 'Normal')
      nl()

      if state.commits[p.name] then
        mark_row(p.name)
        add('      commit: ', 'Comment')
        add(state.commits[p.name], 'Number')
        nl()
      end

      if is_pending then
        mark_row(p.name)
        add('      update: ', 'Comment')
        add('Updates available in remote', 'DiagnosticWarn')
        nl()
      end
      nl()
    end
  end

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
    pcall(buf_set_extmark, state.buf, ns, hl[1], hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
      priority = 100
    })
  end
end


local function fetch_local_commits()
  for i = 1, #state.info.plugins do
    local p = state.info.plugins[i]
    vim.system({ 'git', 'rev-parse', '--short', 'HEAD' }, { cwd = p.path, text = true },
      function(out)
        if out.code == 0 and out.stdout then
          state.commits[p.name] = vim.trim(out.stdout)
          vim.schedule(render)
        end
      end)
  end
end

local function check_updates()
  if state.checking then return end
  state.checking = true
  render()

  local completed = 0
  local total = #state.info.plugins

  for i = 1, total do
    local p = state.info.plugins[i]
    vim.system({ 'git', 'fetch', '--quiet' }, { cwd = p.path }, function(_)
      vim.system({ 'git', 'rev-list', 'HEAD..@{u}', '--count' }, { cwd = p.path, text = true },
        function(out)
          if out.code == 0 and out.stdout then
            local count = tonumber(vim.trim(out.stdout)) or 0
            if count > 0 then state.updates[p.name] = true end
          end
          completed = completed + 1
          if completed >= total then state.checking = false end
          vim.schedule(render)
        end)
    end)
  end
end


local function toggle_details()
  local name = plugin_at_cursor()
  if not name then return end
  state.expanded[name] = not state.expanded[name]
  render()
  if state.win and win_is_valid(state.win) and state.name_to_line[name] then
    api.nvim_win_set_cursor(state.win, { state.name_to_line[name], 0 })
  end
end

local function update_plugin(name)
  if not name then return end
  if vim.pack and vim.pack.update then
    vim.notify('[Resonance] Updating ' .. name .. '...', vim.log.levels.INFO)
    pcall(vim.pack.update, { name })
  else
    utils.notify('Triggering DIY plugin update for ' .. name, vim.log.levels.INFO)
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
    check_updates()
    utils.notify('Fetching remotes in background...', vim.log.levels.INFO)
  end, 'Fetch Updates')

  map('u', function() update_plugin(plugin_at_cursor()) end, 'Update Current Plugin')

  map('U', function()
    if vim.pack and vim.pack.update then
      pcall(vim.pack.update)
    else
      utils.notify('Triggering Global Update...', vim.log.levels.INFO)
    end
  end, 'Update All Plugins')

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
  state.line_to_name = {}
  state.name_to_line = {}
  state.buf = api.nvim_create_buf(false, true)

  vim.bo[state.buf].buftype = 'nofile'
  vim.bo[state.buf].filetype = 'resonance'
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].bufhidden = 'wipe'

  state.win_width = math.floor(vim.o.columns * ui_config.width)

  render()
  fetch_local_commits()

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
    vim.wo[state.win].cursorline = true
    vim.wo[state.win].wrap = false
    vim.wo[state.win].signcolumn = 'no'
    bind_keys(on_close)
  end

  vim.schedule(render)
end

return M
