-- VeryLazy, the automatic replay, and the event spellings
--
-- Part of the resonance.nvim behavioral suite.
--
-- A config used to need three pieces of glue: a trigger_verylazy() call, a
-- hand-written replay loop in its own synchronous VeryLazy autocmd, and the
-- { 'User', pattern = 'VeryLazy' } spelling -- 'VeryLazy' alone raised and
-- aborted the whole load(). These tests pin the behaviour that replaced it.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_verylazy_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local capture_and_wait = h.capture_and_wait
local noticed = h.noticed

-- A name no other test uses, so a trigger group or a spec never collides.
local run_id = tostring(vim.uv.hrtime())
local function fresh(label)
  return label .. '-' .. run_id
end

-- The suite runs inside -c, before VimEnter, so setup() armed VeryLazy on
-- VimEnter in the ResonanceVeryLazy augroup. Firing that group runs the
-- real arming path and nothing else.
--
-- The Neovim running the suite loaded the user's config, which has its own
-- User VeryLazy handlers (session restore, LSP, ...). They are dropped
-- first: the process is thrown away afterwards, and firing them here would
-- run the user's whole config inside a test.
local function drop_foreign_verylazy()
  local autocmds = api.nvim_get_autocmds({ event = 'User', pattern = 'VeryLazy' })
  for i = 1, #autocmds do
    pcall(api.nvim_del_autocmd, autocmds[i].id)
  end
end

local function fire_startup()
  pcall(api.nvim_exec_autocmds, 'VimEnter', { group = 'ResonanceVeryLazy', modeline = false })
  pcall(api.nvim_exec_autocmds, 'UIEnter', { group = 'ResonanceVeryLazy', modeline = false })
  vim.wait(200)
end

-- Count the VeryLazy fires, in a group of the test's own.
local function count_verylazy()
  local n = { value = 0 }
  local group = api.nvim_create_augroup(fresh('TestVeryLazyCount'), { clear = true })
  api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'VeryLazy',
    callback = function() n.value = n.value + 1 end,
  })
  return n
end

-- A buffer naming a file on disk, with its read events already behind it:
-- the `nvim <file>` path, where the file is read before UIEnter.
local function read_buffer()
  local buf = api.nvim_create_buf(true, false)
  local file = vim.fn.tempname()
  vim.fn.writefile({ 'x' }, file)
  api.nvim_buf_set_name(buf, file)
  api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
  api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
  api.nvim_exec_autocmds('BufEnter', { buffer = buf, modeline = false })
  return buf
end

