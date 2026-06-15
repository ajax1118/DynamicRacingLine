local settings = require('src/settings')
local math3d = require('src/math3d')
local knowledge_base = require('src/knowledge_base')
local M = {}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function finiteVec(p)
  if not p then return false end
  local x, y, z = math3d.x(p), math3d.y(p), math3d.z(p)
  return x == x and y == y and z == z and math.abs(x) < 100000 and math.abs(y) < 100000 and math.abs(z) < 100000
end

local function fallbackNormal(forward)
  local up = math3d.vec(0, 1, 0)
  if math.abs(math3d.dot(forward, up)) > 0.96 then return math3d.vec(1, 0, 0) end
  return up
end

local function sign(value)
  value = tonumber(value) or 0
  if value < 0 then return -1 end
  return 1
end

local function speedAeroFactorForTarget(speedKph, strength)
  local reference = math.max(1.0, finiteNumber(settings.SPEED_AERO_REFERENCE_KPH, 260.0))
  local speedRatio = math3d.clamp(finiteNumber(speedKph, 0.0) / reference, 0.0, 1.0)
  return math3d.clamp(1.0 + finiteNumber(strength, 0.0) * speedRatio * speedRatio, 0.90, 1.22)
end

local function brakeAeroFactorForTarget(speedKph, targetKph, strength)
  strength = finiteNumber(strength, 0.0)
  if strength <= 0.0 then return 1.0 end
  local reference = math.max(1.0, finiteNumber(settings.SPEED_AERO_REFERENCE_KPH, 260.0))
  local averageSpeedKph = (math.max(0.0, finiteNumber(speedKph, 0.0)) +
    math.max(0.0, finiteNumber(targetKph, 0.0))) * 0.5
  local speedRatio = math3d.clamp(averageSpeedKph / reference, 0.0, 1.0)
  local scale = math.max(0.0, finiteNumber(settings.BRAKE_SPEED_AERO_EFFECT_SCALE, 0.60))
  local maxFactor = math.max(1.0, finiteNumber(settings.BRAKE_SPEED_AERO_MAX_FACTOR, 1.16))
  return math3d.clamp(1.0 + strength * scale * speedRatio * speedRatio, 1.0, maxFactor)
end

local function brakeCapacityForTarget(baseBrakeG, speedKph, targetKph, strength)
  local base = math.max(0.1, finiteNumber(baseBrakeG, settings.DEFAULT_BRAKE_G))
  local factor = brakeAeroFactorForTarget(speedKph, targetKph, strength)
  local cappedG = math.min(finiteNumber(settings.MAX_DYNAMIC_BRAKE_G, 4.50), base * factor)
  return cappedG * 9.80665, factor
end

local function speedCapTargetFor(curvature, targetSpeedKph, maxSpeedKph)
  curvature = math.abs(finiteNumber(curvature, 0.0))
  targetSpeedKph = finiteNumber(targetSpeedKph, 0.0)
  maxSpeedKph = finiteNumber(maxSpeedKph, settings.MAX_TARGET_SPEED_KPH)
  return curvature <= 0.00001 or targetSpeedKph >= maxSpeedKph - 0.25
end

local function wrapIndex(items, index)
  local count = #(items or {})
  if count == 0 then return 1 end
  return ((index - 1) % count) + 1
end

local function dynamicNeighbor(samples, index, offset, closedLoop)
  local count = #(samples or {})
  if count == 0 then return nil end
  if closedLoop == true then return samples[wrapIndex(samples, index + offset)] end
  local candidate = index + offset
  if candidate < 1 or candidate > count then return nil end
  return samples[candidate]
end

local function dynamicCurvatureAt(samples, index, closedLoop)
  local cur = samples and samples[index]
  if not cur or not finiteVec(cur.pos) then return 0.0, 0.0 end
  local prev = dynamicNeighbor(samples, index, -2, closedLoop)
  local nextSample = dynamicNeighbor(samples, index, 2, closedLoop)
  if not prev or not nextSample or not finiteVec(prev.pos) or not finiteVec(nextSample.pos) or
    prev == cur or nextSample == cur or prev == nextSample then
    return finiteNumber(cur.curvature, 0.0), finiteNumber(cur.signedCurvature, 0.0)
  end

  local a = math3d.norm(math3d.sub(cur.pos, prev.pos), cur.forward or math3d.vec(0, 0, 1))
  local b = math3d.norm(math3d.sub(nextSample.pos, cur.pos), cur.forward or math3d.vec(0, 0, 1))
  local turn = math3d.len(math3d.sub(b, a))
  local span = math.max(1.0, math3d.dist(prev.pos, nextSample.pos))
  local curvature = turn / span
  local normal = cur.normal or fallbackNormal(a)
  local signedTurn = math3d.dot(math3d.cross(a, b), normal)
  return curvature, curvature * sign(signedTurn)
end

