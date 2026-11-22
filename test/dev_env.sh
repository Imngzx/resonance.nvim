#!/usr/bin/env bash
# An isolated Neovim environment for developing resonance.nvim.
#
# Every XDG directory points into <repo>/.dev, so the tests and any manual
# session started from here never touch the real ~/.local, ~/.config or the
# plugin copy the editor actually runs.
#
# Usage: test/dev_env.sh <command> [args]
#   bootstrap          create .dev and install resonance + fixture plugins (idempotent)
#   sync               copy the working tree over the installed copy in .dev
#   test [spec.lua…]   bootstrap, sync, then run the whole suite or the named specs
#   nvim [args]        start an isolated Neovim
#   shell              start $SHELL with the isolated environment exported
#   path               print the installed copy's path

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$REPO/.dev"

export XDG_CONFIG_HOME="$DEV/config"
export XDG_DATA_HOME="$DEV/data"
export XDG_STATE_HOME="$DEV/state"
export XDG_CACHE_HOME="$DEV/cache"
# runner.lua refuses to run when it does not see this.
export RESONANCE_DEV_ENV="$DEV"

INSTALLED="$XDG_DATA_HOME/nvim/site/pack/core/opt/resonance.nvim"

bootstrap() {
  [ -d "$INSTALLED" ] && return 0
  mkdir -p "$XDG_CONFIG_HOME/nvim" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
  # An empty init.lua: the isolated config must not fall back to anything.
  : > "$XDG_CONFIG_HOME/nvim/init.lua"
  echo "Bootstrapping isolated env in $DEV ..."
  nvim --headless -u NONE -l "$REPO/test/dev_bootstrap.lua" "$REPO" "$DEV"
}

sync() {
  cp "$REPO"/lua/resonance/*.lua        "$INSTALLED/lua/resonance/"
  cp "$REPO"/lua/resonance/loader/*.lua "$INSTALLED/lua/resonance/loader/"
  cp "$REPO"/lua/resonance/ui/*.lua     "$INSTALLED/lua/resonance/ui/"
  mkdir -p "$INSTALLED/test"
  cp "$REPO"/test/*.lua                 "$INSTALLED/test/"
  cp "$REPO"/doc/resonance.txt "$REPO"/README.md "$REPO"/AGENTS.md "$INSTALLED/"
}

# Run Lua files in one headless Neovim. An error in `-c luafile` does not
# change Neovim's exit status, so a suite that crashed while loading used to
# exit 0. Each file runs under pcall, and a failure quits with a non-zero
# status instead.
run_lua_files() {
  local args=()
  for f in "$@"; do
    args+=(-c "lua local ok, e = pcall(dofile, '$f') if not ok then io.stderr:write(tostring(e) .. '\n') vim.cmd('cquit 1') end")
  done
  # A test that blocks Neovim outright cannot be stopped from inside (see the
  # watchdog in test/runner.lua), so the whole run has a time limit too.
  # runner.lua keeps the name of the running test in $DEV/current_test.
  local limit="${RESONANCE_SUITE_TIMEOUT_S:-600}"
  local status=0
  rm -f "$DEV/current_test"
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 10 "$limit" nvim --headless "${args[@]}" -c "qall" || status=$?
  else
    nvim --headless "${args[@]}" -c "qall" || status=$?
  fi
  # 124: stopped by timeout. 137: it had to be killed.
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    echo >&2
    echo "TIMEOUT: the run was stopped after ${limit} s (RESONANCE_SUITE_TIMEOUT_S)." >&2
    echo "The test running at that moment: $(cat "$DEV/current_test" 2>/dev/null || echo unknown)" >&2
  fi
  return "$status"
}

run_tests() {
  cd "$REPO"
  if [ $# -eq 0 ]; then
    run_lua_files test/run_all.lua
    return
  fi
  run_lua_files test/runner.lua "$@" test/summary.lua
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  bootstrap) bootstrap ;;
  sync) bootstrap; sync ;;
  test)
    bootstrap
    # Mutation checks edit the installed copy on purpose; syncing would undo
    # the mutation before the run.
    [ "${RESONANCE_TEST_ALLOW_STALE:-}" = 1 ] || sync
    run_tests "$@"
    ;;
  nvim) bootstrap; exec nvim "$@" ;;
  shell) bootstrap; echo "Isolated env: $DEV (exit to leave)"; exec "${SHELL:-bash}" ;;
  path) echo "$INSTALLED" ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
