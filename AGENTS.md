# Resonance.nvim — AI Development Guidelines

> **Purpose**: Step-by-step reference for AI assistants working on this codebase.  
> **Audience**: Any AI agent (Cursor, Claude, Copilot, etc.) editing `resonance.nvim`.  
> **Last Updated**: 2026-08-18

---

## 1. Repository Overview

| Aspect | Detail |
|--------|--------|
| **Type** | Neovim plugin — lazy-loader + UI wrapper around native `vim.pack` (Neovim 0.13+) |
| **Entry Point** | `lua/resonance/init.lua` → `require('resonance').setup()` |
| **Core Modules** | `loader/` (init, build, triggers, spec, dag), `scanner.lua` (discovery), `ui/` (picker) |
| **Install Location** | `~/.local/share/nvim/site/pack/core/opt/resonance.nvim/` (managed by `vim.pack`) |
| **Config Style** | Lazy specs with triggers: `event`, `cmd`, `keys`, `ft` |

---

## 2. Available Tools on This Machine

| Tool | Path | Purpose |
|------|------|---------|
| `vim-startuptime` | `~/go/bin/vim-startuptime` | **Primary benchmark** — measures Neovim startup with custom args |
| `rg` (ripgrep) | System `rg` | Fast code search (prefer over `grep`) |
| `nvim` | System `nvim` (0.13+) | Headless testing: `nvim --headless -c "..." -c "qall"` |
| `git` | System `git` | Version control, `git show HEAD:<file>` for original versions |
| `lua` | Embedded in `nvim` | All Lua execution via `nvim --headless -c "lua ..."` |
| `bash` and `fish` | Standard | Shell commands, pipelines |
| `lua-language-server` | `/usr/bin/lua-language-server` (pacman) | LSP diagnostics: `lua-language-server --check=FILE` |

### Benchmark Command Template

```bash
# Startup benchmark (10 runs, 3 warmup, no user config)
vim-startuptime -count 10 -warmup 3 -- -u NONE \
  -c "luafile ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/init.lua" \
  -c "lua require('resonance').setup()" -c "qall"

# UI open time measurement
nvim --headless -c "luafile lua/resonance/init.lua" \
  -c "lua require('resonance').setup(); local t=vim.uv.hrtime(); require('resonance').open_ui(); print('UI open:', (vim.uv.hrtime()-t)/1e6, 'ms')" -c "qall"

# Direct function timing
nvim --headless -c "lua local t=vim.uv.hrtime(); require('resonance.scanner').get_info(); print('get_info:', (vim.uv.hrtime()-t)/1e6, 'ms')" -c "qall"

# LSP diagnostics
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/loader/init.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/loader/build.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/loader/triggers.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/loader/spec.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/loader/dag.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/scanner.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/init.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/ui/init.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/ui/actions.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/ui/render.lua
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/ui/state.lua
```

---

## 3. Key Changes (2026-08-17)

### `scanner.lua` — Replaced O(n) Filesystem Walk with `vim.pack.get()`

| Before | After |
|--------|-------|
| Manual `fs_scandir` of `pack/*/{start,opt}/*` | `vim.pack.get({info=false, offline=true})` — 0.3ms |
| Heuristic loaded detection (`path ∈ rtp`) | Exact `p.active` from `vim.pack` |
| No pending update info | `rev_to`, `manifest`, `branches`, `tags` available |
| UI open: ~5000ms (blocking network) | UI open: ~12ms (offline cache + async) |

**API**:

```lua
-- Fast path (default): offline, no extra info
scanner.get_info() → { plugins={name,type,path,loaded,trigger,rev}, total, loaded, ... }

-- Detailed path (update checking): fetches rev_to, manifest, branches, tags
scanner.get_detailed_info() -- or scanner.get_info({info=true, offline=false})
```

**Fallback**: Original filesystem scan preserved when `vim.pack` unavailable (`vim.pack = nil`).

