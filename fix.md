# resonance.nvim — Actionable Fix List

> **Target baseline:** branch `fix` (post `note/knowledge/plan-2026-11-17.md`)  
> **Note for agent:** Read the referenced Lua files directly before editing. Do **not** trust stale claims in `AGENTS.md` or `doc/resonance.txt` over actual Lua code.

---

## Agent Guardrails (Mandatory)

1. **Sync before testing:** `test/runner.lua` tests the installed copy (`~/.local/share/nvim/site/pack/core/opt/resonance.nvim/`), not the working tree directly. Sync all changed files before running `./test/run_all.sh` or `nvim --headless -c "luafile test/run_all.lua" -c "qall"`.
2. **No cargo-cult rewrites:** Do **not** add `local pcall = pcall`-style micro-localizations or split tables into SoA arrays unless explicitly part of a task.
3. **Behavioral verification:** For every bug fix, add or update a test in `test/behavior_spec.lua` (or the relevant `*_spec.lua`) and verify the test **fails** if the fix is reverted.
4. **Keep docs truthful:** Only document functions, arguments, and events that actually exist in `lua/`.

---

## P0 — Critical Test Blind Spots & Correctness Bugs

### 0. **REGRESSION — FIXED** — `replay_for_buffer()` starves late-registered triggers, breaking the UI on `nvim <file>` / open-from-yazi

- **Severity:** critical — the statusline, bufferline, and breadcrumb do not render at all on the most common launch paths. Reported by the user on 2026-11-17 after the `replay_for_buffer()` change (commit `f53c591`).
- **Files:** `lua/resonance/loader/init.lua` (`replay_for_buffer`, `has_fired`, `mark_fired`, `setup_event_tracker`), `lua/resonance/loader/triggers.lua`
- **Problem:**
  - `has_fired(event, buf)` records that an event fired **for a buffer**, with no record of *which trigger* observed it.
  - `replay_for_buffer(buf)` skips every event that `has_fired()` reports as already fired.
  - On `nvim file.txt` (and opening a file from yazi), the sequence is:
    1. `BufReadPost` / `BufEnter` fire **before** `UIEnter` → `VeryLazy`.
    2. `VeryLazy` runs the user config, which calls `resonance.load()` for the UI plugins (heirline, bpm, treesitter, lsp, ufo, hlslens, mini-hipatterns, …). **Their triggers are registered now — after the events already fired.**
    3. The user config then calls `resonance.replay_for_buffer(buf)`.
    4. `replay_for_buffer()` sees `has_fired('BufReadPost', buf) == true` and **skips the replay entirely**.
  - Result: the late-registered triggers never fire. The plugin is never loaded, so `heirline.setup()` never runs and there is no statusline, bufferline, or breadcrumb.
  - The `nvim` → picker → enter path is unaffected because the trigger was already registered when `BufReadPost` fired naturally.
- **Verified symptom matrix** (stubbed install, late-registered `event = { 'BufReadPost', 'BufNewFile', 'BufEnter' }` trigger):

  | Launch path | Trigger's `setup` runs? | Observed |
  |---|---|---|
  | `nvim file.txt` | ❌ `false` | UI missing |
  | open file from yazi | ❌ `false` | UI missing |
  | `nvim` → picker → enter | ✅ `true` | UI fine |

  Direct comparison of the old unconditional `pcall(api.nvim_exec_autocmds, …)` against the new `replay_for_buffer()` with the identical setup: `OLD setup_ran=true` / `NEW setup_ran=false`.
- **Root cause:** the fired-event state is tracked **per buffer**, but the question that matters is **per trigger**. "Did `BufReadPost` fire for this buffer?" is the wrong question — the right question is "did *this trigger* already run for this buffer?"
- **Mechanism (verified at each step):**
  1. `BufReadPost` fires for the buffer → `mark_fired('BufReadPost', buf)` → `has_fired('BufReadPost', buf) == true`.
  2. `VeryLazy` registers the heirline trigger. The autocmd exists and is correct:
     `Resonance_heirline.nvim/BufReadPost` is listed by `nvim_get_autocmds({ event = 'BufReadPost' })`.
  3. `replay_for_buffer(buf)` evaluates `has_fired('BufReadPost', buf)` → `true` → **skips `BufReadPost` entirely**.
  4. For a file that exists on disk, `is_file` is true, so the `else` branch (`BufNewFile` / `BufEnter`) is never taken either. `replay_for_buffer()` returns an **empty list** and fires **nothing**.
  5. The heirline trigger never runs → `heirline.setup()` never runs → no statusline, bufferline, or breadcrumb.

  Isolated proof (real file on disk, trigger registered *after* the events):

  ```text
  before replay           hl_setup_ran=false
  REPLAY returned=[]      hl_setup_ran=false     ← replay fired nothing
  ```

  And firing the group directly bypasses the gate and loads it:

  ```text
  before replay           hl_setup_ran=false
  after DIRECT group fire hl_setup_ran=true
  ```