local function recomputeDynamicLineCurvature(samples, closedLoop)
  samples = samples or {}
  if #samples < 3 then
    for _, sample in ipairs(samples) do
      sample.dynamicLineCurvature = finiteNumber(sample.curvature, 0.0)
      sample.dynamicLineSignedCurvature = finiteNumber(sample.signedCurvature, 0.0)
    end
    return samples
  end
  for index, sample in ipairs(samples) do
    local curvature, signedCurvature = dynamicCurvatureAt(samples, index, closedLoop == true)
    sample.dynamicLineCurvature = curvature
    sample.dynamicLineSignedCurvature = signedCurvature
  end
  for _, sample in ipairs(samples) do
    sample.curvature = sample.dynamicLineCurvature
    sample.signedCurvature = sample.dynamicLineSignedCurvature
  end
  return samples
end

local function estimatedTotalLength(samples)
  samples = samples or {}
  local count = #samples
  if count <= 1 then return count end
  local lastS = finiteNumber(samples[count] and samples[count].s, 0.0)
  if lastS <= 0 then return count end
  local spacing = lastS / math.max(1, count - 1)
  return lastS + math.max(0.1, spacing)
end

local function forwardDistance(anchorS, sampleS, totalLength)
  if totalLength <= 0 then return 0 end
  local d = (sampleS - anchorS) % totalLength
  if d < 0 then d = d + totalLength end
  return d
end

local function profileDistanceBetween(samples, leftIndex, rightIndex, closedLoop, totalLength)
  local left = samples and samples[leftIndex]
  local right = samples and samples[rightIndex]
  local leftAhead = finiteNumber(left and left.distanceAheadM, nil)
  local rightAhead = finiteNumber(right and right.distanceAheadM, nil)
  if leftAhead and rightAhead then
    local delta = math.abs(rightAhead - leftAhead)
    if delta > 0.001 and delta < 80.0 then return delta end
  end
  local leftS = finiteNumber(left and left.s, nil)
  local rightS = finiteNumber(right and right.s, nil)
  if leftS and rightS then
    local delta = math.abs(rightS - leftS)
    if closedLoop == true and totalLength and totalLength > 0 then
      delta = math.min(delta, math.max(0.0, totalLength - delta))
    end
    if delta > 0.001 and delta < 80.0 then return delta end
  end
  return math.max(0.25, finiteNumber(settings.TILE_LENGTH_M, 1.45))
end

local function brakeEnvelopeCapacityMps2(car)
  local brakeG = math.max(0.1, finiteNumber(car and (car.brake_decel_g or car.brakeG), settings.DEFAULT_BRAKE_G))
  local scale = math3d.clamp(finiteNumber(settings.BRAKE_TARGET_PROFILE_DECEL_CAPACITY_SCALE, 0.60), 0.25, 1.0)
  return math.max(0.1, brakeG * 9.80665 * scale)
end

local function brakeEnvelopeReserveDistanceM(car)
  car = car or {}
  local currentSpeedKph = math.max(0.0, finiteNumber(car.current_speed_kph, finiteNumber(car.currentSpeedKph, 0.0)))
  local speedMps = currentSpeedKph / 3.6
  local reserveM = math.max(0.0, finiteNumber(settings.BRAKE_TARGET_PROFILE_DECEL_RESERVE_M,
    finiteNumber(settings.BRAKE_DISTANCE_MARGIN_M, 0.0)))
  local reactionS = math.max(0.0, finiteNumber(settings.BRAKE_TARGET_PROFILE_DECEL_REACTION_S,
    finiteNumber(settings.BRAKE_REACTION_TIME_S, 0.0)))
  return reserveM + speedMps * reactionS
end

local function brakeEnvelopeAllowedSpeedKph(targetKph, distanceM, capacityMps2, reserveDistanceM)
  local targetMps = math.max(0.0, finiteNumber(targetKph, 0.0) / 3.6)
  local distance = math.max(0.0, finiteNumber(distanceM, 0.0) - finiteNumber(reserveDistanceM, 0.0))
  local capacity = math.max(0.1, finiteNumber(capacityMps2, settings.DEFAULT_BRAKE_G * 9.80665))
  return math.sqrt(targetMps * targetMps + 2.0 * capacity * distance) * 3.6
end

local function resetBrakeEnvelopeAnchor(speeds, index)
  return finiteNumber(speeds and speeds[index], settings.MAX_TARGET_SPEED_KPH), 0.0
end

