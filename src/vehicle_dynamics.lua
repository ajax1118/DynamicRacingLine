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

local function gripBase(context)
  context = context or {}
  local roadGrip = clamp(finiteNumber(context.roadGrip, 1.0), 0.45, 1.30)
  local surfaceGrip = clamp(finiteNumber(context.surfaceGrip, 1.0), 0.45, 1.30)
  local tyreFactor = clamp(finiteNumber(context.tyreFactor, 1.0), 0.55, 1.18)
  local wetFactor = clamp(finiteNumber(context.wetFactor, 1.0), 0.45, 1.0)
  local trackThermalBrakeFactor = clamp(finiteNumber(context.trackThermalBrakeFactor, 1.0), 0.70, 1.12)
  local pressurePenalty = clamp(finiteNumber(context.pressurePenalty, 0.0), 0.0, 0.35)
  local liveGripEnvelopePenalty = clamp(finiteNumber(context.liveGripEnvelopePenalty, 0.0), 0.0, 0.35)
  local dirtyPenalty = clamp(finiteNumber(context.tyreDirty, 0.0) * 0.06, 0.0, 0.12)
  return roadGrip * surfaceGrip * tyreFactor * wetFactor * trackThermalBrakeFactor *
    (1.0 - pressurePenalty) * (1.0 - liveGripEnvelopePenalty) * (1.0 - dirtyPenalty)
end

local function absEfficiency(context)
  context = context or {}
  local brakeLimitState = tostring(context.brakeLimitState or '')
  local absActive = context.absActive == true or context.absInAction == true or context.tractionControlInAction == true
  local absSetting = finiteNumber(context.abs, finiteNumber(context.absLevel, 0.0))
  if brakeLimitState == 'lockup' then return absActive and 0.88 or 0.74 end
  if absActive then return 0.95 end
  if absSetting > 0 then return 0.97 end
  return 0.92
end

local function brakeTempFactor(context)
  context = context or {}
  local temp = finiteNumber(context.brakeTemperature,
    finiteNumber(context.brakeTempC, finiteNumber(context.frontBrakeTempC, 0.0)))
  if temp <= 0.0 then return 1.0 end
  local coldPenalty = temp < 180.0 and clamp((180.0 - temp) / 260.0, 0.0, 0.22) or 0.0
  local hotPenalty = temp > 720.0 and clamp((temp - 720.0) / 520.0, 0.0, 0.30) or 0.0
  return clamp(1.0 - coldPenalty - hotPenalty, 0.62, 1.06)
end

local function tyreSlipCurve(context, axle, slipDemand)
  context = context or {}
  local axleName = tostring(axle or 'front')
  local stress = axleName == 'rear' and finiteNumber(context.rearTyreStress, 0.0) or finiteNumber(context.frontTyreStress, 0.0)
  local slipStress = math.max(stress, finiteNumber(context.slipStress, 0.0))
  local demand = clamp(finiteNumber(slipDemand, 0.0), 0.0, 1.6)
  local peak = 1.0 - clamp(math.max(0.0, demand - 0.88) * 0.28, 0.0, 0.22)
  local stressLoss = clamp(slipStress * 0.12, 0.0, 0.18)
  return clamp(peak - stressLoss, 0.58, 1.05)
end

local function loadScale(context)
  context = context or {}
  local fuelMassRatio = clamp(finiteNumber(context.fuelMassRatio, 0.0), 0.0, 1.6)
  local ballastKg = math.max(0.0, finiteNumber(context.ballastKg, 0.0))
  local ballastPenalty = clamp(ballastKg / 300.0 * 0.08, 0.0, 0.12)
  local fuelPenalty = clamp(fuelMassRatio * finiteNumber(settings.FUEL_MASS_BRAKE_PENALTY_MULT, 0.28), 0.0, 0.24)
  return clamp(1.0 - fuelPenalty - ballastPenalty, 0.58, 1.0)
end

