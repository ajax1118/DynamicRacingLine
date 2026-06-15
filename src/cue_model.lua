local settings = require('src/settings')
local M = {
  redFrames = {},
  cueStates = {},
  seenThisFrame = {},
  frameDt = 1 / 60,
  futureBrakeTargetsCache = nil,
  brakeTimingProfileCache = {},
}

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

local function positiveBrakeCapacityMps2(value, fallback)
  local defaultCapacity = math.max(0.1, finiteNumber(settings.DEFAULT_BRAKE_G, 1.05) * 9.80665)
  local fallbackCapacity = finiteNumber(fallback, defaultCapacity)
  if fallbackCapacity <= 0.1 then fallbackCapacity = defaultCapacity end
  local capacity = finiteNumber(value, fallbackCapacity)
  if capacity <= 0.1 then capacity = fallbackCapacity end
  return math.max(0.1, capacity)
end

local advisoryCauses = {
  corner_flow_advisory = true,
  recovery_advisory = true,
  instability_advisory = true,
  knowledge_base_advisory = true,
}

local function isAdvisoryCause(cueCause)
  return advisoryCauses[tostring(cueCause or '')] == true
end

local function yellowReasonFor(cueCause, fallback)
  cueCause = tostring(cueCause or '')
  if cueCause == 'brake_zone_warning' then return cueCause end
  if isAdvisoryCause(cueCause) then return cueCause end
  return fallback
end

local function cueTargetSpeedKph(tile)
  return finiteNumber(tile and tile.targetSpeedKph,
    finiteNumber(tile and tile.baseTargetSpeedKph, settings.MAX_TARGET_SPEED_KPH))
end

local function cueStraightSpeedCap(tile)
  return tile and tile.straightSpeedCap == true
end

local function requiredDecelRatio(speedKph, targetKph, distanceM, brakeCapacityMps2)
  local current = math.max(0, finiteNumber(speedKph, 0) / 3.6)
  local target = math.max(0, finiteNumber(targetKph, 0) / 3.6)
  local distance = math.max(1.0, finiteNumber(distanceM, 1))
  local required = math.max(0, (current * current - target * target) / (2.0 * distance))
  local capacity = positiveBrakeCapacityMps2(brakeCapacityMps2, settings.DEFAULT_BRAKE_G * 9.80665)
  return required / capacity, required, capacity
end

local function requiredBrakeDistanceM(speedKph, targetKph, brakeCapacityMps2)
  local current = math.max(0, finiteNumber(speedKph, 0) / 3.6)
  local target = math.max(0, finiteNumber(targetKph, 0) / 3.6)
  local capacity = positiveBrakeCapacityMps2(brakeCapacityMps2, settings.DEFAULT_BRAKE_G * 9.80665)
  return math.max(0.0, (current * current - target * target) / (2.0 * capacity))
end

local function highCapabilityTimingScale(speedKph, brakeCapacityMps2)
  local brakeG = math.max(0.0, positiveBrakeCapacityMps2(brakeCapacityMps2, settings.DEFAULT_BRAKE_G * 9.80665) / 9.80665)
  local highBrakeG = math.max(1.46, finiteNumber(settings.HIGH_CAPABILITY_BRAKE_G, 2.35))
  local brakeScale = clamp((brakeG - 1.45) / math.max(0.01, highBrakeG - 1.45), 0.0, 1.0)
  local highSpeed = math.max(181.0, finiteNumber(settings.HIGH_CAPABILITY_SPEED_KPH, 300.0))
  local speedScale = clamp((finiteNumber(speedKph, 0.0) - 180.0) / math.max(1.0, highSpeed - 180.0), 0.0, 1.0)
  return brakeScale * speedScale
end

local function confidenceUncertaintyScale(confidence)
  local fullTrust = clamp(settings.BRAKE_CONFIDENCE_FULL_TRUST, 0.01, 1.0)
  local minTrust = clamp(settings.BRAKE_CONFIDENCE_MIN_TRUST, 0.0, fullTrust - 0.01)
  return clamp((fullTrust - finiteNumber(confidence, 0.70)) / math.max(0.01, fullTrust - minTrust), 0.0, 1.0)
end

