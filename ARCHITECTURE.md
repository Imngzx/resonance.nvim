# Architecture

How resonance.nvim is put together. The hard rules for editing it are in
`AGENTS.md`. This file explains the shape those rules protect. The source
is the final authority.

## Layers

```text
init.lua (public API)
   │ setup() / load()                       open_ui()
   ▼                                           ▼
loader/  ── control plane ──┐            ui/  ── read-only panel
  init     load, load_now,  │              init    window, keymaps
           event tracker,   │              state   singleton st.state
           replay           │              render  full rebuild + spinner line
  spec     normalize a spec │              actions fetch, update, checkout, uninstall
  triggers event/cmd/keys/ft│                 │
  build    markers, run cmds│                 ▼
  dag      deps + chains    │            scanner.lua ── read-only discovery
   │                        │                 │
   ▼                        ▼                 ▼
builds.lua (build state)   registry.lua (pure shared data)  ◄── both sides
                           specs, triggers, disabled, load times, plugin dirs
utils.lua: get_pack(), notify(), event normalization, git-file hash
```

- The registry depends on nothing. The loader and the scanner both depend on
  it, and the scanner never requires the loader. Opening the panel must not
  install the loader's autocmds.
- `builds.lua` only holds state: it runs no processes and requires nothing
  from the loader. `loader/build.lua` runs the commands and reports into it.
- The loader installs its autocmds the first time it is used (`setup()` or
  `load()`), never at require time.

## Flow 0: startup and `VeryLazy`

- `setup()` and `load()` arm `User VeryLazy` (guarded, so only once). It
  fires at `UIEnter`, or at `VimEnter` when there is no UI, from autocmds in
  the `ResonanceVeryLazy` augroup. If startup is already over when
  Resonance is loaded, it fires on the next tick.
- `fire_verylazy()` runs the VeryLazy handlers synchronously, then calls
  `replay_for_buffer()` for every loaded buffer with a name (unless
  `setup({ replay = false })`). Synchronous on purpose: by then every
  handler has registered its triggers, and a scheduled replay would run
  after the `once` triggers were consumed.
- A `fired` flag keeps it to one fire even if both paths reach it. A
  generation counter, bumped by `_reset()`, makes callbacks armed by an
  older module instance do nothing (the test runner builds one per test).
- `trigger_verylazy()` is the same guarded arm, kept for old configs.

## Flow 1: `load(spec)`

1. `spec.parse_config` works on a copy of the spec. It normalizes
   `plugin`, `setup`/`config` and `lazy`. `lazy = false` means `VimEnter`;
   `lazy = true` adds `User VeryLazy`. A spec with no trigger and no `lazy`
   field also loads on `VimEnter`.
2. The names, triggers and a retained copy of the spec are recorded in the
   registry. Build hooks go into `build_hooks`, and `check_and_build` runs
   for each one.
3. A single `load_now` closure is created for the whole spec and stored in
   `force_load_fns` under every member name, so dependency resolution works
   for any of them.
4. `triggers.register_all` registers the stubs in the augroup
   `Resonance_<first name>`. It returns two teardown lists: the command
   stubs, which are removed before `:packadd`, and everything else, which is
   removed after the load.
   - Events go through `utils.normalize_events`: `'VeryLazy'` and
     `'User Foo'` become User descriptors, and nested tables are normalized
     recursively. A list's own `pattern` applies to its native events only.
   - Native events are grouped by pattern, one autocmd per pattern. An
     unknown event name is reported with `utils.notify` and skipped; when
     Neovim rejects a list, the events are retried one by one so the valid
     ones still register.

## Flow 2: `load_now(ev)` (a trigger fires)

1. Mark this group as having fired for `ev.buf`. Run the cycle check,
   tracked with an ordered `visiting_path`.
2. Load the dependencies. A dependency that has its own spec goes through
   its own `load_now`. Any other dependency is installed with
   `pack.add(..., { load = false })` and then `:packadd`ed. If a dependency
   fails, the parent is aborted.
3. Install the members with `pack.add` inside `pcall`. Then confirm on disk
   that each directory exists, because `:packadd` reports success for a
   plugin that is not installed.