- **Fix:** track fired state per **trigger group** (the `Resonance_<plugin>` augroup already exists — see item 1 in the same batch), not per buffer. `replay_for_buffer(buf)` should fire the event for every trigger group that has **not yet run** for that buffer, and skip only the groups that have. The per-buffer `has_fired()` API must stay available for user configs that need to ask "has this event already run for this buffer?", but it must no longer be the gate that decides whether a trigger gets its chance to run.
  - Concretely: the loader already knows which augroup belongs to which plugin. When a trigger group loads, mark it as fired for that buffer. `replay_for_buffer()` then fires the event once per *unfired* group, not once per *unfired event*.
  - The trigger group must be marked as fired **when it loads**, not when the event first fired — otherwise the group is marked "already fired" before it ever ran.
  - Do **not** "fix" this by making `replay_for_buffer()` fire everything unconditionally again — that reintroduces the duplicate-`FileType` → E218 problem that item 1's guards solve.
- **Verification:**
  - A regression test in `test/behavior_spec.lua`: register a plugin with `event = { 'BufReadPost', 'BufEnter' }` **after** `BufReadPost`/`BufEnter` have already fired for the buffer, then call `replay_for_buffer(buf)` and assert the plugin's `setup` ran.
  - The test must fail against the current code and pass after the fix.
  - Also assert the opposite: a trigger that **already ran** for that buffer is **not** fired a second time (the E218 guard from item 1 must still hold).
  - End-to-end check with the user's real config: `nvim <file>` and opening a file from yazi must render the statusline/bufferline/breadcrumb.

#### Status: fixed

**Implementation** (`lua/resonance/loader/init.lua`, `lua/resonance/loader/triggers.lua`):

- Added `fired_groups[buf][group_name]`, tracked alongside the existing
  per-event `fired_events[buf][event]`.
- `triggers.trigger_group_name(name)` now exposes the augroup name, so the
  loader and the triggers module share one source of truth for it.
- `load_now()` marks its own trigger group as fired for the buffer when the
  trigger runs.
- The event tracker marks every group that **existed when the event fired**.
  A group registered *after* the event is not marked — that is exactly what
  lets a late-registered trigger still load.
- `replay_for_buffer()` now fires each event **once per pending group**,
  scoped to that group, instead of gating on the per-event state. It also
  guards against invalid buffer ids (fix.md item 6).

**Regression test:** `replay: a trigger registered after the event already
fired still loads` in `test/behavior_spec.lua`. It fails against the
pre-fix code (`the late-registered trigger never fired: the replay returned
[FileType]`) and passes after the fix.

**Mutation-verified** — the suite catches the fix being reverted in both
directions:

| Mutation | Tests that fail |
|---|---|
| replay block disabled | `replay: re-fires an event that already happened`, `replay: a successor event that already fired for this buffer is replayed once` |
| per-group gate replaced by the old per-event gate | `replay: a trigger registered after the event already fired still loads`, `fired events: replay_for_buffer fires an event that was missed` |
| per-group gate removed (over-firing) | `fired events: replay_for_buffer does not re-fire an event that already ran` |

**No duplicates:** the replay adds zero extra handler invocations
(`before=(1,1,2) after=(1,1,2)`).

**End-to-end:** with the user's real config, `nvim <file>` and open-from-yazi
both load heirline (`HL_RAN=true` / `PATH2_HL=true`).

#### Follow-up (found 2026-11-17) — `BufEnter` is never replayed for an existing file

The item 0 fix moved the replay onto a per-trigger-group basis, but left
the event selection unchanged:

```lua
if is_file then
  fire_groups('BufReadPre')
  fire_groups('BufReadPost')
else
  fire_groups('BufNewFile')
  fire_groups('BufEnter')     -- ← only for a buffer that is not a file
end
```

`BufEnter` fires for **every** buffer, not only new ones. Verified event
order on `nvim <file>`:

```text
EVENTS_ON_OPEN=BufReadPre,BufReadPost,FileType,BufEnter
```

So a trigger group whose only event is `BufEnter` never fires on the
`nvim <file>` path, and the plugin silently never loads.

Reproduction (late-registered `event = 'BufEnter'` trigger):

```text
REPLAY_FIRED=[BufReadPre,BufReadPost]
AFTER_REPLAY ran=false      ← the plugin never loaded
```

With `fire_groups('BufEnter')` moved out of the `else`:

```text
REPLAY_FIRED=[BufReadPre,BufReadPost,BufEnter]
AFTER_REPLAY ran=true       ← the plugin loads
```

**Impact on the user's actual config: none today.** No plugin in
`~/.config/nvim/lua/plugins/` uses `BufEnter` as a trigger, and the common
shape `event = { 'BufReadPost', 'BufNewFile' }` still loads, because
`BufReadPost` alone satisfies the group. The bug only bites a
`BufEnter`-only trigger.

**Fix:** the `is_file` split should decide between `BufReadPre`/`BufReadPost`
and `BufNewFile` — the events that genuinely differ — and not decide
whether `BufEnter` happens at all:

```lua
if is_file then
  fire_groups('BufReadPre')
  fire_groups('BufReadPost')
else
  fire_groups('BufNewFile')
end

fire_groups('BufEnter')
fire_groups('FileType')
```