local function brakeTimingProfile(speedKph, brakeCapacityMps2, transferClassScale, confidence)
  local scale = highCapabilityTimingScale(speedKph, brakeCapacityMps2)
  local classScale = clamp(finiteNumber(transferClassScale, 0.0), 0.0, 1.0)
  local roadScale = 1.0 - classScale
  local uncertainty = confidenceUncertaintyScale(confidence)
  local confidenceSafety = finiteNumber(settings.BRAKE_CONFIDENCE_UNCERTAINTY_SAFETY, 0.08) * uncertainty
  local confidenceReaction = finiteNumber(settings.BRAKE_CONFIDENCE_UNCERTAINTY_REACTION_S, 0.10) * uncertainty
  local brakeConfidenceMarginM = finiteNumber(settings.BRAKE_CONFIDENCE_UNCERTAINTY_MARGIN_M, 8.0) * uncertainty
  local confidenceWarningM = finiteNumber(settings.BRAKE_CONFIDENCE_UNCERTAINTY_WARNING_M, 10.0) * uncertainty
  return {
    safety = math.max(1.0, finiteNumber(settings.BRAKE_SAFETY_MULT, 1.18) -
      finiteNumber(settings.BRAKE_HIGH_CAP_SAFETY_REDUCTION, 0.12) * scale + confidenceSafety),
    reaction = math.max(0.10, finiteNumber(settings.BRAKE_REACTION_TIME_S, 0.45) -
      finiteNumber(settings.BRAKE_HIGH_CAP_REACTION_REDUCTION_S, 0.17) * scale +
      finiteNumber(settings.BRAKE_CLASS_ROAD_REACTION_BONUS_S, 0.06) * roadScale + confidenceReaction),
    margin = math.max(2.0, finiteNumber(settings.BRAKE_DISTANCE_MARGIN_M, 10.0) -
      finiteNumber(settings.BRAKE_HIGH_CAP_MARGIN_REDUCTION_M, 5.0) * scale +
      finiteNumber(settings.BRAKE_CLASS_ROAD_MARGIN_BONUS_M, 3.0) * roadScale -
      finiteNumber(settings.BRAKE_CLASS_OPEN_MARGIN_REDUCTION_M, 1.5) * classScale +
      brakeConfidenceMarginM),
    entryLead = math.max(0.0, finiteNumber(settings.BRAKE_CORNER_ENTRY_LEAD_M, 18.0) -
      finiteNumber(settings.BRAKE_HIGH_CAP_ENTRY_LEAD_REDUCTION_M, 6.0) * scale),
    warningTime = math.max(0.10, finiteNumber(settings.BRAKE_ZONE_WARNING_TIME_S, 0.38) -
      finiteNumber(settings.BRAKE_HIGH_CAP_WARNING_TIME_REDUCTION_S, 0.085) * scale),
    warningMin = math.max(0.0, finiteNumber(settings.BRAKE_ZONE_WARNING_MIN_M, 14.0)),
    warningMax = math.max(6.0, finiteNumber(settings.BRAKE_ZONE_WARNING_MAX_M, 45.0) -
      finiteNumber(settings.BRAKE_HIGH_CAP_WARNING_MAX_REDUCTION_M, 11.0) * scale -
      finiteNumber(settings.BRAKE_CLASS_OPEN_WARNING_REDUCTION_M, 4.0) * classScale +
      confidenceWarningM),
    transferClassScale = classScale,
    dynamicConfidence = clamp(finiteNumber(confidence, 0.70), 0.0, 1.0),
    confidenceUncertaintyScale = uncertainty,
    brakeConfidenceMarginM = brakeConfidenceMarginM,
  }
end

local function brakeTimingProfileCacheKey(speedKph, brakeCapacityMps2, transferClassScale, confidence)
  return tostring(math.floor(finiteNumber(speedKph, 0.0) * 10.0 + 0.5)) .. ':' ..
    tostring(math.floor(finiteNumber(brakeCapacityMps2, 0.0) * 100.0 + 0.5)) .. ':' ..
    tostring(math.floor(finiteNumber(transferClassScale, 0.0) * 1000.0 + 0.5)) .. ':' ..
    tostring(math.floor(finiteNumber(confidence, 0.70) * 1000.0 + 0.5))
end

local function cachedBrakeTimingProfile(speedKph, brakeCapacityMps2, transferClassScale, confidence)
  local cache = M.brakeTimingProfileCache or {}
  M.brakeTimingProfileCache = cache
  local key = brakeTimingProfileCacheKey(speedKph, brakeCapacityMps2, transferClassScale, confidence)
  local timing = cache[key]
  if timing then return timing end
  timing = brakeTimingProfile(speedKph, brakeCapacityMps2, transferClassScale, confidence)
  cache[key] = timing
  return timing
end

local function brakeWarningDistance(speed, timing)
  local speedMps = math.max(0, finiteNumber(speed, 0) / 3.6)
  timing = timing or brakeTimingProfile(speed, settings.DEFAULT_BRAKE_G * 9.80665, 0.0)
  local time = math.max(0.05, finiteNumber(timing.warningTime, settings.BRAKE_ZONE_WARNING_TIME_S))
  local minM = math.max(0.0, finiteNumber(timing.warningMin, settings.BRAKE_ZONE_WARNING_MIN_M))
  local maxM = math.max(minM, finiteNumber(timing.warningMax, settings.BRAKE_ZONE_WARNING_MAX_M))
  return clamp(speedMps * time, minM, maxM)
end

local function brakeCueProgression(progress, transferClassScale)
  local classScale = clamp(finiteNumber(transferClassScale, 0.0), 0.0, 1.0)
  local exponent = finiteNumber(settings.BRAKE_CUE_PROGRESS_ROAD_EXPONENT, 1.12) * (1.0 - classScale) +
    finiteNumber(settings.BRAKE_CUE_PROGRESS_OPEN_EXPONENT, 0.92) * classScale
  return clamp(progress, 0.0, 1.0) ^ math.max(0.25, exponent)
end

local function brakeClusterEntryLeadFraction(speedKph, transferClassScale)
  local speedScale = clamp((finiteNumber(speedKph, 0.0) - 150.0) / 100.0, 0.0, 1.0)
  local classScale = clamp(finiteNumber(transferClassScale, 0.0), 0.0, 1.0)
  local roadBonusScale = clamp(
    (finiteNumber(settings.BRAKE_CLUSTER_ENTRY_LEAD_ROAD_BONUS_END_KPH, 150.0) - finiteNumber(speedKph, 0.0)) /
    math.max(1.0, finiteNumber(settings.BRAKE_CLUSTER_ENTRY_LEAD_ROAD_BONUS_FADE_KPH, 35.0)),
    0.0,
    1.0)
  local base = finiteNumber(settings.BRAKE_CLUSTER_ENTRY_LEAD_MIN_FRACTION, 0.20) +
    finiteNumber(settings.BRAKE_CLUSTER_ENTRY_LEAD_ROAD_BONUS_FRACTION, 0.35) * roadBonusScale * (1.0 - classScale)
  return clamp(base + finiteNumber(settings.BRAKE_CLUSTER_ENTRY_LEAD_SPEED_BONUS, 0.55) * speedScale, 0.0, 1.0)
end