4. Remove the command stubs, then `:packadd` each member.
5. Builds and setups. Each member's `setup` runs exactly once:
   - Members listed before the first one with a running build are set up
     immediately.
   - The members from that one onward wait:
     - A `cmd` or `keys` load waits up to 30 s (`builds.wait`).
     - Any other load sets them up in `builds.on_complete` once every build
       has settled.
   - A failed build still gets its plugin set up.
6. Remove the remaining triggers and record the load time in
   `registry.load_times`.
7. Replay, once per spec. This only happens if the trigger event has
   already fired for this buffer. The chain (`dag._get_event_chain_internal`)
   is the trigger event and what follows it: `BufReadPre` and `BufNewFile`
   are followed by `BufReadPost`. Each event in the chain that has already
   fired for the buffer, other than the trigger event itself, is re-fired
   once per augroup with `exec_autocmds(..., { group = ... })`. Autocmds
   without a group are never replayed. Recursion is capped by
   `MAX_REPLAY_DEPTH = 2`.

## Flow 3: event tracking and replay

- The tracker records `BufReadPre`, `BufReadPost`, `BufNewFile`, `BufEnter`
  and `FileType` in `fired_events[buf][event]`. It also marks every augroup
  that existed at that moment in `fired_groups[buf][group]`. Both tables are
  pruned on `BufWipeout`.
- The augroup, not the event, is the unit of "already ran". An augroup
  registered after its event fired has not seen that event and still gets
  replayed. This is the `nvim <file>` case: the read events fire before
  `VeryLazy`, which is when the UI plugins register their triggers.
- `replay_for_buffer(buf)` is the public version of the replay. For an
  existing file it re-fires `BufReadPre` and `BufReadPost`, for a new
  buffer `BufNewFile`. In both cases it then re-fires `BufEnter` and
  `FileType`, scoped to each pending augroup.

## Flow 4: builds

- **Marker:** `stdpath('state')/resonance/builds/<name>` holds the commit the
  plugin was last built at. The commit is read from the git files
  (`utils.get_local_hash`), with no subprocess. The marker never goes in
  the plugin's own directory.
- **When a build runs:** `check_and_build` runs at load and on
  `PackChanged` (`install` and `update`). It builds when the commit differs
  from the marker. Uninstalling a plugin from the panel deletes its marker.
- **State:** a build goes `pending → running → ok | failed`. Only the exit
  code decides the result, and the stdout/stderr tail is kept.
- **Timeouts:** the hard timeout kills a build at 10 min
  (`builds.HARD_TIMEOUT_MS`). `builds.NOTIFY_THRESHOLD_MS` (4 s) is
  defined, but nothing reads it yet.
- **Locks:** lock files in `stdpath('state')/resonance/locks` hold a PID
  and are checked for liveness. They stop two Neovim sessions from building
  the same plugin at once.
- **One build at a time:** `run_build` joins a build that is already
  running or pending instead of starting another.

## Flow 5: the panel

- **Open:** `scanner.get_info()` returns the plugins as parallel arrays
  (SoA, indexed `1..total`), built from `pack.get(nil, { info = false })` plus the plugins
  disabled by `cond`.
- **Commit and URL columns:** a first pass takes them from the same cheap
  `pack.get`. The rest are filled in chunks of 11 on `vim.defer_fn`.
- **Expanding a row:** the branches and tags for that one plugin are
  fetched with `info = true` inside a cancellable `vim.async` task. Closing
  the panel (`BufWipeout` on its buffer) cancels the task.
- **`r` (check for updates):** runs `git fetch` for every plugin, at most 5
  at once (`async.semaphore(5)`). It then makes one
  `pack.get(nil, { info = true })` call to get `rev_to`, and runs
  `git log rev..rev_to` for each plugin that has an update.
- **Rendering:** `render()` rebuilds the whole buffer from module-level
  tables that are reused across renders (`table.clear`). The spinner
  rewrites only its own line every 100 ms.

## Things that bite

- **`vim.pack` is loaded lazily.** Go through `utils.get_pack()`. A raw
  `false` means the user disabled it on purpose.
- **Fast-event contexts** (libuv callbacks, `vim.system` callbacks): use
  `utils.notify` and `vim.schedule` there, never direct `vim.notify` or
  `nvim_*` calls.
- **A trigger pattern can be a list.** Join it before showing it.
- **Tests run against the installed copy.** Sync it first (`AGENTS.md` §4).
  `pack_integration_spec` installs real plugins into a temporary
  `XDG_DATA_HOME`.