**Verification:** a behavioural test that registers a `BufEnter`-only trigger
late, calls `replay_for_buffer()`, and asserts the plugin loaded. Must fail
before the fix.

### 1. Restore coverage on 9 silent-false-pass replay tests — FIXED

- **Files:** `test/behavior_spec.lua`, `test/integration_deep_spec.lua`
- **Problem:** After `pack_install` + `is_installed` + `fail_install` were added in `lua/resonance/loader/init.lua`, specs using fake `https://github.com/test/...` URLs abort inside `fail_install()` before reaching the event-replay block. Positive replay tests (`count > 1`) were updated with `test.stub_pack()`, but 9 negative/boundary tests (`count == 0` / `1` / non-recursion) were missed and now trivially pass without ever executing replay:
  - `test/behavior_spec.lua`:
    - `replay: the triggering event handler runs exactly once`
    - `replay: a successor event that has not fired yet is not replayed`
    - `replay: a read on one buffer does not replay another buffer`
    - `replay: nested triggers do not recurse without bound`
    - `replay: an ungrouped successor trigger is not fired by the replay`
    - `replay: an ungrouped trigger that re-fires the event does not recurse`
  - `test/integration_deep_spec.lua`:
    - `replay: does not re-fire the event that triggered the load`
    - `replay: tracks fired events per buffer, not globally`
    - `replay: does not fire events that have not happened yet`
- **Fix:** Call `test.stub_pack()` at the start of each test above and assert that `setup` actually ran (or `plugin_state[name].loaded == true`) so the test proves `load_now` completed and reached the replay block.

#### Status: fixed

All 9 tests now call `test.stub_pack()` and assert that the plugin's
`setup` ran, so they prove `load_now` reached the replay block.

**Note on what these tests can and cannot catch.** The 7 restored tests are
*negative* assertions (`count == 0`, "must not recurse"). A negative
assertion cannot detect a replay block that is **disabled** — nothing fires,
so nothing fires twice. They detect a replay that fires **too much**. The
2 positive tests (`count > 1`) are the ones that catch a disabled replay.

**Mutation-verified** after the restore:

| Mutation | Tests that fail |
|---|---|
| replay block disabled | `replay: re-fires an event that already happened`, `replay: a successor event that already fired for this buffer is replayed once` |
| `has_fired` guard removed from the replay chain (over-firing) | `replay: tracks fired events per buffer, not globally`, `replay: does not fire events that have not happened yet`, `replay: a successor event that has not fired yet is not replayed`, `replay: a read on one buffer does not replay another buffer` |

Both directions are covered, so the suite now has a real safety net for the
replay logic — which is what made the item 0 fix verifiable.

### 2. **FIXED** — Fix `lazy = true` combined with `event` crashing and dropping triggers

- **Files:** `lua/resonance/loader/spec.lua`, `lua/resonance/utils.lua`, `lua/resonance/loader/triggers.lua`
- **Problem:**
  - In `spec.parse_config()`, when `lazy = true` is combined with `event = 'BufReadPre'` (or `event = { 'BufReadPre', 'BufNewFile' }`), `config.event` becomes `{ 'BufReadPre', { 'User', pattern = 'VeryLazy' } }`.
  - `utils.parse_trigger()` then calls `table_concat(ev, ', ')`, which crashes on the nested table entry.
  - `triggers.register_event()` enters the `else` branch (`ev[1] ~= 'User'`), filters only `type(ev[i]) == 'string'`, and silently drops `{ 'User', pattern = 'VeryLazy' }`.
  - If the original `event` was `{ 'User', pattern = 'Custom' }`, `table.insert(event, { 'User', pattern = 'VeryLazy' })` turns `ev[2]` into a table and corrupts `opts.pattern` in `register_event()`.
- **Fix:** Normalize multi-event / mixed `User` + native event specs cleanly across `spec.parse_config()`, `utils.parse_trigger()`, and `triggers.register_event()` (e.g., register each `User` entry separately from plain event names instead of mixing tables into a string list).
- **Verification:** Add end-to-end tests in `test/behavior_spec.lua` (with `test.stub_pack()`) calling `resonance.load()` for `lazy = true` + string `event`, array `event`, and `{ 'User', pattern = ... }`, verifying both the primary event and `VeryLazy` can trigger loading without errors.

### 3. **FIXED** — Handle specs with neither triggers nor `lazy`

- **Files:** `lua/resonance/loader/spec.lua`, `lua/resonance/loader/init.lua`
- **Problem:** A spec with no `event`/`cmd`/`keys`/`ft` and `lazy == nil` (like the `version = 'v1.0.0'` example in `README.md`) registers nothing in `triggers.register_all()`. It is silently never installed and never loaded unless referenced as a dependency.
- **Fix:** Choose explicit behavior—either default triggerless specs (`lazy == nil` and no `event`/`cmd`/`keys`/`ft`) to `lazy = false` (`VimEnter`, or `VeryLazy` if preferred, updating docs to match), or emit a clear `utils.notify(..., vim.log.levels.WARN)` warning when a top-level spec has no triggers. Add a test in `test/behavior_spec.lua`.

### 4. **FIXED** — Propagate dependency load/install failure when dependency is in `M.specs`

