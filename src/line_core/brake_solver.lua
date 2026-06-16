-- DynamicRacingLine line_core/brake_solver.lua
-- Combined speed/brake profile solver for the generated path. It is intentionally
-- conservative when setup/tyre/aero data are missing instead of pretending precision.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local SurfaceHazards = require('src.line_core.surface_hazards')
local VehicleEnvelope = require('src.line_core.vehicle_envelope')
local Settings = require('src/settings')

local M = {}

local function pathCurvature(path, i)
  local n = #path
  if n < 3 then return 0 end
  local a = path[i - 1] or path[n]
  local b = path[i]
  local c = path[i + 1] or path[1]
  local ab = U.norm2(U.sub(b.world, a.world))
  local bc = U.norm2(U.sub(c.world, b.world))
  local dot = U.clamp(U.dot2(ab, bc), -1, 1)
  local crossY = ab.x * bc.z - ab.z * bc.x
  local angle = math.atan2 and math.atan2(crossY, dot) or math.atan(crossY, dot)
  local ds = math.max(0.75, (U.distance2(a.world, b.world) + U.distance2(b.world, c.world)) * 0.5)
  return angle / ds
end

local function resolveCar(car, setup, confidence)
  car = car or {}
  setup = setup or {}
  confidence = U.clamp(confidence or car.confidence or 0.45, 0, 1)

  local mu = tonumber(car.mu or car.gripMu or car.lateralGripMu) or Config.DEFAULT_MU
  local brake = tonumber(car.brakeDecelMps2 or car.brakeDecel or car.brakingPowerMps2) or Config.DEFAULT_BRAKE_DECEL_MPS2
  local traction = tonumber(car.tractionAccelMps2 or car.accelMps2) or Config.DEFAULT_TRACTION_ACCEL_MPS2
  local top = tonumber(car.topSpeedMps or car.maxSpeedMps) or Config.DEFAULT_TOP_SPEED_MPS
  local aero = tonumber(car.aeroDependency or car.aero or 0) or 0
  local fuelKg = tonumber(setup.fuelKg or setup.fuel or car.fuelKg) or 0
  local tyrePenalty = tonumber(setup.tyrePenalty or setup.pressurePenalty or 0) or 0
  local damagePenalty = tonumber(setup.damagePenalty or setup.damage or 0) or 0
  local brakePower = tonumber(setup.brakePower or setup.brake_power or 1) or 1
  local absActive = setup.absActive == true or car.absActive == true

  local massPenalty = U.clamp(fuelKg / 130.0, 0, 0.22)
  local unknownPenalty = (1.0 - confidence) * 0.10
  mu = mu * (1.0 - tyrePenalty * 0.45 - damagePenalty * 0.25 - unknownPenalty)
  brake = brake * U.clamp(brakePower, 0.72, 1.15) * (1.0 - massPenalty * 0.55 - damagePenalty * 0.25 - unknownPenalty)
  if absActive then brake = brake * 1.03 end

  return {
    mu = U.clamp(mu, 0.72, 2.45),
    brakeDecel = U.clamp(brake, 5.4, 17.5),
    tractionAccel = U.clamp(traction * (1.0 - massPenalty * 0.28), 1.8, 9.5),
    topSpeed = U.clamp(top, 38, 125),
    aero = U.clamp(aero, 0, 1.8),
    brakePowerMultiplier = U.clamp(brakePower, 0.72, 1.15),
    confidence = confidence,
  }
end

local function envelopeContext(car, setup, telemetry, confidence)
  local ctx = {}
  local function merge(source)
    if type(source) ~= 'table' then return end
    for k, v in pairs(source) do
      if ctx[k] == nil then ctx[k] = v end
    end
  end
  merge(telemetry)
  merge(setup)
  merge(car)
  ctx.confidence = confidence
  ctx.plannedBrakeInput = ctx.plannedBrakeInput or 0.74
  ctx.currentBrakeInput = nil
  ctx.liveBrakeInput = telemetry and (telemetry.currentBrakeInput or telemetry.brakeInput or telemetry.brake) or nil
  ctx.brakePowerMultiplier = ctx.brakePowerMultiplier or ctx.brakePower or ctx.brake_power or car.brakePowerMultiplier
  ctx.brakeBias = ctx.brakeBias or ctx.brakeBiasFront or car.brakeBias
  ctx.aeroDependency = ctx.aeroDependency or car.aero or car.aeroDependency
  return ctx
