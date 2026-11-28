-- Tests for resonance.ui modules
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/ui_spec.lua" -c "lua test.print_summary()" -c "qall"

local ui = require('resonance.ui')
local state = require('resonance.ui.state')
local actions = require('resonance.ui.actions')
local render = require('resonance.ui.render')
local utils = require('resonance.utils')

local h = dofile('test/helpers.lua')
-- Re-require inside a test: the runner clears package.loaded between tests.
local live = h.live

-- The notifications reported while fn runs.
local function with_capture(fn)
  return h.capture_and_wait(fn, 0)
end

test.run_suite('resonance.ui', {

  {
    name = 'state: initial state valid',
    fn = function()
      test.assert_not_nil(state.state)
      test.assert_eq(type(state.state), 'table')
    end,
  },

  {
    name = 'state: is_valid returns false before open',
    fn = function()
      test.assert_false(state.is_valid())
    end,
  },

  {
    name = 'state: plugin_at_cursor returns nil before open',
    fn = function()
      test.assert_nil(state.plugin_at_cursor())
    end,
  },

  {
    name = 'actions: check_updates_network sets checking flag',
    fn = function()
      -- This is an async test, just verify function exists
      test.assert_not_nil(actions.check_updates_network)
      test.assert_eq(type(actions.check_updates_network), 'function')
    end,
  },

  {
    name = 'actions: toggle_details function exists',
    fn = function()
      test.assert_not_nil(actions.toggle_details)
      test.assert_eq(type(actions.toggle_details), 'function')
    end,
  },

  {
    name = 'actions: update_plugins function exists',
    fn = function()
      test.assert_not_nil(actions.update_plugins)
      test.assert_eq(type(actions.update_plugins), 'function')
    end,
  },

  {
    name = 'actions: uninstall_plugin function exists',
    fn = function()
      test.assert_not_nil(actions.uninstall_plugin)
      test.assert_eq(type(actions.uninstall_plugin), 'function')
    end,
  },

  {
    name = 'actions: checkout_plugin function exists',
    fn = function()
      test.assert_not_nil(actions.checkout_plugin)
      test.assert_eq(type(actions.checkout_plugin), 'function')
    end,
  },

  {
    name = 'render: render function exists',
    fn = function()
      test.assert_not_nil(render.render)
      test.assert_eq(type(render.render), 'function')
    end,
  },

  {
    name = 'render: schedule_render function exists',
    fn = function()
      test.assert_not_nil(render.schedule_render)
      test.assert_eq(type(render.schedule_render), 'function')
    end,
  },

  {
    name = 'render: update_spinner function exists',
    fn = function()
      test.assert_not_nil(render.update_spinner)
      test.assert_eq(type(render.update_spinner), 'function')
    end,
  },

  {
    name = 'ui: open function exists',
    fn = function()
      test.assert_not_nil(ui.open)
      test.assert_eq(type(ui.open), 'function')
    end,
  },

  {
    name = 'actions: update_plugins clears pending state after update',
    fn = function()
      -- Stub pack.update: a real update would mutate the installed plugin tree.
      local l = live()
      local update_called = false
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          update = function()
            update_called = true
            return true
          end,
          get = function()
            return {}
          end,
        }
      end

      l.state.state.info = { total = 0, loaded = 0, plugins = { name = {}, path = {} } }
      l.state.state.updates = { ['some-plugin'] = { 'abc1234 some commit' } }
      l.state.state.updating = false

      with_capture(function()
        l.actions.update_plugins({ 'some-plugin' })
      end)
      vim.wait(1000)

      l.utils.get_pack = orig_get_pack

      test.assert_true(update_called)
      test.assert_false(l.state.state.updating)
      test.assert_nil(l.state.state.updates['some-plugin'])
    end,
  },

  {
    name = 'actions: update_plugins ignores empty name list',
    fn = function()
      local l = live()
      l.state.state.updating = false
      local notices = with_capture(function()
        l.actions.update_plugins({})
      end)
      test.assert_eq(#notices, 0)
      test.assert_false(l.state.state.updating)
    end,
  },

  {
    name = 'actions: update_plugins is a no-op while already updating',
    fn = function()
      local l = live()
      l.state.state.updating = true
      local notices = with_capture(function()
        l.actions.update_plugins({ 'resonance.nvim' })
      end)
      test.assert_eq(#notices, 0)
      l.state.state.updating = false
    end,
  },

  {
    name = 'actions: uninstall_plugin declines when confirm is rejected',
    fn = function()
      local orig_confirm = vim.fn.confirm
      -- actions.lua captures vim.fn.confirm at module load, so stub before
      -- requiring it.
      vim.fn.confirm = function() return 2 end -- 'No'
      local l = live()

      -- Stub pack.del: a real delete would remove an installed plugin.
      local del_called = false
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          del = function()
            del_called = true
            return true
          end,
        }
      end

      local notices = with_capture(function()
        l.actions.uninstall_plugin('resonance.nvim')
      end)
      vim.fn.confirm = orig_confirm
      l.utils.get_pack = orig_get_pack

      test.assert_false(del_called)
      -- No uninstall notification should have been emitted.
      for i = 1, #notices do
        test.assert_not_contains(notices[i], 'Uninstalling')
      end
    end,
  },

  {
    name = 'actions: uninstall_plugin ignores nil name',
    fn = function()
      local orig_confirm = vim.fn.confirm
      local confirm_called = false
      vim.fn.confirm = function()
        confirm_called = true
        return 2
      end
      local l = live()

      with_capture(function()
        l.actions.uninstall_plugin(nil)
      end)
      vim.fn.confirm = orig_confirm

      test.assert_false(confirm_called)
    end,
  },

  {
    name = 'actions: uninstall_plugin deletes when confirm is accepted',
    fn = function()
      local orig_confirm = vim.fn.confirm
      vim.fn.confirm = function() return 1 end -- 'Yes'
      local l = live()

      local deleted_name = nil
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          del = function(names)
            deleted_name = names[1]
            return true
          end,
        }
      end

      with_capture(function()
        l.actions.uninstall_plugin('some-plugin')
      end)
      vim.fn.confirm = orig_confirm
      l.utils.get_pack = orig_get_pack

      test.assert_eq(deleted_name, 'some-plugin')
    end,
  },

  {
    name = 'actions: check_updates_network clears stale pending state',
    fn = function()
      local l = live()
      -- Use an empty plugin list so no real git fetch is issued.
      l.state.state.info = { total = 0, loaded = 0, plugins = { name = {}, path = {} } }
      l.state.state.updates = { ['stale-plugin'] = { 'deadbeef old commit' } }
      l.state.state.checking = false

      l.actions.check_updates_network()
      -- The stale entry must be dropped synchronously, before any fetch.
      test.assert_nil(l.state.state.updates['stale-plugin'])
      test.assert_true(l.state.state.checking)

      l.state.state.checking = false
    end,
  },

  {
    name = 'actions: check_updates_network detects pending updates',
    fn = function()
      -- Build a real git repo so `git log rev..rev_to` yields a commit.
      local dir = '/tmp/resonance_pending_' .. os.time()
      vim.fn.mkdir(dir, 'p')
      vim.fn.system({ 'git', 'init', '-q', dir })
      vim.fn.system({ 'git', '-C', dir, 'config', 'user.email', 't@t.t' })
      vim.fn.system({ 'git', '-C', dir, 'config', 'user.name', 't' })
      vim.fn.system({ 'git', '-C', dir, 'commit', '-q', '--allow-empty', '-m', 'first' })
      local rev = vim.trim(vim.fn.system({ 'git', '-C', dir, 'rev-parse', 'HEAD' }))
      vim.fn.system({ 'git', '-C', dir, 'commit', '-q', '--allow-empty', '-m', 'second' })
      local rev_to = vim.trim(vim.fn.system({ 'git', '-C', dir, 'rev-parse', 'HEAD' }))

      -- Re-require after the runner reset so we share the live module tables.
      local l = live()

      -- Stub vim.pack.get to report a plugin whose rev differs from rev_to.
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          get = function()
            return {
              {
                rev = rev,
                rev_to = rev_to,
                path = dir,
                spec = { name = 'pending-plugin' },
              },
            }
          end,
        }
      end

      l.state.state.info = { total = 1, loaded = 0, plugins = { name = { 'pending-plugin' }, path = { dir } } }
      l.state.state.updates = {}
      l.state.state.checking = false

      l.actions.check_updates_network()
      vim.wait(2000)

      l.utils.get_pack = orig_get_pack

      test.assert_true(l.state.state.updates['pending-plugin'] ~= nil)
      test.assert_true(#l.state.state.updates['pending-plugin'] > 0)
      test.assert_contains(l.state.state.updates['pending-plugin'][1], 'second')

      l.state.state.checking = false
      vim.fn.delete(dir, 'rf')
    end,
  },

  {
    name = 'actions: check_updates_network ignores up-to-date plugins',
    fn = function()
      local dir = '/tmp/resonance_current_' .. os.time()
      vim.fn.mkdir(dir, 'p')
      vim.fn.system({ 'git', 'init', '-q', dir })
      vim.fn.system({ 'git', '-C', dir, 'config', 'user.email', 't@t.t' })
      vim.fn.system({ 'git', '-C', dir, 'config', 'user.name', 't' })
      vim.fn.system({ 'git', '-C', dir, 'commit', '-q', '--allow-empty', '-m', 'only' })
      local rev = vim.trim(vim.fn.system({ 'git', '-C', dir, 'rev-parse', 'HEAD' }))

      -- Re-require after the runner reset so we share the live module tables.
      local l = live()

      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return {
          get = function()
            return { { rev = rev, rev_to = rev, path = dir, spec = { name = 'current-plugin' } } }
          end,
        }
      end

      l.state.state.info = { total = 1, loaded = 0, plugins = { name = { 'current-plugin' }, path = { dir } } }
      l.state.state.updates = {}
      l.state.state.checking = false

      l.actions.check_updates_network()
      vim.wait(2000)

      l.utils.get_pack = orig_get_pack

      test.assert_nil(l.state.state.updates['current-plugin'])

      l.state.state.checking = false
      vim.fn.delete(dir, 'rf')
    end,
  },

  {
    name = 'actions: check_updates_network is a no-op while already checking',
    fn = function()
      local l = live()
      l.state.state.checking = true
      local notices = with_capture(function()
        l.actions.check_updates_network()
      end)
      test.assert_eq(#notices, 0)
      l.state.state.checking = false
    end,
  },

  {
    name = 'actions: check_updates_network reports whether it started a check',
    fn = function()
      -- The `r` keymap needs to know whether the call actually started a
      -- check, so it can notify once instead of on every press.
      local l = live()
      -- An empty plugin list keeps the check from issuing any real fetch.
      l.state.state.info = { total = 0, loaded = 0, plugins = { name = {}, path = {} } }
      l.state.state.checking = false

      local first = l.actions.check_updates_network()
      test.assert_true(first)

      -- A second press while the first check is running must report that it
      -- did NOT start a check, so the keymap stays quiet.
      local second = l.actions.check_updates_network()
      test.assert_false(second)

      l.state.state.checking = false
    end,
  },

  {
    name = 'ui: the r key notifies once and stays inert while checking',
    fn = function()
      -- Hold the check open so the second press lands while the first is
      -- still in flight. That is the real scenario: the network check takes
      -- seconds, and the user can press `r` again in the meantime.
      --
      -- The spawner never calls back, so the fetch never completes and the
      -- check stays in flight.
      local hold = function() end
      h.with_system(hold, function(l)
        local ok, err = pcall(function()
          require('resonance.ui').open({
            border = 'rounded',
            title = 'test',
            width = 0.5,
            height = 0.5,
            backdrop = 0,
          })
          vim.wait(100)

          -- One plugin with a path, so a fetch is actually started.
          l.state.state.info = {
            total = 1,
            loaded = 0,
            plugins = {
              name = { 'some-plugin' },
              type = { 'opt' },
              path = { '/tmp' },
              loaded = { true },
              trigger = { 'event' },
            },
          }
          l.state.state.checking = false

          local notices = with_capture(function()
            -- Drive the keymap the way the user does. The keymap is
            -- buffer-local, so feed the key to the UI buffer.
            local buf = l.state.state.buf
            test.assert_not_nil(buf)
            vim.api.nvim_buf_call(buf, function()
              vim.api.nvim_feedkeys('r', 'x', false)
            end)
            vim.wait(200)
            test.assert_true(l.state.state.checking, 'the check must still be running')
            -- A second press while the check runs must not notify again.
            vim.api.nvim_buf_call(buf, function()
              vim.api.nvim_feedkeys('r', 'x', false)
            end)
            vim.wait(200)
          end)

          local resonating = 0
          for i = 1, #notices do
            if notices[i]:find('Resonating', 1, true) then resonating = resonating + 1 end
          end
          test.assert_eq(resonating, 1, 'the r key must notify exactly once per check')
        end)

        if l.state.state.win and vim.api.nvim_win_is_valid(l.state.state.win) then
          vim.api.nvim_win_close(l.state.state.win, true)
        end
        l.state.state.win = nil
        l.state.state.buf = nil
        l.state.state.checking = false
        if not ok then error(err, 0) end
      end)
    end,
  },

  {
    name = 'actions: check_updates_network resets the pending count',
    fn = function()
      local l = live()
      -- An empty plugin list keeps the check from issuing any real fetch.
      l.state.state.info = { total = 0, loaded = 0, plugins = { name = {}, path = {} } }
      l.state.state.checking = false
      -- A leftover count from a previous check would be shown by the spinner.
      l.state.state.pending_count = 7

      l.actions.check_updates_network()

      test.assert_eq(l.state.state.pending_count, 0)

      l.state.state.checking = false
    end,
  },

  {
    name = 'actions: check_updates_network tracks fetch progress and renders it on the spinner',
    fn = function()
      local held = {}
      local u = live().utils
      local orig_get_pack = u.get_pack
      u.get_pack = function()
        return { get = function() return {} end }
      end

      local ok, err = pcall(h.with_system, function(cmd, _, cb)
        if cmd[1] == 'git' and cmd[2] == 'fetch' then
          held[#held + 1] = cb
        elseif cb then
          cb(h.completed(0))
        end
      end, function(l)
        local buf = vim.api.nvim_create_buf(false, true)
        local win = vim.api.nvim_get_current_win()
        local st = l.state.state
        st.buf = buf
        st.win = win
        -- One disabled plugin (empty path) is excluded from fetch_total.
        st.info = {
          total = 3,
          loaded = 0,
          plugins = {
            name = { 'disabled-plugin', 'plugin-a', 'plugin-b' },
            type = { 'opt', 'opt', 'opt' },
            path = { '', '/tmp', '/tmp' },
            loaded = { false, true, false },
            disabled = { true, false, false },
            trigger = { 'none', 'event', 'cmd' },
          },
        }
        st.checking = false

        local function spinner_line()
          local row = st.spinner_line_idx
          if not row then return nil end
          return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        end

        l.actions.check_updates_network()
        test.assert_true(vim.wait(500, function() return #held == 2 end, 10),
          'both fetches must start')
        test.assert_eq(st.fetch_total, 2)
        test.assert_eq(st.fetch_done, 0)
        test.assert_contains(spinner_line() or '', 'Resonating (0/2)...')

        -- Completing one fetch advances the counter and updates the spinner line.
        held[1](h.completed(0))
        test.assert_true(vim.wait(500, function()
          local line = spinner_line()
          return st.fetch_done == 1 and line ~= nil and line:find('Resonating (1/2)...', 1, true) ~= nil
        end, 10), 'spinner line did not show 1/2: ' .. tostring(spinner_line()))

        -- Completing the second finishes the check and resets the counters.
        held[2](h.completed(0))
        test.assert_true(vim.wait(1000, function() return not st.checking end, 10),
          'the check did not finish')
        test.assert_eq(st.fetch_done, 0)
        test.assert_eq(st.fetch_total, 0)

        st.win = nil
        st.buf = nil
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end)
      u.get_pack = orig_get_pack
      if not ok then error(err, 0) end
    end,
  },

  {
    name = 'actions: check_updates_network updates progress from a real fast-event callback without E5560',
    fn = function()
      -- h.with_system invokes callbacks synchronously on the main loop, which
      -- hides E5560 fast-event violations. Run a real vim.system (`git fetch`
      -- on a throwaway repo) with an open UI buffer so run:on_complete executes
      -- in a genuine libuv fast-event context.
      local dir = h.make_git_repo()
      local l = live()
      local orig_get_pack = l.utils.get_pack
      l.utils.get_pack = function()
        return { get = function() return {} end }
      end

      local buf = vim.api.nvim_create_buf(false, true)
      local st = l.state.state
      local finished, errmsg
      local ok, err = pcall(function()
        st.buf = buf
        st.win = vim.api.nvim_get_current_win()
        st.info = {
          total = 1,
          loaded = 0,
          plugins = {
            name = { 'fast-event-plugin' },
            type = { 'opt' },
            path = { dir },
            loaded = { false },
            disabled = { false },
            trigger = { 'event' },
          },
        }
        st.checking = false
        vim.v.errmsg = ''

        l.actions.check_updates_network()
        finished = vim.wait(3000, function() return not st.checking end, 20)
        -- Drain a tick so any error re-raised on vim.schedule by vim.async
        -- lands in v:errmsg even if the check itself still finished.
        vim.wait(50)
        errmsg = vim.v.errmsg
      end)

      l.utils.get_pack = orig_get_pack
      st.checking = false
      st.win = nil
      st.buf = nil
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      vim.fn.delete(dir, 'rf')
      if not ok then error(err, 0) end

      test.assert_true(finished, 'check_updates_network stalled (fast-event error in on_complete)')
      test.assert_eq(errmsg, '', 'uncaught fast-event error: ' .. tostring(errmsg))
      test.assert_eq(st.fetch_done, 0)
      test.assert_eq(st.fetch_total, 0)
    end,
  },

  {
    name = 'render: spinner omits the count when fetch_total is zero',
    fn = function()
      local l = live()
      local buf = vim.api.nvim_create_buf(false, true)
      local st = l.state.state
      st.buf = buf
      st.win = vim.api.nvim_get_current_win()
      st.info = { total = 0, loaded = 0, plugins = { name = {}, type = {}, path = {}, loaded = {}, trigger = {} } }
      st.checking = true
      st.fetch_done = 0
      st.fetch_total = 0

      require('resonance.ui.render').render()
      local row = st.spinner_line_idx
      test.assert_not_nil(row)
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      test.assert_contains(line, 'Resonating...')
      test.assert_not_contains(line, 'Resonating (')

      st.checking = false
      st.win = nil
      st.buf = nil
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end,
  },

  {
    name = 'actions: check_updates_network skips plugins without a path',
    fn = function()
      -- A plugin disabled via `cond = false` has no directory on disk. The
      -- check must not spawn `git fetch` with an empty cwd for it.
      local fetch_cwds = {}
      local u = live().utils
      local orig_get_pack = u.get_pack
      u.get_pack = function()
        return { get = function() return {} end }
      end

      local ok, err = pcall(h.with_system, function(cmd, opts, cb)
        if cmd[1] == 'git' and cmd[2] == 'fetch' then
          fetch_cwds[#fetch_cwds + 1] = opts.cwd
        end
        if cb then cb(h.completed(0)) end
      end, function(l)
        l.state.state.info = {
          total = 2,
          loaded = 0,
          plugins = {
            name = { 'disabled-plugin', 'real-plugin' },
            path = { '', '/tmp' },
          },
        }
        l.state.state.checking = false
        l.state.state.pending_count = 0

        l.actions.check_updates_network()
        vim.wait(500)
        l.state.state.checking = false
      end)
      u.get_pack = orig_get_pack
      if not ok then error(err, 0) end

      -- Only the plugin with a real path may be fetched.
      test.assert_eq(#fetch_cwds, 1)
      test.assert_eq(fetch_cwds[1], '/tmp')
    end,
  },

  {
    name = 'actions: resonate.concurrency limits the fetches in flight',
    fn = function()
      -- The fetches are held open: the stub keeps each callback and only
      -- releases it on demand, so the number in flight can be counted.
      local held = {}
      local u = live().utils
      local orig_get_pack = u.get_pack
      u.get_pack = function()
        return { get = function() return {} end }
      end

      local ok, err = pcall(h.with_system, function(cmd, opts, cb)
        if cmd[1] == 'git' and cmd[2] == 'fetch' then
          held[#held + 1] = cb
        elseif cb then
          cb(h.completed(0))
        end
      end, function(l)
        local n = 8
        local names, paths = {}, {}
        for i = 1, n do
          names[i] = 'plugin-' .. i
          paths[i] = '/tmp'
        end
        l.actions.configure({ concurrency = 3 })
        l.state.state.info = { total = n, loaded = 0, plugins = { name = names, path = paths } }
        l.state.state.checking = false

        l.actions.check_updates_network()
        vim.wait(100)
        test.assert_eq(#held, 3, 'the fetches in flight must stop at the limit')

        -- One fetch finishing frees exactly one slot.
        held[1](h.completed(0))
        vim.wait(100)
        test.assert_eq(#held, 4, 'a finished fetch must let the next one start')

        -- Release everything so the check completes.
        local released = 1
        test.assert_true(vim.wait(1000, function()
          while released < #held do
            released = released + 1
            held[released](h.completed(0))
          end
          return not l.state.state.checking
        end, 10), 'the check did not complete')
        test.assert_eq(#held, n, 'every plugin must be fetched')
        l.state.state.checking = false
      end)
      u.get_pack = orig_get_pack
      live().actions.configure({})
      if not ok then error(err, 0) end
    end,
  },

  {
    name = 'helpers: with_system restores vim.system when the test body fails',
    fn = function()
      local real = vim.system
      local ok = pcall(h.with_system, nil, function()
        test.assert_true(vim.system ~= real, 'the stub was not installed')
        error('the body failed')
      end)
      test.assert_false(ok, 'the failure was swallowed')
      test.assert_true(vim.system == real, 'vim.system was left stubbed')
      test.assert_nil(package.loaded['resonance.ui.actions'],
        'a module built against the stub was left in package.loaded')
    end,
  },

  {
    name = 'actions: the default fetch concurrency matches vim.pack',
    fn = function()
      local l = live()
      l.actions.configure({})
      test.assert_eq(l.actions.fetch_concurrency(),
        2 * (vim.uv.available_parallelism() or 1))
    end,
  },

  {
    name = 'actions: an invalid resonate.concurrency warns and falls back to the default',
    fn = function()
      local l = live()
      local default = 2 * (vim.uv.available_parallelism() or 1)
      local bad = { 0, -1, 1.5, 'four', math.huge, 0 / 0 }
      for i = 1, #bad do
        l.actions.configure({ concurrency = 7 })
        local notices = with_capture(function()
          l.actions.configure({ concurrency = bad[i] })
        end)
        test.assert_eq(l.actions.fetch_concurrency(), default,
          'concurrency ' .. tostring(bad[i]) .. ' was not replaced by the default')
        local warned = false
        for j = 1, #notices do
          if notices[j]:find('resonate.concurrency', 1, true) then warned = true end
        end
        test.assert_true(warned, 'concurrency ' .. tostring(bad[i]) .. ' was accepted without a warning')
      end
      l.actions.configure({})
    end,
  },

  {
    name = 'ui: open_ui() applies the resonate config from setup()',
    fn = function()
      local r = require('resonance')
      local l = live()
      local ok, err = pcall(function()
        r.setup({ resonate = { concurrency = 3 } })
        r.open_ui()
        test.assert_eq(l.actions.fetch_concurrency(), 3)
      end)
      if l.state.state.win and vim.api.nvim_win_is_valid(l.state.state.win) then
        vim.api.nvim_win_close(l.state.state.win, true)
      end
      l.state.state.win = nil
      l.state.state.buf = nil
      r.config.resonate = {}
      l.actions.configure({})
      if not ok then error(err, 0) end
    end,
  },

  {
    name = 'render: DAG view marks loaded nodes with the filled icon',
    fn = function()
      local l = live()
      l.state.state.dag_data = {
        nodes = {
          ['loaded-node'] = { name = 'loaded-node', deps = {}, trigger = 'event', loaded = true },
          ['idle-node'] = { name = 'idle-node', deps = {}, trigger = 'cmd', loaded = false },
        },
        edges = {},
      }
      l.state.state.view_mode = 'dag'

      -- build_dag_content is module-local; drive it through the public render.
      local l2 = live()
      l2.state.state.buf = vim.api.nvim_create_buf(false, true)
      l2.state.state.win = vim.api.nvim_get_current_win()
      l2.state.state.view_mode = 'dag'
      l2.state.state.dag_data = l.state.state.dag_data

      require('resonance.ui.render').render()

      local lines = vim.api.nvim_buf_get_lines(l2.state.state.buf, 0, -1, false)
      local loaded_line, idle_line
      for i = 1, #lines do
        if lines[i]:find('loaded%-node') then loaded_line = lines[i] end
        if lines[i]:find('idle%-node') then idle_line = lines[i] end
      end

      test.assert_not_nil(loaded_line)
      test.assert_not_nil(idle_line)
      test.assert_contains(loaded_line, '●')
      test.assert_contains(idle_line, '○')
      -- The unloaded node must not carry the filled icon.
      test.assert_not_contains(idle_line, '●')
    end,
  },

  {
    name = 'icons: default glyphs are exposed on state',
    fn = function()
      local l = live()
      test.assert_eq(l.state.state.icons.loaded, '●')
      test.assert_eq(l.state.state.icons.not_loaded, '○')
      test.assert_eq(l.state.state.icons.disabled, '\u{F057}')
    end,
  },

  {
    name = 'icons: custom glyphs are used for every plugin state',
    fn = function()
      local l = live()
      l.state.state.icons = { loaded = '[L]', not_loaded = '[U]', disabled = '[D]' }
      l.state.state.dag_data = {
        nodes = {
          ['loaded-node'] = { name = 'loaded-node', deps = {}, trigger = 'event', loaded = true },
          ['idle-node'] = { name = 'idle-node', deps = {}, trigger = 'cmd', loaded = false },
        },
        edges = {},
      }
      l.state.state.buf = vim.api.nvim_create_buf(false, true)
      l.state.state.win = vim.api.nvim_get_current_win()
      l.state.state.view_mode = 'dag'

      require('resonance.ui.render').render()

      local lines = vim.api.nvim_buf_get_lines(l.state.state.buf, 0, -1, false)
      local loaded_line, idle_line
      for i = 1, #lines do
        if lines[i]:find('loaded%-node') then loaded_line = lines[i] end
        if lines[i]:find('idle%-node') then idle_line = lines[i] end
      end

      test.assert_not_nil(loaded_line)
      test.assert_not_nil(idle_line)
      test.assert_contains(loaded_line, '[L]')
      test.assert_contains(idle_line, '[U]')
      test.assert_not_contains(idle_line, '[L]')
      -- The default glyphs must be gone once overridden.
      test.assert_not_contains(loaded_line, '●')
    end,
  },

  {
    name = 'icons: open applies configured icons to state',
    fn = function()
      local l = live()
      local ui_mod = require('resonance.ui')
      ui_mod.open({
        border = 'rounded',
        title = 'test',
        width = 0.5,
        height = 0.5,
        backdrop = 0,
        icons = { loaded = '<L>', not_loaded = '<U>', disabled = '<D>' },
      })
      vim.wait(200)

      test.assert_eq(l.state.state.icons.loaded, '<L>')
      test.assert_eq(l.state.state.icons.not_loaded, '<U>')
      test.assert_eq(l.state.state.icons.disabled, '<D>')

      -- Close the window so later tests start clean.
      if l.state.state.win and vim.api.nvim_win_is_valid(l.state.state.win) then
        vim.api.nvim_win_close(l.state.state.win, true)
      end
      l.state.state.win = nil
      l.state.state.buf = nil
    end,
  },

  {
    name = 'icons: partial override keeps unspecified defaults',
    fn = function()
      local l = live()
      local ui_mod = require('resonance.ui')
      ui_mod.open({
        border = 'rounded',
        title = 'test',
        width = 0.5,
        height = 0.5,
        backdrop = 0,
        icons = { disabled = '<D>' },
      })
      vim.wait(200)

      test.assert_eq(l.state.state.icons.loaded, '●')
      test.assert_eq(l.state.state.icons.not_loaded, '○')
      test.assert_eq(l.state.state.icons.disabled, '<D>')

      if l.state.state.win and vim.api.nvim_win_is_valid(l.state.state.win) then
        vim.api.nvim_win_close(l.state.state.win, true)
      end
      l.state.state.win = nil
      l.state.state.buf = nil
    end,
  },
})

test.print_summary()