local function applyBrakeProfileDecelEnvelopeBackward(speeds, samples, capacity, reserveDistanceM, closedLoop, totalLength, limited)
  local count = #(speeds or {})
  if count < 2 then return speeds, limited or {} end
  limited = limited or {}
  local anchorTargetKph
  local cumulativeDistanceM = 0.0
  local previousIndex
  local toleranceKph = 0.25

  if closedLoop == true and count > 2 then
    local minIndex = 1
    local minSpeed = finiteNumber(speeds[1], settings.MAX_TARGET_SPEED_KPH)
    for index = 2, count do
      local speed = finiteNumber(speeds[index], minSpeed)
      if speed < minSpeed then
        minSpeed = speed
        minIndex = index
      end
    end

    anchorTargetKph, cumulativeDistanceM = resetBrakeEnvelopeAnchor(speeds, minIndex)
    previousIndex = minIndex
    for offset = 1, count - 1 do
      local index = wrapIndex(speeds, minIndex - offset)
      local step = profileDistanceBetween(samples, index, previousIndex, true, totalLength)
      cumulativeDistanceM = cumulativeDistanceM + step
      local allowed = brakeEnvelopeAllowedSpeedKph(anchorTargetKph, cumulativeDistanceM, capacity, reserveDistanceM)
      if speeds[index] > allowed then
        speeds[index] = allowed
        limited[index] = true
      elseif speeds[index] < allowed - toleranceKph then
        anchorTargetKph, cumulativeDistanceM = resetBrakeEnvelopeAnchor(speeds, index)
      end
      previousIndex = index
    end
    return speeds, limited
  end

  anchorTargetKph, cumulativeDistanceM = resetBrakeEnvelopeAnchor(speeds, count)
  previousIndex = count
  for index = count - 1, 1, -1 do
    local step = profileDistanceBetween(samples, index, previousIndex, false, totalLength)
    cumulativeDistanceM = cumulativeDistanceM + step
    local allowed = brakeEnvelopeAllowedSpeedKph(anchorTargetKph, cumulativeDistanceM, capacity, reserveDistanceM)
    if speeds[index] > allowed then
      speeds[index] = allowed
      limited[index] = true
    elseif speeds[index] < allowed - toleranceKph then
      anchorTargetKph, cumulativeDistanceM = resetBrakeEnvelopeAnchor(speeds, index)
    end
    previousIndex = index
  end
  return speeds, limited
end

local function applyBrakeProfileDecelEnvelope(speeds, samples, car, options)
  if settings.BRAKE_TARGET_PROFILE_DECEL_ENVELOPE ~= true then return speeds, {} end
  local count = #(speeds or {})
  if count < 2 then return speeds, {} end

  options = options or {}
  local closedLoop = options.closedLoop == true
  local totalLength = estimatedTotalLength(samples)
  local capacity = brakeEnvelopeCapacityMps2(car)
  local reserveDistanceM = brakeEnvelopeReserveDistanceM(car)
  local passes = math.max(1, math.floor(finiteNumber(settings.BRAKE_TARGET_PROFILE_DECEL_PASSES, 2) + 0.5))
  local limited = {}

  for _ = 1, passes do
    speeds, limited = applyBrakeProfileDecelEnvelopeBackward(
      speeds, samples, capacity, reserveDistanceM, closedLoop, totalLength, limited)
  end

  return speeds, limited
end

local function smoothBrakeTargetProfile(samples, car, options)
  samples = samples or {}
  local count = #samples
  if count == 0 then return samples end
  local maxTarget = finiteNumber(car and car.max_target_speed_kph, settings.MAX_TARGET_SPEED_KPH)
  local minTarget = finiteNumber(car and car.min_corner_speed_kph, settings.MIN_CORNER_SPEED_KPH)
  local speeds = {}
  local rawSpeeds = {}
  for index, sample in ipairs(samples) do
    local speed = math3d.clamp(finiteNumber(sample and sample.targetSpeedKph, maxTarget), minTarget, maxTarget)
    speeds[index] = speed
    rawSpeeds[index] = speed
  end

  options = options or {}
  local closedLoop = options.closedLoop == true
  local totalLength = estimatedTotalLength(samples)
  if settings.BRAKE_TARGET_PROFILE_SMOOTHING == true and count > 1 then
    local maxRisePerM = math.max(0.25, finiteNumber(settings.BRAKE_TARGET_PROFILE_MAX_RISE_KPH_PER_M, 4.0))
    local passes = math.max(1, math.floor(finiteNumber(settings.BRAKE_TARGET_PROFILE_PASSES, 2) + 0.5))
    for _ = 1, passes do
      for index = 2, count do
        local step = maxRisePerM * profileDistanceBetween(samples, index - 1, index, closedLoop, totalLength)
        speeds[index] = math.min(speeds[index], speeds[index - 1] + step)
      end
      if closedLoop and count > 2 then
        local step = maxRisePerM * profileDistanceBetween(samples, count, 1, true, totalLength)
        speeds[1] = math.min(speeds[1], speeds[count] + step)
      end
      for index = count - 1, 1, -1 do
        local step = maxRisePerM * profileDistanceBetween(samples, index, index + 1, closedLoop, totalLength)
        speeds[index] = math.min(speeds[index], speeds[index + 1] + step)
      end
      if closedLoop and count > 2 then
        local step = maxRisePerM * profileDistanceBetween(samples, count, 1, true, totalLength)
        speeds[count] = math.min(speeds[count], speeds[1] + step)
      end
    end
  end

  local envelopeLimited = {}
  speeds, envelopeLimited = applyBrakeProfileDecelEnvelope(speeds, samples, car, {
    closedLoop = closedLoop,
  })

  for index, sample in ipairs(samples) do
    local target = math3d.clamp(finiteNumber(speeds[index], maxTarget), minTarget, maxTarget)
    sample.brakeProfileTargetSpeedKph = target
    sample.brakeProfileSpeedCap = target >= maxTarget - 0.25
    sample.brakeProfileLimited = target < finiteNumber(sample.targetSpeedKph, maxTarget) - 0.25
    sample.brakeProfileEnvelopeLimited = envelopeLimited[index] == true
    sample.brakeProfileReductionKph = math.max(0.0, finiteNumber(rawSpeeds[index], target) - target)
  end
  return samples