local function weightTransfer(context, speedKph)
  context = context or {}
  local speed = math.max(0.0, finiteNumber(speedKph, 0.0))
  local brakeInput = clamp(finiteNumber(context.currentBrakeInput, finiteNumber(context.brakeInput, 0.55)), 0.0, 1.0)
  local massFactor = clamp(1.0 - finiteNumber(context.fuelMassRatio, 0.0) * 0.08, 0.84, 1.04)
  local transfer = clamp(0.50 + brakeInput * 0.22 + clamp(speed / 280.0, 0.0, 1.0) * 0.04, 0.48, 0.78)
  local rear = clamp(1.0 - transfer + 0.52, 0.50, 1.10)
  return {
    frontLoad = clamp(transfer * massFactor, 0.45, 0.86),
    rearLoad = rear,
    brakeInput = brakeInput,
  }
end

local function trailBrakeFactor(context)
  context = context or {}
  local steer = math.abs(finiteNumber(context.steerAngle, finiteNumber(context.steeringAngle, 0.0)))
  local curvature = math.abs(finiteNumber(context.lineSignedCurvature,
    finiteNumber(context.signedCurvature, finiteNumber(context.currentCurvature, 0.0))))
  local lateralStress = math.max(finiteNumber(context.frontTyreStress, 0.0), finiteNumber(context.rearTyreStress, 0.0))
  local steerDemand = clamp(steer / 22.0 + curvature / 0.012, 0.0, 1.0)
  return clamp(1.0 - steerDemand * 0.18 - lateralStress * 0.08, 0.68, 1.0)
end

local function aeroBalance(context, speedKph)
  context = context or {}
  local speed = math.max(0.0, finiteNumber(speedKph, 0.0))
  local strength = clamp(finiteNumber(context.brakeSpeedAeroStrength,
    finiteNumber(context.speedAeroStrength, 0.0)), 0.0, 0.85)
  local balance = clamp(finiteNumber(context.aeroBalance, finiteNumber(context.brakeAeroBalance, 0.52)), 0.35, 0.68)
  local speedScale = clamp(speed / 280.0, 0.0, 1.45)
  local aeroLoad = strength * speedScale * speedScale
  return {
    frontAero = clamp(1.0 + aeroLoad * balance, 1.0, 1.46),
    rearAero = clamp(1.0 + aeroLoad * (1.0 - balance), 1.0, 1.34),
    balance = balance,
    strength = strength,
  }
end

local function combinedLongitudinalLimit(frontAxleGrip, rearAxleGrip, context, confidence)
  context = context or {}
  local uncertainty = 1.0 - clamp(finiteNumber(confidence, finiteNumber(context.confidence, 0.62)), 0.0, 1.0)
  local front = math.max(0.1, finiteNumber(frontAxleGrip, 1.0))
  local rear = math.max(0.1, finiteNumber(rearAxleGrip, 1.0))
  local split = clamp(finiteNumber(context.brakeBias, finiteNumber(context.brakeBiasFront, 0.60)), 0.46, 0.74)
  local axleLimit = math.min(front / math.max(split, 0.01), rear / math.max(1.0 - split, 0.01))
  local blended = front * split + rear * (1.0 - split)
  return clamp(math.min(blended, axleLimit) * (1.0 - uncertainty * 0.08), 0.42, 1.65)
end

function M.brakeEnvelope(context, speedKph, confidence)
  context = context or {}
  local grip = gripBase(context) * loadScale(context) * brakeTempFactor(context)
  local transfer = weightTransfer(context, speedKph)
  local aero = aeroBalance(context, speedKph)
  local abs = absEfficiency(context)
  local trail = trailBrakeFactor(context)
  local frontSlip = tyreSlipCurve(context, 'front', transfer.brakeInput)
  local rearSlip = tyreSlipCurve(context, 'rear', transfer.brakeInput * 0.82)
  local frontAxleGrip = grip * aero.frontAero * (0.72 + transfer.frontLoad * 0.48) * frontSlip
  local rearAxleGrip = grip * aero.rearAero * (0.78 + transfer.rearLoad * 0.24) * rearSlip
  local limit = combinedLongitudinalLimit(frontAxleGrip, rearAxleGrip, context, confidence) * abs * trail
  return {
    absEfficiency = abs,
    brakeTempFactor = brakeTempFactor(context),
    tyreSlipCurve = math.min(frontSlip, rearSlip),
    weightTransfer = transfer,
    trailBrakeFactor = trail,
    aeroBalance = aero,
    frontAxleGrip = frontAxleGrip,
    rearAxleGrip = rearAxleGrip,
    combinedLongitudinalLimit = clamp(limit, 0.38, 1.70),
  }
end

return M