- **File:** `lua/resonance/loader/init.lua`
- **Problem:** In `load_now()`, inline dependencies (`else` branch) call `return fail_install(...)` when install fails, aborting the parent plugin. Dependencies registered via `resonance.load()` (`if spec_name and M.specs[spec_name]`) call `fn(nil, visiting_path)` (`force_load_fns[spec_name]`) and ignore the result—so if the dependency fails `pack_install`/`is_installed`, the parent still installs and executes `setup()` with a broken dependency.
- **Fix:** Have `load_now()` return `boolean` (`true` on success or already-loaded, `false` on `fail_install` or cycle abort) and abort the parent with `fail_install()` if any dependency call returns `false`. Add a behavioral test in `test/behavior_spec.lua`.

### 4b. **FIXED** — The `r` key spams "Resonating in background..." notifications

- **Severity:** UX — the user can hold `r` and stack unlimited notifications. Reported by the user on 2026-11-17.
- **Files:** `lua/resonance/ui/init.lua` (the `r` keymap), `lua/resonance/ui/actions.lua` (`check_updates_network`)
- **Problem:** the re-entrancy guard lives **inside** `actions.check_updates_network()`, but the notification lives **in the keymap**, outside the guard:

  ```lua
  map('r', function()
    actions.check_updates_network()
    utils.notify('Resonating in background...', vim_log_levels.INFO)  -- always fires
  end, 'Fetch Updates')
  ```

  `check_updates_network()` correctly returns early when `st.state.checking` is true — but the function returns nothing, so the keymap cannot tell. The notification fires on every press regardless.
- **Reproduction (verified, headless):**

  ```text
  SPAM_NOTES=3
  N[1]=Resonating in background...
  N[2]=Resonating in background...
  N[3]=Resonating in background...
  ```

- **Desired behaviour (user):** notify once, and **block** `r` while the check is running — subsequent presses must do nothing, not queue a second check.
- **Fix:** make `check_updates_network()` return a boolean (`true` if it started a check, `false` if one was already running) and notify only on `true`. Alternatively move the notification into `actions.check_updates_network()` and delete it from the keymap. Do **not** unmap/remap `r` — the key must stay inert without extra moving parts.
- **Verification:** a behavioural test that presses `r` twice and asserts exactly **one** notification and that `check_updates_network()` is not re-entered. Must fail before the fix.

#### Status: fixed

`check_updates_network()` now returns `true` when it initiated a check and
`false` when one was already running. The `r` keymap notifies only on `true`,
so the key is **inert** while a check is in flight — it neither notifies
again nor queues a second check.

**Tests** (`test/ui_spec.lua`):

- `actions: check_updates_network reports whether it started a check`
- `ui: the r key notifies once and stays inert while checking` — drives the
  real buffer-local keymap through `nvim_feedkeys`, with the spawner stubbed
  so the check stays in flight.

**Mutation-verified** in both directions:

| Mutation | Test that fails |
|---|---|
| keymap reverted to unconditional notify | `ui: the r key notifies once and stays inert while checking` (`Actual: 2`) |
| guard weakened to return `true` while already checking | both N1 tests |

**End-to-end:** 5 presses against a held-open fetch → **1** notification.

### 5. **FIXED** — Reset `pending_count` and skip empty paths in `check_updates_network()`

- **Files:** `lua/resonance/ui/actions.lua`, `lua/resonance/ui/init.lua`
- **Problem:**
  - `actions.check_updates_network()` clears `st.state.updates = {}` but never resets `st.state.pending_count = 0` (nor does `ui.open()`), so repeated `r` presses accumulate a bogus count in the spinner.
  - `check_updates_network()` loops `1..info.total` without skipping `path == ''` (plugins disabled via `cond = false` and not on disk), spawning `git fetch` with `{ cwd = '' }`.
- **Fix:** Reset `st.state.pending_count = 0` at the start of `check_updates_network()` and in `ui.open()`. Filter out entries where `not path or path == ''` (or missing `/.git`) before counting `valid_total` and spawning `git fetch`; call `finish_check()` if `valid_total == 0`. Add behavioral tests in `test/behavior_spec.lua`.

#### Status: fixed

- `st.state.pending_count = 0` is now reset at the start of
  `check_updates_network()` and in `ui.open()`.
- The fetch loop counts only the plugins with a non-empty path
  (`valid_total`) and spawns `git fetch` only for those. A plugin disabled
  via `cond = false` no longer produces a `git fetch` with `{ cwd = '' }`.
- When `valid_total == 0` the check completes on the next tick instead of
  spawning any process.

**Tests** (`test/ui_spec.lua`):

- `actions: check_updates_network resets the pending count`
- `actions: check_updates_network skips plugins without a path` — stubs the
  spawner and asserts exactly one fetch, for the plugin with a path.

**Mutation-verified:**

| Mutation | Test that fails |
|---|---|
| `pending_count` reset removed | `actions: check_updates_network resets the pending count` (`Expected: 0, Actual: 7`) |
| path filter removed | `actions: check_updates_network skips plugins without a path` (`Expected: 1, Actual: 2`) |

### 7. **FIXED** — Cancel `details_task` and clean UI state on `BufWipeout` (e.g. `:q`)

