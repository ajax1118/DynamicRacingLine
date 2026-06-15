-- DynamicRacingLine line_core/quality_report.lua
-- Quality report flags: centerline_fallback_used, zero_visible_tiles.

local M = {}
function M.build(guidance)
  local w = guidance and guidance.window or {}
  return {
    centerline_fallback_used = guidance and tostring(guidance.reason or ''):find('centerline', 1, true) ~= nil,
    zero_visible_tiles = (w.tileCount or #(w.tiles or {})) == 0,
    confidence = guidance and guidance.confidence or 0,
    reason = guidance and guidance.reason or 'no_guidance',
    profileWarnings = guidance and guidance.profileWarnings or {},
    defaultState = guidance and guidance.defaultState or 'generated_predictive_baseline',
    default_profile = guidance and guidance.default_profile or false,
    avoidRenderWhenTileCountZero = (w.tileCount or #(w.tiles or {})) == 0,
  }
end
function M.format(q) q = q or {}; return string.format('centerline_fallback_used=%s zero_visible_tiles=%s confidence=%.2f reason=%s', tostring(q.centerline_fallback_used), tostring(q.zero_visible_tiles), tonumber(q.confidence or 0), tostring(q.reason or 'unknown')) end
return M
