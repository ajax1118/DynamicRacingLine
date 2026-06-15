-- DynamicRacingLine line_core/dynamic_context.lua
-- R02: fine-grained runtime context, setup hashing, cache invalidation, and default-profile confidence penalties.
-- Runtime snapshots are treated as hints unless values are explicitly measured/high-confidence.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local Profiles = require('src.line_core.profile_resolver')

local M = {}

local function bucketNumber(v, step, fallback)
  v = tonumber(v)
  if v == nil then return fallback or 'na' end
  step = step or 1
  return string.format('%.3f', math.floor(v / step + 0.5) * step)
end

local function boolish(v)
  if v == true then return '1' end
  if v == false then return '0' end
  if v == nil then return 'na' end
  return tostring(v)
end

local function readAny(t, names)
  t = t or {}
  for _, k in ipairs(names) do
    local v = t[k]
    if v ~= nil then return v end
  end
  return nil
end

local function append(parts, key, value)
  if value ~= nil then parts[#parts + 1] = key .. '=' .. tostring(value) end
end

function M.setupFingerprint(setup, telemetry)
  setup = setup or {}
  telemetry = telemetry or {}
  local parts = {}
  append(parts, 'tyreCompound', readAny(setup, {'tyreCompound','compound','tyres','tireCompound'}))
  append(parts, 'fuelKg', bucketNumber(readAny(setup, {'fuelKg','fuel','fuelLoadKg'}) or readAny(telemetry, {'fuelKg','fuel'}), 1.0))
  append(parts, 'ballast', bucketNumber(readAny(setup, {'ballast','ballastKg'}), 1.0))
  append(parts, 'restrictor', bucketNumber(readAny(setup, {'restrictor','restrictorPct'}), 0.5))
  append(parts, 'brakePower', bucketNumber(readAny(setup, {'brakePower','brake_power','brakePowerMult'}), 0.005))
  append(parts, 'brakeBias', bucketNumber(readAny(setup, {'brakeBias','brake_bias','brakeBiasPct'}), 0.0025))
  append(parts, 'frontWing', bucketNumber(readAny(setup, {'frontWing','front_wing','fw'}), 0.25))
  append(parts, 'rearWing', bucketNumber(readAny(setup, {'rearWing','rear_wing','rw','wing'}), 0.25))
  append(parts, 'rideHeightF', bucketNumber(readAny(setup, {'rideHeightF','frontRideHeight','ride_height_front'}), 0.5))
  append(parts, 'rideHeightR', bucketNumber(readAny(setup, {'rideHeightR','rearRideHeight','ride_height_rear'}), 0.5))
  append(parts, 'arbF', bucketNumber(readAny(setup, {'arbF','frontArb','antiRollBarFront'}), 0.25))
  append(parts, 'arbR', bucketNumber(readAny(setup, {'arbR','rearArb','antiRollBarRear'}), 0.25))
  append(parts, 'diffPower', bucketNumber(readAny(setup, {'diffPower','differentialPower'}), 0.01))
  append(parts, 'diffCoast', bucketNumber(readAny(setup, {'diffCoast','differentialCoast'}), 0.01))
  append(parts, 'camberFL', bucketNumber(readAny(setup, {'camberFL','camberFrontLeft'}), 0.02))
  append(parts, 'camberFR', bucketNumber(readAny(setup, {'camberFR','camberFrontRight'}), 0.02))
  append(parts, 'camberRL', bucketNumber(readAny(setup, {'camberRL','camberRearLeft'}), 0.02))
  append(parts, 'camberRR', bucketNumber(readAny(setup, {'camberRR','camberRearRight'}), 0.02))
  append(parts, 'toeF', bucketNumber(readAny(setup, {'toeF','frontToe'}), 0.01))
  append(parts, 'toeR', bucketNumber(readAny(setup, {'toeR','rearToe'}), 0.01))
  append(parts, 'pressureFL', bucketNumber(readAny(setup, {'tyrePressureFL','tirePressureFL','pressureFL'}), 0.05))
  append(parts, 'pressureFR', bucketNumber(readAny(setup, {'tyrePressureFR','tirePressureFR','pressureFR'}), 0.05))
  append(parts, 'pressureRL', bucketNumber(readAny(setup, {'tyrePressureRL','tirePressureRL','pressureRL'}), 0.05))
  append(parts, 'pressureRR', bucketNumber(readAny(setup, {'tyrePressureRR','tirePressureRR','pressureRR'}), 0.05))
  append(parts, 'abs', boolish(readAny(setup, {'absActive','abs','hasAbs'}) or readAny(telemetry, {'absActive'})))
  append(parts, 'tc', boolish(readAny(setup, {'tcActive','tc','hasTc'}) or readAny(telemetry, {'tcActive'})))
  append(parts, 'damage', bucketNumber(readAny(setup, {'damage','damagePenalty','damageState'}) or readAny(telemetry, {'damage'}), 0.02))
  table.sort(parts)
  if #parts == 0 then return 'setup=unknown' end
  return table.concat(parts, '|')
end

function M.setupHash(setup, telemetry)
  return U.hashString(M.setupFingerprint(setup, telemetry))
end

function M.resolve(ctx)
  ctx = ctx or {}
  local trackKey = Profiles.normalizeTrackId(ctx.trackId or ctx.track or ctx.trackName or 'unknown_track')
  local layoutKey = Profiles.normalizeLayoutId(ctx.layoutId or ctx.layout or ctx.layoutName or 'default')
  local carKey = Profiles.normalizeCarId(ctx.carId or ctx.car or ctx.carName or 'unknown_car')
  local setupHash = ctx.setupHash or M.setupHash(ctx.setup or {}, ctx.telemetry or ctx.carState or {})
  local warnings = {}
  local confidence = 1.0
  if trackKey == 'unknown_track' or ctx.usedDefaultTrackProfile == true then warnings[#warnings + 1] = 'track_profile_default_or_unknown'; confidence = confidence - 0.20 end
  if carKey == 'unknown_car' or ctx.usedDefaultCarProfile == true then warnings[#warnings + 1] = 'car_profile_default_or_unknown'; confidence = confidence - 0.18 end
  if tostring(setupHash) == 'setup=unknown' or setupHash == U.hashString('setup=unknown') then warnings[#warnings + 1] = 'setup_snapshot_hint_only'; confidence = confidence - 0.08 end
  if ctx.boundariesKnown ~= true then warnings[#warnings + 1] = 'track_boundaries_unknown_or_inferred'; confidence = confidence - 0.16 end
  if ctx.surfaceMapKnown ~= true then warnings[#warnings + 1] = 'surface_grip_map_unknown'; confidence = confidence - 0.08 end
  return {
    trackKey = trackKey,
    layoutKey = layoutKey,
    carKey = carKey,
    setupHash = setupHash,
    confidence = U.clamp(confidence, 0.18, 1.0),
    warnings = warnings,
    profilePaths = Profiles.profilePaths(ctx.dataRoot or 'data', trackKey, layoutKey, carKey, setupHash),
  }
end

function M.cacheKey(ctx, frame, boundary)
  local r = M.resolve(ctx)
  local grip = bucketNumber(ctx.grip or ctx.trackGrip or (ctx.telemetry and ctx.telemetry.grip), 0.01)
  local wet = bucketNumber(ctx.wetness or ctx.rain or (ctx.telemetry and ctx.telemetry.wetness), 0.02)
  local speedBucket = bucketNumber(ctx.speedMps or (ctx.carState and ctx.carState.speedMps) or (ctx.telemetry and ctx.telemetry.speedMps), 8.0)
  local lengthBucket = bucketNumber(frame and frame.length, 5.0)
  local spacingBucket = bucketNumber(frame and frame.spacing, 0.25)
  local sampleCount = frame and frame.samples and #frame.samples or #(ctx.centerlineSamples or ctx.trackSamples or ctx.samples or {})
  local boundaryConfidence = bucketNumber(boundary and boundary.confidence, 0.05)
  local sampleVersion = ctx.sampleVersion or ctx.splineVersion or ctx.trackDataVersion or 'v0'
  local profileVersion = ctx.profileVersion or 'p0'
  return table.concat({r.trackKey, r.layoutKey, r.carKey, tostring(r.setupHash), 'grip=' .. tostring(grip), 'wet=' .. tostring(wet), 'speed=' .. tostring(speedBucket), 'len=' .. tostring(lengthBucket), 'spacing=' .. tostring(spacingBucket), 'n=' .. tostring(sampleCount), 'bc=' .. tostring(boundaryConfidence), 'sv=' .. tostring(sampleVersion), 'pv=' .. tostring(profileVersion)}, '|'), r
end


-- R02 compatibility wrappers for integration_adapter.lua variants.
function M.guidanceKey(ctx)
  local key = M.cacheKey(ctx or {}, nil, nil)
  return key
end

function M.cacheMaxAge(ctx, base)
  ctx = ctx or {}
  base = base or Config.GUIDANCE_CACHE_MAX_AGE_S or 0.25
  local speed = M.readSpeedMps(ctx)
  if speed > 70 then return math.min(base, 0.16) end
  if speed > 45 then return math.min(base, 0.20) end
  return base
end

function M.readSpeedMps(ctx)
  ctx = ctx or {}
  local t = ctx.carState or ctx.telemetry or {}
  return tonumber(ctx.speedMps or t.speedMps or t.speed_ms or t.speed) or 0
end

function M.profilePenalty(defaultState)
  defaultState = defaultState or {}
  local penalty = 0
  if defaultState.track or defaultState.trackProfile then penalty = penalty + 0.08 end
  if defaultState.car or defaultState.carProfile then penalty = penalty + 0.07 end
  if defaultState.setup or defaultState.setupUnknown then penalty = penalty + 0.04 end
  if defaultState.anyDefault then penalty = penalty + 0.06 end
  return U.clamp(penalty, 0, 0.26)
end


function M.normalize(runtime)
  runtime = runtime or {}
  local resolved = M.resolve(runtime)
  local ctx = {}
  for k, v in pairs(runtime) do ctx[k] = v end
  ctx.trackKey = resolved.trackKey; ctx.layoutKey = resolved.layoutKey; ctx.carKey = resolved.carKey
  ctx.trackId = resolved.trackKey; ctx.layoutId = resolved.layoutKey; ctx.carId = resolved.carKey
  ctx.setupHash = resolved.setupHash
  ctx.setupConfidence = resolved.confidence
  ctx.profileTruthWarning = (#resolved.warnings > 0) and table.concat(resolved.warnings, ',') or nil
  ctx.telemetryConfidence = U.clamp((runtime.telemetry and runtime.telemetry.confidence) or runtime.telemetryConfidence or 0.45, 0, 1)
  return ctx
end

function M.withFineSetup(runtime)
  return M.normalize(runtime or {})
end

function M.estimateCarPhysics(ctx)
  ctx = ctx or {}
  local telem = ctx.telemetry or ctx.carState or {}
  local setup = ctx.setup or {}
  local out = {}
  local profile = ctx.physicsProfile or ctx.carProfile or {}
  if type(profile) == 'table' then for k, v in pairs(profile) do out[k] = v end end
  local corneringG = tonumber(telem.corneringG or telem.lateralG or telem.maxLateralG)
  local brakeG = tonumber(telem.brakeG or telem.maxBrakeG)
  local brakePowerMult = tonumber(setup.brakePowerMult or setup.brakePowerMultiplier or telem.brakePowerMult)
  local brakeSpeedAeroStrength = tonumber(telem.brakeSpeedAeroStrength or telem.speedAeroStrength or setup.brakeSpeedAeroStrength)
  out.mu = tonumber(telem.estimatedGripMu or telem.gripMu or telem.lateralGripMu or corneringG or out.mu) or 1.16
  out.lateralGripMu = out.mu
  out.brakeDecelMps2 = tonumber(telem.estimatedBrakeDecelMps2 or telem.brakeDecelMps2 or out.brakeDecelMps2) or
    (brakeG and brakeG * Config.GRAVITY) or 9.2
  out.tractionAccelMps2 = tonumber(telem.estimatedTractionAccelMps2 or telem.tractionAccelMps2 or out.tractionAccelMps2) or 4.0
  out.aeroDependency = tonumber(telem.aeroDependency or setup.aeroDependency or brakeSpeedAeroStrength or out.aeroDependency) or 0.35
  out.brakeSpeedAeroStrength = brakeSpeedAeroStrength or out.brakeSpeedAeroStrength
  out.brakeBias = tonumber(setup.brakeBias or telem.brakeBias or out.brakeBias)
  out.brakePowerMultiplier = tonumber(setup.brakePowerMultiplier or setup.brakePower or brakePowerMult or out.brakePowerMultiplier) or 1.0
  out.brakePowerMult = brakePowerMult or out.brakePowerMultiplier
  out.corneringG = corneringG or out.corneringG or out.mu
  out.brakeG = brakeG or out.brakeG or (out.brakeDecelMps2 / Config.GRAVITY)
  out.confidence = U.clamp((out.confidence or 0.35) * 0.55 + (ctx.telemetryConfidence or 0.45) * 0.30 + (ctx.setupConfidence or 0.3) * 0.15, 0.12, 0.88)
  out.source = 'dynamic_context_estimate'
  return out
end

return M
