-- DynamicRacingLine line_core/throttle_solver.lua
-- Adds throttle pickup hints after path-linked brake solve.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local M = {}

function M.apply(points, frame, opts)
  opts = opts or {}
  local n = #(points or {})
  local traction = tonumber(opts.tractionAccelMps2 or (opts.car and opts.car.tractionAccelMps2)) or Config.DEFAULT_TRACTION_ACCEL_MPS2
  local spacing = math.max(1, frame and frame.spacing or Config.TARGET_SAMPLE_SPACING_M)
  for i = 1, n do
    local ni = (i % n) + 1
    local v = points[i].solvedSpeedMps or points[i].targetSpeedMps or 0
    local vn = points[ni].solvedSpeedMps or points[ni].targetSpeedMps or v
    local accel = math.max(0, (vn * vn - v * v) / (2 * spacing))
    local curveGate = U.clamp(1 - math.abs(points[i].curvature or 0) / (Config.CURVATURE_STRONG_ABS * 2), 0.15, 1)
    points[i].throttleHint = U.clamp(accel / math.max(1, traction) * curveGate, 0, 1)
  end
  return points, { ok = true, reason = 'throttle_application_solved' }
end

return M
