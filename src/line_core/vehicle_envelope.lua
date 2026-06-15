-- DynamicRacingLine line_core/vehicle_envelope.lua
-- Speed-dependent brake/grip envelope for R02 guidance. This stays pure Lua so the
-- solver can run even when AC/CSP physics fields are incomplete.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')

local M = {}

local function n(value, fallback)
  value = tonumber(value)
  if value == nil or value ~= value or value == math.huge or value == -math.huge then return fallback end
  return value
end

local function readAny(t, names, fallback)
  t = t or {}
  for _, key in ipairs(names) do
    if t[key] ~= nil then return t[key] end
  end
  return fallback
end

local function gripBase(context)
  context = context or {}
  local roadGrip = U.clamp(n(readAny(context, { 'roadGrip', 'trackGrip', 'grip' }, 1.0), 1.0), 0.45, 1.30)
  local surfaceGrip = U.clamp(n(readAny(context, { 'surfaceGrip', 'surfaceGripFactor' }, 1.0), 1.0), 0.40, 1.30)
  local tyreFactor = U.clamp(n(readAny(context, { 'tyreFactor', 'tireFactor' }, 1.0), 1.0), 0.55, 1.18)
  local wetFactor = U.clamp(n(readAny(context, { 'wetFactor' }, 1.0), 1.0), 0.45, 1.0)
  local wetness = U.clamp(n(readAny(context, { 'wetness', 'rain', 'rainWetness', 'rainWater' }, 0.0), 0.0), 0.0, 1.0)
  local thermal = U.clamp(n(readAny(context, { 'trackThermalBrakeFactor' }, 1.0), 1.0), 0.70, 1.12)
  local pressurePenalty = U.clamp(n(readAny(context, { 'pressurePenalty' }, 0.0), 0.0), 0.0, 0.35)
  local dirtyPenalty = U.clamp(n(readAny(context, { 'tyreDirty', 'tireDirty' }, 0.0), 0.0) * 0.08, 0.0, 0.16)
  return roadGrip * surfaceGrip * tyreFactor * wetFactor * (1.0 - wetness * 0.20) *
    thermal * (1.0 - pressurePenalty) * (1.0 - dirtyPenalty)
end

function M.absEfficiency(context)
  context = context or {}
  local state = tostring(context.brakeLimitState or '')
  local absActive = context.absActive == true or context.absInAction == true
  local absSetting = n(readAny(context, { 'abs', 'absLevel' }, 0.0), 0.0)
  if state == 'lockup' then return absActive and 0.88 or 0.72 end
  if absActive then return 0.95 end
  if absSetting > 0 then return 0.97 end
  return 0.91
end

function M.brakeTempFactor(context)
  context = context or {}
  local temp = n(readAny(context, { 'brakeTemperature', 'brakeTempC', 'frontBrakeTempC' }, 0.0), 0.0)
  if temp <= 0 then return 1.0 end
  local cold = temp < 180.0 and U.clamp((180.0 - temp) / 260.0, 0.0, 0.22) or 0.0
  local hot = temp > 720.0 and U.clamp((temp - 720.0) / 520.0, 0.0, 0.30) or 0.0
  return U.clamp(1.0 - cold - hot, 0.62, 1.06)
end

function M.tyreSlipCurve(context, axle, slipDemand)
  context = context or {}
  local axleName = tostring(axle or 'front')
  local axleStress = axleName == 'rear' and n(context.rearTyreStress, 0.0) or n(context.frontTyreStress, 0.0)
  local slipStress = math.max(axleStress, n(context.slipStress, 0.0))
  local demand = U.clamp(n(slipDemand, 0.0), 0.0, 1.6)
  local peakLoss = U.clamp(math.max(0.0, demand - 0.88) * 0.28, 0.0, 0.22)
  local stressLoss = U.clamp(slipStress * 0.12, 0.0, 0.18)
  return U.clamp(1.0 - peakLoss - stressLoss, 0.58, 1.05)
end

function M.weightTransfer(context, speedKph)
  context = context or {}
  local speed = math.max(0.0, n(speedKph, 0.0))
  local brakeInput = U.clamp(n(readAny(context, { 'plannedBrakeInput', 'nominalBrakeInput', 'currentBrakeInput', 'brakeInput', 'brake' }, 0.55), 0.55), 0.0, 1.0)
  local fuelMassRatio = U.clamp(n(context.fuelMassRatio, 0.0), 0.0, 1.6)
  local massFactor = U.clamp(1.0 - fuelMassRatio * 0.08, 0.84, 1.04)
  local transfer = U.clamp(0.50 + brakeInput * 0.22 + U.clamp(speed / 280.0, 0.0, 1.0) * 0.04, 0.48, 0.78)
  return {
    frontLoad = U.clamp(transfer * massFactor, 0.45, 0.86),
    rearLoad = U.clamp(1.0 - transfer + 0.52, 0.50, 1.10),
    brakeInput = brakeInput,
  }
end

