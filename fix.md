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

### 2. Fix `lazy = true` combined with `event` crashing and dropping triggers

- **Files:** `lua/resonance/loader/spec.lua`, `lua/resonance/utils.lua`, `lua/resonance/loader/triggers.lua`
- **Problem:**
  - In `spec.parse_config()`, when `lazy = true` is combined with `event = 'BufReadPre'` (or `event = { 'BufReadPre', 'BufNewFile' }`), `config.event` becomes `{ 'BufReadPre', { 'User', pattern = 'VeryLazy' } }`.
  - `utils.parse_trigger()` then calls `table_concat(ev, ', ')`, which crashes on the nested table entry.
  - `triggers.register_event()` enters the `else` branch (`ev[1] ~= 'User'`), filters only `type(ev[i]) == 'string'`, and silently drops `{ 'User', pattern = 'VeryLazy' }`.
  - If the original `event` was `{ 'User', pattern = 'Custom' }`, `table.insert(event, { 'User', pattern = 'VeryLazy' })` turns `ev[2]` into a table and corrupts `opts.pattern` in `register_event()`.
- **Fix:** Normalize multi-event / mixed `User` + native event specs cleanly across `spec.parse_config()`, `utils.parse_trigger()`, and `triggers.register_event()` (e.g., register each `User` entry separately from plain event names instead of mixing tables into a string list).
- **Verification:** Add end-to-end tests in `test/behavior_spec.lua` (with `test.stub_pack()`) calling `resonance.load()` for `lazy = true` + string `event`, array `event`, and `{ 'User', pattern = ... }`, verifying both the primary event and `VeryLazy` can trigger loading without errors.

### 3. Handle specs with neither triggers nor `lazy`

- **Files:** `lua/resonance/loader/spec.lua`, `lua/resonance/loader/init.lua`
- **Problem:** A spec with no `event`/`cmd`/`keys`/`ft` and `lazy == nil` (like the `version = 'v1.0.0'` example in `README.md`) registers nothing in `triggers.register_all()`. It is silently never installed and never loaded unless referenced as a dependency.
- **Fix:** Choose explicit behavior—either default triggerless specs (`lazy == nil` and no `event`/`cmd`/`keys`/`ft`) to `lazy = false` (`VimEnter`, or `VeryLazy` if preferred, updating docs to match), or emit a clear `utils.notify(..., vim.log.levels.WARN)` warning when a top-level spec has no triggers. Add a test in `test/behavior_spec.lua`.

### 4. Propagate dependency load/install failure when dependency is in `M.specs`

- **File:** `lua/resonance/loader/init.lua`
- **Problem:** In `load_now()`, inline dependencies (`else` branch) call `return fail_install(...)` when install fails, aborting the parent plugin. Dependencies registered via `resonance.load()` (`if spec_name and M.specs[spec_name]`) call `fn(nil, visiting_path)` (`force_load_fns[spec_name]`) and ignore the result—so if the dependency fails `pack_install`/`is_installed`, the parent still installs and executes `setup()` with a broken dependency.
- **Fix:** Have `load_now()` return `boolean` (`true` on success or already-loaded, `false` on `fail_install` or cycle abort) and abort the parent with `fail_install()` if any dependency call returns `false`. Add a behavioral test in `test/behavior_spec.lua`.

### 4b. The `r` key spams "Resonating in background..." notifications

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

### 5. Reset `pending_count` and skip empty paths in `check_updates_network()`

- **Files:** `lua/resonance/ui/actions.lua`, `lua/resonance/ui/init.lua`
- **Problem:**
  - `actions.check_updates_network()` clears `st.state.updates = {}` but never resets `st.state.pending_count = 0` (nor does `ui.open()`), so repeated `r` presses accumulate a bogus count in the spinner.
  - `check_updates_network()` loops `1..info.total` without skipping `path == ''` (plugins disabled via `cond = false` and not on disk), spawning `git fetch` with `{ cwd = '' }`.
- **Fix:** Reset `st.state.pending_count = 0` at the start of `check_updates_network()` and in `ui.open()`. Filter out entries where `not path or path == ''` (or missing `/.git`) before counting `valid_total` and spawning `git fetch`; call `finish_check()` if `valid_total == 0`. Add behavioral tests in `test/behavior_spec.lua`.

