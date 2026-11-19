-- gc
--
-- Memory regressions: state that should be released after a cycle and is
-- not. Each test repeats a cycle many times, collects, and checks what is
-- left. A leak shows up as growth proportional to the cycle count, which a
-- fixed bound catches while normal allocator noise does not.
--
-- The signals, most exact first:
--   - Direct counts where the state is observable: windows, buffers,
--     autocmds, and the per-buffer keys of the loader's fired state.
--   - Live Lua registry refs. Every Lua callback handed to Neovim (an
--     autocmd, a keymap, a user command) holds one, so a callback that is
--     never released shows up here exactly. This is the deterministic one.
--   - Lua heap growth after a full collect. Noisier, so the bounds are set
--     well above the clean value and well below what a leak produces. Not
--     used where Neovim's own runtime retains more than the state under
--     test (buffer churn, see that test).
--
-- Run with: test/dev_env.sh test test/gc_spec.lua

local api = vim.api
local h = dofile('test/helpers.lua')
local live = h.live

local function full_collect()
  collectgarbage('collect')
  collectgarbage('collect')
end

local function heap_kb()
  full_collect()
  return collectgarbage('count')
end

-- The number of live refs in the Lua registry.
--
-- luaL_unref leaves the free-list link (a number) in a released slot, so
-- counting every entry would never go down. Only non-number values are refs
-- that are still held.
local function live_refs()
  local n = 0
  for _, v in pairs(debug.getregistry()) do
    if type(v) ~= 'number' then n = n + 1 end
  end
  return n
end

-- Run `fn` `n` times, letting the event loop run between iterations.
--
-- The panel renders through vim.schedule and loads its details through
-- vim.defer_fn. A tight loop never yields, so those callbacks pile up
-- unrun and look exactly like a leak. Draining the loop measures the
-- steady state a user actually gets.
local function cycle(n, fn, wait_ms)
  for _ = 1, n do
    fn()
    vim.wait(wait_ms or 0)
  end
end

-- Measure what `n` cycles leave behind, after a warm-up that fills the
-- caches and interns the strings a first run allocates once.
local function retained(n, fn, wait_ms)
  cycle(20, fn, wait_ms)
  local kb0, refs0 = heap_kb(), live_refs()
  cycle(n, fn, wait_ms)
  return heap_kb() - kb0, live_refs() - refs0
end