---

### `loader/` — Modular Loader (2026-08-16)

Split monolithic `loader.lua` into 5 focused modules under `lua/resonance/loader/`:

| Module | Responsibility |
|--------|----------------|
| `init.lua` | Main entry, `load()`, `get_plugin_dir()`, `get_dag_data()`, `get_replay_info()`, `_get_event_chain_internal()` |
| `build.lua` | Build hooks, `run_build()`, `check_and_build()`, `mark_build_success()`, `PackChanged` autocmd |
| `triggers.lua` | Trigger registration: `register_event()`, `register_cmd()`, `register_keys()`, `register_ft()`, `register_all()` |
| `spec.lua` | Config parsing: `parse_config()`, `extract_names()`, `normalize_pack_spec()` |
| `dag.lua` | DAG data: `get_dag_data()`, `get_replay_info()`, `_get_event_chain_internal()` |

**Key improvements over original**:
- `check_and_build()` — hash check before building (fixes redundant builds on PackChanged)
- Exported `mark_build_success()`, `setup_packchanged_autocmd()`, `get_plugin_dir()`
- `populate_plugin_dir_cache()` — bulk cache population via single `vim.pack.get()`
- All LSP diagnostics clean

---

### `ui/init.lua` — Optimized UI Open (2026-08-17)

Two-pass async loading:

| Pass | Call | Time | Purpose |
|------|------|------|---------|
| 1 (sync) | `vim.pack.get({info=false, offline=true})` | ~1ms | Commits, URLs, rev |
| 2 (deferred 50ms) | `vim.pack.get({info=true, offline=true})` | ~300ms | Branches, tags |

UI open: **330ms → 12ms** (27x faster)

---

### Build System Fixes (2026-08-17)

- `run_build()`: restored early-return hash check from `loader_original.lua`
- `PackChanged` autocmd: now uses `check_and_build()` instead of direct `run_build()`
- `update_plugins()`: changed `offline=true` → `offline=false` so updates actually download
- All build exports available via `require('resonance.loader')`

---

### Help Documentation (2026-08-17)

- `doc/resonance.txt` — comprehensive help with 18 tags
- `:help resonance`, `:help resonance-api-loader`, `:help resonance-triggers`, etc.

---

## 4. Benchmark Comparisons

### Startup Time (`vim-startuptime`, 10 runs, `-u NONE`)

| Version | Avg (ms) | Min (ms) | Max (ms) |
|---------|----------|----------|----------|
| Original scanner | 0.947 | 0.808 | 1.252 |
| **Optimized scanner** | **0.919** | **0.786** | **1.129** |
| **Modular loader (current)** | **0.87** | **0.77** | **1.27** |

> **No startup regression** — lazy-loading happens post-setup.

### UI Open Time

| Version | Time |
|---------|------|
| Original scanner (online `vim.pack.get`) | ~5000 ms |
| Optimized scanner (offline default) | ~15 ms |
| **Two-pass async (current)** | **~12 ms** |
| Fallback (`vim.pack = nil`) | ~15 ms |

### `vim.pack.get()` Latency

| Call | Time |
|------|------|
| `info=true, offline=false` (network) | ~2150 ms |
| `info=true, offline=true` | ~318 ms |
| `info=false, offline=true` (default) | **~0.3 ms** |
| Filesystem scan (43 plugins) | **~0.1 ms** |

---

## 5. Development Workflow

### Step 1: Read & Understand

```bash
# Read core modules
read lua/resonance/loader/init.lua
read lua/resonance/loader/build.lua
read lua/resonance/loader/triggers.lua
read lua/resonance/loader/spec.lua
read lua/resonance/loader/dag.lua
read lua/resonance/scanner.lua
read lua/resonance/init.lua
read lua/resonance/ui/init.lua
read lua/resonance/ui/actions.lua
read lua/resonance/ui/render.lua
read lua/resonance/ui/state.lua
```

