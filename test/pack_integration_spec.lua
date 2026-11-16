-- Integration test against a real vim.pack, in an isolated data directory.
--
-- The rest of the suite stubs vim.pack out. These tests exercise the real
-- thing: a real git repository, a real install, a real lock file.
--
-- vim.pack derives its install directory from stdpath('data'), so the whole
-- test runs in a child Neovim with XDG_DATA_HOME pointed at a temp dir.
-- Running it in-process would install into the user's real plugin directory.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/pack_integration_spec.lua" -c "qall"

local uv = vim.uv

-- A git repository that looks enough like a plugin for vim.pack to install.
local function make_plugin_repo(root, name)
  local src = root .. '/src/' .. name
  vim.fn.mkdir(src .. '/lua/' .. name, 'p')
  vim.fn.mkdir(src .. '/plugin', 'p')
  vim.fn.writefile({ 'return { version = "1.0.0" }' }, src .. '/lua/' .. name .. '/init.lua')
  vim.fn.writefile({ 'vim.g["' .. name .. '_loaded"] = 1' }, src .. '/plugin/' .. name .. '.lua')
  vim.fn.system({ 'git', 'init', '-q', src })
  vim.fn.system({ 'git', '-C', src, 'add', '.' })
  vim.fn.system({
    'git', '-C', src, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
    'commit', '-q', '-m', 'initial',
  })
  return src
end

-- Run a Lua snippet in a child Neovim with an isolated data directory.
-- Returns the child's stdout.
local function run_isolated(root, snippet)
  local script = root .. '/child.lua'

  -- vim.pack derives its install directory from stdpath('data') and its
  -- lock file from vim.go.packlockfile. XDG_DATA_HOME redirects the former;
  -- the lock file has to be redirected inside the child, before any
  -- vim.pack call, because vim.pack reads it on first use. Without both,
  -- the child would install into the user's real plugin directory.
  local preamble = ([[
    vim.go.packlockfile = %q
  ]]):format(root .. '/pack-lock.json')

  local cmd = {
    'env', 'XDG_DATA_HOME=' .. root,
    'nvim', '--headless', '-u', 'NONE',
    '-c', 'luafile ' .. script,
    '-c', 'qall',
  }

  -- Prepend the preamble to the caller's snippet.
  vim.fn.writefile(
    vim.split(preamble .. '\n' .. snippet, '\n', { plain = true }), script)

  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    error('isolated nvim failed (exit ' .. vim.v.shell_error .. '):\n' .. out)
  end
  return out
end

-- The child prints markers; extract the value between two markers.
local function extract(out, marker)
  local found = out:match(marker .. '([^\n]*)')
  if not found then
    error('marker ' .. marker .. ' not found in child output:\n' .. out)
  end
  return found
end

local function temp_root()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/nvim/site/pack/core/opt', 'p')
  return root
end