end

local function speedLimitFromCurvature(k, car, confidence)
  local ak = math.abs(k or 0)
  if ak < 0.0007 then return car.topSpeed end
  local aeroGain = U.clamp(car.aero * math.sqrt(ak) * 0.65, 0, 0.55)
  local effectiveMu = car.mu * (1.0 + aeroGain)
  local safety = 1.0 - (1.0 - confidence) * 0.12
  local v = math.sqrt(math.max(1.0, effectiveMu * Config.GRAVITY / ak)) * safety
  return U.clamp(v, 6.5, car.topSpeed)
end

local function frictionCircleSpeedLimit(k, car, telemetryContext, confidence, surfaceGrip)
  local ak = math.abs(k or 0)
  if ak < 0.0007 then return car.topSpeed end

  local curveCap = speedLimitFromCurvature(k, car, confidence) * math.sqrt(U.clamp(surfaceGrip or 1.0, 0.35, 1.25))
  local reserve = VehicleEnvelope.frictionCircleBrakeFactor(telemetryContext, k, curveCap)
  local safety = U.clamp(0.76 + reserve * 0.24, 0.70, 1.0)
  return U.clamp(curveCap * safety, 6.5, car.topSpeed)
end

local function referenceAuthorityWeight(referenceBrakeSpeedHints)
  referenceBrakeSpeedHints = referenceBrakeSpeedHints or {}
  local quality = referenceBrakeSpeedHints.referenceQuality or {}
  local qualityConfidence = U.clamp(
    tonumber(quality.confidence) or tonumber(referenceBrakeSpeedHints.confidence) or 0.0,
    0.0,
    1.0)
  local configured = tonumber(Settings.LINE_CORE_R02_AI_BRAKE_SPEED_REFERENCE_WEIGHT) or Config.AI_REFERENCE_MAX_WEIGHT
  local maxWeight = tonumber(Config.AI_REFERENCE_MAX_WEIGHT) or 0.34
  if referenceBrakeSpeedHints.geometryOnly == true then
    configured = math.min(configured, maxWeight)
  end
  return U.clamp(math.min(configured, maxWeight) * qualityConfidence, 0.0, maxWeight)
end

local function signedCurvatureFromFoundation(solverCurvature, referenceCurvature, referenceWeight)
  referenceWeight = U.clamp(referenceWeight or 0.0, 0.0, 1.0)
  local referenceAbs = math.abs(referenceCurvature or 0) * referenceWeight
  local foundationAbs = math.max(math.abs(solverCurvature), referenceAbs)
  if foundationAbs <= math.abs(solverCurvature) then return solverCurvature end
  if referenceCurvature and referenceCurvature ~= 0 then
    return referenceCurvature > 0 and foundationAbs or -foundationAbs
  end
  return solverCurvature >= 0 and foundationAbs or -foundationAbs
end

local function settingNumber(name, fallback)
  return tonumber(Settings and Settings[name]) or fallback
end

local function wrapIndex(index, n)
  while index < 1 do index = index + n end
  while index > n do index = index - n end
  return index
end

