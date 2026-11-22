# Code Tour

A guided walk through resonance.nvim for a person reading the code for the
first time (or coming back after a break).

- `README.md` and `doc/resonance.txt` explain how to **use** the plugin.
- `AGENTS.md` lists the **rules** for editing it.
- `ARCHITECTURE.md` is the short reference of the layers and flows.
- This file is the **story**: what happens, in what order, and in which file.

Everything here was checked against the source on 2026-11-20. If this file
and the source disagree, the source is right.

---

## 1. The idea in one minute

Neovim 0.13 has a built-in plugin manager, `vim.pack`. It can install,
update and delete plugins, but it loads everything at startup.

Resonance adds three things on top of it:

1. **Lazy loading.** A plugin is installed and loaded only when its
   *trigger* happens: an event, a command, a key, or a filetype.
2. **Build hooks.** After a plugin is installed or updated, run `make`
   (or any command, or a Lua function) once per commit.
3. **A panel** (`:Resonance`) that lists plugins, checks for updates, and
   shows the dependency graph.

The core trick of lazy loading is the **stub**. For every trigger,
Resonance registers a small placeholder: an autocmd, a fake user command,
or a fake keymap. When the placeholder fires, it loads the real plugin,
removes itself, and then repeats what the user did (runs the command,
presses the key again).

---

## 2. Words you will meet

| Word | Meaning |
|---|---|
| **spec** | The table the user writes: `{ 'https://…/plugin', event = 'InsertEnter', config = fn }` |
| **member** | One plugin inside a spec. Most specs have one member; `plugin = { a, b }` has two. |
| **trigger** | What makes a spec load: `event`, `cmd`, `keys`, `ft`. |
| **stub** | The placeholder autocmd / command / keymap that waits for the trigger. |
| **`load_now`** | The function that really loads a spec. One per spec, created in `loader/init.lua`. |
| **trigger group** | The augroup `Resonance_<first member name>` that holds a spec's autocmd stubs. |
| **replay** | Firing an event again, only for the handlers that missed it. |
| **VeryLazy** | A `User` event Resonance fires once, right after the UI is up. |
| **marker** | A small file holding the commit a plugin was last built at. |
| **registry** | `registry.lua`: plain shared tables (specs, triggers, load times…). |
| **SoA** | "Struct of arrays": the scanner returns `plugins.name[i]`, `plugins.path[i]`, … instead of a list of tables. |
| **Resonate** | The `r` key in the panel: check every plugin for updates. |

---

## 3. Map of the files

```text
lua/resonance/
  init.lua          public API: setup, load, import, stats, open_ui, …
  registry.lua      shared data only, no logic
  utils.lua         get_pack(), notify(), event normalization, git hash, sort
  builds.lua        build STATE: pending/running/ok/failed, waiters, locks, timeout
  scanner.lua       read-only list of installed plugins (for the panel and stats)
  scandir.lua       import(): read a folder of spec files
  loader/
    init.lua        load(spec), load_now, install, dependencies, setup order
    spec.lua        turn the user's spec into one normal shape
    triggers.lua    create the stubs (event / cmd / keys / ft)
    replay.lua      event tracker + the two replays
    build.lua       build ACTIONS: run the command, marker file, PackChanged
    dag.lua         data for the panel's dependency view
  ui/
    init.lua        open the window, bind the keys
    state.lua       the one state table of the panel
    render.lua      draw the buffer
    actions.lua     fetch, update, checkout, uninstall
```

Who may require whom (the important part):

```text
           init.lua
          /        \
     loader/        ui/ ──► scanner.lua
        │  \         │           │
        │   ▼        ▼           ▼
        │  builds.lua      registry.lua   ◄── loader/ also writes here
        ▼
     utils.lua  (everyone uses it)
```

- `registry.lua` requires nothing. It exists so that the scanner can read
  the loader's data **without requiring the loader**.
- `builds.lua` only keeps state. `loader/build.lua` does the work and
  reports into it.
- Requiring a module never installs autocmds. They are installed on first
  use (`loader.setup()` or `loader.load()`).

---

## 4. Story 1: Neovim starts

The user's `init.lua` calls `require('resonance').setup(opts)`
(`init.lua:214`). It does five small things:

