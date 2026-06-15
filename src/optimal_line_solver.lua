local settings = require('src/settings')
local lap_time_optimizer = require('src/lap_time_optimizer')
local math3d = require('src/math3d')

local M = {}

local finiteNumber = math3d.safeNumber
local clamp = math3d.clamp

local function wrapIndex(values, index)
  local count = #(values or {})
  if count <= 0 then return nil end
  return ((index - 1) % count) + 1
end

local function copyOffsets(offsets)
  local copied = {}
  for index, value in ipairs(offsets or {}) do
    copied[index] = finiteNumber(value, 0.0)
  end
  return copied
end

local function targetSpeedKph(sample)
  return finiteNumber(sample and (sample.brakeProfileTargetSpeedKph or sample.targetSpeedKph),
    finiteNumber(sample and sample.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH))
end

local function speedWeighted(sample, fastestTargetKph)
  local fastest = math.max(60.0, finiteNumber(fastestTargetKph, settings.MAX_TARGET_SPEED_KPH))
  local target = clamp(targetSpeedKph(sample), 20.0, fastest)
  local slowCornerWeight = 1.0 - target / fastest
  local curvatureWeight = clamp(math.abs(finiteNumber(sample and (sample.lineSignedCurvature or sample.signedCurvature),
    finiteNumber(sample and sample.curvature, 0.0))) / 0.008, 0.0, 1.0)
  return clamp(slowCornerWeight * 0.65 + curvatureWeight * 0.35, 0.0, 1.0)
end

local function lineCurvatureCost(offsets, index)
  local count = #(offsets or {})
  if count < 3 then return 0.0 end
  local previous = offsets[wrapIndex(offsets, index - 1)] or 0.0
  local current = offsets[index] or 0.0
  local nextValue = offsets[wrapIndex(offsets, index + 1)] or 0.0
  return math.abs(previous - current * 2.0 + nextValue)
end

local function maxLineCurvatureCost(offsets)
  local maxCost = 0.0
  for index = 1, #(offsets or {}) do
    maxCost = math.max(maxCost, lineCurvatureCost(offsets, index))
  end
  return maxCost
end

function M.refineOffsets(samples, offsets, options)
  if settings.OPTIMAL_LINE_SOLVER_ENABLED == false then
    return offsets, { source = 'heuristic_disabled', iterations = 0, maxCurvatureCost = maxLineCurvatureCost(offsets) }
  end

  samples = samples or {}
  local count = #(offsets or {})
  if count < 5 then
    return offsets, { source = 'minimum_curvature_too_few_samples', iterations = 0, maxCurvatureCost = maxLineCurvatureCost(offsets) }
  end

  options = options or {}
  local maxOffset = math.max(0.0, finiteNumber(options.maxOffset, settings.RACING_LINE_MAX_OFFSET_M))
  local trackLimitMarginM = math.max(0.0, finiteNumber(options.trackLimitMarginM, settings.OPTIMAL_LINE_TRACK_LIMIT_MARGIN_M))
  local limit = math.max(0.0, maxOffset - trackLimitMarginM)
  local maxIteration = math.max(1, math.floor(finiteNumber(settings.OPTIMAL_LINE_MAX_ITERATIONS, 8) + 0.5))
  local speedWeightScale = clamp(finiteNumber(settings.OPTIMAL_LINE_SPEED_WEIGHT, 0.55), 0.0, 1.0)
  local anchorWeight = clamp(finiteNumber(settings.OPTIMAL_LINE_ANCHOR_WEIGHT, 0.40), 0.0, 1.0)
  local refined = copyOffsets(offsets)
  local anchors = copyOffsets(offsets)

  local fastestTargetKph = 0.0
  for _, sample in ipairs(samples) do
    fastestTargetKph = math.max(fastestTargetKph, targetSpeedKph(sample))
  end
  fastestTargetKph = math.max(fastestTargetKph, 80.0)

  for _ = 1, maxIteration do
    local nextOffsets = {}
    for index = 1, count do
      local previous = refined[wrapIndex(refined, index - 1)] or refined[index]
      local current = refined[index] or 0.0
      local nextValue = refined[wrapIndex(refined, index + 1)] or refined[index]
      local minimum_curvature = previous * 0.28 + current * 0.44 + nextValue * 0.28
      local speedWeight = speedWeighted(samples[index], fastestTargetKph) * speedWeightScale
      local anchorAuthority = clamp(anchorWeight + speedWeight * 0.30 + math.abs(anchors[index] or 0.0) / math.max(maxOffset, 0.01) * 0.18, 0.16, 0.84)
      local solved = minimum_curvature * (1.0 - anchorAuthority) + (anchors[index] or 0.0) * anchorAuthority
      nextOffsets[index] = clamp(solved, -limit, limit)
    end
    refined = nextOffsets
  end

  local lapTimeSummary = nil
  refined, lapTimeSummary = lap_time_optimizer.refineLapTime(samples, refined, {
    spacingM = finiteNumber(options.spacingM, settings.PROFILE_SPACING_M),
    maxOffset = maxOffset,
    trackLimitMarginM = trackLimitMarginM,
    corneringG = finiteNumber(options.corneringG, settings.DEFAULT_CORNERING_G),
    speedAeroStrength = finiteNumber(options.speedAeroStrength, 0.0),
    rainWetness = finiteNumber(options.rainWetness, 0.0),
    instabilityRisk = finiteNumber(options.instabilityRisk, 0.0),
  })

  return refined, {
    source = lapTimeSummary and 'minimum_curvature+lap_time_optimizer' or 'minimum_curvature',
    iterations = maxIteration,
    trackLimitMarginM = trackLimitMarginM,
    maxCurvatureCost = maxLineCurvatureCost(refined),
    lapTimeSource = lapTimeSummary and lapTimeSummary.source or 'none',
    sectorTimeCost = lapTimeSummary and lapTimeSummary.sectorTimeCost or 0.0,
  }
end

return M