### Step 2: Test Current Behavior

```bash
# Quick smoke test
nvim --headless -c "luafile lua/resonance/init.lua" -c "lua require('resonance').setup(); require('resonance').load({src='https://github.com/neovim/nvim-lspconfig', event='LspAttach'})" -c "qall"

# Run benchmarks
vim-startuptime -count 10 -warmup 3 -- -u NONE -c "luafile ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/init.lua" -c "lua require('resonance').setup()" -c "qall"
```

### Step 3: Make Changes

- Edit files in **project root** (`/home/alice/Projects/code/lua/resonance.nvim/`)
- Test in **installed location** (`~/.local/share/nvim/site/pack/core/opt/resonance.nvim/`)
- Sync: `cp lua/resonance/*.lua ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/`
- Sync loader: `cp lua/resonance/loader/*.lua ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader/`
- Sync UI: `cp lua/resonance/ui/*.lua ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/ui/`

### Step 4: Verify

```bash
# Functional tests
nvim --headless -c "luafile lua/resonance/init.lua" -c "lua require('resonance').setup(); local info=require('resonance.scanner').get_info(); print(info.total, info.loaded)" -c "qall"
nvim --headless -c "lua vim.pack=nil" -c "luafile lua/resonance/init.lua" -c "lua require('resonance').setup(); local info=require('resonance.scanner').get_info(); print('fallback:', info.total)" -c "qall"

# LSP diagnostics (lua-language-server via pacman)
lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/loader/init.lua

# Benchmarks (must not regress)
vim-startuptime -count 10 -warmup 3 -- -u NONE -c "luafile ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/init.lua" -c "lua require('resonance').setup()" -c "qall"
```

### Step 5: Commit

```bash
cd /home/alice/Projects/code/lua/resonance.nvim
git add lua/resonance/loader/ lua/resonance/scanner.lua lua/resonance/ui/init.lua doc/
git commit -m "perf: modular loader + UI async + build fixes"
```

---

## 6. Critical Patterns & Conventions

### `vim.pack` Integration Rules

1. **Always guard**: `if vim.pack and vim.pack.get then ... end`
2. **Default to offline**: `vim.pack.get(nil, {info=false, offline=true})` for speed
3. **Use `PackChanged` for build hooks** — not polling
4. **Never call `vim.pack.add()` with `load=true` during init** — Resonance controls loading via `:packadd`

### Performance Rules

- **No filesystem walks in hot paths** — use `vim.pack.get()` cache
- **Lazy-require heavy modules** — `package.loaded['x'] or require('x')`
- **Batch operations** — `pack_add()` accepts array, call once
- **Schedule async work** — `vim.schedule()` for git/system calls

### Lua Style (Project Conventions)

- Localize globals at top: `local uv = vim.uv`, `local fs_scandir = uv.fs_scandir`
- Avoid `vim.fn` in hot paths — use `vim.uv` / `vim.system`
- Tables over multiple returns: `{name=..., path=..., loaded=...}`
- Use luajit syntax
- Early returns, flat conditionals
- Comments only for *why*, not *what*

---

## 7. LuaJIT Low-Level Code Style (MANDATORY)

### Core Principles

1. **No wrapper functions** — call C APIs directly, avoid indirection
2. **Localize EVERYTHING at module top** — all `vim.*`, `string.*`, `table.*`, `math.*`, `os.*`, `io.*`, `pcall`
3. **Use numeric `for` loops** — `for i = 1, #t do` NOT `ipairs()` or `pairs()` or `vim.iter()`
4. **Manual index tracking** — use `li = #lines + 1` / `lines[li] = ...; li = li + 1` instead of `#lines + 1`
5. **Pre-compute lookup tables** — 256-char URL encode map, kana normalization table
6. **Memoization** — cache expensive computations (`get_key()` with `_key_memo`)
7. **Short variable names** — `sfmt`, `sbyte`, `sgsub`, `vnotif`, `vsched`, `vlog` (standard in this codebase)
8. **Inline hot functions** — `spacer()` inlined in `response.lua`
9. **Avoid table constructors in loops** — reuse tables, pre-allocate when possible
10. **Early returns** — reduce nesting depth
11. **Direct module requires** — `local c = require('resonance.loader.cache')` not lazy loading in hot paths