### 7. Cancel `details_task` and clean UI state on `BufWipeout` (e.g. `:q`)

- **File:** `lua/resonance/ui/init.lua`
- **Problem:** `cancel_details_task()` is only wired to `q` and `<Esc>` keymaps. Closing the window via `:q` or `<C-w>c` leaves `details_task` uncancelled and `st.state.buf` non-nil, so Pass 2 still runs `pack.get(info=true)` after 50ms.
- **Fix:** Register a `BufWipeout` autocmd (`once = true`, `buffer = st.state.buf`) inside `ui.open()` that calls `cancel_details_task()` and clears `st.state.win, st.state.buf = nil, nil`. Add a test closing the UI window via `nvim_win_close` / `:bwipeout` and verifying `details_task` is cancelled.

### 8. Clean up sibling triggers after load & fix `keys`/`cmd` stub edge cases

- **Files:** `lua/resonance/loader/triggers.lua`, `lua/resonance/loader/init.lua`
- **Problem:**
  - When a plugin has multiple triggers (e.g. `cmd` + `keys` + `event`), firing one leaves the other stubs active.
  - `register_keys()`: `opts.buffer = true` passes boolean `true` to `del_keymap(..., { buf = target_buf })` (expects integer buffer ID); `opts.expr = true` is not handled; `feedkeys(term_key, 'm', false)` forces remapping on string `rhs` even when `noremap` (default) was intended.
  - `register_cmd()`: stub hardcodes `range = true, complete = 'file'` regardless of command behavior.
- **Fix:** Collect per-spec teardown callbacks during `register_all()` and invoke them once `load_now()` succeeds; normalize `opts.buffer == true` to `0`/current buf; respect `opts.remap` (`'mi'` vs `'ni'`) and handle `opts.expr` when replaying `rhs`.

---

## P1 — Performance (300-Plugin Scaling) & Memory Retention

### 9. Lazy-load `branches` / `tags` on `<CR>` expand instead of bulk `info = true` on UI open

- **Files:** `lua/resonance/ui/init.lua`, `lua/resonance/ui/actions.lua`
- **Problem:** Pass 2 (`details_task` in `ui/init.lua`) calls `vim.pack.get(nil, { offline = true, info = true })` for **every** installed plugin 50ms after opening (~420ms at 49 plugins, ~2.5s main-thread freeze at 300 plugins), even though `branches` and `tags` are only rendered when a row is expanded via `<CR>`.
- **Fix:** Remove the bulk 50ms `info = true` Pass 2 from `ui.open()`. In `actions.toggle_details()`, when expanding `name` and `st.state.pack_details[name]` does not yet have `branches`/`tags`, query `pack.get({ name }, { offline = true, info = true })` for just that single plugin and re-render.

### 10. Bound startup `check_and_build` concurrency & avoid unnecessary `git` spawns

- **Files:** `lua/resonance/loader/build.lua`, `lua/resonance/ui/state.lua`
- **Problem:** `check_and_build()` spawns an unbounded `git rev-parse HEAD` subprocess via `async.run` for every plugin with a `build` hook at startup. Also, `run_build()` calls `mark_build_success()` immediately after `build_task(dir)` returns, even if a Lua `build` function spawns async work.
- **Fix:** Gate `git rev-parse HEAD` behind a bounded semaphore (or read `.git/HEAD` / `packed-refs` directly via `vim.uv`, sharing a helper with `ui/state.lua` so zero subprocesses are spawned on startup); document or support a completion callback for async Lua `build` hooks.

### 11. Fix contradictory allocations in `ui/render.lua` & deduplicate `ui.open()` renders

- **Files:** `lua/resonance/ui/render.lua`, `lua/resonance/ui/init.lua`
- **Problem:** `nl()` sets `line_parts = {}` on every line despite `table_clear(line_parts)` in `reset_render_state()`; `reset_render_state()` allocates fresh `st.state.line_to_name = {}` and `st.state.name_to_line = {}`; `ui.open()` performs a synchronous `render()` plus `chunk()` `schedule_render()` plus a trailing `schedule_render()`.
- **Fix:** Use `table_clear(line_parts)` in `nl()`, `table_clear(st.state.line_to_name)` / `table_clear(st.state.name_to_line)` in `reset_render_state()`, and drop the duplicate trailing `schedule_render()` in `ui.open()`.