function M.trailBrakeFactor(context, curvature)
  context = context or {}
  local steer = math.abs(n(readAny(context, { 'steerAngle', 'steeringAngle' }, 0.0), 0.0))
  local k = math.abs(n(curvature, n(readAny(context, { 'lineSignedCurvature', 'signedCurvature', 'currentCurvature' }, 0.0), 0.0)))
  local lateralStress = math.max(n(context.frontTyreStress, 0.0), n(context.rearTyreStress, 0.0))
  local demand = U.clamp(steer / 22.0 + k / 0.012, 0.0, 1.0)
  return U.clamp(1.0 - demand * 0.18 - lateralStress * 0.08, 0.68, 1.0)
end

function M.aeroBalance(context, speedKph)
  context = context or {}
  local speed = math.max(0.0, n(speedKph, 0.0))
  local strength = U.clamp(n(readAny(context, { 'brakeSpeedAeroStrength', 'speedAeroStrength', 'aeroDependency' }, 0.0), 0.0), 0.0, 0.95)
  local balance = U.clamp(n(readAny(context, { 'aeroBalance', 'brakeAeroBalance' }, 0.52), 0.52), 0.35, 0.68)
  local scale = U.clamp(speed / 280.0, 0.0, 1.45)
  local aeroLoad = strength * scale * scale
  return {
    frontAero = U.clamp(1.0 + aeroLoad * balance, 1.0, 1.55),
    rearAero = U.clamp(1.0 + aeroLoad * (1.0 - balance), 1.0, 1.40),
    balance = balance,
    strength = strength,
  }
end

function M.frictionCircleBrakeFactor(context, curvature, speedMps)
  context = context or {}
  local k = math.abs(n(curvature, 0.0))
  local speed = math.max(0.0, n(speedMps, 0.0))
  local lateralG = (speed * speed * k) / Config.GRAVITY
  local limitG = math.max(0.35, n(readAny(context, { 'corneringG', 'lateralG', 'maxLateralG' }, 1.25), 1.25))
  local usage = U.clamp(lateralG / limitG, 0.0, 0.96)
  return U.clamp(math.sqrt(math.max(0.0, 1.0 - usage * usage)), 0.34, 1.0)
end

function M.combinedLongitudinalLimit(frontAxleGrip, rearAxleGrip, context, confidence)
  context = context or {}
  local uncertainty = 1.0 - U.clamp(n(confidence, n(context.confidence, 0.62)), 0.0, 1.0)
  local front = math.max(0.1, n(frontAxleGrip, 1.0))
  local rear = math.max(0.1, n(rearAxleGrip, 1.0))
  local split = U.clamp(n(readAny(context, { 'brakeBias', 'brakeBiasFront' }, 0.60), 0.60), 0.46, 0.74)
  local axleLimit = math.min(front / math.max(split, 0.01), rear / math.max(1.0 - split, 0.01))
  local blended = front * split + rear * (1.0 - split)
  return U.clamp(math.min(blended, axleLimit) * (1.0 - uncertainty * 0.10), 0.36, 1.72)
end

function M.brakeEnvelope(context, speedKph, curvature, confidence)
  context = context or {}
  local speedMps = math.max(0.0, n(speedKph, 0.0) / 3.6)
  local grip = gripBase(context) * M.brakeTempFactor(context)
  local transfer = M.weightTransfer(context, speedKph)
  local aero = M.aeroBalance(context, speedKph)
  local frontSlip = M.tyreSlipCurve(context, 'front', transfer.brakeInput)
  local rearSlip = M.tyreSlipCurve(context, 'rear', transfer.brakeInput * 0.82)
  local frontAxleGrip = grip * aero.frontAero * (0.72 + transfer.frontLoad * 0.48) * frontSlip
  local rearAxleGrip = grip * aero.rearAero * (0.78 + transfer.rearLoad * 0.24) * rearSlip
  local combinedLongitudinalLimit = M.combinedLongitudinalLimit(frontAxleGrip, rearAxleGrip, context, confidence)
  local absEfficiency = M.absEfficiency(context)
  local trailBrakeFactor = M.trailBrakeFactor(context, curvature)
  local frictionCircleBrakeFactor = M.frictionCircleBrakeFactor(context, curvature, speedMps)
  local limit = combinedLongitudinalLimit * absEfficiency * trailBrakeFactor * frictionCircleBrakeFactor
  local brakePower = U.clamp(n(readAny(context, { 'brakePowerMultiplier', 'brakePower', 'brake_power' }, 1.0), 1.0), 0.70, 1.18)
  local brakeDecelMps2 = U.clamp(limit * Config.GRAVITY * brakePower, 3.6, 19.5)
  return {
    absEfficiency = absEfficiency,
    brakeTempFactor = M.brakeTempFactor(context),
    tyreSlipCurve = math.min(frontSlip, rearSlip),
    weightTransfer = transfer,
    trailBrakeFactor = trailBrakeFactor,
    aeroBalance = aero,
    frontAxleGrip = frontAxleGrip,
    rearAxleGrip = rearAxleGrip,
    combinedLongitudinalLimit = combinedLongitudinalLimit,
    frictionCircleBrakeFactor = frictionCircleBrakeFactor,
    brakeDecelMps2 = brakeDecelMps2,
  }
end

return M
