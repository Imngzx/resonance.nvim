-- Behavioral tests for resonance.nvim
--
-- These assert observable outcomes, not just that functions exist. Each test
-- must fail if the behavior it describes regresses.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api

-- The runner clears package.loaded between tests, so module tables captured at
-- file scope can be a different generation than the one under test. Always
-- re-require inside a test when touching module state.
local function live()
  return {
    loader = require('resonance.loader'),
    dag = require('resonance.loader.dag'),
    state = require('resonance.ui.state'),
    actions = require('resonance.ui.actions'),
    utils = require('resonance.utils'),
  }
end

-- Capture notifications emitted by the module under test.
--
-- utils.notify defers through vim.schedule, so a capture that restores the
-- stub immediately would miss anything reported asynchronously. The stub
-- stays installed until the caller is done with it.
local function with_capture(fn)
  local u = live().utils
  local notices = {}
  local orig_notify = u.notify
  u.notify = function(msg, ...)
    notices[#notices + 1] = msg
  end
  local ok, err = pcall(fn)
  if not ok then
    u.notify = orig_notify
    error(err)
  end
  return notices, function()
    u.notify = orig_notify
  end
end

-- Wait for scheduled notifications to arrive, then release the capture.
local function capture_and_wait(fn, ms)
  local notices, release = with_capture(fn)
  vim.wait(ms or 1000)
  release()
  return notices
end

-- True when any captured notice contains the given text.
local function noticed(notices, text)
  for i = 1, #notices do
    if notices[i]:find(text, 1, true) then return true end
  end
  return false
end

-- A scratch group for autocmds created by a test.
local function scratch_group(name)
  return api.nvim_create_augroup(name, { clear = true })
end

-- Events recorded by a handler, in the order they fire.
local function recorder(event, opts)
  opts = opts or {}
  local seen = {}
  local group = opts.group or scratch_group(opts.group_name or 'ResonanceBehavior')
  api.nvim_create_autocmd(event, {
    group = group,
    buffer = opts.buffer,
    callback = function(args)
      seen[#seen + 1] = { event = args.event, buf = args.buf, match = args.match }
    end,
  })
  return seen
end

local function count(seen)
  return #seen
end

-- A throwaway git repository with one commit. check_updates_network runs a
-- real `git fetch`, which only completes against a real repository.
local function make_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.system({ 'git', 'init', '-q', dir })
  vim.fn.writefile({ 'x' }, dir .. '/file.txt')
  vim.fn.system({ 'git', '-C', dir, 'add', '.' })
  vim.fn.system({
    'git', '-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
    'commit', '-q', '-m', 'initial',
  })
  return dir
end

test.run_suite('resonance.behavior', {
  -- ---------------------------------------------------------------------
  -- Event chain: the structure the replay is built on
  -- ---------------------------------------------------------------------

  {
    name = 'chain: a global autocmd on BufReadPost appears in the chain',
    fn = function()
      local l = live()
      local group = scratch_group('ResonanceChainGlobal')
      api.nvim_create_autocmd('BufReadPost', { group = group, callback = function() end })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('BufReadPre', buf, {})

      local events = {}
      for i = 1, #chain do
        events[#events + 1] = chain[i].event
      end

      -- The origin must be present, and the successor must be reachable.
      test.assert_eq(events[1], 'BufReadPre')
      test.assert_true(vim.tbl_contains(events, 'BufReadPost'))
    end,
  },

  {
    name = 'chain: BufRead and BufReadPost are not both listed',
    fn = function()
      local l = live()
      local group = scratch_group('ResonanceChainAlias')
      api.nvim_create_autocmd('BufRead', { group = group, callback = function() end })
      api.nvim_create_autocmd('BufReadPost', { group = group, callback = function() end })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('BufReadPre', buf, {})

      -- Neovim aliases the two events, so listing both would replay the
      -- same handlers twice.
      local read, post = 0, 0
      for i = 1, #chain do
        if chain[i].event == 'BufRead' then read = read + 1 end
        if chain[i].event == 'BufReadPost' then post = post + 1 end
      end
      test.assert_eq(read + post, 1)
    end,
  },

  {
    name = 'chain: the origin event carries the groups that already handled it',
    fn = function()
      local l = live()
      local group_name = 'ResonanceChainExclude'
      scratch_group(group_name)
      api.nvim_create_autocmd('BufReadPre', { group = group_name, callback = function() end })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('BufReadPre', buf, {})

      test.assert_true(#chain >= 1)
      test.assert_eq(chain[1].event, 'BufReadPre')
      -- The exclude set is keyed by group name, which is how the replay
      -- matches groups when it fires them.
      test.assert_true(chain[1].exclude[group_name] == true)
    end,
  },

  {
    name = 'chain: a non-buffer event terminates the chain',
    fn = function()
      local l = live()
      local group = scratch_group('ResonanceChainUser')
      api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'ResonanceChainUser',
        callback = function() end,
      })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('User', buf, {})

      test.assert_eq(#chain, 1)
      test.assert_eq(chain[1].event, 'User')
    end,
  },

  -- ---------------------------------------------------------------------
  -- Replay: what actually fires, and what must not fire
  -- ---------------------------------------------------------------------

  {
    name = 'replay: the triggering event handler runs exactly once',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local seen = recorder('BufReadPre', { group_name = 'ResonanceReplayOnce', buffer = buf })

      _G.resonance.load({
        src = 'https://github.com/test/replay-once',
        event = 'BufReadPre',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(100)

      test.assert_eq(count(seen), 1)
    end,
  },

  {
    name = 'replay: a successor event that has not fired yet is not replayed',
    fn = function()
      local l = live()
      local seen = recorder('BufReadPost', { group_name = 'ResonanceReplayPending' })

      _G.resonance.load({
        src = 'https://github.com/test/replay-pending',
        event = 'BufReadPre',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufReadPre', { modeline = false })
      vim.wait(100)

      -- BufReadPost is still to come for this read; firing it now would run
      -- the handler twice for a single read.
      test.assert_eq(count(seen), 0)
    end,
  },

  {
    name = 'replay: a successor event that already fired for this buffer is replayed once',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local seen = recorder('BufReadPost', { group_name = 'ResonanceReplayFired', buffer = buf })

      -- Mark the read as done for this buffer.
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
      test.assert_eq(count(seen), 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-fired',
        event = 'BufNewFile',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufNewFile', { buffer = buf, modeline = false })
      vim.wait(100)

      -- BufNewFile's chain reaches BufReadPost, which already ran for this
      -- buffer, so it is replayed. Exactly once: the origin event is never
      -- replayed, and an alias must not double the count.
      test.assert_eq(count(seen), 2)
    end,
  },

  {
    name = 'replay: a read on one buffer does not replay another buffer',
    fn = function()
      local l = live()
      local buf_a = api.nvim_create_buf(false, true)
      local buf_b = api.nvim_create_buf(false, true)

      local seen_a = recorder('BufReadPost', { group_name = 'ResonanceReplayBufA', buffer = buf_a })
      local seen_b = recorder('BufReadPost', { group_name = 'ResonanceReplayBufB', buffer = buf_b })

      -- Buffer A's read already happened.
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf_a, modeline = false })
      test.assert_eq(count(seen_a), 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-two-buffers',
        event = 'BufNewFile',
        setup = function() end,
      })

      -- Buffer B is a different buffer, so A's state must not apply to it.
      api.nvim_exec_autocmds('BufNewFile', { buffer = buf_b, modeline = false })
      vim.wait(100)

      test.assert_eq(count(seen_a), 1)
      test.assert_eq(count(seen_b), 0)
    end,
  },

  {
    name = 'replay: nested triggers do not recurse without bound',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local depth = 0
      local max_depth = 0

      local group = scratch_group('ResonanceReplayDepth')
      api.nvim_create_autocmd('BufReadPre', {
        group = group,
        buffer = buf,
        nested = true,
        callback = function()
          depth = depth + 1
          if depth > max_depth then max_depth = depth end
          -- Re-enter the read pipeline, the way a picker opening a file does.
          if depth < 40 then
            pcall(function() api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false }) end)
          end
        end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-depth',
        event = 'BufReadPre',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(200)

      -- The loader must not stack replays on top of each other. The handler
      -- above recurses on its own, so the bound is on the loader's own
      -- contribution, which shows up as an unbounded depth here.
      test.assert_true(max_depth <= 40, 'nesting depth exceeded the bound: ' .. max_depth)
    end,
  },

  -- ---------------------------------------------------------------------
  -- Trigger registration: what the loader actually wires up
  -- ---------------------------------------------------------------------

  {
    name = 'triggers: a cmd trigger creates the command',
    fn = function()
      local l = live()
      _G.resonance.load({
        src = 'https://github.com/test/cmd-trigger',
        cmd = 'ResonanceTestCmd',
        setup = function() end,
      })

      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds['ResonanceTestCmd'])
    end,
  },

  {
    name = 'triggers: a cmd trigger runs the plugin setup when invoked',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cmd-trigger-run',
        cmd = 'ResonanceTestCmdRun',
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceTestCmdRun', modeline = false })
      -- The command itself is what loads the plugin.
      vim.cmd('ResonanceTestCmdRun')
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  {
    name = 'triggers: an ft trigger fires on the matching filetype',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/ft-trigger',
        ft = 'resonancebehaviortest',
        setup = function() ran = true end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(buf, 'x.resonancebehaviortest')
      vim.bo[buf].filetype = 'resonancebehaviortest'
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  {
    name = 'triggers: a cond that is false skips the plugin entirely',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cond-false',
        event = 'User',
        cond = function() return false end,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceCondTest', modeline = false })
      vim.wait(100)

      test.assert_false(ran)
    end,
  },

  {
    name = 'triggers: a cond that is true loads the plugin',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cond-true',
        event = { 'User', pattern = 'ResonanceCondTrueTest' },
        cond = function() return true end,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceCondTrueTest', modeline = false })
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  -- ---------------------------------------------------------------------
  -- UI actions: observable outcomes
  -- ---------------------------------------------------------------------

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
      local l = live()
      local post_fires = 0
      api.nvim_create_autocmd('BufReadPost', {
        callback = function() post_fires = post_fires + 1 end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-ungrouped-a',
        event = 'BufReadPre',
        setup = function() end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/replay-ungrouped-b',
        event = 'BufReadPre',
        setup = function() end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(300)

      -- The replay must not fire the ungrouped trigger at all.
      test.assert_eq(post_fires, 0)
    end,
  },

  {
    name = 'replay: an ungrouped trigger that re-fires the event does not recurse',
    fn = function()
      -- The shape that produced E218: an ungrouped handler that fires the
      -- event again, reached through the replay.
      local l = live()
      local fires = 0
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
        setup = function() end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/replay-recursion-b',
        event = 'BufReadPre',
        setup = function() end,
      })

      local buf = api.nvim_create_buf(false, true)
      local ok, err = pcall(api.nvim_exec_autocmds, 'BufReadPre', { buffer = buf, modeline = false })
      vim.wait(300)

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

-- Behavioral tests for resonance.nvim
--
-- These assert observable outcomes, not just that functions exist. Each test
-- must fail if the behavior it describes regresses.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api

-- The runner clears package.loaded between tests, so module tables captured at
-- file scope can be a different generation than the one under test. Always
-- re-require inside a test when touching module state.
local function live()
  return {
    loader = require('resonance.loader'),
    dag = require('resonance.loader.dag'),
    state = require('resonance.ui.state'),
    actions = require('resonance.ui.actions'),
    utils = require('resonance.utils'),
  }
end

-- Capture notifications emitted by the module under test.
--
-- utils.notify defers through vim.schedule, so a capture that restores the
-- stub immediately would miss anything reported asynchronously. The stub
-- stays installed until the caller is done with it.
local function with_capture(fn)
  local u = live().utils
  local notices = {}
  local orig_notify = u.notify
  u.notify = function(msg, ...)
    notices[#notices + 1] = msg
  end
  local ok, err = pcall(fn)
  if not ok then
    u.notify = orig_notify
    error(err)
  end
  return notices, function()
    u.notify = orig_notify
  end
end

-- Wait for scheduled notifications to arrive, then release the capture.
local function capture_and_wait(fn, ms)
  local notices, release = with_capture(fn)
  vim.wait(ms or 1000)
  release()
  return notices
end

-- True when any captured notice contains the given text.
local function noticed(notices, text)
  for i = 1, #notices do
    if notices[i]:find(text, 1, true) then return true end
  end
  return false
end

-- A scratch group for autocmds created by a test.
local function scratch_group(name)
  return api.nvim_create_augroup(name, { clear = true })
end

-- Events recorded by a handler, in the order they fire.
local function recorder(event, opts)
  opts = opts or {}
  local seen = {}
  local group = opts.group or scratch_group(opts.group_name or 'ResonanceBehavior')
  api.nvim_create_autocmd(event, {
    group = group,
    buffer = opts.buffer,
    callback = function(args)
      seen[#seen + 1] = { event = args.event, buf = args.buf, match = args.match }
    end,
  })
  return seen
end

local function count(seen)
  return #seen
end

-- A throwaway git repository with one commit. check_updates_network runs a
-- real `git fetch`, which only completes against a real repository.
local function make_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.system({ 'git', 'init', '-q', dir })
  vim.fn.writefile({ 'x' }, dir .. '/file.txt')
  vim.fn.system({ 'git', '-C', dir, 'add', '.' })
  vim.fn.system({
    'git', '-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
    'commit', '-q', '-m', 'initial',
  })
  return dir
end

test.run_suite('resonance.behavior', {
  -- ---------------------------------------------------------------------
  -- Event chain: the structure the replay is built on
  -- ---------------------------------------------------------------------

  {
    name = 'chain: a global autocmd on BufReadPost appears in the chain',
    fn = function()
      local l = live()
      local group = scratch_group('ResonanceChainGlobal')
      api.nvim_create_autocmd('BufReadPost', { group = group, callback = function() end })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('BufReadPre', buf, {})

      local events = {}
      for i = 1, #chain do
        events[#events + 1] = chain[i].event
      end

      -- The origin must be present, and the successor must be reachable.
      test.assert_eq(events[1], 'BufReadPre')
      test.assert_true(vim.tbl_contains(events, 'BufReadPost'))
    end,
  },

  {
    name = 'chain: BufRead and BufReadPost are not both listed',
    fn = function()
      local l = live()
      local group = scratch_group('ResonanceChainAlias')
      api.nvim_create_autocmd('BufRead', { group = group, callback = function() end })
      api.nvim_create_autocmd('BufReadPost', { group = group, callback = function() end })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('BufReadPre', buf, {})

      -- Neovim aliases the two events, so listing both would replay the
      -- same handlers twice.
      local read, post = 0, 0
      for i = 1, #chain do
        if chain[i].event == 'BufRead' then read = read + 1 end
        if chain[i].event == 'BufReadPost' then post = post + 1 end
      end
      test.assert_eq(read + post, 1)
    end,
  },

  {
    name = 'chain: the origin event carries the groups that already handled it',
    fn = function()
      local l = live()
      local group_name = 'ResonanceChainExclude'
      scratch_group(group_name)
      api.nvim_create_autocmd('BufReadPre', { group = group_name, callback = function() end })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('BufReadPre', buf, {})

      test.assert_true(#chain >= 1)
      test.assert_eq(chain[1].event, 'BufReadPre')
      -- The exclude set is keyed by group name, which is how the replay
      -- matches groups when it fires them.
      test.assert_true(chain[1].exclude[group_name] == true)
    end,
  },

  {
    name = 'chain: a non-buffer event terminates the chain',
    fn = function()
      local l = live()
      local group = scratch_group('ResonanceChainUser')
      api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'ResonanceChainUser',
        callback = function() end,
      })

      local buf = api.nvim_create_buf(false, true)
      local chain = l.dag._get_event_chain_internal('User', buf, {})

      test.assert_eq(#chain, 1)
      test.assert_eq(chain[1].event, 'User')
    end,
  },

  -- ---------------------------------------------------------------------
  -- Replay: what actually fires, and what must not fire
  -- ---------------------------------------------------------------------

  {
    name = 'replay: the triggering event handler runs exactly once',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local seen = recorder('BufReadPre', { group_name = 'ResonanceReplayOnce', buffer = buf })

      _G.resonance.load({
        src = 'https://github.com/test/replay-once',
        event = 'BufReadPre',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(100)

      test.assert_eq(count(seen), 1)
    end,
  },

  {
    name = 'replay: a successor event that has not fired yet is not replayed',
    fn = function()
      local l = live()
      local seen = recorder('BufReadPost', { group_name = 'ResonanceReplayPending' })

      _G.resonance.load({
        src = 'https://github.com/test/replay-pending',
        event = 'BufReadPre',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufReadPre', { modeline = false })
      vim.wait(100)

      -- BufReadPost is still to come for this read; firing it now would run
      -- the handler twice for a single read.
      test.assert_eq(count(seen), 0)
    end,
  },

  {
    name = 'replay: a successor event that already fired for this buffer is replayed once',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local seen = recorder('BufReadPost', { group_name = 'ResonanceReplayFired', buffer = buf })

      -- Mark the read as done for this buffer.
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
      test.assert_eq(count(seen), 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-fired',
        event = 'BufNewFile',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufNewFile', { buffer = buf, modeline = false })
      vim.wait(100)

      -- BufNewFile's chain reaches BufReadPost, which already ran for this
      -- buffer, so it is replayed. Exactly once: the origin event is never
      -- replayed, and an alias must not double the count.
      test.assert_eq(count(seen), 2)
    end,
  },

  {
    name = 'replay: a read on one buffer does not replay another buffer',
    fn = function()
      local l = live()
      local buf_a = api.nvim_create_buf(false, true)
      local buf_b = api.nvim_create_buf(false, true)

      local seen_a = recorder('BufReadPost', { group_name = 'ResonanceReplayBufA', buffer = buf_a })
      local seen_b = recorder('BufReadPost', { group_name = 'ResonanceReplayBufB', buffer = buf_b })

      -- Buffer A's read already happened.
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf_a, modeline = false })
      test.assert_eq(count(seen_a), 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-two-buffers',
        event = 'BufNewFile',
        setup = function() end,
      })

      -- Buffer B is a different buffer, so A's state must not apply to it.
      api.nvim_exec_autocmds('BufNewFile', { buffer = buf_b, modeline = false })
      vim.wait(100)

      test.assert_eq(count(seen_a), 1)
      test.assert_eq(count(seen_b), 0)
    end,
  },

  {
    name = 'replay: nested triggers do not recurse without bound',
    fn = function()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local depth = 0
      local max_depth = 0

      local group = scratch_group('ResonanceReplayDepth')
      api.nvim_create_autocmd('BufReadPre', {
        group = group,
        buffer = buf,
        nested = true,
        callback = function()
          depth = depth + 1
          if depth > max_depth then max_depth = depth end
          -- Re-enter the read pipeline, the way a picker opening a file does.
          if depth < 40 then
            pcall(function() api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false }) end)
          end
        end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-depth',
        event = 'BufReadPre',
        setup = function() end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(200)

      -- The loader must not stack replays on top of each other. The handler
      -- above recurses on its own, so the bound is on the loader's own
      -- contribution, which shows up as an unbounded depth here.
      test.assert_true(max_depth <= 40, 'nesting depth exceeded the bound: ' .. max_depth)
    end,
  },

  -- ---------------------------------------------------------------------
  -- Trigger registration: what the loader actually wires up
  -- ---------------------------------------------------------------------

  {
    name = 'triggers: a cmd trigger creates the command',
    fn = function()
      local l = live()
      _G.resonance.load({
        src = 'https://github.com/test/cmd-trigger',
        cmd = 'ResonanceTestCmd',
        setup = function() end,
      })

      local cmds = api.nvim_get_commands({})
      test.assert_not_nil(cmds['ResonanceTestCmd'])
    end,
  },

  {
    name = 'triggers: a cmd trigger runs the plugin setup when invoked',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cmd-trigger-run',
        cmd = 'ResonanceTestCmdRun',
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceTestCmdRun', modeline = false })
      -- The command itself is what loads the plugin.
      vim.cmd('ResonanceTestCmdRun')
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  {
    name = 'triggers: an ft trigger fires on the matching filetype',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/ft-trigger',
        ft = 'resonancebehaviortest',
        setup = function() ran = true end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(buf, 'x.resonancebehaviortest')
      vim.bo[buf].filetype = 'resonancebehaviortest'
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  {
    name = 'triggers: a cond that is false skips the plugin entirely',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cond-false',
        event = 'User',
        cond = function() return false end,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceCondTest', modeline = false })
      vim.wait(100)

      test.assert_false(ran)
    end,
  },

  {
    name = 'triggers: a cond that is true loads the plugin',
    fn = function()
      local l = live()
      local ran = false
      _G.resonance.load({
        src = 'https://github.com/test/cond-true',
        event = { 'User', pattern = 'ResonanceCondTrueTest' },
        cond = function() return true end,
        setup = function() ran = true end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceCondTrueTest', modeline = false })
      vim.wait(200)

      test.assert_true(ran)
    end,
  },

  -- ---------------------------------------------------------------------
  -- UI actions: observable outcomes
  -- ---------------------------------------------------------------------

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
      local l = live()
      local post_fires = 0
      api.nvim_create_autocmd('BufReadPost', {
        callback = function() post_fires = post_fires + 1 end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-ungrouped-a',
        event = 'BufReadPre',
        setup = function() end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/replay-ungrouped-b',
        event = 'BufReadPre',
        setup = function() end,
      })

      local buf = api.nvim_create_buf(false, true)
      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(300)

      -- The replay must not fire the ungrouped trigger at all.
      test.assert_eq(post_fires, 0)
    end,
  },

  {
    name = 'replay: an ungrouped trigger that re-fires the event does not recurse',
    fn = function()
      -- The shape that produced E218: an ungrouped handler that fires the
      -- event again, reached through the replay.
      local l = live()
      local fires = 0
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
        setup = function() end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/replay-recursion-b',
        event = 'BufReadPre',
        setup = function() end,
      })

      local buf = api.nvim_create_buf(false, true)
      local ok, err = pcall(api.nvim_exec_autocmds, 'BufReadPre', { buffer = buf, modeline = false })
      vim.wait(300)

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
