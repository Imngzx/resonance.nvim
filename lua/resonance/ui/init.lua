local M = {}
local api = vim.api
local st = require('resonance.ui.state')
local render_mod = require('resonance.ui.render')
local actions = require('resonance.ui.actions')
local utils = require('resonance.utils')
local registry = require('resonance.registry')

local pcall = pcall
local pairs = pairs
local math_floor = math.floor
local math_min = math.min
local vim_keymap_set = vim.keymap.set
local vim_log_levels = vim.log.levels
local vim_cmd = vim.cmd
local vim_defer_fn = vim.defer_fn
local vim_o = vim.o
local vbo = vim.bo
local vwo = vim.wo

local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_set_current_win = api.nvim_set_current_win
local nvim_create_buf = api.nvim_create_buf
local nvim_win_close = api.nvim_win_close
local nvim_open_win = api.nvim_open_win

-- Merge user-supplied icons over the defaults. Each key is independent so a
-- user can override only the glyphs they care about.
local function resolve_icons(icons)
  local defaults = st.default_icons()
  return {
    loaded = icons and icons.loaded or defaults.loaded,
    not_loaded = icons and icons.not_loaded or defaults.not_loaded,
    disabled = icons and icons.disabled or defaults.disabled,
  }
end

local function bind_keys(win_close_fn)
  local map = function(lhs, rhs, desc)
    vim_keymap_set('n', lhs, rhs, { buf = st.state.buf, nowait = true, silent = true, desc = desc })
  end

  map('q', win_close_fn, 'Close')
  map('<Esc>', win_close_fn, 'Close')
  map('<CR>', actions.toggle_details, 'Toggle Details')
  map('r', function()
    -- Notify only when a check actually started. While one is in flight the
    -- key stays inert, so holding `r` cannot stack notifications.
    if actions.check_updates_network() then
      utils.notify('Resonating in background...', vim_log_levels.INFO)
    end
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
      utils.notify('No pending updates.', vim_log_levels.INFO)
    end
  end, 'Update All Pending')
  map('s', function()
    local name = st.plugin_at_cursor()
    if name and st.state.updates[name] then
      st.state.updates[name] = nil
      render_mod.schedule_render()
      utils.notify('Skipped update for ' .. name, vim_log_levels.INFO)
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
      -- No picker: ask what to search for. `vimgrep /.*/` matched every line
      -- of every plugin file and froze Neovim building the quickfix list.
      vim.ui.input({ prompt = 'Search plugin sources: ' }, function(pattern)
        if not pattern or pattern == '' then return end
        vim_cmd('vimgrep /' .. vim.fn.escape(pattern, '/') .. '/j ' ..
          vim.fn.fnameescape(dir) .. '/**/* | copen')
      end)
    end
  end, 'Search Sources')
  map('D', function()
    win_close_fn()
    local dir = st.state.info.pack_dir
    if pcall(require, 'snacks') then
      require('snacks').explorer({ cwd = dir })
    else
      vim_cmd('Explore ' .. vim.fn.fnameescape(dir))
    end
  end, 'Open Dir')
  map('C', function()
    local pack = utils.get_pack()
    if pack and pack.update then
      win_close_fn()
      pack.update(nil, { offline = true })
    else
      utils.notify('Native vim.pack is not available.', vim_log_levels.WARN)
    end
  end, 'Native Update Review')
  map('c', function()
    local name = st.plugin_at_cursor()
    if name then actions.checkout_plugin(name) end
  end, 'Checkout Plugin')
  map('A', function()
    st.state.view_mode = st.state.view_mode == 'dag' and 'list' or 'dag'
    st.refresh_dag_data()
    render_mod.schedule_render()
  end, 'Toggle DAG View')
end

