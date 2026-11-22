#!/usr/bin/env bash
# Run lua-language-server over lua/ and fail on any diagnostic.
#
# The check needs Neovim's own type definitions (vim.SystemCompleted,
# vim.async.Task, ...), which live in $VIMRUNTIME/lua. .luarc.json cannot
# name that directory, because it differs per machine, so a config with the
# library path added is generated for the run.
#
# Usage: test/lint.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

for tool in nvim lua-language-server; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test/lint.sh: $tool is not on the PATH" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The config is JSON, and Neovim is the JSON tool every machine here has.
nvim --headless -u NONE -l /dev/stdin "$REPO/.luarc.json" "$TMP/luarc.json" <<'LUA'
local src, dst = arg[1], arg[2]
local config = vim.json.decode(table.concat(vim.fn.readfile(src), '\n'))
config.workspace = config.workspace or {}
config.workspace.library = { vim.env.VIMRUNTIME .. '/lua' }
vim.fn.writefile({ vim.json.encode(config) }, dst)
LUA

# --check exits non-zero when it finds a problem.
lua-language-server --check="$REPO/lua" --configpath="$TMP/luarc.json" \
  --checklevel=Warning --logpath="$TMP/log"
