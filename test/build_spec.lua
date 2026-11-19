-- Tests for resonance.loader.build
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/build_spec.lua" -c "lua test.print_summary()" -c "qall"

local build = require('resonance.loader.build')
local uv = vim.uv
local fs = vim.fs
local h = dofile('test/helpers.lua')
local make_git_repo = h.make_git_repo

-- The build markers live in Resonance's state directory, keyed by plugin
-- name.
local marker_dir = vim.fn.stdpath('state') .. '/resonance/builds'
local function marker_path(name)
  return marker_dir .. '/' .. name
end
local function clear_marker(name)
  uv.fs_unlink(marker_path(name))
end

test.run_suite('resonance.loader.build', {

  {
    name = 'the build module does not load vim.async until a build runs',
    fn = function()
      -- vim.async costs ~1.4 ms to load: it pulls in seven submodules. The
      -- loader requires the build module at setup time, so loading it
      -- eagerly put that cost on every Neovim startup, for a build that
      -- only runs for a plugin with a build hook whose hash changed.
      --
      -- The check has to run in a child Neovim: vim.async is cached in the
      -- vim metatable, so once anything has touched it, a same-process
      -- check can never see it unloaded again.
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, 'p')
      local script = root .. '/child.lua'
      local child = ([[
        vim.opt.runtimepath:append(%q)
        require('resonance.loader.build')
        local n = 0
        for k in pairs(package.loaded) do
          if k:match('^vim%%.async') then n = n + 1 end
        end
        print('ASYNC_COUNT:' .. n)
      ]]):format(vim.fn.stdpath('data') .. '/site/pack/core/opt/resonance.nvim')
      vim.fn.writefile(vim.split(child, '\n', { plain = true }), script)

      local out = vim.fn.system({
        'nvim', '--headless', '-u', 'NONE',
        '-c', 'luafile ' .. script,
        '-c', 'qall',
      })
      test.assert_eq(vim.v.shell_error, 0, 'the child nvim failed:\n' .. out)

      local count = out:match('ASYNC_COUNT:(%d+)')
      test.assert_not_nil(count, 'the child printed no count:\n' .. out)
      test.assert_eq(tonumber(count), 0,
        'requiring the build module loaded ' .. count .. ' vim.async submodule(s)')
    end,
  },

  {
    name = 'clear_build_marker: a reinstall runs the build again',
    fn = function()
      -- The build artifacts live inside the plugin directory, so
      -- uninstalling the plugin deletes them -- but the marker is in
      -- Resonance's own state directory and outlives the plugin.
      --
      -- A reinstall of the same version then lands on the same commit, so
      -- the marker still matched and the build was skipped. The plugin
      -- came back without its artifacts: no compiled native module, no
      -- installed dependencies, no generated files.
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local name = 'reinstall-test-' .. os.time()
      local marker = marker_path(name)
      local artifact = dir .. '/BUILT'

      -- A git repo, so the hash is a real commit.
      vim.fn.writefile({ 'x' }, dir .. '/file.txt')
      vim.fn.system({ 'git', 'init', '-q', dir })
      vim.fn.system({ 'git', '-C', dir, 'add', '-A' })
      vim.fn.system({
        'git', '-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
        'commit', '-q', '-m', 'initial',
      })
      local hash = require('resonance.utils').get_local_hash(dir)
      test.assert_not_nil(hash, 'the test repo has no commit')

      -- The marker from the previous install, and no artifacts.
      build.mark_build_success(name, hash)
      test.assert_not_nil(uv.fs_stat(marker), 'the marker was not written')

      -- The uninstall drops the marker.
      build.clear_build_marker(name)
      test.assert_nil(uv.fs_stat(marker),
        'the marker survived the uninstall')

      -- The reinstall runs the build, because the marker is gone.
      build.check_and_build(name, dir, 'touch ' .. artifact)
      local waited = vim.wait(3000, function()
        return uv.fs_stat(artifact) ~= nil
      end)
      test.assert_true(waited, 'the build did not run after the reinstall')

      uv.fs_unlink(artifact)
      uv.fs_unlink(marker)
    end,
  },

  {
    name = 'mark_build_success: writes the hash to the state directory',
    fn = function()
      local name = 'marker-test-' .. os.time()
      build.mark_build_success(name, 'abc123')
      local fd = uv.fs_open(marker_path(name), 'r', 438)
      test.assert_not_nil(fd, 'the marker was not written')
      local stat = uv.fs_fstat(fd)
      local content = uv.fs_read(fd, stat.size, 0)
      uv.fs_close(fd)
      test.assert_eq(content, 'abc123')
      clear_marker(name)
    end,
  },

  {
    name = 'mark_build_success: does not write into the plugin directory',
    fn = function()
      -- The marker used to be written into the plugin's own directory,
      -- which dirtied its git working tree -- a file the plugin's own
      -- tooling did not put there, showing up in git status.
      local dir = '/tmp/test_build_pollute_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'pollute-test-' .. os.time()

      build.mark_build_success(name, 'abc123')

      test.assert_nil(uv.fs_stat(dir .. '/.resonance_built'),
        'the marker was written into the plugin directory')
      test.assert_not_nil(uv.fs_stat(marker_path(name)),
        'the marker was not written to the state directory')

      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'mark_build_success: a name with a slash stays inside the marker directory',
    fn = function()
      -- The name is used as a file name. A name with a slash in it used
      -- to build a path in a directory that does not exist, and the
      -- write was silently dropped: the build cache was lost, and the
      -- plugin rebuilt on every check.
      --
      -- A name with a traversal in it was worse: it wrote outside the
      -- marker directory.
      local name = 'slash/name-' .. os.time()
      build.mark_build_success(name, 'abc123')

      -- The marker lands under the marker directory, keyed by the last
      -- segment of the name.
      local segment = name:match('[^/]+$')
      local fd = uv.fs_open(marker_path(segment), 'r', 438)
      test.assert_not_nil(fd, 'the marker was not written to the marker directory')
      local stat = uv.fs_fstat(fd)
      local content = uv.fs_read(fd, stat.size, 0)
      uv.fs_close(fd)
      test.assert_eq(content, 'abc123')

      -- Nothing is written outside the marker directory.
      local escaped = vim.fn.stdpath('state') .. '/resonance/escaped-' .. os.time()
      uv.fs_unlink(escaped)
      build.mark_build_success('../' .. escaped:match('([^/]+)$'), 'abc123')
      test.assert_nil(uv.fs_stat(escaped),
        'a name with a traversal wrote outside the marker directory')

      clear_marker(segment)
    end,
  },

  {
    name = 'check_and_build: skips when hash matches',
    fn = function()
      -- This test used to assert that the build did not run immediately
      -- after check_and_build() returned, with no wait. The build runs
      -- asynchronously, so that assertion passed whether or not the hash
      -- check worked -- and the build did run: the directory was not a
      -- git working tree, so the hash did not match the marker.
      --
      -- The directory has to be a real git repository whose commit the
      -- marker holds, and the assertion has to wait for the build to
      -- have had its chance to run.
      local dir = make_git_repo()
      local name = 'skip-test-' .. os.time()

      local hash = require('resonance.utils').get_local_hash(dir)
      test.assert_not_nil(hash, 'the test repository has no readable commit')
      build.mark_build_success(name, hash)

      local built = false
      local function fake_build() built = true end
      build.check_and_build(name, dir, fake_build)
      vim.wait(1500)

      test.assert_false(built, 'the build ran even though the hash matched')
      clear_marker(name)
      vim.fn.delete(dir, 'rf')
    end,
  },

  {
    name = 'run_build: executes string build command',
    fn = function()
      local dir = '/tmp/test_build_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'string-cmd-' .. os.time()
      uv.fs_write(uv.fs_open(dir .. '/test.txt', 'w', 438), 'hello')
      build.run_build(name, dir, 'echo "built" > ' .. dir .. '/build.out', 'hash1')
      vim.wait(500)
      test.assert_true(uv.fs_stat(dir .. '/build.out') ~= nil)
      local fd = uv.fs_open(dir .. '/build.out', 'r', 438)
      local stat = uv.fs_fstat(fd)
      local content = uv.fs_read(fd, stat.size, 0)
      uv.fs_close(fd)
      test.assert_true(content:match('built'))
      uv.fs_unlink(dir .. '/build.out')
      uv.fs_unlink(dir .. '/test.txt')
      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: executes function build hook',
    fn = function()
      local dir = '/tmp/test_build_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'fn-hook-' .. os.time()
      local called = false
      build.run_build(name, dir, function(d) called = true; test.assert_eq(d, dir) end, 'hash1')
      vim.wait(500)
      test.assert_true(called)
      clear_marker(name)
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
      local name = 'rebuild-' .. os.time()
      -- Record a stale hash so the current revision differs from the marker.
      build.mark_build_success(name, 'stale-hash')

      local built = false
      build.check_and_build(name, dir, function()
        built = true
      end)
      vim.wait(1500)

      test.assert_true(built)
      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'check_and_build: rebuild overwrites stale hash marker',
    fn = function()
      local dir = '/tmp/test_build_marker_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'stale-' .. os.time()
      build.mark_build_success(name, 'stale-hash')

      build.check_and_build(name, dir, function() end)
      vim.wait(1500)

      local fd = uv.fs_open(marker_path(name), 'r', 438)
      test.assert_not_nil(fd)
      local stat = uv.fs_fstat(fd)
      local content = uv.fs_read(fd, stat.size, 0)
      uv.fs_close(fd)
      test.assert_not_eq(content, 'stale-hash')

      clear_marker(name)
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
      clear_marker('packchanged-test')
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
      local name = 'nocmd-' .. os.time()
      build.check_and_build(name, dir, function() built = true end)
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

      clear_marker(name)
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
      local name = 'once-' .. os.time()

      build.check_and_build(name, dir, build_fn)
      vim.wait(1500)
      test.assert_eq(built, 1, 'the first check did not build')

      -- The marker now holds the current commit, so the second check must
      -- not build again.
      build.check_and_build(name, dir, build_fn)
      vim.wait(1500)
      test.assert_eq(built, 1, 'the second check rebuilt an unchanged commit')

      clear_marker(name)
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
      local name = 'async-' .. os.time()
      local sys = vim.system({ 'sh', '-c', 'sleep 0.3; echo done > ' .. marker }, { text = true })

      build.run_build(name, dir, function() return sys end, 'hash1',
        function() settled = true end)
      vim.wait(1500)

      test.assert_true(settled, 'the completion callback never fired')
      test.assert_true(uv.fs_stat(marker) ~= nil,
        'the build was marked successful before the async work finished')

      clear_marker(name)
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
      local name = 'asyncfail-' .. os.time()
      local sys = vim.system({ 'sh', '-c', 'exit 3' }, { text = true })

      build.run_build(name, dir, function() return sys end, 'hash1',
        function(ok, err) result = { ok = ok, err = err } end)
      vim.wait(1500)

      test.assert_not_nil(result, 'the completion callback never fired')
      test.assert_false(result.ok, 'a failed build was reported as successful')
      test.assert_nil(uv.fs_stat(marker_path(name)),
        'a failed build was marked as built')

      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'mark_build_success: a name that reduces to a relative path still writes a marker',
    fn = function()
      -- The marker name is reduced to its last path segment, which is
      -- what keeps a name with a slash inside the marker directory. The
      -- two names that survive that reduction without a slash -- "." and
      -- ".." -- are the directory itself and its parent.
      --
      -- The write to such a path fails: fs_open on a directory is
      -- refused. The marker was therefore never written, the build cache
      -- was lost, and the plugin rebuilt on every check -- the same
      -- failure the slash case had.
      local names = { '.', '..' }
      for i = 1, #names do
        local name = names[i]
        build.mark_build_success(name, 'abc123')

        -- The marker is written under the marker directory under a
        -- replacement name, and it holds the hash.
        local replaced = marker_path('_')
        local fd = uv.fs_open(replaced, 'r', 438)
        test.assert_not_nil(fd,
          'no marker was written for the name "' .. name .. '"')
        local stat = uv.fs_fstat(fd)
        local content = uv.fs_read(fd, stat.size, 0)
        uv.fs_close(fd)
        test.assert_eq(content, 'abc123',
          'the marker for the name "' .. name .. '" holds the wrong content')

        clear_marker('_')
      end
    end,
  },

  {
    name = 'run_build: a build that is already running is not started again',
    fn = function()
      -- check_and_build() is called from two places: the loader, when it
      -- registers the build hook, and the PackChanged handler, when the
      -- plugin is installed. The second call landed while the first was
      -- still running, so two builds of the same plugin wrote into the
      -- same directory at the same time.
      local dir = '/tmp/test_build_dup_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'dup-build-' .. os.time()

      local runs = 0
      local task = function()
        runs = runs + 1
      end

      build.run_build(name, dir, task, 'hash1')
      -- The second call arrives while the first is still in flight.
      build.run_build(name, dir, task, 'hash1')
      vim.wait(1500)

      test.assert_eq(runs, 1,
        'the build ran ' .. runs .. ' times; it must run once')
      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: the output is captured, and the exit code is the verdict',
    fn = function()
      -- A build that prints errors and exits 0 is a success by the exit
      -- code -- yarn, npm, cargo and make all write warnings to stderr on
      -- a successful build. But the output is captured, so the swallowed
      -- error is visible.
      local dir = '/tmp/test_build_tail_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'tail-build-' .. os.time()

      local result = nil
      build.run_build(name, dir, 'echo "npm error swallowed" >&2; exit 0', 'hash1',
        function(ok, err) result = { ok = ok, err = err } end)
      vim.wait(1500)

      test.assert_not_nil(result, 'the completion callback never fired')
      test.assert_true(result.ok, 'a build that exited 0 was reported as failed')

      local status = require('resonance.builds').status(name)
      test.assert_not_nil(status, 'the build has no status')
      test.assert_eq(status.state, 'ok')
      test.assert_not_nil(status.output_tail, 'the output was not captured')
      test.assert_true(status.output_tail:find('npm error swallowed', 1, true) ~= nil,
        'the output tail does not hold the error: ' .. tostring(status.output_tail))

      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: a failed build carries its output',
    fn = function()
      local dir = '/tmp/test_build_failout_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'failout-build-' .. os.time()

      local result = nil
      build.run_build(name, dir, 'echo "the real reason" >&2; exit 3', 'hash1',
        function(ok, err) result = { ok = ok, err = err } end)
      vim.wait(1500)

      test.assert_not_nil(result, 'the completion callback never fired')
      test.assert_false(result.ok, 'a failed build was reported as successful')

      local status = require('resonance.builds').status(name)
      test.assert_not_nil(status.output_tail, 'the output was not captured')
      test.assert_true(status.output_tail:find('the real reason', 1, true) ~= nil,
        'the output tail does not hold the reason: ' .. tostring(status.output_tail))

      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: a build killed by the hard timeout settles once',
    fn = function()
      -- The timer reported the failure, then the killed child exited and
      -- the task reported it again: the completion callback ran twice and
      -- the timeout reason was overwritten by the exit-code error.
      local builds = require('resonance.builds')
      local dir = '/tmp/test_build_timeout_' .. os.time()
      uv.fs_mkdir(dir, 493)
      local name = 'timeout-build-' .. os.time()

      local orig_timeout = builds.HARD_TIMEOUT_MS
      builds.HARD_TIMEOUT_MS = 200

      local calls = 0
      local last_err = nil
      build.run_build(name, dir, 'sleep 3', 'hash1', function(_, err)
        calls = calls + 1
        last_err = err
      end)
      vim.wait(1500)
      builds.HARD_TIMEOUT_MS = orig_timeout

      test.assert_eq(calls, 1, 'the completion callback count')
      test.assert_true(tostring(last_err):find('timed out', 1, true) ~= nil,
        'the timeout reason was lost: ' .. tostring(last_err))
      local status = builds.status(name)
      test.assert_eq(status.state, 'failed')
      test.assert_true(tostring(status.error):find('timed out', 1, true) ~= nil,
        'the build state lost the timeout reason: ' .. tostring(status.error))

      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'PackChanged: a delete removes the build marker',
    fn = function()
      -- The panel's uninstall cleared the marker, but vim.pack.del() and
      -- :packdel went through PackChanged, which ignored 'delete'. The
      -- marker survived, and a reinstall at the same commit skipped the
      -- build.
      local name = 'packdel-marker-' .. os.time()
      build.mark_build_success(name, 'abc1234')
      test.assert_not_nil(uv.fs_stat(marker_path(name)), 'the marker was not written')

      build.setup_packchanged_autocmd(function() return nil end)
      vim.api.nvim_exec_autocmds('PackChanged', {
        modeline = false,
        data = { kind = 'delete', spec = { name = name }, path = '/nonexistent/' .. name },
      })

      test.assert_nil(uv.fs_stat(marker_path(name)), 'the marker outlived the delete')
      clear_marker(name)
    end,
  },

  {
    name = 'PackChanged: an install builds even when a stale marker matches',
    fn = function()
      -- The plugin directory was removed by hand, so no delete event
      -- cleared the marker. The reinstall lands on the same commit, and
      -- the marker matched: the build was skipped and the plugin had no
      -- artifacts.
      local name = 'reinstall-marker-' .. os.time()
      local dir = make_git_repo()
      local hash = require('resonance.utils').get_local_hash(dir)
      test.assert_not_nil(hash, 'the test repo has no commit')
      build.mark_build_success(name, hash)

      local built = false
      build.build_hooks[name] = function() built = true end
      build.setup_packchanged_autocmd(function() return dir end)

      vim.api.nvim_exec_autocmds('PackChanged', {
        modeline = false,
        data = { kind = 'install', spec = { name = name }, path = dir },
      })
      vim.wait(1500, function() return built end)

      test.assert_true(built, 'the install skipped the build because of a stale marker')
      build.build_hooks[name] = nil
      clear_marker(name)
      vim.fn.delete(dir, 'rf')
    end,
  },

  {
    name = 'run_build: a build locked by another session waits instead of reporting success',
    fn = function()
      -- When another Neovim session held the lock, the build was reported
      -- as succeeded straight away. The loader took that as "done" and ran
      -- setup() against the tree the other session was still building.
      local builds = require('resonance.builds')
      local name = 'locked-build-' .. os.time()
      local dir = '/tmp/test_build_locked_' .. os.time()
      uv.fs_mkdir(dir, 493)

      -- A lock held by a live process that is not this session's build.
      local lock_dir = vim.fn.stdpath('state') .. '/resonance/locks'
      vim.fn.mkdir(lock_dir, 'p')
      local lock_file = lock_dir .. '/' .. name
      vim.fn.writefile({ tostring(uv.os_getpid()) }, lock_file)

      local orig_poll = build.LOCK_POLL_MS
      build.LOCK_POLL_MS = 50

      -- The wait shows in the progress message, so a build that seems stuck
      -- says what it is waiting on.
      build._reset_batch()
      local texts = {}
      local group = vim.api.nvim_create_augroup('ResonanceBuildLockProgressTest', { clear = true })
      vim.api.nvim_create_autocmd('Progress', {
        group = group,
        callback = function(ev)
          local d = ev.data or {}
          if d.source == 'resonance' then texts[#texts + 1] = d.status .. ' ' .. d.text[1] end
        end,
      })

      local built = false
      local result = nil
      build.run_build(name, dir, function() built = true end, 'hash1',
        function(ok) result = ok end)
      vim.wait(400)

      test.assert_false(built, 'the build ran while another session held the lock')
      test.assert_nil(result, 'the build settled while another session held the lock')
      test.assert_eq(builds.status(name).state, 'running')
      test.assert_not_nil(uv.fs_stat(lock_file), "the other session's lock was removed")

      -- The other session is done and released the lock without a marker
      -- for this commit, so this session builds.
      uv.fs_unlink(lock_file)
      vim.wait(1500, function() return result ~= nil end)
      build.LOCK_POLL_MS = orig_poll

      test.assert_true(built, 'the build never ran once the lock was free')
      test.assert_true(result, 'the build did not succeed')
      test.assert_eq(builds.status(name).state, 'ok')

      vim.wait(50)
      vim.api.nvim_del_augroup_by_id(group)
      local want = {
        'running Building (0/1) ' .. name,
        'running Building (0/1) ' .. name .. ': waiting for another Neovim session',
        'success Build done',
      }
      test.assert_true(vim.deep_equal(texts, want),
        'wrong progress updates while waiting on the lock: ' .. vim.inspect(texts))

      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'run_build: a build the other session finished is not run again',
    fn = function()
      local builds = require('resonance.builds')
      local name = 'locked-done-' .. os.time()
      local dir = '/tmp/test_build_lockdone_' .. os.time()
      uv.fs_mkdir(dir, 493)

      local lock_dir = vim.fn.stdpath('state') .. '/resonance/locks'
      vim.fn.mkdir(lock_dir, 'p')
      local lock_file = lock_dir .. '/' .. name
      vim.fn.writefile({ tostring(uv.os_getpid()) }, lock_file)

      local orig_poll = build.LOCK_POLL_MS
      build.LOCK_POLL_MS = 50

      local built = false
      local result = nil
      build.run_build(name, dir, function() built = true end, 'hash1',
        function(ok) result = ok end)
      vim.wait(200)

      -- The other session builds this commit, writes the marker, and
      -- releases the lock.
      build.mark_build_success(name, 'hash1')
      uv.fs_unlink(lock_file)
      vim.wait(1500, function() return result ~= nil end)
      build.LOCK_POLL_MS = orig_poll

      test.assert_false(built, 'the build ran again after the other session finished it')
      test.assert_true(result, 'the build was not reported as done')
      test.assert_eq(builds.status(name).state, 'ok')

      clear_marker(name)
      uv.fs_rmdir(dir)
    end,
  },

  {
    name = 'build: concurrency limits how many build commands run at once',
    fn = function()
      -- Each build registers itself in a shared directory, counts who else
      -- is there, and holds its slot for a while. The highest count is the
      -- number of builds that actually ran at the same time.
      --
      -- Run at two limits, so the test proves the limit is what changes the
      -- count: a run that never overlapped would pass a limit of 1 too.
      local function peak(limit)
        build.configure({ concurrency = limit })
        local root = vim.fn.tempname()
        local running = root .. '/running'
        vim.fn.mkdir(running, 'p')
        local log = root .. '/log'
        local cmd = ('touch %s/$$; ls %s | wc -l >> %s; sleep 0.3; rm %s/$$')
          :format(running, running, log, running)
        local names, done = {}, 0
        for i = 1, 3 do
          names[i] = ('concurrency-%d-%d-%d'):format(limit, i, uv.hrtime())
          build.run_build(names[i], root, cmd, 'hash1', function() done = done + 1 end)
        end
        vim.wait(5000, function() return done == 3 end)
        local max = 0
        for line in io.lines(log) do
          local n = tonumber(line)
          if n and n > max then max = n end
        end
        for i = 1, #names do clear_marker(names[i]) end
        vim.fn.delete(root, 'rf')
        return max, done
      end

      local ok, err = pcall(function()
        local one, done1 = peak(1)
        local two, done2 = peak(2)
        test.assert_eq(done1, 3, 'not every build finished at a limit of 1')
        test.assert_eq(done2, 3, 'not every build finished at a limit of 2')
        test.assert_eq(one, 1, 'builds overlapped with a concurrency of 1')
        test.assert_eq(two, 2, 'a concurrency of 2 did not run two builds at once')
      end)
      build.configure({})
      if not ok then error(err, 0) end
    end,
  },

  {
    name = 'build: an invalid concurrency warns and falls back to the default',
    fn = function()
      local bad = { 0, -1, 1.5, 'four', math.huge }
      for i = 1, #bad do
        build.configure({ concurrency = 5 })
        local notices = h.capture_and_wait(function()
          build.configure({ concurrency = bad[i] })
        end, 50)
        test.assert_eq(build.concurrency(), 2,
          'concurrency ' .. tostring(bad[i]) .. ' was not replaced by the default')
        test.assert_true(h.noticed(notices, 'build.concurrency'),
          'concurrency ' .. tostring(bad[i]) .. ' was accepted without a warning')
      end
      build.configure({})
    end,
  },

  {
    name = 'build: setup() passes the build config to the build module',
    fn = function()
      local r = h.live().resonance
      local ok, err = pcall(function()
        r.setup({ build = { concurrency = 3 } })
        test.assert_eq(require('resonance.loader.build').concurrency(), 3)
      end)
      r.config.build = { concurrency = 2, progress = true }
      require('resonance.loader.build').configure({})
      if not ok then error(err, 0) end
    end,
  },

  {
    name = 'build: builds report one counted progress message, closed with a summary',
    fn = function()
      -- All builds in flight share one progress message, "Building (1/3)
      -- name", like vim.pack's install report. It ends on a summary of the
      -- batch -- done, failed, or failed partially -- and the notifications
      -- name the plugins. The last update must carry a final status, or the
      -- spinner never stops.
      -- Reset once, for builds an earlier test left unsettled. Each batch
      -- after this one has to start its own count: that is under test.
      build._reset_batch()
      local function batch_of(tasks, opts)
        build.configure(opts or {})
        local seen = {}
        local group = vim.api.nvim_create_augroup('ResonanceBuildProgressTest', { clear = true })
        vim.api.nvim_create_autocmd('Progress', {
          group = group,
          callback = function(ev)
            local d = ev.data or {}
            if d.source == 'resonance' then
              local x = d.data or {}
              seen[#seen + 1] = {
                id = d.id, status = d.status, percent = d.percent,
                text = d.text and d.text[1] or '',
                done = x.done, total = x.total, failed = x.failed, plugin = x.plugin,
              }
            end
          end,
        })
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        local names, done = {}, 0
        local t = uv.hrtime()
        for i = 1, #tasks do
          names[i] = ('progress-%d-%d'):format(i, t)
          build.run_build(names[i], root, tasks[i], 'hash1', function() done = done + 1 end)
        end
        vim.wait(5000, function() return done == #tasks end)
        vim.wait(50)
        vim.api.nvim_del_augroup_by_id(group)
        for i = 1, #names do clear_marker(names[i]) end
        vim.fn.delete(root, 'rf')
        build.configure({})
        return seen, names
      end

      -- The whole sequence, update by update. Each build starts in its own
      -- scheduled callback, so they join in order; the Lua hook is
      -- synchronous and settles right after it joins, and the two commands
      -- settle in the order of their run times.
      local function check(label, seen, names, final_status, final_text, failed)
        local function u(status, text, done, total, nfailed, plugin)
          return {
            id = 'resonance.build', status = status, text = text,
            percent = math.floor(done / total * 100),
            done = done, total = total, failed = nfailed, plugin = plugin,
          }
        end
        local want = {
          u('running', 'Building (0/1) ' .. names[1], 0, 1, 0, names[1]),
          u('running', 'Building (0/2) ' .. names[2], 0, 2, 0, names[2]),
          u('running', 'Building (0/3) ' .. names[3], 0, 3, 0, names[3]),
          u('running', 'Building (1/3)', 1, 3, failed[1]),
          u('running', 'Building (2/3)', 2, 3, failed[2]),
          u(final_status, final_text, 3, 3, failed[3]),
        }
        test.assert_true(vim.deep_equal(seen, want),
          label .. ': wrong progress updates\nwant ' .. vim.inspect(want) .. '\ngot  ' .. vim.inspect(seen))
      end

      local fail_fn = function() error('no') end
      local seen, names = batch_of({ 'sleep 0.1', 'sleep 0.4', function() end })
      check('all ok', seen, names, 'success', 'Build done', { 0, 0, 0 })
      seen, names = batch_of({ 'sleep 0.1; exit 3', 'sleep 0.4; exit 3', fail_fn })
      check('all failed', seen, names, 'failed', 'Build failed', { 1, 2, 3 })
      seen, names = batch_of({ 'sleep 0.1', 'sleep 0.4; exit 3', fail_fn })
      check('some failed', seen, names, 'failed', 'Build failed partially', { 1, 1, 2 })

      test.assert_eq(#batch_of({ 'true' }, { progress = false }), 0,
        'progress = false still sent progress messages')
    end,
  },
})

test.print_summary()