local function speedDropBrakeLeadM(speedKph, targetKph, transferClassScale)
  local extraLeadMaxM = math.max(0.0, finiteNumber(settings.BRAKE_SPEED_DROP_EXTRA_LEAD_M, 0.0))
  if extraLeadMaxM <= 0.0 then return 0.0 end
  local speedDropKph = math.max(0.0, finiteNumber(speedKph, 0.0) - finiteNumber(targetKph, 0.0))
  local dropStart = math.max(0.0, finiteNumber(settings.BRAKE_SPEED_DROP_LEAD_START_KPH, 18.0))
  local dropFull = math.max(dropStart + 1.0, finiteNumber(settings.BRAKE_SPEED_DROP_LEAD_FULL_KPH, 165.0))
  local speedStart = math.max(0.0, finiteNumber(settings.BRAKE_SPEED_DROP_LEAD_SPEED_START_KPH, 115.0))
  local speedFull = math.max(speedStart + 1.0, finiteNumber(settings.BRAKE_SPEED_DROP_LEAD_SPEED_FULL_KPH, 285.0))
  local dropScale = clamp((speedDropKph - dropStart) / math.max(1.0, dropFull - dropStart), 0.0, 1.0)
  local speedScale = clamp((finiteNumber(speedKph, 0.0) - speedStart) / math.max(1.0, speedFull - speedStart), 0.0, 1.0)
  local classScale = clamp(finiteNumber(transferClassScale, 0.0), 0.0, 1.0)
  local classLeadScale = 1.0 - classScale * 0.20
  return extraLeadMaxM * dropScale * speedScale * classLeadScale
end

local function adjustedBrakeDistance(distanceM, speedKph, entryLeadM)
  local speedMps = math.max(0, finiteNumber(speedKph, 0) / 3.6)
  local reaction = math.max(0, finiteNumber(settings.BRAKE_REACTION_TIME_S, 0.28))
  local margin = math.max(0, finiteNumber(settings.BRAKE_DISTANCE_MARGIN_M, 6.0))
  local entryLead = math.max(0, finiteNumber(entryLeadM, 0.0))
  local rawDistance = math.max(1.0, finiteNumber(distanceM, 1.0))
  local adjusted = rawDistance - entryLead - margin - speedMps * reaction
  local minAvailable = rawDistance * math.max(0.05, finiteNumber(settings.BRAKE_AVAILABLE_DISTANCE_MIN_FRACTION, 0.35))
  return math.max(1.0, minAvailable, adjusted)
end

local function confirmedFutureBrakeTarget(candidate, candidates, lookaheadTiles)
  local confirmationM = math.max(0.5, finiteNumber(settings.BRAKE_CLUSTER_CONFIRMATION_M, 18.0))
  local minSamples = math.max(1, math.floor(finiteNumber(settings.BRAKE_CLUSTER_MIN_SAMPLES, 2) + 0.5))
  local toleranceKph = math.max(0.0, finiteNumber(settings.BRAKE_CLUSTER_TARGET_TOLERANCE_KPH, 8.0))
  local sparseMinCurvature = math.max(0.0, finiteNumber(settings.BRAKE_SPARSE_TERMINAL_MIN_CURVATURE, 0.0010))
  local clusterConfirmedSamples = 0
  local confirmedEntryDistanceM = finiteNumber(candidate and candidate.distanceM, 0.0)
  local confirmedTargetDistanceM = finiteNumber(candidate and candidate.distanceM, 0.0)
  local confirmedTargetKph = math.huge
  local confirmedCurvature = finiteNumber(candidate and candidate.brakingCurvature,
    finiteNumber(candidate and candidate.curvature, 0.0))
  local confirmedCornerBrakeBiasM = finiteNumber(candidate and candidate.cornerBrakeBiasM, 0.0)
  local confirmedBrakeCapacityMps2 = finiteNumber(candidate and candidate.brakeCapacityMps2, 0.0)
  local confirmedBrakeSpeedAeroFactor = finiteNumber(candidate and candidate.brakeSpeedAeroFactor, 1.0)
  local laterSampleInConfirmationWindow = false

  for _, other in ipairs(lookaheadTiles or {}) do
    local otherDistanceM = finiteNumber(other and other.distanceAheadM, -1.0)
    local otherTargetKph = cueTargetSpeedKph(other)
    if other and cueStraightSpeedCap(other) ~= true and
      math.abs(otherDistanceM - candidate.distanceM) <= confirmationM and
      otherTargetKph <= candidate.targetKph + toleranceKph then
      clusterConfirmedSamples = clusterConfirmedSamples + 1
      if otherDistanceM < confirmedEntryDistanceM then
        confirmedEntryDistanceM = otherDistanceM
      end
      if otherTargetKph < confirmedTargetKph or
        (otherTargetKph == confirmedTargetKph and otherDistanceM < confirmedTargetDistanceM) then
        confirmedTargetKph = otherTargetKph
        confirmedTargetDistanceM = otherDistanceM
        confirmedCurvature = finiteNumber(other.brakingCurvature, finiteNumber(other.curvature, confirmedCurvature))
        confirmedCornerBrakeBiasM = finiteNumber(other.cornerBrakeBiasM, confirmedCornerBrakeBiasM)
        confirmedBrakeCapacityMps2 = finiteNumber(other.brakeCapacityMps2, confirmedBrakeCapacityMps2)
        confirmedBrakeSpeedAeroFactor = finiteNumber(other.brakeSpeedAeroFactor, confirmedBrakeSpeedAeroFactor)
      end
    end
  end

  for _, sample in ipairs(lookaheadTiles or {}) do
    local sampleDistanceM = finiteNumber(sample and sample.distanceAheadM, -1.0)
    if sampleDistanceM > candidate.distanceM and sampleDistanceM <= candidate.distanceM + confirmationM then
      laterSampleInConfirmationWindow = true
      break
    end
  end

  local legacySingleTarget = #(lookaheadTiles or {}) == 1 and clusterConfirmedSamples == 1
  local sparseTerminalCurvature = math.abs(finiteNumber(candidate and candidate.brakingCurvature,
    finiteNumber(candidate and candidate.curvature, 0.0)))
  local sparseTerminalCurvatureOk = sparseTerminalCurvature >= sparseMinCurvature
  local sparseTerminalTarget = clusterConfirmedSamples == 1 and laterSampleInConfirmationWindow ~= true and
    sparseTerminalCurvatureOk == true
  if not legacySingleTarget and not sparseTerminalTarget and clusterConfirmedSamples < minSamples then
    return nil, 'isolated_brake_target_noise'
  end

  return {
    distanceM = confirmedEntryDistanceM,
    entryDistanceM = confirmedEntryDistanceM,
    targetSampleDistanceM = confirmedTargetDistanceM,
    confirmedTargetDistanceM = confirmedTargetDistanceM,
    targetKph = confirmedTargetKph,
    brakingCurvature = confirmedCurvature,
    curvature = confirmedCurvature,
    cornerBrakeBiasM = confirmedCornerBrakeBiasM,
    brakeCapacityMps2 = confirmedBrakeCapacityMps2,
    brakeSpeedAeroFactor = confirmedBrakeSpeedAeroFactor,
    clusterConfirmedSamples = clusterConfirmedSamples,
    legacySingleTarget = legacySingleTarget,
    sparseTerminalTarget = sparseTerminalTarget,
    sparseTerminalCurvatureOk = sparseTerminalCurvatureOk,
  }, 'confirmed'