- **File:** `lua/resonance/ui/init.lua`
- **Problem:** `cancel_details_task()` is only wired to `q` and `<Esc>` keymaps. Closing the window via `:q` or `<C-w>c` leaves `details_task` uncancelled and `st.state.buf` non-nil, so Pass 2 still runs `pack.get(info=true)` after 50ms.
- **Fix:** Register a `BufWipeout` autocmd (`once = true`, `buffer = st.state.buf`) inside `ui.open()` that calls `cancel_details_task()` and clears `st.state.win, st.state.buf = nil, nil`. Add a test closing the UI window via `nvim_win_close` / `:bwipeout` and verifying `details_task` is cancelled.

### 8. **FIXED** — Clean up sibling triggers after load & fix `keys`/`cmd` stub edge cases

- **Files:** `lua/resonance/loader/triggers.lua`, `lua/resonance/loader/init.lua`
- **Problem:**
  - When a plugin has multiple triggers (e.g. `cmd` + `keys` + `event`), firing one leaves the other stubs active.
  - `register_keys()`: `opts.buffer = true` passes boolean `true` to `del_keymap(..., { buf = target_buf })` (expects integer buffer ID); `opts.expr = true` is not handled; `feedkeys(term_key, 'm', false)` forces remapping on string `rhs` even when `noremap` (default) was intended.
  - `register_cmd()`: stub hardcodes `range = true, complete = 'file'` regardless of command behavior.
- **Fix:** Collect per-spec teardown callbacks during `register_all()` and invoke them once `load_now()` succeeds; normalize `opts.buffer == true` to `0`/current buf; respect `opts.remap` (`'mi'` vs `'ni'`) and handle `opts.expr` when replaying `rhs`.

---

## P1 — Performance (300-Plugin Scaling) & Memory Retention

### 9. **FIXED** — Lazy-load `branches` / `tags` on `<CR>` expand instead of bulk `info = true` on UI open

- **Files:** `lua/resonance/ui/init.lua`, `lua/resonance/ui/actions.lua`
- **Problem:** Pass 2 (`details_task` in `ui/init.lua`) calls `vim.pack.get(nil, { offline = true, info = true })` for **every** installed plugin 50ms after opening (~420ms at 49 plugins, ~2.5s main-thread freeze at 300 plugins), even though `branches` and `tags` are only rendered when a row is expanded via `<CR>`.
- **Fix:** Remove the bulk 50ms `info = true` Pass 2 from `ui.open()`. In `actions.toggle_details()`, when expanding `name` and `st.state.pack_details[name]` does not yet have `branches`/`tags`, query `pack.get({ name }, { offline = true, info = true })` for just that single plugin and re-render.

### 10. **FIXED** — Bound startup `check_and_build` concurrency & avoid unnecessary `git` spawns

- **Files:** `lua/resonance/loader/build.lua`, `lua/resonance/ui/state.lua`
- **Problem:** `check_and_build()` spawns an unbounded `git rev-parse HEAD` subprocess via `async.run` for every plugin with a `build` hook at startup. Also, `run_build()` calls `mark_build_success()` immediately after `build_task(dir)` returns, even if a Lua `build` function spawns async work.
- **Fix:** Gate `git rev-parse HEAD` behind a bounded semaphore (or read `.git/HEAD` / `packed-refs` directly via `vim.uv`, sharing a helper with `ui/state.lua` so zero subprocesses are spawned on startup); document or support a completion callback for async Lua `build` hooks.

### 11. **FIXED** — Fix contradictory allocations in `ui/render.lua` & deduplicate `ui.open()` renders

- **Files:** `lua/resonance/ui/render.lua`, `lua/resonance/ui/init.lua`
- **Problem:** `nl()` sets `line_parts = {}` on every line despite `table_clear(line_parts)` in `reset_render_state()`; `reset_render_state()` allocates fresh `st.state.line_to_name = {}` and `st.state.name_to_line = {}`; `ui.open()` performs a synchronous `render()` plus `chunk()` `schedule_render()` plus a trailing `schedule_render()`.
- **Fix:** Use `table_clear(line_parts)` in `nl()`, `table_clear(st.state.line_to_name)` / `table_clear(st.state.name_to_line)` in `reset_render_state()`, and drop the duplicate trailing `schedule_render()` in `ui.open()`.

### 12. **FIXED** — Prune long-session memory retention

- **Files:** `lua/resonance/loader/init.lua`, `lua/resonance/ui/actions.lua`, `lua/resonance/ui/init.lua`, `lua/resonance/ui/render.lua`
- **Fix:**
  - Add `BufWipeout` autocmd in `ResonanceEventTracker` to set `fired_events[args.buf] = nil`.
  - After a plugin finishes loading successfully (`member_state.loaded = true`), clear `config.setup = nil` / `config.config = nil` (and per-plugin `setup` refs) so user config closures can be garbage collected.
  - In `actions.uninstall_plugin()`, prune `pack_details[name]`, `urls[name]`, `commits[name]`, `updates[name]`, `expanded[name]`, and `scanner.load_times[name]`.
  - Clear `render.lua` module-level `lines` / `hls` on UI close (`BufWipeout`).

