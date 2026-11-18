# Resonance.nvim — AI Development Guidelines

> **Purpose:** the hard rules for editing this codebase. Read it, then read
> the source — the source wins.
> **Target:** Neovim **0.13+** (`vim.pack` + `vim.async` both required).

---

## 1. Project structure

| Path | Role |
|---|---|
| `lua/resonance/init.lua` | Public API: `setup()`, `load()`, `stats()`, `open_ui()`, `has_fired()`, `replay_for_buffer()` |
| `lua/resonance/registry.lua` | Shared pure data: specs, triggers, disabled plugins, load times, plugin dirs. No side effects. |
| `lua/resonance/loader/` | Control plane: `init` (load/force-load), `spec` (normalize), `triggers` (autocmd/cmd/keymap/ft), `build` (build hooks), `dag` (dependency + event-chain data) |
| `lua/resonance/scanner.lua` | Read-only discovery of installed plugins (SOA parallel arrays) |
| `lua/resonance/ui/` | Panel: `init` (window + keymaps), `state` (singleton), `render`, `actions` |
| `lua/resonance/utils.lua` | Shared helpers — **`utils.get_pack()` lives here** |

Entry point: `require('resonance').setup()`.

**The scanner must not require the loader.** The shared state lives in
`registry.lua`, which depends on neither. The loader and the scanner both
require the registry, so the cycle is gone: requiring the scanner no
longer drags the control plane — and its `PackChanged` build autocmd —
into the read-only panel.

**Tools:** `rg` (ripgrep) for content search, `fd` for file finding — prefer
both over `grep` and `find`. `nvim` for headless testing, `lua-language-server`
for diagnostics.

Installed copy (what users actually run, and what the test suite exercises):

```text
~/.local/share/nvim/site/pack/core/opt/resonance.nvim/
```

**Open issues live in `plan.md` (repo root).** Read it before starting work —
it lists every unresolved bug with reproduction steps. `fix.md` and
`note/knowledge/fix-notes.md` are history, not a task list.

---

## 2. Red lines — violating these causes bugs

1. **Never touch `vim.pack` directly.** Use `utils.get_pack()`. It does
   `rawget(vim, 'pack')`, which bypasses the `vim` metatable's lazy
   rehydration. Bare `vim.pack` breaks the fallback path and the
   `vim.pack = nil` tests.
2. **Query offline by default.** `pack.get(nil, { info = false, offline = true })`.
   `info = true` is slow (~420 ms at 49 plugins) and blocks the main thread.
3. **Never trust `:packadd`.** It returns success for a plugin that was
   never installed. Verify the directory exists on disk first, and check the
   error from `pack.add` — `vim.pack.add` *raises* on failure.
4. **Notify through `utils.notify`,** which defers via `vim.schedule`.
   `vim.notify` cannot be called from a fast-event context (an `async` task
   body, a libuv callback).
5. **Triggers are grouped per plugin** (`Resonance_<plugin>` augroup).
   The replay addresses groups, not events. `fired_groups[buf][group]` is
   the unit of "already ran" — a group registered *after* its event fired
   has not seen that event and must still get its chance.
6. **Never call `vim.pack.add(..., { load = true })` during init.**
   Resonance controls loading via `:packadd`.
7. **Build hooks go through `PackChanged`,** never polling.

---

## 3. Code style — match the surrounding code

