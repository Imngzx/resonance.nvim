-- Populate the isolated dev env (see test/dev_env.sh).
--
-- Run with: nvim --headless -u NONE -l test/dev_bootstrap.lua <repo> <dev>
--
-- vim.pack.get() reads the lock file, not the disk, so a plugin copied into
-- pack/core/opt is invisible to it. Resonance and the fixtures are installed
-- through vim.pack.add() for that reason: the scanner and the panel then see
-- a real plugin set, the same way they do in a user's setup.

local repo, dev = arg[1], arg[2]
assert(repo and dev, 'usage: dev_bootstrap.lua <repo> <dev>')
assert(vim.env.XDG_DATA_HOME and vim.env.XDG_DATA_HOME:find(dev, 1, true) == 1,
  'refusing to bootstrap outside the isolated env: XDG_DATA_HOME=' .. tostring(vim.env.XDG_DATA_HOME))

local FIXTURES = { 'fixture-alpha', 'fixture-beta', 'fixture-gamma' }

local function git(args)
  local out = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait()
  if out.code ~= 0 then error('git ' .. table.concat(args, ' ') .. ' failed:\n' .. out.stderr) end
end

-- A git repository that looks enough like a plugin for vim.pack to install.
-- Same shape as make_plugin_repo() in test/pack_integration_spec.lua.
local function make_fixture(name)
  local src = dev .. '/fixtures/src/' .. name
  if vim.uv.fs_stat(src .. '/.git') then return src end
  local mod = name:gsub('-', '_')
  vim.fn.mkdir(src .. '/lua/' .. mod, 'p')
  vim.fn.mkdir(src .. '/plugin', 'p')
  vim.fn.writefile({ 'local M = {}', 'function M.setup(opts) M.opts = opts end', 'return M' },
    src .. '/lua/' .. mod .. '/init.lua')
  vim.fn.writefile({ ('vim.g.%s_loaded = 1'):format(mod) }, src .. '/plugin/' .. name .. '.lua')
  git({ 'init', '-q', src })
  git({ '-C', src, 'add', '.' })
  git({ '-C', src, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
    'commit', '-q', '-m', 'initial' })
  return src
end

local specs = { { src = 'file://' .. repo, name = 'resonance.nvim' } }
for i = 1, #FIXTURES do
  specs[#specs + 1] = { src = 'file://' .. make_fixture(FIXTURES[i]), name = FIXTURES[i] }
end

vim.pack.add(specs, { load = false, confirm = false })

local packs = vim.pack.get(nil, { info = false, offline = true })
io.stdout:write(('Installed %d plugins into %s\n'):format(#packs, vim.fn.stdpath('data')))