---

## P2 — Architecture, Cache Consistency, Tests & Docs

### 13. **FIXED** — Move `.resonance_built` to `stdpath('state')` & invalidate `_plugin_dir_cache`

- **Files:** `lua/resonance/loader/build.lua`, `lua/resonance/loader/init.lua`
- **Fix:** Store build hash markers under `vim.fn.stdpath('state') .. '/resonance/builds/' .. name` (migrating/ignoring old markers cleanly) so plugin git repos are not dirtied. Update or clear `_plugin_dir_cache` on `PackChanged` (`install`/`delete`) and after `pack_install()`.

### 14. **FIXED** — Break `scanner` ↔ `loader` circular dependency & stop mutating user specs

- **Files:** `lua/resonance/scanner.lua`, `lua/resonance/utils.lua`, `lua/resonance/loader/init.lua`, `lua/resonance/loader/spec.lua`, `lua/resonance/ui/render.lua`
- **Fix:**
  - Extract a pure-data `lua/resonance/registry.lua` holding `specs`, `plugin_triggers`, `disabled_plugins`, and `load_times`; move `setup_event_tracker()` and `setup_packchanged_autocmd()` out of module require-time into `resonance.setup()` / first `load()`.
  - Stop mutating caller-owned `config` tables in `spec.parse_config()` and `load_now()` (`config._replay_done` should live in `plugin_state` / `registry`).
  - *(Optional cleanup)* Replace the 9-array SoA + `apply_sort()` in `scanner.lua` / `utils.lua` with a plain array of plugin entry tables sorted in-place.

### 15. **FIXED** — Fix `M.stats()` caching & implement `M._reset()`

- **File:** `lua/resonance/init.lua`
- **Problem:** `M.stats()` freezes `loaded` and `count` on first call forever; `test/runner.lua` checks `resonance._reset()`, which does not exist.
- **Fix:** Freeze only `startuptime` (`_end_time`) at `UIEnter`/`VimEnter` or first `stats()` call; read `count`, `loaded`, and `times` dynamically from `scanner.get_info()`. Implement `M._reset()` to clear `M._cached_stats`, `M._end_time`, and `loader_mod`.

### 16. **FIXED** — Fix `test/build_spec.lua` async false positive & align documentation

- **Files:** `test/build_spec.lua`, `doc/resonance.txt`, `README.md`, `AGENTS.md`
- **Fixes:**
  - `test/build_spec.lua` (`check_and_build: skips when hash matches`): add a real temp git repo (or deterministic revision) and `vim.wait()` so the assertion actually tests the async completion rather than passing before `async.run` executes.
  - `doc/resonance.txt`:
    - Fix `setup()` (UI options only) vs `load()` (plugin specs) signatures;
    - Remove non-existent `open_ui([ui_config])` parameter;
    - Remove unimplemented `ResonanceLoad` / `ResonanceUpdate` / `ForceLoad<Name>` events from Section 7;
    - Resolve contradiction on line 153 (`lazy = true -- Cannot combine with explicit event/cmd/keys/ft` vs `README.md` stating it adds `VeryLazy` as fallback).
  - `README.md`: Update the `version = 'v1.0.0'` example to include `lazy = false` or a trigger (or align with item 3), and clarify `vim.pack.add` vs `resonance.load` in Method 1 bootstrap.
  - `AGENTS.md`: Remove unrelated `Jisho.org` / kana copy-paste from Section 7, correct the `p.active` claim in Section 3 (actual code checks `rtp`), and separate plugin-only vs full-Neovim numbers in Section 4.

---

## P3 — Newly verified (2026-11-18)

Every item below was checked against the installed copy, not inferred.

### 17. **`register_keys` deletes the plugin's real mapping when the shorthand has no `rhs`** — HIGH

- **File:** `lua/resonance/loader/triggers.lua`
- **Problem:** `keys = { '<leader>Tg' }` — the shorthand with no `rhs` — means "the plugin
  defines this mapping itself". When the plugin loads, its `setup()` creates the real
  mapping, and the teardown that follows deletes it:

  ```lua
  local function restore_keymap()
    local del_opts = is_buffer and { buf = target_buf } or {}
    pcall(del_keymap, mode, lhs, del_opts)      -- deletes whatever is there now
    if rhs and config.restore_keys ~= false then
      set_keymap(mode, lhs, rhs, restore_opts)   -- ...and rhs is nil, so nothing is restored
    end
  end
  ```

  The delete is unconditional, so it removes the plugin's mapping, not just the stub.
  `rhs` being nil means nothing is put back. The user's shortcut is silently dead.
- **Verified (both paths):**

  | Path | Before | After the load |
  |---|---|---|
  | the key itself fired | `rhs=nil callback=true` | `rhs=nil callback=nil` — **gone** |
  | a sibling trigger fired | `rhs=nil callback=true` | `rhs=nil callback=nil` — **gone** |

- **Fix:** keep a reference to the stub callback and check whether the mapping at
  teardown time is still that stub. Only then is it the stub to remove; if the plugin
  has already taken the mapping over, leave it alone. When `rhs` is nil, the stub
  must not delete anything the plugin owns.