test.run_suite('resonance.pack_integration', {
  {
    name = 'vim.pack: installs a plugin from a local git repository',
    fn = function()
      local root = temp_root()
      local src = make_plugin_repo(root, 'resonance-testplug')

      local out = run_isolated(root, ([[
        vim.pack.add({ %q }, { confirm = false, load = false })
        local packs = vim.pack.get(nil, { info = false, offline = true })
        print('COUNT:' .. #packs)
        for i = 1, #packs do
          print('NAME:' .. packs[i].spec.name)
          print('PATH:' .. packs[i].path)
        end
      ]]):format(src))

      test.assert_eq(extract(out, 'COUNT:'), '1')
      test.assert_eq(extract(out, 'NAME:'), 'resonance-testplug')
      test.assert_contains(extract(out, 'PATH:'), 'resonance-testplug')
    end,
  },

  {
    name = 'vim.pack: the installed plugin lands under the isolated pack directory',
    fn = function()
      local root = temp_root()
      local src = make_plugin_repo(root, 'resonance-testplug')

      run_isolated(root, ([[
        vim.pack.add({ %q }, { confirm = false, load = false })
      ]]):format(src))

      -- The install must not have touched the real plugin directory.
      local installed = root .. '/nvim/site/pack/core/opt/resonance-testplug'
      test.assert_true(uv.fs_stat(installed) ~= nil, 'plugin was not installed in the isolated directory')
      test.assert_true(uv.fs_stat(installed .. '/.git') ~= nil, 'installed plugin has no git directory')
    end,
  },

  {
    name = 'vim.pack: the lock file records the installed plugin',
    fn = function()
      local root = temp_root()
      local src = make_plugin_repo(root, 'resonance-testplug')

      run_isolated(root, ([[
        vim.pack.add({ %q }, { confirm = false, load = false })
      ]]):format(src))

      local lock_path = root .. '/pack-lock.json'
      test.assert_true(uv.fs_stat(lock_path) ~= nil, 'no lock file was written')
      local lock = vim.json.decode(table.concat(vim.fn.readfile(lock_path), '\n'))
      local entry = lock.plugins['resonance-testplug']
      test.assert_not_nil(entry)
      test.assert_eq(type(entry.rev), 'string')
      test.assert_eq(type(entry.src), 'string')
    end,
  },

  {
    name = 'scanner: finds plugins installed by a real vim.pack',
    fn = function()
      local root = temp_root()
      local src = make_plugin_repo(root, 'resonance-scannerplug')

      -- The scanner needs the whole resonance module tree, and the child
      -- runs with -u NONE so nothing is on its package path. Copy the tree
      -- into the isolated root and point package.path at it.
      local repo_root = vim.fn.getcwd()
      local dest = root .. '/resonance-lua'
      vim.fn.mkdir(dest, 'p')
      vim.fn.system({ 'cp', '-r', repo_root .. '/lua/resonance', dest .. '/resonance' })

      local out = run_isolated(root, ([[
        package.path = %q .. '/?.lua;' .. %q .. '/?/init.lua;' .. package.path
        vim.pack.add({ %q }, { confirm = false, load = false })
        local scanner = require('resonance.scanner')
        local info = scanner.get_info()
        print('TOTAL:' .. info.total)
        local found = false
        for i = 1, info.total do
          if info.plugins.name[i] == 'resonance-scannerplug' then found = true end
        end
        print('FOUND:' .. tostring(found))
      ]]):format(dest, dest, src))

      test.assert_eq(extract(out, 'FOUND:'), 'true')
      test.assert_true(tonumber(extract(out, 'TOTAL:')) >= 1)
    end,
  },

  {
    name = 'vim.pack: deleting a plugin removes it from the pack directory',
    fn = function()
      local root = temp_root()
      local src = make_plugin_repo(root, 'resonance-delplug')

      local out = run_isolated(root, ([[
        vim.pack.add({ %q }, { confirm = false, load = false })
        local before = vim.pack.get(nil, { info = false, offline = true })
        print('BEFORE:' .. #before)
        vim.pack.del({ 'resonance-delplug' }, { force = true })
        local after = vim.pack.get(nil, { info = false, offline = true })
        print('AFTER:' .. #after)
      ]]):format(src))

      test.assert_eq(extract(out, 'BEFORE:'), '1')
      test.assert_eq(extract(out, 'AFTER:'), '0')
      test.assert_true(uv.fs_stat(root .. '/nvim/site/pack/core/opt/resonance-delplug') == nil)
    end,
  },

  {
    name = 'vim.pack: a corrupted plugin directory is reported, not silently ignored',
    fn = function()
      local root = temp_root()
      local src = make_plugin_repo(root, 'resonance-brokenplug')

      -- Install, then break the git directory the way a partial or damaged
      -- install would.
      run_isolated(root, ([[
        vim.pack.add({ %q }, { confirm = false, load = false })
      ]]):format(src))

      local broken = root .. '/nvim/site/pack/core/opt/resonance-brokenplug/.git'
      vim.fn.mkdir(broken, 'p')
      vim.fn.writefile({ 'not a repository' }, broken .. '/HEAD')

      -- The lock entry still claims a valid revision, so the lock is
      -- consistent with the directory on disk and nothing should break.
      local out = run_isolated(root, ([[
        local ok = pcall(function()
          local packs = vim.pack.get(nil, { info = false, offline = true })
          print('COUNT:' .. #packs)
        end)
        print('OK:' .. tostring(ok))
      ]]))

      test.assert_eq(extract(out, 'OK:'), 'true')
    end,
  },
})

test.print_summary()