### Required Localization Pattern (at top of EVERY module)

```lua
-- Standard library
local sfmt = string.format
local sbyte = string.byte
local sgsub = string.gsub
local slower = string.lower
local ssub = string.sub
local schar = string.char
local sconcat = table.concat
local math_min = math.min
local mfloor = math.floor
local otime = os.time
local pcall = pcall
local iopen = io.open

-- Neovim C APIs (vim.*)
local uv = vim.uv
local vfn = vim.fn
local vfsn = vim.fs.normalize
local vnotif = vim.notify
local vsched = vim.schedule
local vlog = vim.log.levels
local vjson_dec = vim.json.decode
local vjson_enc = vim.json.encode
local vnet_req = vim.net and vim.net.request
local vsys = vim.system
local vexpand = vim.fn.expand
local strim = vim.trim
local sfind = string.find
local srequire = require

-- vim.api (localize individually)
local vapi = vim.api
local nwin_gc = vapi.nvim_win_get_cursor
local nbuf_gl = vapi.nvim_buf_get_lines
local nwin_sc = vapi.nvim_win_set_cursor
local nbuf_cr = vapi.nvim_create_buf
local nbuf_sl = vapi.nvim_buf_set_lines
local nwin_op = vapi.nvim_open_win
local nbuf_iv = vapi.nvim_buf_is_valid
local nwin_iv = vapi.nvim_win_is_valid
local nwin_cl = vapi.nvim_win_close
local napi_ea = vapi.nvim_exec_autocmds
local nbuf_at = vapi.nvim_buf_attach

-- vim.* options (modern Neovim 0.13+)
local vo = vim.o
local vbo = vim.bo
local vwo = vim.wo
local vkmap = vim.keymap.set
local vcmd = vim.cmd
```

### Loop Patterns (Use These)

```lua
-- ✅ GOOD: Numeric for loop
for i = 1, #data do
  local item = data[i]
  -- ...
end

-- ✅ GOOD: Reverse numeric loop
for i = #targs, 1, -1 do
  local b = targs[i]
  -- ...
end

-- ✅ GOOD: Manual index for line building
local lines = {}
local li = 1
lines[li] = sfmt('## %s', w)
li = li + 1

-- ❌ BAD: ipairs/pairs in hot paths
for i, v in ipairs(t) do ... end

-- ❌ BAD: vim.iter in hot paths
vim.iter(t):each(function(v) ... end)

-- ❌ BAD: #lines + 1 in tight loops
lines[#lines + 1] = x
```

### Memoization Pattern

```lua
local _memo = {}

local function get_key(w)
  local m = _memo[w]
  if m then return m end
  -- compute...
  _memo[w] = result
  return result
end

local function clear_memo()
  _memo = {}
end
```

### Pre-computed Lookup Tables

```lua
local _url_map = {}
for i = 0, 255 do
  local c = schar(i)
  if c:match('[%w%-_%.~]') then
    _url_map[i] = c
  elseif c == ' ' then
    _url_map[i] = '+'
  elseif c == '\n' then
    _url_map[i] = '%0D%0A'
  else
    _url_map[i] = sfmt('%%%02X', i)
  end
end

local function urlencode(str)
  if not str then return '' end
  return sgsub(str, '.', function(c)
    return _url_map[sbyte(c)]
  end)
end
```

### Spinner Timer (LuaJIT-friendly)

```lua
spin_idx = (spin_idx % 10) + 1  -- hardcoded #spin_frames = 10
local frame = spin_frames[spin_idx]
```