end

local function targetSpeedFromCorneringG(curvature, cornering_g, minSpeed, maxSpeed)
  local radius = 1.0 / curvature
  local speedMps = math.sqrt(math.max(1.0, cornering_g * 9.80665 * radius))
  return math3d.clamp(speedMps * 3.6, minSpeed, maxSpeed)
end

local function targetSpeedForCurvature(curvature, car)
  car = car or {}
  curvature = math.abs(finiteNumber(curvature, 0))
  local minSpeed = finiteNumber(car.min_corner_speed_kph, settings.MIN_CORNER_SPEED_KPH)
  local maxSpeed = finiteNumber(car.max_target_speed_kph, settings.MAX_TARGET_SPEED_KPH)
  if curvature <= 0.00001 then return maxSpeed end

  local cornering_g = math.max(0.1, finiteNumber(car.cornering_g, settings.DEFAULT_CORNERING_G))
  local cornering_g_no_speed_aero = math.max(0.1, finiteNumber(car.cornering_g_no_speed_aero, cornering_g))
  local speed_aero_strength = math3d.clamp(finiteNumber(car.speed_aero_strength, 0.0), 0.0, 0.30)
  if speed_aero_strength <= 0.0 then
    return targetSpeedFromCorneringG(curvature, cornering_g, minSpeed, maxSpeed)
  end

  local speedKph = targetSpeedFromCorneringG(curvature, cornering_g_no_speed_aero, minSpeed, maxSpeed)
  for _ = 1, 4 do
    local aero = speedAeroFactorForTarget(speedKph, speed_aero_strength)
    speedKph = targetSpeedFromCorneringG(curvature, cornering_g_no_speed_aero * aero, minSpeed, maxSpeed)
  end
  return speedKph
end

local function brakingCurvatureForSample(sample)
  sample = sample or {}
  local lineCurvature = math.abs(finiteNumber(sample.curvature, 0.0))
  local dynamicLineCurvature = math.abs(finiteNumber(sample.dynamicLineCurvature, lineCurvature))
  local storedLineCurvature = math.abs(finiteNumber(sample.lineCurvature, lineCurvature))
  local centerCurvature = math.abs(finiteNumber(sample.centerCurvature, lineCurvature))
  return math.max(lineCurvature, dynamicLineCurvature, storedLineCurvature, centerCurvature)
end

local function sequenceThresholds(speedKph, corneringG)
  local highDownforceG = math.max(1.56, finiteNumber(settings.SEQUENCE_ADVISORY_HIGH_DOWNFORCE_G, 2.90))
  local highSpeedKph = math.max(141.0, finiteNumber(settings.SEQUENCE_ADVISORY_HIGH_SPEED_KPH, 220.0))
  local downforceScale = math3d.clamp((finiteNumber(corneringG, settings.DEFAULT_CORNERING_G) - 1.55) /
    math.max(0.01, highDownforceG - 1.55), 0.0, 1.0)
  local speedScale = math3d.clamp((finiteNumber(speedKph, 0.0) - 140.0) / math.max(1.0, highSpeedKph - 140.0), 0.0, 1.0)
  local scale = downforceScale * speedScale
  return {
    scale = scale,
    minCurvature = math.max(0.0, finiteNumber(settings.SEQUENCE_ADVISORY_MIN_CURVATURE, 0.0015) -
      finiteNumber(settings.SEQUENCE_ADVISORY_MIN_CURVATURE_REDUCTION, 0.00035) * scale),
    minEnergy = math.max(0.0, finiteNumber(settings.SEQUENCE_ADVISORY_MIN_ENERGY, 0.0025) -
      finiteNumber(settings.SEQUENCE_ADVISORY_MIN_ENERGY_REDUCTION, 0.00055) * scale),
    minLoadRatio = math.max(0.05, finiteNumber(settings.SEQUENCE_ADVISORY_MIN_LOAD_RATIO, 0.34) -
      finiteNumber(settings.SEQUENCE_ADVISORY_MIN_LOAD_RATIO_REDUCTION, 0.14) * scale),
  }
end

