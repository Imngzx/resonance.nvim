local M = {}
local scanner = require('resonance.scanner')
local utils = require('resonance.utils')

local function build_content()
  local info = scanner.get_info()
  local lines, extmarks, cur_line, cur_col, line_idx = {}, {}, '', 0, 0

  local function new_line()
    if line_idx > 0 then table.insert(lines, cur_line) end
    cur_line, cur_col, line_idx = '', 0, line_idx + 1
  end

  local function append(text, hl)
    if text == '' then return end
    if hl then
      table.insert(extmarks,
        { line = line_idx - 1, start_col = cur_col, end_col = cur_col + #text, hl_group = hl })
    end
    cur_line, cur_col = cur_line .. text, cur_col + #text
  end

  new_line(); new_line()
  append('  ')
  append(' Home (H) ', 'CursorLine')
  append('  ', 'NONE')
  append(' Update (U) ', 'CursorLine')
  append('  ', 'NONE')
  append(' Search (S) ', 'CursorLine')
  append('  ', 'NONE')
  append(' Dir (D) ', 'CursorLine')
  append('  ', 'NONE')
  append(' Quit (q) ', 'CursorLine')
  new_line(); new_line()

  local stats = require('resonance').stats()
  if stats.startuptime > 0 then
    append('  Startuptime: ', 'Title')
    append(string.format('%.2f ms', stats.startuptime), 'WarningMsg')
    append(' (Till UIEnter/Dashboard)', 'Comment')
    new_line(); new_line()
  end

  append(string.format('  Total: %d plugins  Loaded: %d', info.total, info.loaded), 'Comment')
  new_line(); new_line()

  local max_len = 0
  for _, p in ipairs(info.plugins) do
    if #p.name > max_len then max_len = #p.name end
  end

  for _, p in ipairs(info.plugins) do
    new_line()
    append('  ')
    if p.loaded then
      append('● ', 'Statement')
      append('󰏗 ', 'Function')
      append(p.name, 'Normal')
    else
      append('○ ', 'Comment')
      append('󰏗 ', 'Comment')
      append(p.name, 'Comment')
    end

    -- 填充空格以对齐
    local name_pad = max_len - #p.name + 2
    append(string.rep(' ', name_pad > 0 and name_pad or 2), 'NONE')

    -- 输出分类 (start/opt)
    append(string.format('[%s]', p.type), 'Comment')

    -- 如果有探针数据，输出耗时
    if p.loaded then
      local ms = info.load_times[p.name]
      if ms then
        local type_pad = 7 - #p.type
        append(string.rep(' ', type_pad > 0 and type_pad or 1), 'NONE')
        append(string.format('%.2f ms', ms), 'WarningMsg')
      end
    end
  end
  table.insert(lines, cur_line)

  return lines, extmarks, info.pack_dir
end

local function bind_keys(buf, win_close_fn, pack_dir)
  vim.keymap.set('n', 'q', win_close_fn, { buf = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', win_close_fn, { buf = buf, nowait = true })
  vim.keymap.set('n', 'H', 'gg', { buf = buf })

  vim.keymap.set('n', 'U', function()
    win_close_fn()
    vim.pack.update()
    utils.notify('Triggering DIY plugin update...', vim.log.levels.INFO)
  end, { buf = buf, desc = 'Update Plugins' })

  vim.keymap.set('n', 'S', function()
    win_close_fn()
    local has_snacks, snacks = pcall(require, 'snacks')
    local has_tele, tele = pcall(require, 'telescope.builtin')
    if has_snacks then
      snacks.picker.grep({ cwd = pack_dir, title = '  Plugins Source ' })
    elseif has_tele then
      tele.live_grep({ cwd = pack_dir })
    else
      vim.cmd('vimgrep /.*/j ' .. pack_dir .. '/**/* | copen')
    end
  end, { buf = buf, nowait = true, desc = 'Search in Plugins Source' })

  vim.keymap.set('n', 'D', function()
    win_close_fn()
    if pcall(require, 'snacks') then
      require('snacks').explorer({ cwd = pack_dir })
    else
      vim.cmd('Explore ' .. pack_dir)
    end
  end, { buf = buf, nowait = true, desc = 'Open Plugin Directory' })
end

function M.open(ui_config)
  local lines, extmarks, pack_dir = build_content()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local ns = vim.api.nvim_create_namespace('resonance_ui')
  for _, em in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, em.line, em.start_col, {
      end_col = em.end_col,
      hl_group = em.hl_group,
      priority = 100
    })
  end

  local ok_snacks, snacks = pcall(require, 'snacks')
  local ok_nui, Popup = pcall(require, 'nui.popup')

  if ok_snacks then
    local win = snacks.win({
      buf = buf,
      position = 'float',
      width = ui_config.width,
      height = ui_config.height,
      border = ui_config.border,
      backdrop = ui_config.backdrop,
      title = ui_config.title,
      title_pos = 'center',
      enter = true,
      bo = {
        buftype = 'nofile',
        filetype = 'resonance',
        swapfile = false,
        bufhidden = 'wipe',
      },
      wo = {
        cursorline = true,
        wrap = false,
        signcolumn = 'no',
        number = false,
        relativenumber = false,
      }
    })
    bind_keys(buf, function() win:close() end, pack_dir)
  elseif ok_nui then
    local popup = Popup({
      bufnr = buf,
      enter = true,
      focusable = true,
      border = { style = ui_config.border, text = { top = ui_config.title, top_align = 'center' } },
      position = '50%',
      size = { width = math.floor(vim.o.columns * ui_config.width), height = math.floor(vim.o.lines * ui_config.height) },
      buf_options = { modifiable = false, readonly = true, bufhidden = 'wipe' },
      win_options = { cursorline = true, wrap = false, signcolumn = 'no', number = false, relativenumber = false }
    })
    popup:mount()
    bind_keys(buf, function() popup:unmount() end, pack_dir)
  else
    local w = math.floor(vim.o.columns * ui_config.width)
    local h = math.floor(vim.o.lines * ui_config.height)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      row = math.floor((vim.o.lines - h) / 2),
      col = math.floor((vim.o.columns - w) / 2),
      width = w,
      height = h,
      style = 'minimal',
      border = ui_config.border,
      title = ui_config.title,
      title_pos = 'center',
      zindex = 50
    })
    vim.bo[buf].bufhidden = 'wipe'
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    bind_keys(buf, function() pcall(vim.api.nvim_win_close, win, true) end, pack_dir)
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'resonance'
end

return M
