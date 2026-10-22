# resonance.nvim — AI Agent Knowledge Base

> **Purpose**: Enable future AI agents to work on this codebase without re-discovering patterns.
> **Last Updated**: 2026-10-22

---

## 1. Module Map

| File | Responsibility |
|------|----------------|
| `lua/resonance/init.lua` | Public API: `setup()`, `load()`, `stats()`, `open_ui()`, `trigger_verylazy()` |
| `lua/resonance/loader/init.lua` | Core: DAG resolution, lazy triggers, event replay, build hooks (entry point) |
| `lua/resonance/loader/spec.lua` | Plugin config parsing, name extraction, spec normalization |
| `lua/resonance/loader/triggers.lua` | Event/cmd/keys/ft trigger registration |
| `lua/resonance/loader/build.lua` | Build hooks, run_build, check_and_build, PackChanged handler |
| `lua/resonance/loader/dag.lua` | DAG data, replay info, event chain |
| `lua/resonance/scanner.lua` | Plugin discovery: scans `vim.pack` directories, extracts metadata |
| `lua/resonance/utils.lua` | Shared utilities: `extract_name()`, `normalize_pack_spec()`, `parse_trigger()`, `parse_dependencies()`, `notify()`, `fast_normalize()` |
| `lua/resonance/ui/init.lua` | UI entry: window/buffer creation, key bindings |
| `lua/resonance/ui/render.lua` | Rendering: list view + DAG view, extmark highlights |
| `lua/resonance/ui/state.lua` | UI state: `view_mode`, `dag_data`, `replay_info`, helpers |
| `lua/resonance/ui/actions.lua` | Actions: update, uninstall, checkout, search, dir |

---

## 2. Key Architecture Patterns

### Plugin Spec (via `resonance.load()`)

```lua
resonance.load({
  {
    src = "https://github.com/owner/repo",
    name = "custom-name",        -- optional
    version = "branch|tag|commit",
    event = "BufReadPre",        -- or { "BufReadPre", "BufNewFile" }
    cmd = "Telescope",           -- or { "Cmd1", "Cmd2" }
    ft = "markdown",             -- or { "ft1", "ft2" }
    keys = { { "n", "<leader>f", "Telescope find_files" } },
    dependencies = { "https://github.com/owner/dep" },
    build = "make",              -- or function()
    config = function()          -- called after packadd
      require('plugin').setup({...})
    end,
  }
})
```

### Lazy Trigger Resolution (loader/)

| Trigger | Mechanism |
|---------|-----------|
| `event` | `create_autocmd(event, { once=true, callback=load_now })` |
| `cmd` | `create_user_command(cmd, wrapper)` — wrapper deletes command, loads, re-executes |
| `keys` | `set_keymap(mode, lhs, wrapper)` — wrapper deletes keymap, loads, executes RHS |
| `ft` | `create_autocmd('FileType', { pattern=ft, once=true, callback=load_now })` |

### DAG Resolution

```lua
-- Recursive DFS with cycle detection (FIXED: ordered path tracking + abort on cycle)
load_now(ev, visiting_path)
  -- Initialize visiting_path with _order array for cycle path tracking
  if visiting_path[current_name] then
    -- Build cycle path in order: A -> B -> A
    notify('Circular dependency detected: A -> B -> A (aborting)', ERROR)
    return
  end
  visiting_path[current_name] = true
  path_order[#path_order + 1] = current_name

  if state.loaded then return end
  state.loaded = true

  for dep in deps do
    -- Always call _force_load to check visiting_path for cycles
    -- load_now early-returns if already loaded
    M.specs[dep.name]._force_load(nil, visiting_path)
  end
  -- pack_add + packadd + setup()
```

### Event Replay

When plugin loads via `event` trigger, autocmds for that event may have already fired.

```lua
-- Re-fires chain: BufReadPre → BufRead → BufReadPost
for c in chain do
  exec_autocmds(c.event, { buf=c.buf, group=c.group, data=c.data })
end
```

---

## 3. UI State (`state.lua`)

```lua
M.state = {
  view_mode = 'list',        -- 'list' | 'dag'
  dag_data = {               -- populated by refresh_dag_data()
    nodes = { [name] = { name, deps[], trigger, loaded } },
    edges = { [name] = dep_names[] }
  },
  replay_info = {            -- only for plugins with _replay_done
    [name] = { event, chain[], replayed }
  },
  -- ... other fields
}
```

**Key functions:**
- `M.refresh_dag_data()` — pulls from `loader.get_dag_data()` + `get_replay_info()`
- `M.plugin_at_cursor()` — returns plugin name under cursor (walks up for detail lines)

---

## 4. Rendering Pipeline (`render.lua`)

### Module-Level State (reused across renders)

```lua
local line_parts = {}  -- cleared via index assignment
local lines = {}
local hls = {}
local line_idx = 0
local cur_col = 0
```

### Two Views

| View | Function | Key |
|------|----------|-----|
| List | `build_content()` | default |
| DAG | `build_dag_content()` | `A` |

### Performance Patterns

- `reset_render_state()` clears arrays in-place (no allocation)
- `add()`/`nl()`/`mark_row()` are upvalues (no closure creation)
- `_spaces_cache` metatable for O(1) space strings
- Numeric loops for SOA data (`names[i]`, `types[i]`, `paths[i]`)

---

## 5. Development Workflow

### Test Commands

