-- DynamicRacingLine line_core/validator.lua
-- Adaptive lateral validation and repair. The optimizer and smoother now share the same
-- limits so the optimizer does not create offsets that smoothing later rejects.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local Boundaries = require('src.line_core.boundaries')

local M = {}

local function curvatureAt(curvatures, i)
  if not curvatures or #curvatures == 0 then return 0 end
  local n = #curvatures
  while i < 1 do i = i + n end
  while i > n do i = i - n end
  return curvatures[i] or 0
end

function M.validate(offsets, frame, boundary, opts)
  opts = opts or {}
  local n = #offsets
  local reasons = {}
  local ok = true
  local spacing = frame and frame.spacing or Config.TARGET_SAMPLE_SPACING_M
  local curvatures = opts.curvatures or {}
  local speedMps = opts.speedMps or 0
  local confidence = opts.confidence or (boundary and boundary.confidence) or 0.55

  for i = 1, n do
    local b = Boundaries.at(boundary, i)
    local clamped = Boundaries.clampOffset(boundary, i, offsets[i] or 0)
    if math.abs(clamped - (offsets[i] or 0)) > 0.015 then
      ok = false
      reasons[#reasons + 1] = { kind = 'boundary', index = i, value = offsets[i], allowed = clamped, source = b.source }
    end
  end

  for i = 2, n do
    local b = Boundaries.at(boundary, i)
    local stepLimit = Config.dynamicOffsetStepLimit(spacing, speedMps, math.min(b.usableLeft, b.usableRight), confidence)
    local step = math.abs((offsets[i] or 0) - (offsets[i - 1] or 0))
    if step > stepLimit then
      ok = false
      reasons[#reasons + 1] = { kind = 'step', index = i, value = step, limit = stepLimit }
    end
  end

  for i = 3, n do
    local b = Boundaries.at(boundary, i)
    local curvatureAbs = math.abs(curvatureAt(curvatures, i))
    local accLimit = Config.dynamicOffsetAccelLimit(spacing, curvatureAbs, math.min(b.usableLeft, b.usableRight), confidence)
    local acc = math.abs((offsets[i] or 0) - 2 * (offsets[i - 1] or 0) + (offsets[i - 2] or 0))
    if acc > accLimit then
      ok = false
      reasons[#reasons + 1] = { kind = 'accel', index = i, value = acc, limit = accLimit }
    end
  end

  for i = 4, n do
    local b = Boundaries.at(boundary, i)
    local curvatureAbs = math.abs(curvatureAt(curvatures, i))
    local jerkLimit = Config.dynamicOffsetJerkLimit(spacing, curvatureAbs, math.min(b.usableLeft, b.usableRight), confidence)
    local jerk = math.abs((offsets[i] or 0) - 3 * (offsets[i - 1] or 0) + 3 * (offsets[i - 2] or 0) - (offsets[i - 3] or 0))
    if jerk > jerkLimit then
      ok = false
      reasons[#reasons + 1] = { kind = 'jerk', index = i, value = jerk, limit = jerkLimit }
    end
  end

  return { ok = ok, reasons = reasons, reasonCount = #reasons }
end

local function boundPass(offsets, boundary)
  local out = {}
  for i = 1, #offsets do
    out[i] = Boundaries.clampOffset(boundary, i, offsets[i] or 0)
  end
  return out
end

local function stepPass(offsets, frame, boundary, opts, relax)
  local n = #offsets
  local out = {}
  local spacing = frame and frame.spacing or Config.TARGET_SAMPLE_SPACING_M
  local speedMps = opts.speedMps or 0
  local confidence = opts.confidence or (boundary and boundary.confidence) or 0.55
  out[1] = offsets[1] or 0

  for i = 2, n do
    local b = Boundaries.at(boundary, i)
    local limit = Config.dynamicOffsetStepLimit(spacing, speedMps, math.min(b.usableLeft, b.usableRight), confidence) * relax
    local delta = (offsets[i] or 0) - out[i - 1]
    out[i] = out[i - 1] + U.clamp(delta, -limit, limit)
    out[i] = Boundaries.clampOffset(boundary, i, out[i])
  end

  -- Backward pass prevents all limiting error from accumulating forward.
  for i = n - 1, 1, -1 do
    local b = Boundaries.at(boundary, i)
    local limit = Config.dynamicOffsetStepLimit(spacing, speedMps, math.min(b.usableLeft, b.usableRight), confidence) * relax
    local delta = out[i] - out[i + 1]
    out[i] = out[i + 1] + U.clamp(delta, -limit, limit)
    out[i] = Boundaries.clampOffset(boundary, i, out[i])
  end
  return out
end

local function smoothingPass(offsets, boundary, amount)
  local n = #offsets
  local out = {}
  for i = 1, n do
    local prev = offsets[i - 1] or offsets[n]
    local curr = offsets[i] or 0
    local next = offsets[i + 1] or offsets[1]
    local smoothed = curr * (1.0 - amount) + ((prev + next) * 0.5) * amount
    out[i] = Boundaries.clampOffset(boundary, i, smoothed)
  end
  return out
end

function M.repair(offsets, frame, boundary, opts)
  opts = opts or {}
  local current = boundPass(offsets, boundary)
  local report = M.validate(current, frame, boundary, opts)
  if report.ok then
    report.repaired = false
    report.passes = 0
    return current, report
  end

  local relax = 1.0
  local amplitude = 1.0
  local best = current
  local bestReport = report

  for pass = 1, Config.VALIDATION_MAX_REPAIR_PASSES do
    relax = 1.0 + Config.VALIDATION_RELAX_PER_PASS * pass
    amplitude = amplitude * Config.VALIDATION_AMPLITUDE_DECAY

    local candidate = {}
    for i = 1, #current do candidate[i] = (current[i] or 0) * amplitude end
    candidate = smoothingPass(candidate, boundary, 0.18)
    candidate = stepPass(candidate, frame, boundary, opts, relax)
    candidate = smoothingPass(candidate, boundary, 0.12)
    candidate = boundPass(candidate, boundary)

    local r = M.validate(candidate, frame, boundary, opts)
    best, bestReport = candidate, r
    if r.ok then
      r.repaired = true
      r.passes = pass
      return candidate, r
    end
  end

  -- Last resort: keep the least-bad repaired candidate. Do not immediately throw away
  -- the racing line and fall back to centerline unless the caller explicitly opts in.
  if Config.CENTERLINE_FALLBACK_AFTER_REPAIR and opts.allowCenterlineFallback then
    local center = {}
    for i = 1, #offsets do center[i] = 0 end
    local r = M.validate(center, frame, boundary, opts)
    r.repaired = true
    r.centerlineFallback = true
    return center, r
  end

  bestReport.repaired = true
  bestReport.passes = Config.VALIDATION_MAX_REPAIR_PASSES
  bestReport.centerlineFallback = false
  bestReport.warning = 'kept_best_repaired_line_instead_of_centerline'
  return best, bestReport
end

return M
