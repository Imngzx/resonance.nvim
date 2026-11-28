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
      api.nvim_exec_autocmds('BufReadPre', { buf = buf, modeline = false })
      api.nvim_exec_autocmds('BufReadPost', { buf = buf, modeline = false })
      api.nvim_exec_autocmds('BufEnter', { buf = buf, modeline = false })

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
      api.nvim_exec_autocmds('BufReadPre', { buf = buf, modeline = false })
      api.nvim_exec_autocmds('BufReadPost', { buf = buf, modeline = false })
      api.nvim_exec_autocmds('BufEnter', { buf = buf, modeline = false })

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
      local seen = recorder('BufReadPre', { group_name = 'ResonanceReplayOnce', buf = buf })
      local setup_ran = false

      _G.resonance.load({
        src = 'https://github.com/test/replay-once',
        event = 'BufReadPre',
        setup = function() setup_ran = true end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buf = buf, modeline = false })
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
    name = 'replay: a handler that already ran for the buffer is not run again by a later load',
    fn = function()
      -- The replay used to fire every group on a successor event that had
      -- already run for the buffer, so loading one plugin re-ran every
      -- other plugin's BufReadPost handler: an `:e!` ran them twice.
      test.stub_pack()
      local buf = api.nvim_create_buf(false, true)
      local seen = recorder('BufReadPost', { group_name = 'ResonanceReplayFired', buf = buf })
      local setup_ran = false

      api.nvim_exec_autocmds('BufReadPost', { buf = buf, modeline = false })
      test.assert_eq(count(seen), 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-fired',
        event = 'FileType',
        setup = function() setup_ran = true end,
      })

      -- A FileType load replays BufReadPost, which already ran here.
      api.nvim_exec_autocmds('FileType', { buf = buf, modeline = false })
      vim.wait(100)

      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      test.assert_eq(count(seen), 1, 'a handler that already ran was run again')
    end,
  },

  {
    name = 'replay: a plugin loaded on FileType sees the read that loaded it',
    fn = function()
      -- Neovim does not run an autocmd added while its event is firing, so
      -- the handlers a plugin registers in setup() missed the very event
      -- that loaded it: a FileType plugin did not attach to the first file
      -- until it was reopened.
      --
      -- BufReadPost is still running when FileType fires (filetype
      -- detection is a BufReadPost handler), so it has to be replayed too.
      test.stub_pack()
      local file = vim.fn.tempname() .. '.lua'
      vim.fn.writefile({ 'x = 1' }, file)
      local hits = {}

      _G.resonance.load({
        src = 'https://github.com/test/replay-own-filetype',
        event = { 'FileType', pattern = 'lua' },
        setup = function()
          local group = scratch_group('ResonanceReplayOwnFt')
          api.nvim_create_autocmd('FileType', {
            group = group, pattern = 'lua',
            callback = function(a) hits[#hits + 1] = 'FileType ' .. a.buf end,
          })
          api.nvim_create_autocmd('BufReadPost', {
            group = group,
            callback = function(a) hits[#hits + 1] = 'BufReadPost ' .. a.buf end,
          })
        end,
      })

      vim.cmd.edit(file)
      local buf = api.nvim_get_current_buf()
      vim.wait(100)
      vim.cmd('bwipeout!')

      test.assert_true(vim.deep_equal(hits, { 'BufReadPost ' .. buf, 'FileType ' .. buf }),
        'the plugin\'s own handlers saw ' .. vim.inspect(hits))
    end,
  },

  {
    name = 'replay: a plugin loaded on ft sees the FileType that loaded it',
    fn = function()
      test.stub_pack()
      local file = vim.fn.tempname() .. '.lua'
      vim.fn.writefile({ 'x = 1' }, file)
      local hits = 0

      _G.resonance.load({
        src = 'https://github.com/test/replay-own-ft',
        ft = 'lua',
        setup = function()
          api.nvim_create_autocmd('FileType', {
            group = scratch_group('ResonanceReplayOwnFtKey'), pattern = 'lua',
            callback = function() hits = hits + 1 end,
          })
        end,
      })

      vim.cmd.edit(file)
      vim.wait(100)
      vim.cmd('bwipeout!')

      test.assert_eq(hits, 1, 'the plugin\'s FileType handler ran ' .. hits .. ' times')
    end,
  },

  {
    name = 'replay: a plugin loaded on a User event sees the event that loaded it',
    fn = function()
      -- A User event is matched by pattern, not by buffer: firing it for a
      -- buffer would never reach a `User Foo` handler.
      test.stub_pack()
      local hits = 0

      _G.resonance.load({
        src = 'https://github.com/test/replay-own-user',
        event = { 'User', pattern = 'ResonanceReplayOwnUser' },
        setup = function()
          api.nvim_create_autocmd('User', {
            group = scratch_group('ResonanceReplayOwnUserGroup'),
            pattern = 'ResonanceReplayOwnUser',
            callback = function() hits = hits + 1 end,
          })
        end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceReplayOwnUser', modeline = false })
      vim.wait(100)

      test.assert_eq(hits, 1, 'the plugin\'s User handler ran ' .. hits .. ' times')
    end,
  },

  {
    name = 'replay: a plugin loaded on BufReadPre does not get the rest of the read twice',
    fn = function()
      -- BufReadPost and FileType are still to come when BufReadPre loads
      -- the plugin. They reach its handlers naturally, so replaying them
      -- as well would run each one twice.
      test.stub_pack()
      local file = vim.fn.tempname() .. '.lua'
      vim.fn.writefile({ 'x = 1' }, file)
      local hits = {}

      _G.resonance.load({
        src = 'https://github.com/test/replay-own-pre',
        event = 'BufReadPre',
        setup = function()
          local group = scratch_group('ResonanceReplayOwnPre')
          api.nvim_create_autocmd('BufReadPost', {
            group = group, callback = function() hits[#hits + 1] = 'BufReadPost' end,
          })
          api.nvim_create_autocmd('FileType', {
            group = group, pattern = 'lua', callback = function() hits[#hits + 1] = 'FileType' end,
          })
        end,
      })

      vim.cmd.edit(file)
      vim.wait(100)
      vim.cmd('bwipeout!')

      -- Each exactly once. The order is Neovim's own: filetype detection
      -- is a BufReadPost handler that runs before the plugin's.
      table.sort(hits)
      test.assert_true(vim.deep_equal(hits, { 'BufReadPost', 'FileType' }),
        'the plugin\'s handlers saw ' .. vim.inspect(hits))
    end,
  },

  {
    name = 'replay: a read on one buffer does not replay another buffer',
    fn = function()
      test.stub_pack()
      local l = live()
      local buf_a = api.nvim_create_buf(false, true)
      local buf_b = api.nvim_create_buf(false, true)

      local seen_a = recorder('BufReadPost', { group_name = 'ResonanceReplayBufA', buf = buf_a })
      local seen_b = recorder('BufReadPost', { group_name = 'ResonanceReplayBufB', buf = buf_b })
      local setup_ran = false

      -- Buffer A's read already happened.
      api.nvim_exec_autocmds('BufReadPost', { buf = buf_a, modeline = false })
      test.assert_eq(count(seen_a), 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-two-buffers',
        event = 'BufNewFile',
        setup = function() setup_ran = true end,
      })

      -- Buffer B is a different buffer, so A's state must not apply to it.
      api.nvim_exec_autocmds('BufNewFile', { buf = buf_b, modeline = false })
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
        buf = buf,
        nested = true,
        callback = function()
          depth = depth + 1
          if depth > max_depth then max_depth = depth end
          -- Re-enter the read pipeline, the way a picker opening a file does.
          if depth < 40 then
            pcall(function() api.nvim_exec_autocmds('BufReadPre', { buf = buf, modeline = false }) end)
          end
        end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-depth',
        event = 'BufReadPre',
        setup = function() setup_ran = true end,
      })

      api.nvim_exec_autocmds('BufReadPre', { buf = buf, modeline = false })
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
