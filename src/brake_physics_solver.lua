local settings = require('src/settings')
local vehicle_dynamics = require('src/vehicle_dynamics')

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

local function frictionScale(context)
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

local function mechanicalScale(context)
  context = context or {}
  local brakePowerMult = clamp(finiteNumber(context.brakePowerMult, 1.0), 0.55, 1.35)
  local brakeBiasBrakeFactor = clamp(finiteNumber(context.brakeBiasBrakeFactor, 1.0), 0.76, 1.08)
  local damageBrakeFactor = clamp(finiteNumber(context.damageBrakeFactor, 1.0), 0.40, 1.0)
  local brakeAssistPenalty = clamp(finiteNumber(context.brakeAssistPenalty, 0.0), 0.0, 0.28)
  local setupRisk = clamp(math.max(
    finiteNumber(context.setupMechanicalRisk, 0.0),
    finiteNumber(context.setupAeroRisk, 0.0)), 0.0, 1.0)
  return brakePowerMult * brakeBiasBrakeFactor * damageBrakeFactor * (1.0 - brakeAssistPenalty) *
    (1.0 - setupRisk * 0.08)
end

local function loadScale(context)
  context = context or {}
  local fuelMassRatio = clamp(finiteNumber(context.fuelMassRatio, 0.0), 0.0, 1.6)
  local ballastKg = math.max(0.0, finiteNumber(context.ballastKg, 0.0))
  local ballastPenalty = clamp(ballastKg / 300.0 * 0.08, 0.0, 0.12)
  local fuelPenalty = clamp(fuelMassRatio * finiteNumber(settings.FUEL_MASS_BRAKE_PENALTY_MULT, 0.28), 0.0, 0.24)
  return clamp(1.0 - fuelPenalty - ballastPenalty, 0.58, 1.0)
end

local function aeroScale(context, speedKph)
  context = context or {}
  local speed = math.max(0.0, finiteNumber(speedKph, 0.0))
  local brakeSpeedAeroStrength = clamp(finiteNumber(context.brakeSpeedAeroStrength,
    finiteNumber(context.speedAeroStrength, 0.0)), 0.0, 0.85)
  local brakeSpeedAeroFactor = clamp(finiteNumber(context.brakeSpeedAeroFactor, 1.0), 0.80, 1.45)
  local normalizedSpeed = clamp(speed / 280.0, 0.0, 1.45)
  return clamp(1.0 + brakeSpeedAeroStrength * normalizedSpeed * normalizedSpeed, 1.0, 1.55) *
    brakeSpeedAeroFactor
end

local function tyreLoadScale(context)
  context = context or {}
  local physicsTyreBrakeLoadSensitivityFactor = clamp(finiteNumber(context.physicsTyreBrakeLoadSensitivityFactor,
    finiteNumber(context.physicsTyreLoadSensitivityFactor, 1.0)), 0.72, 1.12)
  local frontStress = clamp(finiteNumber(context.frontTyreStress, 0.0), 0.0, 1.0)
  local rearStress = clamp(finiteNumber(context.rearTyreStress, 0.0), 0.0, 1.0)
  local brakeLimitState = tostring(context.brakeLimitState or '')
  local lockupPenalty = brakeLimitState == 'lockup' and 0.12 or 0.0
  local stressPenalty = math.max(frontStress, rearStress) * 0.10
  return physicsTyreBrakeLoadSensitivityFactor * (1.0 - stressPenalty - lockupPenalty)
end

function M.capacity(context, speedKph, confidence)
  context = context or {}
  local baseBrakeG = math.max(0.20, finiteNumber(context.brakeG, settings.DEFAULT_BRAKE_G))
  local uncertainty = 1.0 - clamp(finiteNumber(confidence, finiteNumber(context.confidence, 0.62)), 0.0, 1.0)
  local envelope = vehicle_dynamics.brakeEnvelope(context, speedKph, confidence)
  local scale = mechanicalScale(context) * tyreLoadScale(context) * finiteNumber(envelope.combinedLongitudinalLimit, 1.0)
  scale = scale * (1.0 - uncertainty * 0.08)
  local capacity = math.max(0.8, baseBrakeG * scale * 9.80665)
  return capacity, {
    source = 'physics_solver',
    baseBrakeG = baseBrakeG,
    scale = scale,
    uncertainty = uncertainty,
    envelope = envelope,
  }
end

function M.brakeDistance(speedKph, targetKph, context, confidence)
  local current = math.max(0.0, finiteNumber(speedKph, 0.0) / 3.6)
  local target = math.max(0.0, finiteNumber(targetKph, 0.0) / 3.6)
  if current <= target + 0.1 then return 0.0, { source = 'physics_solver', capacityMps2 = 0.0 } end
  local steps = math.max(4, math.floor(finiteNumber(settings.BRAKE_SOLVER_STEPS, 10) + 0.5))
  local totalDistance = 0.0
  local speedHi = current
  local minCapacity = math.huge
  for step = 1, steps do
    local speedLo = target + (current - target) * (steps - step) / steps
    local avgSpeed = (speedHi + speedLo) * 0.5
    local capacity = M.capacity(context, avgSpeed * 3.6, confidence)
    minCapacity = math.min(minCapacity, capacity)
    totalDistance = totalDistance + math.max(0.0, (speedHi * speedHi - speedLo * speedLo) / (2.0 * capacity))
    speedHi = speedLo
  end
  local uncertainty = 1.0 - clamp(finiteNumber(confidence, finiteNumber(context and context.confidence, 0.62)), 0.0, 1.0)
  local reaction = math.max(0.08, finiteNumber(settings.BRAKE_REACTION_TIME_S, 0.45) + uncertainty * 0.10)
  local margin = math.max(2.0, finiteNumber(settings.BRAKE_DISTANCE_MARGIN_M, 14.0) + uncertainty * 8.0)
  local safety = math.max(1.0, finiteNumber(settings.BRAKE_SOLVER_SAFETY_MULT, 1.12))
  return totalDistance * safety + current * reaction + margin, {
    source = 'physics_solver',
    capacityMps2 = minCapacity < math.huge and minCapacity or 0.0,
    reactionS = reaction,
    marginM = margin,
  }
end

function M.allowedSpeed(targetKph, distanceToTargetM, context, confidence)
  local target = math.max(0.0, finiteNumber(targetKph, 0.0))
  local distance = math.max(0.0, finiteNumber(distanceToTargetM, 0.0))
  local lo = target
  local hi = math.max(target, finiteNumber(context and context.maxTargetSpeedKph, settings.MAX_TARGET_SPEED_KPH))
  for _ = 1, 14 do
    local mid = (lo + hi) * 0.5
    local required = M.brakeDistance(mid, target, context, confidence)
    if required <= distance then
      lo = mid
    else
      hi = mid
    end
  end
  return lo
end

function M.brakePoint(apexDistanceM, speedKph, targetKph, context, confidence)
  local distance = M.brakeDistance(speedKph, targetKph, context, confidence)
  return finiteNumber(apexDistanceM, 0.0) - distance, distance
end

return M
