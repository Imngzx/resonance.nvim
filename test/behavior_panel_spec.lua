-- the panel, the scanner and the git helpers
--
-- Part of the resonance.nvim behavioral suite.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_panel_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local live = h.live
local capture_and_wait = h.capture_and_wait
local noticed = h.noticed

-- Hide a module from require() for the length of fn: the Neovim running the
-- suite loaded the user's config, so snacks and telescope are there.
local function without_modules(names, fn)
  local saved_loaded, saved_preload = {}, {}
  for i = 1, #names do
    local n = names[i]
    saved_loaded[n] = package.loaded[n]
    saved_preload[n] = package.preload[n]
    package.loaded[n] = nil
    package.preload[n] = function() error('hidden by the test') end
  end
  local ok, err = pcall(fn)
  for i = 1, #names do
    local n = names[i]
    package.loaded[n] = saved_loaded[n]
    package.preload[n] = saved_preload[n]
  end
  if not ok then error(err, 0) end
end

local function keymap_callback(buf, lhs)
  local maps = api.nvim_buf_get_keymap(buf, 'n')
  for i = 1, #maps do
    if maps[i].lhs == lhs then return maps[i].callback end
  end
  return nil
end

test.run_suite('resonance.behavior.panel', {

  {
    name = 'panel: a render that raises does not stop later renders',
    fn = function()
      -- The scheduled flag was cleared after the render, so a render that
      -- raised left it set, and every later schedule_render() did nothing.
      local render = require('resonance.ui.render')
      local orig = render.render
      local calls = 0
      render.render = function()
        calls = calls + 1
        if calls == 1 then error('a broken render') end
      end
      render.render_scheduled = false
      render.schedule_render()
      vim.wait(100, function() return calls >= 1 end)
      pcall(vim.wait, 50)
      render.schedule_render()
      vim.wait(200, function() return calls >= 2 end)
      render.render = orig
      render.render_scheduled = false
      test.assert_eq(calls, 2, 'the render after a failed one never ran')
    end,
  },

  {
    name = 'panel: a plugin with no directory does not read /.git/config',
    fn = function()
      -- state.lua localizes fs_open when it is loaded, so the spy goes in
      -- first. Neovim's module loader reads files through fs_open too, so
      -- only the opens made by get_src_url itself are counted.
      local opened = {}
      local counting = false
      local orig_open = vim.uv.fs_open
      vim.uv.fs_open = function(path, ...)
        if counting then opened[#opened + 1] = path end
        return orig_open(path, ...)
      end
      package.loaded['resonance.ui.state'] = nil
      local state = require('resonance.ui.state')
      counting = true
      local ok, url = pcall(state.get_src_url, '')
      counting = false
      vim.uv.fs_open = orig_open
      package.loaded['resonance.ui.state'] = nil
      test.assert_true(ok, tostring(url))
      test.assert_eq(url, 'unknown')
      test.assert_eq(#opened, 0, 'a file was opened for an empty path: ' .. vim.inspect(opened))
    end,
  },

  {
    name = 'panel: an update whose log lists no commit is still listed',
    fn = function()
      -- A downgrade, a pin or a force-pushed branch has no commits in
      -- rev..rev_to. It was counted by the spinner but left out of the list,
      -- and U skipped it.
      local l = live()
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          get = function()
            return { { spec = { name = 'pinned-plugin' }, path = '/tmp', rev = 'aaaaaaa111', rev_to = 'bbbbbbb222' } }
          end,
        }
      end
      local entry
      local ok, err = pcall(h.with_system, nil, function(l2)
        l2.state.state.info = { total = 1, loaded = 0, plugins = { name = { 'pinned-plugin' }, path = { '/tmp' } } }
        l2.state.state.checking = false
        l2.actions.check_updates_network()
        vim.wait(1000, function() return not l2.state.state.checking end, 20)
        entry = l2.state.state.updates['pinned-plugin']
        l2.state.state.checking = false
      end)
      l.utils.get_pack = orig_get_pack
      if not ok then error(err, 0) end
      test.assert_not_nil(entry, 'the update was left out of the list')
      test.assert_contains(entry[1], 'aaaaaaa -> bbbbbbb')
    end,
  },

  {
    name = 'git: a packed ref matches its own line, not a longer branch name',
    fn = function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. '/.git', 'p')
      vim.fn.writefile({ 'ref: refs/heads/main' }, dir .. '/.git/HEAD')
      vim.fn.writefile({
        '# pack-refs with: peeled fully-peeled sorted',
        '1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main-wip',
        '2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/main',
      }, dir .. '/.git/packed-refs')
      local hash = _G.utils.get_local_hash(dir)
      vim.fn.delete(dir, 'rf')
      test.assert_eq(hash, '2222222', 'the hash of refs/heads/main-wip was returned for refs/heads/main')
    end,
  },

  {
    name = 'scanner: the fallback follows a symlinked pack group',
    fn = function()
      -- Without vim.pack the scanner walks pack/<group>/<opt|start>/<plugin>.
      -- A symlinked group was skipped, and its plugins were missing.
      local data = vim.fn.tempname()
      local real_group = vim.fn.tempname()
      vim.fn.mkdir(real_group .. '/opt/linked-plugin', 'p')
      vim.fn.mkdir(data .. '/nvim/site/pack/plain/opt/plain-plugin', 'p')
      vim.uv.fs_symlink(real_group, data .. '/nvim/site/pack/linked')
      local root = vim.fn.stdpath('data') .. '/site/pack/core/opt/resonance.nvim'
      local out = vim.system({
        'nvim', '--headless', '--clean', '--cmd', 'set rtp^=' .. root,
        '-c', "lua require('resonance.utils').disable_pack()",
        '-c', "lua local i = require('resonance.scanner').get_info(); local n = {} for k = 1, i.total do n[#n + 1] = i.plugins.name[k] end io.stdout:write('NAMES=' .. table.concat(n, ',') .. '\\n')",
        '-c', 'qall!',
      }, { env = { XDG_DATA_HOME = data }, text = true }):wait(15000)
      vim.fn.delete(data, 'rf')
      vim.fn.delete(real_group, 'rf')
      test.assert_contains(out.stdout, 'plain-plugin', 'the scan did not run: ' .. out.stdout .. out.stderr)
      test.assert_contains(out.stdout, 'linked-plugin', 'the symlinked group was skipped: ' .. out.stdout)
    end,
  },

  {
    name = 'panel: D opens a pack directory with a space in its path',
    fn = function()
      local cmds = {}
      local orig_cmd = vim.cmd
      vim.cmd = setmetatable({}, {
        __call = function(_, c)
          if type(c) == 'string' and c:find('^Explore') then
            cmds[#cmds + 1] = c
            return
          end
          return orig_cmd(c)
        end,
        __index = orig_cmd,
      })
      local ok, err = pcall(function()
        package.loaded['resonance.ui'] = nil
        require('resonance').open_ui()
        vim.wait(100)
        local st = require('resonance.ui.state')
        st.state.info.pack_dir = '/tmp/with space/pack'
        local cb = keymap_callback(st.state.buf, 'D')
        assert(cb, 'no D mapping')
        without_modules({ 'snacks' }, cb)
      end)
      vim.cmd = orig_cmd
      package.loaded['resonance.ui'] = nil
      test.assert_true(ok, tostring(err))
      test.assert_eq(cmds[1], 'Explore /tmp/with\\ space/pack', 'the directory was not escaped')
    end,
  },

  {
    name = 'panel: D uses neo-tree when its command exists',
    fn = function()
      local seen = nil
      api.nvim_create_user_command('Neotree', function(a) seen = a.args end, { nargs = '*' })
      local ok, err = pcall(function()
        package.loaded['resonance.ui'] = nil
        require('resonance').open_ui()
        vim.wait(100)
        local st = require('resonance.ui.state')
        st.state.info.pack_dir = '/tmp/with space/pack'
        local cb = keymap_callback(st.state.buf, 'D')
        assert(cb, 'no D mapping')
        without_modules({ 'snacks' }, cb)
      end)
      api.nvim_del_user_command('Neotree')
      package.loaded['resonance.ui'] = nil
      test.assert_true(ok, tostring(err))
      test.assert_eq(seen, 'dir=/tmp/with\\ space/pack')
    end,
  },

  {
    name = 'panel: D edits the directory when netrw is disabled',
    fn = function()
      -- With g:loaded_netrwPlugin set there is no :Explore, and D raised
      -- "E492: Not an editor command". Editing the directory hands it to
      -- the plugin that replaced netrw.
      local cmds = {}
      local orig_cmd = vim.cmd
      local orig_exists = vim.fn.exists
      vim.fn.exists = function(what)
        if what == ':Explore' or what == ':Neotree' then return 0 end
        return orig_exists(what)
      end
      vim.cmd = setmetatable({}, {
        __call = function(_, c)
          if type(c) == 'string' and (c:find('^Explore') or c:find('^edit ')) then
            cmds[#cmds + 1] = c
            return
          end
          return orig_cmd(c)
        end,
        __index = orig_cmd,
      })
      local ok, err = pcall(function()
        package.loaded['resonance.ui'] = nil
        require('resonance').open_ui()
        vim.wait(100)
        local st = require('resonance.ui.state')
        st.state.info.pack_dir = '/tmp/with space/pack'
        local cb = keymap_callback(st.state.buf, 'D')
        assert(cb, 'no D mapping')
        without_modules({ 'snacks' }, cb)
      end)
      vim.cmd = orig_cmd
      vim.fn.exists = orig_exists
      package.loaded['resonance.ui'] = nil
      test.assert_true(ok, tostring(err))
      test.assert_eq(cmds[1], 'edit /tmp/with\\ space/pack')
    end,
  },

  {
    name = 'panel: wiping the buffer of a closed panel leaves the reopened panel alone',
    fn = function()
      -- A split keeps the panel buffer alive after the panel is closed.
      -- When that split went away later, the old buffer's BufWipeout
      -- cleared the state of the panel that had been opened since.
      local st
      local old_buf, new_buf, buf_after, win_after
      local ok, err = pcall(function()
        package.loaded['resonance.ui'] = nil
        require('resonance').open_ui()
        vim.wait(100)
        st = require('resonance.ui.state')
        old_buf = st.state.buf
        local split = api.nvim_open_win(old_buf, false, { split = 'below' })
        local close = keymap_callback(old_buf, 'q')
        assert(close, 'no q mapping')
        close()
        assert(api.nvim_buf_is_valid(old_buf), 'the split did not keep the old buffer alive')

        require('resonance').open_ui()
        vim.wait(100)
        new_buf = st.state.buf
        api.nvim_win_close(split, true)
        if api.nvim_buf_is_valid(old_buf) then api.nvim_buf_delete(old_buf, { force = true }) end
        buf_after, win_after = st.state.buf, st.state.win
      end)
      if st and st.state.buf then
        local close = keymap_callback(st.state.buf, 'q')
        if close then pcall(close) end
      end
      package.loaded['resonance.ui'] = nil
      test.assert_true(ok, tostring(err))
      test.assert_true(new_buf ~= nil and new_buf ~= old_buf, 'the panel was not reopened on a new buffer')
      test.assert_eq(buf_after, new_buf, 'the old buffer wiped the state of the reopened panel')
      test.assert_not_nil(win_after, 'the reopened panel lost its window')
    end,
  },

  {
    name = 'panel: a fetch that hangs is stopped, reported, and the check finishes',
    fn = function()
      -- One `git fetch` that never returned held the whole check open:
      -- no result was shown and `r` stayed inert for the session. Every
      -- fetch now carries a timeout, and vim.system reports a process it
      -- stopped that way as exit code 124.
      local l = live()
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return { get = function() return {} end }
      end
      local fetch_timeouts = {}
      local still_checking
      local notices
      local ok, err = pcall(h.with_system, function(cmd, opts, cb)
        if cmd[2] == 'fetch' then
          fetch_timeouts[#fetch_timeouts + 1] = opts.timeout or false
          cb(h.completed(opts.cwd == '/tmp/hung' and 124 or 0))
          return
        end
        cb(h.completed(0))
      end, function(l2)
        l2.state.state.info = {
          total = 2, loaded = 0,
          plugins = { name = { 'fine-plugin', 'hung-plugin' }, path = { '/tmp/fine', '/tmp/hung' } },
        }
        l2.state.state.checking = false
        notices = capture_and_wait(function()
          l2.actions.check_updates_network()
          vim.wait(1000, function() return not l2.state.state.checking end, 20)
        end, 100)
        still_checking = l2.state.state.checking
        l2.state.state.checking = false
      end)
      l.utils.get_pack = orig_get_pack
      if not ok then error(err, 0) end
      test.assert_eq(#fetch_timeouts, 2)
      for i = 1, #fetch_timeouts do
        test.assert_true(type(fetch_timeouts[i]) == 'number' and fetch_timeouts[i] > 0,
          'a fetch was started without a timeout')
      end
      test.assert_false(still_checking, 'the check never finished')
      test.assert_true(noticed(notices, 'Fetch timed out for hung-plugin'), vim.inspect(notices))
      test.assert_false(noticed(notices, 'fine-plugin'), vim.inspect(notices))
    end,
  },

  {
    name = 'panel: git runs without the GIT_DIR of the environment',
    fn = function()
      -- GIT_DIR wins over the working directory. With Neovim started as
      -- `GIT_DIR=~/.dotfiles nvim`, the fetch and the log ran against the
      -- dotfiles repository and the check reported no update; a checkout
      -- would have switched branches there.
      local l = live()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. '/.git', 'p')
      local vars = { 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE' }
      local saved = {}
      for i = 1, #vars do
        saved[i] = vim.env[vars[i]]
        vim.env[vars[i]] = '/tmp/someone-elses-repo'
      end
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          get = function()
            return { { spec = { name = 'env-plugin' }, path = dir, rev = 'aaaaaaa111', rev_to = 'bbbbbbb222' } }
          end,
        }
      end
      local orig_input = vim.ui.input
      vim.ui.input = function(_, cb) cb('main') end
      local seen = {}
      local ok, err = pcall(h.with_system, function(cmd, opts, cb)
        seen[cmd[2]] = opts
        cb(h.completed(0))
      end, function(l2)
        l2.state.state.info = {
          total = 1, loaded = 0,
          plugins = { name = { 'env-plugin' }, path = { dir } },
        }
        l2.state.state.checking = false
        l2.actions.check_updates_network()
        vim.wait(1000, function() return not l2.state.state.checking end, 20)
        l2.actions.checkout_plugin('env-plugin')
        vim.wait(500, function() return seen.checkout ~= nil end, 20)
        l2.state.state.checking = false
      end)
      vim.ui.input = orig_input
      l.utils.get_pack = orig_get_pack
      for i = 1, #vars do vim.env[vars[i]] = saved[i] end
      vim.fn.delete(dir, 'rf')
      if not ok then error(err, 0) end

      local subcommands = { 'fetch', 'log', 'checkout' }
      for i = 1, #subcommands do
        local sub = subcommands[i]
        local opts = seen[sub]
        test.assert_not_nil(opts, 'git ' .. sub .. ' never ran')
        test.assert_true(opts.clear_env == true and type(opts.env) == 'table',
          'git ' .. sub .. ' inherits the environment as it is')
        for v = 1, #vars do
          test.assert_eq(opts.env[vars[v]], nil, 'git ' .. sub .. ' still sees ' .. vars[v])
        end
        test.assert_not_nil(opts.env.PATH, 'git ' .. sub .. ' lost the rest of the environment')
      end
    end,
  },

  {
    name = 'panel: without vim.pack, update and uninstall say so instead of pretending',
    fn = function()
      -- Update used to say "Triggering plugin update" and do nothing;
      -- uninstall asked for confirmation, then did nothing.
      local u = live().utils
      local orig_confirm = vim.fn.confirm
      local asked = 0
      vim.fn.confirm = function() asked = asked + 1; return 1 end
      package.loaded['resonance.ui.actions'] = nil
      local actions = require('resonance.ui.actions')
      local saved = rawget(vim, 'pack')
      u.disable_pack()
      local notices = capture_and_wait(function()
        actions.update_plugins({ 'some-plugin' })
        actions.uninstall_plugin('some-plugin')
      end, 100)
      u.restore_pack(saved)
      vim.fn.confirm = orig_confirm
      package.loaded['resonance.ui.actions'] = nil
      test.assert_true(noticed(notices, 'Updating needs vim.pack'), vim.inspect(notices))
      test.assert_false(noticed(notices, 'Triggering plugin update'), vim.inspect(notices))
      test.assert_true(noticed(notices, 'Uninstalling needs vim.pack'), vim.inspect(notices))
      test.assert_eq(asked, 0, 'a confirmation was asked for an uninstall that cannot happen')
    end,
  },
})
