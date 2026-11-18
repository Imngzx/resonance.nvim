-- architecture
--
-- Part of the resonance.nvim behavioral suite.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_arch_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local live = h.live

-- The runner resets package.loaded between tests, but the loader is
-- loaded by resonance.setup() at the start of every test. This drops it
-- again, so a test can see what a fresh require pulls in.
--
-- The autocmds the previous test installed are still registered in
-- Neovim -- dropping the module does not unregister them -- so they are
-- cleared too.
local function unload_control_plane()
  for _, a in ipairs(api.nvim_get_autocmds({ event = 'PackChanged' })) do
    if (a.group_name or ''):match('^Resonance') then
      pcall(api.nvim_del_autocmd, a.id)
    end
  end
  for _, a in ipairs(api.nvim_get_autocmds({ event = 'BufReadPost' })) do
    if a.group_name == 'ResonanceEventTracker' then
      pcall(api.nvim_del_autocmd, a.id)
    end
  end
  package.loaded['resonance.loader'] = nil
  package.loaded['resonance.loader.spec'] = nil
  package.loaded['resonance.loader.triggers'] = nil
  package.loaded['resonance.loader.build'] = nil
  package.loaded['resonance.loader.dag'] = nil
  package.loaded['resonance.scanner'] = nil
  package.loaded['resonance.registry'] = nil
end

