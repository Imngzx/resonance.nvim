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
})

test.print_summary()