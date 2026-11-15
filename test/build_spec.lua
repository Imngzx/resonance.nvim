-- Tests for resonance.loader.build
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/build_spec.lua" -c "lua test.print_summary()" -c "qall"

local build = require('resonance.loader.build')
local uv = vim.uv
local fs = vim.fs

test.run_suite('resonance.loader.build', {

  {
    name = 'mark_build_success: writes hash file',
    fn = function()
      local dir = '/tmp/test_build_' .. os.time()
      uv.fs_mkdir(dir, 493)
      build.mark_build_success(dir, 'abc123')
      local fd = uv.fs_open(dir .. '/.resonance_built', 'r', 438)
      test.assert_not_nil(fd)
      local stat = uv.fs_fstat(fd)
      local content = uv.fs_read(fd, stat.size, 0)
      uv.fs_close(fd)
      test.assert_eq(content, 'abc123')
      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'check_and_build: skips when hash matches',
    fn = function()
      local dir = '/tmp/test_build_' .. os.time()
      uv.fs_mkdir(dir, 493)
      build.mark_build_success(dir, 'abc123')
      local built = false
      local function fake_build() built = true end
      build.check_and_build('test', dir, fake_build)
      test.assert_false(built)
      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: executes string build command',
    fn = function()
      local dir = '/tmp/test_build_' .. os.time()
      uv.fs_mkdir(dir, 493)
      uv.fs_write(uv.fs_open(dir .. '/test.txt', 'w', 438), 'hello')
      build.run_build('test', dir, 'echo "built" > ' .. dir .. '/build.out', 'hash1')
      vim.wait(500)
      test.assert_true(uv.fs_stat(dir .. '/build.out') ~= nil)
      local fd = uv.fs_open(dir .. '/build.out', 'r', 438)
      local stat = uv.fs_fstat(fd)
      local content = uv.fs_read(fd, stat.size, 0)
      uv.fs_close(fd)
      test.assert_true(content:match('built'))
      uv.fs_unlink(dir .. '/build.out')
      uv.fs_unlink(dir .. '/test.txt')
      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: executes function build hook',
    fn = function()
      local dir = '/tmp/test_build_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local called = false
      build.run_build('test', dir, function(d) called = true; test.assert_eq(d, dir) end, 'hash1')
      vim.wait(500)
      test.assert_true(called)
      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'build_hooks: table exists',
    fn = function()
      test.assert_not_nil(build.build_hooks)
      test.assert_eq(type(build.build_hooks), 'table')
    end,
  },

  {
    name = 'check_and_build: rebuilds when hash changed',
    fn = function()
      local dir = '/tmp/test_build_rebuild_' .. os.time()
      uv.fs_mkdir(dir, 493)
      -- Record a stale hash so the current revision differs from the marker.
      build.mark_build_success(dir, 'stale-hash')

      local built = false
      build.check_and_build('test', dir, function()
        built = true
      end)
      vim.wait(1500)

      test.assert_true(built)
      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'check_and_build: rebuild overwrites stale hash marker',
    fn = function()
      local dir = '/tmp/test_build_marker_' .. os.time()
      uv.fs_mkdir(dir, 493)
      build.mark_build_success(dir, 'stale-hash')

      build.check_and_build('test', dir, function() end)
      vim.wait(1500)

      local fd = uv.fs_open(dir .. '/.resonance_built', 'r', 438)
      test.assert_not_nil(fd)
      local stat = uv.fs_fstat(fd)
      local content = uv.fs_read(fd, stat.size, 0)
      uv.fs_close(fd)
      test.assert_not_eq(content, 'stale-hash')

      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'PackChanged: runs build for installed plugin with hook',
    fn = function()
      local dir = '/tmp/test_build_packchanged_' .. os.time()
      uv.fs_mkdir(dir, 493)

      local built = false
      build.build_hooks['packchanged-test'] = function()
        built = true
      end
      build.setup_packchanged_autocmd(function()
        return dir
      end)

      vim.api.nvim_exec_autocmds('PackChanged', {
        modeline = false,
        data = { kind = 'install', spec = { name = 'packchanged-test' }, path = dir },
      })
      vim.wait(1500)

      test.assert_true(built)
      build.build_hooks['packchanged-test'] = nil
      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'PackChanged: ignores plugin without build hook',
    fn = function()
      local dir = '/tmp/test_build_nohook_' .. os.time()
      uv.fs_mkdir(dir, 493)

      local built = false
      build.build_hooks['nohook-test'] = nil
      build.setup_packchanged_autocmd(function()
        return dir
      end)

      vim.api.nvim_exec_autocmds('PackChanged', {
        modeline = false,
        data = { kind = 'install', spec = { name = 'nohook-test' }, path = dir },
      })
      vim.wait(500)

      test.assert_false(built)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'PackChanged: ignores non install/update kinds',
    fn = function()
      local dir = '/tmp/test_build_kind_' .. os.time()
      uv.fs_mkdir(dir, 493)

      local built = false
      build.build_hooks['kind-test'] = function()
        built = true
      end
      build.setup_packchanged_autocmd(function()
        return dir
      end)

      vim.api.nvim_exec_autocmds('PackChanged', {
        modeline = false,
        data = { kind = 'remove', spec = { name = 'kind-test' }, path = dir },
      })
      vim.wait(500)

      test.assert_false(built)
      build.build_hooks['kind-test'] = nil
      uv.fs_rmdir(dir)
    end,
  },
})

test.print_summary()