# Resonance.nvim — AI Development Guidelines

> **Purpose:** the hard rules for editing this codebase. Read it, then read
> the source — the source wins.
> **Target:** Neovim **0.13+** (`vim.pack` + `vim.async` both required).
> Repo: [resonance.nvim](https://github.com/Imngzx/resonance.nvim).

---

## 1. Project structure

| Path | Role |
|---|---|
| `lua/resonance/init.lua` | Public API: `setup()`, `load()`, `import()`, `stats()`, `open_ui()`, `has_fired()`, `replay_for_buffer()`, `trigger_verylazy()` (legacy) |
| `lua/resonance/registry.lua` | Shared pure data: specs, triggers, disabled plugins, load times, plugin dirs. No side effects. |
| `lua/resonance/loader/` | Control plane: `init` (load, install), `spec` (normalize), `triggers`, `replay` (event tracker and both replays), `build` (build hooks), `dag` (panel data, required on first use) |
| `lua/resonance/builds.lua` | Per-plugin build state: status, wait, output tail, hard timeout, cross-session PID lock. Requires nothing from the loader. |
| `lua/resonance/scandir.lua` | Opt-in `import()`. Required only when `import()` is called. |
| `lua/resonance/scanner.lua` | Read-only discovery of installed plugins (SoA: parallel arrays indexed `1..total`) |
| `lua/resonance/ui/` | Panel: `init` (window + keymaps), `state` (singleton), `render`, `actions` |
| `lua/resonance/utils.lua` | Shared helpers — **`utils.get_pack()` lives here** |
| `CODE_TOUR.md` | Guided walk-through: glossary, file map, each flow as a story. Keep it in step when a flow changes. |

Entry point: `require('resonance').setup()`.

**The scanner must not require the loader.** Shared state goes in
`registry.lua`, which both require and which requires neither. Requiring
the loader from the scanner would pull the control plane — and its
`PackChanged` build autocmd — into the read-only panel.

**Tools:** `rg` for content search, `fd` for file finding — prefer both
over `grep` and `find`. `nvim` for headless testing, `lua-language-server`
for diagnostics.

**Open issues live in GitHub Issues.** History is `git log`; the *why* of
each fix goes in the code comments and the regression tests. Keep any
working plan in a local,
untracked file (for example via `.git/info/exclude`) and do not commit it.

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
  `uv_fs_stat`, `nvim_buf_set_extmark`, `vbo` / `vwo`. No unused aliases,
  no other convention (`sfmt` / `vnotif` / `vlog`).
- **Arrays → numeric `for i = 1, #t`. Dictionaries → `pairs()`.**
  `ipairs()` is not used anywhere in this codebase.
- **`ui/render.lua` reuses buffers** via `table.clear` — do not reassign
  `lines` / `hls` / `line_parts` to `{}` mid-render.
- **Use SoA where it already exists.** The scanner returns parallel arrays
  (`info.plugins.name[i]`, `.path[i]`, `.loaded[i]`, …). Add a per-plugin
  field as one more parallel array; do not convert to a list of tables.
  Use AoS only for a new list that does not come from an SoA structure.
  - Iterate `for i = 1, info.total`, never `#t`: `rev` / `rev_to` /
    `manifest` have holes on purpose, and `#` is unreliable with holes.
  - Write every array at every index when adding an entry (see
    `append_disabled()` in the scanner).
  - Sort with `utils.sort_plugins()` + `utils.apply_sort()`, and list
    every field in `apply_sort`, or that field falls out of alignment.
- Early returns, flat conditionals, comments only for *why*.
- No filesystem walks in hot paths — use the `vim.pack.get()` cache.
- Avoid `vim.fn` in hot paths — prefer `vim.uv` / `vim.system`.

---

## 4. Development loop

### Isolated env

Every XDG directory points into the git-ignored `.dev/`, so nothing
touches the real `~/.local`, `~/.config`, or the plugin copy the editor
runs.

```bash
test/dev_env.sh bootstrap   # create .dev: installs resonance + 3 fixture plugins via vim.pack
test/dev_env.sh sync        # copy the working tree over the installed copy
test/dev_env.sh nvim        # an isolated Neovim for manual testing
test/dev_env.sh shell       # a shell with the isolated XDG env exported
test/dev_env.sh path        # print the installed copy's path
rm -rf .dev                 # start over; the next command bootstraps again
```

The suite tests the **installed** copy, not the repo. `test/dev_env.sh test`
syncs before every run, and `test/runner.lua` fails if the copy is stale or
if it runs outside the isolated env (`RESONANCE_TEST_ALLOW_REAL_ENV=1`
overrides it — don't).

The isolated env has no user config: no `mapleader`, no snacks, no
personal plugins. A test that needs one of them must set it up itself.

### Test

```bash
./test/run_all.sh                          # the whole suite, isolated
test/dev_env.sh test test/gc_spec.lua      # one or more spec files
```

- **Faking processes:** use `h.with_system(handler, fn)` from
  `test/helpers.lua`, not an assignment to `vim.system`: `ui/actions.lua`
  holds `vim.system` in a local, and the helper rebuilds it against the
  stub and restores it afterwards.
- **`test/docs_spec.lua`** fails on a broken `|link|` in the help file or a
  stale `doc/tags`.
- **`test/pack_integration_spec.lua`** installs real plugins into its own
  temp `XDG_DATA_HOME` per test.
- **`test/gc_spec.lua`** holds the memory regressions. Prefer an exact count
  (buffers, windows, autocmds, registry refs, table keys) over a heap
  bound. Neovim's runtime retains memory per buffer and window in headless
  mode, so switch such sources off or count around them, and drain the
  event loop (`vim.wait`) between cycles.

**CI** (`.github/workflows/test.yml`) runs `./test/run_all.sh` on every push
to `main`, every pull request and once a week, in an Arch container with
Neovim nightly installed by `bob`. That machine has a shallow checkout on a
detached HEAD, no git identity, and runs as root. A test that commits must
set the identity itself (`-c user.name=… -c user.email=…`, or `git config`
inside its own temp repo), and nothing may depend on a tool beyond `git`,
`sh` and coreutils. Only GitHub runs it.

**Mutation-check new regression tests.** Revert the fix in the *installed*
copy only and confirm the test fails, then sync to restore it:

```bash
$EDITOR "$(test/dev_env.sh path)/lua/resonance/loader/init.lua"   # break it
RESONANCE_TEST_ALLOW_STALE=1 test/dev_env.sh test test/gc_spec.lua
test/dev_env.sh sync
```

### Diagnose

```bash
lua-language-server --check=lua/resonance/loader/init.lua   # and the other modules
```

### Benchmark (performance changes only)

No regression allowed on any of these.

```bash
# Keep `-u NONE` and the rtp flag together. Without the synced copy on the
# runtimepath, require('resonance') fails or loads the copy the real config
# installed, and the number is not for the working tree. `luafile
# lua/resonance/init.lua` does not register the module either.
I=$(test/dev_env.sh path)

# startup (-vimpath: vim-startuptime defaults to `vim`)
vim-startuptime -vimpath nvim -count 10 -warmup 3 -- \
  -u NONE --cmd "set rtp+=$I" \
  -c "lua require('resonance').setup()" -c "qall"

# baseline; subtract it to get the plugin's own cost
vim-startuptime -vimpath nvim -count 10 -warmup 3 -- \
  -u NONE -c "qall"

# UI open time (the plugin list comes from the real vim.pack lockfile)
nvim --headless -u NONE --cmd "set rtp+=$I" \
  -c "lua require('resonance').setup(); local t=vim.uv.hrtime(); require('resonance').open_ui(); print('UI open:', (vim.uv.hrtime()-t)/1e6, 'ms')" \
  -c "qall"
```

**Resonate (`r`)** — `test/bench_resonate.sh`. No network needed: N local
repos are installed through vim.pack in throwaway XDG dirs, and every
`git fetch` sleeps to stand in for the round trip. It times the phases
(fetch / blocking `pack.get` / `git log` / total) and exits non-zero if a
check misses a pending update.

```bash
test/bench_resonate.sh                                  # 49 plugins, 500 ms latency, 3 runs
RESONANCE_BENCH_CONCURRENCY=5 test/bench_resonate.sh    # compare a setting
```

Knobs: `RESONANCE_BENCH_PLUGINS`, `_LATENCY_MS`, `_RUNS`, `_CONCURRENCY`.
Reference (2026-11-19, 8 threads): concurrency 16 → ~2.5 s total
(fetch ~2.1 s, `pack.get` ~0.4 s); concurrency 5 → ~5.7 s.
A change to the Resonate path must not raise the total or the `pack.get`
time.

---

## 5. Common tasks

**Add a trigger type** — `loader/triggers.lua`: add `register_<type>()`,
call it from `register_all()`. Pass the `group` through so the replay can
address it. A trigger pattern may be a list: join it for display, never
concatenate it (see `parse_trigger()`).

**Add a UI column/action** — `ui/state.lua` (field), `ui/actions.lua`
(handler), `ui/init.lua` (keymap), `ui/render.lua` (column).

**Modify the build system** — hooks in `loader/build.lua` (`run_build()`,
`check_and_build()`, `mark_build_success()`, `clear_build_marker()`, the
`PackChanged` autocmd); state in `lua/resonance/builds.lua`. The build
marker lives in `stdpath('state') .. '/resonance/builds/'`, keyed by plugin
name — never in the plugin's own directory, which dirties its git worktree.
The settled rules: one build per plugin at a time; only the exit code
decides success; `setup()` runs after the build (a load started by a
command or a keymap waits, bounded, and so do its dependencies; any other
load defers until every build of the spec settles); a failed build still gets its
plugin set up; background builds never block the editor. See
`:h resonance-build-order`.

**Add a `setup()` option** — follow `build.concurrency` and
`resonate.concurrency`:

1. `init.lua`: the default in `M.config` and a `---@field` on the
   matching `Resonance*Config` class. A default that depends on the
   machine stays out of `M.config` and lives in the owning module.
2. The owning module: `M.configure(opts)` validates the value; an invalid
   one is reported through `utils.notify` (naming the option, e.g.
   `build.concurrency`) and falls back to the default. Add a getter so
   tests can read the applied value.
3. Call `configure()` where the module is first needed, not
   unconditionally from `setup()`: requiring a module there adds its
   load cost to every startup. `build` is applied in `setup()` because the
   loader already requires it; `resonate` is applied in `open_ui()`.
4. `doc/resonance.txt`: a `*resonance-<name>-config*` section and a line
   in the `resonance.setup()` reference; then regenerate the tags (below).
   `README.md`: add the option to the setup example.
5. Tests: the default, each invalid value warns and falls back, and the
   `setup()` → module wiring.

**Edit the help file** — after adding or renaming a `*tag*` in
`doc/resonance.txt`, regenerate `doc/tags` and commit it with the doc:

```bash
nvim --headless -c 'helptags doc' -c q
```

**Tag a release** — only when the user asks for one; never on your own.
While the version is `0.x`: a fix raises the patch (`v0.9.1`), a feature or
a breaking change raises the minor (`v0.10.0`).

1. `main` is clean, pushed, and its last CI run is green
   (`gh run list --branch main --limit 1`).
2. Raise the pinned version in the install examples — `README.md`
   (Installation) and `doc/resonance.txt` (`*resonance-installation*`) —
   and commit that. The tag goes on this commit, so the tagged tree names
   its own version.
3. `git tag -a vX.Y.Z -m "vX.Y.Z: <summary>"`. Annotated, never lightweight.
4. The user pushes: `git push origin main vX.Y.Z` (both remotes get it).
   A tag push does not start CI; the `main` push does.
5. Optional, GitHub only: `gh release create vX.Y.Z --verify-tag --notes-from-tag`.

A pushed tag is never moved or deleted. A mistake gets a new patch version.

---

## 6. Committing

Stage only your own changes, never `git add -A` / `git add .`: other
agents or the user may have uncommitted work in the tree. Check
`git status` first and add files by path. If a file mixes your changes
with someone else's, do not commit it; ask the user.
