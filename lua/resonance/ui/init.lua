local M = {}
local api = vim.api
local st = require('resonance.ui.state')
local render_mod = require('resonance.ui.render')
local actions = require('resonance.ui.actions')
local utils = require('resonance.utils')

local function bind_keys(win_close_fn)
  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buf = st.state.buf, nowait = true, silent = true, desc = desc })
  end

  map('q', win_close_fn, 'Close')
  map('<Esc>', win_close_fn, 'Close')
  map('<CR>', actions.toggle_details, 'Toggle Details')
  map('H', 'gg', 'Home')
  map('r', function()
    actions.check_updates_network()
    utils.notify('Resonating in background...', vim.log.levels.INFO)
  end, 'Fetch Updates')
  map('u', function()
    local name = st.plugin_at_cursor()
    if name then actions.update_plugins({ name }) end
  end, 'Update Current Plugin')
  map('U', function()
    local names = {}
    for name, _ in pairs(st.state.updates) do names[#names + 1] = name end
    if #names > 0 then
      actions.update_plugins(names)
    else
      utils.notify('No pending updates.', vim.log.levels.INFO)
    end
  end, 'Update All Pending')
  map('s', function()
    local name = st.plugin_at_cursor()
    if name and st.state.updates[name] then
      st.state.updates[name] = nil
      render_mod.schedule_render()
      utils.notify('Skipped update for ' .. name, vim.log.levels.INFO)
    end
  end, 'Skip Update')
  map('dd', function()
    local name = st.plugin_at_cursor()
    if name then actions.uninstall_plugin(name) end
  end, 'Uninstall Current Plugin')
  map('S', function()
    win_close_fn()
    local dir = st.state.info.pack_dir
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
    local dir = st.state.info.pack_dir
    if pcall(require, 'snacks') then
      require('snacks').explorer({ cwd = dir })
    else
      vim.cmd('Explore ' .. dir)
    end
  end, 'Open Dir')
end

function M.open(ui_config)
  if st.state.win and api.nvim_win_is_valid(st.state.win) then
    api.nvim_set_current_win(st.state.win); return
  end

  st.init_hls()
  st.state.info = require('resonance.scanner').get_info()
  st.state.buf = api.nvim_create_buf(false, true)

  vim.bo[st.state.buf].buftype = 'nofile'
  vim.bo[st.state.buf].filetype = 'resonance'
  vim.bo[st.state.buf].swapfile = false
  vim.bo[st.state.buf].bufhidden = 'wipe'

  st.state.win_width = math.floor(vim.o.columns * ui_config.width)
  st.state.updates, st.state.commits = {}, {}

  local function load_commits_async()
    local total = st.state.info.total
    local i = 1
    local function chunk()
      local end_idx = math.min(i + 10, total)
      for j = i, end_idx do
        local p_name, p_path = st.state.info.plugins.name[j], st.state.info.plugins.path[j]
        st.state.commits[p_name] = st.get_local_hash(p_path)
      end
      i = end_idx + 1
      if i <= total then
        vim.defer_fn(chunk, 5)
      else
        render_mod.schedule_render()
      end
    end
    chunk()
  end
  load_commits_async()

  render_mod.render()

  local function on_close()
    if st.state.win and api.nvim_win_is_valid(st.state.win) then
      pcall(api.nvim_win_close, st.state.win, true)
    end
    st.state.win, st.state.buf = nil, nil
  end

  local ok_snacks, snacks = pcall(require, 'snacks')
  local ok_nui, Popup = pcall(require, 'nui.popup')

  if ok_snacks then
    local win = snacks.win({
      buf = st.state.buf,
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
    st.state.win = win.win
    bind_keys(function()
      win:close(); st.state.win, st.state.buf = nil, nil
    end)
  elseif ok_nui then
    local popup = Popup({
      bufnr = st.state.buf,
      enter = true,
      focusable = true,
      border = { style = ui_config.border, text = { top = ui_config.title, top_align = 'center' } },
      position = '50%',
      size = { width = st.state.win_width, height = math.floor(vim.o.lines * ui_config.height) },
      win_options = { cursorline = true, wrap = false, signcolumn = 'no' }
    })
    popup:mount()
    st.state.win = popup.winid
    bind_keys(function()
      popup:unmount(); st.state.win, st.state.buf = nil, nil
    end)
  else
    local h = math.floor(vim.o.lines * ui_config.height)
    st.state.win = api.nvim_open_win(st.state.buf, true, {
      relative = 'editor',
      row = math.floor((vim.o.lines - h) / 2),
      col = math.floor((vim.o.columns - st.state.win_width) / 2),
      width = st.state.win_width,
      height = h,
      style = 'minimal',
      border = ui_config.border,
      title = ui_config.title,
      title_pos = 'center',
      zindex = 50
    })
    vim.wo[st.state.win].cursorline = true; vim.wo[st.state.win].wrap = false; vim.wo[st.state.win].signcolumn =
    'no'
    bind_keys(on_close)
  end
  render_mod.schedule_render()
end

return M