### Modern Neovim APIs (Neovim 0.13+)

```lua
-- ✅ GOOD: Direct vim.bo/vim.wo
vbo[buf].filetype = 'markdown'
vbo[buf].modifiable = false
vwo[win].wrap = true
vwo[win].conceallevel = 2

-- ❌ BAD: Deprecated
vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')
vim.api.nvim_win_set_option(win, 'wrap', true)
```

### Async Notifications (Avoid Fast-Event-Context Errors)

```lua
-- ✅ ALWAYS wrap vim.notify in vim_schedule
vsched(function()
  vnotif('✓ Query successful: ' .. w, vlog.INFO, { title = 'Jisho.org', id = 'jisho_req', timeout = 10 })
end)
```

---

## 8. Common Tasks

### Add New Lazy Trigger Type

1. `loader/triggers.lua`: Add `register_<type>()` function
2. `loader/triggers.lua`: Add to `register_all()`
3. `loader/init.lua`: Ensure trigger registered in `M.load()`
4. `scanner.lua`: Add trigger icon fallback in `get_info()`

### Add UI Column/Action

1. `ui/state.lua`: Add field to `st.state`
2. `ui/actions.lua`: Add handler function
3. `ui/init.lua`: Add keymap in `map()` calls
4. `ui/render.lua`: Add column in `draw_plugin()`

### Modify Build System

- `loader/build.lua`: `M.build_hooks`, `M.run_build()`, `M.check_and_build()`, `PackChanged` autocmd
- `loader/init.lua`: Export build functions
- Respects `.resonance_built` hash cache
- `offline=false` for `update_plugins()` to trigger PackChanged

---

## 9. Debugging Checklist

| Symptom | Check |
|---------|-------|
| UI slow to open | `scanner.get_info()` using `offline=false`? |
| Plugin not loading | Trigger registered in `M.plugin_triggers`? `:packadd` called? |
| Build not running | `PackChanged` firing? `M.build_hooks[name]` set? |
| Startup regression | `vim-startuptime` — check `inits 1` time |
| Fallback broken | Test with `lua vim.pack=nil` |

---

## 10. Reference: `vim.pack` API Used

| Function | Purpose | Resonance Usage |
|----------|---------|-----------------|
| `vim.pack.add(specs, {confirm=false, load=false})` | Install plugins | `loader/init.lua:354` |
| `vim.pack.get(names?, {info, offline})` | Query installed | `scanner.lua`, `loader/init.lua`, `ui/actions.lua` |
| `vim.pack.update(names?, {force, offline})` | Update plugins | `ui/actions.lua:103` |
| `vim.pack.del(names, {force})` | Delete plugins | `ui/actions.lua:136` |
| `PackChanged` event | Build hooks | `loader/build.lua:95` |
| `vim.pack.Spec` fields | `src`, `name`, `version`, `data` | `loader/spec.lua` normalize |

---

## 11. Sync Locations

| Source (Edit Here) | Installed (Test Here) |
|--------------------|----------------------|
| `/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/` | `~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/` |
| `/home/alice/Projects/code/lua/resonance.nvim/doc/` | `~/.local/share/nvim/site/pack/core/opt/resonance.nvim/doc/` |

**Always test in installed location** — that's what users run.

---

## 12. Emergency: Restore Original Files

```bash
# From git HEAD
cd /home/alice/Projects/code/lua/resonance.nvim
git show HEAD:lua/resonance/scanner.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/scanner.lua
git show HEAD:lua/resonance/loader/init.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader/init.lua
git show HEAD:lua/resonance/loader/build.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader/build.lua
git show HEAD:lua/resonance/loader/triggers.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader/triggers.lua
git show HEAD:lua/resonance/loader/spec.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader/spec.lua
git show HEAD:lua/resonance/loader/dag.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader/dag.lua
git show HEAD:lua/resonance/init.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/init.lua
git show HEAD:lua/resonance/ui/init.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/ui/init.lua
git show HEAD:lua/resonance/ui/actions.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/ui/actions.lua
git show HEAD:lua/resonance/ui/render.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/ui/render.lua
git show HEAD:lua/resonance/ui/state.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/ui/state.lua
```

