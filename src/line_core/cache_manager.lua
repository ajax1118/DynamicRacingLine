-- DynamicRacingLine line_core/cache_manager.lua
-- Fine cache key buckets for setup/grip/speed/wet/sample changes.

local Dynamic = require('src.line_core.dynamic_context')
local M = {}
function M.runtimeKey(ctx) return Dynamic.cacheKey(ctx or {}) end
function M.isStale(entry, now, maxAgeS) return not entry or ((now or os.clock()) - (entry.stamp or 0)) > (maxAgeS or 0.3) end
return M