1. Merges `opts` into `M.config`.
2. **Arms VeryLazy** (`arm_verylazy`, `init.lua:174`): one autocmd on
   `UIEnter`, one on `VimEnter` (for headless runs with no UI).
3. Creates the `:Resonance` command.
4. Calls `loader.setup()`, which installs:
   - `PackChanged` handlers (run builds; drop the plugin-directory cache),
   - the **event tracker** (see Story 4). It must exist before the first
     file is read, which is why `setup()` should come early.
5. Passes `opts.build` to `loader/build.lua` (`configure`).

Then the user calls `load({...})` with their specs (Story 2).

Later, when the UI appears, `fire_verylazy()` runs (`init.lua:132`):

1. Latches the startup time for `stats()`.
2. Fires `User VeryLazy` **synchronously**. Every `VeryLazy` spec loads now.
3. Calls `replay_for_buffer()` for every loaded, named buffer (unless
   `setup({ replay = false })`). This is the fix for `nvim file.lua`: the
   file was read *before* VeryLazy, so plugins loaded at VeryLazy would
   never see its `BufReadPost`.

It fires only once, even if both autocmds reach it.

It never fires in the middle of an install. vim.pack runs the event loop
while it clones, so on a first start the scheduled fire came during the
`lazy = false` installs: VeryLazy plugins were set up before the
colorscheme, and a file opened meanwhile lost its read events (the install
runs inside a `VimEnter` handler, and autocommands do not nest). If
`loader.installing()` is true, `fire_verylazy()` hands itself to
`loader.after_installs()`, which runs it once the last install is over.

> **Startup time note.** `stats().startuptime` is counted from
> `_G.start_time` if the user set it at the top of `init.lua`. Otherwise
> it is counted from the first `require('resonance')`, not from the real
> start of Neovim (`init.lua:17`).

---

## 5. Story 2: `load(spec)` — registering, not loading

`loader/init.lua:501`. Nothing is installed here. The spec is only
**registered**.

1. **List or single?** `spec.is_plugin_list`: a table whose `[1]` is a
   table and which has no named field is a list; `load` calls itself for
   each entry.
2. **Normalize** (`spec.parse_config`). It works on a copy; the user's
   table is never changed.
   - The plugin can be written as `[1]`, `src`, `url`, or `plugin = …`.
   - `config` is an alias of `setup`.
   - `lazy = true` **adds** `User VeryLazy` to the other triggers.
   - `lazy = false` means `VimEnter`. Together with `event`/`cmd`/`ft` it
     **raises an error**. Careful: inside a list, that error stops every
     spec after it.
   - No trigger and no `lazy` → also `VimEnter`.
   - `cond` false (or a function returning false/nil) → the spec is
     recorded in `registry.disabled_plugins` and nothing else happens. The
     panel still shows it.
3. **Record** names, trigger text and a copy of the spec (without the
   `setup` closure) in the registry.
4. **Builds:** if the spec has `build`, remember it in `build_hooks` and
   call `check_and_build` (it does nothing if the plugin is not on disk
   yet).
5. **Create `load_now`**, one closure for the whole spec, and store it in
   `force_load_fns[name]` for every member. Dependencies use this table.
6. **Create the stubs** (`triggers.register_all`), described next.
7. **Too late for the startup event?** If the spec waits for `VimEnter`
   and startup is over, or for VeryLazy and it has fired
   (`registry.verylazy_fired`), `load_now` is scheduled for the next tick.
   Without this, a spec registered after startup never loaded.

### The four stubs (`loader/triggers.lua`)