end

local function betterBrakeDemand(candidate, best, yellow, red)
  if not candidate then return false end
  if not best then return true end

  local zonePriorityM = math.max(0.0, finiteNumber(settings.BRAKE_ZONE_START_PRIORITY_M, 8.0))
  local targetPriorityM = math.max(0.0, finiteNumber(settings.BRAKE_TARGET_DISTANCE_PRIORITY_M, 12.0))
  local ratioMargin = math.max(0.0, finiteNumber(settings.BRAKE_TARGET_RATIO_OVERRIDE_MARGIN, 0.16))
  local candidateZoneStart = finiteNumber(candidate.brakeZoneStartDistanceM, candidate.targetDistanceM)
  local bestZoneStart = finiteNumber(best.brakeZoneStartDistanceM, best.targetDistanceM)

  if candidateZoneStart < bestZoneStart - zonePriorityM then return true end
  if candidateZoneStart > bestZoneStart + zonePriorityM then return false end

  local candidateTarget = finiteNumber(candidate.targetSampleDistanceM, candidate.targetDistanceM)
  local bestTarget = finiteNumber(best.targetSampleDistanceM, best.targetDistanceM)
  if candidateTarget < bestTarget - targetPriorityM and candidate.ratio >= best.ratio - ratioMargin then
    return true
  end
  if candidateTarget > bestTarget + targetPriorityM and candidate.ratio <= best.ratio + ratioMargin then
    return false
  end

  if candidate.ratio >= red and best.ratio < red then return true end
  if candidate.ratio < red and best.ratio >= red then return false end
  if candidate.ratio >= yellow and best.ratio < yellow then return true end
  if candidate.ratio < yellow and best.ratio >= yellow then return false end
  return candidate.ratio > best.ratio
end

