-- Run all test suites
-- Usage: nvim --headless -c "luafile test/run_all.lua" -c "qall"

dofile('test/runner.lua')

dofile('test/spec_spec.lua')
dofile('test/triggers_spec.lua')
dofile('test/build_spec.lua')
dofile('test/builds_spec.lua')
dofile('test/scanner_spec.lua')
dofile('test/loader_spec.lua')
dofile('test/integration_spec.lua')
dofile('test/ui_spec.lua')
dofile('test/integration_deep_spec.lua')
dofile('test/behavior_build_spec.lua')
dofile('test/behavior_chain_spec.lua')
dofile('test/behavior_replay_spec.lua')
dofile('test/behavior_triggers_spec.lua')
dofile('test/behavior_stats_spec.lua')
dofile('test/behavior_arch_spec.lua')
dofile('test/behavior_ui_spec.lua')
dofile('test/pack_integration_spec.lua')

test.print_summary()
test.exit_with_status()