local function smoothBrakeRatios(raw, k, speed, target, spacing, confidence)
  local n = #raw
  local out = {}
  local yellow = math.max(0.04, settingNumber('YELLOW_RATIO', 0.09) * 0.72)
  for i = 1, n do
    local prev = raw[wrapIndex(i - 1, n)] or 0
    local curr = raw[i] or 0
    local next1 = raw[wrapIndex(i + 1, n)] or 0
    local next2 = raw[wrapIndex(i + 2, n)] or 0
    out[i] = curr * 0.52 + prev * 0.16 + next1 * 0.23 + next2 * 0.09
  end

  -- Bridge one-sample gaps inside a real brake event so colors do not flicker
  -- red/yellow/green/red across adjacent tiles.
  for i = 1, n do
    if out[i] < yellow then
      local left = out[wrapIndex(i - 1, n)] or 0
      local right = out[wrapIndex(i + 1, n)] or 0
      if left >= yellow and right >= yellow then
        out[i] = math.min(math.max(left, right), (left + right) * 0.42)
      end
    end
  end

  -- Remove single-tile noise. True braking survives because the zone classifier
  -- below sees a contiguous cluster or a high max-intensity demand.
  for i = 1, n do
    local left = math.max(out[wrapIndex(i - 1, n)] or 0, out[wrapIndex(i - 2, n)] or 0)
    local right = math.max(out[wrapIndex(i + 1, n)] or 0, out[wrapIndex(i + 2, n)] or 0)
    if out[i] < 0.22 and left < yellow and right < yellow then out[i] = 0 end
  end
  return out
end

local function straightBrakeAllowed(k, speed, target, i, spacing)
  local n = #speed
  local curveMin = math.max(0.0003, settingNumber('LINE_CORE_R02_STRAIGHT_BRAKE_CURVATURE_MIN', 0.00115))
  if math.abs(k[i] or 0) >= curveMin then return true end

  local lookahead = math.min(n - 1, math.max(3, math.floor(90.0 / math.max(1.0, spacing))))
  local minFutureSpeed = speed[i] or 0
  local maxFutureCurvature = 0.0
  for j = 1, lookahead do
    local idx = wrapIndex(i + j, n)
    minFutureSpeed = math.min(minFutureSpeed, speed[idx] or minFutureSpeed)
    maxFutureCurvature = math.max(maxFutureCurvature, math.abs(k[idx] or 0))
  end
  local speedDropKph = math.max(0.0, ((speed[i] or 0) - minFutureSpeed) * 3.6)
  local minDropKph = math.max(2.0, settingNumber('LINE_CORE_R02_MIN_BRAKE_SPEED_DROP_KPH', 10.0))
  return maxFutureCurvature >= curveMin and speedDropKph >= minDropKph
end

local function classifyBrakeZones(rawRatios, k, speed, target, spacing, confidence)
  local n = #rawRatios
  local smoothed = smoothBrakeRatios(rawRatios, k, speed, target, spacing, confidence)
  local yellow = math.max(0.04, settingNumber('YELLOW_RATIO', 0.09))
  local red = math.max(yellow + 0.05, settingNumber('RED_RATIO', 0.50))
  local minClusterM = math.max(spacing, settingNumber('LINE_CORE_R02_MIN_BRAKE_CLUSTER_M', 15.0))
  local minClusterPoints = math.max(2, math.floor(minClusterM / math.max(1.0, spacing) + 0.5))
  local ratios, meta = {}, {}
  local active = {}

  for i = 1, n do
    local allowed = straightBrakeAllowed(k, speed, target, i, spacing)
    ratios[i] = allowed and smoothed[i] or 0.0
    active[i] = ratios[i] >= yellow * 0.78
    meta[i] = {
      brakeZoneActive = false,
      brakeCueEligible = false,
      brakeZoneMaxIntensity = 0.0,
      brakeZoneId = 0,
    }
  end

  local zoneId = 0
  local i = 1
  while i <= n do
    if not active[i] then
      i = i + 1
    else
      local startIndex = i
      local maxIntensity = 0.0
      while i <= n and active[i] do
        maxIntensity = math.max(maxIntensity, ratios[i] or 0.0)
        i = i + 1
      end
      local endIndex = i - 1
      local count = endIndex - startIndex + 1
      local eligible = count >= minClusterPoints or maxIntensity >= red * 0.82
      zoneId = zoneId + 1
      for idx = startIndex, endIndex do
        if eligible then
          meta[idx].brakeZoneActive = true
          meta[idx].brakeCueEligible = true
          meta[idx].brakeZoneMaxIntensity = maxIntensity
          meta[idx].brakeZoneId = zoneId
        else
          ratios[idx] = 0.0
        end
      end
    end
  end

  -- Join a seam-split brake zone on closed tracks.
  if n > 3 and meta[1].brakeZoneActive and meta[n].brakeZoneActive then
    local maxIntensity = math.max(meta[1].brakeZoneMaxIntensity or 0, meta[n].brakeZoneMaxIntensity or 0)
    local seamZoneId = math.min(meta[1].brakeZoneId or 1, meta[n].brakeZoneId or 1)
    local idx = 1
    while idx <= n and meta[idx].brakeZoneActive do
      meta[idx].brakeZoneId = seamZoneId
      meta[idx].brakeZoneMaxIntensity = maxIntensity
      idx = idx + 1
    end
    idx = n
    while idx >= 1 and meta[idx].brakeZoneActive do
      meta[idx].brakeZoneId = seamZoneId
      meta[idx].brakeZoneMaxIntensity = maxIntensity
      idx = idx - 1
    end
  end

  return ratios, meta
