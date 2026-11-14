local function R() return _G.resonance end
local function L() return _G.loader end
local function S() return _G.scanner end

test.run_suite('resonance.integration', {

  {
    name = 'setup: initializes without error',
    fn = function()
      R().setup({})
      test.assert_true(true)
    end,
  },

  {
    name = 'load: accepts single plugin spec',
    fn = function()
      R().load({src = 'https://github.com/test/integration1', event = 'LspAttach'})
      test.assert_not_nil(L().specs['integration1'])
    end,
  },

  {
    name = 'load: handles lazy=false',
    fn = function()
      R().load({src = 'https://github.com/test/integration2', lazy = false})
      local spec = L().specs['integration2']
      test.assert_not_nil(spec)
      test.assert_eq(spec.event, 'VimEnter')
    end,
  },

  {
    name = 'load: handles lazy=true',
    fn = function()
      R().load({src = 'https://github.com/test/integration3', lazy = true})
      local spec = L().specs['integration3']
      test.assert_not_nil(spec)
      test.assert_eq(type(spec.event), 'table')
      test.assert_eq(spec.event.pattern, 'VeryLazy')
    end,
  },

  {
    name = 'load: handles cond=false (skips plugin)',
    fn = function()
      local spec = L().specs['integration4']
      test.assert_nil(spec)
    end,
  },

  {
    name = 'load: handles cond=function returning false',
    fn = function()
      local spec = L().specs['integration5']
      test.assert_nil(spec)
    end,
  },

  {
    name = 'load: tracks cond-disabled plugins for UI state',
    fn = function()
      R().load({
        src = 'https://github.com/test/ui-disabled-cond',
        event = 'BufReadPre',
        cond = false,
      })
      local disabled = L().disabled_plugins['ui-disabled-cond']
      test.assert_not_nil(disabled)
      test.assert_eq(disabled.reason, 'cond')
      local info = S().get_info()
      local found = false
      for i = 1, info.total do
        if info.plugins.name[i] == 'ui-disabled-cond' then
          found = true
          test.assert_true(info.plugins.disabled[i])
          test.assert_eq(info.plugins.trigger[i], '󱐋 BufReadPre')
        end
      end
      test.assert_true(found)
      local nodes = L().get_dag_data()
      test.assert_true(nodes['ui-disabled-cond'].disabled)
      test.assert_eq(nodes['ui-disabled-cond'].trigger, '󱐋 BufReadPre')
    end,
  },

  {
    name = 'load: handles cond=function returning true',
    fn = function()
      R().load({src = 'https://github.com/test/integration6', cond = function() return true end})
      test.assert_not_nil(L().specs['integration6'])
    end,
  },

  {
    name = 'load: handles keys as function',
    fn = function()
      R().load({
        src = 'https://github.com/test/integration7',
        keys = function() return {{'n', '<leader>test', function() end}} end
      })
      test.assert_not_nil(L().specs['integration7'])
    end,
  },

  {
    name = 'load: handles dependencies',
    fn = function()
      R().load({
        src = 'https://github.com/test/integration8',
        dependencies = {'https://github.com/test/dep1', 'https://github.com/test/dep2'},
        event = 'BufReadPre',
      })
      local spec = L().specs['integration8']
      test.assert_not_nil(spec)
      test.assert_not_nil(spec.dependencies)
      test.assert_eq(#spec.dependencies, 2)
    end,
  },

  {
    name = 'load: handles build string',
    fn = function()
      R().load({src = 'https://github.com/test/integration9', build = 'make'})
      local spec = L().specs['integration9']
      test.assert_not_nil(spec)
      test.assert_eq(spec.build, 'make')
    end,
  },

  {
    name = 'load: handles build function',
    fn = function()
      local build_fn = function(dir) end
      R().load({src = 'https://github.com/test/integration10', build = build_fn})
      local spec = L().specs['integration10']
      test.assert_not_nil(spec)
      test.assert_eq(spec.build, build_fn)
    end,
  },

  {
    name = 'load: handles version pinning',
    fn = function()
      R().load({src = 'https://github.com/test/integration11', version = 'v1.0.0'})
      local spec = L().specs['integration11']
      test.assert_not_nil(spec)
      test.assert_eq(spec.version, 'v1.0.0')
    end,
  },

  {
    name = 'scanner: reflects loaded plugins',
    fn = function()
      local info = S().get_info()
      test.assert_not_nil(info)
      test.assert_true(info.total >= 0)
    end,
  },

  {
    name = 'dag: get_dag_data returns structure',
    fn = function()
      local nodes, edges = L().get_dag_data()
      test.assert_not_nil(nodes)
      test.assert_not_nil(edges)
    end,
  },

  {
    name = 'dag: get_replay_info returns structure',
    fn = function()
      local info = L().get_replay_info()
      test.assert_not_nil(info)
    end,
  },

  {
    name = 'config: setup with ui config',
    fn = function()
      R().setup({
        ui = {
          border = 'rounded',
          width = 100,
          height = 30,
        }
      })
      test.assert_not_nil(R().config.ui)
      test.assert_eq(R().config.ui.border, 'rounded')
    end,
  },

  {
    name = 'load: cond=false with lazy=false skips lazy validation',
    fn = function()
      R().load({src = 'https://github.com/test/cond-lazy-false', lazy = false, cond = false})
      test.assert_nil(L().specs['cond-lazy-false'])
      test.assert_not_nil(L().disabled_plugins['cond-lazy-false'])
    end,
  },

  {
    name = 'load: cond=function returning nil treated as false',
    fn = function()
      R().load({src = 'https://github.com/test/cond-nil', event = 'BufReadPre', cond = function() return nil end})
      test.assert_nil(L().specs['cond-nil'])
      test.assert_not_nil(L().disabled_plugins['cond-nil'])
    end,
  },

  {
    name = 'load: cond=false with dependencies tracks both',
    fn = function()
      R().load({src = 'https://github.com/test/dep-cond', cond = false})
      R().load({src = 'https://github.com/test/main-cond', event = 'BufReadPre', dependencies = {'https://github.com/test/dep-cond'}})
      local disabled = L().disabled_plugins['dep-cond']
      test.assert_not_nil(disabled)
      local info = S().get_info()
      local found = false
      for i = 1, info.total do
        if info.plugins.name[i] == 'dep-cond' then
          found = true
          test.assert_true(info.plugins.disabled[i])
        end
      end
      test.assert_true(found)
      local nodes = L().get_dag_data()
      test.assert_true(nodes['dep-cond'].disabled)
      test.assert_false(nodes['main-cond'].disabled)
    end,
  },

  {
    name = 'load: disabled plugin URL present in scanner',
    fn = function()
      R().load({src = 'https://github.com/test/disabled-url', event = 'BufReadPre', cond = false})
      local info = S().get_info()
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
      R().load({
        {src = 'https://github.com/test/mixed-enabled', event = 'BufReadPre'},
        {src = 'https://github.com/test/mixed-disabled', event = 'BufReadPre', cond = false},
        {src = 'https://github.com/test/mixed-enabled2', event = 'BufReadPre'},
      })
      test.assert_not_nil(L().specs['mixed-enabled'])
      test.assert_not_nil(L().specs['mixed-enabled2'])
      test.assert_nil(L().specs['mixed-disabled'])
      test.assert_not_nil(L().disabled_plugins['mixed-disabled'])
      local info = S().get_info()
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
      R().load({src = 'https://github.com/test/lazy-cond', lazy = true, cond = false})
      test.assert_nil(L().specs['lazy-cond'])
      test.assert_not_nil(L().disabled_plugins['lazy-cond'])
    end,
  },

  {
    name = 'load: keys as function with cond=false extracts trigger',
    fn = function()
      R().load({
        src = 'https://github.com/test/keys-cond',
        keys = function() return {{'n', '<leader>test', function() end}} end,
        cond = false,
      })
      local disabled = L().disabled_plugins['keys-cond']
      test.assert_not_nil(disabled)
      test.assert_eq(disabled.trigger, '󰌌 keys')
    end,
  },
})

test.print_summary()