-- The autocmds of a plugin's trigger group, as "event:pattern" strings.
local function trigger_autocmds(name)
  local group = require('resonance.loader.triggers').trigger_group_name(name)
  local ok, autocmds = pcall(api.nvim_get_autocmds, { group = group })
  local out = {}
  if not ok then return out end
  for i = 1, #autocmds do
    out[#out + 1] = autocmds[i].event .. ':' .. autocmds[i].pattern
  end
  table.sort(out)
  return out
end

local function has(list, item)
  for i = 1, #list do
    if list[i] == item then return true end
  end
  return false
end

test.run_suite('resonance.behavior.verylazy', {

  -- VeryLazy and the installs of a first start --------------------------------

  {
    name = 'verylazy: waits for a running install, and its replay rescues a file opened meanwhile',
    fn = function()
      -- vim.pack.add runs the event loop while it clones. VeryLazy, scheduled
      -- at startup, fired in the middle of the `lazy = false` install: its
      -- plugins were set up before the eager one. A file opened during the
      -- install fired no BufReadPost -- the install runs inside a VimEnter
      -- handler, and autocommands do not nest -- and the replay that would
      -- have caught it had already run. Its plugin never loaded.
      local stub = test.stub_pack()
      drop_foreign_verylazy()
      _G.resonance._reset()
      _G.resonance.setup()

      local eager, vl, onread = fresh('first-eager'), fresh('first-vl'), fresh('first-onread')
      local file = vim.fn.tempname()
      vim.fn.writefile({ 'x' }, file)
      local log = {}
      local add = stub.add
      stub.add = function(specs)
        local src = type(specs[1]) == 'table' and (specs[1].src or specs[1][1]) or specs[1]
        if tostring(src):find(eager, 1, true) then
          -- The clone takes a while, and the user opens a file meanwhile.
          vim.defer_fn(function() vim.cmd('edit ' .. vim.fn.fnameescape(file)) end, 20)
          vim.wait(200)
        end
        return add(specs)
      end

      _G.resonance.load({
        { src = 'https://github.com/test/' .. eager, lazy = false, setup = function() log[#log + 1] = 'eager' end },
        { src = 'https://github.com/test/' .. vl, event = 'VeryLazy', setup = function() log[#log + 1] = 'vl' end },
        { src = 'https://github.com/test/' .. onread, event = 'BufReadPost', setup = function() log[#log + 1] = 'onread' end },
      })

      -- Startup: VeryLazy is scheduled, then the eager trigger installs.
      api.nvim_exec_autocmds('VimEnter', { group = 'ResonanceVeryLazy', modeline = false })
      local group = require('resonance.loader.triggers').trigger_group_name(eager)
      api.nvim_exec_autocmds('VimEnter', { group = group, modeline = false })
      vim.wait(500, function() return #log >= 3 end, 10)

      local buf = vim.fn.bufnr(file)
      if buf > 0 then pcall(api.nvim_buf_delete, buf, { force = true }) end
      vim.fn.delete(file)
      test.assert_eq(table.concat(log, ','), 'eager,vl,onread',
        'VeryLazy ran during the install, or the file opened meanwhile lost its plugin')
    end,
  },

  -- VeryLazy fires by itself ------------------------------------------------

  {
    name = 'verylazy: setup() alone fires User VeryLazy, once',
    fn = function()
      -- trigger_verylazy() used to be required. A config that forgot it
      -- never fired VeryLazy, and no VeryLazy plugin ever loaded.
      --
      -- Start from nothing armed: the user's config, loaded by the Neovim
      -- running the suite, may have armed VeryLazy itself, and that would
      -- make this test pass without setup() doing anything.
      drop_foreign_verylazy()
      pcall(api.nvim_del_augroup_by_name, 'ResonanceVeryLazy')
      _G.resonance._reset()
      _G.resonance.setup()
      local n = count_verylazy()
      fire_startup()
      test.assert_eq(n.value, 1, 'VeryLazy did not fire exactly once from setup() alone')
    end,
  },

  {
    name = 'verylazy: arming twice still fires once',
    fn = function()
      -- setup() and load() both arm VeryLazy, and a config may call setup()
      -- twice. The UIEnter and VimEnter paths can also both reach the fire;
      -- VeryLazy must still run once.
      drop_foreign_verylazy()
      _G.resonance.setup()
      _G.resonance.setup()
      local n = count_verylazy()
      fire_startup()
      vim.wait(100)
      test.assert_eq(n.value, 1, 'VeryLazy fired more than once')
    end,
  },

  {
    name = 'verylazy: a callback armed before _reset() does not fire',
    fn = function()
      -- The runner builds a fresh module for every test, and every one
      -- arms VeryLazy. A callback left over from an earlier generation must
      -- not fire into the current one.
      drop_foreign_verylazy()
      _G.resonance._reset()
      local n = count_verylazy()
      fire_startup()
      test.assert_eq(n.value, 0, 'a stale VeryLazy callback fired after _reset()')
    end,
  },

  -- The replay runs by itself ----------------------------------------------

  {
    name = 'verylazy: a trigger registered during VeryLazy loads with no manual replay',
    fn = function()
      -- `nvim <file>` reads the file before UIEnter, and a plugin whose
      -- trigger is registered in VeryLazy never saw that read. The user
      -- had to write a replay loop; now it runs on its own.
      --
      -- A VeryLazy handler that raises comes first: it must not stop the
      -- replay.
      test.stub_pack()
      drop_foreign_verylazy()
      local buf = read_buffer()
      local setup_ran = false
      local group = api.nvim_create_augroup(fresh('TestVeryLazyLate'), { clear = true })
      api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'VeryLazy',
        callback = function() error('a broken plugin setup') end,
      })
      api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'VeryLazy',
        callback = function()
          _G.resonance.load({
            src = 'https://github.com/test/' .. fresh('verylazy-late'),
            event = { 'BufReadPost', 'BufNewFile' },
            setup = function() setup_ran = true end,
          })
        end,
      })

      pcall(fire_startup)
      vim.wait(200)
      pcall(api.nvim_buf_delete, buf, { force = true })
      test.assert_true(setup_ran, 'the trigger registered during VeryLazy never loaded')
    end,
  },

  {
    name = 'verylazy: setup({ replay = false }) after load() turns the replay off',
    fn = function()
      -- load() can arm VeryLazy before the user's setup() runs, so the
      -- option has to be read when VeryLazy fires, not when it is armed.
      test.stub_pack()
      drop_foreign_verylazy()
      local buf = read_buffer()
      local setup_ran = false
      _G.resonance.load({
        src = 'https://github.com/test/' .. fresh('verylazy-early'),
        event = { 'User', pattern = 'NeverFired' },
      })
      _G.resonance.setup({ replay = false })
      local group = api.nvim_create_augroup(fresh('TestVeryLazyOff'), { clear = true })
      api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'VeryLazy',
        callback = function()
          _G.resonance.load({
            src = 'https://github.com/test/' .. fresh('verylazy-off'),
            event = 'BufReadPost',
            setup = function() setup_ran = true end,
          })
        end,
      })

      fire_startup()
      pcall(api.nvim_buf_delete, buf, { force = true })
      test.assert_false(setup_ran, 'the replay ran although replay = false')
    end,
  },

  {
    name = 'verylazy: loaded after startup, VeryLazy fires once and latches the startup time',
    fn = function()
      -- The suite runs inside -c, before VimEnter, so the path taken when
      -- Resonance is loaded after startup cannot be reached in this
      -- process. A child Neovim calls setup() from its own VimEnter, where
      -- v:vim_did_enter is already 1.
      --
      -- The startup time used to be latched only by the UIEnter/VimEnter
      -- callbacks, which never run on that path.
      local root = vim.fn.stdpath('data') .. '/site/pack/core/opt/resonance.nvim'
      local script = vim.fn.tempname() .. '.lua'
      vim.fn.writefile({
        "local r = require('resonance')",
        "local n = 0",
        "vim.api.nvim_create_autocmd('User', { pattern = 'VeryLazy', callback = function() n = n + 1 end })",
        "local did_enter = vim.v.vim_did_enter",
        "r.setup()",
        "vim.defer_fn(function()",
        "  io.stdout:write('DID_ENTER=' .. did_enter .. ' FIRED=' .. n .. ' LATCHED=' .. tostring(r._end_time ~= nil) .. '\\n')",
        "  vim.cmd('qall!')",
        "end, 300)",
      }, script)
      local out = vim.system({
        'nvim', '--headless', '--clean',
        '--cmd', 'set rtp^=' .. root,
        '--cmd', 'autocmd VimEnter * ++once lua dofile(' .. vim.inspect(script) .. ')',
      }, { text = true }):wait(15000)
      vim.fn.delete(script)
      local text = (out.stdout or '') .. (out.stderr or '')
      test.assert_contains(text, 'DID_ENTER=1', 'the child did not reach the late-load path: ' .. text)
      test.assert_contains(text, 'FIRED=1', 'VeryLazy did not fire exactly once when loaded late: ' .. text)
      test.assert_contains(text, 'LATCHED=true', 'the startup time was not latched when VeryLazy fired: ' .. text)
    end,
  },

  -- Event spellings ----------------------------------------------------------

  {
    name = "events: 'VeryLazy' and 'User Foo' register User autocmds",
    fn = function()
      -- 'VeryLazy' is the lazy.nvim spelling. It used to reach
      -- nvim_create_autocmd as an event name and abort the whole load().
      test.stub_pack()
      local a, b = fresh('ev-verylazy'), fresh('ev-userfoo')
      _G.resonance.load({ src = 'https://github.com/test/' .. a, event = 'VeryLazy' })
      _G.resonance.load({ src = 'https://github.com/test/' .. b, event = 'User Foo' })
      test.assert_true(has(trigger_autocmds(a), 'User:VeryLazy'),
        "'VeryLazy' did not register User VeryLazy: " .. vim.inspect(trigger_autocmds(a)))
      test.assert_true(has(trigger_autocmds(b), 'User:Foo'),
        "'User Foo' did not register User Foo: " .. vim.inspect(trigger_autocmds(b)))
    end,
  },

  {
    name = 'events: a User event nested in a list is kept',
    fn = function()
      test.stub_pack()
      local name = fresh('ev-nested-user')
      _G.resonance.load({
        src = 'https://github.com/test/' .. name,
        event = { 'InsertEnter', { 'User', pattern = 'X' } },
      })
      local got = trigger_autocmds(name)
      test.assert_true(has(got, 'User:X'), 'the nested User event was dropped: ' .. vim.inspect(got))
      test.assert_true(has(got, 'InsertEnter:*'), 'InsertEnter is missing: ' .. vim.inspect(got))
    end,
  },

  {
    name = "events: a list's pattern does not overwrite a nested User event's",
    fn = function()
      test.stub_pack()
      local name = fresh('ev-outer-pattern')
      _G.resonance.load({
        src = 'https://github.com/test/' .. name,
        event = { 'InsertEnter', { 'User', pattern = 'X' }, pattern = '*.lua' },
      })
      local got = trigger_autocmds(name)
      test.assert_true(has(got, 'User:X'), 'the User pattern was overwritten: ' .. vim.inspect(got))
      test.assert_true(has(got, 'InsertEnter:*.lua'), 'the list pattern was lost: ' .. vim.inspect(got))
    end,
  },

  {
    name = "events: one event's pattern does not leak onto another",
    fn = function()
      -- The first pattern found used to be applied to every native event:
      -- InsertEnter here was scoped to markdown files.
      test.stub_pack()
      local name = fresh('ev-pattern-bleed')
      _G.resonance.load({
        src = 'https://github.com/test/' .. name,
        event = { 'InsertEnter', { event = 'BufEnter', pattern = '*.md' } },
      })
      local got = trigger_autocmds(name)
      test.assert_true(has(got, 'InsertEnter:*'), 'InsertEnter took the *.md pattern: ' .. vim.inspect(got))
      test.assert_true(has(got, 'BufEnter:*.md'), 'BufEnter *.md is missing: ' .. vim.inspect(got))
    end,
  },

  {
    name = "events: { event = 'User', pattern = 'X' } is a User event",
    fn = function()
      -- Written by analogy with { event = 'BufEnter', pattern = '*.md' }. It
      -- has no internal `user` flag, so it was read as a native event: the
      -- list's own pattern overwrote X, and the trigger showed a bare "User".
      test.stub_pack()
      local name = fresh('ev-user-descriptor')
      local spec_event = { 'InsertEnter', { event = 'User', pattern = 'X' }, pattern = '*.lua' }
      _G.resonance.load({ src = 'https://github.com/test/' .. name, event = spec_event })
      local got = trigger_autocmds(name)
      test.assert_true(has(got, 'User:X'), 'the User pattern was overwritten: ' .. vim.inspect(got))
      test.assert_true(has(got, 'InsertEnter:*.lua'), 'the list pattern was lost: ' .. vim.inspect(got))
      test.assert_contains(_G.utils.parse_trigger({ event = { { event = 'User', pattern = 'X' } } }), 'User(X)',
        'the trigger is not shown with its pattern')
      test.assert_nil(spec_event[2].user, "the user's own descriptor table was modified")
    end,
  },

  {
    name = "events: surrounding whitespace in 'User Foo ' is ignored",
    fn = function()
      test.stub_pack()
      local name = fresh('ev-user-trailing')
      _G.resonance.load({ src = 'https://github.com/test/' .. name, event = { 'User Foo ', ' BufReadPost' } })
      local got = trigger_autocmds(name)
      test.assert_true(has(got, 'User:Foo'), "'User Foo ' did not register User Foo: " .. vim.inspect(got))
      test.assert_true(has(got, 'BufReadPost:*'), "' BufReadPost' did not register: " .. vim.inspect(got))
    end,
  },

  {
    name = 'events: a single descriptor normalizes to itself',
    fn = function()
      local got = _G.utils.normalize_events({ event = 'BufEnter', pattern = '*.md' })
      test.assert_eq(#got, 1, 'the descriptor was dropped: ' .. vim.inspect(got))
      test.assert_eq(got[1].event, 'BufEnter')
      test.assert_eq(got[1].pattern, '*.md')
    end,
  },

  {
    name = 'events: events sharing a list pattern register together',
    fn = function()
      test.stub_pack()
      local name = fresh('ev-list-pattern')
      local pats = { '*.lua', '*.vim' }
      _G.resonance.load({
        src = 'https://github.com/test/' .. name,
        event = {
          { event = 'BufEnter', pattern = { '*.lua', '*.vim' } },
          { event = 'BufLeave', pattern = pats },
        },
      })
      local got = trigger_autocmds(name)
      local want = { 'BufEnter:*.lua', 'BufEnter:*.vim', 'BufLeave:*.lua', 'BufLeave:*.vim' }
      for i = 1, #want do
        test.assert_true(has(got, want[i]), want[i] .. ' is missing: ' .. vim.inspect(got))
      end
    end,
  },

  -- A bad event name ---------------------------------------------------------

  {
    name = 'events: a bad event name is reported, and the rest still registers',
    fn = function()
      -- nvim_create_autocmd rejects the whole list, so the valid event used
      -- to go down with the typo, and the raise aborted every spec after it.
      test.stub_pack()
      local bad, good = fresh('ev-typo'), fresh('ev-after-typo')
      local ok, err
      local notices = capture_and_wait(function()
        ok, err = pcall(_G.resonance.load, {
          { src = 'https://github.com/test/' .. bad, event = { 'BufReadPost', 'TypoEvent' } },
          { src = 'https://github.com/test/' .. good, event = 'BufReadPost' },
        })
      end, 200)
      test.assert_true(ok, 'load() raised on a bad event name: ' .. tostring(err))
      test.assert_true(has(trigger_autocmds(bad), 'BufReadPost:*'),
        'the valid event went down with the typo: ' .. vim.inspect(trigger_autocmds(bad)))
      test.assert_true(has(trigger_autocmds(good), 'BufReadPost:*'),
        'the spec after the typo was not registered')
      test.assert_true(noticed(notices, "Invalid event 'TypoEvent' for " .. bad),
        'the error does not name the event and the plugin: ' .. vim.inspect(notices))
    end,
  },
})