---

## 13. AI Workflow & Communication Patterns

### Todo System (Mandatory for Multi-Step Work)

**Initialize at start of any multi-step task:**

```lua
todo(i="Brief purpose", op="init", list=[{"phase": "PhaseName", "items": ["Task 1", "Task 2"]}])
```

**Update as work progresses:**

```lua
todo(i="Task description", op="start", task="Task 1", phase="PhaseName")
todo(i="Task description", op="done", task="Task 1", phase="PhaseName")
```

**Phase transitions are automatic** — earliest incomplete task in phase order becomes active.

**Purpose:** Gives user clear visibility into what's being worked on, what's done, and what's next.

---

### Code Editing Patterns

#### Use `edit` tool with anchored patches (not `write` for modifications)

```lua
edit(i="Purpose", input=[[
*** Begin Patch
[lua/resonance/ui/render.lua#HASH]
PUT 25.=25:
+local NEW_CONSTANT = 'value'
PUT 100.=100:
  local x = NEW_CONSTANT
*** End Patch
]])
```

#### Use `write` only for

- New files
- Complete rewrites (when patch would be >50% of file)
- Generated files

---

### Benchmark-Driven Development

**Every performance change must:**

1. Measure baseline with `vim-startuptime -count 10 -warmup 3`
2. Make change
3. Re-measure — **no regression allowed**
4. Document before/after in commit message

**UI timing test template:**

```bash
nvim --headless -c "luafile lua/resonance/init.lua" \
  -c "lua require('resonance').setup(); local t=vim.uv.hrtime(); require('resonance').open_ui(); print('UI open:', (vim.uv.hrtime()-t)/1e6, 'ms')" -c "qall"
```

---

### Sync Discipline

| Action | Command |
|--------|---------|
| Sync single file | `cp lua/resonance/ui/render.lua ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/ui/render.lua` |
| Sync all UI | `cp lua/resonance/ui/*.lua ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/ui/` |
| Sync all core | `cp lua/resonance/*.lua ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/` |
| Sync loader | `cp lua/resonance/loader/*.lua ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader/` |

**Always test in installed location** — user runtime environment.

---

### Testing Patterns

#### Headless UI test (with frame capture)

```bash
nvim --headless -c "set rtp+=/home/alice/Projects/code/lua/resonance.nvim" \
  -c "lua require('resonance').setup(); require('resonance').open_ui(); local a=require('resonance.ui.actions'); a.check_updates_network(); local st=require('resonance.ui.state'); for i=1,12 do vim.wait(50); local buf=st.state.buf; if buf then local lines=vim.api.nvim_buf_get_lines(buf, 11, 14, false); print('T+'..(i*50)..'ms checking='..tostring(st.state.checking)..' frame='..st.state.spinner_frame..' '..vim.inspect(lines[1])) end end" -c "sleep 5000m" -c "qall"
```

#### Fallback test (no vim.pack)

```bash
nvim --headless -c "lua vim.pack=nil" -c "luafile lua/resonance/init.lua" -c "lua require('resonance').setup(); local info=require('resonance.scanner').get_info(); print('fallback:', info.total)" -c "qall"
```

#### Load test

```bash
nvim --headless -c "luafile lua/resonance/init.lua" -c "lua require('resonance').setup(); require('resonance').load({src='https://github.com/neovim/nvim-lspconfig', event='LspAttach'})" -c "qall"
```

---

*Generated 2026-08-15. Updated 2026-08-17 with modular loader, build fixes, UI async, help docs. Updated 2026-08-18 with LuaJIT low-level optimization patterns.*