local function confirmedFutureBrakeTargets(car, lookaheadTiles)
  local speed = finiteNumber(car and car.speedKmh, 0)
  if speed <= 3.0 then return {} end
  local cache = M.futureBrakeTargetsCache
  if cache and cache.lookaheadTiles == lookaheadTiles and math.abs(finiteNumber(cache.speedKph, -1.0) - speed) < 0.01 then
    return cache.targets or {}
  end

  local minDrop = math.max(0.0, finiteNumber(settings.BRAKE_LOOKAHEAD_MIN_DROP_KPH, 10.0))
  local minAnchorDistanceM = math.max(0.5, finiteNumber(settings.BRAKE_STABLE_ANCHOR_MIN_AHEAD_M, 0.5))
  local confirmationM = math.max(0.5, finiteNumber(settings.BRAKE_CLUSTER_CONFIRMATION_M, 18.0))
  local toleranceKph = math.max(0.0, finiteNumber(settings.BRAKE_CLUSTER_TARGET_TOLERANCE_KPH, 8.0))
  local anchorSpacingM = math.max(2.0, confirmationM * 0.50)
  local candidates = {}
  local targets = {}
  local seen = {}
  local lastAnchorDistanceM = -math.huge
  local lastAnchorTargetKph = math.huge

  for _, candidate in ipairs(lookaheadTiles or {}) do
    local candidateDistance = finiteNumber(candidate and candidate.distanceAheadM, -1.0)
    if candidateDistance > minAnchorDistanceM and cueStraightSpeedCap(candidate) ~= true then
      local target = cueTargetSpeedKph(candidate)
      if speed > target + minDrop then
        local firstAnchor = #candidates == 0
        local farEnough = candidateDistance >= lastAnchorDistanceM + anchorSpacingM
        local sharperTarget = target < lastAnchorTargetKph - math.max(1.0, toleranceKph * 0.50)
        if firstAnchor or farEnough or sharperTarget then
          candidates[#candidates + 1] = {
            distanceM = candidateDistance,
            targetKph = target,
            brakingCurvature = finiteNumber(candidate.brakingCurvature, finiteNumber(candidate.curvature, 0.0)),
            curvature = finiteNumber(candidate.curvature, 0.0),
            cornerBrakeBiasM = finiteNumber(candidate.cornerBrakeBiasM, 0.0),
            brakeCapacityMps2 = finiteNumber(candidate.brakeCapacityMps2, 0.0),
            brakeSpeedAeroFactor = finiteNumber(candidate.brakeSpeedAeroFactor, 1.0),
          }
          lastAnchorDistanceM = candidateDistance
          lastAnchorTargetKph = target
        end
      end
    end
  end

  for _, candidate in ipairs(candidates) do
    local confirmed = confirmedFutureBrakeTarget(candidate, candidates, lookaheadTiles)
    if confirmed then
      local key = tostring(math.floor(finiteNumber(confirmed.distanceM, 0.0) * 10.0 + 0.5)) .. ':' ..
        tostring(math.floor(finiteNumber(confirmed.targetKph, 0.0) * 10.0 + 0.5))
      if seen[key] ~= true then
        seen[key] = true
        targets[#targets + 1] = confirmed
      end
    end
  end

  table.sort(targets, function(a, b)
    return finiteNumber(a and a.distanceM, 0.0) < finiteNumber(b and b.distanceM, 0.0)
  end)
  M.futureBrakeTargetsCache = {
    lookaheadTiles = lookaheadTiles,
    speedKph = speed,
    targets = targets,
  }
  return targets
end

local function futureBrakeDemand(tile, car, lookaheadTiles, capacity)
  local speed = finiteNumber(car and car.speedKmh, 0)
  if speed <= 3.0 then return nil end
  local speedMps = math.max(0, speed / 3.6)
  local tileDistance = finiteNumber(tile and tile.distanceAheadM, 0.0)
  local transferClassScale = clamp(finiteNumber(tile and
    (tile.brakeTransferScale or tile.cueTransferClassScale or tile.transferClassScale), 0.0), 0.0, 1.0)
  local dynamicConfidence = clamp(finiteNumber(tile and tile.dynamicConfidence, 0.70), 0.0, 1.0)
  local minDrop = math.max(0.0, finiteNumber(settings.BRAKE_LOOKAHEAD_MIN_DROP_KPH, 10.0))
  local yellow = finiteNumber(settings.YELLOW_RATIO, 0.14)
  local red = math.max(yellow + 0.01, finiteNumber(settings.RED_RATIO, 0.58))
  local best = nil

  for _, confirmed in ipairs(confirmedFutureBrakeTargets(car, lookaheadTiles)) do
    if confirmed and confirmed.distanceM > tileDistance + 0.5 then
      local fallbackCapacity = positiveBrakeCapacityMps2(capacity, settings.DEFAULT_BRAKE_G * 9.80665)
      local clampedCapacity = positiveBrakeCapacityMps2(confirmed.brakeCapacityMps2, fallbackCapacity)
      local timing = cachedBrakeTimingProfile(speed, clampedCapacity, transferClassScale, dynamicConfidence)
      local activeEntryLeadM = confirmed.legacySingleTarget == true and timing.entryLead or
        timing.entryLead * brakeClusterEntryLeadFraction(speed, transferClassScale)
      activeEntryLeadM = activeEntryLeadM + speedDropBrakeLeadM(speed, confirmed.targetKph, transferClassScale)
      local entryDistanceM = finiteNumber(confirmed.entryDistanceM, confirmed.distanceM)
      local targetSampleDistanceM = finiteNumber(confirmed.targetSampleDistanceM,
        finiteNumber(confirmed.confirmedTargetDistanceM, confirmed.distanceM))
      local brakingTargetDistanceM = math.max(0.5, entryDistanceM - activeEntryLeadM)
      local cornerBrakeBiasM = finiteNumber(confirmed.cornerBrakeBiasM, 0.0)
      cornerBrakeBiasM = clamp(cornerBrakeBiasM,
        finiteNumber(settings.CORNER_LEARNING_MIN_BRAKE_BIAS_M, -20.0),
        finiteNumber(settings.CORNER_LEARNING_MAX_BRAKE_BIAS_M, 24.0))
      local brakeDistanceM = requiredBrakeDistanceM(speed, confirmed.targetKph, clampedCapacity) * timing.safety +
        speedMps * timing.reaction + timing.margin
      brakeDistanceM = brakeDistanceM + cornerBrakeBiasM
      brakeDistanceM = math.max(0.0, brakeDistanceM)
      local brakeZoneStartDistanceM = brakingTargetDistanceM - brakeDistanceM
      local brakeZoneWarningStartDistanceM = brakeZoneStartDistanceM - brakeWarningDistance(speed, timing)
      local ratio = nil
      local required = 0.0
      local available = math.max(1.0, brakingTargetDistanceM - tileDistance)
      local cause = 'brake_zone_active'

      if tileDistance >= brakeZoneWarningStartDistanceM then
        if tileDistance < brakeZoneStartDistanceM then
          local progress = (tileDistance - brakeZoneWarningStartDistanceM) /
            math.max(0.001, brakeZoneStartDistanceM - brakeZoneWarningStartDistanceM)
          ratio = yellow + brakeCueProgression(progress, transferClassScale) *
            math.max(0.001, red - yellow - 0.001)
          required = ratio * clampedCapacity
          cause = 'brake_zone_warning'
        else
          ratio, required, clampedCapacity = requiredDecelRatio(speed, confirmed.targetKph, available, clampedCapacity)
          ratio = ratio * timing.safety
          required = required * timing.safety
          local speedDrop = speed - confirmed.targetKph
          if speedDrop <= minDrop * 2.0 then
            ratio = math.min(red - 0.001, math.max(yellow, ratio))
          else
            ratio = math.max(red, ratio)
          end
        end
      end

      if ratio then
        local demand = {
          ratio = ratio,
          required = required,
          capacity = clampedCapacity,
          targetSpeedKph = confirmed.targetKph,
          targetPointAheadM = brakingTargetDistanceM,
          targetDistanceM = brakingTargetDistanceM,
          entryDistanceM = entryDistanceM,
          targetSampleDistanceM = targetSampleDistanceM,
          distanceFromTileM = available,
          sampleDistanceFromTileM = targetSampleDistanceM - tileDistance,
          availableDistanceM = available,
          entryLeadM = activeEntryLeadM,
          targetCurvature = finiteNumber(confirmed.brakingCurvature, confirmed.curvature),
          brakeSpeedAeroFactor = finiteNumber(confirmed.brakeSpeedAeroFactor, 1.0),
          requiredBrakeDistanceM = brakeDistanceM,
          brakeZoneStartDistanceM = brakeZoneStartDistanceM,
          brakeZoneWarningStartDistanceM = brakeZoneWarningStartDistanceM,
          cornerBrakeBiasM = cornerBrakeBiasM,
          cueCause = cause,
          transferClassScale = transferClassScale,
          dynamicConfidence = timing.dynamicConfidence,
          confidenceUncertaintyScale = timing.confidenceUncertaintyScale,
          brakeConfidenceMarginM = timing.brakeConfidenceMarginM,
          clusterConfirmedSamples = confirmed.clusterConfirmedSamples,
          sparseTerminalTarget = confirmed.sparseTerminalTarget,
          sparseTerminalCurvatureOk = confirmed.sparseTerminalCurvatureOk,
        }
        if betterBrakeDemand(demand, best, yellow, red) then best = demand end
      end
    end
  end

  return best
end

local function keyForTile(tile)
  local trackDistanceM = tonumber(tile and tile.s)
  if trackDistanceM then
    local binM = math.max(0.5, finiteNumber(settings.CUE_STATE_DISTANCE_KEY_M, 4.0))
    return 's:' .. tostring(math.floor(trackDistanceM / binM + 0.5))
  end
  if tile and tile.progress ~= nil then
    return 'p:' .. tostring(math.floor(finiteNumber(tile.progress, 0.0) * 10000.0 + 0.5))
  end
  if tile and tile.key ~= nil then return tostring(tile.key) end
  if tile and tile.sampleIndex ~= nil then return tostring(tile.sampleIndex) end
  if tile and tile.index ~= nil then return tostring(tile.index) end
  return 'unknown'
end

local function smoothRatio(previous, raw, dt)
  previous = finiteNumber(previous, raw)
  raw = finiteNumber(raw, 0)
  dt = clamp(dt, 1 / 120, 0.25)
  local rate = raw >= previous and finiteNumber(settings.CUE_ATTACK_RATE, 24.0) or finiteNumber(settings.CUE_RELEASE_RATE, 5.0)
  local alpha = clamp(dt * rate, 0, 1)
  return previous + (raw - previous) * alpha
end

local function severityForRatio(ratio)
  local yellow = finiteNumber(settings.YELLOW_RATIO, 0.14)
  local red = math.max(yellow + 0.01, finiteNumber(settings.RED_RATIO, 0.58))
  return clamp((ratio - yellow) / (red - yellow), 0, 1)
end

function M.beginFrame(frameId, dt)
  M.frameId = frameId
  M.frameDt = clamp(dt, 1 / 120, 0.25)
  M.seenThisFrame = {}
  M.futureBrakeTargetsCache = nil
  M.brakeTimingProfileCache = {}
end

function M.endFrame()
  for tileKey, _ in pairs(M.redFrames) do
    if not M.seenThisFrame[tileKey] then M.redFrames[tileKey] = nil end
  end
  for tileKey, _ in pairs(M.cueStates) do
    if not M.seenThisFrame[tileKey] then M.cueStates[tileKey] = nil end
  end
  M.seenThisFrame = {}
end

local function kindForRatio(tileKey, ratio, cueCause)
  M.seenThisFrame[tileKey] = true
  ratio = finiteNumber(ratio, 0.0)
  local cueCauseText = tostring(cueCause or '')
  local zeroReleaseRatio = math.max(0.0, finiteNumber(settings.CUE_ZERO_RELEASE_RATIO, 0.015))
  local yellowReleaseRatio = math.max(0.0,
    finiteNumber(settings.YELLOW_RATIO, 0.14) - finiteNumber(settings.YELLOW_HYSTERESIS, 0.03))
  local noCauseReleaseRatio = math.max(zeroReleaseRatio,
    finiteNumber(settings.CUE_NO_CAUSE_RELEASE_RATIO, yellowReleaseRatio))
  local zeroDemandRelease = cueCauseText == '' and ratio <= noCauseReleaseRatio
  if zeroDemandRelease then
    M.redFrames[tileKey] = 0
    M.cueStates[tileKey] = {
      ratio = 0.0,
      kind = 'green',
      severity = 0.0,
    }
    return 'green', 'safe_or_on_target', 0.0, 0.0, 0
  end
  local state = M.cueStates[tileKey] or { ratio = ratio, kind = 'green' }
  local displayRatio = smoothRatio(state.ratio, ratio, M.frameDt)
  local yellowEnter = finiteNumber(settings.YELLOW_RATIO, 0.14)
  local redEnter = math.max(yellowEnter + 0.01, finiteNumber(settings.RED_RATIO, 0.58))
  local yellowExit = math.max(0.0, yellowEnter - finiteNumber(settings.YELLOW_HYSTERESIS, 0.03))
  local redExit = math.max(yellowEnter, redEnter - finiteNumber(settings.RED_HYSTERESIS, 0.08))
  local previousKind = state.kind or 'green'
  local kind = 'green'
  local reason = 'safe_or_on_target'
  local redAuthority = not isAdvisoryCause(cueCause) and tostring(cueCause or '') ~= 'brake_zone_warning'

  if previousKind == 'red' then
    if displayRatio >= redExit and redAuthority then
      kind, reason = 'red', tostring(cueCause or '') == 'brake_zone_active' and 'brake_zone_active' or 'brake_now_hysteresis'
    elseif displayRatio >= yellowExit then
      kind, reason = 'yellow', yellowReasonFor(cueCause, 'recovery_advisory')
    end
  elseif previousKind == 'yellow' then
    if displayRatio >= redEnter and redAuthority then
      kind, reason = 'red', tostring(cueCause or '') == 'brake_zone_active' and 'brake_zone_active' or 'brake_now'
    elseif displayRatio >= yellowExit then
      kind, reason = 'yellow', yellowReasonFor(cueCause, 'prepare_or_lift_hysteresis')
    end
  else
    if displayRatio >= redEnter and redAuthority then
      kind, reason = 'red', tostring(cueCause or '') == 'brake_zone_active' and 'brake_zone_active' or 'brake_now'
    elseif displayRatio >= yellowEnter then
      kind, reason = 'yellow', yellowReasonFor(cueCause, 'prepare_or_lift')
    end
  end

  M.redFrames[tileKey] = kind == 'red' and ((M.redFrames[tileKey] or 0) + 1) or 0
  M.cueStates[tileKey] = {
    ratio = displayRatio,
    kind = kind,
    severity = severityForRatio(displayRatio),
  }
  return kind, reason, displayRatio, M.cueStates[tileKey].severity, M.redFrames[tileKey] or 0
end

function M.evaluate(tile, car, profile, lookaheadTiles)
  tile = tile or {}
  car = car or {}
  profile = profile or {}
  local speed = finiteNumber(car.speedKmh, 0)
  local distance = math.max(1.0, finiteNumber(tile.distanceAheadM, 1))
  local target = cueTargetSpeedKph(tile)
  local capacity = finiteNumber(tile.brakeCapacityMps2, settings.DEFAULT_BRAKE_G * 9.80665)
  local ratio, required, clampedCapacity = 0.0, 0.0,
    positiveBrakeCapacityMps2(capacity, settings.DEFAULT_BRAKE_G * 9.80665)
  local directTransferClassScale = clamp(finiteNumber(tile.brakeTransferScale or tile.cueTransferClassScale or tile.transferClassScale, 0.0), 0.0, 1.0)
  local directDynamicConfidence = clamp(finiteNumber(tile.dynamicConfidence, 0.70), 0.0, 1.0)
  local speedMps = math.max(0.0, speed / 3.6)
  local directMinDrop = math.max(0.0, finiteNumber(settings.BRAKE_DIRECT_MIN_DROP_KPH,
    finiteNumber(settings.BRAKE_LOOKAHEAD_MIN_DROP_KPH, 6.0)))
  local directCueMinRatio = math.max(finiteNumber(settings.CUE_ZERO_RELEASE_RATIO, 0.015),
    finiteNumber(settings.BRAKE_DIRECT_MIN_RATIO, 0.035))
  local directMinTargetDistanceM = math.max(0.0, finiteNumber(settings.BRAKE_DIRECT_MIN_TARGET_DISTANCE_M, 24.0))
  local directCueCause = nil
  local directDemandAuthoritative = false
  local directBrakeTiming = nil
  local directRequiredBrakeDistanceM = 0.0
  local directSpeedDropLeadM = 0.0
  local directAvailableDistanceM = distance
  local directBrakeZoneStartDistanceM = distance
  local directBrakeZoneWarningStartDistanceM = distance
  local directTargetNeedsBrake = distance >= directMinTargetDistanceM and
    cueStraightSpeedCap(tile) ~= true and speed > 3.0 and speed > target + directMinDrop
  if directTargetNeedsBrake then
    directBrakeTiming = cachedBrakeTimingProfile(speed, clampedCapacity, directTransferClassScale, directDynamicConfidence)
    directSpeedDropLeadM = speedDropBrakeLeadM(speed, target, directTransferClassScale)
    directRequiredBrakeDistanceM = requiredBrakeDistanceM(speed, target, clampedCapacity) * directBrakeTiming.safety +
      speedMps * directBrakeTiming.reaction + directBrakeTiming.margin + directSpeedDropLeadM
    directAvailableDistanceM = math.max(1.0,
      distance - speedMps * directBrakeTiming.reaction - directBrakeTiming.margin - directSpeedDropLeadM)
    ratio, required, clampedCapacity = requiredDecelRatio(speed, target, directAvailableDistanceM, clampedCapacity)
    ratio = ratio * directBrakeTiming.safety
    required = required * directBrakeTiming.safety
    directBrakeZoneStartDistanceM = distance - directRequiredBrakeDistanceM
    directBrakeZoneWarningStartDistanceM = directBrakeZoneStartDistanceM - brakeWarningDistance(speed, directBrakeTiming)
    if ratio > directCueMinRatio then
      directDemandAuthoritative = true
      directCueCause = 'direct_target_brake'
    end
  end
  if directTargetNeedsBrake and directDemandAuthoritative ~= true then
    ratio = 0.0
    required = 0.0
    directRequiredBrakeDistanceM = 0.0
    directAvailableDistanceM = distance
    directBrakeZoneStartDistanceM = distance
    directBrakeZoneWarningStartDistanceM = distance
  end
  local future = futureBrakeDemand(tile, car, lookaheadTiles, capacity)
  local brakeTargetSpeedKph = target
  local brakeTargetDistanceM = distance
  local brakeTargetSampleDistanceM = distance
  local brakeTargetAvailableDistanceM = directAvailableDistanceM
  local brakeTargetEntryLeadM = 0.0
  local brakeTargetCurvature = finiteNumber(tile.brakingCurvature, finiteNumber(tile.curvature, 0.0))
  local brakeClusterConfirmedSamples = 0
  local brakeSparseTerminalTarget = false
  local brakeSparseTerminalCurvatureOk = false
  local dynamicConfidence = directDynamicConfidence
  local confidenceUncertaintyScaleValue = confidenceUncertaintyScale(dynamicConfidence)
  local brakeConfidenceMarginM = finiteNumber(settings.BRAKE_CONFIDENCE_UNCERTAINTY_MARGIN_M, 8.0) *
    confidenceUncertaintyScaleValue
  local requiredBrakeDistanceAheadM = directRequiredBrakeDistanceM
  local targetPointAheadM = distance
  local brakeZoneStartDistanceM = directBrakeZoneStartDistanceM
  local brakeZoneWarningStartDistanceM = directBrakeZoneWarningStartDistanceM
  local brakeTransferClassScale = directTransferClassScale
  local brakeSpeedAeroFactor = finiteNumber(tile.brakeSpeedAeroFactor, 1.0)
  local cornerBrakeBiasM = clamp(finiteNumber(tile.cornerBrakeBiasM, 0.0),
    finiteNumber(settings.CORNER_LEARNING_MIN_BRAKE_BIAS_M, -20.0),
    finiteNumber(settings.CORNER_LEARNING_MAX_BRAKE_BIAS_M, 24.0))
  local cueCause = directCueCause
  local sequenceAdvisory = finiteNumber(tile.sequenceAdvisoryRatio, 0.0)
  if sequenceAdvisory > ratio then
    ratio = math.min(math.max(finiteNumber(settings.YELLOW_RATIO, 0.14), sequenceAdvisory),
      math.max(finiteNumber(settings.YELLOW_RATIO, 0.14), finiteNumber(settings.RED_RATIO, 0.58)) - 0.001)
    required = ratio * clampedCapacity
    cueCause = 'corner_flow_advisory'
  end
  local instabilityAdvisory = finiteNumber(tile.instabilityAdvisoryRatio, 0.0)
  if instabilityAdvisory > ratio then
    ratio = math.min(math.max(finiteNumber(settings.YELLOW_RATIO, 0.14), instabilityAdvisory),
      math.max(finiteNumber(settings.YELLOW_RATIO, 0.14), finiteNumber(settings.RED_RATIO, 0.58)) - 0.001)
    required = ratio * clampedCapacity
    cueCause = 'instability_advisory'
  end
  local knowledgeBaseAdvisory = finiteNumber(tile.knowledgeBaseAdvisoryRatio, 0.0)
  if knowledgeBaseAdvisory > ratio then
    ratio = math.min(math.max(finiteNumber(settings.YELLOW_RATIO, 0.14), knowledgeBaseAdvisory),
      math.max(finiteNumber(settings.YELLOW_RATIO, 0.14), finiteNumber(settings.RED_RATIO, 0.58)) - 0.001)
    required = ratio * clampedCapacity
    cueCause = 'knowledge_base_advisory'
  end
  local futureRatioMargin = math.max(0.0, finiteNumber(settings.BRAKE_TARGET_RATIO_OVERRIDE_MARGIN, 0.16))
  local futureOverridesCue = future and future.ratio > ratio
  local futureSuppliesTargetMetadata = future and
    (futureOverridesCue or (tostring(cueCause or '') == 'direct_target_brake' and future.ratio >= ratio - futureRatioMargin))
  if futureSuppliesTargetMetadata then
    if futureOverridesCue then
      ratio = future.ratio
      required = future.required
      clampedCapacity = future.capacity
    end
    brakeTargetSpeedKph = future.targetSpeedKph
    targetPointAheadM = future.targetPointAheadM
    brakeTargetDistanceM = future.targetDistanceM
    brakeTargetSampleDistanceM = future.targetSampleDistanceM
    brakeTargetAvailableDistanceM = future.availableDistanceM
    brakeTargetEntryLeadM = future.entryLeadM
    brakeTargetCurvature = future.targetCurvature
    brakeClusterConfirmedSamples = future.clusterConfirmedSamples or 0
    brakeSparseTerminalTarget = future.sparseTerminalTarget == true
    brakeSparseTerminalCurvatureOk = future.sparseTerminalCurvatureOk == true
    brakeTransferClassScale = finiteNumber(future.cueTransferClassScale or future.transferClassScale, brakeTransferClassScale)
    brakeSpeedAeroFactor = finiteNumber(future.brakeSpeedAeroFactor, brakeSpeedAeroFactor)
    cornerBrakeBiasM = finiteNumber(future.cornerBrakeBiasM, cornerBrakeBiasM)
    dynamicConfidence = finiteNumber(future.dynamicConfidence, dynamicConfidence)
    confidenceUncertaintyScaleValue = finiteNumber(future.confidenceUncertaintyScale, confidenceUncertaintyScaleValue)
    brakeConfidenceMarginM = finiteNumber(future.brakeConfidenceMarginM, brakeConfidenceMarginM)
    requiredBrakeDistanceAheadM = future.requiredBrakeDistanceM
    brakeZoneStartDistanceM = future.brakeZoneStartDistanceM
    brakeZoneWarningStartDistanceM = future.brakeZoneWarningStartDistanceM
    if futureOverridesCue then cueCause = future.cueCause end
  end
  local kind, reason, cueRatio, cueSeverity, redFrames = kindForRatio(keyForTile(tile), ratio, cueCause)
  return {
    kind = kind,
    targetSpeedKph = target,
    brakeTargetSpeedKph = brakeTargetSpeedKph,
    brakeTargetDistanceM = brakeTargetDistanceM,
    brakeTargetSampleDistanceM = brakeTargetSampleDistanceM,
    brakeTargetAvailableDistanceM = brakeTargetAvailableDistanceM,
    brakeTargetEntryLeadM = brakeTargetEntryLeadM,
    brakeTargetCurvature = brakeTargetCurvature,
    brakeClusterConfirmedSamples = brakeClusterConfirmedSamples,
    brakeSparseTerminalTarget = brakeSparseTerminalTarget,
    brakeSparseTerminalCurvatureOk = brakeSparseTerminalCurvatureOk,
    brakeTransferClassScale = brakeTransferClassScale,
    brakeSpeedAeroFactor = brakeSpeedAeroFactor,
    cornerBrakeBiasM = cornerBrakeBiasM,
    dynamicConfidence = dynamicConfidence,
    confidenceUncertaintyScale = confidenceUncertaintyScaleValue,
    brakeConfidenceMarginM = brakeConfidenceMarginM,
    requiredBrakeDistanceM = requiredBrakeDistanceAheadM,
    targetPointAheadM = targetPointAheadM,
    brakeZoneStartDistanceM = brakeZoneStartDistanceM,
    brakeZoneWarningStartDistanceM = brakeZoneWarningStartDistanceM,
    cueCause = cueCause or reason,
    sequenceDemand = sequenceAdvisory,
    requiredDecelRatio = ratio,
    cueRatio = cueRatio,
    cueSeverity = cueSeverity,
    redFrames = redFrames,
    requiredDecelMps2 = required,
    brakeCapacityMps2 = clampedCapacity,
    reason = cueCause or reason,
    profileKey = profile.carKey or 'default',
  }
end

M.requiredDecelRatio = requiredDecelRatio
M.confidenceUncertaintyScale = confidenceUncertaintyScale

return M
