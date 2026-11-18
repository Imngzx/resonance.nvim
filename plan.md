# resonance.nvim — Open Issues Plan

> **Branch:** `fix`
> **Baseline:** `24160c7`
> **Compiled:** 2026-11-17, refreshed 2026-11-18 by cross-checking `fix.md`,
> `note/knowledge/fix-notes.md`, and the actual Lua source. Every item below was
> **verified against the code** — and Batch 4 against the **installed copy** —
> not copied from the notes.
>
> **Status:** items 0–21 are **resolved**. Batch 4 items 22–23 are **open**.

---

## How this list was built

Three sources were merged and each claim was re-checked against the current
source:

| Source | Items | Result |
|---|---|---|
| `fix.md` | 0–16 | **all done** |
| `note/knowledge/fix-notes.md` | P1/P2/P3 lists | reconciled with the source on 2026-11-18 |
| `note/knowledge/plan-2026-11-17.md` | items 0–4 | **done** (previous session) |
| User report (this session) | `r` key notification spam | **confirmed by reproduction** |
| Fresh audit (2026-11-18) | 17–23 | **confirmed on the installed copy** — Batch 4 |

Items already resolved are listed under "Already resolved" in `fix.md` and are
**not** repeated in the work batches.

---

## New issues reported by the user

### N1. **RESOLVED** — The `r` key spams "Resonating in background..." notifications

- **Severity:** UX — the user can hold `r` and stack unlimited notifications.
- **File:** `lua/resonance/ui/init.lua:46-50` (the keymap), `lua/resonance/ui/actions.lua:55-57` (the guard).
- **Root cause:** the re-entrancy guard lives **inside**
  `actions.check_updates_network()`, but the notification lives **in the
  keymap**, outside the guard:

  ```lua
  map('r', function()
    actions.check_updates_network()
    utils.notify('Resonating in background...', vim_log_levels.INFO)  -- always fires
  end, 'Fetch Updates')
  ```

  `check_updates_network()` correctly returns early when
  `st.state.checking` is true — but the keymap cannot tell, because the
  function returns nothing. The notification therefore fires on every
  press regardless.
- **Reproduction (verified, headless):**

  ```text
  SPAM_NOTES=3
  N[1]=Resonating in background...
  N[2]=Resonating in background...
  N[3]=Resonating in background...
  ```

