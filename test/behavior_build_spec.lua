-- build ordering
--
-- Part of the resonance.nvim behavioral suite.
--
-- The load flow used to run the plugin's setup() while its build was
-- still going: the plugin's tree was incomplete, and a setup that expects
-- the build's output failed against a half-built tree.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_build_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local live = h.live
local make_git_repo = h.make_git_repo

-- The builds module keeps the state of the builds. A test has to start
-- from a clean slate, or it sees the state of the previous test.
--
-- The module is not unloaded: the loader holds a reference to it, so
-- unloading it here would give the test a different instance than the
-- one the loader writes to. The state is cleared instead.
local function reset_builds()
  local builds = require('resonance.builds')
  builds._reset()
  return builds
end

-- A plugin that was built once is not built again: the marker in
-- Resonance's state directory records the commit it was built at, and it
-- outlives the plugin. A test that uses a fixed name therefore passes
-- once and fails on every run after it.
--
-- So every test uses a name of its own, and the marker is removed before
-- the test starts. The name is unique per run as well: two runs in
-- parallel would otherwise share a marker.
local run_id = tostring(vim.uv.hrtime()) .. '-' .. tostring(vim.uv.getpid())

local function fresh_name(label)
  return label .. '-' .. run_id
end

local function clear_marker(name)
  local dir = vim.fn.stdpath('state') .. '/resonance/builds'
  vim.fn.delete(dir .. '/' .. name)
end

