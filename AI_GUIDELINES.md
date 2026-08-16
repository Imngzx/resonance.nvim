# Resonance.nvim — AI Development Guidelines

> **Purpose**: Step-by-step reference for AI assistants working on this codebase.  
> **Audience**: Any AI agent (Cursor, Claude, Copilot, etc.) editing `resonance.nvim`.  
> **Last Updated**: 2026-08-16

---

## 1. Repository Overview

| Aspect | Detail |
|--------|--------|
| **Type** | Neovim plugin — lazy-loader + UI wrapper around native `vim.pack` (Neovim 0.13+) |
| **Entry Point** | `lua/resonance/init.lua` → `require('resonance').setup()` |
| **Core Modules** | `loader.lua` (install/load/lazy), `scanner.lua` (discovery), `ui/` (picker) |
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
```

---

## 3. Key Changes (2026-08-15)

### `scanner.lua` — Replaced O(n) Filesystem Walk with `vim.pack.get()`

| Before | After |
|--------|-------|
| Manual `fs_scandir` of `pack/*/{start,opt}/*` | `vim.pack.get({info=false, offline=true})` — 0.3ms |
| Heuristic loaded detection (`path ∈ rtp`) | Exact `p.active` from `vim.pack` |
| No pending update info | `rev_to`, `manifest`, `branches`, `tags` available |
| UI open: ~5000ms (blocking network) | UI open: ~15ms (offline cache) |

**API**:

```lua
-- Fast path (default): offline, no extra info
scanner.get_info() → { plugins={name,type,path,loaded,trigger,rev}, total, loaded, ... }

-- Detailed path (update checking): fetches rev_to, manifest, branches, tags
scanner.get_detailed_info() -- or scanner.get_info({info=true, offline=false})
```

**Fallback**: Original filesystem scan preserved when `vim.pack` unavailable (`vim.pack = nil`).

---

### `loader.lua` — Optimized `get_plugin_dir()` with Bulk Cache

| Before | After |
|--------|-------|
| Per-call filesystem walk on cache miss | Single `vim.pack.get({info=false, offline=true})` populates entire cache |
| ~0.1ms per miss | ~0.3ms total for all 43 plugins |

**Change**: `get_plugin_dir(name)` now tries `vim.pack.get()` first, falls back to original scan.

---

## 4. Benchmark Comparisons

### Startup Time (`vim-startuptime`, 10 runs, `-u NONE`)

| Version | Avg (ms) | Min (ms) | Max (ms) |
|---------|----------|----------|----------|
| Original scanner | 0.947 | 0.808 | 1.252 |
| **Optimized scanner** | **0.919** | **0.786** | **1.129** |
| Original loader | — | — | — |
| **Optimized loader** | **0.919** | **0.786** | **1.129** |

> **No startup regression** — lazy-loading happens post-setup.

### UI Open Time

| Version | Time |
|---------|------|
| Original scanner (online `vim.pack.get`) | ~5000 ms |
| **Optimized scanner (offline default)** | **~15 ms** |
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
read lua/resonance/loader.lua
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

### Step 4: Verify

```bash
# Functional tests
nvim --headless -c "luafile lua/resonance/init.lua" -c "lua require('resonance').setup(); local info=require('resonance.scanner').get_info(); print(info.total, info.loaded)" -c "qall"
nvim --headless -c "lua vim.pack=nil" -c "luafile lua/resonance/init.lua" -c "lua require('resonance').setup(); local info=require('resonance.scanner').get_info(); print('fallback:', info.total)" -c "qall"

# Benchmarks (must not regress)
vim-startuptime -count 10 -warmup 3 -- -u NONE -c "luafile ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/init.lua" -c "lua require('resonance').setup()" -c "qall"
```

### Step 5: Commit

```bash
cd /home/alice/Projects/code/lua/resonance.nvim
git add lua/resonance/scanner.lua lua/resonance/loader.lua
git commit -m "perf: optimize scanner/loader with vim.pack.get offline cache"
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

## 7. Common Tasks

### Add New Lazy Trigger Type

1. `loader.lua`: Extend `parse_trigger()` (lines 153-189)
2. `loader.lua`: Add autocmd/command/keymap in `M.load()` (lines 404-490)
3. `scanner.lua`: Add trigger icon fallback in `get_info()`

### Add UI Column/Action

1. `ui/state.lua`: Add field to `st.state`
2. `ui/actions.lua`: Add handler function
3. `ui/init.lua`: Add keymap in `map()` calls
4. `ui/render.lua`: Add column in `draw_plugin()`

### Modify Build System

- `loader.lua`: `M.build_hooks`, `M.run_build()`, `PackChanged` autocmd (lines 49-151)
- Respects `.resonance_built` hash cache

---

## 8. Debugging Checklist

| Symptom | Check |
|---------|-------|
| UI slow to open | `scanner.get_info()` using `offline=false`? |
| Plugin not loading | Trigger registered in `M.plugin_triggers`? `:packadd` called? |
| Build not running | `PackChanged` firing? `M.build_hooks[name]` set? |
| Startup regression | `vim-startuptime` — check `inits 1` time |
| Fallback broken | Test with `lua vim.pack=nil` |

---

## 9. Reference: `vim.pack` API Used

| Function | Purpose | Resonance Usage |
|----------|---------|-----------------|
| `vim.pack.add(specs, {confirm=false, load=false})` | Install plugins | `loader.lua:354` |
| `vim.pack.get(names?, {info, offline})` | Query installed | `scanner.lua`, `loader.lua`, `ui/actions.lua` |
| `vim.pack.update(names?, {force, offline})` | Update plugins | `ui/actions.lua:103` |
| `vim.pack.del(names, {force})` | Delete plugins | `ui/actions.lua:136` |
| `PackChanged` event | Build hooks | `loader.lua:133` |
| `vim.pack.Spec` fields | `src`, `name`, `version`, `data` | `loader.lua:191` normalize |

---

## 10. Sync Locations

| Source (Edit Here) | Installed (Test Here) |
|--------------------|----------------------|
| `/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/` | `~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/` |

**Always test in installed location** — that's what users run.

---

## 11. Emergency: Restore Original Files

```bash
# From git HEAD
cd /home/alice/Projects/code/lua/resonance.nvim
git show HEAD:lua/resonance/scanner.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/scanner.lua
git show HEAD:lua/resonance/loader.lua > ~/.local/share/nvim/site/pack/core/opt/resonance.nvim/lua/resonance/loader.lua
```

---

## 12. AI Workflow & Communication Patterns

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

**Rules:**

- Always read file first to get current `#HASH`
- Use `PUT N.=M:` for replacements, `PUT <N:`/`PUT >N:` for insertions
- Body rows start with `+` (literal `-` → `+-`)
- Never use `-` lines — the range defines what's removed
- After edit, re-read if doing sequential edits to same file

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

## 13. Recent Optimizations (2026-08-16)

### UI Render (`render.lua`)

| Optimization | Change |
|--------------|--------|
| Cached static button lines | `BUTTONS` table at module scope |
| Pre-computed type labels | `TYPE_LABELS = {opt='[opt]', start='[start]'}` |
| Cached `stats()` call | `_cached_stats` memoization |
| Pre-fetched src URLs | Async in `init.lua` `load_commits_async()` |

### Actions (`actions.lua`)

| Optimization | Change |
|--------------|--------|
| Localize `uv_hrtime` | `local uv_hrtime = vim.uv.hrtime` |
| All imports used | No dead code |
| `schedule` → `vim.defer_fn(..., 1)` | Spinner gets one event-loop tick |
| `finish_check` delayed 200ms | Spinner visible when no updates |

### State (`state.lua`)

| Addition | Purpose |
|----------|---------|
| `spinner_frame` | Module-global frame counter for 30fps animation |

---

*Generated 2026-08-15. Updated 2026-08-16 with AI workflow patterns.*
