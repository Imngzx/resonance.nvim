-- replay
--
-- Part of the resonance.nvim behavioral suite. Split out of the former
-- behavior_spec.lua to keep each file focused.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_replay_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local live = h.live
local with_capture = h.with_capture
local capture_and_wait = h.capture_and_wait
local noticed = h.noticed
local scratch_group = h.scratch_group
local recorder = h.recorder
local count = h.count
local make_git_repo = h.make_git_repo

test.run_suite('resonance.behavior.replay', {

  {
    name = 'replay: a trigger registered after the event already fired still loads',
    fn = function()
      -- The regression: a plugin whose trigger is registered AFTER the
      -- event it listens for already fired must still get its chance to
      -- load. This is the `nvim <file>` / open-from-yazi path: BufReadPost
      -- and BufEnter fire before UIEnter -> VeryLazy, and the UI plugins
      -- (heirline, bpm, treesitter, lsp, ...) register their triggers in
      -- VeryLazy, after the event is already behind them.
      --
      -- The fired-event state is tracked per buffer, so the replay used to
      -- skip the event entirely and the plugin never loaded: no statusline,
      -- no bufferline, no breadcrumb.
      test.stub_pack()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local setup_ran = false

      -- The buffer must name a file that exists on disk: replay_for_buffer
      -- treats a named-but-missing buffer as a new file and fires
      -- BufNewFile, which would let the trigger load for the wrong reason.
      local file = vim.fn.tempname()
      vim.fn.writefile({ 'x' }, file)
      api.nvim_buf_set_name(buf, file)

      -- The read events happen FIRST, before the trigger exists.
      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
      api.nvim_exec_autocmds('BufEnter', { buffer = buf, modeline = false })

      -- The plugin registers its trigger NOW, after those events fired.
      _G.resonance.load({
        src = 'https://github.com/test/replay-late-trigger',
        event = { 'BufReadPost', 'BufNewFile', 'BufEnter' },
        setup = function() setup_ran = true end,
      })

      -- The replay must give the late-registered trigger its chance.
      local replayed = _G.resonance.replay_for_buffer(buf)
      vim.wait(200)

      test.assert_true(setup_ran,
        'the late-registered trigger never fired: the replay returned [' ..
        table.concat(replayed, ',') .. ']')
    end,
  },

  {
    name = 'replay: a BufEnter-only trigger loads for a file that exists on disk',
    fn = function()
      -- BufEnter fires for EVERY buffer, not only new ones. The replay
      -- picked its events from whether the buffer is a file on disk and
      -- put BufEnter in the "not a file" branch, so a BufEnter-only
      -- trigger group was never replayed for an existing file -- the
      -- plugin silently never loaded.
      test.stub_pack()
      local buf = api.nvim_create_buf(false, true)
      local setup_ran = false

      -- The buffer must name a file that exists on disk. That is the case
      -- that used to skip BufEnter.
      local file = vim.fn.tempname()
      vim.fn.writefile({ 'x' }, file)
      api.nvim_buf_set_name(buf, file)

      -- The read events happen FIRST, before the trigger exists.
      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
      api.nvim_exec_autocmds('BufEnter', { buffer = buf, modeline = false })

      -- The plugin registers its BufEnter-only trigger NOW.
      _G.resonance.load({
        src = 'https://github.com/test/replay-bufenter-only',
        event = 'BufEnter',
        setup = function() setup_ran = true end,
      })

      local replayed = _G.resonance.replay_for_buffer(buf)
      vim.wait(200)

      test.assert_true(setup_ran,
        'the BufEnter-only trigger never fired: the replay returned [' ..
        table.concat(replayed, ',') .. ']')
    end,
  },

  {
    name = 'replay: the triggering event handler runs exactly once',
    fn = function()
      test.stub_pack()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local seen = recorder('BufReadPre', { group_name = 'ResonanceReplayOnce', buffer = buf })
      local setup_ran = false

      _G.resonance.load({
        src = 'https://github.com/test/replay-once',
        event = 'BufReadPre',
        setup = function() setup_ran = true end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(100)

      -- The install must have succeeded, or the load aborted before the
      -- replay block and this assertion would pass without testing it.
      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      test.assert_eq(count(seen), 1)
    end,
  },

  {
    name = 'replay: a successor event that has not fired yet is not replayed',
    fn = function()
      test.stub_pack()
      local l = live()
      local seen = recorder('BufReadPost', { group_name = 'ResonanceReplayPending' })
      local setup_ran = false

      _G.resonance.load({
        src = 'https://github.com/test/replay-pending',
        event = 'BufReadPre',
        setup = function() setup_ran = true end,
      })

      api.nvim_exec_autocmds('BufReadPre', { modeline = false })
      vim.wait(100)

      -- Without a successful install the load aborts before the replay
      -- block, and this assertion would pass without testing anything.
      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      -- BufReadPost is still to come for this read; firing it now would run
      -- the handler twice for a single read.
      test.assert_eq(count(seen), 0)
    end,
  },

  {
    name = 'replay: a successor event that already fired for this buffer is replayed once',
    fn = function()
      test.stub_pack()
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
      test.stub_pack()
      local l = live()
      local buf_a = api.nvim_create_buf(false, true)
      local buf_b = api.nvim_create_buf(false, true)

      local seen_a = recorder('BufReadPost', { group_name = 'ResonanceReplayBufA', buffer = buf_a })
      local seen_b = recorder('BufReadPost', { group_name = 'ResonanceReplayBufB', buffer = buf_b })
      local setup_ran = false

      -- Buffer A's read already happened.
      api.nvim_exec_autocmds('BufReadPost', { buffer = buf_a, modeline = false })
      test.assert_eq(count(seen_a), 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-two-buffers',
        event = 'BufNewFile',
        setup = function() setup_ran = true end,
      })

      -- Buffer B is a different buffer, so A's state must not apply to it.
      api.nvim_exec_autocmds('BufNewFile', { buffer = buf_b, modeline = false })
      vim.wait(100)

      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      test.assert_eq(count(seen_a), 1)
      test.assert_eq(count(seen_b), 0)
    end,
  },

  {
    name = 'replay: nested triggers do not recurse without bound',
    fn = function()
      test.stub_pack()
      local l = live()
      local buf = api.nvim_create_buf(false, true)
      local depth = 0
      local max_depth = 0
      local setup_ran = false

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
        setup = function() setup_ran = true end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(200)

      -- Without a successful install the load aborts before the replay
      -- block, and the depth bound is never exercised.
      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      -- The loader must not stack replays on top of each other. The handler
      -- above recurses on its own, so the bound is on the loader's own
      -- contribution, which shows up as an unbounded depth here.
      test.assert_true(max_depth <= 40, 'nesting depth exceeded the bound: ' .. max_depth)
    end,
  },
})

test.print_summary()
