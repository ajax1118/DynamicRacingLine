-- DynamicRacingLine line_core/line_quality_monitor.lua
-- Runtime quality flags for no-tile, fallback, or centerline-collapse events.

local M = {}
function M.evaluate(g)
  local w = g and g.window or {}
  return { ok = g and g.ok == true and (w.tileCount or #(w.tiles or {})) > 0, tileCount = w.tileCount or #(w.tiles or {}), confidence = g and g.confidence or 0, reason = g and g.reason or 'no_guidance' }
end
return M
