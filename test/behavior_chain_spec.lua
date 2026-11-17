-- chain
--
-- Part of the resonance.nvim behavioral suite. Split out of the former
-- behavior_spec.lua to keep each file focused.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_chain_spec.lua" -c "lua test.print_summary()" -c "qall"

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

test.run_suite('resonance.behavior.chain', {
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
})

test.print_summary()
