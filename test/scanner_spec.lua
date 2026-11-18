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
    name = 'get_detailed_info: populates rev_to and manifest fields',
    fn = function()
      local info = scanner.get_detailed_info()
      test.assert_not_nil(info.plugins.rev_to)
      test.assert_not_nil(info.plugins.manifest)

      -- rev_to/manifest are sparse (only resolvable plugins get a value), so
      -- count entries instead of using #.
      local rev_to_count, manifest_count = 0, 0
      for _ in pairs(info.plugins.rev_to) do rev_to_count = rev_to_count + 1 end
      for _ in pairs(info.plugins.manifest) do manifest_count = manifest_count + 1 end
      test.assert_true(rev_to_count > 0)

      -- No entry may fall outside the reported plugin range.
      for i in pairs(info.plugins.rev_to) do
        test.assert_true(i >= 1 and i <= info.total)
      end
      for i in pairs(info.plugins.manifest) do
        test.assert_true(i >= 1 and i <= info.total)
      end
    end,
  },

  {
    name = 'get_detailed_info: differs from fast path by requesting info',
    fn = function()
      local fast = scanner.get_info()
      local detailed = scanner.get_detailed_info()

      -- The fast path must not populate the detailed-only columns.
      test.assert_nil(fast.plugins.rev_to[1])
      test.assert_nil(fast.plugins.manifest[1])

      -- The detailed path must request info, so at least one plugin resolves a
      -- target revision or manifest entry.
      local populated = false
      for i = 1, detailed.total do
        if detailed.plugins.rev_to[i] ~= nil or detailed.plugins.manifest[i] ~= nil then
          populated = true
          break
        end
      end
      test.assert_true(populated)
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

  {
    name = 'fallback: loaded count matches loaded=true entries',
    fn = function()
      local orig_pack = rawget(vim, 'pack') or vim.pack
      require('resonance.utils').disable_pack()
      package.loaded['resonance.scanner'] = nil
      local fallback_scanner = require('resonance.scanner')

      local info = fallback_scanner.get_info()
      test.assert_not_nil(info)
      test.assert_not_nil(info.plugins)

      -- The fallback must agree with itself about which plugins are loaded.
      local loaded_count = 0
      for i = 1, info.total do
        if info.plugins.loaded[i] then loaded_count = loaded_count + 1 end
      end
      test.assert_eq(loaded_count, info.loaded)

      local all_arrays_same_length = #info.plugins.name == info.total
        and #info.plugins.type == info.total
        and #info.plugins.path == info.total
        and #info.plugins.loaded == info.total
        and #info.plugins.trigger == info.total
        and #info.plugins.disabled == info.total
      test.assert_true(all_arrays_same_length)

      require('resonance.utils').restore_pack(orig_pack)
      package.loaded['resonance.scanner'] = nil
    end,
  },

  {
    name = 'fallback: discovers real plugin directories',
    fn = function()
      local orig_pack = rawget(vim, 'pack') or vim.pack
      require('resonance.utils').disable_pack()
      package.loaded['resonance.scanner'] = nil
      local fallback_scanner = require('resonance.scanner')

      local info = fallback_scanner.get_info()
      test.assert_true(info.total > 0)

      -- Names must be plugin directories, never the pack layout segments.
      for i = 1, info.total do
        local name = info.plugins.name[i]
        test.assert_not_eq(name, 'opt')
        test.assert_not_eq(name, 'start')
        test.assert_true(vim.uv.fs_stat(info.plugins.path[i]) ~= nil)
        test.assert_eq(info.plugins.type[i], 'opt')
      end

      require('resonance.utils').restore_pack(orig_pack)
      package.loaded['resonance.scanner'] = nil
    end,
  },

  {
    name = 'fallback: does not report unloaded plugins as loaded',
    fn = function()
      local orig_pack = rawget(vim, 'pack') or vim.pack
      require('resonance.utils').disable_pack()
      package.loaded['resonance.scanner'] = nil
      local fallback_scanner = require('resonance.scanner')

      local info = fallback_scanner.get_info()
      local rtps = {}
      for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
        rtps[vim.fs.normalize(p)] = true
      end

      -- Every plugin reported as loaded must actually be on the runtime path.
      for i = 1, info.total do
        if info.plugins.loaded[i] then
          test.assert_true(rtps[vim.fs.normalize(info.plugins.path[i])] ~= nil)
        end
      end

      require('resonance.utils').restore_pack(orig_pack)
      package.loaded['resonance.scanner'] = nil
    end,
  },

  {
    name = 'fallback: disabled plugins are excluded from loaded count',
    fn = function()
      local orig_pack = rawget(vim, 'pack') or vim.pack
      require('resonance.utils').disable_pack()
      package.loaded['resonance.scanner'] = nil
      local fallback_scanner = require('resonance.scanner')

      local info = fallback_scanner.get_info()
      for i = 1, info.total do
        if info.plugins.disabled[i] then
          test.assert_false(info.plugins.loaded[i])
        end
      end

      require('resonance.utils').restore_pack(orig_pack)
      package.loaded['resonance.scanner'] = nil
    end,
  },
})

test.print_summary()