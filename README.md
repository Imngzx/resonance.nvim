# 🔊 Resonance.nvim

> A ridiculously fast, minimalist, and zero-dependency lazy-loader & plugin manager for Neovim (0.13+).

`Resonance.nvim` is born out of a desire for extreme performance and simplicity. It strips away the bloat of traditional package managers while keeping the most powerful features: **lazy-loading**, **automatic build hooks**, and an **elegant UI**.

## ✨ Features

- **Zero Dependencies:** Works out of the box. Native UI fallback is provided if you prefer a minimalist setup.
- **Ecosystem Resonance:** Gracefully upgrades its UI and search capabilities if `snacks.nvim` or `nui.nvim` are detected.
- **Advanced Lazy Loading:** Load plugins on `Event`, `Cmd`, `Keys`, or `FileType`.
- **Automatic Build Hooks:** Intercepts `PackChanged` events to automatically run `make`, `cargo`, or custom lua functions when a plugin is installed/updated.
- **Blazing Fast:** Built entirely on Neovim's native `vim.pack` and modern `vim.system` APIs.

## 📦 Installation & Configuration

Add this bootstrap snippet to your `init.lua`. It ensures `resonance.nvim` is downloaded and prepended to your runtime path on the first run.

```lua
local pack_path = vim.fn.stdpath("data") .. "/site/pack/resonance/start/resonance.nvim"
local plugin_url = "https://github.com/Imngzx/resonance.nvim"

if not vim.uv.fs_stat(pack_path) then
  vim.notify("🎵 Resonating (Downloading resonance.nvim)...", vim.log.levels.INFO)
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/Imngzx/resonance.nvim.git",
    "--branch=main",
    pack_path
  })
end

vim.opt.rtp:prepend(pack_path)

-- 👇 add this for updating resonance.nvim
vim.pack.add({ plugin_url })

-- =====================================================================
-- 🚀 Configuration
-- =====================================================================
local resonance = require("resonance")

resonance.setup({
  ui = { border = "rounded", width = 0.65 }
})

-- example: snacks
resonance.load({
  plugin = "https://github.com/folke/snacks.nvim",
  event = { 'User', pattern = 'VeryLazy' },
  setup = function()
  end
})

-- UI keymap binding 
vim.keymap.set("n", "<leader>pL", resonance.open_ui, { desc = "Resonance UI" })

-- NOTE: must put this at the end of your init.lua!
resonance.trigger_verylazy()

```

Then add code below on the very top of your init.lua (* Optional)

```lua
_G.start_time = vim.uv.hrtime()
_G.end_time = nil

vim.api.nvim_create_autocmd('UIEnter', {
  once = true,
  callback = function()
    _G.end_time = vim.uv.hrtime()
  end
})
 ```

The code above can helps you to calculate your loading time.

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
resonance.load({
  plugin = "https://github.com/nvim-treesitter/nvim-treesitter",
  -- Multiple native events stacked together
  event = { "BufReadPre", "BufNewFile" },
  setup = function()
    -- Config here...
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

## License

This project is licensed under the MIT License.