- **Also in the same function:**
  - `local feed_mode = opts.noremap and 'n' or 'm'` is inverted. `vim.keymap.set` is
    noremap by default; `opts.noremap` is nil unless the user asks for it. So a key
    with no options is replayed with `'m'` — forced remapping. It should be
    `(opts.remap == true or opts.noremap == false) and 'm' or 'n'`.
  - The mapping is set twice when the key fires: `restore_keymap()` sets it, then the
    stub callback sets it again. Same mapping, same options — harmless, but redundant.

#### Status: fixed

The teardown now compares the installed mapping's callback against the stub's. The
delete only happens while the stub is still installed, so a mapping the plugin took
over is left alone.

The comparison is on the callback rather than the lhs, because the keymap API
reports an lhs in its own notation: `<C-x>` comes back as `<C-X>` and `<Space>` as
a plain space. A string comparison would miss those.

Three buffer-handling defects surfaced while fixing this:

- `opts.buffer = false` means the mapping is **global**, but the old `is_buffer`
  check treated any non-nil buffer option as buffer-local. The lookup then asked
  for the keymap of a buffer that does not exist (`Invalid 'buf': Expected Lua
  number`).
- `opts.buf = 0` means the current buffer when the mapping is **set**, but the
  teardown deleted from whatever was current **later**. The buffer is now resolved
  to an id at registration time, so both the set and the delete target the same
  buffer.
- The double `set_keymap` is gone: the stub removes itself on the way in, so the
  teardown finds no stub and does nothing.

**Tests** (`test/behavior_triggers_spec.lua`, `test/triggers_spec.lua`):

| Test | Covers |
|---|---|
| `a key shorthand without an rhs keeps the plugin own mapping` | the sibling-trigger path |
| `a key shorthand without an rhs keeps its mapping when the key fires` | the key-fired path |
| `a keymap with an rhs is still restored after the load` | the normal case did not regress |
| `a keymap with buffer=false is treated as a global mapping` | the global-mapping case |
| `a keymap with buf=0 is deleted from the buffer it was set on` | the buffer-id resolution |
| `a string rhs is fed without remapping by default` | the inverted feed mode |
| `remap = true feeds the rhs with remapping` | the inverse of the default |

**Mutation-verified:**

| Mutation | Test that fails |
|---|---|
| the conditional delete removed | both `a key shorthand without an rhs` tests |
| `feed_mode` reverted to the inverted form | `a string rhs is fed without remapping by default` |
| `buf = 0` not resolved, `is_buffer` reverted | `buffer=false` and `buf=0` tests |

### 18. **FIXED** — **`register_cmd` raises `E1208` when the command takes no arguments** — MEDIUM

- **File:** `lua/resonance/loader/triggers.lua`
- **Problem:** the command defaults are `{ nargs = '*', bang = true, range = true,
  complete = 'file' }`. A spec with `cmd = { name = 'X', opts = { nargs = 0 } }` merges
  to `nargs = 0` with `complete = 'file'` still set, and Neovim rejects that:

  ```
  'complete' used without 'nargs'
  ```

  The error escapes `resonance.load()` and the plugin is never registered.
- **Verified:** `load ok: false` — `triggers.lua:118: 'complete' used without 'nargs'`.
- **Fix:** drop `complete` when `nargs` is `0` (or `'0'`), unless the user set it
  explicitly.

#### Status: fixed

The default `complete = 'file'` is dropped when `nargs` is `0` and the user did not
ask for a completion. A completion the user set explicitly is left alone — if it is
invalid, Neovim reports it.

The error was worse than a missing command: it escaped `resonance.load()` and
aborted the whole call, so the spec's **other** triggers were never registered
either. A spec with a bad command and an event trigger ended up with neither.

**Tests** (`test/behavior_triggers_spec.lua`):

| Test | Covers |
|---|---|
| `a command that takes no arguments is registered` | the command exists, with `nargs = '0'` |
| `a command that takes no arguments keeps the other triggers` | the error no longer aborts the load |
| `a command that takes no arguments is invoked` | the registered command actually loads the plugin |

**Mutation-verified:** removing the guard fails all three tests
(`'complete' used without 'nargs'`).

**Note:** the `Execution failed: Command not found` notice a stub produces when the
plugin does not define its own command is pre-existing behavior, not part of this
fix. It was checked against the code before the change and reports the same.

### 19. **FIXED** — **`force_load_fns` keeps the user's `setup` closure alive for the whole session** — MEDIUM

- **File:** `lua/resonance/loader/init.lua`
- **Problem:** `retained_spec()` drops `setup` from the registry copy, so the registry
  does not hold it. But `force_load_fns[name] = load_now` stores the `load_now`
  closure, whose upvalue is `config` — and `config.setup` is the user's closure. It
  is never released.
- **Verified:** holding the setup closure weakly and clearing `force_load_fns` releases
  it immediately:

  ```
  after clearing force_load_fns, closure alive: false
  ```

  With `force_load_fns` intact the closure is still alive after the load.
- **Fix:** clear `config.setup` / `config.config` (and the per-plugin `setup` /
  `config`) once the members have loaded and `member_state.loaded = true`.

