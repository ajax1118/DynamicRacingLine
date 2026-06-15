local settings = require('src/settings')
local brake_physics_solver = require('src/brake_physics_solver')

local M = {}
local cornerCache = {}
local cornerCacheOrder = {}

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

local function sampleDistance(sample, index)
  return finiteNumber(sample and sample.distanceAheadM, finiteNumber(sample and sample.s, index or 0))
end

local function curvature(sample)
  return math.abs(finiteNumber(sample and sample.brakingCurvature,
    finiteNumber(sample and sample.curvature, 0.0)))
end

local function signedCurvature(sample)
  return finiteNumber(sample and sample.lineSignedCurvature,
    finiteNumber(sample and sample.signedCurvature, 0.0))
end

local function roundedNumber(value, scale)
  scale = math.max(1.0, finiteNumber(scale, 1.0))
  return math.floor(finiteNumber(value, 0.0) * scale + 0.5) / scale
end

local function cacheKey(samples, context, options)
  context = context or {}
  options = options or {}
  local count = #(samples or {})
  local first = samples and samples[1] or {}
  local last = samples and samples[count] or {}
  return table.concat({
    tostring(count),
    tostring(roundedNumber(sampleDistance(first, 1), 2.0)),
    tostring(roundedNumber(sampleDistance(last, count), 2.0)),
    tostring(roundedNumber(context.currentSpeedKph, 0.10)),
    tostring(roundedNumber(context.brakeG, 10.0)),
    tostring(roundedNumber(context.corneringG, 10.0)),
    tostring(roundedNumber(context.roadGrip, 20.0)),
    tostring(roundedNumber(context.surfaceGrip, 20.0)),
    tostring(roundedNumber(context.pressurePenalty, 20.0)),
    tostring(roundedNumber(context.fuelMassRatio, 10.0)),
    tostring(roundedNumber(context.brakePowerMult, 10.0)),
    tostring(roundedNumber(options.threshold or settings.PREDICTIVE_CORNER_CURVATURE_THRESHOLD, 10000.0)),
  }, ':')
end