end

function M.solve(path, frame, opts)
  opts = opts or {}
  local n = #path
  local result = {
    ok = false,
    reason = 'not_enough_path_points',
    points = {},
    confidence = 0,
  }
  if n < 3 then return result end

  local confidence = U.clamp(opts.confidence or 0.5, 0, 1)
  local car = resolveCar(opts.car, opts.setup, confidence)
  local telemetryContext = envelopeContext(car, opts.setup or {}, opts.telemetry or opts.context or {}, confidence)
  local spacing = math.max(0.75, frame and frame.spacing or Config.TARGET_SAMPLE_SPACING_M)
  local referenceBrakeSpeedHints = opts.referenceBrakeSpeedHints or {}
  local referenceCurvatureByIndex = referenceBrakeSpeedHints.referenceCurvatureByIndex or {}
  local referenceSpeedCapMpsByIndex = referenceBrakeSpeedHints.referenceSpeedCapMpsByIndex or {}
  local referenceHintScaleByIndex = referenceBrakeSpeedHints.referenceHintScaleByIndex or {}
  local referenceRiskByIndex = referenceBrakeSpeedHints.referenceRiskByIndex or {}
  local referenceWeight = referenceAuthorityWeight(referenceBrakeSpeedHints)
  local k = {}
  local solverCurvatureByIndex = {}
  local aiSplineReferenceCurvatureByIndex = {}
  local target = {}
  local speed = {}
  local frictionCircleSpeedCapMpsByIndex = {}
  local brakeDecelByIndex = {}
  local brakeEnvelopeByIndex = {}

  for i = 1, n do
    local solverCurvature = pathCurvature(path, i)
    local referenceCurvature = tonumber(referenceCurvatureByIndex[i]) or 0.0
    solverCurvatureByIndex[i] = solverCurvature
    aiSplineReferenceCurvatureByIndex[i] = referenceCurvature
    local foundationCurvature = signedCurvatureFromFoundation(solverCurvature, referenceCurvature, referenceWeight)
    local aiHintRisk = U.clamp(tonumber(referenceRiskByIndex[i]) or 0.0, 0.0, 1.0)
    foundationCurvature = foundationCurvature * (1.0 + aiHintRisk * 0.18)
    k[i] = foundationCurvature
    local surfaceGrip = SurfaceHazards.gripAt(opts.surfaceMap, i)
    local referenceSpeedCap = tonumber(referenceSpeedCapMpsByIndex[i])
    local referenceHintScale = U.clamp(tonumber(referenceHintScaleByIndex[i]) or 1.0, 0.50, 1.12)
    local referenceCap = referenceSpeedCap and math.min(referenceSpeedCap, car.topSpeed) or car.topSpeed
    local hintedReferenceCap = math.min(referenceCap * referenceHintScale * (1.18 + confidence * 0.12), car.topSpeed)
    local physicsCurveCap = speedLimitFromCurvature(foundationCurvature, car, confidence) * math.sqrt(surfaceGrip)
    local frictionCircleCap = frictionCircleSpeedLimit(foundationCurvature, car, telemetryContext, confidence, surfaceGrip)
    frictionCircleSpeedCapMpsByIndex[i] = frictionCircleCap
    target[i] = U.clamp(math.min(hintedReferenceCap, physicsCurveCap, frictionCircleCap), 6.5, car.topSpeed)
    speed[i] = target[i]
    brakeEnvelopeByIndex[i] = VehicleEnvelope.brakeEnvelope(telemetryContext, target[i] * 3.6, foundationCurvature, confidence)
    brakeDecelByIndex[i] = U.clamp(
      car.brakeDecel * 0.35 + (brakeEnvelopeByIndex[i].brakeDecelMps2 or car.brakeDecel) * 0.65,
      3.8,
      20.5)
  end

  -- Backward braking pass. This makes red zones appear where physics says speed must drop.
  for i = n - 1, 1, -1 do
    local maxEntry = math.sqrt(math.max(0, speed[i + 1] * speed[i + 1] + 2 * (brakeDecelByIndex[i] or car.brakeDecel) * spacing))
    speed[i] = math.min(speed[i], maxEntry, car.topSpeed)
  end
  -- Seam pass for closed loops.
  for pass = 1, 2 do
    for i = n, 1, -1 do
      local nextIndex = (i % n) + 1
      local maxEntry = math.sqrt(math.max(0, speed[nextIndex] * speed[nextIndex] + 2 * (brakeDecelByIndex[i] or car.brakeDecel) * spacing))
      speed[i] = math.min(speed[i], maxEntry, car.topSpeed)
    end
  end

  -- Forward traction pass. This gives more realistic exit speed after slow corners.
  for i = 2, n do
    local maxExit = math.sqrt(math.max(0, speed[i - 1] * speed[i - 1] + 2 * car.tractionAccel * spacing))
    speed[i] = math.min(speed[i], maxExit, target[i], car.topSpeed)
  end

  local rawBrakeRatios = {}
  local accelDemandByIndex = {}
  local throttleHintByIndex = {}
  for i = 1, n do
    local nextIndex = (i % n) + 1
    local prevIndex = i - 1; if prevIndex < 1 then prevIndex = n end
    local v = speed[i]
    local vNext = speed[nextIndex]
    local vPrev = speed[prevIndex]
    local decelDemand = math.max(0, (v * v - vNext * vNext) / (2 * spacing))
    local accelDemand = math.max(0, (v * v - vPrev * vPrev) / (2 * spacing))
    local brakeCapacityMps2 = brakeDecelByIndex[i] or car.brakeDecel
    rawBrakeRatios[i] = U.clamp(decelDemand / math.max(1, brakeCapacityMps2), 0, 1)
    accelDemandByIndex[i] = accelDemand
    throttleHintByIndex[i] = U.clamp((vNext - v) / math.max(1, car.tractionAccel), 0, 1)
  end

  local brakeRatios, brakeZoneMeta = classifyBrakeZones(rawBrakeRatios, k, speed, target, spacing, confidence)
  local points = {}
  for i = 1, n do
    local brakeIntensity = U.clamp(brakeRatios[i] or 0.0, 0, 1)
    local meta = brakeZoneMeta[i] or {}
    local brakeCapacityMps2 = brakeDecelByIndex[i] or car.brakeDecel
    local color
    if meta.brakeCueEligible ~= true then color = 'green'
    elseif brakeIntensity >= math.max(0.34, settingNumber('RED_RATIO', 0.50) * 0.72) and
        (meta.brakeZoneMaxIntensity or brakeIntensity) >= settingNumber('RED_RATIO', 0.50) then color = 'red'
    elseif brakeIntensity > 0.22 then color = 'orange'
    elseif brakeIntensity >= settingNumber('YELLOW_RATIO', 0.09) then color = 'yellow'
    else color = 'green' end

    points[i] = {
      progress = path[i].progress,
      world = path[i].world,
      offset = path[i].offset or 0,
      curvature = k[i],
      solverCurvature = solverCurvatureByIndex[i],
      referenceCurvature = aiSplineReferenceCurvatureByIndex[i],
      referenceAuthorityWeight = referenceWeight,
      brakeSpeedFoundationSource = referenceBrakeSpeedHints.source or 'ai_spline_reference',
      targetSpeedMps = target[i],
      solvedSpeedMps = speed[i],
      frictionCircleSpeedCapMps = frictionCircleSpeedCapMpsByIndex[i],
      surfaceGripFactor = SurfaceHazards.gripAt(opts.surfaceMap, i),
      brakeIntensity = brakeIntensity,
      rawBrakeIntensity = rawBrakeRatios[i] or 0.0,
      aiHintRisk = referenceRiskByIndex[i] or 0.0,
      referenceHintScale = referenceHintScaleByIndex[i] or 1.0,
      brakeZoneActive = meta.brakeZoneActive == true,
      brakeCueEligible = meta.brakeCueEligible == true,
      brakeZoneMaxIntensity = meta.brakeZoneMaxIntensity or brakeIntensity,
      brakeZoneId = meta.brakeZoneId or 0,
      throttleHint = throttleHintByIndex[i] or 0.0,
      color = color,
      tileTilt = U.clamp(brakeIntensity * 1.15, 0, 1),
      confidence = confidence,
      accelDemand = accelDemandByIndex[i] or 0.0,
      brakeCapacityMps2 = brakeCapacityMps2,
      brakeEnvelope = brakeEnvelopeByIndex[i],
      source = 'physics_brake_solver',
    }
  end

  -- Expand brake cues slightly upstream at low confidence so visible and brake windows agree.
  local marginPoints = math.floor((Config.LOW_CONFIDENCE_BRAKE_MARGIN_M * (1.0 - confidence)) / spacing)
  if marginPoints > 0 then
    for i = 1, n do
      if points[i].brakeCueEligible == true and points[i].brakeIntensity > 0.35 then
        for j = 1, marginPoints do
          local idx = i - j
          while idx < 1 do idx = idx + n end
          local fade = 1.0 - (j / (marginPoints + 1))
          points[idx].brakeIntensity = math.max(points[idx].brakeIntensity, points[i].brakeIntensity * 0.45 * fade)
          points[idx].brakeZoneActive = true
          points[idx].brakeCueEligible = true
          points[idx].brakeZoneMaxIntensity = math.max(points[idx].brakeZoneMaxIntensity or 0.0, points[i].brakeZoneMaxIntensity or points[i].brakeIntensity)
          points[idx].brakeZoneId = points[i].brakeZoneId or points[idx].brakeZoneId
          if points[idx].brakeIntensity > 0.25 then points[idx].color = 'yellow' end
          if points[idx].brakeIntensity > 0.55 then points[idx].color = 'orange' end
          points[idx].tileTilt = math.max(points[idx].tileTilt, points[idx].brakeIntensity)
        end
      end
    end
  end

  return {
    ok = true,
    reason = 'speed_and_brake_profile_solved',
    points = points,
    carModel = car,
    brakeDecelByIndex = brakeDecelByIndex,
    brakeEnvelopeByIndex = brakeEnvelopeByIndex,
    solverCurvatureByIndex = solverCurvatureByIndex,
    referenceCurvatureByIndex = aiSplineReferenceCurvatureByIndex,
    referenceSpeedCapMpsByIndex = referenceSpeedCapMpsByIndex,
    frictionCircleSpeedCapMpsByIndex = frictionCircleSpeedCapMpsByIndex,
    referenceHintScaleByIndex = referenceHintScaleByIndex,
    referenceRiskByIndex = referenceRiskByIndex,
    referenceAuthorityWeight = referenceWeight,
    brakeSpeedFoundationSource = referenceBrakeSpeedHints.source or 'ai_spline_reference',
    confidence = confidence,
  }
end

return M
