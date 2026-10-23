-- Run all test suites
-- Usage: nvim --headless -c "luafile test/run_all.lua" -c "qall"

dofile('test/runner.lua')

dofile('test/spec_spec.lua')
dofile('test/triggers_spec.lua')
dofile('test/build_spec.lua')
dofile('test/scanner_spec.lua')
dofile('test/loader_spec.lua')
dofile('test/integration_spec.lua')
dofile('test/ui_spec.lua')

test.print_summary()
test.exit_with_status()