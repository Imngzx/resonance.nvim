-- The registry is the shared, pure-data state of the plugin manager.
--
-- It exists to break the cycle between the loader and the scanner. The
-- loader needs to write load times, and the scanner needs to read the
-- specs, the triggers and the disabled plugins -- so the scanner used to
-- require the loader, while the loader required the scanner. Requiring
-- either one pulled in the other, and with it the whole control plane:
-- opening the read-only UI panel installed the PackChanged build autocmd.
--
-- Nothing here depends on the loader or the scanner, so both can require
-- it freely. The registry holds data and nothing else: no require-time
-- side effects, no autocmds, no I/O.
--
-- The plugin directory lookup lives here too, because the scanner needs it
-- for the plugins a false `cond` disabled -- those are in the registry but
-- not in vim.pack, so the scanner has nowhere else to ask.

local M = {}

-- Plugin triggers registered by the loader, keyed by plugin name.
M.plugin_triggers = {}

-- Plugins disabled by a false `cond` predicate, keyed by plugin name.
M.disabled_plugins = {}

-- Specs registered by the loader, keyed by plugin name.
M.specs = {}

-- URL -> spec name mapping.
M.spec_urls = {}

-- Load time in milliseconds, keyed by plugin name.
M.load_times = {}

-- Plugin name -> installation directory.
--
-- Populated lazily from the vim.pack cache, or from a filesystem scan when
-- vim.pack is unavailable. The loader invalidates it when a plugin is
-- installed or removed.
M.plugin_dirs = nil

--- Drop the cached plugin directories.
---
--- A plugin installed or removed during the session was not in the cached
--- directories, so the cache has to go when one is.
function M.invalidate_plugin_dirs()
  M.plugin_dirs = nil
end

--- Forget everything.
---
--- For testing.
function M._reset()
  for k in pairs(M.plugin_triggers) do M.plugin_triggers[k] = nil end
  for k in pairs(M.disabled_plugins) do M.disabled_plugins[k] = nil end
  for k in pairs(M.specs) do M.specs[k] = nil end
  for k in pairs(M.spec_urls) do M.spec_urls[k] = nil end
  for k in pairs(M.load_times) do M.load_times[k] = nil end
  M.plugin_dirs = nil
end

return M