test.run_suite('resonance.gc', {

  {
    name = 'gc: opening and closing the panel releases its buffer, window and callbacks',
    fn = function()
      -- Each open creates a scratch buffer with a dozen keymap callbacks
      -- and a BufWipeout autocmd. They are released only when the buffer
      -- is wiped; a panel buffer that survives its window keeps all of
      -- them alive for the rest of the session.
      local r = live().resonance
      local function open_close()
        r.open_ui()
        local win = require('resonance.ui.state').state.win
        test.assert_not_nil(win, 'the panel did not open a window')
        api.nvim_win_close(win, true)
      end

      -- Neovim's own matchparen registers a `once` SafeState autocmd on
      -- every BufWinEnter. Headless Neovim never reaches SafeState, so those
      -- pile up at one ref per opened window -- with or without Resonance.
      -- Switch it off for the measurement so only the panel's refs count.
      local matchparen = vim.fn.exists(':NoMatchParen') == 2
      if matchparen then vim.cmd('NoMatchParen') end

      cycle(5, open_close, 5)
      local bufs0, wins0 = #api.nvim_list_bufs(), #api.nvim_list_wins()
      local kb, refs = retained(200, open_close, 5)

      if matchparen then vim.cmd('DoMatchParen') end

      test.assert_eq(#api.nvim_list_bufs(), bufs0, 'panel buffers accumulate across open/close')
      test.assert_eq(#api.nvim_list_wins(), wins0, 'panel windows accumulate across open/close')
      test.assert_true(refs <= 0,
        ('200 open/close cycles left %d Lua callback refs alive'):format(refs))
      -- Measured clean: 30-45 KB, allocator noise that does not scale with
      -- the cycle count. The exact checks above catch a retained panel; this
      -- bound catches state retained elsewhere (render buffers, UI state).
      test.assert_true(kb < 256,
        ('200 open/close cycles retained %.1f KB'):format(kb))
    end,
  },

  {
    name = 'gc: the fired state of a wiped buffer is released',
    fn = function()
      -- The tracker records every read event per buffer id, and the replay
      -- bookkeeping records every group per buffer id. Buffer ids are never
      -- reused, so without the BufWipeout prune each buffer a session ever
      -- opened stays in both tables.
      local loader = live().loader
      loader.setup()
      local fired_events = loader._internal.fired_events
      local fired_groups = loader._internal.fired_groups
      local events = { 'BufReadPre', 'BufReadPost', 'BufEnter', 'FileType' }
      local function fire_all(buf)
        for i = 1, #events do
          api.nvim_exec_autocmds(events[i], { buffer = buf, modeline = false })
        end
      end

      -- Guard against a vacuous pass: a live buffer must be recorded in
      -- both tables, or "nothing left behind" proves nothing.
      local kept = api.nvim_create_buf(true, false)
      fire_all(kept)
      test.assert_not_nil(fired_events[kept], 'the tracker did not record the events of a live buffer')
      test.assert_not_nil(fired_groups[kept], 'the tracker did not record the groups of a live buffer')

      -- Counted by key rather than by heap: Neovim's own runtime retains
      -- more per created buffer than these tables do, so a heap bound could
      -- not tell a missing prune from the editor's noise.
      local wiped = {}
      for i = 1, 2000 do
        local buf = api.nvim_create_buf(true, false)
        fire_all(buf)
        api.nvim_buf_delete(buf, { force = true })
        wiped[i] = buf
      end

      local left_events, left_groups = 0, 0
      for i = 1, #wiped do
        if fired_events[wiped[i]] then left_events = left_events + 1 end
        if fired_groups[wiped[i]] then left_groups = left_groups + 1 end
      end
      api.nvim_buf_delete(kept, { force = true })

      test.assert_eq(left_events, 0, 'wiped buffers left behind in the fired-events table')
      test.assert_eq(left_groups, 0, 'wiped buffers left behind in the fired-groups table')
    end,
  },

  {
    name = 'gc: stats() does not retain anything between calls',
    fn = function()
      -- stats() rebuilds the scanner's plugin arrays on every call. They
      -- are temporaries: a dashboard that calls it on every redraw must
      -- not grow the heap.
      local r = live().resonance
      local kb, refs = retained(1000, function() r.stats() end)

      test.assert_true(refs <= 0,
        ('1000 stats() calls left %d Lua callback refs alive'):format(refs))
      -- Measured clean: 7-20 KB. Retaining the result of each call: about
      -- 1600 KB, even with the handful of fixture plugins.
      test.assert_true(kb < 128,
        ('1000 stats() calls retained %.1f KB'):format(kb))
    end,
  },

  {
    name = 'gc: a late group is replayed once, and repeated replays retain nothing',
    fn = function()
      -- The replay marks each group it fires, so the next replay of the
      -- same buffer skips it. Without the mark, every replay runs every
      -- late group again: a handler meant to run once per read runs once
      -- per replay call.
      local l = live()
      l.loader.setup()
      local buf = api.nvim_create_buf(true, false)
      api.nvim_buf_set_name(buf, vim.fn.tempname() .. '-gc-replay.txt')
      api.nvim_set_current_buf(buf)
      api.nvim_exec_autocmds('BufEnter', { buffer = buf, modeline = false })

      -- Registered after the buffer's BufEnter: it has not seen it, so the
      -- replay owes it exactly one run.
      local runs = 0
      local group = api.nvim_create_augroup('ResonanceGcLateGroup', { clear = true })
      api.nvim_create_autocmd('BufEnter', {
        group = group,
        buffer = buf,
        callback = function() runs = runs + 1 end,
      })

      local kb = retained(2000, function() l.loader.replay_for_buffer(buf) end)

      api.nvim_del_augroup_by_id(group)
      api.nvim_buf_delete(buf, { force = true })

      test.assert_eq(runs, 1, 'the late group was not replayed exactly once across 2020 replays')
      -- Measured clean: 2-13 KB. The replay builds its results in
      -- temporaries.
      test.assert_true(kb < 128,
        ('2000 replays retained %.1f KB'):format(kb))
    end,
  },

  {
    name = 'gc: loading a plugin releases all of its trigger stubs',
    fn = function()
      -- A spec with several triggers registers one stub per trigger in its
      -- Resonance_<plugin> group. The first one to fire loads the plugin;
      -- its siblings have done their job and must go with the group, or
      -- their callbacks stay alive (and keep firing) for the session.
      test.stub_pack()
      local l = live()
      local n = 0
      local function load_and_fire()
        n = n + 1
        local name = 'gc-trigger-' .. n
        l.resonance.load({
          src = 'https://github.com/test/' .. name,
          event = { 'User', pattern = 'ResonanceGc' .. n },
          ft = { 'gcft' .. n },
          setup = function() end,
        })
        api.nvim_exec_autocmds('User', { pattern = 'ResonanceGc' .. n, modeline = false })
      end

      local _, refs = retained(100, load_and_fire)

      local group_name = require('resonance.loader.triggers').trigger_group_name('gc-trigger-' .. n)
      local ok, left = pcall(api.nvim_get_autocmds, { group = group_name })
      test.assert_true(not ok or #left == 0,
        'the trigger group still holds ' .. (ok and #left or 0) .. ' stub(s) after the load')
      -- Each spec here registers two stubs, so a group that is not torn
      -- down leaves at least one callback per spec: 100 or more.
      test.assert_true(refs < 20,
        ('100 loaded specs left %d Lua callback refs alive'):format(refs))
    end,
  },

})
