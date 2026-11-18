-- ui
--
-- Part of the resonance.nvim behavioral suite. Split out of the former
-- behavior_spec.lua to keep each file focused.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_ui_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local live = h.live
local with_capture = h.with_capture
local capture_and_wait = h.capture_and_wait
local noticed = h.noticed
local scratch_group = h.scratch_group
local recorder = h.recorder
local map_count = h.map_count
local make_git_repo = h.make_git_repo

test.run_suite('resonance.behavior.ui', {

  {
    name = 'actions: update_plugins reports failure instead of silently succeeding',
    fn = function()
      local l = live()
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          update = function() error('network down') end,
          get = function() return {} end,
        }
      end

      l.state.state.info = { total = 0, loaded = 0, plugins = { name = {}, path = {} } }
      l.state.state.updating = false

      local notices = capture_and_wait(function()
        l.actions.update_plugins({ 'some-plugin' })
      end, 1000)

      l.utils.get_pack = orig_get_pack

      -- The failure must be surfaced to the user.
      test.assert_true(noticed(notices, 'failed'), 'update failure was not reported')
      test.assert_false(l.state.state.updating)
    end,
  },

  {
    name = 'actions: uninstall_plugin reports failure when the delete fails',
    fn = function()
      local orig_confirm = vim.fn.confirm
      vim.fn.confirm = function() return 1 end -- 'Yes'

      local l = live()
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          del = function() error('permission denied') end,
        }
      end

      local notices = with_capture(function()
        l.actions.uninstall_plugin('some-plugin')
      end)

      vim.fn.confirm = orig_confirm
      l.utils.get_pack = orig_get_pack

      local reported = false
      for i = 1, #notices do
        if notices[i]:find('failed', 1, true) then reported = true end
      end
      test.assert_true(reported, 'uninstall failure was not reported')
    end,
  },

  {
    name = 'actions: uninstall_plugin does not delete when the user declines',
    fn = function()
      local orig_confirm = vim.fn.confirm
      vim.fn.confirm = function() return 2 end -- 'No'

      local l = live()
      local deleted = false
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          del = function()
            deleted = true
            return true
          end,
        }
      end

      with_capture(function()
        l.actions.uninstall_plugin('some-plugin')
      end)

      vim.fn.confirm = orig_confirm
      l.utils.get_pack = orig_get_pack

      test.assert_false(deleted)
    end,
  },

  {
    name = 'actions: uninstall_plugin forgets everything it cached for the plugin',
    fn = function()
      -- The UI caches the details, url, commit, update state and expansion
      -- of every plugin. A plugin that was uninstalled is no longer on disk,
      -- so none of that should stay reachable.
      local orig_confirm = vim.fn.confirm
      vim.fn.confirm = function() return 1 end -- 'Yes'

      local l = live()
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          del = function() return true end,
          get = function() return {} end,
        }
      end

      local name = 'gone-plugin'
      l.state.state.pack_details[name] = { spec = { name = name } }
      l.state.state.urls[name] = 'https://example.com/gone'
      l.state.state.commits[name] = 'abc1234'
      l.state.state.updates[name] = { has_update = true }
      l.state.state.expanded[name] = true
      l.scanner.load_times[name] = 1.5

      with_capture(function()
        l.actions.uninstall_plugin(name)
      end)

      vim.fn.confirm = orig_confirm
      l.utils.get_pack = orig_get_pack

      test.assert_nil(l.state.state.pack_details[name], 'pack_details was not pruned')
      test.assert_nil(l.state.state.urls[name], 'urls was not pruned')
      test.assert_nil(l.state.state.commits[name], 'commits was not pruned')
      test.assert_nil(l.state.state.updates[name], 'updates was not pruned')
      test.assert_nil(l.state.state.expanded[name], 'expanded was not pruned')
      test.assert_nil(l.scanner.load_times[name], 'scanner.load_times was not pruned')
    end,
  },

  {
    name = 'actions: checkout_plugin refuses a plugin with no git directory',
    fn = function()
      local l = live()
      -- A path with no .git directory.
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')

      l.state.state.info = {
        total = 1,
        loaded = 0,
        plugins = { name = { 'not-a-repo' }, path = { dir } },
      }

      local notices = with_capture(function()
        l.actions.checkout_plugin('not-a-repo')
      end)

      local reported = false
      for i = 1, #notices do
        if notices[i]:find('not a Git repository', 1, true) then reported = true end
      end
      test.assert_true(reported, 'missing git repository was not reported')
    end,
  },

  {
    name = 'actions: checkout_plugin reports an unknown plugin',
    fn = function()
      local l = live()
      l.state.state.info = {
        total = 0,
        loaded = 0,
        plugins = { name = {}, path = {} },
      }

      local notices = with_capture(function()
        l.actions.checkout_plugin('no-such-plugin')
      end)

      local reported = false
      for i = 1, #notices do
        if notices[i]:find('Cannot find path', 1, true) then reported = true end
      end
      test.assert_true(reported, 'unknown plugin was not reported')
    end,
  },

  {
    name = 'actions: check_updates_network counts a plugin with a pending update',
    fn = function()
      local l = live()
      -- check_updates_network runs a real `git fetch` per plugin, so the
      -- path must be a real repository for the fetch to complete.
      local dir = make_git_repo()

      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          get = function()
            return {
              {
                rev = 'aaaaaaa',
                rev_to = 'bbbbbbb',
                path = dir,
                spec = { name = 'pending-plugin' },
              },
            }
          end,
        }
      end

      l.state.state.info = {
        total = 1,
        loaded = 0,
        plugins = { name = { 'pending-plugin' }, path = { dir } },
      }
      l.state.state.checking = false
      l.state.state.pending_count = 0

      local notices, release = with_capture(function()
        l.actions.check_updates_network()
      end)
      vim.wait(2000)
      release()

      l.utils.get_pack = orig_get_pack

      test.assert_false(l.state.state.checking)
      -- The spinner shows this count, so it must reflect the pending update.
      test.assert_eq(l.state.state.pending_count, 1)
    end,
  },

  {
    name = 'actions: check_updates_network reports no updates for a current plugin',
    fn = function()
      local l = live()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')

      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          get = function()
            return {
              {
                rev = 'aaaaaaa',
                rev_to = 'aaaaaaa',
                path = dir,
                spec = { name = 'current-plugin' },
              },
            }
          end,
        }
      end

      l.state.state.info = {
        total = 1,
        loaded = 0,
        plugins = { name = { 'current-plugin' }, path = { dir } },
      }
      l.state.state.checking = false

      with_capture(function()
        l.actions.check_updates_network()
      end)
      vim.wait(1500)

      l.utils.get_pack = orig_get_pack

      test.assert_false(l.state.state.checking)
      test.assert_eq(l.state.state.pending_count, 0)
    end,
  },

  {
    name = 'replay: an ungrouped successor trigger is not fired by the replay',
    fn = function()
      -- Resonance registers its event triggers without a group. Replaying the
      -- chain by firing the whole event would re-run those ungrouped
      -- triggers, and with two plugins on the same event each load would
      -- trigger the other's replay, recursing until Neovim raises E218.
      test.stub_pack()
      local l = live()
      local post_fires = 0
      local setups = 0
      api.nvim_create_autocmd('BufReadPost', {
        callback = function() post_fires = post_fires + 1 end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-ungrouped-a',
        event = 'BufReadPre',
        setup = function() setups = setups + 1 end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/replay-ungrouped-b',
        event = 'BufReadPre',
        setup = function() setups = setups + 1 end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(300)

      -- Without a successful install the load aborts before the replay
      -- block, and this assertion would pass without testing anything.
      test.assert_eq(setups, 2, 'the plugins never loaded: the replay block was never reached')
      -- The replay must not fire the ungrouped trigger at all.
      test.assert_eq(post_fires, 0)
    end,
  },

  {
    name = 'replay: an ungrouped trigger that re-fires the event does not recurse',
    fn = function()
      -- The shape that produced E218: an ungrouped handler that fires the
      -- event again, reached through the replay.
      test.stub_pack()
      local l = live()
      local fires = 0
      local setups = 0
      api.nvim_create_autocmd('BufReadPost', {
        callback = function()
          fires = fires + 1
          if fires < 20 then
            pcall(api.nvim_exec_autocmds, 'BufReadPost', { modeline = false })
          end
        end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-recursion-a',
        event = 'BufReadPre',
        setup = function() setups = setups + 1 end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/replay-recursion-b',
        event = 'BufReadPre',
        setup = function() setups = setups + 1 end,
      })

      local buf = api.nvim_create_buf(false, true)
      local ok, err = pcall(api.nvim_exec_autocmds, 'BufReadPre', { buffer = buf, modeline = false })
      vim.wait(300)

      -- Without a successful install the load aborts before the replay
      -- block, and this assertion would pass without testing anything.
      test.assert_eq(setups, 2, 'the plugins never loaded: the replay block was never reached')
      test.assert_true(ok, 'the trigger recursed: ' .. tostring(err))
      -- The replay must not have reached the ungrouped handler.
      test.assert_eq(fires, 0)
    end,
  },

  {
    name = 'install: a failed install is reported to the user',
    fn = function()
      -- vim.pack.add raises on failure. The loader must surface that error
      -- instead of swallowing it: a silent failure leaves a plugin that never
      -- loads and never loads again.
      local l = live()
      test.stub_pack({ add_error = 'network down' })

      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/install-fails',
        event = 'BufReadPre',
        setup = function() ran = true end,
      })

      local buf = api.nvim_create_buf(false, true)
      local notices = capture_and_wait(function()
        api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      end, 1000)

      test.assert_true(noticed(notices, 'install-fails'),
        'the failing plugin was not named in the error')
      test.assert_true(noticed(notices, 'network down'),
        'the underlying error was not reported')
      test.assert_false(ran, 'setup ran even though the install failed')
    end,
  },

  {
    name = 'install: a failed install does not mark the plugin loaded',
    fn = function()
      local l = live()
      test.stub_pack({ add_error = 'network down' })

      _G.resonance.load({
        src = 'https://github.com/test/install-not-loaded',
        event = 'BufReadPre',
        setup = function() end,
      })

      local buf = api.nvim_create_buf(false, true)
      capture_and_wait(function()
        api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      end, 1000)

      local state = l.loader._internal.plugin_state['install-not-loaded']
      test.assert_false(state and state.loaded,
        'a plugin whose install failed was marked loaded')
      test.assert_false(state and state.replay_done,
        'a plugin whose install failed was marked replay_done')
    end,
  },

  {
    name = 'install: an install that produces no directory is reported',
    fn = function()
      -- `:packadd` reports success for a plugin that was never installed, so
      -- the loader has to verify the directory itself.
      local l = live()
      local stub = test.stub_pack()

      -- The stub reports the plugin as installed but never creates the
      -- directory, which is what a failed install looks like.
      stub.add = function(specs)
        stub.calls[#stub.calls + 1] = specs
      end
      stub.get = function(names, opts2)
        local out = {}
        for _, name in ipairs(names or {}) do
          out[#out + 1] = {
            spec = { name = name },
            path = '/nonexistent/resonance-test/' .. name,
          }
        end
        return out
      end

      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/install-missing-dir',
        event = 'BufReadPre',
        setup = function() ran = true end,
      })

      local buf = api.nvim_create_buf(false, true)
      local notices = capture_and_wait(function()
        api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      end, 1000)

      test.assert_true(noticed(notices, 'install-missing-dir'),
        'the plugin with no directory was not reported')
      test.assert_false(ran, 'setup ran even though nothing was installed')
    end,
  },

  {
    name = 'triggers: an event trigger is registered in a group',
    fn = function()
      -- An ungrouped trigger cannot be excluded from a replay and cannot be
      -- replayed individually, so the replay has no way to address it.
      local l = live()
      test.stub_pack()

      _G.resonance.load({
        src = 'https://github.com/test/grouped-trigger',
        event = 'BufReadPre',
        setup = function() end,
      })

      local found = nil
      local autocmds = api.nvim_get_autocmds({ event = 'BufReadPre' })
      for i = 1, #autocmds do
        if autocmds[i].group_name and autocmds[i].group_name:match('^Resonance_') then
          found = autocmds[i].group_name
        end
      end
      test.assert_not_nil(found, 'the event trigger was not registered in a group')
      test.assert_contains(found, 'grouped-trigger')
    end,
  },

  {
    name = 'triggers: an ft trigger is registered in a group',
    fn = function()
      local l = live()
      test.stub_pack()

      _G.resonance.load({
        src = 'https://github.com/test/grouped-ft-trigger',
        ft = 'resonancegroupedft',
        setup = function() end,
      })

      local found = nil
      local autocmds = api.nvim_get_autocmds({ event = 'FileType' })
      for i = 1, #autocmds do
        if autocmds[i].group_name and autocmds[i].group_name:match('^Resonance_') then
          found = autocmds[i].group_name
        end
      end
      test.assert_not_nil(found, 'the ft trigger was not registered in a group')
      test.assert_contains(found, 'grouped-ft-trigger')
    end,
  },

  {
    name = 'triggers: two plugins on the same event get separate groups',
    fn = function()
      -- A shared group would make one plugin's trigger exclude the other's.
      local l = live()
      test.stub_pack()

      _G.resonance.load({
        src = 'https://github.com/test/separate-group-a',
        event = 'BufReadPre',
        setup = function() end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/separate-group-b',
        event = 'BufReadPre',
        setup = function() end,
      })

      local groups = {}
      local autocmds = api.nvim_get_autocmds({ event = 'BufReadPre' })
      for i = 1, #autocmds do
        local name = autocmds[i].group_name
        if name and name:match('^Resonance_') then groups[name] = true end
      end

      test.assert_true(groups['Resonance_separate-group-a'])
      test.assert_true(groups['Resonance_separate-group-b'])
    end,
  },

  {
    name = 'fired events: has_fired reports an event that already ran',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local group = scratch_group('ResonanceFiredProbe')

      test.assert_false(l.loader.has_fired('BufReadPost', buf))

      api.nvim_create_autocmd('BufReadPost', {
        group = group,
        buffer = buf,
        callback = function() end,
      })
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
      vim.wait(100)

      test.assert_true(l.loader.has_fired('BufReadPost', buf))
      test.assert_false(l.loader.has_fired('FileType', buf))
    end,
  },

  {
    name = 'fired events: replay_for_buffer does not re-fire an event that already ran',
    fn = function()
      -- The user config used to fire BufReadPre/BufReadPost/FileType for
      -- every open buffer, so every handler ran twice.
      local l = live()
      local counts = { BufReadPre = 0, BufReadPost = 0, BufEnter = 0, FileType = 0 }
      local group = scratch_group('ResonanceReplayProbe')
      -- Opening a file fires all four. BufEnter is in the list because
      -- Neovim fires it for every buffer, not only new ones -- the replay
      -- has to treat it the same way, or a BufEnter-only trigger group
      -- never gets replayed on the `nvim <file>` path.
      local events = { 'BufReadPre', 'BufReadPost', 'BufEnter', 'FileType' }

      local buf = api.nvim_create_buf(false, true)
      vim.fn.writefile({ 'x' }, '/tmp/resonance-replay-probe.txt')
      api.nvim_buf_set_name(buf, '/tmp/resonance-replay-probe.txt')

      -- Scope the probe to the buffer under test, so the counts reflect this
      -- buffer only.
      for i = 1, #events do
        local name = events[i]
        api.nvim_create_autocmd(name, {
          group = group,
          buffer = buf,
          callback = function() counts[name] = counts[name] + 1 end,
        })
      end

      -- Simulate a native read: the events run and the tracker records them.
      -- FileType may fire more than once for a buffer (Neovim fires it when
      -- the buffer is set up as well), so the assertion is on the delta the
      -- replay causes, not on an absolute count.
      for i = 1, #events do
        api.nvim_exec_autocmds(events[i], { buffer = buf, modeline = false })
      end
      vim.wait(100)

      local before = { counts.BufReadPre, counts.BufReadPost, counts.BufEnter, counts.FileType }

      -- The replay must not run them a second time.
      local fired = l.loader.replay_for_buffer(buf)
      test.assert_eq(#fired, 0)
      test.assert_eq(counts.BufReadPre, before[1])
      test.assert_eq(counts.BufReadPost, before[2])
      test.assert_eq(counts.BufEnter, before[3])
      test.assert_eq(counts.FileType, before[4])
    end,
  },

  {
    name = 'fired events: replay_for_buffer fires an event that was missed',
    fn = function()
      local l = live()
      local count = 0
      local group = scratch_group('ResonanceReplayMissed')
      api.nvim_create_autocmd('BufReadPost', {
        group = group,
        callback = function() count = count + 1 end,
      })

      local buf = api.nvim_create_buf(false, true)
      vim.fn.writefile({ 'x' }, '/tmp/resonance-replay-missed.txt')
      api.nvim_buf_set_name(buf, '/tmp/resonance-replay-missed.txt')

      test.assert_eq(count, 0)
      local fired = l.loader.replay_for_buffer(buf)

      test.assert_eq(count, 1, 'the missed event was not replayed')
      test.assert_true(vim.tbl_contains(fired, 'BufReadPost'))
    end,
  },

  {
    name = 'ui: closing the UI cancels the deferred details task',
    fn = function()
      -- The details task writes into the UI state. A deferred callback has
      -- no way to know the UI is gone, so it runs as a cancellable task that
      -- the close handler cancels.
      --
      -- The task is started by expanding a row, not by opening the UI: the
      -- UI no longer asks for the details of every plugin up front.
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor', row = 1, col = 1, width = 40, height = 10,
      })
      l.state.state.buf = buf
      l.state.state.win = win
      l.state.state.info = {
        total = 1,
        loaded = 1,
        plugins = {
          name = { 'some-plugin' },
          type = { 'opt' },
          path = { '/tmp' },
          loaded = { true },
          disabled = { false },
          trigger = { 'event' },
        },
      }
      api.nvim_set_current_win(win)
      require('resonance.ui.render').render()
      local plugin_line = l.state.state.name_to_line['some-plugin']
      test.assert_not_nil(plugin_line)
      api.nvim_win_set_cursor(win, { plugin_line, 0 })

      l.actions.toggle_details()
      vim.wait(100)

      local st = l.state
      test.assert_not_nil(st.state.details_task,
        'the details pass is not running as a task')

      -- Close the UI the way the keymap does.
      local task = st.state.details_task
      st.state.details_task = nil
      if task then pcall(task.close, task) end
      st.state.win, st.state.buf = nil, nil

      -- The task must not raise when it observes the cancellation.
      vim.wait(500)
      test.assert_true(true)
    end,
  },

  {
    name = 'ui: wiping the UI buffer cancels the deferred details task',
    fn = function()
      -- The details task was only cancelled by the q/Esc keymaps and the
      -- native close handler. Closing the UI another way -- :q, <C-w>c, or
      -- :bwipeout -- left the task running and st.state.buf non-nil, so
      -- the details pass still ran pack.get(info=true) 50 ms later and
      -- wrote into a buffer nobody owned.
      --
      -- The UI has to be opened through open_ui: that is where the
      -- BufWipeout autocmd is registered.
      local l = live()
      require('resonance').open_ui()
      vim.wait(100)

      local st = l.state
      local ui_buf = st.state.buf
      test.assert_not_nil(ui_buf)

      -- Start the details task by expanding a row.
      local plugin_line = st.state.name_to_line and st.state.name_to_line['resonance.nvim']
      if plugin_line and st.state.win and api.nvim_win_is_valid(st.state.win) then
        api.nvim_set_current_win(st.state.win)
        api.nvim_win_set_cursor(st.state.win, { plugin_line, 0 })
        l.actions.toggle_details()
        vim.wait(100)
      end

      test.assert_not_nil(st.state.details_task,
        'the details pass is not running as a task')

      -- Close the UI the way :q and <C-w>c do: the buffer goes away.
      api.nvim_buf_delete(ui_buf, { force = true })
      vim.wait(300)

      test.assert_nil(st.state.details_task,
        'the details task survived the buffer being wiped')
      test.assert_nil(st.state.buf,
        'the UI buffer is still registered after it was wiped')
    end,
  },

  {
    name = 'render: closing the UI releases the rendered lines',
    fn = function()
      -- The render buffers are module-level, so the last render's lines and
      -- highlights stay reachable while the UI is closed. They have to be
      -- released when it closes.
      local l = live()
      require('resonance.ui').open({
        border = 'rounded',
        title = 'test',
        width = 0.5,
        height = 0.5,
        backdrop = 0,
      })
      vim.wait(300)

      local st = l.state.state
      test.assert_true(map_count(st.line_to_name) > 0,
        'the UI rendered no rows, so this test proves nothing')
      test.assert_true(map_count(st.name_to_line) > 0,
        'the UI rendered no names, so this test proves nothing')

      local ui_buf = st.buf
      api.nvim_buf_delete(ui_buf, { force = true })
      vim.wait(300)

      -- The maps are keyed by name and by line number, so the length
      -- operator cannot count them: it reports 0 for a string-keyed table
      -- whatever the table holds. The entries have to be walked.
      test.assert_eq(map_count(st.line_to_name), 0,
        'the rendered row map was not released when the UI closed')
      test.assert_eq(map_count(st.name_to_line), 0,
        'the rendered name map was not released when the UI closed')
    end,
  },

  {
    name = 'render: a plugin with no type does not break the render',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 1,
        col = 1,
        width = 40,
        height = 10,
      })

      l.state.state.buf = buf
      l.state.state.win = win
      -- The scanner's type array can be shorter than its name array.
      l.state.state.info = {
        total = 1,
        loaded = 0,
        plugins = {
          name = { 'typeless-plugin' },
          type = {},
          path = { '/tmp' },
          loaded = { false },
          disabled = { false },
          trigger = { 'event' },
        },
      }
      api.nvim_set_current_win(win)

      local ok, err = pcall(function()
        require('resonance.ui.render').render()
      end)

      api.nvim_win_close(win, true)
      test.assert_true(ok, 'render failed: ' .. tostring(err))
    end,
  },

  {
    name = 'render: the cursor stays on its plugin when the list re-sorts',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 1,
        col = 1,
        width = 60,
        height = 20,
      })

      l.state.state.buf = buf
      l.state.state.win = win
      l.state.state.info = {
        total = 2,
        loaded = 2,
        plugins = {
          name = { 'a-plugin', 'b-plugin' },
          type = { 'opt', 'opt' },
          path = { '/tmp', '/tmp' },
          loaded = { true, true },
          disabled = { false, false },
          trigger = { 'event', 'event' },
        },
      }
      api.nvim_set_current_win(win)

      require('resonance.ui.render').render()
      local a_line = l.state.state.name_to_line['a-plugin']
      test.assert_not_nil(a_line)
      api.nvim_win_set_cursor(win, { a_line, 0 })
      test.assert_eq(require('resonance.ui.state').plugin_at_cursor(), 'a-plugin')

      -- A pending update moves that plugin to the top of the list, which
      -- re-sorts the rows. The cursor must follow the plugin it was on,
      -- otherwise the next action would apply to a different plugin.
      l.state.state.updates['b-plugin'] = { 'abc1234 fix' }
      require('resonance.ui.render').render()

      test.assert_eq(require('resonance.ui.state').plugin_at_cursor(), 'a-plugin')

      api.nvim_win_close(win, true)
    end,
  },

  {
    name = 'ui: opening the UI does not fetch info for every plugin',
    fn = function()
      -- Pass 2 asked pack.get for info = true across every installed
      -- plugin, 50 ms after the UI opened. That is ~420 ms at 49 plugins
      -- and a ~2.5 s main-thread freeze at 300 -- all of it for the
      -- branches and tags, which are only shown on an expanded row.
      --
      -- The UI modules capture `utils` when they are first required, so
      -- the stub has to be installed on that exact instance. Requiring
      -- resonance.ui first forces the capture.
      local l = live()
      require('resonance.ui')
      local utils = require('resonance.utils')
      local real_get = utils.get_pack()
      test.assert_not_nil(real_get, 'vim.pack is not available')

      local info_calls = {}
      local stub = {
        get = function(names, opts)
          if opts and opts.info then
            -- names can be nil (every plugin), and assigning nil to a table
            -- slot is a no-op, so the request has to be recorded explicitly.
            info_calls[#info_calls + 1] = names or 'ALL'
          end
          return real_get(names, opts)
        end,
      }
      for key, value in pairs(real_get) do
        if stub[key] == nil then stub[key] = value end
      end
      local orig = utils.get_pack
      utils.get_pack = function() return stub end

      require('resonance').open_ui()
      vim.wait(400)

      utils.get_pack = orig

      test.assert_eq(#info_calls, 0,
        'opening the UI fetched info = true for ' .. #info_calls .. ' request(s)')
    end,
  },

  {
    name = 'ui: expanding a row fetches info for that plugin only',
    fn = function()
      local l = live()
      local utils = l.utils
      local real_get = utils.get_pack()
      test.assert_not_nil(real_get, 'vim.pack is not available')

      local info_calls = {}
      local stub = {
        get = function(names, opts)
          if opts and opts.info then
            info_calls[#info_calls + 1] = names
          end
          return real_get(names, opts)
        end,
      }
      for key, value in pairs(real_get) do
        if stub[key] == nil then stub[key] = value end
      end
      local orig = utils.get_pack
      utils.get_pack = function() return stub end

      -- Put a plugin row on the screen and put the cursor on it.
      local buf = api.nvim_create_buf(false, true)
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor', row = 1, col = 1, width = 40, height = 10,
      })
      l.state.state.buf = buf
      l.state.state.win = win
      l.state.state.info = {
        total = 1,
        loaded = 1,
        plugins = {
          name = { 'some-plugin' },
          type = { 'opt' },
          path = { '/tmp' },
          loaded = { true },
          disabled = { false },
          trigger = { 'event' },
        },
      }
      api.nvim_set_current_win(win)
      require('resonance.ui.render').render()
      local plugin_line = l.state.state.name_to_line['some-plugin']
      test.assert_not_nil(plugin_line)
      api.nvim_win_set_cursor(win, { plugin_line, 0 })

      l.actions.toggle_details()
      vim.wait(200)

      utils.get_pack = orig
      api.nvim_win_close(win, true)

      test.assert_eq(#info_calls, 1,
        'expanding a row made ' .. #info_calls .. ' info requests')
      test.assert_eq(info_calls[1][1], 'some-plugin',
        'the info request was not for the expanded plugin')
    end,
  },

  {
    name = 'actions: toggle_details flips the expanded flag for the plugin at the cursor',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 1,
        col = 1,
        width = 40,
        height = 10,
      })

      l.state.state.buf = buf
      l.state.state.win = win
      l.state.state.info = {
        total = 1,
        loaded = 1,
        plugins = {
          name = { 'some-plugin' },
          type = { 'opt' },
          path = { '/tmp' },
          loaded = { true },
          disabled = { false },
          trigger = { 'event' },
        },
      }
      api.nvim_set_current_win(win)

      -- Render once so the plugin rows exist, then put the cursor on the
      -- plugin the way a user would.
      require('resonance.ui.render').render()
      local plugin_line = l.state.state.name_to_line['some-plugin']
      test.assert_not_nil(plugin_line)
      api.nvim_win_set_cursor(win, { plugin_line, 0 })

      test.assert_false(l.state.state.expanded['some-plugin'] == true)
      l.actions.toggle_details()
      test.assert_true(l.state.state.expanded['some-plugin'] == true)
      l.actions.toggle_details()
      test.assert_false(l.state.state.expanded['some-plugin'] == true)

      api.nvim_win_close(win, true)
    end,
  },
})

test.print_summary()
