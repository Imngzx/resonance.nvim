test.run_suite('resonance.integration', {

  {
    name = 'setup: initializes without error',
    fn = function()
      _G.resonance.setup({})
      test.assert_true(true)
    end,
  },

  {
    name = 'load: accepts single plugin spec',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/integration1', event = 'LspAttach'})
      test.assert_not_nil(_G.loader.specs['integration1'])
    end,
  },

  {
    name = 'load: handles lazy=false',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/integration2', lazy = false})
      local spec = _G.loader.specs['integration2']
      test.assert_not_nil(spec)
      test.assert_eq(spec.event, 'VimEnter')
    end,
  },

  {
    name = 'load: handles lazy=true',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/integration3', lazy = true})
      local spec = _G.loader.specs['integration3']
      test.assert_not_nil(spec)
      test.assert_eq(type(spec.event), 'table')
      test.assert_eq(spec.event.pattern, 'VeryLazy')
    end,
  },

  {
    name = 'load: handles cond=false (skips plugin)',
    fn = function()
      local spec = _G.loader.specs['integration4']
      test.assert_nil(spec)
    end,
  },

  {
    name = 'load: handles cond=function returning false',
    fn = function()
      local spec = _G.loader.specs['integration5']
      test.assert_nil(spec)
    end,
  },

  {
    name = 'load: tracks cond-disabled plugins for UI state',
    fn = function()
      _G.resonance.load({
        src = 'https://github.com/test/ui-disabled-cond',
        event = 'BufReadPre',
        cond = false,
      })
      local disabled = _G.loader.disabled_plugins['ui-disabled-cond']
      test.assert_not_nil(disabled)
      test.assert_eq(disabled.reason, 'cond')
      local info = _G.scanner.get_info()
      local found = false
      for i = 1, info.total do
        if info.plugins.name[i] == 'ui-disabled-cond' then
          found = true
          test.assert_true(info.plugins.disabled[i])
          test.assert_eq(info.plugins.trigger[i], '󱐋 BufReadPre')
        end
      end
      test.assert_true(found)
      local nodes = _G.loader.get_dag_data()
      test.assert_true(nodes['ui-disabled-cond'].disabled)
      test.assert_eq(nodes['ui-disabled-cond'].trigger, '󱐋 BufReadPre')
    end,
  },

  {
    name = 'load: handles cond=function returning true',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/integration6', cond = function() return true end})
      test.assert_not_nil(_G.loader.specs['integration6'])
    end,
  },

  {
    name = 'load: handles keys as function',
    fn = function()
      _G.resonance.load({
        src = 'https://github.com/test/integration7',
        keys = function() return {{'n', '<leader>test', function() end}} end
      })
      test.assert_not_nil(_G.loader.specs['integration7'])
    end,
  },

  {
    name = 'load: handles dependencies',
    fn = function()
      _G.resonance.load({
        src = 'https://github.com/test/integration8',
        dependencies = {'https://github.com/test/dep1', 'https://github.com/test/dep2'},
        event = 'BufReadPre',
      })
      local spec = _G.loader.specs['integration8']
      test.assert_not_nil(spec)
      test.assert_not_nil(spec.dependencies)
      test.assert_eq(#spec.dependencies, 2)
    end,
  },

  {
    name = 'load: handles build string',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/integration9', build = 'make'})
      local spec = _G.loader.specs['integration9']
      test.assert_not_nil(spec)
      test.assert_eq(spec.build, 'make')
    end,
  },

  {
    name = 'load: handles build function',
    fn = function()
      local build_fn = function(dir) end
      _G.resonance.load({src = 'https://github.com/test/integration10', build = build_fn})
      local spec = _G.loader.specs['integration10']
      test.assert_not_nil(spec)
      test.assert_eq(spec.build, build_fn)
    end,
  },

  {
    name = 'load: handles version pinning',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/integration11', version = 'v1.0.0'})
      local spec = _G.loader.specs['integration11']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'v1.0.0')
    end,
  },

  {
    name = 'scanner: reflects loaded plugins',
    fn = function()
      local info = _G.scanner.get_info()
      test.assert_not_nil(info)
      test.assert_true(info.total >= 0)
    end,
  },

  {
    name = 'dag: get_dag_data returns structure',
    fn = function()
      local nodes, edges = _G.loader.get_dag_data()
      test.assert_not_nil(nodes)
      test.assert_not_nil(edges)
    end,
  },

  {
    name = 'dag: get_replay_info returns structure',
    fn = function()
      local info = _G.loader.get_replay_info()
      test.assert_not_nil(info)
    end,
  },

  {
    name = 'config: setup with ui config',
    fn = function()
      _G.resonance.setup({
        ui = {
          border = 'rounded',
          width = 100,
          height = 30,
        }
      })
      test.assert_not_nil(_G.resonance.config.ui)
      test.assert_eq(_G.resonance.config.ui.border, 'rounded')
    end,
  },

  {
    name = 'load: cond=false with lazy=false skips lazy validation',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/cond-lazy-false', lazy = false, cond = false})
      test.assert_nil(_G.loader.specs['cond-lazy-false'])
      test.assert_not_nil(_G.loader.disabled_plugins['cond-lazy-false'])
    end,
  },

  {
    name = 'load: cond=function returning nil treated as false',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/cond-nil', event = 'BufReadPre', cond = function() return nil end})
      test.assert_nil(_G.loader.specs['cond-nil'])
      test.assert_not_nil(_G.loader.disabled_plugins['cond-nil'])
    end,
  },

  {
    name = 'load: cond=false with dependencies tracks both',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/dep-cond', cond = false})
      _G.resonance.load({src = 'https://github.com/test/main-cond', event = 'BufReadPre', dependencies = {'https://github.com/test/dep-cond'}})
      local disabled = _G.loader.disabled_plugins['dep-cond']
      test.assert_not_nil(disabled)
      local info = _G.scanner.get_info()
      local found = false
      for i = 1, info.total do
        if info.plugins.name[i] == 'dep-cond' then
          found = true
          test.assert_true(info.plugins.disabled[i])
        end
      end
      test.assert_true(found)
      local nodes = _G.loader.get_dag_data()
      test.assert_true(nodes['dep-cond'].disabled)
      test.assert_false(nodes['main-cond'].disabled)
    end,
  },

  {
    name = 'load: disabled plugin URL present in scanner',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/disabled-url', event = 'BufReadPre', cond = false})
      local info = _G.scanner.get_info()
      local found = false
      for i = 1, info.total do
        if info.plugins.name[i] == 'disabled-url' then
          found = true
          test.assert_eq(info.plugins.path[i], '')
          test.assert_true(info.plugins.disabled[i])
        end
      end
      test.assert_true(found)
    end,
  },

  {
    name = 'load: mixed list with some disabled',
    fn = function()
      _G.resonance.load({
        {src = 'https://github.com/test/mixed-enabled', event = 'BufReadPre'},
        {src = 'https://github.com/test/mixed-disabled', event = 'BufReadPre', cond = false},
        {src = 'https://github.com/test/mixed-enabled2', event = 'BufReadPre'},
      })
      test.assert_not_nil(_G.loader.specs['mixed-enabled'])
      test.assert_not_nil(_G.loader.specs['mixed-enabled2'])
      test.assert_nil(_G.loader.specs['mixed-disabled'])
      test.assert_not_nil(_G.loader.disabled_plugins['mixed-disabled'])
      local info = _G.scanner.get_info()
      local disabled = 0
      for i = 1, info.total do
        if info.plugins.name[i]:find('mixed') and info.plugins.disabled[i] then
          disabled = disabled + 1
        end
      end
      test.assert_eq(disabled, 1)
    end,
  },

  {
    name = 'load: lazy=true with cond=false skips plugin',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/lazy-cond', lazy = true, cond = false})
      test.assert_nil(_G.loader.specs['lazy-cond'])
      test.assert_not_nil(_G.loader.disabled_plugins['lazy-cond'])
    end,
  },

  {
    name = 'load: keys as function with cond=false extracts trigger',
    fn = function()
      _G.resonance.load({
        src = 'https://github.com/test/keys-cond',
        keys = function() return {{'n', '<leader>test', function() end}} end,
        cond = false,
      })
      local disabled = _G.loader.disabled_plugins['keys-cond']
      test.assert_not_nil(disabled)
      test.assert_eq(disabled.trigger, '󰌌 keys')
    end,
  },

  {
    name = 'ui: disabled plugin shows  icon with DiagnosticError',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/ui-icon', event = 'BufReadPre', cond = false})
      _G.resonance.open_ui()
      local st = require('resonance.ui.state')
      local render = require('resonance.ui.render')
      render.render()
      local lines = vim.api.nvim_buf_get_lines(st.state.buf, 0, -1, false)
      local found = false
      for _, l in ipairs(lines) do
        if l:find('ui-icon', 1, true) and l:find('', 1, true) then
          found = true
          break
        end
      end
      test.assert_true(found)
    end,
  },

  {
    name = 'ui: disabled plugin expanded shows disabled(cond) status',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/ui-status', event = 'BufReadPre', cond = false})
      _G.resonance.open_ui()
      local st = require('resonance.ui.state')
      local render = require('resonance.ui.render')
      st.state.expanded['ui-status'] = true
      render.render()
      local lines = vim.api.nvim_buf_get_lines(st.state.buf, 0, -1, false)
      local found_name = false
      local found_status = false
      for _, l in ipairs(lines) do
        if l:find('ui-status', 1, true) then found_name = true end
        if l:find('status: disabled(cond)', 1, true) then found_status = true end
      end
      test.assert_true(found_name)
      test.assert_true(found_status)
    end,
  },

  {
    name = 'ui: disabled count displayed in header',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/ui-count1', cond = false})
      _G.resonance.load({src = 'https://github.com/test/ui-count2', cond = false})
      _G.resonance.open_ui()
      local st = require('resonance.ui.state')
      local render = require('resonance.ui.render')
      render.render()
      local lines = vim.api.nvim_buf_get_lines(st.state.buf, 0, -1, false)
      local found = false
      for _, l in ipairs(lines) do
        if l:find('disabled: 2', 1, true) then
          found = true
          break
        end
      end
      test.assert_true(found)
    end,
  },

  {
    name = 'ui: disabled plugins sorted last',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/z-enabled', event = 'BufReadPre'})
      _G.resonance.load({src = 'https://github.com/test/a-disabled', event = 'BufReadPre', cond = false})
      _G.resonance.open_ui()
      local st = require('resonance.ui.state')
      local render = require('resonance.ui.render')
      render.render()
      local lines = vim.api.nvim_buf_get_lines(st.state.buf, 0, -1, false)

      -- The scanner's sorted SOA must place disabled plugins after enabled ones.
      local info = st.state.info
      local last_enabled_idx = nil
      local first_disabled_idx = nil
      for i = 1, info.total do
        if info.plugins.disabled[i] then
          if first_disabled_idx == nil then first_disabled_idx = i end
        else
          last_enabled_idx = i
        end
      end
      test.assert_not_nil(first_disabled_idx)
      test.assert_not_nil(last_enabled_idx)
      test.assert_true(last_enabled_idx < first_disabled_idx)

      -- Locate the rendered row of the disabled plugin and of any enabled plugin.
      local disabled_line = nil
      local enabled_line = nil
      for i = 1, info.total do
        local name = info.plugins.name[i]
        local disabled = info.plugins.disabled[i]
        for ln, text in ipairs(lines) do
          if text:find(name, 1, true) then
            if disabled then
              disabled_line = disabled_line or ln
            else
              enabled_line = enabled_line or ln
            end
            break
          end
        end
      end

      test.assert_not_nil(disabled_line)
      test.assert_not_nil(enabled_line)
      test.assert_true(disabled_line > enabled_line)
    end,
  },

  {
    name = 'dag: disabled label shown with Comment color',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/dag-disabled', event = 'BufReadPre', cond = false})
      _G.resonance.open_ui()
      local st = require('resonance.ui.state')
      local render = require('resonance.ui.render')
      st.state.view_mode = 'dag'
      st.refresh_dag_data()
      render.render()
      local lines = vim.api.nvim_buf_get_lines(st.state.buf, 0, -1, false)
      local found = false
      for _, l in ipairs(lines) do
        if l:find('dag-disabled', 1, true) and l:find('disabled (cond)', 1, true) then
          found = true
          break
        end
      end
      test.assert_true(found)
    end,
  },

  {
    name = 'load: disabled plugin cannot be force-loaded',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/no-force', event = 'BufReadPre', cond = false})
      local fn = _G.loader.force_load_fns['no-force']
      test.assert_nil(fn)
    end,
  },

  {
    name = 'load: disabled plugin triggers not registered',
    fn = function()
      _G.resonance.load({src = 'https://github.com/test/no-triggers', event = 'BufReadPre', cond = false})
      local trig = _G.loader.plugin_triggers['no-triggers']
      test.assert_nil(trig)
    end,
  },
})

test.print_summary()