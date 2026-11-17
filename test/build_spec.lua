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

  {
    name = 'check_and_build: spawns no subprocess to find the commit',
    fn = function()
      -- The build check runs for every plugin with a build hook at startup.
      -- Running `git rev-parse HEAD` for each one is a process per plugin,
      -- all at once, with nothing bounding how many run at the same time.
      -- The commit is read from the git files instead.
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.system({ 'git', 'init', '-q', dir })
      vim.fn.writefile({ 'x' }, dir .. '/file.txt')
      vim.fn.system({ 'git', '-C', dir, 'add', '.' })
      vim.fn.system({
        'git', '-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
        'commit', '-q', '-m', 'initial',
      })

      -- A shim on PATH counts the git processes that actually get spawned.
      -- Stubbing vim.system would not work: the build module captures it
      -- when it loads, so a later stub is never seen.
      local shim = vim.fn.tempname()
      vim.fn.mkdir(shim, 'p')
      local log = shim .. '/count'
      vim.fn.writefile({ '#!/bin/sh', 'echo x >> ' .. log, 'exec /usr/bin/git "$@"' },
        shim .. '/git')
      vim.fn.setfperm(shim .. '/git', 'rwxr-xr-x')

      local orig_path = vim.env.PATH
      vim.env.PATH = shim .. ':' .. orig_path

      local built = false
      build.check_and_build('nocmd', dir, function() built = true end)
      vim.wait(1500)

      vim.env.PATH = orig_path

      local spawned = 0
      if uv.fs_stat(log) then
        local fd = uv.fs_open(log, 'r', 438)
        local stat = uv.fs_fstat(fd)
        spawned = #vim.split(uv.fs_read(fd, stat.size, 0), '\n', { trimempty = true })
        uv.fs_close(fd)
      end

      test.assert_eq(spawned, 0, 'the build check spawned a git subprocess')
      test.assert_true(built, 'the build did not run for a real git working tree')

      uv.fs_unlink(dir .. '/.resonance_built')
      vim.fn.delete(dir, 'rf')
      vim.fn.delete(shim, 'rf')
    end,
  },

  {
    name = 'check_and_build: does not rebuild when the commit has not moved',
    fn = function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.system({ 'git', 'init', '-q', dir })
      vim.fn.writefile({ 'x' }, dir .. '/file.txt')
      vim.fn.system({ 'git', '-C', dir, 'add', '.' })
      vim.fn.system({
        'git', '-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
        'commit', '-q', '-m', 'initial',
      })

      local built = 0
      local function build_fn() built = built + 1 end

      build.check_and_build('once', dir, build_fn)
      vim.wait(1500)
      test.assert_eq(built, 1, 'the first check did not build')

      -- The marker now holds the current commit, so the second check must
      -- not build again.
      build.check_and_build('once', dir, build_fn)
      vim.wait(1500)
      test.assert_eq(built, 1, 'the second check rebuilt an unchanged commit')

      uv.fs_unlink(dir .. '/.resonance_built')
      vim.fn.delete(dir, 'rf')
    end,
  },

  {
    name = 'run_build: waits for an async build hook before marking it built',
    fn = function()
      -- A Lua build hook that hands back a vim.SystemObj has not finished
      -- when the hook returns. Marking the build as successful then would
      -- make the next check skip a build that never ran.
      local dir = '/tmp/test_build_async_' .. os.time()
      uv.fs_mkdir(dir, 493)

      local marker = dir .. '/done.txt'
      local settled = false
      local sys = vim.system({ 'sh', '-c', 'sleep 0.3; echo done > ' .. marker }, { text = true })

      build.run_build('async', dir, function() return sys end, 'hash1',
        function() settled = true end)
      vim.wait(1500)

      test.assert_true(settled, 'the completion callback never fired')
      test.assert_true(uv.fs_stat(marker) ~= nil,
        'the build was marked successful before the async work finished')

      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_unlink(marker)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: reports a failed async build hook',
    fn = function()
      local dir = '/tmp/test_build_async_fail_' .. os.time()
      uv.fs_mkdir(dir, 493)

      local result = nil
      local sys = vim.system({ 'sh', '-c', 'exit 3' }, { text = true })

      build.run_build('asyncfail', dir, function() return sys end, 'hash1',
        function(ok, err) result = { ok = ok, err = err } end)
      vim.wait(1500)

      test.assert_not_nil(result, 'the completion callback never fired')
      test.assert_false(result.ok, 'a failed build was reported as successful')
      test.assert_nil(uv.fs_stat(dir .. '/.resonance_built'),
        'a failed build was marked as built')

      uv.fs_unlink(dir .. '/.resonance_built')
      uv.fs_rmdir(dir)
    end,
  },
})

test.print_summary()