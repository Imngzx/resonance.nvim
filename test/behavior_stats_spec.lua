-- stats
--
-- Part of the resonance.nvim behavioral suite.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_stats_spec.lua" -c "lua test.print_summary()" -c "qall"

local h = dofile('test/helpers.lua')
local live = h.live

test.run_suite('resonance.behavior.stats', {

  {
    name = 'stats: the plugin counts follow a plugin that loads after the first call',
    fn = function()
      -- stats() used to cache the whole result table on the first call,
      -- so the counts were frozen for the rest of the session: a plugin
      -- that loaded later was never counted.
      --
      -- The load time is the observable that follows a load: the scanner
      -- records it when the plugin is loaded, and it is read from the
      -- scanner on every stats() call.
      local l = live()
      test.stub_pack()

      local before = l.resonance.stats()
      test.assert_nil(before.times['stats-late-load'],
        'the plugin was already recorded before it loaded')

      l.resonance.load({
        src = 'https://github.com/test/stats-late-load',
        event = { 'User', pattern = 'ResonanceStatsLateLoad' },
        setup = function() end,
      })
      vim.api.nvim_exec_autocmds('User',
        { pattern = 'ResonanceStatsLateLoad', modeline = false })
      vim.wait(300)

      local after = l.resonance.stats()

      test.assert_not_nil(after.times['stats-late-load'],
        'the load time did not follow the plugin that loaded later')
      test.assert_true(after.count >= before.count,
        'the total count went down')
      test.assert_false(before == after,
        'stats() returned the very same cached table')
    end,
  },

  {
    name = 'stats: the startup time is latched on the first call',
    fn = function()
      -- The startup time is a one-shot measurement, so it must not drift
      -- between calls. The counts are live; the time is not.
      local l = live()

      local first = l.resonance.stats()
      vim.wait(50)
      local second = l.resonance.stats()

      test.assert_eq(second.startuptime, first.startuptime,
        'the startup time changed between two calls')
    end,
  },

  {
    name = 'stats: the startup time is latched at UIEnter, not at the first call',
    fn = function()
      -- The UI can be opened long after startup. The measurement is the
      -- time until the UI became usable, so the end is latched when the
      -- UI enters -- not when something first asks for the stats.
      local l = live()
      l.resonance._end_time = nil

      -- Latch the end the way the VeryLazy fire does.
      l.resonance._end_time = vim.uv.hrtime()
      vim.wait(50)
      local latched = l.resonance.stats().startuptime

      -- A later call must report the same time, not a later one.
      vim.wait(50)
      test.assert_eq(l.resonance.stats().startuptime, latched,
        'the startup time drifted after the end was latched')
    end,
  },

  {
    name = 'stats: _reset clears the latched startup time',
    fn = function()
      -- The test runner resets the module between tests. Without a
      -- _reset(), the latched end time leaked from one test into the
      -- next.
      local l = live()

      l.resonance._end_time = vim.uv.hrtime()
      local latched = l.resonance.stats().startuptime

      l.resonance._reset()
      test.assert_nil(l.resonance._end_time,
        '_reset did not clear the latched end time')

      local after = l.resonance.stats().startuptime
      test.assert_true(after >= latched,
        'the startup time went backwards after a reset')
    end,
  },
})

test.print_summary()
