# 🔊 Resonance.nvim

> A ridiculously fast, minimalist, and zero-dependency lazy-loader & plugin manager for Neovim (0.13+).

`Resonance.nvim` is born out of a desire for extreme performance and simplicity. It strips away the bloat of traditional package managers while keeping the most powerful features: **lazy-loading**, **automatic build hooks**, and an **elegant UI**.

**❤️Special Thanks to: [CWorld1](https://github.com/cworld1)**

## ✨ Features

- **Zero Dependencies:** Works out of the box. Native UI fallback is provided if you prefer a minimalist setup.
- **Ecosystem Resonance:** Gracefully upgrades its UI and search capabilities if `snacks.nvim` or `nui.nvim` are detected.
- **Advanced Lazy Loading:** Load plugins on `Event`, `Cmd`, `Keys`, or `FileType`.
- **Automatic Build Hooks:** Intercepts `PackChanged` events to automatically run `make`, `cargo`, or custom lua functions when a plugin is installed/updated.
- **Blazing Fast:** Built entirely on Neovim's native `vim.pack` and modern `vim.system` APIs.

## Preview Image

![Preview Image](https://github.com/user-attachments/assets/87dc705a-55c6-400d-9821-2b56660e25bf)

## 📦 Installation & Configuration

Add this bootstrap snippet to your `init.lua`. It ensures `resonance.nvim` is downloaded and prepended to your runtime path on the first run.

```lua
-- =====================================================================
-- 🎵 Bootstrap Resonance.nvim
-- =====================================================================
local plugin_url = "https://github.com/Imngzx/resonance.nvim"
local pack_path = vim.fn.stdpath("data") .. "/site/pack/core/opt/resonance.nvim"

if not vim.uv.fs_stat(pack_path) then
  vim.notify("󱑽 Resonating (Downloading resonance.nvim)...", vim.log.levels.INFO)
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    plugin_url,
    "--branch=main",
    pack_path
  })
end

vim.opt.rtp:prepend(pack_path)

vim.pack.add({ plugin_url })

-- =====================================================================
-- 🚀 Configuration
-- =====================================================================
local resonance = require("resonance")

resonance.setup({
  ui = {
    border = 'rounded',
    title = ' 󱑽 Resonance 󱑽 ',
    width = 0.65,
    height = 0.75,
    backdrop = 60, -- only for snacks
  }
})

-- UI keymap binding 
vim.keymap.set("n", "<leader>pL", resonance.open_ui, { desc = "Resonance UI" })

-- NOTE: must put this at the end of your init.lua!
resonance.trigger_verylazy()

```

## ⚡ Lazy Loading by Events

Because `Resonance.nvim` uses Neovim's native C-API (`nvim_create_autocmd`) under the hood, it supports **all** native Neovim events out of the box.

You can define events as a `string`, a `table` of multiple strings, or a detailed `User` event table.

### 1. Native Neovim Events

Here are the most commonly used native events for lazy-loading plugins:

- **Startup & UI:** `VimEnter`, `UIEnter`
- **File & Buffer:** `BufReadPre`, `BufReadPost`, `BufNewFile`, `BufEnter`
- **Mode Changes:** `InsertEnter`, `CmdlineEnter`, `VisualEnter`
- **Others:** `CursorMoved`, `FocusGained`, `TextYankPost`

**Examples:**

```lua
-- Single event
event = "VimEnter"

-- Multiple events
event = { "BufReadPost", "BufNewFile" }

-- Trigger when entering Insert or Command mode (Great for completion plugins)
event = { "InsertEnter", "CmdlineEnter" }
```

### 2. Custom (User) Events

For ecosystem-specific events (like the famous `VeryLazy` triggered by `resonance.trigger_verylazy()`), you must use the strict Neovim native format for `User` autocmds:

**Examples:**

```lua
-- Trigger on VeryLazy
event = { "User", pattern = "VeryLazy" }

-- Trigger on other custom patterns (e.g. Mason load)
event = { "User", pattern = "MasonLoaded" }
```

### 📝 Complete Example

```lua
local resonance = require('resonance')

resonance.load({
  plugin = "https://github.com/nvim-treesitter/nvim-treesitter",
  -- Multiple native events stacked together
  event = { "BufReadPre", "BufNewFile" },
  setup = function()
    -- Config here...
  end
})
```

## 📊 Dashboard Resonance.stats integration

![Preview Image](https://github.com/user-attachments/assets/7b09a0be-6c3d-40a5-900a-ac0e116d7731)

Resonance provides a clean, zero-hack API to retrieve plugin statistics and exact startup times, heavily inspired by `lazy.nvim`.

Because Resonance locks the "Time to UI" exactly at the first moment `require('resonance').stats()` is called, placing this in your dashboard's render function guarantees the most accurate startup time measurement.

### The `stats()` API

```lua
local stats = require("resonance").stats()
-- returns:
-- {
--   count = 37,        -- Total number of plugins managed
--   loaded = 20,       -- Plugins loaded at startup
--   startuptime = 24.5,-- Startup time in milliseconds (Time to UI)
--   times = { ... }    -- Table containing load times for individual plugins
-- }
```

For snacks.nvim:

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

For alpha.nvim:

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

For mini.starter

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

## ⌨️ UI Keymaps

> [!TIP]
> When the Resonance panel is open:

- `H` : Jump to home (top)
- `U` : Trigger plugin updates (vim.pack.update())
- `S` : Search inside plugins source code (Powered by Snacks.picker / Telescope / Native vimgrep)
- `D` : Open plugin directory
- `q` / Esc : Quit

## Simple Configuration examples

[Complex example](https://github.com/Imngzx/nvim-config-rice-.ver-)
[Simple example](https://github.com/Imngzx/resonance-demo-nvim-config)

## License

This project is licensed under the MIT License.
