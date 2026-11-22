-- spec shapes and loader edge cases
--
-- Part of the resonance.nvim behavioral suite.
--
-- Run with: nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_specs_spec.lua" -c "lua test.print_summary()" -c "qall"

local api = vim.api
local h = dofile('test/helpers.lua')
local capture_and_wait = h.capture_and_wait
local noticed = h.noticed

local run_id = tostring(vim.uv.hrtime())
local function fresh(label)
  return label .. '-' .. run_id
end

-- The specs handed to vim.pack.add across every call the stub saw.
local function added_specs(stub)
  local out = {}
  for i = 1, #stub.calls do
    local call = stub.calls[i]
    for j = 1, #call do out[#out + 1] = call[j] end
  end
  return out
end

local function find_added(stub, name)
  local specs = added_specs(stub)
  for i = 1, #specs do
    local s = specs[i]
    local src = type(s) == 'string' and s or (s.src or s[1])
    if src and src:find(name, 1, true) then return s end
  end
  return nil
end

test.run_suite('resonance.behavior.specs', {

  -- 2.11a: a single spec whose plugin is written as its first element ------

  {
    name = 'specs: { { url }, lazy = false, dependencies = ... } is one spec',
    fn = function()
      -- It used to be read as a list of specs, and lazy, dependencies, cond,
      -- build and version were silently dropped.
      test.stub_pack()
      local main, dep = fresh('one-spec'), fresh('one-spec-dep')
      _G.resonance.load({
        { 'https://github.com/test/' .. main },
        lazy = false,
        dependencies = { 'https://github.com/test/' .. dep },
      })
      local spec = _G.loader.specs[main]
      test.assert_not_nil(spec, 'the spec was not registered under its plugin name')
      test.assert_not_nil(spec.dependencies, 'the dependencies were dropped')
      test.assert_eq(spec.event, 'VimEnter', 'lazy = false was dropped')
    end,
  },

  {
    name = 'specs: a list of specs is still a list',
    fn = function()
      test.stub_pack()
      local a, b = fresh('list-a'), fresh('list-b')
      test.assert_true(require('resonance.loader.spec').is_plugin_list({ { 'x' }, { 'y' } }))
      _G.resonance.load({
        { 'https://github.com/test/' .. a, event = 'BufReadPost' },
        { 'https://github.com/test/' .. b, cmd = 'ListB' .. run_id:sub(-4) },
      })
      test.assert_not_nil(_G.loader.specs[a], 'the first spec of the list was not registered')
      test.assert_not_nil(_G.loader.specs[b], 'the second spec of the list was not registered')
    end,
  },

  -- 2.11b: plugin = { url, version = ... } ----------------------------------

  {
    name = "specs: plugin = { 'url', version = ... } keeps the version",
    fn = function()
      -- The table was read as a list of plugins, and vim.pack.add received
      -- the bare URL: the pin was silently ignored.
      local stub = test.stub_pack()
      local name = fresh('pinned')
      local cmd = 'Pinned' .. run_id:sub(-4)
      _G.resonance.load({ plugin = { 'https://github.com/test/' .. name, version = 'v1.0.0' }, cmd = cmd })
      pcall(vim.cmd, cmd)
      local added = find_added(stub, name)
      test.assert_not_nil(added, 'the plugin was never installed')
      test.assert_eq(type(added) == 'table' and added.version or nil, 'v1.0.0',
        'the version did not reach vim.pack.add: ' .. vim.inspect(added))
    end,
  },

  {
    name = "specs: plugin = { 'url1', 'url2' } is still two plugins",
    fn = function()
      local stub = test.stub_pack()
      local a, b = fresh('pair-a'), fresh('pair-b')
      local cmd = 'Pair' .. run_id:sub(-4)
      _G.resonance.load({
        plugin = { 'https://github.com/test/' .. a, 'https://github.com/test/' .. b },
        cmd = cmd,
      })
      test.assert_not_nil(_G.loader.specs[a], 'the first plugin is missing')
      test.assert_not_nil(_G.loader.specs[b], 'the second plugin is missing')
      pcall(vim.cmd, cmd)
      test.assert_not_nil(find_added(stub, a), 'the first plugin was not installed')
      test.assert_not_nil(find_added(stub, b), 'the second plugin was not installed')
    end,
  },

  -- 2.2: a spec with no plugin ------------------------------------------------

  {
    name = 'specs: a spec with no plugin is reported, and firing its event does not crash',
    fn = function()
      -- Its trigger used to be registered, and crashed with "table index is
      -- nil" in load_now when it fired.
      test.stub_pack()
      local pattern = 'Nameless' .. run_id:sub(-4)
      local ran = false
      local notices = capture_and_wait(function()
        _G.resonance.load({ event = { 'User', pattern = pattern }, setup = function() ran = true end })
      end, 100)
      test.assert_true(noticed(notices, 'Spec has no plugin'), 'the nameless spec was not reported: ' .. vim.inspect(notices))
      local errors = {}
      local ok, err = pcall(api.nvim_exec_autocmds, 'User', { pattern = pattern })
      test.assert_true(ok, 'firing the event raised: ' .. tostring(err))
      local autocmds = api.nvim_get_autocmds({ event = 'User', pattern = pattern })
      for i = 1, #autocmds do
        if (autocmds[i].group_name or ''):find('^Resonance_') then errors[#errors + 1] = autocmds[i].group_name end
      end
      test.assert_eq(#errors, 0, 'a trigger was registered for the nameless spec: ' .. vim.inspect(errors))
      test.assert_false(ran, 'the setup ran for a spec with no plugin')
    end,
  },

  -- 2.3: a failed member does not unload one that was already loaded --------

  {
    name = 'specs: a failed member install leaves an already-loaded member loaded',
    fn = function()
      local a, b = fresh('memA'), fresh('memB')
      test.stub_pack({ add_error = function(n) return n == b end })
      _G.loader._internal.plugin_state[a] = { loaded = true }
      local cmd = 'Members' .. run_id:sub(-4)
      _G.resonance.load({ plugin = { 'https://github.com/test/' .. a, 'https://github.com/test/' .. b }, cmd = cmd })
      capture_and_wait(function() pcall(vim.cmd, cmd) end, 100)
      test.assert_true(_G.loader._internal.plugin_state[a].loaded,
        "the other member's failure marked the loaded member as unloaded")
    end,
  },

  -- 2.9: one command spec table, shown for a disabled plugin ----------------

  {
    name = 'specs: a disabled plugin with one command spec table shows the command',
    fn = function()
      test.stub_pack()
      local name = fresh('disabled-cmd')
      _G.resonance.load({
        src = 'https://github.com/test/' .. name,
        cond = false,
        cmd = { name = 'Neogit', opts = { nargs = 0 } },
      })
      local d = _G.loader.disabled_plugins[name]
      test.assert_not_nil(d, 'the plugin was not recorded as disabled')
      test.assert_contains(d.trigger, 'Neogit', 'the command is missing from the trigger')
    end,
  },

  -- 2.10: the command stub ----------------------------------------------------

  {
    name = 'specs: a failed install keeps the command, and :vertical does not raise',
    fn = function()
      -- The stub deleted itself before the load, so the command was gone
      -- for the rest of the session. With a modifier, re-parsing the command
      -- line raised an uncaught E492.
      local name = fresh('cmd-fail')
      test.stub_pack({ add_error = 'network down' })
      local cmd = 'CmdFail' .. run_id:sub(-4)
      _G.resonance.load({ src = 'https://github.com/test/' .. name, cmd = cmd })
      local ok, err
      capture_and_wait(function() ok, err = pcall(vim.cmd, 'vertical ' .. cmd) end, 100)
      test.assert_true(ok, ':vertical raised after a failed install: ' .. tostring(err))
      test.assert_eq(vim.fn.exists(':' .. cmd), 2, 'the command is gone after one failed install')
    end,
  },

  {
    name = 'specs: modifiers and arguments reach the real command',
    fn = function()
      test.stub_pack()
      local name = fresh('cmd-mods')
      local cmd = 'CmdMods' .. run_id:sub(-4)
      local seen = nil
      _G.resonance.load({
        src = 'https://github.com/test/' .. name,
        cmd = cmd,
        setup = function()
          api.nvim_create_user_command(cmd, function(a)
            seen = { vertical = a.smods.vertical, args = a.args }
          end, { nargs = '*' })
        end,
      })
      capture_and_wait(function() vim.cmd('vertical ' .. cmd .. ' hello') end, 100)
      test.assert_not_nil(seen, 'the real command never ran')
      test.assert_true(seen.vertical, ':vertical did not reach the real command')
      test.assert_eq(seen.args, 'hello')
    end,
  },

  {
    name = 'specs: several words reach a one-argument command as one argument',
    fn = function()
      -- The stub takes any number of arguments and split them on
      -- whitespace. A real command with nargs 1 or ? then got three
      -- arguments for `:Git commit -m x` and raised "Wrong number of
      -- arguments": the plugin loaded, the command did not run.
      test.stub_pack()
      local nargs_list = { '?', 1 }
      for n = 1, #nargs_list do
        local name = fresh('cmd-one-arg-' .. n)
        local cmd = 'CmdOneArg' .. n .. run_id:sub(-4)
        local seen = nil
        _G.resonance.load({
          src = 'https://github.com/test/' .. name,
          cmd = cmd,
          setup = function()
            api.nvim_create_user_command(cmd, function(a) seen = a.args end,
              { nargs = nargs_list[n] })
          end,
        })
        local notices = capture_and_wait(function() vim.cmd(cmd .. ' commit -m msg') end, 100)
        test.assert_false(noticed(notices, 'Wrong number of arguments'),
          'nargs=' .. tostring(nargs_list[n]) .. ': ' .. vim.inspect(notices))
        test.assert_eq(seen, 'commit -m msg', 'nargs=' .. tostring(nargs_list[n]))
      end
    end,
  },

  -- a spec registered after startup ------------------------------------------

  {
    name = 'specs: an eager or triggerless spec registered after VimEnter still loads',
    fn = function()
      -- Both get a VimEnter trigger, and VimEnter does not come twice: the
      -- spec was registered and then never loaded, with no message.
      -- The suite runs before VimEnter, so the test stands in for a session
      -- that has started.
      test.stub_pack()
      local a, b, c = fresh('late-plain'), fresh('late-eager'), fresh('late-event')
      local ran = {}
      local orig = _G.loader._startup_over
      _G.loader._startup_over = function() return true end
      local ok, err = pcall(_G.resonance.load, {
        { src = 'https://github.com/test/' .. a, setup = function() ran.plain = true end },
        { src = 'https://github.com/test/' .. b, lazy = false, setup = function() ran.eager = true end },
        { src = 'https://github.com/test/' .. c, event = 'BufReadPost', setup = function() ran.event = true end },
      })
      _G.loader._startup_over = orig
      test.assert_true(ok, tostring(err))
      test.assert_eq(ran.plain, nil, 'load() must return before the plugin loads, as at startup')
      vim.wait(500, function() return ran.plain and ran.eager end, 10)
      test.assert_true(ran.plain, 'the spec with no trigger never loaded')
      test.assert_true(ran.eager, 'the lazy = false spec never loaded')
      test.assert_eq(ran.event, nil, 'a spec waiting for an ordinary event was loaded too')
    end,
  },

  {
    name = 'specs: a lazy = true spec registered after VeryLazy still loads',
    fn = function()
      test.stub_pack()
      local first, late, both = fresh('vl-first'), fresh('vl-late'), fresh('vl-late-cmd')
      local fired = false
      local ran = {}
      api.nvim_create_autocmd('User', { pattern = 'VeryLazy', once = true, callback = function() fired = true end })
      _G.resonance.load({ src = 'https://github.com/test/' .. first, lazy = true })
      -- Headless, VimEnter is what ends startup and fires VeryLazy.
      api.nvim_exec_autocmds('VimEnter', { group = 'ResonanceVeryLazy' })
      vim.wait(500, function() return fired end, 10)
      test.assert_true(fired, 'VeryLazy did not fire in the test session')

      _G.resonance.load({
        { src = 'https://github.com/test/' .. late, lazy = true, setup = function() ran.late = true end },
        -- VeryLazy is the fallback of a spec with another trigger, and it
        -- is just as gone.
        {
          src = 'https://github.com/test/' .. both,
          lazy = true,
          cmd = 'VlLate' .. run_id:sub(-4),
          setup = function() ran.both = true end,
        },
      })
      vim.wait(500, function() return ran.late and ran.both end, 10)
      test.assert_true(ran.late, 'the lazy = true spec never loaded')
      test.assert_true(ran.both, 'the lazy = true spec with a command never loaded')
    end,
  },

  -- a bad keys entry ---------------------------------------------------------

  {
    name = 'specs: a bad keys entry is reported and the rest still registers',
    fn = function()
      -- { lhs, rhs } is lazy.nvim's order; here the lhs is read as the mode
      -- and vim.keymap.set raises "Invalid mode shortname". The raise left
      -- load() half-way: the second spec was never registered.
      test.stub_pack()
      local a, b = fresh('bad-keys-a'), fresh('bad-keys-b')
      local good_lhs = '<Plug>(GoodKey' .. run_id:sub(-4) .. ')'
      local ok, err
      local notices = capture_and_wait(function()
        ok, err = pcall(_G.resonance.load, {
          {
            src = 'https://github.com/test/' .. a,
            keys = {
              { '<leader>zz', '<cmd>echo 1<CR>', desc = 'lazy.nvim order' },
              { 'n', good_lhs, '<cmd>echo 2<CR>' },
            },
          },
          { src = 'https://github.com/test/' .. b, cmd = 'BadKeysB' .. run_id:sub(-4) },
        })
      end, 100)
      test.assert_true(ok, 'load() raised: ' .. tostring(err))
      test.assert_true(noticed(notices, 'Invalid keys entry'), 'the bad entry was not reported: ' .. vim.inspect(notices))
      test.assert_true(noticed(notices, a), 'the report does not name the plugin: ' .. vim.inspect(notices))
      test.assert_not_nil(_G.loader.specs[b], 'the spec after the bad entry was not registered')
      test.assert_true(vim.fn.maparg(good_lhs, 'n') ~= '' or vim.fn.mapcheck(good_lhs, 'n') ~= '',
        'the valid entry of the same spec was not mapped')
      pcall(vim.keymap.del, 'n', good_lhs)
    end,
  },

  {
    name = 'specs: a keys function may return shorthand strings, and one that raises is reported',
    fn = function()
      test.stub_pack()
      local a, b, c = fresh('keys-fn-a'), fresh('keys-fn-b'), fresh('keys-fn-c')
      local lhs = '<Plug>(FnKey' .. run_id:sub(-4) .. ')'
      local ok, err
      local notices = capture_and_wait(function()
        ok, err = pcall(_G.resonance.load, {
          { src = 'https://github.com/test/' .. a, keys = function() return { lhs, 42 } end },
          { src = 'https://github.com/test/' .. b, keys = function() error('keys blew up') end },
          { src = 'https://github.com/test/' .. c, cmd = 'KeysFnC' .. run_id:sub(-4) },
        })
      end, 100)
      test.assert_true(ok, 'load() raised: ' .. tostring(err))
      test.assert_true(vim.fn.mapcheck(lhs, 'n') ~= '', 'the shorthand returned by the function was not mapped')
      test.assert_true(noticed(notices, 'Invalid keys entry 42'), vim.inspect(notices))
      test.assert_true(noticed(notices, 'keys blew up'), vim.inspect(notices))
      test.assert_not_nil(_G.loader.specs[c], 'the spec after the raising function was not registered')
      pcall(vim.keymap.del, 'n', lhs)
    end,
  },

  {
    name = 'specs: a command the plugin never defines is reported, not run',
    fn = function()
      test.stub_pack()
      local name = fresh('cmd-missing')
      local cmd = 'CmdMissing' .. run_id:sub(-4)
      _G.resonance.load({ src = 'https://github.com/test/' .. name, cmd = cmd })
      local notices = capture_and_wait(function() pcall(vim.cmd, cmd) end, 100)
      test.assert_true(noticed(notices, 'is not defined after loading'),
        'the missing command was not reported: ' .. vim.inspect(notices))
      test.assert_false(noticed(notices, 'E492'), 'the missing command was run anyway: ' .. vim.inspect(notices))
    end,
  },
})
