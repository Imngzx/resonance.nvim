-- Tests for resonance.loader.init (main loader)
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/loader_spec.lua" -c "lua test.print_summary()" -c "qall"

local loader = require('resonance.loader')
local utils = require('resonance.utils')

test.run_suite('resonance.loader.init', {

  {
    name = 'get_plugin_dir: returns path for installed plugin',
    fn = function()
      local dir = loader.get_plugin_dir('resonance.nvim')
      test.assert_not_nil(dir)
      test.assert_true(type(dir) == 'string')
      test.assert_true(dir:match('resonance.nvim'))
    end,
  },

  {
    name = 'get_plugin_dir: returns nil for non-existent plugin',
    fn = function()
      local dir = loader.get_plugin_dir('nonexistent-plugin-xyz')
      test.assert_nil(dir)
    end,
  },

  {
    name = 'get_plugin_dir: fallback scan resolves real plugin dirs',
    fn = function()
      -- vim.pack is lazily rehydrated by the vim metatable, so nil it out via
      -- rawset to actually exercise the filesystem fallback.
      local orig_pack = rawget(vim, 'pack')
      rawset(vim, 'pack', nil)
      loader._reset()
      package.loaded['resonance.loader'] = nil
      local fallback_loader = require('resonance.loader')

      local dir = fallback_loader.get_plugin_dir('resonance.nvim')
      test.assert_not_nil(dir)
      -- The resolved path must point at the plugin itself, not a pack segment.
      test.assert_not_eq(dir:match('/opt$'), '/opt')
      test.assert_not_eq(dir:match('/start$'), '/start')
      test.assert_true(dir:match('/opt/resonance%.nvim$') ~= nil)
      test.assert_true(vim.uv.fs_stat(dir) ~= nil)

      rawset(vim, 'pack', orig_pack)
      loader._reset()
      package.loaded['resonance.loader'] = nil
    end,
  },

  {
    name = 'plugin_triggers: table exists',
    fn = function()
      test.assert_not_nil(loader.plugin_triggers)
      test.assert_eq(type(loader.plugin_triggers), 'table')
    end,
  },

  {
    name = 'specs: table exists',
    fn = function()
      test.assert_not_nil(loader.specs)
      test.assert_eq(type(loader.specs), 'table')
    end,
  },

  {
    name = 'build_hooks: table exists',
    fn = function()
      test.assert_not_nil(loader.build_hooks)
      test.assert_eq(type(loader.build_hooks), 'table')
    end,
  },

  {
    name = 'get_dag_data: returns nodes and edges',
    fn = function()
      local nodes, edges = loader.get_dag_data()
      test.assert_not_nil(nodes)
      test.assert_not_nil(edges)
      test.assert_eq(type(nodes), 'table')
      test.assert_eq(type(edges), 'table')
    end,
  },

  {
    name = 'get_replay_info: returns replay info',
    fn = function()
      local info = loader.get_replay_info()
      test.assert_not_nil(info)
      test.assert_eq(type(info), 'table')
    end,
  },

  {
    name = '_get_event_chain_internal: returns chain for event',
    fn = function()
      local chain = loader._get_event_chain_internal('BufReadPre', 0, {})
      test.assert_not_nil(chain)
      test.assert_eq(type(chain), 'table')
    end,
  },

  {
    name = '_get_event_chain_internal: BufReadPre chain advances through BufReadPost',
    fn = function()
      -- Register global autocmds on the BufReadPre -> BufRead -> BufReadPost path.
      local group = vim.api.nvim_create_augroup('ResonanceChainTest', { clear = true })
      vim.api.nvim_create_autocmd('BufReadPre', { group = group, callback = function() end })
      vim.api.nvim_create_autocmd('BufRead', { group = group, callback = function() end })
      vim.api.nvim_create_autocmd('BufReadPost', { group = group, callback = function() end })

      -- A real buffer is passed, as it is when a trigger autocmd fires.
      local buf = vim.api.nvim_create_buf(false, true)
      local live_loader = require('resonance.loader')
      local chain = live_loader._get_event_chain_internal('BufReadPre', buf, {})

      local events = {}
      for i = 1, #chain do
        events[#events + 1] = chain[i].event
      end

      -- BufRead and BufReadPost are aliases in Neovim: one autocmd registered
      -- for either fires for both, and get_autocmds matches them together.
      -- The chain therefore canonicalises to BufReadPost and must not list the
      -- alias twice, which would replay the same handlers twice.
      test.assert_eq(events[1], 'BufReadPre')
      test.assert_eq(events[2], 'BufReadPost')
      test.assert_eq(#events, 2)
    end,
  },

  {
    name = '_get_event_chain_internal: chain stops at a non-buffer event',
    fn = function()
      local group = vim.api.nvim_create_augroup('ResonanceChainStopTest', { clear = true })
      vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'ResonanceChainStop',
        callback = function() end,
      })

      local buf = vim.api.nvim_create_buf(false, true)
      local live_loader = require('resonance.loader')
      local chain = live_loader._get_event_chain_internal('User', buf, {})

      -- 'User' has no successor, so the chain must contain exactly one entry.
      test.assert_eq(#chain, 1)
      test.assert_eq(chain[1].event, 'User')
    end,
  },

  {
    name = '_get_event_chain_internal: chain does not repeat an event',
    fn = function()
      local group = vim.api.nvim_create_augroup('ResonanceChainCycleTest', { clear = true })
      vim.api.nvim_create_autocmd('BufRead', { group = group, callback = function() end })

      local buf = vim.api.nvim_create_buf(false, true)
      local live_loader = require('resonance.loader')
      local chain = live_loader._get_event_chain_internal('BufRead', buf, {})

      local seen = {}
      for i = 1, #chain do
        test.assert_nil(seen[chain[i].event])
        seen[chain[i].event] = true
      end
    end,
  },

  {
    name = 'fired state: the buffer is forgotten when it is wiped',
    fn = function()
      -- fired_events[buf] and fired_groups[buf] are keyed by buffer id.
      -- Without pruning, every buffer a user ever opened stayed in those
      -- tables for the whole session.
      local api = vim.api
      local buf = api.nvim_create_buf(false, true)
      api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      api.nvim_exec_autocmds('BufEnter', { buffer = buf, modeline = false })

      local live_loader = require('resonance.loader')
      test.assert_true(live_loader.has_fired('BufReadPre', buf),
        'the event was not recorded for the buffer')

      api.nvim_buf_delete(buf, { force = true })
      vim.wait(100)

      test.assert_false(live_loader.has_fired('BufReadPre', buf),
        'the fired state still holds the wiped buffer')
    end,
  },

  {
    name = 'the setup closure is not retained after the plugin loads',
    fn = function()
      -- The loader keeps a spec per plugin for the whole session. If that
      -- copy carried the setup closure, everything the closure captured
      -- stayed reachable for as long as Neovim ran.
      local live_loader = require('resonance.loader')
      local packs = vim.pack.get(nil, { offline = true, info = false })
      if not packs or not packs[1] then return end

      local target = packs[1].spec.name
      local config = {
        plugin = target,
        setup = function() end,
      }
      live_loader.load(config)
      vim.wait(300)

      local retained = live_loader.specs[target]
      test.assert_not_nil(retained, 'the spec was not retained')
      test.assert_nil(retained.setup, 'the retained spec still holds the setup closure')
      test.assert_nil(retained.config, 'the retained spec still holds the config closure')
      -- The user's own table must not be mutated by the loader.
      test.assert_not_nil(config.setup, "the loader cleared the user's setup field")
    end,
  },
})

test.print_summary()