test.run_suite('resonance.behavior.arch', {

  {
    name = 'arch: requiring the scanner does not load the loader',
    fn = function()
      -- The scanner used to require the loader, and the loader required
      -- the scanner. Requiring either one pulled in the other, and with
      -- it the whole control plane: opening the read-only panel
      -- installed the PackChanged build autocmd.
      --
      -- The require was inside get_info(), so the cycle only showed when
      -- the scanner was actually used -- which is every time the panel
      -- opens.
      unload_control_plane()

      local scanner = require('resonance.scanner')
      scanner.get_info()

      test.assert_nil(package.loaded['resonance.loader'],
        'using the scanner loaded the loader')
    end,
  },

  {
    name = 'arch: requiring the registry does not load the loader or the scanner',
    fn = function()
      unload_control_plane()

      require('resonance.registry')

      test.assert_nil(package.loaded['resonance.loader'],
        'requiring the registry loaded the loader')
      test.assert_nil(package.loaded['resonance.scanner'],
        'requiring the registry loaded the scanner')
    end,
  },

  {
    name = 'arch: the scanner reads the triggers and disabled plugins from the registry',
    fn = function()
      -- The registry is the shared state, so what the loader writes is
      -- what the scanner reports.
      --
      -- The trigger and the disabled plugin are attached to a plugin that
      -- is really installed, because the scanner walks the installed
      -- plugins: a name that is not installed is not scanned at all.
      unload_control_plane()

      local registry = require('resonance.registry')
      local scanner = require('resonance.scanner')

      local info = scanner.get_info()
      test.assert_true(info.total > 0, 'no plugins are installed to scan')

      local installed = info.plugins.name[1]
      local disabled = info.plugins.name[2] or info.plugins.name[1]

      registry.plugin_triggers[installed] = 'Test Trigger'
      registry.disabled_plugins[disabled] = {
        trigger = 'none',
        reason = 'cond',
        url = 'https://github.com/test/arch-disabled',
      }

      local scanned = scanner.get_info()

      local found_trigger = false
      for i = 1, scanned.total do
        if scanned.plugins.name[i] == installed then
          found_trigger = scanned.plugins.trigger[i] == 'Test Trigger'
        end
      end
      test.assert_true(found_trigger,
        'the scanner did not report the trigger the registry holds')

      local found_disabled = false
      for i = 1, scanned.total do
        if scanned.plugins.name[i] == disabled then
          found_disabled = scanned.plugins.disabled[i] == true
        end
      end
      test.assert_true(found_disabled,
        'the scanner did not report the disabled plugin the registry holds')
    end,
  },

  {
    name = 'arch: requiring the loader installs no autocmds',
    fn = function()
      -- Requiring the loader used to register two PackChanged handlers
      -- and five event-tracker autocmds as a side effect.
      unload_control_plane()

      require('resonance.loader')

      local resonance_autocmds = 0
      for _, a in ipairs(api.nvim_get_autocmds({ event = 'PackChanged' })) do
        if (a.group_name or ''):match('^Resonance') then
          resonance_autocmds = resonance_autocmds + 1
        end
      end
      test.assert_eq(resonance_autocmds, 0,
        'requiring the loader installed a PackChanged autocmd')

      local tracker = 0
      for _, a in ipairs(api.nvim_get_autocmds({ event = 'BufReadPost' })) do
        if a.group_name == 'ResonanceEventTracker' then
          tracker = tracker + 1
        end
      end
      test.assert_eq(tracker, 0,
        'requiring the loader installed the event tracker')
    end,
  },

  {
    name = 'arch: loading a plugin installs the control plane',
    fn = function()
      -- The autocmds are deferred to the first load(), so they are still
      -- there when the user actually asks for a plugin.
      unload_control_plane()
      local loader = require('resonance.loader')

      loader.load({
        src = 'https://github.com/test/arch-autocmds',
        event = { 'User', pattern = 'ResonanceArchAutocmds' },
        setup = function() end,
      })

      local packchanged = 0
      for _, a in ipairs(api.nvim_get_autocmds({ event = 'PackChanged' })) do
        if (a.group_name or ''):match('^Resonance') then
          packchanged = packchanged + 1
        end
      end
      test.assert_true(packchanged > 0,
        'loading a plugin did not install the PackChanged autocmd')

      local tracker = 0
      for _, a in ipairs(api.nvim_get_autocmds({ event = 'BufReadPost' })) do
        if a.group_name == 'ResonanceEventTracker' then
          tracker = tracker + 1
        end
      end
      test.assert_true(tracker > 0,
        'loading a plugin did not install the event tracker')
    end,
  },

  {
    name = 'arch: the user\'s spec table is not modified',
    fn = function()
      -- parse_config() rewrote the caller's table in place: it added a
      -- `plugin` field and normalized the `keys` list. A spec is the
      -- user's own table, and it stays theirs.
      local spec = require('resonance.loader.spec')

      local user = {
        src = 'https://github.com/test/arch-user-spec',
        event = 'BufReadPre',
        keys = { '<leader>aU' },
      }

      local parsed = spec.parse_config(user)

      test.assert_not_nil(parsed, 'the spec did not parse')
      test.assert_nil(user.plugin,
        "the user's table gained a plugin field")
      test.assert_eq(type(user.keys[1]), 'string',
        "the user's key list was rewritten")

      -- The parsed copy is normalized.
      test.assert_not_nil(parsed.plugin, 'the parsed copy has no plugin field')
      test.assert_eq(type(parsed.keys[1]), 'table',
        'the parsed copy did not normalize the key list')
    end,
  },

  {
    name = 'arch: the setup closure is released after the plugin loads',
    fn = function()
      -- The loader keeps the load_now closure for the whole session, and
      -- that closure holds the spec. The setup closure is the only part
      -- of the spec that holds onto the user's state, so a setup that
      -- captured a large table kept that table alive for the whole
      -- session.
      test.stub_pack()
      local weak = setmetatable({}, { __mode = 'v' })
      local setup
      do
        local payload = { marker = 'retained by the setup closure' }
        weak.ref = payload
        setup = function() return payload end
      end

      _G.resonance.load({
        src = 'https://github.com/test/arch-release-setup',
        event = { 'User', pattern = 'ResonanceArchReleaseSetup' },
        setup = setup,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceArchReleaseSetup', modeline = false })
      vim.wait(200)

      -- Drop the last outside reference, then collect.
      setup = nil
      collectgarbage()
      collectgarbage()
      collectgarbage()

      test.assert_nil(weak.ref,
        "the setup closure is still reachable after the load")
    end,
  },

  {
    name = 'arch: a per-plugin setup closure is released after the plugin loads',
    fn = function()
      -- The same for a setup that lives in the plugin table rather than
      -- at the top level of the spec.
      test.stub_pack()
      local weak = setmetatable({}, { __mode = 'v' })
      local setup
      do
        local payload = { marker = 'retained by the plugin setup' }
        weak.ref = payload
        setup = function() return payload end
      end

      _G.resonance.load({
        src = 'https://github.com/test/arch-release-plugin-setup',
        plugin = {
          { 'https://github.com/test/arch-release-plugin-setup', setup = setup },
        },
        event = { 'User', pattern = 'ResonanceArchReleasePluginSetup' },
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceArchReleasePluginSetup', modeline = false })
      vim.wait(200)

      setup = nil
      collectgarbage()
      collectgarbage()
      collectgarbage()

      test.assert_nil(weak.ref,
        "the plugin setup closure is still reachable after the load")
    end,
  },

  {
    name = 'arch: releasing the setup does not stop it from running',
    fn = function()
      -- The release happens after the setup ran, so the setup still runs
      -- exactly once.
      test.stub_pack()
      local ran = 0
      _G.resonance.load({
        src = 'https://github.com/test/arch-setup-runs',
        event = { 'User', pattern = 'ResonanceArchSetupRuns' },
        setup = function() ran = ran + 1 end,
      })

      api.nvim_exec_autocmds('User', { pattern = 'ResonanceArchSetupRuns', modeline = false })
      vim.wait(200)

      test.assert_eq(ran, 1, 'the setup did not run exactly once')
    end,
  },
})

test.print_summary()
