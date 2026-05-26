# Resonance.nvim

> [!WARNING]
> This plugin is still in alpha development, README will be updated soon

## installation

```lua
-- =====================================================================
-- 🎵 Bootstrap Resonance.nvim
-- =====================================================================
local pack_path = vim.fn.stdpath("data") .. "/site/pack/resonance/start/resonance.nvim"

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

-- 确保插件在本次启动时立刻可用
vim.opt.rtp:prepend(pack_path)

-- =====================================================================
-- 🚀 使用 Resonance 加载你的配置
-- =====================================================================
local resonance = require("resonance")

resonance.setup({
  ui = { border = "rounded", width = 0.65 }
})

-- 示例：加载 Snacks
resonance.load({
  plugin = "https://github.com/folke/snacks.nvim",
  event = "VeryLazy",
  setup = function()
    -- 你的 snacks 设置
  end
})

-- UI 绑定
vim.keymap.set("n", "<leader>pL", resonance.open_ui, { desc = "Resonance UI" })

-- 引擎点火！
resonance.trigger_verylazy()

```