| Trigger | Stub | When it fires |
|---|---|---|
| `event` | `once` autocmd(s) in the trigger group. Native events share one autocmd per pattern; each `User` event gets its own. | Calls `load_now(ev)`. |
| `ft` | One `FileType` autocmd in the trigger group. | Calls `load_now(ev)`. |
| `cmd` | A real user command with permissive options. | Deletes itself, calls `load_now`, then runs the real command with the same args, bang, range and modifiers. If the load failed, the stub is put back. |
| `keys` | A real keymap. | Deletes itself, calls `load_now`, then runs the `rhs` (or feeds the same key again if there is no `rhs`, so the plugin's own mapping answers). |

Details worth knowing:

- An unknown event name is reported and skipped; the other events and the
  other specs still register. A `keys` entry that `vim.keymap.set` rejects
  (lazy.nvim's `{ lhs, rhs }` order is the usual one) is handled the same
  way.
- `register_all` returns **two** cleanup lists. Command stubs are removed
  *before* `:packadd` (the plugin wants to create the same command name).
  Everything else is removed *after* the load.
- A key stub is removed only if it is still the stub. If the plugin
  already put its own mapping there, it is left alone.

---

## 6. Story 3: a trigger fires — `load_now`

`loader/init.lua:767`. This is the heart of the plugin.

```text
trigger fires
   │
   ▼
1. mark this trigger group as "seen" for the buffer
2. cycle check (A needs B needs A → error, stop)
3. already loaded? → return
4. snapshot the augroups (for the replay, step 11)
5. load dependencies ── fails? → stop, report, stay unloaded
6. pack.add(members, { load = false })  ── fails? → stop, report
7. check every member's directory really exists
8. remove command stubs
9. :packadd each member
10. start builds, then run setup() in order  (see Story 5)
11. remove the remaining stubs, record the load time, replay
```

Things that are easy to miss:

- **Dependencies** (step 5). If the dependency has its own spec, its own
  `load_now` is called. Otherwise it is just installed and `:packadd`ed.
  A dependency entry keeps only `src`, `name`, `version`, `data`: a
  trigger written *on a dependency entry* is ignored. To give a
  dependency triggers, a build or a setup, write a separate spec for it.
- **`:packadd` cannot be trusted** (step 7). It reports success for a
  plugin that does not exist, so the directory is checked on disk.
- **A failed load leaves the spec unloaded**, so the trigger can be tried
  again later.
- **`setup` runs once per member**, in the order the members were listed.
  A member's own `setup` wins; the spec-level `setup` is used for the
  first member only.
- After the setups have run, the closures are dropped so that whatever
  they captured can be garbage-collected.

---

## 7. Story 4: replay — "you missed an event"

This is the hardest part of the codebase. All of it is in
`loader/replay.lua`. There are **two different replays** that solve two
different problems.

### The tracker (shared by both)

Five events are tracked: `BufReadPre`, `BufReadPost` (= `BufRead`),
`BufNewFile`, `BufEnter`, `FileType`. Each time one fires, the tracker
remembers:

- `fired_events[buf][event] = true` — this event happened for this buffer.
- `fired_groups[buf][group] = true` — for every augroup that had a handler
  on that event at that moment: this group has seen it.

Both tables are cleaned on `BufWipeout`.

The key idea: **"already ran" is decided per augroup, not per event.** A
group created *after* the event has not seen it, even though the event is
in the past.

`has_fired(event, buf)` reads the first table. For any event outside the
five it always returns `false`.

### Replay A: after a load (`snapshot` + `after_load`)

Problem: a plugin loads on `FileType`. While loading, it registers its own
`FileType` and `BufReadPost` handlers. Neovim does not run an autocmd that
was added while its event is firing, and `BufReadPost` is already over. So
the plugin misses the very file that loaded it.

Solution:

1. Before loading, `snapshot(event)` writes down which augroups exist on
   the trigger event and on its **predecessors**:

   | Trigger | Predecessors also replayed |
   |---|---|
   | `BufReadPost` | `BufReadPre` |
   | `FileType` | `BufReadPre`, `BufNewFile`, `BufReadPost` |
   | `BufEnter` | `BufReadPre`, `BufNewFile`, `BufReadPost`, `FileType` |
   | anything else | none |

2. After loading, `after_load` fires each of those events once per augroup
   that is **new** (not in the snapshot), scoped to that group.
   - The trigger event is always fired to the new groups.
   - A predecessor is fired only if it really ran for this buffer.
   - Events still to come (for example `BufReadPost` after a `BufReadPre`
     load) are left to Neovim.

Old groups are never fired again, so no handler runs twice. Autocmds
without an augroup cannot be addressed and are never replayed. The replay
happens once per spec, and nesting is limited to depth 2.

### Replay B: after VeryLazy (`replay_for_buffer`)

Problem: `nvim file.lua`. The file is read, *then* the UI appears, *then*
VeryLazy registers many `BufReadPost` stubs. They all missed the read.

Solution: for one buffer, fire `BufReadPre` + `BufReadPost` (existing
file) or `BufNewFile` (new buffer), then `BufEnter` and `FileType`, each
one once per augroup that is **not** in `fired_groups[buf]`. Each group is
marked as it is fired, so calling it twice is safe.

`init.lua` calls this for every open file right after VeryLazy. It is also
public: `require('resonance').replay_for_buffer(buf)`.

> `loader/dag.lua` has an older helper, `_get_event_chain_internal`. It is
> **not** part of either replay. Only the tests call it today.

---

## 8. Story 5: builds

Two files: `loader/build.lua` (does things) and `builds.lua` (remembers
things).

**When does a build run?** `check_and_build(name, dir, task)` compares the
plugin's current commit (read straight from the `.git` files, no
subprocess) with the marker file
`stdpath('state')/resonance/builds/<name>`. Different → build. It is
called:

- when the spec is registered (`load(spec)`),
- when the spec loads (`load_now`), unless the build already failed in
  this session,
- on `PackChanged` with kind `install` or `update`. An `install` deletes
  the marker first, so it always builds. A `delete` only removes the marker.

**What is a build?**

- A string → `sh -c <string>` in the plugin directory. At most
  `build.concurrency` (default 2) of these run at once.
- A function → called with the directory. If it returns something with
  `:wait()` (a `vim.system` object) or `:await()` (a promise), the build
  waits for it. Lua hooks are not counted in the concurrency limit.

**Rules**

- State goes `pending → running → ok | failed`.
- **Only the exit code decides.** Text on stderr is not a failure. The last
  4 KB of output is kept and shown when a build fails.
- One build per plugin at a time. A second request joins the running one.
- Across Neovim sessions too: a lock file in
  `stdpath('state')/resonance/locks/<name>` holds a PID. A second session
  waits; if the first one built the same commit, the second skips. A lock
  whose process is dead is taken over.
- After 10 minutes a build is killed and marked failed.
- The marker is written only on success, so a failed build is tried again
  later.
- Progress is reported as one Neovim progress message per batch
  ("Building (1/3) name"), and each build also sends its own
  success/failure notification.

**Setup waits for the build.** A plugin must not be set up on a half-built
tree. In `setup_members` (`loader/init.lua:688`):

- Members listed before the first building member are set up now.
- From that member on, everybody waits (to keep the order):
  - If a **command or a keymap started the load**, Neovim waits up to 30 s
    for the build (the event loop keeps running). If the build is still
    going after that, the setup is postponed and the user is told.
  - Otherwise nothing waits; the setups run when every build has settled.
- A failed build still gets its plugin set up.

The trigger that fired decides. The `cmd` and `keys` stubs call
`load_now(triggers.USER_ACTION)`; an autocmd calls it with its event. The
flag travels in `visiting_path`, so a dependency loaded for a command
waits too. A spec with `event` + `keys` that loads through its event does
not wait.

---

## 9. Story 6: the panel

`open_ui()` → `ui/init.lua:136`.

1. **Scan.** `scanner.get_info()` asks `vim.pack.get(nil, { info = false,
   offline = true })` (fast, reads the lockfile) and adds the plugins
   disabled by `cond`. The result is SoA: parallel arrays indexed
   `1..info.total`. Always loop to `info.total`, never `#array`, because
   some arrays have holes.
2. **Window.** `snacks.win` if snacks is installed, else `nui.popup`, else
   a plain floating window.
3. **Commits and URLs** come from the same cheap `pack.get`; anything
   missing is read from the git files in chunks of 11 plugins.
4. **Render.** `render.lua` rebuilds the whole buffer each time, reusing
   the same Lua tables (`table.clear`). While checking, the spinner
   rewrites only its own line every 100 ms.

Keys (`bind_keys`, `ui/init.lua:38`):

| Key | What it does | Where |
|---|---|---|
| `<CR>` | Expand a row. Branches and tags for **that one plugin** are fetched with `info = true` in a cancellable async task. | `actions.toggle_details` |
| `r` | Resonate (below). | `actions.check_updates_network` |
| `u` / `U` | `vim.pack.update` for one plugin / all pending ones. | `actions.update_plugins` |
| `s` | Hide a pending update from the list. | `ui/init.lua` |
| `c` | Ask for a branch/tag/commit and run `git checkout`. | `actions.checkout_plugin` |
| `dd` | `vim.pack.del`, then delete the build marker. | `actions.uninstall_plugin` |
| `A` | Dependency view. This is the one place the panel requires the loader. | `state.refresh_dag_data` |
| `S` / `D` | Grep / browse the pack directory. | `ui/init.lua` |
| `C` | vim.pack's own update review, offline. | `ui/init.lua` |
| `q`, `<Esc>` | Close. | |

**Resonate (`r`)** in three steps:

1. `git fetch --tags --force` in every plugin directory, at most
   `resonate.concurrency` at once (default: 2 × CPU threads).
2. One blocking `pack.get(nil, { info = true, offline = true })` to learn
   each plugin's target revision (`rev_to`).
3. For every plugin where `rev ≠ rev_to`: `git log --oneline rev..rev_to`,
   shown under the plugin.

The panel's git processes (fetch, log, checkout) run with
`utils.git_env()`: the environment without `GIT_DIR`, `GIT_WORK_TREE` and
`GIT_INDEX_FILE`, which would otherwise point git at another repository.

---

## 10. Story 7: `import('plugins')`

`scandir.lua`. Optional; the module is only required if the user calls
`import()`.

1. List the top level of `<config>/lua/plugins/`: every `*.lua` file and
   every folder that has an `init.lua`. Sort by name.
2. `require` each one under `pcall`. A module returns one spec or a list of
   specs; anything else is ignored.
3. Sort all collected specs by `priority` (high first, default 0, ties in
   file order), remove `priority`, and call the public `load()` for each,
   again under `pcall`.

Small rules: the folder's own `init.lua` is read first as the module
`plugins`; a subfolder that was imported on its own (`plugins.core`) is
skipped by the parent import; errors go to `opts.on_error` or a
notification.

> **Careful:** `import()` recognises a positional spec only when its first
> element contains `://`. `{ 'git@host:user/repo' }` works with `load()`
> but is silently ignored by `import()`; write it with `src = …` there.

---

## 11. Without `vim.pack` (fallback mode)

`utils.get_pack()` returns `nil` when `vim.pack` is missing or was set to
`false`. Then:

- Plugins are found by scanning `site/pack/*/{opt,start}/*` on disk.
- Triggers, loading and build hooks still work. Nothing is installed:
  the plugin must already be on disk.
- In the panel, `u`, `U`, `dd` and `C` are unavailable. `r` still fetches
  but cannot list updates, and expanded rows show no branches or tags.
  `c` (checkout) works, because it calls git directly.

Always go through `utils.get_pack()`; never read `vim.pack` directly.

---

## 12. Where to look when…

| I want to… | Start here |
|---|---|
| understand a spec field | `loader/spec.lua` `parse_config` |
| add a trigger type | `loader/triggers.lua` `register_all` |
| change the load order / setup order | `loader/init.lua` `load_now`, `setup_members` |
| debug "handler ran twice" or "plugin missed the file" | `loader/replay.lua` |
| debug "build runs every startup" | marker: `loader/build.lua` `check_and_build`, `mark_build_success` |
| debug "build never finishes" | `builds.lua` state + locks; `builds.status(name)` |
| add a panel key | `ui/init.lua` `bind_keys` + `ui/actions.lua` |
| add a panel column | `ui/render.lua` `draw_plugin` (+ a new parallel array in `scanner.lua`) |
| add a `setup()` option | `AGENTS.md` §5 has the recipe |

Handy calls while debugging:

```lua
require('resonance.registry').specs            -- every registered spec
require('resonance.registry').plugin_triggers  -- name -> trigger text
require('resonance.builds').status('name')     -- state, error, output tail
require('resonance').has_fired('BufReadPost', 0)
require('resonance').stats()
```

---

## 13. Working on the code

```bash
./test/run_all.sh                        # whole suite, in an isolated env
test/dev_env.sh test test/gc_spec.lua    # one spec file
test/dev_env.sh nvim                     # an isolated Neovim to play in
```

- The tests run against a **copy** installed under `.dev/`, never against
  your real config. `test/dev_env.sh test` syncs the copy first.
- 374 tests passed on 2026-11-20.
- The editing rules (red lines, code style, commit rules) are in
  `AGENTS.md`. Read §2 before changing anything.