### 12. Prune long-session memory retention

- **Files:** `lua/resonance/loader/init.lua`, `lua/resonance/ui/actions.lua`, `lua/resonance/ui/init.lua`, `lua/resonance/ui/render.lua`
- **Fix:**
  - Add `BufWipeout` autocmd in `ResonanceEventTracker` to set `fired_events[args.buf] = nil`.
  - After a plugin finishes loading successfully (`member_state.loaded = true`), clear `config.setup = nil` / `config.config = nil` (and per-plugin `setup` refs) so user config closures can be garbage collected.
  - In `actions.uninstall_plugin()`, prune `pack_details[name]`, `urls[name]`, `commits[name]`, `updates[name]`, `expanded[name]`, and `scanner.load_times[name]`.
  - Clear `render.lua` module-level `lines` / `hls` on UI close (`BufWipeout`).

---

## P2 — Architecture, Cache Consistency, Tests & Docs

### 13. Move `.resonance_built` to `stdpath('state')` & invalidate `_plugin_dir_cache`

- **Files:** `lua/resonance/loader/build.lua`, `lua/resonance/loader/init.lua`
- **Fix:** Store build hash markers under `vim.fn.stdpath('state') .. '/resonance/builds/' .. name` (migrating/ignoring old markers cleanly) so plugin git repos are not dirtied. Update or clear `_plugin_dir_cache` on `PackChanged` (`install`/`delete`) and after `pack_install()`.

### 14. Break `scanner` ↔ `loader` circular dependency & stop mutating user specs

- **Files:** `lua/resonance/scanner.lua`, `lua/resonance/utils.lua`, `lua/resonance/loader/init.lua`, `lua/resonance/loader/spec.lua`, `lua/resonance/ui/render.lua`
- **Fix:**
  - Extract a pure-data `lua/resonance/registry.lua` holding `specs`, `plugin_triggers`, `disabled_plugins`, and `load_times`; move `setup_event_tracker()` and `setup_packchanged_autocmd()` out of module require-time into `resonance.setup()` / first `load()`.
  - Stop mutating caller-owned `config` tables in `spec.parse_config()` and `load_now()` (`config._replay_done` should live in `plugin_state` / `registry`).
  - *(Optional cleanup)* Replace the 9-array SoA + `apply_sort()` in `scanner.lua` / `utils.lua` with a plain array of plugin entry tables sorted in-place.

### 15. Fix `M.stats()` caching & implement `M._reset()`

- **File:** `lua/resonance/init.lua`
- **Problem:** `M.stats()` freezes `loaded` and `count` on first call forever; `test/runner.lua` checks `resonance._reset()`, which does not exist.
- **Fix:** Freeze only `startuptime` (`_end_time`) at `UIEnter`/`VimEnter` or first `stats()` call; read `count`, `loaded`, and `times` dynamically from `scanner.get_info()`. Implement `M._reset()` to clear `M._cached_stats`, `M._end_time`, and `loader_mod`.

### 16. Fix `test/build_spec.lua` async false positive & align documentation

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

## Suggested Execution Batches

> **See `plan.md`** for the consolidated, code-verified plan of everything still
> open. This list is the same sequencing, kept here for history.

0. **Batch 0 (REGRESSION) — DONE:** Items `0` and `1`. The UI was broken on `nvim <file>` and open-from-yazi; both are fixed and mutation-verified. Item 1 (restoring the test coverage) had to land first: the replay assertions were vacuous, so there was no safety net to prove the item 0 fix. Item 6 (invalid-buffer guard) landed as part of the item 0 fix and has been removed from this list.
1. **Batch 1 (Tests & P0 bugs):** Items `2, 3, 4, 4b, 5, 7`. Item 4b is the user-reported `r`-key notification spam.
2. **Batch 2 (Performance, Triggers & GC):** Items `8, 9, 11, 12`
3. **Batch 3 (Architecture, Build State & Docs):** Items `10, 13, 14, 15, 16`