```bash
# Quick smoke test
nvim --headless -c "lua require('resonance').setup()" -c "lua require('resonance').load({{src='https://github.com/nvim-lua/plenary.nvim', name='plenary'}})" -c "lua require('resonance.ui').open({width=0.8})" -c "qa"

# Benchmark render
nvim --headless -c "lua local t=vim.uv.hrtime(); require('resonance').setup(); require('resonance').load({{src='https://github.com/nvim-lua/plenary.nvim', name='plenary'}}); require('resonance.ui').open({width=0.8}); local st=require('resonance.ui.state'); st.refresh_dag_data(); st.state.view_mode='dag'; require('resonance.ui.render').render(); print('render:', (vim.uv.hrtime()-t)/1e6, 'ms')" -c "qa"

# lua_ls diagnostics
~/Projects/code/lua/resonance.nvim/lua/resonance/ui/render.lua
```

### Code Style (from AGENTS.md)

- Localize globals at top: `local uv = vim.uv`, `local api = vim.api`
- Tables over multiple returns
- Early returns, flat conditionals
- `vim.uv`/`vim.system` over `vim.fn` in hot paths
- `vim.schedule()` for async work
- Comments only for *why*, not *what*

### Commit Convention

```
feat(ui): add DAG visualization
fix(ui): reset view_mode on reopen
perf(render): reuse module-level state arrays
```

---

## 6. Known Limitations / Gotchas

| Issue | Location | Notes |
|-------|----------|-------|
| Spec key collision | `loader/init.lua:298` | Uses repo name only; `owner/repo` collides with `other/repo` |
| Spec mutation | `loader/init.lua:52` | `plugin_state` table used but `_force_load`/`_replay_done` still written to user config |
| No spec.lua parsing | `scanner.lua` | Misses lazy triggers defined in plugin's `plugin/spec.lua` |
| `cmd`/`keys`/`ft` no replay | `loader/init.lua` | Only `event` triggers replay missed autocmds |
| UI state not persisted | `state.lua` | `view_mode`, `expanded` reset on reopen |

---

## 7. Performance Baselines (2026-10-22)

| Operation | Avg Time |
|-----------|----------|
| `get_dag_data()` | ~0.03 ms |
| `get_replay_info()` | ~3.4 ms |
| DAG render (5 plugins) | ~11.8 ms |
| List render (5 plugins) | ~13.1 ms |
| UI open (offline) | ~7-10 ms |
| Startup overhead | ~0.88 ms |

All lua_ls diagnostics: **clean** (`.luarc.json` with LuaJIT + Neovim globals)

---

## 8. Quick Reference: Adding Features

### New UI Action

1. Add function to `actions.lua`
2. Add key binding in `init.lua:bind_keys()`
3. Add button to `render.lua:BUTTONS` if needed

### New Lazy Trigger Type

1. Add parsing in `loader/spec.lua:parse_trigger()`
2. Register autocmd/command/keymap in `loader/triggers.lua`
3. Handle replay in `load_now()` if applicable

### New Render View

1. Add `view_mode` value to `state.lua`
2. Add `build_<view>_content()` before `build_content()`
3. Add branch in `build_content()`: `if view_mode == 'x' then return build_x() end`
4. Add key binding in `init.lua`

---

## 9. Recent Fixes (2026-10-19 to 2026-10-22)

### Fix: `pack_add_safe` passes options correctly
**Commit:** a73de6d
**File:** `lua/resonance/loader/init.lua`
- Changed `pack_add_safe(vararg)` to `pack_add_safe(...)` to forward all arguments
- Fixes `confirm=false, load=false` being dropped, which broke lazy-loading

### Fix: Circular dependency detection now works
**Commit:** aeafd81
**File:** `lua/resonance/loader/init.lua`
- Marks `visiting_path` before processing dependencies
- Recursive A→B→A now correctly detected and reported with full path

### Fix: Dependency resolution works with custom plugin names
**Commit:** ceb610a
**File:** `lua/resonance/loader/init.lua`
- Added `M.spec_urls` mapping (URL → spec name)
- Dependencies specified by URL now resolve to custom-named specs correctly

### Fix: Replay ungrouped autocmds in event replay
**Commit:** ab2e48d
**File:** `lua/resonance/loader/init.lua`
- When `exclude` table non-empty, ungrouped autocmds (`group == nil`) now use empty string `''` as key
- Previously they were skipped entirely

### Fix: Read full .git files instead of 64KB limit
**Commit:** b40a149
**File:** `lua/resonance/ui/state.lua`
- Uses `uv_fs_fstat` to get file size, then reads entire content
- Fixes hash/URL truncation for repos with large `.git/config` or `packed-refs`

### Fix: Restore autocmd group names in replay info
**Commit:** 6f5b0d3
**File:** `lua/resonance/loader/dag.lua`
- `get_replay_info()` now shows autocmd group names (filetypedetect, nvim.autoread, etc.)
- Uses `plugin_triggers` parameter instead of re-parsing trigger from spec
- Skips User events (no standard autocmd chain)

### Fix: UI restored important elements
**Commit:** d54acf9
**File:** `lua/resonance/utils.lua`
- Restored key rendering elements accidentally removed

### Fix: Code deduplication
**Commit:** a7d89d3
**Files:** `lua/resonance/loader/dag.lua`, `lua/resonance/loader/spec.lua`, `lua/resonance/utils.lua`
- Removed duplicate logic across modules

### Fix: Sorting logic deduplication
**Commit:** 2956e47
**Files:** `lua/resonance/scanner.lua`, `lua/resonance/utils.lua`
- Unified sorting implementation

### Fix: load_now closure memory leak
**Commit:** af09a7e
**Files:** `lua/resonance/loader/dag.lua`, `lua/resonance/loader/init.lua`
- Fixed closure references causing memory leak

### Fix: Sorting numeric loops optimization
**Commit:** d1f5db7
**File:** `lua/resonance/utils.lua`
- `apply_sort`: replaced `ipairs` with numeric `for i = 1, #fields` loops

---

*Generated for future agents. Update when architecture changes.*