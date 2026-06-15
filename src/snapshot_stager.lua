local settings = require('src/settings')

local M = {}
local stagedBySession = {}

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

local function nowStamp()
  local ok, value = pcall(function() return os.time() end)
  return ok and value or 0
end

local function sessionKey(session)
  return tostring(session and session.track_id or '') .. ':' ..
    tostring(session and session.layout_id or '') .. ':' ..
    tostring(session and session.car_id or '') .. ':' ..
    tostring(session and session.setup_hash or '')
end

local function confidenceCap(context)
  context = context or {}
  local live = finiteNumber(context.liveGripEnvelopeConfidence, 0.0)
  local base = finiteNumber(context.confidence, 0.50)
  local sampleAge = finiteNumber(context.runtimeSeconds, finiteNumber(context.sessionTimeS, 0.0))
  local cap = math.min(base, 0.58 + live * 0.24)
  if sampleAge > 180.0 then cap = cap + 0.08 end
  return clamp(cap, 0.18, 0.82)
end

function M.stageRuntimeProfiles(session, car, runtimeProfile, context)
  session = session or {}
  car = car or {}
  runtimeProfile = runtimeProfile or {}
  context = context or {}
  local carProfile = runtimeProfile.car or {}
  local trackProfile = runtimeProfile.track or {}
  local cap = confidenceCap(context)
  local stabilityWindow = math.max(2, math.floor(finiteNumber(settings.RUNTIME_SNAPSHOT_STABILITY_WINDOW, 4) + 0.5))
  local doNotOverwriteCurated = tostring(carProfile.source or '') ~= 'runtime_snapshot' and finiteNumber(carProfile.confidence, 0.0) >= cap
  local payload = {
    source = 'runtime_snapshot_hint',
    runtime_snapshot_hint = true,
    generated_at = nowStamp(),
    stabilityWindow = stabilityWindow,
    confidenceCap = cap,
    doNotOverwriteCurated = doNotOverwriteCurated,
    car = {
      id = session.car_id,
      car_id = session.car_id,
      name = session.car_id,
      setup_hash = session.setup_hash,
      brake_decel_g = finiteNumber(context.brakeG, finiteNumber(carProfile.brake_decel_g, 1.15)),
      brake_g = finiteNumber(context.brakeG, finiteNumber(carProfile.brake_decel_g, 1.15)),
      cornering_g = finiteNumber(context.corneringG, finiteNumber(carProfile.cornering_g, 1.20)),
      speed_aero_strength = finiteNumber(context.speedAeroStrength, finiteNumber(carProfile.speed_aero_strength, 0.0)),
      brakeSpeedAeroStrength = finiteNumber(context.brakeSpeedAeroStrength, finiteNumber(carProfile.brake_speed_aero_strength, 0.0)),
      brakePowerMult = finiteNumber(context.brakePowerMult, finiteNumber(car.brakePowerMult, 1.0)),
      brakeBias = finiteNumber(context.brakeBias, finiteNumber(car.brakeBias, 0.0)),
      physicsTyreBrakeLoadSensitivityFactor = finiteNumber(context.physicsTyreBrakeLoadSensitivityFactor,
        finiteNumber(carProfile.physics_tyre_brake_load_sensitivity_factor, 1.0)),
      confidence = cap,
    },
    track = {
      id = session.track_id,
      track_id = session.track_id,
      layout_id = session.layout_id,
      name = session.track_id,
      surface_grip_hint = finiteNumber(context.surfaceGrip, finiteNumber(trackProfile.surface_grip_hint, 1.0)),
      road_grip = finiteNumber(context.roadGrip, finiteNumber(trackProfile.road_grip, 1.0)),
      track_thermal_brake_factor = finiteNumber(context.trackThermalBrakeFactor, 1.0),
      rainIntensity = finiteNumber(context.rainIntensity, 0.0),
      rainWetness = finiteNumber(context.rainWetness, 0.0),
      grip_risk = finiteNumber(context.knowledgeBaseTrackRisk, finiteNumber(trackProfile.grip_risk, 0.0)),
      confidence = cap,
    },
  }
  local key = sessionKey(session)
  local state = stagedBySession[key] or { count = 0, lastBrakeG = nil, lastCorneringG = nil }
  local brakeDelta = state.lastBrakeG and math.abs(state.lastBrakeG - payload.car.brake_decel_g) or 0.0
  local cornerDelta = state.lastCorneringG and math.abs(state.lastCorneringG - payload.car.cornering_g) or 0.0
  if brakeDelta < 0.18 and cornerDelta < 0.18 then
    state.count = state.count + 1
  else
    state.count = 1
  end
  state.lastBrakeG = payload.car.brake_decel_g
  state.lastCorneringG = payload.car.cornering_g
  state.payload = payload
  stagedBySession[key] = state
  payload.stableSamples = state.count
  return payload
end

function M.promoteIfStable(session, staged, context)
  staged = staged or stagedBySession[sessionKey(session)] and stagedBySession[sessionKey(session)].payload
  if type(staged) ~= 'table' then return nil, 'missing_staged_snapshot' end
  local stableSamples = finiteNumber(staged.stableSamples, 0.0)
  local stabilityWindow = finiteNumber(staged.stabilityWindow, 4.0)
  if stableSamples < stabilityWindow then return nil, 'stabilityWindow' end
  if staged.doNotOverwriteCurated == true then return nil, 'doNotOverwriteCurated' end
  local confidenceCapValue = confidenceCap(context or {})
  staged.car.source = 'runtime_snapshot_promoted'
  staged.car.confidence = math.min(finiteNumber(staged.car.confidence, 0.0), confidenceCapValue)
  staged.track.source = 'runtime_snapshot_promoted'
  staged.track.confidence = math.min(finiteNumber(staged.track.confidence, 0.0), confidenceCapValue)
  return {
    car = staged.car,
    track = staged.track,
    confidenceCap = confidenceCapValue,
  }, 'promoted'
end

return M