- **Desired behaviour (user's words):** "I prefer notify and blocks the user r
  during resonating (after user pressed r)". So: **one** notification on the
  first press, and subsequent presses during the check do nothing — no second
  notification, and the key is inert until the check finishes.
- **Fix options:**
  1. Make `check_updates_network()` return a boolean (`true` if it started a
     check, `false` if one was already running) and notify only on `true`.
     Smallest change; the guard stays where the state lives.
  2. Move the notification into `actions.check_updates_network()` and delete
     it from the keymap. Same effect, but puts the message next to the
     spinner it describes.
  3. Physically unmap/remap `r` while checking. **Rejected** — more moving
     parts, and the buffer-local keymap has to be restored on every exit
     path including errors and UI close.
- **Recommendation:** option 1 or 2. The key must be **inert**, not merely
  silent — the user asked for it to be blocked, so the second press must not
  queue a second check either.
- **Verification:** a behavioural test that presses `r` twice and asserts
  exactly **one** notification and that `check_updates_network()` is not
  re-entered. Must fail before the fix.

#### Resolution

**Option 1** was taken. `check_updates_network()` returns `true` when it
initiated a check and `false` when one was already running; the `r` keymap
notifies only on `true`.

The key is **inert**, not merely silent — the second press neither notifies
nor queues a second check, because the guard short-circuits before any work
is scheduled.

Option 3 was rejected: unmap/remap would need the buffer-local keymap
restored on every exit path, including errors and UI close.

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

**Note on the return contract.** `check_updates_network()` returns `true`
when it started a check, including the degenerate case where there is
nothing to fetch — the spinner was raised and the check completes on the
next tick. It returns `false` only when a check was already running or
there is no plugin list at all.

### N2. **RESOLVED** — `replay_for_buffer()` never replays `BufEnter` for an existing file

- **Severity:** high — a trigger group whose only event is `BufEnter` never
  fires on the `nvim <file>` path, so the plugin silently never loads.
  Found by the user on 2026-11-17 while reviewing the item 0 fix.
- **File:** `lua/resonance/loader/init.lua:298-306` (`replay_for_buffer`)
- **Problem:** the replay picks its events from whether the buffer is a file
  on disk:

  ```lua
  if is_file then
    fire_groups('BufReadPre')
    fire_groups('BufReadPost')
  else
    fire_groups('BufNewFile')
    fire_groups('BufEnter')
  end
  ```

  `BufEnter` is in the `else` branch, so it is replayed **only for a buffer
  that is not a file on disk**. But `BufEnter` fires for *every* buffer —
  Neovim fires it on entering a buffer, whether or not the file exists.

  Verified event order on `nvim <file>`:

  ```text
  EVENTS_ON_OPEN=BufReadPre,BufReadPost,FileType,BufEnter
  ```

  `BufEnter` is in the list, and the replay skips it.
- **Reproduction (verified, headless):** a plugin whose only trigger is
  `event = 'BufEnter'`, registered late (after the events already fired):

  ```text
  REPLAY_FIRED=[BufReadPre,BufReadPost]
  AFTER_REPLAY ran=false      ← the plugin never loaded
  ```

  With `fire_groups('BufEnter')` moved out of the `else`:

  ```text
  REPLAY_FIRED=[BufReadPre,BufReadPost,BufEnter]
  AFTER_REPLAY ran=true       ← the plugin loads
  ```

- **The same flaw silently affects `BufNewFile`.** A plugin whose only
  trigger is `event = 'BufNewFile'` is also never replayed for an existing
  file:

  | Buffer | `BufNewFile`-only trigger | Replayed |
  |---|---|---|
  | existing file (`is_file = true`) | `ran=false` | `BufReadPre,BufReadPost` |
  | new file (`is_file = false`) | `ran=true` | `BufNewFile,BufEnter` |

  `BufNewFile` genuinely only fires for a *new* file, so not replaying it
  for an existing file is arguably correct. `BufEnter` is different — it
  fires for every buffer, so it must always be replayed.
- **Impact on the user's actual config:** **none today.** No plugin in
  `~/.config/nvim/lua/plugins/` uses `BufEnter` as a trigger, and the
  common shape `event = { 'BufReadPost', 'BufNewFile' }` (`ufo`,
  `mini-hipatterns`, `tool`, `treesitter-context`, `ui`) still loads,
  because `BufReadPost` alone satisfies the group. The bug only bites a
  `BufEnter`-only trigger, or a group whose events are all in the `else`
  branch.
- **Fix:** move `fire_groups('BufEnter')` out of the `else` so it runs for
  every buffer:

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

  The `is_file` split should decide between `BufReadPre`/`BufReadPost` and
  `BufNewFile` — the events that genuinely differ — and not decide whether
  `BufEnter` happens at all.
- **Verification:** a behavioural test that registers a `BufEnter`-only
  trigger late, calls `replay_for_buffer()`, and asserts the plugin loaded.
  Must fail before the fix.

---

## Batch 1 — P0 correctness (from `fix.md`)

### 2. **RESOLVED** — `lazy = true` combined with `event` crashes and drops triggers

- **Files:** `lua/resonance/loader/spec.lua`, `lua/resonance/utils.lua`, `lua/resonance/loader/triggers.lua`
- **Status:** open — verified in code.
- **Problem (verified):**
  - `spec.parse_config()` (`spec.lua:38-57`) inserts a **nested table**
    `{ 'User', pattern = 'VeryLazy' }` into `config.event`.
  - `utils.parse_trigger()` (`utils.lua:88`) calls
    `table_concat(ev, ', ')` on that list → **crashes** on the table entry.
  - `triggers.register_event()` (`triggers.lua:53-72`) takes the
    `event_name == 'User'` branch only when `ev[1] == 'User'`. When the
    original event was a native name, `ev[1]` is the native name, so the
    mixed list goes to the `else` branch, which filters
    `type(ev[i]) == 'string'` and **silently drops** the `User` entry.
  - If the original event **was** `{ 'User', pattern = 'Custom' }`,
    `table.insert(event, { 'User', pattern = 'VeryLazy' })` puts a table at
    `ev[2]`, corrupting `opts.pattern` (which is read as `ev[2] or ev.pattern`).
- **Fix:** normalise multi-event / mixed `User` + native event specs across
  the three modules. Represent a `User` event with a dedicated field rather
  than mixing tables into a string list; register each `User` entry
  separately from the native event names.
- **Verification:** behavioural tests (with `test.stub_pack()`) for
  `lazy = true` + string `event`, + array `event`, + `{ 'User', pattern = ... }`.
  Each must prove both the primary event and `VeryLazy` can trigger the load
  without error, and must fail before the fix.

### 3. **RESOLVED** — Specs with neither triggers nor `lazy` are silently never installed

- **Files:** `lua/resonance/loader/spec.lua`, `lua/resonance/loader/init.lua`
- **Status:** DONE. The false positive is fixed and the docs are corrected;
  the details below describe what was found. `triggers.register_all()` registers nothing
  when `event`/`cmd`/`keys`/`ft` are all absent and `lazy` is `nil`, so the
  spec is never installed or loaded.
- **Contradiction to resolve:** the README's `version = 'v1.0.0'` example has
  no trigger and no `lazy` — it documents a spec that does nothing.
- **Fix (pick one, then make the docs match):**
  - (a) default triggerless specs to `lazy = false` (`VimEnter`), or
  - (b) emit `utils.notify(..., WARN)` naming the plugin.
  Option (a) is what a user writing `version = 'v1.0.0'` expects: they want
  the plugin, just pinned.
- **Verification:** behavioural test asserting the chosen behaviour.

### 4. **RESOLVED** — Dependency failure is not propagated when the dependency is in `M.specs`

- **File:** `lua/resonance/loader/init.lua:517-520`
- **Status:** open — verified.
- **Problem:** dependencies registered through `resonance.load()` take the
  `if spec_name and M.specs[spec_name]` branch, which calls
  `fn(nil, visiting_path)` and **discards the return value**. If that
  dependency fails to install, the parent proceeds to install and run
  `setup()` with a broken dependency.
  The inline-dependency branch (the `else`) already handles this correctly
  via `return fail_install(...)`.
- **Fix:** make `load_now()` return a boolean (`true` = success or already
  loaded, `false` = install failure or cycle abort) and abort the parent
  when a dependency returns `false`.
- **Verification:** behavioural test — a dependency whose install fails must
  prevent the parent's `setup()` from running.

### 5. **RESOLVED** — `check_updates_network()` leaks `pending_count` and fetches empty paths

- **Files:** `lua/resonance/ui/actions.lua`, `lua/resonance/ui/init.lua`
- **Status:** open — verified.
- **Problem 1:** `actions.check_updates_network()` clears `st.state.updates = {}`
  but **never resets** `st.state.pending_count`. The spinner renders
  `Updates Available (%d)` from that counter (`render.lua:501`), so repeated
  presses accumulate a bogus number. `ui.open()` does not reset it either.
- **Problem 2:** the fetch loop (`actions.lua:73-80`) iterates
  `1..info.total` without skipping `path == ''`, so a plugin disabled via
  `cond = false` spawns `git fetch` with `{ cwd = '' }`.
- **Fix:** reset `st.state.pending_count = 0` at the start of
  `check_updates_network()` and in `ui.open()`; filter entries with an empty
  or missing path before counting and spawning, and call `finish_check()` if
  no valid paths remain.
- **Verification:** behavioural tests for both.

#### Resolution

- `st.state.pending_count = 0` is reset at the start of
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

### 7. **RESOLVED** — `details_task` survives `:q` / `<C-w>c`; UI state is not cleaned up

- **File:** `lua/resonance/ui/init.lua`
- **Status:** open — verified. `cancel_details_task()` is wired only to the
  `q` / `<Esc>` keymaps (`ui/init.lua:253-255`, `269-271`) and the native
  `on_close`. Closing via `:q` or `<C-w>c` leaves `details_task` running and
  `st.state.buf` non-`nil`, so Pass 2 still calls `pack.get(info=true)` 50 ms
  later and writes into a buffer nobody owns.
- **Fix:** register a `BufWipeout` autocmd (`once = true`,
  `buffer = st.state.buf`) in `ui.open()` that calls `cancel_details_task()`
  and clears `st.state.win` / `st.state.buf`.
- **Verification:** behavioural test — close the UI via `nvim_win_close` /
  `:bwipeout` and assert `details_task` was cancelled.

---

## Batch 2 — Triggers, UX and memory

### 8. **RESOLVED** — Sibling triggers are not cleaned up after a load; `keys`/`cmd` stub edge cases

- **Files:** `lua/resonance/loader/triggers.lua`, `lua/resonance/loader/init.lua`
- **Status:** open — verified.
- **Problem (a):** a plugin with several triggers (`cmd` + `keys` + `event`)
  only tears down the one that fired. The others stay live as stubs. The
  `cmd` path deletes its own command (`triggers.lua:81`) and the `keys` path
  deletes its own keymap (`triggers.lua:128`), but there is no
  **cross-trigger** teardown.
- **Problem (b):** `register_keys()` passes `opts.buffer = true` straight
  into `del_keymap(..., { buf = target_buf })`, where `target_buf` is the
  boolean `true` — the API expects an integer buffer id. `opts.expr` is not
  handled at all. `feedkeys(term_key, 'm', false)` forces remapping on a
  string RHS even when `noremap` was intended.
- **Problem (c):** `register_cmd()` hardcodes
  `{ nargs = '*', bang = true, range = true, complete = 'file' }` regardless
  what the real command expects, so the stub can reject a valid invocation.
- **Fix:** collect per-spec teardown callbacks during `register_all()` and
  invoke them once `load_now()` succeeds; normalise `opts.buffer == true` to
  the current buffer id; respect `opts.remap` (`'mi'` vs `'ni'`) and handle
  `opts.expr`; let a `cmd` spec supply its own `nargs`/`range`/`complete`.
- **Verification:** behavioural tests — after one trigger fires, the sibling
  triggers of the same plugin are gone.

### 9. **RESOLVED** — `branches` / `tags` are fetched for every plugin on UI open

- **Files:** `lua/resonance/ui/init.lua`, `lua/resonance/ui/actions.lua`
- **Status:** open — verified. Pass 2 (`ui/init.lua:184-207`) calls
  `pack.get(nil, { offline = true, info = true })` for **every** installed
  plugin 50 ms after opening — ~420 ms at 49 plugins, ~2.5 s main-thread
  freeze at 300 plugins — even though `branches` and `tags` are only shown
  when a row is expanded with `<CR>`.
- **Fix:** remove the bulk Pass 2 from `ui.open()`. In
  `actions.toggle_details()`, when expanding a row whose `pack_details[name]`
  lacks `branches`/`tags`, query `pack.get({ name }, { offline = true, info = true })`
  for that one plugin and re-render.
- **Note:** this partially reverses an earlier optimisation
  (`5d622af`, which made Pass 2 a cancellable task). The cancellability
  work is still worth keeping for the per-plugin query.
- **Verification:** behavioural test — opening the UI must not request
  `info = true` for all plugins; expanding one row must fetch only that one.

### 11. **RESOLVED** — Contradictory allocations in `ui/render.lua`; duplicate renders in `ui.open()`

- **Files:** `lua/resonance/ui/render.lua`, `lua/resonance/ui/init.lua`
- **Status:** open — verified.
- **Problem (a):** `nl()` (`render.lua:91-95`) does `line_parts = {}` on every
  line, allocating a fresh table per rendered line, while
  `reset_render_state()` (`render.lua:106`) calls `table_clear(line_parts)`
  on the module-level table. The two are inconsistent — the clear is
  pointless because the table was replaced.
- **Problem (b):** `reset_render_state()` (`render.lua:108-109`) allocates
  fresh `st.state.line_to_name = {}` and `st.state.name_to_line = {}` every
  render instead of clearing the existing ones.
- **Problem (c):** `ui.open()` renders three times: a synchronous
  `render_mod.render()` (`ui/init.lua:218`), a `chunk()`-scheduled
  `schedule_render()` (`ui/init.lua:174`), and a trailing
  `schedule_render()` (`ui/init.lua:292`).
- **Fix:** `table_clear(line_parts)` in `nl()`; `table_clear` the two
  `st.state` maps in `reset_render_state()`; drop the duplicate trailing
  `schedule_render()` in `ui.open()`.
- **Verification:** no behavioural test needed — this is a pure allocation
  change. Benchmark UI open time to confirm no regression.

### 12. **RESOLVED** — Long-session memory retention

- **Files:** `lua/resonance/loader/init.lua`, `lua/resonance/ui/actions.lua`, `lua/resonance/ui/init.lua`, `lua/resonance/ui/render.lua`
- **Status:** open — verified, all four sub-items are missing.
- **Problem:** four independent leaks:
  1. `fired_events[buf]` / `fired_groups[buf]` are never pruned when a
     buffer is wiped — no `BufWipeout` autocmd exists in the loader.
  2. `config.setup` / `config.config` are never cleared after a successful
     load, so user closures stay reachable for the session.
  3. `actions.uninstall_plugin()` does **not** prune `pack_details[name]`,
     `urls[name]`, `commits[name]`, `updates[name]`, `expanded[name]`, or
     `scanner.load_times[name]`.
  4. `render.lua`'s module-level `lines` / `hls` are cleared on the next
     render but never on UI close, so the last render's data is retained
     while the UI is closed.
- **Fix:** as listed per sub-item.
- **Verification:** behavioural test — after `BufWipeout`, the loader's
  fired-state tables no longer contain the buffer id.

---

## Batch 3 — Architecture, build state and docs

### 10. **RESOLVED** — Startup `check_and_build` spawns an unbounded `git rev-parse` per plugin

- **Files:** `lua/resonance/loader/build.lua`, `lua/resonance/ui/state.lua`
- **Status:** open — verified. `build.check_and_build()` (`build.lua:93-99`)
  runs `async.run` → `git rev-parse HEAD` for **every** plugin with a build
  hook at startup, with no concurrency bound. The `build_semaphore(2)` only
  guards the actual build, not the hash check.
- **Secondary problem:** `run_build()` calls `mark_build_success()` as soon
  as `build_task(dir)` returns, even if the Lua `build` function spawned
  async work — the hash is marked built before the build finished.
- **Fix:** gate the hash check behind a bounded semaphore, or read
  `.git/HEAD` / `packed-refs` directly via `vim.uv` (the same helper
  `ui/state.lua:get_local_hash` already uses) so **zero** subprocesses are
  spawned at startup. Support a completion callback for async Lua `build`
  hooks.
- **Verification:** behavioural test — `check_and_build` on N plugins must
  not spawn N concurrent `git` processes.

### 13. **RESOLVED** — `.resonance_built` pollutes the plugin repo; `_plugin_dir_cache` never invalidates

- **Files:** `lua/resonance/loader/build.lua`, `lua/resonance/loader/init.lua`
- **Status:** open — verified. `build.lua` writes `.resonance_built` into the
  plugin's own directory (`build.lua:31`, `48`, `91`), dirtying its git
  working tree. `loader/init.lua:129` caches `_plugin_dir_cache` and only
  clears it in `M._reset()` (`loader/init.lua:343`) — never on `PackChanged`
  or after a fresh install, so `get_plugin_dir()` can return `nil` for a
  plugin installed during the session.
- **Fix:** store build markers under
  `vim.fn.stdpath('state') .. '/resonance/builds/' .. name`; clear
  `_plugin_dir_cache` on `PackChanged` (install / delete) and after
  `pack_install()`.
- **Verification:** behavioural test — a marker written for plugin `foo`
  must not appear inside `foo`'s directory.

### 14. **RESOLVED** — `scanner` ↔ `loader` circular dependency; user specs are mutated

- **Files:** `lua/resonance/scanner.lua`, `lua/resonance/utils.lua`, `lua/resonance/loader/init.lua`, `lua/resonance/loader/spec.lua`, `lua/resonance/ui/render.lua`
- **Status:** DONE — `registry.lua` added, the cycle is broken, the loader's
  autocmds are deferred, and the user's specs are no longer mutated.
  Six behavioural tests in `test/behavior_arch_spec.lua`.
- **Problem (a):** `scanner.lua:101` and `scanner.lua:120` do
  `require('resonance.loader')`, while `loader/init.lua` requires the
  scanner. Opening the read-only UI panel therefore drags in the whole
  control plane, including the `PackChanged` build autocmd.
- **Problem (b):** require-time side effects: `setup_event_tracker()` runs at
  `loader/init.lua:235` and `build.setup_packchanged_autocmd()` at
  `loader/init.lua:324` — both when the module is **required**, not when it
  is used.
- **Problem (c):** caller-owned tables are mutated: `spec.parse_config()`
  rewrites `config` in place (`spec.lua:18-27`), and `load_now()` writes
  `config._replay_done = true` (`loader/init.lua:600`) back into the user's
  spec. `loader/dag.lua:176,198` then reads that field back out of the
  user-owned table.
  - **Correction (2026-11-17):** `config._force_load` is **not** set anywhere
    in the current source — `rg '_force_load' lua/` returns nothing. That
    claim was carried forward from `fix-notes.md` without re-checking. The
    only user-table mutation left is `config._replay_done`.
- **Fix:** extract a pure-data `lua/resonance/registry.lua` holding `specs`,
  `plugin_triggers`, `disabled_plugins`, `load_times`; move the
  `setup_event_tracker()` / `setup_packchanged_autocmd()` calls into
  `resonance.setup()` or the first `load()`; stop mutating caller tables.
- **Risk:** the largest blast radius in this list. The trigger-group naming
  and the replay both depend on the loader's internals. Do this **after**
  Batch 1 and 2, with the suite green as the guard.

**What was actually done:**

- **(a)** `lua/resonance/registry.lua` is new: pure data, no require-time
  side effects, no dependency on either the loader or the scanner. It
  holds `specs`, `plugin_triggers`, `disabled_plugins`, `spec_urls`,
  `load_times` and the plugin-directory cache. The loader and the scanner
  both require it, so the cycle is gone. The scanner's plugin-directory
  lookup moved there too, because a plugin disabled by a false `cond` is
  in the registry but not in `vim.pack`.
- **(b)** The loader's autocmds — two `PackChanged` handlers and the five
  event-tracker autocmds — are no longer installed when the module is
  required. They are installed by `loader.setup()`, which `resonance.setup()`
  calls, and by the first `load()` as a backstop.
  - The event tracker has to be in place before the first read event
    fires, or the events that already fired are not recorded and the
    replay fires them a second time. That is why `resonance.setup()`
    installs it rather than leaving it to the first `load()`.
- **(c)** `spec.parse_config()` now works on a copy, so the caller's table
  is untouched. The nested `keys` list is copied as well: the shorthand
  entries were rewritten in place.
- The panel no longer loads the loader. `ui/init.lua` reads the disabled
  plugins from the registry; `ui/state.lua`'s `refresh_dag_data()` still
  requires the loader, but it is only called when the user toggles the
  DAG view, which genuinely needs the control plane.
- The DAG output is byte-identical before and after the change
  (18 nodes, 18 edges against the user's own config).
- The `config._replay_done` write was already safe: it writes to the
  loader's retained copy, not the user's table.

### 15. **RESOLVED** — `M.stats()` freezes forever; `M._reset()` does not exist

- **File:** `lua/resonance/init.lua`
- **Status:** DONE — `8ead18f`. `M.stats()` now latches only `startuptime`
  and reads `count` / `loaded` / `times` live from `scanner.get_info()`.
  `M._reset()` clears the latched end time and the cached loader module.
  Four behavioural tests in `test/behavior_stats_spec.lua`.
- **Fix:** freeze only `startuptime` (`_end_time`) at `UIEnter`/`VimEnter` or
  the first `stats()` call; read `count`, `loaded` and `times` live from
  `scanner.get_info()`. Implement `M._reset()` clearing `M._cached_stats`,
  `M._end_time`, and `loader_mod`.
- **Verification:** behavioural test — `stats().loaded` must reflect a
  plugin loaded after the first `stats()` call.

### 16. **RESOLVED** — `test/build_spec.lua` false positive; documentation drift

- **Files:** `test/build_spec.lua`, `doc/resonance.txt`, `README.md`, `AGENTS.md`
- **Status:** DONE — `f5be742`. The false positive is fixed and the docs are
  corrected; the details below describe what was found.
- **Problem (a) — false positive:** `test/build_spec.lua:28-42`
  (`check_and_build: skips when hash matches`) asserts `built == false`
  **immediately**, with no `vim.wait()`. The async `git rev-parse` has not
  run yet, so the test passes whether or not the hash check works. It needs
  a real temp git repo and a `vim.wait()`.
- **Problem (b) — `doc/resonance.txt` drift** (all verified):
  - `doc/resonance.txt:108` — "The `resonance.setup()` function accepts a
    list of plugin specifications." **False.** `setup(opts)` only merges UI
    config (`init.lua:69-74`); plugin specs go to `resonance.load()`.
    The Quick Start at `doc/resonance.txt:68-100` passes a plugin list to
    `setup()` — that entire example is wrong.
  - `doc/resonance.txt:273` — `resonance.open_ui([ui_config])`. **False.**
    `M.open_ui()` takes no arguments (`init.lua:162-164`).
  - `doc/resonance.txt:168` — "Cannot combine with explicit
    event/cmd/keys/ft" for `lazy = true`. **False.** `spec.lua:44-48` adds
    `VeryLazy` as an *additional* trigger; `README.md:181` documents it
    correctly as a fallback. Direct contradiction between the two files.
  - `doc/resonance.txt` Section 7 lists `ResonanceLoad` / `ResonanceUpdate` /
    `ForceLoad<Name>` events — verified **not to exist** in the source.
- **Problem (c) — `README.md`:** the `version = 'v1.0.0'` example has no
  trigger and no `lazy`, so it documents a no-op spec (see item 3). The
  bootstrap section should also distinguish `vim.pack.add` from
  `resonance.load`.
- **Problem (d) — `AGENTS.md`:** Section 7 still contains unrelated
  `Jisho.org` / kana copy-paste; Section 3 claims `p.active` is used for
  loaded detection (the code checks the runtimepath instead); Section 4 mixes
  plugin-only and full-Neovim startup numbers.
- **Fix:** as listed per sub-item. Keep the docs truthful — the AGENTS.md
  guardrail says not to trust stale claims over actual code, and these are
  exactly such claims.

**What was actually done:**

- **(a)** The test now uses a real git repository whose commit the marker
  holds, and waits for the build to have had its chance to run. Reverting
  the hash check in *both* `check_and_build()` and `run_build()` makes it
  fail; reverting only one does not, because the other covers it.
- **(b)** Corrected: the Quick Start, the "multiple plugins" example, and
  the configuration intro now use `load()` for specs and `setup()` for the
  UI options; `open_ui()` takes no argument; `lazy = true` is documented
  as an extra trigger; the events section lists only `User VeryLazy`.
  Added the missing `stats()` entry and the UI options table.
- **Tags.** Seven section tags used the wrong closing character
  (`*resonance-ui>`, `*resonance-events|`, …), so `:helptags` silently
  dropped them — 15 tags were generated where 22 were expected. The field
  names `|event|`, `|cmd|`, `|ft|`, `|keys|`, `|cond|`, `|lazy|` were also
  rendered as links to nonexistent tags. All fixed; every `|tag|` in the
  file now resolves.
- **(c)** The bootstrap now distinguishes `vim.pack.add()` (installs
  Resonance itself) from `resonance.load()` (every other plugin); the
  version-pinning example says it loads eagerly on VimEnter.
- **(d)** The AGENTS.md in the repo has already been rewritten since this
  item was written — it has no `Jisho` section and no `p.active` claim.
  The one stale line was the build-marker location, which item 13 had
  already changed; it now names `stdpath('state') .. '/resonance/builds/'`.

---

## Batch 4 — Newly verified (2026-11-18)

Every item below was checked against the **installed copy**, not inferred from
reading the source. Each one names the command output that proves it.

### 17. **RESOLVED** — **`register_keys` deletes the plugin's real mapping when the shorthand has no `rhs`** — HIGH

- **File:** `lua/resonance/loader/triggers.lua`
- **Problem:** `keys = { '<leader>Tg' }` — the shorthand with no `rhs` — means "the
  plugin defines this mapping itself". When the plugin loads, its `setup()` creates
  the real mapping, and the teardown that follows deletes it:

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

#### Resolution

The teardown compares the installed mapping's callback against the stub's. The delete
only happens while the stub is still installed, so a mapping the plugin took over is
left alone. The comparison is on the callback rather than the lhs, because the
keymap API reports an lhs in its own notation (`<C-x>` comes back as `<C-X>`).

Three buffer-handling defects surfaced while fixing this:

- `opts.buffer = false` means the mapping is **global**, but the old `is_buffer`
  check treated any non-nil buffer option as buffer-local. The lookup asked for the
  keymap of a buffer that does not exist.
- `opts.buf = 0` means the current buffer when the mapping is **set**, but the
  teardown deleted from whatever was current **later**. The buffer is now resolved
  to an id at registration time.
- The double `set_keymap` is gone: the stub removes itself on the way in, so the
  teardown finds no stub and does nothing.

**Tests** (`test/behavior_triggers_spec.lua`, `test/triggers_spec.lua`) — seven new
cases covering the sibling-trigger path, the key-fired path, the unchanged normal
case, `buffer = false`, `buf = 0`, and both feed modes.

**Mutation-verified:**

| Mutation | Test that fails |
|---|---|
| the conditional delete removed | both `a key shorthand without an rhs` tests |
| `feed_mode` reverted to the inverted form | `a string rhs is fed without remapping by default` |
| `buf = 0` not resolved, `is_buffer` reverted | the `buffer=false` and `buf=0` tests |

### 18. **RESOLVED** — **`register_cmd` raises `E1208` when the command takes no arguments** — MEDIUM

- **File:** `lua/resonance/loader/triggers.lua`
- **Problem:** the command defaults are `{ nargs = '*', bang = true, range = true,
  complete = 'file' }`. A spec with `cmd = { name = 'X', opts = { nargs = 0 } }` merges
  to `nargs = 0` with `complete = 'file'` still set, and Neovim rejects that.
- **Verified:** `load ok: false` — `triggers.lua:118: 'complete' used without 'nargs'`.
- **Fix:** drop `complete` when `nargs` is `0` (or `'0'`), unless the user set it
  explicitly.

#### Resolution

The default `complete = 'file'` is dropped when `nargs` is `0` and the user did not
ask for a completion. A completion the user set explicitly is left alone.

The error was worse than a missing command: it escaped `resonance.load()` and
aborted the whole call, so the spec's **other** triggers were never registered
either. A spec with a bad command and an event trigger ended up with neither.

**Tests** (`test/behavior_triggers_spec.lua`) — three new cases: the command is
registered with `nargs = '0'`, the other triggers survive, and the registered
command actually loads the plugin.

**Mutation-verified:** removing the guard fails all three tests.

**Note:** the `Execution failed: Command not found` notice a stub produces when the
plugin does not define its own command is pre-existing behavior — checked against
the code before the change.

### 19. **RESOLVED** — **`force_load_fns` keeps the user's `setup` closure alive for the whole session** — MEDIUM

- **File:** `lua/resonance/loader/init.lua`
- **Problem:** `retained_spec()` drops `setup` from the registry copy, so the registry
  does not hold it. But `force_load_fns[name] = load_now` stores the `load_now`
  closure, whose upvalue is `config` — and `config.setup` is the user's closure. It
  is never released.
- **Verified:** holding the setup closure weakly and clearing `force_load_fns` releases
  it immediately (`after clearing force_load_fns, closure alive: false`). With
  `force_load_fns` intact the closure is still alive after the load.
- **Fix:** clear `config.setup` / `config.config` (and the per-plugin `setup` /
  `config`) once the members have loaded and `member_state.loaded = true`.

#### Resolution

The setup closures are released once the members have loaded, right after the setup
call. Both shapes are covered: `config.setup` at the top level of the spec, and
`setup` inside a member of the `plugin` list.

The release happens **after** the setup has run, so the setup still runs exactly
once. Verified against the code before the change: a two-member spec still runs
both setups, in order, and a second spec for an already-loaded plugin still does
not re-run its setup.

**Tests** (`test/behavior_arch_spec.lua`) — three new cases: `config.setup` is
released, the `plugin` list shape is released, and the setup still runs exactly
once.

**Mutation-verified:** removing the release fails both release tests.

### 20. **RESOLVED** — **`test/behavior_ui_spec.lua` asserts `#name_to_line == 0`, which is always true** — LOW

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

#### Resolution

A `map_count` helper was added to `test/helpers.lua`: it walks the table instead of
using the length operator, so it counts the entries whatever the keys are.

The test now asserts on both maps with it, and the "the UI rendered no rows" guard
covers `name_to_line` too — before, that map was never checked for being populated,
so the test would have passed against a UI that rendered no names at all.

**Verified against the old assertion:** with 49 entries in `name_to_line`,
`count(st.name_to_line) == 0` was still **true** — the assertion could never fail.

**Mutation-verified:** removing the close-time cleanup in `render.clear()` now fails
the test (`Expected: 0, Actual: 49`). It passed before the fix.

### 21. **RESOLVED** — **`utils.normalize_events()` drops a table `pattern`** — LOW

- **File:** `lua/resonance/utils.lua`
- **Problem:** only `type(event.pattern) == 'string'` is kept. Neovim accepts a list of
  patterns, so `event = { 'BufReadPost', pattern = { '*.lua', '*.vim' } }` loses its
  patterns.
- **Verified:** `event[1] event=BufReadPost pattern=nil`.
- **Fix:** accept a table as well as a string.

#### Resolution

`normalize_events()` now keeps a table pattern, for both a native event list and a
`User` event. The pattern reaches `nvim_create_autocmd`, which creates one autocmd
per pattern.

**Tests** (`test/spec_spec.lua`, `test/behavior_triggers_spec.lua`) — three new
cases: the list survives the normalization for a native event, for a `User` event,
and it reaches the registered autocmds.

**Mutation-verified:** dropping the table again fails all three tests.

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

## Stale entries in `note/knowledge/fix-notes.md`

These rows are **no longer accurate** and should be corrected when
`fix-notes.md` is next touched. They are not work items.

| Row in `fix-notes.md` | Actual status |
|---|---|
| P1 "触发器不回收" — only the fired trigger is deleted | **Fixed** (item 8, commits `3275053` / `23d4071`). All sibling stubs are torn down after a load. |
| P1 "UI 状态陈旧" — `check_updates_network` does not clear `updates` | **Fixed.** `updates = {}` is cleared (`actions.lua:64`), and `pending_count` is now reset too (item 5). |
| P1 "UI 状态陈旧" — `pack_details` / `expanded` not reset in `open()` | **Still true.** `ui.open()` resets `updates` and `commits` (`ui/init.lua:135`) but not `pack_details` or `expanded`. |
| P1 "`_plugin_dir_cache` 永不失效" | **Fixed** (item 13, commit `24160c7`) — the cache moved to `registry.plugin_dirs` and is invalidated on `PackChanged`. |
| P2 "零测试、零 CI、无格式化/静态检查配置" | **Partly stale.** There are now 13 test files and 201 passing tests. Still no CI, no `stylua`/`luacheck` config, and no `:checkhealth`. |
| P1 "无 trigger 的 spec 永远不加载也不安装" | **Fixed** (item 3, commit `be50123`) — triggerless specs load eagerly on `VimEnter`. |
| P1 "`BufEnter` 对已存在的文件从不被重放" | **Fixed** (commit `be80437`). |
| P2 "文档漂移" — README uses `Vim.fn` / `Vim.uv` / `Vim.notify` / `Vim.system` | **Stale.** Verified: zero matches in the current README. |
| P2 "文档漂移" — doc says the DAG key is `g`, code uses `A` | **Stale.** `doc/resonance.txt:224` already says `A`. |
| P3 "`r` 键阻塞主线程" | **Stale.** `check_updates_network()` uses `vim.async` + a semaphore; the git fetches are non-blocking. The *notification* spam is a separate, new issue — N1. |
| P3 "spinner 每 100ms 触发一次全量重绘" | **Stale.** `update_spinner()` (`render.lua:494-522`) rewrites a single line and two extmarks. |
| P0 "`vim.async` 硬依赖，require 期无守卫" | **Intentionally not fixed** — the project targets Neovim 0.13+. The note already says so. |
| P3 "首次触发可能现场 clone" | **Still true, and now deliberate.** `plan-2026-11-17.md` item 4 explains why the install stays blocking: the plugin must be on disk before `setup()` runs. |

### New entries to add to `fix-notes.md`

| Issue | Where |
|---|---|
| `r` key notification spam (N1) | P1, new row — **added** |
| Triggerless specs never install (item 3) | already present as the first P1 row — **now fixed** |
| `stats()` freezes forever / no `M._reset()` (item 15) | P2, new row — **added** |
| `build_spec.lua` false positive (item 16a) | P2, new row — **added** |
| Batch 4 items 17–23 | P1, new table — **added 2026-11-18** |

---

## Sequencing

```text
0. N1  r-key notification spam        ← DONE (with item 5)
1. N2  BufEnter never replayed        ← DONE
2. Batch 1  items 2, 3, 4, 7           ← DONE
3. Batch 2  items 8, 9, 11, 12         ← DONE
4. Batch 3  items 10, 13, 14, 15, 16   ← DONE
5. Batch 4  items 17-21                 ← DONE; shortcut, crash, leak, vacuous assertion, lost pattern
6.          items 22, 23               ← OPEN; small losses
```

Rationale for the order:

- **N1 first.** The user reported it, it is one file, and it touches the
  same `actions.check_updates_network()` that item 5 also modifies. Land
  them together so the guard and the counter reset are consistent. **Done.**
- **N2 second.** Also user-reported, and it is a one-line change with a
  one-test guard. It belongs to the same failure class as item 0 — a
  plugin that silently never loads — so it should not sit behind a
  multi-file refactor.
- **Batch 1 before Batch 2.** Items 2, 3 and 4 are correctness bugs that
  can silently produce a plugin that never loads — the same failure class
  the previous session just fixed. They also define the trigger semantics
  that item 8 refines.
- **Item 9 before item 10.** Both are performance, but item 9 removes work
  outright while item 10 only bounds it.
- **Item 14 last.** It restructures the loader, the scanner and the registry
  together. Every other item touches code it will move. Doing it last means
  the diffs stay reviewable.
- **Item 16 last.** The docs must describe the code as it ends up, not as
  it is partway through.

---

## Definition of done

- Full suite green.
- Every behavioural change has a regression test that **fails against the
  pre-change code** — verified by mutation, not by inspection.
- LSP diagnostics clean across all source files.
- Installed copy (`~/.local/share/nvim/site/pack/core/opt/resonance.nvim`)
  byte-identical to the repo.
- `fix.md` and `note/knowledge/fix-notes.md` updated: resolved items removed
  or marked, stale rows corrected.
- Benchmark for any performance item (UI open time, startup time) — no
  regression.
- Commit per batch, so the history stays bisectable.

---

*Every issue in this file was verified by reading the current source on
2026-11-17, and Batch 4 was verified by running it against the installed
copy on 2026-11-18. Nothing here is copied forward from the notes without
re-checking it against the code.*