test.run_suite('resonance.behavior.build', {

  {
    name = 'build: the setup runs after the build has finished',
    fn = function()
      -- The defect: setup() ran while the build was still in flight. The
      -- plugin was set up against a half-built tree.
      --
      -- The build is a Lua hook, so the test controls it exactly: it
      -- writes an artifact, and the setup checks that the artifact is
      -- there.
      local builds = reset_builds()
      test.stub_pack()

      local plugin = fresh_name('build-order')
      clear_marker(plugin)

      local artifact = vim.fn.tempname()
      vim.fn.delete(artifact)

      local setup_ran = false
      local artifact_at_setup = nil
      local build_ran = false

      _G.resonance.load({
        src = 'https://github.com/test/' .. plugin,
        cmd = 'ResonanceBuildOrder',
        build = function()
          build_ran = true
          local fd = io.open(artifact, 'w')
          fd:write('built')
          fd:close()
        end,
        setup = function()
          setup_ran = true
          artifact_at_setup = vim.uv.fs_stat(artifact) ~= nil
        end,
      })

      -- Nothing has run yet: the plugin is not loaded.
      test.assert_false(setup_ran, 'the setup ran before the plugin was loaded')
      test.assert_false(build_ran, 'the build ran before the plugin was loaded')

      -- Fire the command. The load starts the build and waits for it.
      vim.cmd('ResonanceBuildOrder')
      vim.wait(2000)

      test.assert_true(build_ran, 'the build never ran')
      test.assert_true(setup_ran, 'the setup never ran')
      test.assert_true(artifact_at_setup,
        'the setup ran before the build had finished')

      local status = builds.status(plugin)
      test.assert_not_nil(status, 'the build tracker has no entry for the plugin')
      test.assert_eq(status.state, 'ok')

      clear_marker(plugin)
    end,
  },

  {
    name = 'build: a plugin with no build is set up straight away',
    fn = function()
      reset_builds()
      test.stub_pack()

      local setup_ran = false
      _G.resonance.load({
        src = 'https://github.com/test/' .. fresh_name('no-build'),
        cmd = 'ResonanceNoBuild',
        setup = function() setup_ran = true end,
      })

      vim.cmd('ResonanceNoBuild')
      vim.wait(500)

      test.assert_true(setup_ran, 'the setup never ran')
    end,
  },

  {
    name = 'build: the setup is deferred for an automatic trigger',
    fn = function()
      -- An automatic load -- an event -- does not wait for the build. A
      -- plugin with a 60-second build would freeze the editor on
      -- startup. The setup is deferred until the build is done instead.
      local builds = reset_builds()
      test.stub_pack()

      local plugin = fresh_name('build-defer')
      clear_marker(plugin)

      local setup_ran = false
      _G.resonance.load({
        src = 'https://github.com/test/' .. plugin,
        event = { 'User', pattern = 'ResonanceBuildDefer' },
        build = function() end,
        setup = function() setup_ran = true end,
      })

      local start = vim.uv.hrtime()
      api.nvim_exec_autocmds('User', { pattern = 'ResonanceBuildDefer', modeline = false })
      local elapsed = (vim.uv.hrtime() - start) / 1e6

      -- The trigger returned straight away. The editor is not blocked by
      -- a build it did not ask for.
      test.assert_true(elapsed < 200,
        'the event trigger blocked for ' .. math.floor(elapsed) .. ' ms')

      -- The build is registered for the plugin, and the setup waits for
      -- it.
      vim.wait(1500)
      test.assert_true(setup_ran, 'the deferred setup never ran')
      local status = builds.status(plugin)
      test.assert_not_nil(status, 'the build tracker has no entry for the plugin')
      test.assert_eq(status.state, 'ok')

      clear_marker(plugin)
    end,
  },

  {
    name = 'build: the trigger that fired decides the wait, not the triggers the spec has',
    fn = function()
      -- The check used to be "the spec has cmd or keys". A spec with an
      -- event and a key then blocked the editor when the event loaded it,
      -- although nobody had asked for the plugin.
      local builds = reset_builds()
      test.stub_pack()

      local by_event, by_key = fresh_name('wait-by-event'), fresh_name('wait-by-key')
      clear_marker(by_event)
      clear_marker(by_key)
      local lhs_event = '<Plug>(WaitByEvent' .. run_id:sub(-4) .. ')'
      local lhs_key = '<Plug>(WaitByKey' .. run_id:sub(-4) .. ')'
      local ran = {}

      _G.resonance.load({
        {
          src = 'https://github.com/test/' .. by_event,
          event = { 'User', pattern = 'ResonanceWaitByEvent' },
          keys = { { 'n', lhs_event, function() end } },
          build = 'sleep 0.6',
          setup = function() ran.event = true end,
        },
        {
          src = 'https://github.com/test/' .. by_key,
          event = { 'User', pattern = 'ResonanceWaitByKey' },
          keys = { { 'n', lhs_key, function() end } },
          build = 'sleep 0.6',
          setup = function() ran.key = true end,
        },
      })

      -- The event loads the first one: it must not wait.
      local start = vim.uv.hrtime()
      api.nvim_exec_autocmds('User', { pattern = 'ResonanceWaitByEvent', modeline = false })
      local elapsed = (vim.uv.hrtime() - start) / 1e6
      test.assert_true(elapsed < 300,
        'the event blocked for ' .. math.floor(elapsed) .. ' ms on a spec that also has keys')
      test.assert_eq(ran.event, nil, 'the setup ran while the build was still going')
      vim.wait(3000, function() return ran.event end, 20)
      test.assert_true(ran.event, 'the deferred setup never ran')

      -- The key loads the second one: the user is waiting, so it waits.
      local stub = vim.fn.maparg(lhs_key, 'n', false, true).callback
      test.assert_not_nil(stub, 'the key stub was not mapped')
      start = vim.uv.hrtime()
      stub()
      elapsed = (vim.uv.hrtime() - start) / 1e6
      test.assert_true(ran.key, 'the key returned before the plugin was set up')
      test.assert_true(elapsed >= 400, 'the key did not wait for the build: ' .. math.floor(elapsed) .. ' ms')

      test.assert_eq(builds.status(by_event).state, 'ok')
      test.assert_eq(builds.status(by_key).state, 'ok')
      pcall(vim.keymap.del, 'n', lhs_event)
      pcall(vim.keymap.del, 'n', lhs_key)
      clear_marker(by_event)
      clear_marker(by_key)
    end,
  },

  {
    name = 'build: a command waits for the build of a dependency as well',
    fn = function()
      -- The dependency is loaded on behalf of the user who ran the command.
      -- Its own spec has no command, but the parent's setup runs right
      -- after it and needs it set up.
      reset_builds()
      test.stub_pack()

      local parent, dep = fresh_name('wait-parent'), fresh_name('wait-dep')
      clear_marker(dep)
      local cmd = 'ResonanceWaitParent'
      local order = {}

      _G.resonance.load({
        {
          src = 'https://github.com/test/' .. dep,
          event = { 'User', pattern = 'ResonanceWaitDep' },
          build = 'sleep 0.5',
          setup = function() order[#order + 1] = 'dep' end,
        },
        {
          src = 'https://github.com/test/' .. parent,
          cmd = cmd,
          dependencies = { 'https://github.com/test/' .. dep },
          setup = function()
            order[#order + 1] = 'parent'
            api.nvim_create_user_command(cmd, function() end, {})
          end,
        },
      })

      vim.cmd(cmd)
      test.assert_eq(table.concat(order, ','), 'dep,parent',
        'the dependency was not set up before its parent')
      clear_marker(dep)
    end,
  },

  {
    name = 'build: a failing build does not stop the plugin from being set up',
    fn = function()
      -- A broken build must not leave the plugin unloaded forever. The
      -- setup runs anyway: a plugin with no build artifacts may still be
      -- useful, and the error is reported.
      local builds = reset_builds()
      test.stub_pack()

      local plugin = fresh_name('build-fail')
      clear_marker(plugin)

      local setup_ran = false
      _G.resonance.load({
        src = 'https://github.com/test/' .. plugin,
        cmd = 'ResonanceBuildFail',
        build = function()
          error('the build failed')
        end,
        setup = function() setup_ran = true end,
      })

      -- The failure is reported, not raised: it does not break the load.
      local notices = h.with_capture(function()
        vim.cmd('ResonanceBuildFail')
        vim.wait(2000)
      end)

      test.assert_true(setup_ran, 'the setup never ran after a failed build')
      local status = builds.status(plugin)
      test.assert_not_nil(status, 'the build tracker has no entry for the plugin')
      test.assert_eq(status.state, 'failed')

      clear_marker(plugin)
    end,
  },

  {
    name = 'build: in a multi-plugin spec, every member is set up exactly once',
    fn = function()
      -- The defect: the ready members were set up with run_setups(1..last
      -- ready), and the user-initiated path then ran run_setups(1..n) once
      -- the build was done. Every member before the last ready one was
      -- set up twice -- including the built member, the first time while
      -- its build was still running.
      local builds = reset_builds()
      test.stub_pack()

      local built_name = fresh_name('multi-built')
      local plain_name = fresh_name('multi-plain')
      clear_marker(built_name)

      local built = false
      local count = { built = 0, plain = 0 }
      local built_done_at_first_setup = nil

      _G.resonance.load({
        plugin = {
          {
            src = 'https://github.com/test/' .. built_name,
            build = function() built = true end,
            setup = function()
              count.built = count.built + 1
              if built_done_at_first_setup == nil then
                built_done_at_first_setup = built
              end
            end,
          },
          {
            src = 'https://github.com/test/' .. plain_name,
            setup = function() count.plain = count.plain + 1 end,
          },
        },
        cmd = 'ResonanceBuildMulti',
      })

      vim.cmd('ResonanceBuildMulti')
      vim.wait(2000)

      test.assert_eq(count.built, 1, 'the built member was not set up exactly once')
      test.assert_eq(count.plain, 1, 'the plain member was not set up exactly once')
      test.assert_true(built_done_at_first_setup,
        'the built member was set up before its build had finished')
      test.assert_eq(builds.status(built_name).state, 'ok')

      clear_marker(built_name)
    end,
  },

  {
    name = 'build: a deferred setup waits for every build, not only the last',
    fn = function()
      -- The defect: the deferred setups were hooked to the completion of
      -- the last building member only. Builds finish in any order, so a
      -- fast last build set up a member whose own build was still going.
      local builds = reset_builds()
      test.stub_pack()

      local slow = fresh_name('defer-slow')
      local fast = fresh_name('defer-fast')
      clear_marker(slow)
      clear_marker(fast)

      local count = 0
      local slow_state_at_setup = nil

      _G.resonance.load({
        plugin = {
          {
            src = 'https://github.com/test/' .. slow,
            build = 'sleep 0.8',
            setup = function()
              count = count + 1
              local s = builds.status(slow)
              slow_state_at_setup = s and s.state
            end,
          },
          {
            src = 'https://github.com/test/' .. fast,
            build = 'true',
            setup = function() count = count + 1 end,
          },
        },
        event = { 'User', pattern = 'ResonanceBuildDeferAll' },
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'ResonanceBuildDeferAll' })
      vim.wait(4000, function() return count >= 2 end)
      vim.wait(100)

      test.assert_eq(count, 2, 'the members were not set up exactly once each')
      test.assert_eq(slow_state_at_setup, 'ok',
        'the slow member was set up while its build was still running')

      clear_marker(slow)
      clear_marker(fast)
    end,
  },

  {
    name = 'build: a failed deferred build is reported once',
    fn = function()
      -- The deferred setup reported the failure again, on top of the build's
      -- own report: the same "Build failed" twice.
      reset_builds()
      local stub = test.stub_pack()
      local plugin = fresh_name('build-fail-once')
      clear_marker(plugin)
      local pattern = 'BuildFailOnce' .. tostring(vim.uv.hrtime()):sub(-5)
      _G.resonance.load({
        src = 'https://github.com/test/' .. plugin,
        event = { 'User', pattern = pattern },
        build = function() error('the build failed') end,
        setup = function() end,
      })
      local notices = h.capture_and_wait(function()
        api.nvim_exec_autocmds('User', { pattern = pattern })
      end, 1500)
      local n = 0
      for i = 1, #notices do
        if notices[i]:find('Build failed for ' .. plugin, 1, true) then n = n + 1 end
      end
      clear_marker(plugin)
      test.assert_eq(n, 1, 'the build failure was not reported exactly once: ' .. vim.inspect(notices))
    end,
  },

  {
    name = 'build: a build that already failed is not re-run by the lazy load',
    fn = function()
      -- The load started the same failing build again, and a cmd/keys load
      -- waited up to 30 s for it to fail a second time.
      local builds = reset_builds()
      test.stub_pack()
      local plugin = fresh_name('build-failed-before')
      clear_marker(plugin)
      builds.start(plugin)
      builds.finish(plugin, false, 'failed earlier in this session')
      local calls = 0
      local setup_ran = false
      local cmd = 'BuildFailedBefore' .. tostring(vim.uv.hrtime()):sub(-5)
      _G.resonance.load({
        src = 'https://github.com/test/' .. plugin,
        cmd = cmd,
        build = function() calls = calls + 1 end,
        setup = function() setup_ran = true end,
      })
      local t0 = vim.uv.hrtime()
      h.capture_and_wait(function() pcall(vim.cmd, cmd) end, 300)
      local waited_ms = (vim.uv.hrtime() - t0) / 1e6
      clear_marker(plugin)
      test.assert_eq(calls, 0, 'the failed build was started again by the lazy load')
      test.assert_true(setup_ran, 'the plugin was not set up after its failed build')
      test.assert_true(waited_ms < 2000, 'the load blocked on the failed build: ' .. waited_ms .. ' ms')
    end,
  },

})

test.print_summary()
