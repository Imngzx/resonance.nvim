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

})

test.print_summary()
