-- DynamicRacingLine line_core/guidance_cache.lua
-- Small cache with explicit stale markers for FPS spikes.

local M = { entry = nil }
function M.get(key, now, maxAge)
  if not M.entry or M.entry.key ~= key then return nil end
  if (now or os.clock()) - (M.entry.stamp or 0) > (maxAge or 0.3) then return nil end
  return M.entry.value
end
function M.put(key, value, now) M.entry = { key = key, value = value, stamp = now or os.clock() }; return value end
function M.clear() M.entry = nil end
return M