function M.open(ui_config)
  if st.state.win and nvim_win_is_valid(st.state.win) then
    nvim_set_current_win(st.state.win); return
  end

  st.init_hls()
  st.state.info = require('resonance.scanner').get_info()
  st.state.buf = nvim_create_buf(false, true)

  vbo[st.state.buf].buftype = 'nofile'
  vbo[st.state.buf].filetype = 'resonance'
  vbo[st.state.buf].swapfile = false
  vbo[st.state.buf].bufhidden = 'wipe'

  st.state.win_width = math_floor(vim_o.columns * ui_config.width)
  st.state.updates, st.state.commits = {}, {}
  -- The expanded rows and their details belong to the UI that was open
  -- before. They were left behind, so a reopened UI showed rows still
  -- expanded, and the details of a row were not fetched again: the stale
  -- branches and tags of the previous session were shown instead.
  st.state.expanded = {}
  st.state.pack_details = {}
  st.state.pending_count = 0
  st.state.view_mode = 'list'
  st.state.icons = resolve_icons(ui_config.icons)
  local function load_commits_async()
    -- First pass: fast load with info=false (commits, urls, rev) ~1ms
    local pack = utils.get_pack()
    if pack then
      local ok, packs = pcall(pack.get, nil, { offline = true, info = false })
      if ok and type(packs) == 'table' then
        for p = 1, #packs do
          local pk = packs[p]
          local name = pk.spec.name
          st.state.pack_details[name] = pk
          if pk.rev then st.state.commits[name] = string.sub(pk.rev, 1, 7) end
          if pk.spec and pk.spec.src then st.state.urls[name] = pk.spec.src end
        end
      end
    end

    local total = st.state.info.total
    local i = 1
    local function chunk()
      local end_idx = math_min(i + 10, total)
      for j = i, end_idx do
        local p_name, p_path = st.state.info.plugins.name[j], st.state.info.plugins.path[j]
        if p_path and p_path ~= '' then
          if not st.state.commits[p_name] then
            st.state.commits[p_name] = st.get_local_hash(p_path) or 'unknown'
          end
          if not st.state.urls[p_name] then
            st.state.urls[p_name] = st.get_src_url(p_path) or 'unknown'
          end
        else
          -- The disabled plugins live in the registry, not in the loader:
          -- the panel is read-only, and requiring the loader for one
          -- lookup would pull the whole control plane into it.
          local disabled = registry.disabled_plugins[p_name]
          if disabled and disabled.url then st.state.urls[p_name] = disabled.url end
        end
      end
      i = end_idx + 1
      if i <= total then
        vim_defer_fn(chunk, 5)
      elseif i > 10 then
        -- The first chunk ran synchronously, so the render below already
        -- covers it. Only a deferred final chunk needs its own render.
        render_mod.schedule_render()
      end
    end
    chunk()
  end
  load_commits_async()

  -- Cancel the deferred details task when the UI closes. The task writes
  -- into st.state, so it must not outlive the window.
  local function cancel_details_task()
    local task = st.state.details_task
    st.state.details_task = nil
    if task then pcall(task.close, task) end
  end

  local function on_close()
    cancel_details_task()
    if st.state.win and nvim_win_is_valid(st.state.win) then
      pcall(nvim_win_close, st.state.win, true)
    end
    render_mod.clear()
    st.state.win, st.state.buf = nil, nil
  end

  -- The UI can be closed without going through the keymaps: :q, <C-w>c and
  -- :bwipeout all remove the buffer. The details task writes into st.state,
  -- so it must not outlive the buffer. A BufWipeout autocmd on the UI
  -- buffer catches every way of closing it.
  api.nvim_create_autocmd('BufWipeout', {
    buffer = st.state.buf,
    once = true,
    callback = function()
      cancel_details_task()
      render_mod.clear()
      st.state.win, st.state.buf = nil, nil
    end,
  })

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
      cancel_details_task()
      win:close(); st.state.win, st.state.buf = nil, nil
    end)
  elseif ok_nui then
    local popup = Popup({
      bufnr = st.state.buf,
      enter = true,
      focusable = true,
      border = { style = ui_config.border, text = { top = ui_config.title, top_align = 'center' } },
      position = '50%',
      size = { width = st.state.win_width, height = math_floor(vim_o.lines * ui_config.height) },
      win_options = { cursorline = true, wrap = false, signcolumn = 'no' }
    })
    popup:mount()
    st.state.win = popup.winid
    bind_keys(function()
      cancel_details_task()
      popup:unmount(); st.state.win, st.state.buf = nil, nil
    end)
  else
    local h = math_floor(vim_o.lines * ui_config.height)
    st.state.win = nvim_open_win(st.state.buf, true, {
      relative = 'editor',
      row = math_floor((vim_o.lines - h) / 2),
      col = math_floor((vim_o.columns - st.state.win_width) / 2),
      width = st.state.win_width,
      height = h,
      style = 'minimal',
      border = ui_config.border,
      title = ui_config.title,
      title_pos = 'center',
      zindex = 50
    })
    vwo[st.state.win].cursorline = true
    vwo[st.state.win].wrap = false
    vwo[st.state.win].signcolumn = 'no'
    bind_keys(on_close)
  end
  render_mod.schedule_render()
end

return M
