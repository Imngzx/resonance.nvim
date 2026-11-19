#!/usr/bin/env bash
# Run all resonance.nvim tests, in the isolated env (see test/dev_env.sh).
# Usage: ./test/run_all.sh

set -euo pipefail

exec "$(dirname "$0")/dev_env.sh" test
