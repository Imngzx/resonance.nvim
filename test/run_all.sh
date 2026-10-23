#!/usr/bin/env bash
# Run all resonance.nvim tests
# Usage: ./test/run_all.sh

set -e

cd "$(dirname "$0")/.."

echo "Running all resonance.nvim tests..."
echo "=================================="

nvim --headless \
  -c "luafile test/run_all.lua" \
  -c "qall"

echo ""
echo "All tests passed!"