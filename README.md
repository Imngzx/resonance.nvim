# 🔊 Resonance.nvim

[![tests](https://github.com/Imngzx/resonance.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/Imngzx/resonance.nvim/actions/workflows/test.yml)

> An optimized, minimalist, and zero-dependency lazy-loader and `vim.pack` wrapper for Neovim (0.13+).

`Resonance.nvim` is born out of a desire for extreme performance and simplicity. It strips away the bloat of traditional package managers while keeping the most powerful features: **lazy-loading**, **automatic build hooks**, and an **elegant UI**.

**❤️Special Thanks to: [CWorld1](https://github.com/cworld1)**.

## ✨ Features

- **Zero Dependencies:** Works out of the box. Native UI fallback is provided if you prefer a minimalist setup.
- **Pretty UI:** Gracefully upgrades its UI and search capabilities if `snacks.nvim` or `nui.nvim` are detected.
- **Advanced Lazy Loading:** Load plugins on `Event`, `Cmd`, `Keys`, or `FileType`.
- **Automatic Build Hooks:** Intercepts `PackChanged` events to automatically run `make`, `cargo`, or custom Lua functions when a plugin is installed or updated.
- **Optional Folder Import:** Keep one spec per file in `lua/plugins/` and register them all with `resonance.import('plugins')`, lazy.nvim style, ordered by `priority`. Opt-in: nothing is scanned unless you call it.
- **Native Update Discovery:** Checks pending updates with `vim.pack.get()` and displays the commits from the installed revision to the resolved target revision.
- **Reported Failures:** A failed install is reported with the plugin name and the underlying error, instead of leaving a plugin that silently never loads.
- **Fast:** Built entirely on Neovim's native `vim.pack`, `vim.async`, and modern `vim.system` APIs.

> [!IMPORTANT]
> Requires **Neovim 0.13+**. The plugin uses `vim.async` and `vim.pack`, both of which are 0.13-era APIs.

> [!TIP]
> Please enable UI2 for better experience.

## Preview Image

<https://github.com/user-attachments/assets/f37b574f-6061-493b-95cb-9e9478616b05>

![Preview Image](https://github.com/user-attachments/assets/61066efd-71df-4499-af05-2b8984015ad3)

| ![Build notifications](https://github.com/user-attachments/assets/36ec5afb-23c4-4c3f-a1ae-88eaac56a88f) | ![DAG UI](https://github.com/user-attachments/assets/985d85a1-6fc4-4a6f-81f5-213ce737f12e) |
| -------------- | --------------- |

## 📦 Installation and Configuration

Add this bootstrap snippet to your `init.lua`. It ensures `resonance.nvim` is downloaded and prepended to your runtime path on the first run.

`vim.pack.add()` installs Resonance itself -- it is the one plugin you
install directly, because the plugin manager cannot manage itself. Every
other plugin goes through `resonance.load()`, which is what gives it
triggers.

```lua
-- =====================================================================
-- 🎵 Install Resonance.nvim
-- =====================================================================
-- You can also use the link from codeberg

-- Method 1:
vim.pack.add({'https://github.com/Imngzx/resonance.nvim'})

-- To stay on a tagged release instead of the latest commit:
-- vim.pack.add({{ src = 'https://github.com/Imngzx/resonance.nvim', version = 'v0.9.0' }})

--OR ...

-- Method 2 (for custom message):
local plugin_url = 'https://github.com/Imngzx/resonance.nvim'
local pack_path = vim.fn.stdpath('data') .. '/site/pack/core/opt/resonance.nvim'

if not vim.uv.fs_stat(pack_path) then
  vim.notify('󱑽 Resonating (Downloading resonance.nvim)...', vim.log.levels.INFO)
  vim.system({ 'git', 'clone', '--filter=blob:none', plugin_url, '--branch=main',
    pack_path }):wait()
end

vim.opt.rtp:prepend(pack_path)
-- Don't worry, both method works well (≧◡≦)

-- =====================================================================
-- 🚀 Configuration
-- =====================================================================
local resonance = require('resonance')

resonance.setup({
  ui = {
    border = 'rounded',
    width = 0.65,
    height = 0.75,
  },
  build = {
    concurrency = 2, -- build commands that run at once
    progress = true, -- report builds as progress messages (:h resonance-build-config)
  },
  resonate = {
    -- concurrency = 16, -- `git fetch` that run at once on Resonate
    --                   -- (default: 2 x CPU threads, :h resonance-resonate-config)
  },
})

resonance.load({
  -- Every other plugin goes here, with its triggers.
  {
    'https://github.com/<author>/<plugin_name>',
    event = 'VeryLazy',
  },
})
```

That is the whole setup. `VeryLazy` fires on its own once the UI is up,
and the files you opened before it are replayed for the plugins that
register their triggers then. See [Replaying Missed Events](#-replaying-missed-events).

> [!NOTE]
> **Keep netrw enabled unless you have `snacks.nvim` or `neo-tree.nvim`.**
> The panel's `D` key (open the plugin directory) uses the snacks explorer,
> then `:Neotree`, then netrw's `:Explore`. If you disable netrw
> (`vim.g.loaded_netrwPlugin = 1`) and have neither, `D` falls back to
> `:edit <dir>`, which only shows something when another plugin handles
> directories (oil.nvim, nvim-tree, mini.files).

### 🎨 Customizing Icons

The glyphs used for each plugin state can be changed via `ui.icons`. Each key is
independent, so you can override only the ones you care about.

| Key | State | Default |
|---|---|---|
| `loaded` | Plugin is loaded | `●` |
| `not_loaded` | Plugin is installed but not loaded | `○` |
| `disabled` | Plugin disabled by `cond` | ** |

```lua
resonance.setup({
  ui = {
    icons = {
      loaded = '✓',      -- or '[L]'
      not_loaded = '✗',  -- or '[U]'
      disabled = '',     -- empty string hides it entirely
    },
  },
})
```

> [!TIP]
> The default `disabled` glyph is a Nerd Font private-use codepoint (`U+F057`).
> If it renders as a blank box, set it to a codepoint your font actually has.

## ⚡ Lazy Loading by Events

Because `Resonance.nvim` uses Neovim's native C-API (`nvim_create_autocmd`) under the hood, it supports **all** native Neovim events out of the box.

You can define events as a `string`, a `table` of multiple strings, or a detailed `User` event table.

### 1. Native Neovim Events

Here are the most commonly used native events for lazy-loading plugins:

- **Startup and UI:** `VimEnter`, `UIEnter`
- **File and Buffer:** `BufReadPre`, `BufReadPost`, `BufNewFile`, `BufEnter`
- **Mode Changes:** `InsertEnter`, `CmdlineEnter`, `VisualEnter`
- **Others:** `CursorMoved`, `FocusGained`, `TextYankPost`

#### **Examples:**

```lua
-- Single event
event = "VimEnter"

-- Multiple events
event = { "BufReadPost", "BufNewFile" }

-- Restrict the event to certain files
event = { "BufReadPost", pattern = { "*.lua", "*.vim" } }

-- Trigger when entering Insert or Command mode (Great for completion plugins)
event = { "InsertEnter", "CmdlineEnter" }
```

### 2. Custom (User) Events

`VeryLazy` fires on its own once the UI is up. Any `User` event can be
written as a string or in Neovim's native form, and mixed into a list:

**Examples:**

```lua
-- Trigger on VeryLazy
event = "VeryLazy"

-- Other User events (e.g. Mason load) -- both spellings work
event = "User MasonLoaded"
event = { "User", pattern = "MasonLoaded" }

-- Mixed with native events
event = { "InsertEnter", "User MasonLoaded" }
```

An unknown event name is reported with a notification and skipped; the
rest of the spec, and every spec after it, still loads.

### Package Specs

Resonance accepts native `vim.pack` fields: `src`, `name`, `version`, and `data`. A source can also be supplied as the first positional value or through the `url` compatibility alias; Resonance normalizes both to `src` before calling `vim.pack.add()`.

Give an entry a lazy trigger -- `event`, `cmd`, `keys`, or `ft` -- to load it on
demand. An entry with no trigger loads eagerly on `VimEnter`, the same as `lazy = false` —
useful for a plugin you just want installed and pinned, with no trigger of its
own.

### 📝 Complete Example

```lua
local resonance = require('resonance')

resonance.load({
  {
    "https://github.com/<author>/<plugin1_name>",

    dependencies = "https://github.com/<author>/<plugin2_name>",

    build = 'make', -- npm i or others based on plugin's docs

    cmd = {'cmd1', 'cmd2'},
    -- Or with the command's own options:
    -- cmd = {name = 'cmd1', opts = {nargs = 0}},

    -- Conditional loading: boolean or function
    cond = function() return vim.fn.has('nvim-0.9') == 1 end,

    -- lazy = true: adds VeryLazy as FALLBACK (works with other triggers)
    lazy = true,

    -- Keys: shorthand strings normalized to {'n', 'key'}
    keys = {
      -- A key with no rhs means the plugin defines the mapping itself.
      -- The stub is removed once the plugin loads, and the plugin's own
      -- mapping is left in place.
      '<leader>Tg',
      '<leader>TL',
      -- Or full spec:
      { 'n', '<leader>Tc', '<cmd>cmd3<CR>', { desc = 'Open something' } },
    },

    event = { "BufReadPre", "BufNewFile" },
    -- For VeryLazy: event = "VeryLazy"
    config = function()

      local name = require('plugin1_name')

      name.setup({
      -- Config here...
      })

    end
  },

  { -- Version pinning examples
    "https://github.com/<author>/<plugin_versioned>",
    version = 'v1.0.0',  -- Tag
    -- version = 'main',     -- Branch
    -- version = 'abc1234',  -- Commit hash
    -- No trigger: loads eagerly on VimEnter. Use a trigger if you want
    -- the plugin to stay unloaded until you need it.
  },

  { -- lazy = false: eager load on VimEnter (no event/cmd/ft allowed)
    "https://github.com/<author>/<eager_plugin>",
    lazy = false,
  },

  -- { another plugin... },

  -- { another plugin... },
})
```

To register specs from one file per plugin instead of a single `load()` call, see [Importing a Plugins Folder](#-importing-a-plugins-folder-optional).

[Complex example](https://github.com/Imngzx/nvim-config-rice-.ver-/blob/nvim-native/lua/config/resonance.lua).

[Simple example](https://github.com/Imngzx/resonance-demo-nvim-config).

## 📂 Importing a Plugins Folder (optional)

Instead of calling `resonance.load()` for every spec, you can keep one spec
per file and import the whole folder, lazy.nvim style. It is opt-in: nothing
is scanned unless you call `import()`.

```lua
-- lua/plugins/jisho.lua
return {
  'https://github.com/Imngzx/jisho.nvim',
  cmd = 'Jisho',
  config = function() require('jisho').setup() end,
}
```

```lua
-- init.lua, after resonance.setup()
local resonance = require('resonance')
resonance.import('plugins.core')   -- lua/plugins/core/: theme, core UI
vim.api.nvim_create_autocmd('User', {
  pattern = 'VeryLazy',
  callback = function() resonance.import('plugins') end,  -- lua/plugins/
})
```

- A file returns one spec or a list of specs. Anything else it returns
  (a helper table, nothing) is ignored, so a file may still call
  `resonance.load()` itself.
- Only the top level is scanned: `*.lua` files and folders with an
  `init.lua` (`lua/plugins/heirline/init.lua`). Helper files inside a folder
  are never imported on their own. Files are required in name order.
- The folder's own `lua/plugins/init.lua` is the `plugins` module itself:
  its specs are read first, and it is never required a second time as
  `plugins.init`. It may call `import('plugins')` itself; its own return
  value is then not imported.
- A folder you import on its own (`plugins.core`) is skipped by the
  parent import (`plugins`), so its specs are not registered twice.
- `priority = 1000` registers a spec before the others in the same
  `import()` call (default 0) — put it on your colorscheme. It is stripped
  before `load()`. A non-number is reported and counts as 0.
- A file that fails to load is reported and skipped; the rest still load.
  Pass `on_error = function(mod, err) ... end` to handle it yourself (for
  example, raise in a strict test run).
- `root` changes the scanned `lua/` directory (default
  `stdpath('config') .. '/lua'`).

## 📊 Dashboard Resonance.stats integration

![Preview Image](https://github.com/user-attachments/assets/7b09a0be-6c3d-40a5-900a-ac0e116d7731)

Resonance provides a clean, zero-hack API to retrieve plugin statistics and exact startup times, heavily inspired by `lazy.nvim`.

`startuptime` is a one-shot measurement: it is latched at `UIEnter`/`VimEnter` (or at the first `stats()` call, whichever comes first) and never changes afterwards. Placing this in your dashboard's render function therefore guarantees the most accurate startup time measurement.

The plugin counts are read live on every call, because a plugin can load at any point -- after the first `stats()` call, or never.

### The `stats()` API

```lua
local stats = require("resonance").stats()
-- returns:
-- {
--   count = 37,        -- Total number of plugins managed
--   loaded = 20,       -- Plugins currently loaded
--   startuptime = 24.5,-- Startup time in milliseconds (Time to UI), latched
--   times = { ... }    -- Table containing load times for individual plugins
-- }
```

#### For snacks.nvim

```lua
require("snacks").setup({
  dashboard = {
    sections = {
      { section = 'header' },
      { section = 'keys', gap = 1, padding = 1 },
      function()
        local stats = require("resonance").stats()
        local ms = string.format("%.2f ms", stats.startuptime)
        return {
          align = 'center',
          text = {
            { "󱐋 ", hl = "Special" },
            { stats.loaded .. " / " .. stats.count, hl = "Special" },
            { " plugins loaded in ", hl = "Comment" },
            { ms, hl = "Special" },
          },
          padding = 1,
        }
      end,
    }
  }
})
```

#### For alpha.nvim

```lua
local alpha = require("alpha")
local dashboard = require("alpha.themes.dashboard")

-- ... (your header and buttons configuration) ...

-- Dynamically generate the footer
dashboard.section.footer.val = function()
  local stats = require("resonance").stats()
  local ms = string.format("%.2f ms", stats.startuptime)
  return "󱐋 " .. stats.loaded .. " / " .. stats.count .. " plugins loaded in " .. ms
end
-- Optional: apply highlight group to footer
dashboard.section.footer.opts.hl = "Comment"

alpha.setup(dashboard.opts)
```

#### For **mini.starter**

```lua
local starter = require("mini.starter")

starter.setup({
  -- ... (your items and hooks) ...

  footer = function()
    local stats = require("resonance").stats()
    local ms = string.format("%.2f ms", stats.startuptime)
    return "󱐋 " .. stats.loaded .. " / " .. stats.count .. " plugins loaded in " .. ms
  end
})
```

> [!TIP]
> `startuptime` is counted from the first `require('resonance')`. To count from the real start of Neovim (a very "honest" startuptime), add this on top of your init.lua.

```lua
-- enable this for a "very" honest startuptime :)
_G.start_time = vim.uv.hrtime()
```

## 🔁 Replaying Missed Events

`nvim <file>` reads the file before the UI is up. A plugin that registers
its `BufReadPost` trigger during `VeryLazy` would never see that read, so no
statusline, no treesitter, no LSP for the first file.

Resonance handles this on its own: right after the `VeryLazy` handlers
have run, it replays the read events for every open file. There is nothing
to add to your config. To turn it off:

```lua
resonance.setup({ replay = false })
```

The replay fires each read event once per **trigger group** that
has not yet run for the buffer. No handler runs twice for the same read,
and a trigger registered after the event already fired still gets its
chance to load — that is what makes the statusline and bufferline appear
when Neovim is started with a file.

Firing the events unconditionally instead makes every handler run twice,
and a duplicated `FileType` can reach `E218`.

The event that loads a plugin is also replayed to the handlers the plugin
registers while it loads, once, so a plugin loaded on `FileType` still
attaches to the file that loaded it. Handlers that existed before the load
do not run again.

For your own replays, `require('resonance').replay_for_buffer(buf)` runs
the same replay for one buffer, and `require('resonance').has_fired(event, buf)`
tells you whether an event has already run for it (the read events only:
`BufReadPre`, `BufReadPost`, `BufNewFile`, `BufEnter`, `FileType`). Calling the replay again
is safe: a group that already ran is not fired twice.

`resonance.trigger_verylazy()` is no longer needed. It still works, and
calling it as well as `setup()` fires `VeryLazy` only once.

## ⌨️ UI Keymaps

- `<CR>`: Expand the plugin at the cursor (branches, tags, path, URL).
- `U` : Update every plugin that `r` found pending (`vim.pack.update()`).
- `u` : Update the plugin at the cursor (`vim.pack.update()`).
- `dd`: Delete the plugin at the cursor.
- `c` : Check out an available branch, commit, or tag.
- `r` : Resonate: `git fetch` every plugin, then list the pending updates with their commits (`:h resonance-resonate-config`).
- `S` : Search inside plugins source code (Powered by Snacks.picker / Telescope / Native vimgrep).
- `A` : Check Dependency Graph (DAG) and Event Replay.
- `s` : Skip plugin update.
- `D` : Open plugin directory (snacks explorer / neo-tree / netrw).
- `C` : Open vim.pack's own update review (offline).
- `q` / Esc : Quit.

## License

This project is licensed under the MIT License.
