-- DynamicRacingLine line_core/legacy_constants_bridge.lua
-- Use this while migrating old files that still reference fixed constants like
-- RACING_LINE_MAX_OFFSET_ACCEL_M = 0.024 and RACING_LINE_MAX_OFFSET_JERK_M = 0.012.

local Config = require('src.line_core.config')

local M = {}

function M.values()
  return {
    RACING_LINE_MAX_OFFSET_ACCEL_M = Config.OFFSET_ACCEL_MAX_M,
    RACING_LINE_MAX_OFFSET_JERK_M = Config.OFFSET_JERK_MAX_M,
    RACING_LINE_MAX_OFFSET_STEP_M = Config.OFFSET_STEP_MAX_M,
    RACING_LINE_MIN_OFFSET_ACCEL_M = Config.OFFSET_ACCEL_BASE_M,
    RACING_LINE_MIN_OFFSET_JERK_M = Config.OFFSET_JERK_BASE_M,
    RACING_LINE_DISABLE_CENTERLINE_VALIDATOR_FALLBACK = true,
    RACING_LINE_USE_ADAPTIVE_OFFSET_LIMITS = true,
  }
end

function M.apply(target)
  if not target then
    error('legacy_constants_bridge.apply() requires an explicit target table')
  end
  local v = M.values()
  for k, val in pairs(v) do target[k] = val end
  return v
end

return M
