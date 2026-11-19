-- Benchmark of Resonate (`r` in the panel), without the network.
--
-- Run it through test/bench_resonate.sh, which sets up the throwaway XDG
-- dirs and the git config this needs. Not part of the test suite.
--
-- N local git repos stand in for the remotes. They are installed with
-- vim.pack, then each gets one new commit, so every plugin has a pending
-- update. The remotes are reached through git's `ext::` transport with a
-- sleep in front, which stands in for the network round trip: a fetch
-- from GitHub was measured at ~0.5 s, almost all of it latency.
--
-- One check is timed per run, split into its phases:
--   fetch    first `git fetch` started -> last one finished
--   pack.get the pack.get(info = true) call; it blocks the editor
--   log      pack.get returned -> check finished (the `git log` calls)
--   total    check_updates_network() called -> check finished
-- The pending count is checked too: a faster check that misses updates is
-- not faster.

local uv = vim.uv
local hrtime = uv.hrtime

local N = tonumber(vim.env.RESONANCE_BENCH_PLUGINS) or 49
local LATENCY_MS = tonumber(vim.env.RESONANCE_BENCH_LATENCY_MS) or 500
local RUNS = tonumber(vim.env.RESONANCE_BENCH_RUNS) or 3
local CONCURRENCY = tonumber(vim.env.RESONANCE_BENCH_CONCURRENCY) -- nil: the default
local ROOT = assert(vim.env.RESONANCE_BENCH_ROOT, 'run through test/bench_resonate.sh')

local function ms(ns) return ns / 1e6 end

local function git(args, cwd)
  local cmd = { 'git', '-c', 'user.name=bench', '-c', 'user.email=bench@localhost',
    '-c', 'commit.gpgsign=false' }
  vim.list_extend(cmd, args)
  local out = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if out.code ~= 0 then
    error(table.concat(args, ' ') .. ': ' .. (out.stderr or ''))
  end
  return out.stdout
end

-- Fixture: N remotes, installed through vim.pack.
local remotes = ROOT .. '/remotes'
vim.fn.mkdir(remotes, 'p')
local specs = {}
for i = 1, N do
  local name = string.format('bench-plugin-%03d', i)
  local dir = remotes .. '/' .. name
  git({ 'init', '-q', dir })
  vim.fn.mkdir(dir .. '/lua', 'p')
  vim.fn.writefile({ 'return {}' }, dir .. '/lua/' .. name:gsub('-', '_') .. '.lua')
  git({ 'add', '.' }, dir)
  git({ 'commit', '-q', '-m', 'initial' }, dir)
  specs[i] = { src = 'file://' .. dir, name = name }
end

io.stdout:write(string.format('Installing %d fixture plugins ...\n', N))
-- vim.pack reports the install as progress messages, which would land in
-- the middle of the results table. They are dropped for the install only,
-- and the scheduled last one is drained before the echo comes back.
local real_echo = vim.api.nvim_echo
vim.api.nvim_echo = function() end
vim.pack.add(specs, { confirm = false, load = false })
vim.wait(100)
vim.api.nvim_echo = real_echo

-- One new commit per remote, and the latency in front of every fetch.
-- vim.pack.get(offline) never contacts the remote, so changing the URL
-- after the install does not disturb it.
local sleep = string.format('%.3f', LATENCY_MS / 1000)
local packs = vim.pack.get(nil, { info = false })
for i = 1, #packs do
  local p = packs[i]
  local origin = remotes .. '/' .. p.spec.name
  git({ 'commit', '-q', '--allow-empty', '-m', 'update' }, origin)
  git({ 'remote', 'set-url', 'origin',
    'ext::sh -c sleep% ' .. sleep .. ';% exec% %S% ' .. origin }, p.path)
end

-- Instrumentation, installed before the panel modules load: ui/actions
-- copies vim.system into a local when it is required.
local t = {}
local function reset_timings()
  t = { fetch_first = nil, fetch_last = nil, fetches = 0, get_ms = 0, get_end = nil }
end
reset_timings()

local real_system = vim.system
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(cmd, opts, cb)
  if cmd[1] ~= 'git' or cmd[2] ~= 'fetch' or not cb then
    return real_system(cmd, opts, cb)
  end
  t.fetch_first = t.fetch_first or hrtime()
  return real_system(cmd, opts, function(out)
    t.fetch_last = hrtime()
    t.fetches = t.fetches + 1
    cb(out)
  end)
end

local pack = vim.pack -- load it, so rawget(vim, 'pack') in utils sees this table
local real_get = pack.get
pack.get = function(names, opts)
  if not (opts and opts.info) then return real_get(names, opts) end
  local s = hrtime()
  local res = real_get(names, opts)
  local e = hrtime()
  t.get_ms = t.get_ms + ms(e - s)
  t.get_end = e
  return res
end

local resonance = require('resonance')
resonance.setup({ resonate = { concurrency = CONCURRENCY } })
resonance.open_ui()
local st = require('resonance.ui.state')
local actions = require('resonance.ui.actions')

io.stdout:write(string.format(
  'Resonate benchmark: %d plugins, %d ms simulated latency, concurrency %d, %d run(s)\n\n',
  N, LATENCY_MS, actions.fetch_concurrency(), RUNS))
io.stdout:write(string.format('%-4s %9s %10s %8s %9s %8s\n',
  'run', 'fetch ms', 'pack.get', 'log ms', 'total ms', 'pending'))

local totals = {}
local failed = false
for run = 1, RUNS do
  reset_timings()
  local start = hrtime()
  assert(actions.check_updates_network(), 'the check did not start')
  local done = vim.wait(10 * 60 * 1000, function() return not st.state.checking end, 1)
  local finish = hrtime()
  assert(done, 'the check did not finish within 10 minutes')

  local pending = 0
  for _ in pairs(st.state.updates) do pending = pending + 1 end
  if pending ~= N or t.fetches ~= N then failed = true end

  local fetch_ms = t.fetch_first and ms(t.fetch_last - t.fetch_first) or 0
  local log_ms = t.get_end and ms(finish - t.get_end) or 0
  totals[run] = ms(finish - start)
  io.stdout:write(string.format('%-4d %9.0f %10.0f %8.0f %9.0f %5d/%d\n',
    run, fetch_ms, t.get_ms, log_ms, totals[run], pending, N))
end

table.sort(totals)
io.stdout:write(string.format('\nmedian total: %.0f ms\n', totals[math.ceil(#totals / 2)]))
if failed then
  io.stderr:write('FAIL: not every plugin was fetched and reported as pending\n')
  os.exit(1)
end