#### Status: fixed

The setup closures are released once the members have loaded, right after the setup
call. Both shapes are covered: `config.setup` at the top level of the spec, and
`setup` inside a member of the `plugin` list.

The release happens **after** the setup has run, so the setup still runs exactly
once. Verified against the code before the change: a two-member spec still runs
both setups, in order, and a second spec for an already-loaded plugin still does
not re-run its setup.

**Tests** (`test/behavior_arch_spec.lua`):

| Test | Covers |
|---|---|
| `the setup closure is released after the plugin loads` | `config.setup` |
| `a per-plugin setup closure is released after the plugin loads` | the `plugin` list shape |
| `releasing the setup does not stop it from running` | the setup still runs exactly once |

**Mutation-verified:** removing the release fails both release tests
(`the setup closure is still reachable after the load`).

### 20. **FIXED** — **`test/behavior_ui_spec.lua` asserts `#name_to_line == 0`, which is always true** — LOW

- **File:** `test/behavior_ui_spec.lua`
- **Problem:** `helpers.count(t)` is `#t`. `name_to_line` is keyed by plugin name
  (strings), and `#` on a table with only string keys is always `0`. So

  ```lua
  test.assert_eq(count(st.name_to_line), 0, ...)
  ```

  passes whether or not the map was cleared. The neighbouring assertion on
  `line_to_name` happens to work only because its keys are integers — and `#` on a
  sparse integer table is not the length either.
- **Fix:** assert with `next(st.name_to_line) ~= nil` before the close and
  `next(st.name_to_line) == nil` after. Same for `line_to_name`.

#### Status: fixed

A `map_count` helper was added to `test/helpers.lua`: it walks the table instead of
using the length operator, so it counts the entries whatever the keys are.

The test now asserts on both maps with it, and the "the UI rendered no rows" guard
covers `name_to_line` too — before, that map was never checked for being populated,
so the test would have passed against a UI that rendered no names at all.

**Verified against the old assertion:** with 49 entries in `name_to_line`,
`count(st.name_to_line) == 0` was still **true** — the assertion could never fail.
The new assertion reports the entries.

**Mutation-verified:** removing the close-time cleanup in `render.clear()` now fails
the test (`Expected: 0, Actual: 49`). It passed before the fix.

### 21. **`utils.normalize_events()` drops a table `pattern`** — LOW

- **File:** `lua/resonance/utils.lua`
- **Problem:** only `type(event.pattern) == 'string'` is kept. Neovim accepts a list of
  patterns, so `event = { 'BufReadPost', pattern = { '*.lua', '*.vim' } }` loses its
  patterns.
- **Verified:** `event[1] event=BufReadPost pattern=nil`.
- **Fix:** accept a table as well as a string.

### 22. **`fetch_plugin_details` does not cancel the previous task** — LOW

- **File:** `lua/resonance/ui/actions.lua`
- **Problem:** `st.state.details_task = task` overwrites the previous task without
  cancelling it. `cancel_details_task()` exists in `ui/init.lua`, but only the UI
  close path uses it.
- **Verified:** expanding two rows in a row runs **two** `info = true` fetches
  (`detail_calls: 2`) — the first one was never cancelled.
- **Impact:** redundant work, not corruption: each task writes to its own name key.
- **Fix:** cancel the previous task before starting a new one.

### 23. **`marker_path` does not sanitize the plugin name** — LOW

- **File:** `lua/resonance/loader/build.lua`
- **Problem:** `marker_dir .. '/' .. name` — a name with a `/` in it builds a path in a
  directory that does not exist, and the write is silently dropped.
- **Verified:** `mark_build_success('evil/name', ...)` returns without error, but
  nothing is written: `evil/name written: false`, `evil dir created: false`. The
  build cache is lost for that plugin, so it rebuilds on every check.
- **Fix:** replace anything outside `[%w_.-]` with `_`, the way
  `triggers.trigger_group_name` does.

---

## Suggested Execution Batches

> **See `plan.md`** for the consolidated, code-verified plan of everything still
> open. This list is the same sequencing, kept here for history.

0. **Batch 0 (REGRESSION) — DONE:** Items `0` and `1`. The UI was broken on `nvim <file>` and open-from-yazi; both are fixed and mutation-verified. Item 1 (restoring the test coverage) had to land first: the replay assertions were vacuous, so there was no safety net to prove the item 0 fix. Item 6 (invalid-buffer guard) landed as part of the item 0 fix and has been removed from this list.
1. **Batch 1 (Tests & P0 bugs) — DONE:** Items `2, 3, 4, 4b, 5, 7`. Item 4b is the user-reported `r`-key notification spam.
2. **Batch 2 (Performance, Triggers & GC) — DONE:** Items `8, 9, 11, 12`
3. **Batch 3 (Architecture, Build State & Docs) — DONE:** Items `10, 13, 14, 15, 16`
4. **Batch 4 (Newly verified) — OPEN:** Items `21`–`23`. Items `17` (broke a user's shortcut),
   `18` (crashed the whole load on a valid config), `19` (retained a closure) and `20` (a
   vacuous assertion) are **fixed**. The rest are three small losses.
