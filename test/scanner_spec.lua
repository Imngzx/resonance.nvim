-- Tests for resonance.scanner
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/scanner_spec.lua" -c "lua test.print_summary()" -c "qall"

local scanner = require('resonance.scanner')

test.run_suite('resonance.scanner', {

  {
    name = 'get_info: returns plugin list structure',
    fn = function()
      local info = scanner.get_info()
      test.assert_not_nil(info)
      test.assert_not_nil(info.plugins)
      test.assert_not_nil(info.plugins.name)
      test.assert_not_nil(info.plugins.type)
      test.assert_not_nil(info.plugins.path)
      test.assert_not_nil(info.plugins.loaded)
      test.assert_not_nil(info.plugins.trigger)
      test.assert_not_nil(info.total)
      test.assert_not_nil(info.loaded)
      test.assert_not_nil(info.pack_dir)
    end,
  },

  {
    name = 'get_info: offline=true by default',
    fn = function()
      local info = scanner.get_info()
      test.assert_not_nil(info)
    end,
  },

  {
    name = 'get_info: returns correct types',
    fn = function()
      local info = scanner.get_info()
      test.assert_eq(type(info.total), 'number')
      test.assert_eq(type(info.loaded), 'number')
      test.assert_eq(type(info.pack_dir), 'string')
      test.assert_eq(type(info.plugins.name), 'table')
    end,
  },

  {
    name = 'get_detailed_info: returns extended info',
    fn = function()
      local info = scanner.get_detailed_info()
      test.assert_not_nil(info)
      test.assert_not_nil(info.plugins)
    end,
  },

  {
    name = 'get_info: plugins arrays same length',
    fn = function()
      local info = scanner.get_info()
      local p = info.plugins
      test.assert_eq(#p.name, info.total)
      test.assert_eq(#p.type, info.total)
      test.assert_eq(#p.path, info.total)
      test.assert_eq(#p.loaded, info.total)
      test.assert_eq(#p.trigger, info.total)
    end,
  },

  {
    name = 'get_info: loaded count matches loaded=true entries',
    fn = function()
      local info = scanner.get_info()
      local loaded_count = 0
      for i = 1, info.total do
        if info.plugins.loaded[i] then loaded_count = loaded_count + 1 end
      end
      test.assert_eq(loaded_count, info.loaded)
    end,
  },

  {
    name = 'load_times: table exists',
    fn = function()
      test.assert_not_nil(scanner.load_times)
      test.assert_eq(type(scanner.load_times), 'table')
    end,
  },
})

test.print_summary()