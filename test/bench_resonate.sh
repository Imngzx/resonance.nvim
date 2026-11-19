#!/usr/bin/env bash
# Benchmark Resonate (`r` in the panel) without the network.
#
# Usage: test/bench_resonate.sh
#   RESONANCE_BENCH_PLUGINS=49       fixture plugins
#   RESONANCE_BENCH_LATENCY_MS=500   simulated round trip per `git fetch`
#   RESONANCE_BENCH_RUNS=3           checks timed
#   RESONANCE_BENCH_CONCURRENCY=     resonate.concurrency (default: the plugin's)
#
# Runs against the synced copy in .dev (test/dev_env.sh path), in its own
# throwaway XDG dirs, so neither the real config nor .dev is touched.
# RESONANCE_TEST_ALLOW_STALE=1 skips the sync, to benchmark an edited
# installed copy (an experiment, or a mutation check). Exits non-zero when
# a check misses a pending update. See test/bench_resonate.lua.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ "${RESONANCE_TEST_ALLOW_STALE:-}" = 1 ] || "$REPO/test/dev_env.sh" sync
INSTALLED="$("$REPO/test/dev_env.sh" path)"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/resonance-bench.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export XDG_CONFIG_HOME="$ROOT/config" XDG_DATA_HOME="$ROOT/data"
export XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export RESONANCE_BENCH_ROOT="$ROOT"
# The simulated latency goes through git's ext:: transport, which git
# refuses unless it is allowed. Scoped to this process tree.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.ext.allow GIT_CONFIG_VALUE_0=always

nvim --headless -u NONE --cmd "set rtp^=$INSTALLED" -l "$REPO/test/bench_resonate.lua"
