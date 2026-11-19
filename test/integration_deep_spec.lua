-- Deep integration tests for resonance.loader
-- Tests actual plugin loading behavior, not just spec parsing
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/integration_deep_spec.lua" -c "lua test.print_summary()" -c "qall"

test.run_suite('resonance.loader.deep', {

  {
    name = 'lazy load: event trigger fires and loads plugin',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/event-plugin',
        event = { 'User', pattern = 'TestEvent' },
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- Fire the event
      vim.api.nvim_exec_autocmds('User', { pattern = 'TestEvent', modeline = false })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'replay: does not re-fire the event that triggered the load',
    fn = function()
      -- A buffer-scoped autocmd, like the ones that make the event chain
      -- non-empty. Replaying this event would re-run the very autocmd the
      -- loader is running inside, recursing until Neovim raises E218.
      test.stub_pack()
      local buf = vim.api.nvim_create_buf(false, true)
      local group = vim.api.nvim_create_augroup('ResonanceReplayTest', { clear = true })
      local fired = 0
      local setup_ran = false
      vim.api.nvim_create_autocmd('BufReadPre', {
        group = group,
        buffer = buf,
        callback = function() fired = fired + 1 end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-origin',
        event = 'BufReadPre',
        setup = function() setup_ran = true end,
      })

      vim.api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
      vim.wait(100)

      -- Without a successful install the load aborts before the replay
      -- block, and this assertion would pass without testing anything.
      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      -- The origin event must fire exactly once: the original, no replay.
      test.assert_eq(fired, 1)
    end,
  },

  {
    name = 'replay: tracks fired events per buffer, not globally',
    fn = function()
      -- A read that happened for one buffer must not suppress the events
      -- still pending for another buffer, and must not cause the first
      -- buffer's handlers to run again.
      test.stub_pack()
      local group = vim.api.nvim_create_augroup('ResonanceReplayPerBuf', { clear = true })
      local counts = {}
      local setup_ran = false
      vim.api.nvim_create_autocmd('BufReadPost', {
        group = group,
        callback = function(args) counts[args.buf] = (counts[args.buf] or 0) + 1 end,
      })

      -- Buffer A: its read already happened.
      local buf_a = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_exec_autocmds('BufReadPost', { buffer = buf_a, modeline = false })
      test.assert_eq(counts[buf_a], 1)

      _G.resonance.load({
        src = 'https://github.com/test/replay-perbuf',
        event = 'BufNewFile',
        setup = function() setup_ran = true end,
      })

      -- Buffer B: a brand new file, its read has not happened yet.
      local buf_b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_exec_autocmds('BufNewFile', { buffer = buf_b, modeline = false })
      vim.wait(100)

      -- Without a successful install the load aborts before the replay
      -- block, and this assertion would pass without testing anything.
      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      -- Buffer A must not be replayed, and buffer B must not be replayed
      -- early: its read event is still pending and will fire naturally.
      test.assert_eq(counts[buf_a], 1)
      test.assert_eq(counts[buf_b] or 0, 0)
    end,
  },

  {
    name = 'replay: does not fire events that have not happened yet',
    fn = function()
      -- BufRead and BufReadPost are still to come for the current read.
      -- Firing them from the replay would run them twice, and a handler that
      -- opens a file would recurse until Neovim raises E218.
      test.stub_pack()
      local group = vim.api.nvim_create_augroup('ResonanceReplayPending', { clear = true })
      local read_count, post_count = 0, 0
      local setup_ran = false
      vim.api.nvim_create_autocmd('BufRead', {
        group = group,
        callback = function() read_count = read_count + 1 end,
      })
      vim.api.nvim_create_autocmd('BufReadPost', {
        group = group,
        callback = function() post_count = post_count + 1 end,
      })

      _G.resonance.load({
        src = 'https://github.com/test/replay-pending',
        event = 'BufReadPre',
        setup = function() setup_ran = true end,
      })

      vim.api.nvim_exec_autocmds('BufReadPre', { modeline = false })
      vim.wait(100)

      -- Without a successful install the load aborts before the replay
      -- block, and this assertion would pass without testing anything.
      test.assert_true(setup_ran, 'the plugin never loaded: the replay block was never reached')
      -- Neither successor event may be replayed.
      test.assert_eq(read_count, 0)
      test.assert_eq(post_count, 0)
    end,
  },

  {
    name = 'replay: a plugin\'s own BufRead handler is replayed once, others are not',
    fn = function()
      test.stub_pack()
      -- BufRead and BufReadPost are aliases in Neovim, so a handler registered
      -- for either runs for both. A plugin loaded on FileType has the read
      -- already behind it: its own BufRead handler gets the read exactly
      -- once, and a handler that already saw the read does not see it again.
      local group = vim.api.nvim_create_augroup('ResonanceReplayFired', { clear = true })
      local read_count = 0
      vim.api.nvim_create_autocmd('BufRead', {
        group = group,
        callback = function() read_count = read_count + 1 end,
      })

      -- Mark the read event as already fired.
      vim.api.nvim_exec_autocmds('BufRead', { modeline = false })
      test.assert_eq(read_count, 1)

      local own_count = 0
      _G.resonance.load({
        src = 'https://github.com/test/replay-fired',
        event = 'FileType',
        setup = function()
          vim.api.nvim_create_autocmd('BufRead', {
            group = vim.api.nvim_create_augroup('ResonanceReplayOwnRead', { clear = true }),
            callback = function() own_count = own_count + 1 end,
          })
        end,
      })

      vim.api.nvim_exec_autocmds('FileType', { modeline = false })
      vim.wait(100)

      test.assert_eq(own_count, 1, 'the plugin\'s own BufRead handler')
      test.assert_eq(read_count, 1, 'a handler that already saw the read')
    end,
  },

  {
    name = 'lazy load: VeryLazy trigger fires and loads plugin',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/verylazy-plugin',
        lazy = true,
        setup = function() table.insert(load_order, 'setup') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy', modeline = false })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: keymap trigger fires and loads plugin',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/keymap-plugin',
        keys = function()
          return {{'n', '<leader>test', function() table.insert(load_order, 'rhs') end}}
        end,
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- Headless Neovim does not dispatch mappings from injected keys; invoke the
      -- registered callback directly.
      local want = vim.api.nvim_replace_termcodes('<leader>test', true, false, true)
      vim.wait(50)
      local fired = false
      for _, km in ipairs(vim.api.nvim_get_keymap('n')) do
        if km.lhs == want and km.callback then
          km.callback()
          fired = true
          break
        end
      end
      test.assert_true(fired)
      vim.wait(100)

      -- The plugin must load (setup) before its rhs runs.
      test.assert_eq(#load_order, 2)
      test.assert_eq(load_order[1], 'setup')
      test.assert_eq(load_order[2], 'rhs')
    end,
  },

  {
    name = 'lazy load: cmd trigger fires and loads plugin',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/cmd-plugin',
        cmd = 'TestLoadPlugin',
        setup = function() table.insert(load_order, 'setup') end,
      })

      -- Execute the command to trigger the lazy load.
      vim.cmd('TestLoadPlugin')
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: ft trigger fires and loads plugin',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/ft-plugin',
        ft = 'testfiletype',
        setup = function() table.insert(load_order, 'setup') end,
      })

      vim.api.nvim_set_option_value('filetype', 'testfiletype', { buf = 0 })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'lazy load: plugin loads only once regardless of multiple triggers',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({
        src = 'https://github.com/test/multi-trigger',
        event = { 'User', pattern = 'MultiTrigger1' },
        cmd = 'MultiTriggerCmd',
        setup = function() table.insert(load_order, 'setup') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'MultiTrigger1', modeline = false })
      vim.wait(100)
      vim.api.nvim_exec_autocmds('User', { pattern = 'MultiTrigger1', modeline = false })
      vim.wait(100)

      test.assert_eq(#load_order, 1)
      test.assert_eq(load_order[1], 'setup')
    end,
  },

  {
    name = 'dependency: loads dependencies before plugin',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({src = 'https://github.com/test/dep-b', setup = function() table.insert(load_order, 'dep-b') end})
      _G.resonance.load({src = 'https://github.com/test/dep-c', setup = function() table.insert(load_order, 'dep-c') end})
      _G.resonance.load({
        src = 'https://github.com/test/plugin-a',
        dependencies = {'https://github.com/test/dep-b', 'https://github.com/test/dep-c'},
        event = { 'User', pattern = 'DepTestEvent' },
        setup = function() table.insert(load_order, 'plugin-a') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'DepTestEvent', modeline = false })
      vim.wait(100)

      test.assert_eq(load_order[1], 'dep-b')
      test.assert_eq(load_order[2], 'dep-c')
      test.assert_eq(load_order[3], 'plugin-a')
    end,
  },

  {
    name = 'dependency: a failed dependency install stops the parent',
    fn = function()
      -- The dependency is registered through resonance.load(), so it takes
      -- the "dependency is in M.specs" branch. That branch called the
      -- dependency's loader and discarded the return value, so a failed
      -- install was invisible: the parent went on to install and run its
      -- own setup() with a broken dependency.
      -- Only the dependency fails to install. The parent installs fine, so
      -- the test proves the parent was stopped by the dependency's failure
      -- rather than by its own.
      test.stub_pack({
        add_error = function(name) return name == 'broken-dep' end,
        add_error_message = 'install failed for broken-dep',
      })
      local parent_setup_ran = false
      _G.resonance.load({
        src = 'https://github.com/test/broken-dep',
        event = { 'User', pattern = 'BrokenDepEvent' },
        setup = function() end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/parent-plugin',
        dependencies = { 'https://github.com/test/broken-dep' },
        event = { 'User', pattern = 'BrokenDepEvent' },
        setup = function() parent_setup_ran = true end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'BrokenDepEvent', modeline = false })
      vim.wait(200)

      test.assert_false(parent_setup_ran,
        'the parent ran setup() even though its dependency failed to install')
    end,
  },

  {
    name = 'dependency: transitive dependencies work',
    fn = function()
      test.stub_pack()
      local load_order = {}
      _G.resonance.load({src = 'https://github.com/test/bottom-plugin', setup = function() table.insert(load_order, 'bottom') end})
      _G.resonance.load({
        src = 'https://github.com/test/mid-plugin',
        dependencies = {'https://github.com/test/bottom-plugin'},
        setup = function() table.insert(load_order, 'mid') end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/top-plugin',
        dependencies = {'https://github.com/test/mid-plugin'},
        event = { 'User', pattern = 'TransitiveTest' },
        setup = function() table.insert(load_order, 'top') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'TransitiveTest', modeline = false })
      vim.wait(100)

      test.assert_eq(load_order[1], 'bottom')
      test.assert_eq(load_order[2], 'mid')
      test.assert_eq(load_order[3], 'top')
    end,
  },

  {
    name = 'dependency: two-node cycle is detected and aborted',
    fn = function()
      local load_order = {}
      local notices = {}
      local utils = require('resonance.utils')
      local orig_notify = utils.notify
      utils.notify = function(msg, ...)
        table.insert(notices, msg)
        return orig_notify(msg, ...)
      end

      _G.resonance.load({
        src = 'https://github.com/test/cyc-a',
        dependencies = {'https://github.com/test/cyc-b'},
        event = { 'User', pattern = 'CycleTest' },
        setup = function() table.insert(load_order, 'a') end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/cyc-b',
        dependencies = {'https://github.com/test/cyc-a'},
        setup = function() table.insert(load_order, 'b') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'CycleTest', modeline = false })
      vim.wait(200)
      utils.notify = orig_notify

      test.assert_true(#notices >= 1)
      test.assert_contains(notices[1], 'Circular dependency detected')
      test.assert_contains(notices[1], 'cyc-a')
      test.assert_contains(notices[1], 'cyc-b')
    end,
  },

  {
    name = 'dependency: self-cycle is detected',
    fn = function()
      local notices = {}
      local utils = require('resonance.utils')
      local orig_notify = utils.notify
      utils.notify = function(msg, ...)
        table.insert(notices, msg)
        return orig_notify(msg, ...)
      end

      _G.resonance.load({
        src = 'https://github.com/test/self-cyc',
        dependencies = {'https://github.com/test/self-cyc'},
        event = { 'User', pattern = 'SelfCycleTest' },
        setup = function() end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'SelfCycleTest', modeline = false })
      vim.wait(200)
      utils.notify = orig_notify

      test.assert_true(#notices >= 1)
      test.assert_contains(notices[1], 'Circular dependency detected')
      test.assert_contains(notices[1], 'self-cyc')
    end,
  },

  {
    name = 'dependency: multi-node cycle does not recurse infinitely',
    fn = function()
      local notices = {}
      local utils = require('resonance.utils')
      local orig_notify = utils.notify
      utils.notify = function(msg, ...)
        table.insert(notices, msg)
        return orig_notify(msg, ...)
      end

      -- Cycle of 10 nodes: cyc10-1 -> cyc10-2 -> ... -> cyc10-10 -> cyc10-1
      for i = 1, 10 do
        local dep = 'https://github.com/test/cyc10-' .. (i % 10 + 1)
        _G.resonance.load({
          src = 'https://github.com/test/cyc10-' .. i,
          dependencies = { dep },
          event = (i == 1 and { 'User', pattern = 'Cycle10Test' } or nil),
          setup = function() end,
        })
      end

      local ok = pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = 'Cycle10Test', modeline = false })
      vim.wait(300)
      utils.notify = orig_notify

      test.assert_true(ok)
      test.assert_true(#notices >= 1)
      test.assert_contains(notices[1], 'Circular dependency detected')
    end,
  },

  {
    name = 'dependency: diamond graph is not a false cycle',
    fn = function()
      test.stub_pack()
      local load_order = {}
      local notices = {}
      local utils = require('resonance.utils')
      local orig_notify = utils.notify
      utils.notify = function(msg, ...)
        table.insert(notices, msg)
        return orig_notify(msg, ...)
      end

      _G.resonance.load({
        src = 'https://github.com/test/dia-top',
        dependencies = {'https://github.com/test/dia-left', 'https://github.com/test/dia-right'},
        event = { 'User', pattern = 'DiamondTest' },
        setup = function() table.insert(load_order, 'top') end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/dia-left',
        dependencies = {'https://github.com/test/dia-base'},
        setup = function() table.insert(load_order, 'left') end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/dia-right',
        dependencies = {'https://github.com/test/dia-base'},
        setup = function() table.insert(load_order, 'right') end,
      })
      _G.resonance.load({
        src = 'https://github.com/test/dia-base',
        setup = function() table.insert(load_order, 'base') end,
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'DiamondTest', modeline = false })
      vim.wait(200)
      utils.notify = orig_notify

      -- A shared dependency is not a cycle.
      test.assert_eq(#notices, 0)
      -- The shared dependency loads exactly once.
      local base_count = 0
      for i = 1, #load_order do
        if load_order[i] == 'base' then base_count = base_count + 1 end
      end
      test.assert_eq(base_count, 1)
      test.assert_eq(load_order[#load_order], 'top')
    end,
  },

  {
    name = 'cond: function returning false skips plugin entirely',
    fn = function()
      local load_count = 0
      _G.resonance.load({
        src = 'https://github.com/test/cond-fake-trigger',
        event = 'BufReadPre',
        cond = function() return false end,
        setup = function() load_count = load_count + 1 end,
      })

      -- Never registered for loading: no spec, no force-load entry, no trigger.
      test.assert_nil(_G.loader.specs['cond-fake-trigger'])
      test.assert_nil(_G.loader.force_load_fns['cond-fake-trigger'])
      test.assert_nil(_G.loader.plugin_triggers['cond-fake-trigger'])
      test.assert_not_nil(_G.loader.disabled_plugins['cond-fake-trigger'])

      -- Firing the trigger must not load it.
      vim.api.nvim_exec_autocmds('BufReadPre', { modeline = false })
      vim.wait(100)
      test.assert_eq(load_count, 0)
    end,
  },

  {
    name = 'cond: function returning true loads plugin',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/cond-true', event = 'BufReadPre', cond = function() return true end})
      test.assert_not_nil(_G.loader.specs['cond-true'])
    end,
  },

  {
    name = 'eager load: lazy=false loads on VimEnter',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/eager-plugin', lazy = false})
      local spec = _G.loader.specs['eager-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.event, 'VimEnter')
    end,
  },

  {
    name = 'grouped plugins: setup and loaded state apply to every member',
    fn = function()
      test.stub_pack()
      local setup_a, setup_b = 0, 0
      _G.resonance.load({
        {src = 'https://github.com/test/group-a', event = { 'User', pattern = 'GroupedPluginTest' }, setup = function() setup_a = setup_a + 1 end},
        {src = 'https://github.com/test/group-b', event = { 'User', pattern = 'GroupedPluginTest' }, setup = function() setup_b = setup_b + 1 end},
      })

      vim.api.nvim_exec_autocmds('User', { pattern = 'GroupedPluginTest', modeline = false })
      vim.wait(100)

      local nodes = _G.loader.get_dag_data()
      test.assert_eq(setup_a, 1)
      test.assert_eq(setup_b, 1)
      test.assert_true(nodes['group-a'].loaded)
      test.assert_true(nodes['group-b'].loaded)
    end,
  },

  {
    name = 'version pinning: tag version works',
    fn = function()
      _G.resonance.load({ src = 'https://github.com/test/version-plugin', version = 'v1.0.0' })
      local spec = _G.loader.specs['version-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'v1.0.0')
    end,
  },

  {
    name = 'version pinning: branch version works',
    fn = function()
      _G.resonance.load({ src = 'https://github.com/test/version-plugin', version = 'main' })
      local spec = _G.loader.specs['version-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'main')
    end,
  },

  {
    name = 'version pinning: commit hash version works',
    fn = function()
      _G.resonance.load({ src = 'https://github.com/test/version-plugin', version = 'abc1234' })
      local spec = _G.loader.specs['version-plugin']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'abc1234')
    end,
  },

  {
    name = 'triggerless spec: loads on VimEnter',
    fn = function()
      -- A spec with no trigger and no lazy field registered nothing at all:
      -- no autocmd, no keymap, no command. The plugin was never installed
      -- and never loaded. The README documents this shape for version
      -- pinning -- { src = ..., version = 'v1.0.0' } -- where the user
      -- wants the plugin, just pinned.
      test.stub_pack()
      local setup_ran = false
      _G.resonance.load({
        src = 'https://github.com/test/triggerless-plugin',
        version = 'v1.0.0',
        setup = function() setup_ran = true end,
      })

      vim.api.nvim_exec_autocmds('VimEnter', { modeline = false })
      vim.wait(200)

      test.assert_true(setup_ran, 'the triggerless plugin never loaded')
    end,
  },

  {
    name = 'fallback mode: works when vim.pack is unavailable',
    fn = function()
      -- vim.pack is lazily rehydrated by the vim metatable, so nil it out via
      -- rawset to actually exercise the filesystem fallback.
      local original_pack = rawget(vim, 'pack') or vim.pack
      require('resonance.utils').disable_pack()
      _G.resonance.setup({})
      _G.resonance.load({src = 'https://github.com/test/fallback', event = 'BufReadPre'})
      local info = _G.scanner.get_info()
      test.assert_true(info.total > 0)
      for i = 1, info.total do
        test.assert_not_eq(info.plugins.name[i], 'opt')
        test.assert_not_eq(info.plugins.name[i], 'start')
      end
      require('resonance.utils').restore_pack(original_pack)
    end,
  },
})

test.print_summary()