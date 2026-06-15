local settings = require('src/settings')

local M = {}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function clamp(value, lo, hi)
  value = tonumber(value) or lo
  if value < lo then return lo end
  if value > hi then return hi end
  return value
end

local function wrapIndex(values, index)
  local count = #(values or {})
  if count <= 0 then return nil end
  return ((index - 1) % count) + 1
end

local function targetSpeedKph(sample)
  return finiteNumber(sample and (sample.brakeProfileTargetSpeedKph or sample.targetSpeedKph),
    finiteNumber(sample and sample.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH))
end

local function carGripEnvelope(sample, options)
  options = options or {}
  local speed = targetSpeedKph(sample)
  local curvature = math.abs(finiteNumber(sample and (sample.lineSignedCurvature or sample.signedCurvature),
    finiteNumber(sample and sample.curvature, 0.0)))
  local grip = clamp(finiteNumber(options.corneringG, finiteNumber(sample and sample.corneringG, settings.DEFAULT_CORNERING_G)), 0.55, 4.5)
  local load = clamp(1.0 - curvature / 0.020 * 0.16, 0.72, 1.05)
  local speedAero = clamp(1.0 + finiteNumber(options.speedAeroStrength, 0.0) * (speed / 280.0) * (speed / 280.0), 1.0, 1.35)
  return grip * load * speedAero
end

local function kerbRisk(sample, offset, options)
  options = options or {}
  local maxOffset = math.max(0.1, finiteNumber(options.maxOffset, settings.RACING_LINE_MAX_OFFSET_M))
  local normalized = math.abs(finiteNumber(offset, 0.0)) / maxOffset
  local kerbUse = clamp((normalized - 0.78) / 0.22, 0.0, 1.0)
  local wetness = math.max(finiteNumber(sample and sample.rainWetness, 0.0), finiteNumber(options.rainWetness, 0.0))
  local instability = math.max(finiteNumber(sample and sample.exitInstabilityRisk, 0.0), finiteNumber(options.instabilityRisk, 0.0))
  return kerbUse * (0.35 + wetness * 0.35 + instability * 0.30)
end

local function sectorTimeCost(sample, offset, previousOffset, nextOffset, options)
  options = options or {}
  local speed = math.max(20.0, targetSpeedKph(sample))
  local spacing = math.max(0.5, finiteNumber(options.spacingM, settings.PROFILE_SPACING_M))
  local curvature = math.abs(finiteNumber(sample and (sample.lineSignedCurvature or sample.signedCurvature),
    finiteNumber(sample and sample.curvature, 0.0)))
  local gripEnvelope = carGripEnvelope(sample, options)
  local lateralDemand = curvature * speed * speed / 1296.0
  local gripPenalty = math.max(0.0, lateralDemand / math.max(0.10, gripEnvelope) - 1.0)
  local pathBend = math.abs((previousOffset or offset) - offset) + math.abs((nextOffset or offset) - offset)
  local pathLengthPenalty = pathBend / spacing * 0.10
  local apexReward = math.abs(offset) / math.max(0.1, finiteNumber(options.maxOffset, settings.RACING_LINE_MAX_OFFSET_M)) *
    clamp(curvature / 0.010, 0.0, 1.0) * 0.045
  return spacing / (speed / 3.6) + gripPenalty * 0.18 + pathLengthPenalty + kerbRisk(sample, offset, options) * 0.08 - apexReward
end

local function candidateOffsets(anchor, limit, step)
  anchor = finiteNumber(anchor, 0.0)
  limit = math.max(0.0, finiteNumber(limit, settings.RACING_LINE_MAX_OFFSET_M))
  step = math.max(0.05, finiteNumber(step, 0.35))
  return {
    clamp(anchor - step, -limit, limit),
    clamp(anchor - step * 0.5, -limit, limit),
    clamp(anchor, -limit, limit),
    clamp(anchor + step * 0.5, -limit, limit),
    clamp(anchor + step, -limit, limit),
  }
end

function M.scoreOffset(samples, offsets, index, candidate, options)
  local count = #(offsets or {})
  if count == 0 then return 0.0 end
  local previous = offsets[wrapIndex(offsets, index - 1)] or candidate
  local nextValue = offsets[wrapIndex(offsets, index + 1)] or candidate
  return sectorTimeCost(samples and samples[index] or {}, candidate, previous, nextValue, options)
end

function M.refineLapTime(samples, offsets, options)
  samples = samples or {}
  offsets = offsets or {}
  options = options or {}
  local count = #offsets
  if count < 5 then return offsets, { source = 'lap_time_too_few_samples', iterations = 0 } end

  local trackLimitMarginM = math.max(0.0, finiteNumber(options.trackLimitMarginM, settings.OPTIMAL_LINE_TRACK_LIMIT_MARGIN_M))
  local maxOffset = math.max(0.0, finiteNumber(options.maxOffset, settings.RACING_LINE_MAX_OFFSET_M))
  local limit = math.max(0.0, maxOffset - trackLimitMarginM)
  local iterations = math.max(1, math.floor(finiteNumber(settings.LAP_TIME_OPTIMIZER_ITERATIONS, 3) + 0.5))
  local step = math.max(0.04, finiteNumber(settings.LAP_TIME_OPTIMIZER_STEP_M, 0.34))
  local refined = {}
  for index, value in ipairs(offsets) do refined[index] = clamp(value, -limit, limit) end

  for _ = 1, iterations do
    local nextOffsets = {}
    for index = 1, count do
      local best = refined[index]
      local bestScore = M.scoreOffset(samples, refined, index, best, options)
      for _, candidate in ipairs(candidateOffsets(best, limit, step)) do
        local score = M.scoreOffset(samples, refined, index, candidate, options)
        if score < bestScore then
          best = candidate
          bestScore = score
        end
      end
      nextOffsets[index] = best
    end
    refined = nextOffsets
    step = step * 0.58
  end

  local totalCost = 0.0
  for index = 1, count do
    totalCost = totalCost + M.scoreOffset(samples, refined, index, refined[index], options)
  end
  return refined, {
    source = 'lap_time_optimizer',
    iterations = iterations,
    trackLimitMarginM = trackLimitMarginM,
    sectorTimeCost = totalCost,
  }
end

return M
