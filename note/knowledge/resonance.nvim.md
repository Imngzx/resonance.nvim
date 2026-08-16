# resonance.nvim — AI Agent Knowledge Base

> **Purpose**: Enable future AI agents to work on this codebase without re-discovering patterns.
> **Last Updated**: 2026-08-16

---

## 1. Module Map

| File | Responsibility |
|------|----------------|
| `lua/resonance/init.lua` | Public API: `setup()`, `load()`, `stats()`, `open_ui()`, `trigger_verylazy()` |
| `lua/resonance/loader.lua` | Core: DAG resolution, lazy triggers, event replay, build hooks |
| `lua/resonance/scanner.lua` | Plugin discovery: scans `vim.pack` directories, extracts metadata |
| `lua/resonance/utils.lua` | Shared utilities: `fast_normalize()`, `notify()` |
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

### Lazy Trigger Resolution (loader.lua)
| Trigger | Mechanism |
|---------|-----------|
| `event` | `create_autocmd(event, { once=true, callback=load_now })` |
| `cmd` | `create_user_command(cmd, wrapper)` — wrapper deletes command, loads, re-executes |
| `keys` | `set_keymap(mode, lhs, wrapper)` — wrapper deletes keymap, loads, executes RHS |
| `ft` | `create_autocmd('FileType', { pattern=ft, once=true, callback=load_now })` |

### DAG Resolution
```lua
-- Recursive DFS with cycle detection
load_now(ev, visiting_path)
  visiting_path[current_name] = true
  for dep in deps do
    if not M.specs[dep]._loaded then
      M.specs[dep]._force_load(ev, visiting_path)
    end
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
| DAG | `build_dag_content()` | `g` |

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
/home/alice/.local/share/nvim/mason/bin/lua-language-server --check=/home/alice/Projects/code/lua/resonance.nvim/lua/resonance/ui/render.lua
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
| Spec key collision | `loader.lua:298` | Uses repo name only; `owner/repo` collides with `other/repo` |
| Silent cycle break | `loader.lua:342` | Warns but doesn't print full cycle path |
| Spec mutation | `loader.lua:335` | Adds `_loaded`, `_force_load`, `_replay_done` to user spec |
| No spec.lua parsing | `scanner.lua` | Misses lazy triggers defined in plugin's `plugin/spec.lua` |
| `cmd`/`keys`/`ft` no replay | `loader.lua` | Only `event` triggers replay missed autocmds |
| UI state not persisted | `state.lua` | `view_mode`, `expanded` reset on reopen |

---

## 7. Performance Baselines (2026-08-16)

| Operation | Avg Time |
|-----------|----------|
| `get_dag_data()` | ~0.03 ms |
| `get_replay_info()` | ~3.4 ms |
| DAG render (5 plugins) | ~11.8 ms |
| List render (5 plugins) | ~13.1 ms |

All lua_ls diagnostics: **clean** (`.luarc.json` with LuaJIT + Neovim globals)

---

## 8. Quick Reference: Adding Features

### New UI Action
1. Add function to `actions.lua`
2. Add key binding in `init.lua:bind_keys()`
3. Add button to `render.lua:BUTTONS` if needed

### New Lazy Trigger Type
1. Add parsing in `loader.lua:parse_trigger()`
2. Register autocmd/command/keymap in `M.load()`
3. Handle replay in `load_now()` if applicable

### New Render View
1. Add `view_mode` value to `state.lua`
2. Add `build_<view>_content()` before `build_content()`
3. Add branch in `build_content()`: `if view_mode == 'x' then return build_x() end`
4. Add key binding in `init.lua`

---

*Generated for future agents. Update when architecture changes.*