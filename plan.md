# resonance.nvim — Open Issues Plan

> **Branch:** `fix`
> **Baseline:** `38375de` (197 tests passing, 0 failed)
> **Compiled:** 2026-11-17 by cross-checking `fix.md`, `note/knowledge/fix-notes.md`,
> and the actual Lua source. Every item below was **verified against the code**,
> not copied from the notes.

---

## How this list was built

Three sources were merged and each claim was re-checked against the current
source:

| Source | Items | Result |
|---|---|---|
| `fix.md` | 0–16 | 0, 1, 6 **done**; the rest **open** |
| `note/knowledge/fix-notes.md` | P1/P2/P3 lists | mostly **still open**; a few now **stale** |
| `note/knowledge/plan-2026-11-17.md` | items 0–4 | **done** (previous session) |
| User report (this session) | `r` key notification spam | **confirmed by reproduction** |

Items already resolved are listed in [Already resolved](#already-resolved) and
are **not** repeated in the work batches.

---

## New issues reported by the user

### N1. The `r` key spams "Resonating in background..." notifications

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

  ```
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

---

## Batch 1 — P0 correctness (from `fix.md`)

### 2. `lazy = true` combined with `event` crashes and drops triggers

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

### 3. Specs with neither triggers nor `lazy` are silently never installed

- **Files:** `lua/resonance/loader/spec.lua`, `lua/resonance/loader/init.lua`
- **Status:** open — verified. `triggers.register_all()` registers nothing
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

### 4. Dependency failure is not propagated when the dependency is in `M.specs`

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

### 5. `check_updates_network()` leaks `pending_count` and fetches empty paths

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

### 7. `details_task` survives `:q` / `<C-w>c`; UI state is not cleaned up

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

### 8. Sibling triggers are not cleaned up after a load; `keys`/`cmd` stub edge cases

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

### 9. `branches` / `tags` are fetched for every plugin on UI open

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

### 11. Contradictory allocations in `ui/render.lua`; duplicate renders in `ui.open()`

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

### 12. Long-session memory retention

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

### 10. Startup `check_and_build` spawns an unbounded `git rev-parse` per plugin

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

### 13. `.resonance_built` pollutes the plugin repo; `_plugin_dir_cache` never invalidates

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

### 14. `scanner` ↔ `loader` circular dependency; user specs are mutated

- **Files:** `lua/resonance/scanner.lua`, `lua/resonance/utils.lua`, `lua/resonance/loader/init.lua`, `lua/resonance/loader/spec.lua`, `lua/resonance/ui/render.lua`
- **Status:** open — verified.
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
  spec. `config._force_load` is set the same way.
- **Fix:** extract a pure-data `lua/resonance/registry.lua` holding `specs`,
  `plugin_triggers`, `disabled_plugins`, `load_times`; move the
  `setup_event_tracker()` / `setup_packchanged_autocmd()` calls into
  `resonance.setup()` or the first `load()`; stop mutating caller tables.
- **Risk:** the largest blast radius in this list. The trigger-group naming
  and the replay both depend on the loader's internals. Do this **after**
  Batch 1 and 2, with the suite green as the guard.

### 15. `M.stats()` freezes forever; `M._reset()` does not exist

- **File:** `lua/resonance/init.lua`
- **Status:** open — verified. `M.stats()` (`init.lua:116-133`) caches the
  whole result table on first call, so `count` and `loaded` are frozen for
  the session. `test/runner.lua` calls `resonance._reset()`, but
  `resonance/init.lua` has no `_reset` — only `loader/init.lua` and
  `ui/state.lua` do.
- **Fix:** freeze only `startuptime` (`_end_time`) at `UIEnter`/`VimEnter` or
  the first `stats()` call; read `count`, `loaded` and `times` live from
  `scanner.get_info()`. Implement `M._reset()` clearing `M._cached_stats`,
  `M._end_time`, and `loader_mod`.
- **Verification:** behavioural test — `stats().loaded` must reflect a
  plugin loaded after the first `stats()` call.

### 16. `test/build_spec.lua` false positive; documentation drift

- **Files:** `test/build_spec.lua`, `doc/resonance.txt`, `README.md`, `AGENTS.md`
- **Status:** open — verified.
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

---

## Stale entries in `note/knowledge/fix-notes.md`

These rows are **no longer accurate** and should be corrected when
`fix-notes.md` is next touched. They are not work items.

| Row in `fix-notes.md` | Actual status |
|---|---|
| P1 "触发器不回收" — only the fired trigger is deleted | **Still true**, now item 8. The `cmd` path deletes its command and the `keys` path deletes its keymap, but siblings survive. |
| P1 "UI 状态陈旧" — `check_updates_network` does not clear `updates` | **Partly fixed.** `updates = {}` is now cleared (`actions.lua:57`), but `pending_count` is not — item 5. |
| P1 "UI 状态陈旧" — `pack_details` / `expanded` not reset in `open()` | **Still true.** `ui.open()` resets `updates` and `commits` (`ui/init.lua:132`) but not `pack_details` or `expanded`. |
| P1 "`_plugin_dir_cache` 永不失效" | **Still true** — item 13. |
| P2 "零测试、零 CI、无格式化/静态检查配置" | **Partly stale.** There are now 13 test files and 197 passing tests. Still no CI, no `stylua`/`luacheck` config, and no `:checkhealth`. |
| P2 "文档漂移" — README uses `Vim.fn` / `Vim.uv` / `Vim.notify` / `Vim.system` | **Stale.** Verified: zero matches in the current README. |
| P2 "文档漂移" — doc says the DAG key is `g`, code uses `A` | **Stale.** `doc/resonance.txt:224` already says `A`. |
| P3 "`r` 键阻塞主线程" | **Stale.** `check_updates_network()` uses `vim.async` + a semaphore; the git fetches are non-blocking. The *notification* spam is a separate, new issue — N1. |
| P3 "spinner 每 100ms 触发一次全量重绘" | **Stale.** `update_spinner()` (`render.lua:494-522`) rewrites a single line and two extmarks. |
| P0 "`vim.async` 硬依赖，require 期无守卫" | **Intentionally not fixed** — the project targets Neovim 0.13+. The note already says so. |
| P3 "首次触发可能现场 clone" | **Still true, and now deliberate.** `plan-2026-11-17.md` item 4 explains why the install stays blocking: the plugin must be on disk before `setup()` runs. |

### New entries to add to `fix-notes.md`

| Issue | Where |
|---|---|
| `r` key notification spam (N1) | P1, new row |
| Triggerless specs never install (item 3) | already present as the first P1 row |
| `stats()` freezes forever / no `M._reset()` (item 15) | P2, new row |
| `build_spec.lua` false positive (item 16a) | P2, new row |

---

## Sequencing

```text
0. N1  r-key notification spam        ← user-reported, smallest, highest visibility
1. Batch 1  items 2, 3, 4, 5, 7        ← P0 correctness
2. Batch 2  items 8, 9, 11, 12         ← triggers, UX, memory
3. Batch 3  items 10, 13, 15, 16       ← build state, stats, docs
4.          item 14                    ← architecture; largest blast radius, last
```

Rationale for the order:

- **N1 first.** The user reported it, it is one file, and it touches the
  same `actions.check_updates_network()` that item 5 also modifies. Land
  them together so the guard and the counter reset are consistent.
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

- Full suite green (baseline: **197 passing, 0 failed**).
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
2026-11-17. The `r`-key spam was additionally reproduced in a headless
Neovim. Nothing here is copied forward from the notes without re-checking
it against the code.*
