-- DynamicRacingLine line_core/path_evaluator.lua
-- Joint path + brake/lap-time local evaluator so minimum-curvature and lap-time passes do not fight.
-- Includes validator cost so smoothing/validation cannot reject optimizer output later.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local Boundaries = require('src.line_core.boundaries')
local SurfaceHazards = require('src.line_core.surface_hazards')

local M = { objective = 'joint_curvature_validator_boundary_surface_ai' }

local function wi(i, n) while i < 1 do i = i + n end; while i > n do i = i - n end; return i end

local function validatorCost(offsets, boundary, i, opts)
  local n = #offsets
  local b = Boundaries.at(boundary, i)
  local dd = (offsets[wi(i + 1, n)] or 0) - 2 * (offsets[i] or 0) + (offsets[wi(i - 1, n)] or 0)
  local jerk = (offsets[wi(i + 2, n)] or 0) - 3 * (offsets[wi(i + 1, n)] or 0) + 3 * (offsets[i] or 0) - (offsets[wi(i - 1, n)] or 0)
  local spacing = opts and opts.frame and opts.frame.spacing or Config.TARGET_SAMPLE_SPACING_M
  local curvatureAbs = math.abs(opts and opts.curvatures and opts.curvatures[i] or 0)
  local halfWidth = math.min(b.usableLeft or Config.DEFAULT_TRACK_HALF_WIDTH_M, b.usableRight or Config.DEFAULT_TRACK_HALF_WIDTH_M)
  local confidence = opts and opts.confidence or b.confidence or 0.55
  local accelLimit = Config.dynamicOffsetAccelLimit(spacing, curvatureAbs, halfWidth, confidence)
  local jerkLimit = Config.dynamicOffsetJerkLimit(spacing, curvatureAbs, halfWidth, confidence)
  return math.max(0, math.abs(dd) - accelLimit) * 4.0 + math.max(0, math.abs(jerk) - jerkLimit) * 3.0
end

local function surfaceRisk(offsets, boundary, i, opts)
  local baseRisk = Boundaries.riskForOffset(boundary, i, offsets[i] or 0)
  local hazardRisk = SurfaceHazards.riskForOffset(boundary, opts and opts.surfaceMap, i, offsets[i] or 0)
  return math.max(baseRisk, hazardRisk)
end

local function brakeCost(offsets, i, opts)
  local curvatures = opts and opts.curvatures or {}
  local car = opts and opts.car or {}
  local k = math.abs(curvatures[i] or 0)
  local offsetChange = math.abs((offsets[wi(i + 1, #offsets)] or 0) - (offsets[wi(i - 1, #offsets)] or 0))
  local brakeDecel = math.max(4.0, tonumber(car.brakeDecelMps2 or car.brakeDecel or Config.DEFAULT_BRAKE_DECEL_MPS2) or Config.DEFAULT_BRAKE_DECEL_MPS2)
  return k * offsetChange * (10.5 / brakeDecel)
end

local function speedReward(offsets, boundary, i, opts)
  local curvatures = opts and opts.curvatures or {}
  local k = math.abs(curvatures[i] or 0)
  local usable = Boundaries.maxUsableAbs(boundary, i)
  local offsetRatio = math.abs(offsets[i] or 0) / math.max(0.1, usable)
  return -U.clamp(offsetRatio * k * 7.5, 0, 0.14)
end

local function lapTimeCost(offsets, boundary, i, opts)
  local b = Boundaries.at(boundary, i)
  local risk = surfaceRisk(offsets, boundary, i, opts)
  local n = #offsets
  local dd = (offsets[wi(i + 1, n)] or 0) - 2 * (offsets[i] or 0) + (offsets[wi(i - 1, n)] or 0)
  local jerk = (offsets[wi(i + 2, n)] or 0) - 3 * (offsets[wi(i + 1, n)] or 0) + 3 * (offsets[i] or 0) - (offsets[wi(i - 1, n)] or 0)
  return math.abs(dd) * 0.35 +
    math.abs(jerk) * 0.18 +
    risk * (b.narrow and 7.2 or 4.4) +
    brakeCost(offsets, i, opts) +
    validatorCost(offsets, boundary, i, opts) +
    speedReward(offsets, boundary, i, opts)
end

local function localCost(offsets, boundary, i, opts)
  return lapTimeCost(offsets, boundary, i, opts)
end

function M.score(frame, boundary, offsets, opts)
  local total = 0
  opts = opts or {}
  opts.frame = frame
  for i = 1, #(offsets or {}) do total = total + localCost(offsets, boundary, i, opts) end
  return total, { total = total, reason = 'joint_path_score' }
end

function M.refine(frame, boundary, offsets, opts)
  opts = opts or {}
  local n = #(offsets or {})
  if n < 8 then return offsets, { changed = 0, reason = 'too_few_offsets' } end
  local changed = 0
  local band = opts.candidateBandM or Config.JOINT_PATH_CANDIDATE_BAND_M or 0.55
  local step = opts.candidateStepM or Config.JOINT_PATH_CANDIDATE_STEP_M or 0.22
  opts.frame = frame
  for i = 1, n do
    local base = offsets[i] or 0
    local best, bestCost = base, localCost(offsets, boundary, i, opts)
    for d = -band, band + 1e-6, step do
      local old = offsets[i]
      offsets[i] = Boundaries.clampOffset(boundary, i, base + d)
      local c = localCost(offsets, boundary, i, opts)
      if c < bestCost then bestCost = c; best = offsets[i] end
      offsets[i] = old
    end
    if math.abs(best - base) > 0.015 then offsets[i] = best; changed = changed + 1 end
  end
  local score = M.score(frame, boundary, offsets, opts)
  return offsets, { changed = changed, score = score, reason = 'joint_path_laptime_refine' }
end

return M
