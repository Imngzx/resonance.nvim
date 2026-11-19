-- Behavioral tests for resonance.nvim
--
-- These assert observable outcomes, not just that functions exist. Each test
-- must fail if the behavior it describes regresses.
--
-- The suite is split into focused files by subject. This file only loads
-- them, so it can still be run on its own:
--
--   nvim --headless -c "luafile test/runner.lua" -c "luafile test/behavior_spec.lua" -c "qall"

local SUITES = {
  'test/behavior_arch_spec.lua',
  'test/behavior_build_spec.lua',
  'test/behavior_chain_spec.lua',
  'test/behavior_replay_spec.lua',
  'test/behavior_verylazy_spec.lua',
  'test/behavior_specs_spec.lua',
  'test/behavior_stats_spec.lua',
  'test/behavior_triggers_spec.lua',
  'test/behavior_ui_spec.lua',
}

for i = 1, #SUITES do
  dofile(SUITES[i])
end