local function sequenceAdvisoryRatio(samples, index, car)
  if settings.SEQUENCE_ADVISORY_ENABLED ~= true then return 0.0 end
  samples = samples or {}
  if #samples < 5 then return 0.0 end
  car = car or {}
  local speedKph = finiteNumber(car.current_speed_kph, 0.0)
  if speedKph < finiteNumber(settings.SEQUENCE_ADVISORY_MIN_SPEED_KPH, 60.0) then return 0.0 end

  local corneringG = math.max(0.1, finiteNumber(car.cornering_g, settings.DEFAULT_CORNERING_G))
  local thresholds = sequenceThresholds(speedKph, corneringG)
  local minCurvature = thresholds.minCurvature
  local weakSigns = {}
  local strongEnergy = 0.0
  local strongCount = 0
  local headingEnergy = 0.0
  local weakCount = 0
  local distanceAccum = 0.0
  local totalLength = estimatedTotalLength(samples)
  local anchor = samples[wrapIndex(samples, index)]
  local anchorS = finiteNumber(anchor and anchor.s, index)
  local lookaheadM = math.max(5.0, finiteNumber(settings.SEQUENCE_ADVISORY_LOOKAHEAD_M, 90.0))
  local maxSamples = math.min(#samples, math.max(5, math.floor(finiteNumber(settings.SEQUENCE_ADVISORY_MAX_SAMPLES, 96) + 0.5)))
  local weakCurvature = minCurvature * math3d.clamp(finiteNumber(settings.SEQUENCE_ADVISORY_WEAK_CURVATURE_SCALE, 0.55), 0.25, 1.0)
  local nominalSpacing = math.max(0.1, totalLength / math.max(1, #samples))
  local previousDistance = nil

  for offset = 0, maxSamples do
    local sample = samples[wrapIndex(samples, index + offset)]
    local sampleS = finiteNumber(sample and sample.s, index + offset)
    local distance = forwardDistance(anchorS, sampleS, totalLength)
    if offset > 0 and distance > lookaheadM then break end
    local ds = nominalSpacing
    if previousDistance ~= nil then ds = math.max(0.1, distance - previousDistance) end
    previousDistance = distance
    local signed = finiteNumber(sample and sample.signedCurvature, finiteNumber(sample and sample.curvature, 0.0))
    local absSigned = math.abs(signed)
    if absSigned >= weakCurvature then
      weakSigns[#weakSigns + 1] = signed >= 0 and 1 or -1
      headingEnergy = headingEnergy + absSigned * ds
      weakCount = weakCount + 1
      distanceAccum = distanceAccum + ds
    end
    if absSigned >= minCurvature then
      strongEnergy = strongEnergy + absSigned
      strongCount = strongCount + 1
    end
  end
  if weakCount < 4 then return 0.0 end

  local flips = 0
  for i = 2, #weakSigns do
    if weakSigns[i] ~= weakSigns[i - 1] then flips = flips + 1 end
  end

  local curvatureEnergy = strongCount >= 4 and (strongEnergy / strongCount) or
    (headingEnergy / math.max(nominalSpacing, distanceAccum))
  local connectedWindowM = math3d.clamp(distanceAccum, 5.0, lookaheadM)
  local connectedEnergyThreshold = thresholds.minEnergy * connectedWindowM *
    math3d.clamp(finiteNumber(settings.SEQUENCE_ADVISORY_MULTISCALE_ENERGY_MULT, 0.35), 0.10, 1.0)
  if curvatureEnergy < thresholds.minEnergy and headingEnergy < connectedEnergyThreshold then return 0.0 end

  local speedMps = speedKph / 3.6
  local lateralLoadRatio = (speedMps * speedMps * curvatureEnergy) / (corneringG * 9.80665)
  local energyRatio = math3d.clamp(headingEnergy / math.max(0.001, thresholds.minEnergy * lookaheadM), 0.0, 1.5)
  local connectedLoadRatio = lateralLoadRatio +
    energyRatio * finiteNumber(settings.SEQUENCE_ADVISORY_HEADING_LOAD_MULT, 0.10) +
    math.min(flips, 4) * finiteNumber(settings.SEQUENCE_ADVISORY_FLIP_LOAD_BONUS, 0.015)
  local advisoryLoadRatio = math.max(lateralLoadRatio, connectedLoadRatio)
  if advisoryLoadRatio < thresholds.minLoadRatio then return 0.0 end

  local yellow = finiteNumber(settings.YELLOW_RATIO, 0.14)
  local red = math.max(yellow + 0.01, finiteNumber(settings.RED_RATIO, 0.58))
  local ratio = 0.0
  if flips < 2 then
    if flips < 1 or thresholds.scale < finiteNumber(settings.SEQUENCE_ADVISORY_FLOW_MIN_SCALE, 0.65) then
      return 0.0
    end
    ratio = yellow + (advisoryLoadRatio - thresholds.minLoadRatio) *
      finiteNumber(settings.SEQUENCE_ADVISORY_FLOW_RATIO_MULT, 0.18)
  else
    ratio = yellow + (advisoryLoadRatio - thresholds.minLoadRatio) * 0.34 +
      math.max(0, flips - 2) * 0.025
  end
  return math3d.clamp(ratio, yellow, red - 0.001)
end


local function instabilityAdvisoryRatio(sample, car, context)
  if settings.SPIN_GUARD_ENABLED ~= true then return 0.0 end
  sample = sample or {}
  car = car or {}
  context = context or {}
  local speedKph = finiteNumber(car.current_speed_kph, 0.0)
  if speedKph < finiteNumber(settings.SPIN_GUARD_MIN_SPEED_KPH, 35.0) then return 0.0 end
  local curvature = math.abs(finiteNumber(sample.curvature, 0.0))
  if curvature < finiteNumber(settings.SPIN_GUARD_MIN_CURVATURE, 0.0010) then return 0.0 end

  local frontStress = finiteNumber(context.frontTyreStress, 0.0)
  local rearStress = finiteNumber(context.rearTyreStress, 0.0)
  local worstAxleStress = finiteNumber(context.worstAxleTyreStress, math.max(frontStress, rearStress))
  local slipStress = finiteNumber(context.slipStress, 0.0)
  local rearBias = math.max(0.0, rearStress - frontStress * 0.82)
  local wetLoad = math.max(
    math3d.clamp(finiteNumber(context.rainIntensity, 0.0), 0.0, 1.0) * 0.60,
    math3d.clamp(finiteNumber(context.rainWetness, 0.0), 0.0, 1.0),
    math3d.clamp(finiteNumber(context.rainWater, 0.0), 0.0, 1.0) * 1.20)
  local tractionAssist = context.tractionControlInAction == true and 1.0 or 0.0

  local stressRange = math.max(0.05, finiteNumber(settings.SPIN_GUARD_STRESS_RANGE, 0.70))
  local rearStressLoad = math3d.clamp((rearBias - finiteNumber(settings.SPIN_GUARD_REAR_STRESS_START, 0.10)) / stressRange, 0.0, 1.0)
  local slipLoad = math3d.clamp((math.max(slipStress, worstAxleStress) - finiteNumber(settings.SPIN_GUARD_SLIP_STRESS_START, 0.20)) / stressRange, 0.0, 1.0)
  local speedLoad = math3d.clamp((speedKph - 45.0) / 120.0, 0.0, 1.0)
  local curveLoad = math3d.clamp(curvature / 0.0040, 0.0, 1.0)
  local instabilityLoad = (rearStressLoad * finiteNumber(settings.SPIN_GUARD_REAR_BIAS_MULT, 0.55) +
    slipLoad * finiteNumber(settings.SPIN_GUARD_SLIP_MULT, 0.35) +
    wetLoad * finiteNumber(settings.SPIN_GUARD_WET_MULT, 0.10) +
    tractionAssist * finiteNumber(settings.SPIN_GUARD_TC_MULT, 0.12)) *
    math.max(0.25, speedLoad) * math.max(0.40, curveLoad)

  if instabilityLoad <= 0.001 then return 0.0 end
  local yellow = finiteNumber(settings.YELLOW_RATIO, 0.09)
  local red = math.max(yellow + 0.01, finiteNumber(settings.RED_RATIO, 0.50))
  local maxRatio = math.min(red - 0.001, finiteNumber(settings.SPIN_GUARD_MAX_RATIO, 0.42))
  return math3d.clamp(yellow + instabilityLoad * finiteNumber(settings.SPIN_GUARD_RATIO_MULT, 0.36), yellow, maxRatio)
end

local function dynamicConfidenceForContext(context)
  context = context or {}
  local broadConfidence = finiteNumber(context.confidence, finiteNumber(context.capabilityConfidence, 0.70))
  local brakeConfidence = finiteNumber(context.brakeGConfidence, broadConfidence)
  local corneringConfidence = finiteNumber(context.corneringGConfidence, broadConfidence)
  return math3d.clamp(math.min(broadConfidence, brakeConfidence, corneringConfidence), 0.35, 1.0)
end

local function dynamicLineScale(context)
  context = context or {}
  local baseCorneringG = math.max(0.1, finiteNumber(context.baseCorneringG, settings.DEFAULT_CORNERING_G))
  local gripScale = math3d.clamp(finiteNumber(context.corneringG, baseCorneringG) / baseCorneringG, 0.55, 1.20)
  local confidence = dynamicConfidenceForContext(context)
  local confidenceScale = 0.90 + confidence * 0.10
  return math3d.clamp(gripScale * confidenceScale,
    finiteNumber(settings.RACING_LINE_MIN_DYNAMIC_SCALE, 0.45),
    finiteNumber(settings.RACING_LINE_MAX_DYNAMIC_SCALE, 1.12))
end

local function applyDynamicLineGeometry(sample, scale)
  if not sample or not sample.centerPos or not sample.right then return end
  if settings.RACING_LINE_ENABLED ~= true then
    sample.lineOffsetScale = 0.0
    sample.dynamicLineOffsetM = 0.0
    sample.pos = sample.centerPos
    return
  end
  if sample.racingLineActive ~= true or sample.linePlacementMode ~= 'lateral_optimal' then
    sample.lineOffsetScale = 0.0
    sample.dynamicLineOffsetM = 0.0
    sample.pos = sample.centerPos
    return
  end
  local staticOffset = finiteNumber(sample.racingLineOffsetM, 0.0)
  local lateralRight = sample.centerRight or sample.right
  sample.lineOffsetScale = scale
  sample.dynamicLineOffsetM = staticOffset * scale
  sample.pos = math3d.add(sample.centerPos, math3d.mul(lateralRight, sample.dynamicLineOffsetM))
end

function M.build(samples, profile)
  local car = profile and profile.car or {}
  local baseBrakeG = math.max(0.1, finiteNumber(car.brake_decel_g, settings.DEFAULT_BRAKE_G))
  local speedAeroStrength = finiteNumber(car.speed_aero_strength, 0.0)
  for _, sample in ipairs(samples or {}) do
    sample.brakingCurvature = brakingCurvatureForSample(sample)
    sample.baseTargetSpeedKph = targetSpeedForCurvature(sample.brakingCurvature or sample.curvature or 0, car)
    sample.targetSpeedKph = sample.baseTargetSpeedKph
    sample.straightSpeedCap = speedCapTargetFor(sample.brakingCurvature or sample.curvature or 0, sample.targetSpeedKph, car.max_target_speed_kph)
    sample.baseBrakeCapacityMps2 = baseBrakeG * 9.80665
    sample.brakeCapacityMps2, sample.brakeSpeedAeroFactor =
      brakeCapacityForTarget(baseBrakeG, sample.targetSpeedKph, sample.targetSpeedKph, speedAeroStrength)
  end
  smoothBrakeTargetProfile(samples, car, { closedLoop = true })
  return samples
end

function M.refreshTargetsFromGeometry(samples, context, options)
  context = context or {}
  options = options or {}
  local car = {
    cornering_g = finiteNumber(context.corneringG, settings.DEFAULT_CORNERING_G),
    cornering_g_no_speed_aero = finiteNumber(context.corneringGNoSpeedAero, context.corneringG),
    speed_aero_strength = finiteNumber(context.speedAeroStrength, 0.0),
    brake_speed_aero_strength = finiteNumber(context.brakeSpeedAeroStrength, context.speedAeroStrength),
    brake_decel_g = finiteNumber(context.brakeG, settings.DEFAULT_BRAKE_G),
    min_corner_speed_kph = finiteNumber(context.minCornerSpeedKph, settings.MIN_CORNER_SPEED_KPH),
    max_target_speed_kph = finiteNumber(context.maxTargetSpeedKph, settings.MAX_TARGET_SPEED_KPH),
    current_speed_kph = finiteNumber(context.currentSpeedKph, 0.0),
  }
  local baseBrakeG = math.max(0.1, finiteNumber(context.brakeG, settings.DEFAULT_BRAKE_G))
  local preserveKnowledgeScale = options.preserveKnowledgeScale == true
  samples = samples or {}
  recomputeDynamicLineCurvature(samples, options.closedLoop == true)
  for _, sample in ipairs(samples) do
    sample.brakingCurvature = brakingCurvatureForSample(sample)
    sample.targetSpeedKph = targetSpeedForCurvature(sample.brakingCurvature or sample.curvature or 0, car)
    if preserveKnowledgeScale then
      local targetScale = finiteNumber(sample.knowledgeBaseTargetScale, 1.0)
      if targetScale < 0.999 and sample.targetSpeedKph < car.max_target_speed_kph - 0.25 then
        sample.targetSpeedKph = math.max(car.min_corner_speed_kph, sample.targetSpeedKph * targetScale)
      end
    end
    sample.straightSpeedCap = speedCapTargetFor(sample.brakingCurvature or sample.curvature or 0, sample.targetSpeedKph, car.max_target_speed_kph)
    sample.baseBrakeCapacityMps2 = baseBrakeG * 9.80665
    sample.brakeCapacityMps2, sample.brakeSpeedAeroFactor =
      brakeCapacityForTarget(baseBrakeG, car.current_speed_kph, sample.targetSpeedKph, car.brake_speed_aero_strength)
  end
  smoothBrakeTargetProfile(samples, car, options)
  return samples
end

function M.applyDynamic(samples, context, options)
  context = context or {}
  options = options or {}
  local sampleKnowledgeEnabled = options.knowledgeBase ~= false
  local sequenceEnabled = options.sequenceAdvisory ~= false
  local spinGuardEnabled = options.spinGuard ~= false
  local car = {
    cornering_g = finiteNumber(context.corneringG, settings.DEFAULT_CORNERING_G),
    cornering_g_no_speed_aero = finiteNumber(context.corneringGNoSpeedAero, context.corneringG),
    speed_aero_strength = finiteNumber(context.speedAeroStrength, 0.0),
    brake_speed_aero_strength = finiteNumber(context.brakeSpeedAeroStrength, context.speedAeroStrength),
    brake_decel_g = finiteNumber(context.brakeG, settings.DEFAULT_BRAKE_G),
    min_corner_speed_kph = finiteNumber(context.minCornerSpeedKph, settings.MIN_CORNER_SPEED_KPH),
    max_target_speed_kph = finiteNumber(context.maxTargetSpeedKph, settings.MAX_TARGET_SPEED_KPH),
    current_speed_kph = finiteNumber(context.currentSpeedKph, 0.0),
  }
  local baseBrakeG = math.max(0.1, finiteNumber(context.brakeG, settings.DEFAULT_BRAKE_G))
  local transferClassScale = math3d.clamp(finiteNumber(context.transferClassScale, 0.0), 0.0, 1.0)
  local cueTransferClassScale = math3d.clamp(finiteNumber(context.cueTransferClassScale, transferClassScale), 0.0, 1.0)
  local capabilityClass = tostring(context.capabilityClass or 'road')
  local lineScale = dynamicLineScale(context)
  local dynamicConfidence = dynamicConfidenceForContext(context)
  samples = samples or {}
  for _, sample in ipairs(samples) do
    applyDynamicLineGeometry(sample, lineScale)
  end
  recomputeDynamicLineCurvature(samples, options.closedLoop == true)
  for index, sample in ipairs(samples) do
    sample.brakingCurvature = brakingCurvatureForSample(sample)
    sample.baseTargetSpeedKph = sample.baseTargetSpeedKph or sample.targetSpeedKph or
      targetSpeedForCurvature(sample.brakingCurvature or sample.curvature or 0, car)
    sample.targetSpeedKph = targetSpeedForCurvature(sample.brakingCurvature or sample.curvature or 0, car)
    if sampleKnowledgeEnabled then
      local knowledgeMemory = knowledge_base.sampleRisk(context, sample)
      sample.knowledgeBaseMemoryKey = tostring(knowledgeMemory.key or '')
      sample.knowledgeBaseRisk = finiteNumber(knowledgeMemory.risk, 0.0)
      sample.knowledgeBaseConfidence = finiteNumber(knowledgeMemory.confidence, 0.0)
      sample.knowledgeBaseSource = tostring(knowledgeMemory.source or 'none')
      sample.knowledgeBaseTargetScale = finiteNumber(knowledgeMemory.targetScale, 1.0)
      if sample.knowledgeBaseTargetScale < 0.999 and sample.targetSpeedKph < car.max_target_speed_kph - 0.25 then
        sample.targetSpeedKph = math.max(car.min_corner_speed_kph, sample.targetSpeedKph * sample.knowledgeBaseTargetScale)
      end
      sample.knowledgeBaseAdvisoryRatio = finiteNumber(knowledgeMemory.advisoryRatio, 0.0)
    else
      sample.knowledgeBaseMemoryKey = ''
      sample.knowledgeBaseRisk = 0.0
      sample.knowledgeBaseConfidence = 0.0
      sample.knowledgeBaseSource = 'performance_skip'
      sample.knowledgeBaseTargetScale = 1.0
      sample.knowledgeBaseAdvisoryRatio = 0.0
    end
    sample.straightSpeedCap = speedCapTargetFor(sample.brakingCurvature or sample.curvature or 0, sample.targetSpeedKph, car.max_target_speed_kph)
    sample.baseBrakeCapacityMps2 = baseBrakeG * 9.80665
    sample.brakeCapacityMps2, sample.brakeSpeedAeroFactor =
      brakeCapacityForTarget(baseBrakeG, car.current_speed_kph, sample.targetSpeedKph, car.brake_speed_aero_strength)
    sample.transferClassScale = transferClassScale
    sample.momentTransferClassScale = math3d.clamp(finiteNumber(context.momentTransferClassScale, cueTransferClassScale), 0.0, 1.0)
    sample.brakeTransferScale = math3d.clamp(finiteNumber(context.brakeTransferScale, cueTransferClassScale), 0.0, 1.0)
    sample.aeroTransferScale = math3d.clamp(finiteNumber(context.aeroTransferScale, cueTransferClassScale), 0.0, 1.0)
    sample.cueTransferClassScale = cueTransferClassScale
    sample.capabilityClass = capabilityClass
    sample.sequenceAdvisoryRatio = sequenceEnabled and sequenceAdvisoryRatio(samples, index, car) or 0.0
    sample.instabilityAdvisoryRatio = spinGuardEnabled and instabilityAdvisoryRatio(sample, car, context) or 0.0
    sample.dynamicContextSummary = context.summary or 'dynamic_context_unavailable'
    sample.dynamicConfidence = dynamicConfidence
  end
  smoothBrakeTargetProfile(samples, car, options)
  return samples
end

M.targetSpeedForCurvature = targetSpeedForCurvature
M.dynamicLineScale = dynamicLineScale
M.speedCapTargetFor = speedCapTargetFor
M.brakeAeroFactorForTarget = brakeAeroFactorForTarget
M.brakeCapacityForTarget = brakeCapacityForTarget
M.sequenceAdvisoryRatio = sequenceAdvisoryRatio
M.instabilityAdvisoryRatio = instabilityAdvisoryRatio
M.knowledgeBaseSampleRisk = knowledge_base.sampleRisk

return M