local function rememberCornerCache(key, corners)
  if not key or key == '' then return end
  cornerCache[key] = {
    corners = corners,
    savedAt = os and os.clock and os.clock() or 0,
  }
  cornerCacheOrder[#cornerCacheOrder + 1] = key
  local maxEntries = math.max(2, math.floor(finiteNumber(settings.PREDICTIVE_BASELINE_CACHE_MAX, 12) + 0.5))
  while #cornerCacheOrder > maxEntries do
    local evicted = table.remove(cornerCacheOrder, 1)
    cornerCache[evicted] = nil
  end
end

local function cachedCornerMap(samples, context, options)
  options = options or {}
  local key = cacheKey(samples, context, options)
  if options.forceRebuild ~= true then
    local cached = cornerCache[key]
    if cached and type(cached.corners) == 'table' then
      return cached.corners, key, true
    end
  end
  local corners = M.buildCornerMap(samples, context)
  rememberCornerCache(key, corners)
  return corners, key, false
end

local function cornerSpeedFromCurvature(k, context)
  local minSpeed = finiteNumber(context and context.minCornerSpeedKph, settings.MIN_CORNER_SPEED_KPH)
  local maxSpeed = finiteNumber(context and context.maxTargetSpeedKph, settings.MAX_TARGET_SPEED_KPH)
  if k <= 0.00001 then return maxSpeed end
  local gripG = math.max(0.35, finiteNumber(context and context.corneringG, settings.DEFAULT_CORNERING_G))
  local radius = 1.0 / math.max(0.00001, k)
  local speedMps = math.sqrt(math.max(0.0, gripG * 9.80665 * radius))
  return clamp(speedMps * 3.6, minSpeed, maxSpeed)
end

local function brakeDistanceM(speedKph, targetKph, context, confidence)
  return brake_physics_solver.brakeDistance(speedKph, targetKph, context, confidence)
end

local function allowedSpeedKph(targetKph, distanceToApexM, context, confidence)
  local reserve = math.max(0.0, finiteNumber(settings.BRAKE_TARGET_PROFILE_DECEL_RESERVE_M, 18.0))
  local distance = math.max(0.0, finiteNumber(distanceToApexM, 0.0) - reserve)
  return brake_physics_solver.allowedSpeed(targetKph, distance, context, confidence)
end

local function classifySegment(k, direction, d, corner)
  if not corner then return k < 0.00065 and 'straight' or 'flowing_corner' end
  if d < corner.turnInDistanceM then return 'braking_zone' end
  if d < corner.apexDistanceM then return 'turn_in' end
  if d < corner.exitDistanceM then return 'apex_exit' end
  if k > 0.0030 then return 'low_speed_corner' end
  if k > 0.0014 then return 'medium_speed_corner' end
  if direction ~= 0 then return 'high_speed_corner' end
  return 'straight'
end

function M.buildCornerMap(samples, context)
  local threshold = math.max(0.00025, finiteNumber(settings.PREDICTIVE_CORNER_CURVATURE_THRESHOLD, 0.0010))
  local minLengthM = math.max(5.0, finiteNumber(settings.PREDICTIVE_CORNER_MIN_LENGTH_M, 10.0))
  local corners = {}
  local active = nil
  for index, sample in ipairs(samples or {}) do
    local k = curvature(sample)
    local d = sampleDistance(sample, index)
    if k >= threshold then
      if not active then
        active = { firstIndex = index, lastIndex = index, entryDistanceM = d, exitDistanceM = d, maxCurvature = k, apexIndex = index }
      end
      active.lastIndex = index
      active.exitDistanceM = d
      if k > active.maxCurvature then
        active.maxCurvature = k
        active.apexIndex = index
      end
    elseif active then
      if math.abs(active.exitDistanceM - active.entryDistanceM) >= minLengthM then corners[#corners + 1] = active end
      active = nil
    end
  end
  if active and math.abs(active.exitDistanceM - active.entryDistanceM) >= minLengthM then corners[#corners + 1] = active end

  local confidence = clamp(finiteNumber(context and context.confidence, 0.60), 0.0, 1.0)
  local approachM = math.max(20.0, finiteNumber(settings.PREDICTIVE_CORNER_APPROACH_M, 85.0))
  local exitPadM = math.max(12.0, finiteNumber(settings.PREDICTIVE_CORNER_EXIT_M, 45.0))
  for index, corner in ipairs(corners) do
    local apexSample = samples[corner.apexIndex] or samples[corner.firstIndex] or {}
    local apexDistance = sampleDistance(apexSample, corner.apexIndex)
    local target = math.min(
      finiteNumber(apexSample.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH),
      cornerSpeedFromCurvature(corner.maxCurvature, context))
    local currentSpeed = math.max(target, finiteNumber(context and context.currentSpeedKph, target))
    local brakeDistance, brakeDetail = brakeDistanceM(currentSpeed, target, context, confidence)
    local brakeStart = apexDistance - brakeDistance
    corner.id = string.format('c%03d', index)
    corner.apexDistanceM = apexDistance
    corner.turnInDistanceM = math.max(corner.entryDistanceM, apexDistance - math.max(8.0, brakeDistance * 0.28))
    corner.brakeStartDistanceM = brakeStart
    corner.brakeReleaseDistanceM = math.max(corner.turnInDistanceM, apexDistance - math.max(4.0, brakeDistance * 0.12))
    corner.exitDistanceM = corner.exitDistanceM + exitPadM
    corner.approachStartDistanceM = brakeStart - approachM
    corner.targetSpeedKph = target
    corner.direction = signedCurvature(apexSample) >= 0 and 1 or -1
    corner.confidence = confidence
    corner.brakeCapacityMps2 = finiteNumber(brakeDetail and brakeDetail.capacityMps2, 0.0)
    corner.brakeSolverSource = tostring(brakeDetail and brakeDetail.source or 'physics_solver')
  end
  return corners
end

function M.apply(samples, context, session, options)
  samples = samples or {}
  context = context or {}
  options = options or {}
  if settings.PREDICTIVE_BASELINE_ENABLED == false then return { corner_count = 0, confidence = 0.0 } end
  local corners, usedCacheKey, usedCache = cachedCornerMap(samples, context, options)
  local confidence = clamp(finiteNumber(context.confidence, 0.60), 0.0, 1.0)
  local currentSpeed = finiteNumber(context.currentSpeedKph, 0.0)
  for index, sample in ipairs(samples) do
    local d = sampleDistance(sample, index)
    local k = curvature(sample)
    local bestCorner = nil
    for _, corner in ipairs(corners) do
      if d >= corner.approachStartDistanceM and d <= corner.exitDistanceM then
        bestCorner = corner
        break
      end
    end

    sample.predictiveConfidence = confidence
    sample.predictiveSource = 'generated_predictive_baseline'
    sample.predictiveCacheKey = usedCacheKey
    sample.predictiveCacheHit = usedCache == true
    sample.guidanceModelVersion = 'physics-first-20260611'
    if bestCorner then
      local target = finiteNumber(bestCorner.targetSpeedKph, finiteNumber(sample.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH))
      local distanceToApex = math.max(0.0, bestCorner.apexDistanceM - d)
      local allowed = allowedSpeedKph(target, distanceToApex, context, confidence)
      local existingTarget = finiteNumber(sample.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH)
      if currentSpeed > target + 4.0 and d >= bestCorner.brakeStartDistanceM and d <= bestCorner.apexDistanceM then
        sample.targetSpeedKph = math.min(existingTarget, allowed)
        sample.brakeProfileTargetSpeedKph = math.min(finiteNumber(sample.brakeProfileTargetSpeedKph, sample.targetSpeedKph), sample.targetSpeedKph)
        sample.straightSpeedCap = false
      end
      local brakeWindow = math.max(1.0, bestCorner.apexDistanceM - bestCorner.brakeStartDistanceM)
      local brakeProgress = clamp((d - bestCorner.brakeStartDistanceM) / brakeWindow, 0.0, 1.0)
      sample.cornerId = bestCorner.id
      sample.segmentType = classifySegment(k, bestCorner.direction, d, bestCorner)
      sample.predictiveBrakeStartDistanceM = bestCorner.brakeStartDistanceM
      sample.predictiveBrakeReleaseDistanceM = bestCorner.brakeReleaseDistanceM
      sample.predictiveTurnInDistanceM = bestCorner.turnInDistanceM
      sample.predictiveApexDistanceM = bestCorner.apexDistanceM
      sample.predictiveExitDistanceM = bestCorner.exitDistanceM
      sample.predictiveApexSpeedKph = target
      sample.predictiveBrakeCapacityMps2 = bestCorner.brakeCapacityMps2
      sample.predictiveSolverSource = bestCorner.brakeSolverSource
      sample.predictiveBrakeIntensity = d >= bestCorner.brakeStartDistanceM and d <= bestCorner.apexDistanceM and brakeProgress or 0.0
      sample.predictiveTrackOutHint = bestCorner.direction > 0 and 'track_out_left' or 'track_out_right'
    else
      sample.cornerId = sample.cornerId or 'straight'
      sample.segmentType = classifySegment(k, 0, d, nil)
      sample.predictiveBrakeStartDistanceM = sample.predictiveBrakeStartDistanceM or 0.0
      sample.predictiveBrakeReleaseDistanceM = sample.predictiveBrakeReleaseDistanceM or 0.0
      sample.predictiveTurnInDistanceM = sample.predictiveTurnInDistanceM or 0.0
      sample.predictiveApexDistanceM = sample.predictiveApexDistanceM or 0.0
      sample.predictiveExitDistanceM = sample.predictiveExitDistanceM or 0.0
      sample.predictiveBrakeIntensity = 0.0
      sample.predictiveBrakeCapacityMps2 = 0.0
      sample.predictiveSolverSource = 'physics_solver'
    end
  end
  return { corner_count = #corners, confidence = confidence, corners = corners, cacheKey = usedCacheKey, cacheHit = usedCache == true }
end

return M