- **Localize what the module uses, at the top.** Follow the existing naming
  in that file: `string_format`, `vim_schedule`, `vim_log_levels`,
  `uv_fs_stat`, `nvim_buf_set_extmark`, `vbo` / `vwo`. Do **not** introduce
  unused aliases, and do not rename to a different convention
  (`sfmt` / `vnotif` / `vlog` are not this codebase's style).
- **Arrays → numeric `for i = 1, #t`. Dictionaries → `pairs()`.** `pairs()`
  is required for map iteration and is used throughout `loader/dag.lua`.
  `ipairs()` is not used anywhere in this codebase.
- **`ui/render.lua` reuses buffers** via `table.clear` — do not reassign
  `lines` / `hls` / `line_parts` to `{}` mid-render.
- **New lists use AoS** — one table per entry, fields as keys:
  `local p = plugins[i]` then `p.name`, `p.path`. Do **not** create parallel
  arrays. The scanner's existing SoA shape is legacy; leave it alone and
  do not extend it, but do not copy it into new code.
  - Why: Lua arrays hold `TValue` pointers, so parallel arrays scatter
    every field across separate allocations — the cache-locality win SoA
    gives in C does not exist here.
  - Sorting an AoS list is `table.sort(plugins, cmp)` in place; sorting SoA
    means rebuilding every parallel array (`utils.apply_sort` copies each
    field into a fresh table).
  - A missing field in AoS is just `p.rev_to == nil`. In SoA it punches a
    hole: `#t` becomes unreliable (measured: a nil at index 2 of a 3-element
    array reports length 1 while index 3 still holds a value).
- Early returns, flat conditionals, comments only for *why*.
- No filesystem walks in hot paths — use the `vim.pack.get()` cache.
- Localize globals; avoid `vim.fn` in hot paths — prefer `vim.uv` /
  `vim.system`.

---

## 4. Development loop

### Sync (the suite tests the **installed** copy, not the repo)

```bash
I=~/.local/share/nvim/site/pack/core/opt/resonance.nvim
cp lua/resonance/*.lua        $I/lua/resonance/
cp lua/resonance/loader/*.lua $I/lua/resonance/loader/
cp lua/resonance/ui/*.lua     $I/lua/resonance/ui/
cp test/*.lua                 $I/test/
cp doc/resonance.txt README.md AGENTS.md $I/
```

`test/runner.lua` fails loudly if the installed copy is stale. Sync before
every test run.

### Test

```bash
./test/run_all.sh
# or: nvim --headless -c "luafile test/run_all.lua" -c "qall"
```

`test/pack_integration_spec.lua` installs real plugins — it must run with
`XDG_DATA_HOME` pointed at a temp dir, never against the user's real
plugin directory.

**Mutation-check new regression tests.** A test that passes against broken
code is worse than no test. Revert the fix in the *installed* copy only and
confirm the test fails:

```bash
RESONANCE_TEST_ALLOW_STALE=1 nvim --headless \
  -c "luafile test/runner.lua" -c "luafile test/behavior_spec.lua" -c "qall"
```

### Diagnose

```bash
lua-language-server --check=lua/resonance/loader/init.lua   # and the other modules
```

### Benchmark (performance changes only)

```bash
# startup
#
# -vimpath is required: vim-startuptime defaults to the `vim` binary,
# which is not installed on this machine. Without it the command fails.
#
# The runtimepath has to be set explicitly. Under `-u NONE` the plugin
# directory is not on the runtimepath, so `require('resonance')` fails
# with "module not found" and the benchmark measures a failed require
# instead of the plugin.
I=$HOME/.local/share/nvim/site/pack/core/opt/resonance.nvim
vim-startuptime -vimpath "$(which nvim)" -count 10 -warmup 3 -- \
  -u NONE --cmd "set rtp+=$I" \
  -c "lua require('resonance').setup()" -c "qall"

# Baseline, to get the plugin's own cost. Run it too: the startup total
# is mostly Neovim itself.
vim-startuptime -vimpath "$(which nvim)" -count 10 -warmup 3 -- \
  -u NONE -c "qall"

# UI open time
nvim --headless -c "luafile lua/resonance/init.lua" \
  -c "lua require('resonance').setup(); local t=vim.uv.hrtime(); require('resonance').open_ui(); print('UI open:', (vim.uv.hrtime()-t)/1e6, 'ms')" \
  -c "qall"
```

No regression allowed on either.

---

## 5. Common tasks

**Add a trigger type** — `loader/triggers.lua`: add `register_<type>()`,
call it from `register_all()`. Pass the `group` through so the replay can
address it.

**Add a UI column/action** — `ui/state.lua` (field), `ui/actions.lua`
(handler), `ui/init.lua` (keymap), `ui/render.lua` (column).

**Modify the build system** — `loader/build.lua`: `run_build()`,
`check_and_build()`, `mark_build_success()`, `clear_build_marker()`,
`PackChanged` autocmd. The build hash marker lives in
`stdpath('state') .. '/resonance/builds/'`, keyed by plugin name — never
in the plugin's own directory, which dirties its git worktree.

**A build-system rework is planned** — see `plan.md` Batch 5 / `fix.md` P4
(items 27–30). Three confirmed defects: `setup()` runs before the build
finishes, a build that exits 0 while printing errors is reported as
succeeded, and one load can start two concurrent builds. The fix is a
new `lua/resonance/builds.lua` that owns the per-plugin build state
(status, wait, output tail, cross-session PID lock), with the settled
decisions: background builds never block the editor, only the exit code
decides success, and there are two separate timeouts (a notify threshold
and a hard build timeout).

**A trigger pattern may be a list** — `normalize_events()` keeps a table
pattern as a table, because Neovim accepts a list of patterns on an
autocmd. Anything that renders a pattern for display has to join it
rather than concatenate it. `parse_trigger()` does this; a bare
`'(' .. pattern .. ')'` raises `attempt to concatenate a table value` and
takes the whole load down.

---

## 6. Committing

Use the session's `commit` namespace, not raw `git add` / `git commit`:

```lua
d = await commit.draft()
await d.commit("subject", ["- body"])
```

It selects only your own changed lines and leaves other agents' and the
user's work untouched. Use raw git only if that namespace is unavailable.
