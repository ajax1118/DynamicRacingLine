local settings = require('src/settings')
local math3d = require('src/math3d')
local physics_capability = require('src/physics_capability')
local real_life_priors = require('src/real_life_priors')
local knowledge_base = require('src/knowledge_base')
local M = {}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function clamp(value, lo, hi)
  return math3d.clamp(finiteNumber(value, lo), lo, hi)
end

local TRUST_ORDER_PROOF = 'live_telemetry>ac_physics_setup>local_adaptive_db>curated_profile>real_life_prior>class_heuristic'

local function capabilitySourceTrustRank(source)
  source = tostring(source or '')
  if source:find('live_telemetry', 1, true) then return 5 end
  if source == 'ac_physics_setup' then return 4 end
  if source:find('ac_physics_', 1, true) then return 4 end
  if source:find('local_adaptive_db', 1, true) then return 3 end
  if source:find('curated_profile', 1, true) then return 3 end
  if source:find('real_life_prior', 1, true) then return 2 end
  if source:find('class_heuristic', 1, true) then return 1 end
  return 0
end

local function profileCar(profile)
  local carProfile = profile and profile.car or {}
  local capability = type(carProfile.capability) == 'table' and carProfile.capability or nil
  if not capability then return carProfile end
  local out = {}
  for k, v in pairs(carProfile) do out[k] = v end
  if out.cornering_g == nil then out.cornering_g = capability.cornering_g or capability.corneringG end
  if out.brake_decel_g == nil then out.brake_decel_g = capability.brake_decel_g or capability.brake_g or capability.braking_g or capability.brakeG end
  if out.speed_aero_strength == nil then out.speed_aero_strength = capability.speed_aero_strength or capability.speedAeroStrength or capability.aero_dependency end
  if out.has_cornering_g == nil then out.has_cornering_g = out.cornering_g ~= nil end
  if out.has_brake_decel_g == nil then out.has_brake_decel_g = out.brake_decel_g ~= nil end
  if out.has_speed_aero_strength == nil then out.has_speed_aero_strength = out.speed_aero_strength ~= nil end
  return out
end

local function profileTrack(profile)
  return profile and profile.track or {}
end

local wheelAverage
local wheelAverageAbs
local wheelSlipStress

local telemetryState = {
  carKey = nil,
  carIdentityKey = nil,
  setupFingerprint = nil,
  currentResetReason = 'none',
  lastResetReason = 'none',
  previousTime = nil,
  previousSpeedKmh = nil,
  previousForward = nil,
  observedBrakeG = 0.0,
  observedCorneringG = 0.0,
  learnedBaseBrakeG = 0.0,
  learnedBaseCorneringG = 0.0,
  learnedBrakeG = 0.0,
  learnedCorneringG = 0.0,
  telemetryBrakeSamples = 0,
  telemetryCornerSamples = 0,
  strongBrakeSamples = 0,
  strongCornerSamples = 0,
  cornerCapabilitySamples = 0,
  brakeSampleThisFrame = false,
  brakeCapabilitySampleThisFrame = false,
  brakeLimitSampleThisFrame = false,
  cornerSampleThisFrame = false,
  cornerLimitSampleThisFrame = false,
  telemetrySampleAccepted = false,
  telemetryRejectReason = 'init',
  telemetryTrafficBlocked = false,
  brakeLimitState = 'not_braking',
  brakeSlipRatio = 0.0,
  frontBrakeSlipRatio = 0.0,
  rearBrakeSlipRatio = 0.0,
  brakeLockupAxle = 'none',
  brakeLearningRejectReason = 'init',
  brakeCapabilitySamples = 0,
  cleanStrongBrakeSamples = 0,
  absInterventionBrakeSamples = 0,
  lockupRiskBrakeSamples = 0,
  aeroHighSpeedCornerSamples = 0,
  aeroHighSpeedLimitSamples = 0,
  observedAeroCorneringG = 0.0,
  observedAeroSpeedKph = 0.0,
  observedSpeedAeroStrength = 0.0,
  learnedSpeedAeroStrength = 0.0,
  aeroStrengthSampleThisFrame = false,
  liveGripEnvelopePenalty = 0.0,
  liveGripEnvelopeConfidence = 1.0,
  liveGripEnvelopeState = 'nominal',
}

local function copyVec(value)
  if not value then return nil end
  return math3d.vec(math3d.x(value), math3d.y(value), math3d.z(value))
end

local function nowSeconds()
  return os.clock and os.clock() or 0
end

local function hasCompleteSetupFingerprint(setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  if setupFingerprint == '' or setupFingerprint == 'unknown' then return false end
  if not setupFingerprint:find('^car=') then return false end
  local requiredTokens = {
    '|tyre=',
    '|press=',
    '|pressSrc=',
    '|pressSrcTyres=',
    '|fuel=',
    '|ballast=',
    '|restrictor=',
    '|loadSrc=',
    '|brakePower=',
    '|bias=',
    '|wing=',
    '|tuneSrc=',
    '|tuneSrcFields=',
    '|aero=',
    '|mech=',
    '|drive=',
    '|align=',
    '|damp=',
    '|gear=',
    '|diff=',
    '|assist=',
    '|physics=',
    '|damage=',
  }
  for _, requiredToken in ipairs(requiredTokens) do
    if not setupFingerprint:find(requiredToken, 1, true) then return false end
  end
  return true
end

local function hasLiveKnownLoadEvidence(car)
  return (car and car.fuelKnown == true and finiteNumber(car.fuel, 0.0) == 0.0) or
    (car and car.ballastKnown == true and finiteNumber(car.ballast, 0.0) == 0.0) or
    (car and car.restrictorKnown == true and finiteNumber(car.restrictor, 0.0) == 0.0)
end

local function isPressureSource(source)
  return source == 'live_static' or source == 'setup' or
    source == 'live_current' or source == 'fallback'
end

local function pressureSourceList(pressureSource)
  pressureSource = tostring(pressureSource or '')
  local sources = {}
  for source in string.gmatch(pressureSource, '[^:]+') do
    if not isPressureSource(source) then return nil end
    sources[#sources + 1] = source
  end
  if #sources ~= 4 then return nil end
  return sources
end

local function pressureSourceTyreList(pressureSourceTyres)
  pressureSourceTyres = tostring(pressureSourceTyres or '')
  local lf, rf, lr, rr = pressureSourceTyres:match('^lf:([^,]+),rf:([^,]+),lr:([^,]+),rr:([^,]+)$')
  if not lf then return nil end
  local sources = { lf, rf, lr, rr }
  for _, source in ipairs(sources) do
    if not isPressureSource(source) then return nil end
  end
  return sources
end

local function hasTrustedPressureSourceValue(sources)
  for _, source in ipairs(sources or {}) do
    if source == 'live_static' or source == 'setup' or source == 'live_current' then return true end
  end
  return false
end

local function pressureSourcesMatch(compactSources, labelledSources)
  if not compactSources or not labelledSources then return false end
  for index = 1, 4 do
    if compactSources[index] ~= labelledSources[index] then return false end
  end
  return true
end

local function hasValidPressureSourceProof(setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  local pressureSource = setupFingerprint:match('%|pressSrc=([^|]+)') or ''
  local pressureSourceTyres = setupFingerprint:match('%|pressSrcTyres=([^|]+)') or ''
  local compactSources = pressureSourceList(pressureSource)
  local labelledSources = pressureSourceTyreList(pressureSourceTyres)
  return compactSources ~= nil and labelledSources ~= nil and pressureSourcesMatch(compactSources, labelledSources)
end

local function isTuneSource(source, allowPhysics)
  return source == 'live' or source == 'setup' or source == 'fallback' or
    (allowPhysics == true and source == 'physics')
end

local function tuneSourceList(tuneSource)
  tuneSource = tostring(tuneSource or '')
  local brakePower, brakeBias, wing = tuneSource:match('^([^:]+):([^:]+):([^:]+)$')
  if not brakePower then return nil end
  if not isTuneSource(brakePower, true) then return nil end
  if not isTuneSource(brakeBias, true) then return nil end
  if not isTuneSource(wing, false) then return nil end
  return { brakePower, brakeBias, wing }
end

local function tuneSourceFieldList(tuneSourceFields)
  tuneSourceFields = tostring(tuneSourceFields or '')
  local brakePower, brakeBias, wing = tuneSourceFields:match('^brakePower:([^,]+),brakeBias:([^,]+),wing:([^,]+)$')
  if not brakePower then return nil end
  if not isTuneSource(brakePower, true) then return nil end
  if not isTuneSource(brakeBias, true) then return nil end
  if not isTuneSource(wing, false) then return nil end
  return { brakePower, brakeBias, wing }
end

local function tuneSourcesMatch(compactSources, labelledSources)
  if not compactSources or not labelledSources then return false end
  for index = 1, 3 do
    if compactSources[index] ~= labelledSources[index] then return false end
  end
  return true
end

local function hasValidTuneSourceProof(setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  local tuneSource = setupFingerprint:match('%|tuneSrc=([^|]+)') or ''
  local tuneSourceFields = setupFingerprint:match('%|tuneSrcFields=([^|]+)') or ''
  local compactSources = tuneSourceList(tuneSource)
  local labelledSources = tuneSourceFieldList(tuneSourceFields)
  return compactSources ~= nil and labelledSources ~= nil and tuneSourcesMatch(compactSources, labelledSources)
end

local function hasTrustedPressureSource(setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  if setupFingerprint:find('|press=0.0/0.0/0.0/0.0', 1, true) then return false end
  if setupFingerprint:find('|pressSrc=fallback:fallback:fallback:fallback', 1, true) then return false end
  if setupFingerprint:find('|pressSrcTyres=lf:fallback,rf:fallback,lr:fallback,rr:fallback', 1, true) then return false end
  local pressureSource = setupFingerprint:match('%|pressSrc=([^|]+)') or ''
  local pressureSourceTyres = setupFingerprint:match('%|pressSrcTyres=([^|]+)') or ''
  local compactSources = pressureSourceList(pressureSource)
  local labelledSources = pressureSourceTyreList(pressureSourceTyres)
  if not compactSources or not labelledSources then return false end
  if not pressureSourcesMatch(compactSources, labelledSources) then return false end
  return hasTrustedPressureSourceValue(compactSources) and hasTrustedPressureSourceValue(labelledSources)
end

local function hasTrustedTuneSource(setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  if setupFingerprint:find('|tuneSrc=fallback:fallback:fallback', 1, true) then return false end
  if setupFingerprint:find('|tuneSrcFields=brakePower:fallback,brakeBias:fallback,wing:fallback', 1, true) then return false end
  local tuneSource = setupFingerprint:match('%|tuneSrc=([^|]+)') or ''
  local tuneSourceFields = setupFingerprint:match('%|tuneSrcFields=([^|]+)') or ''
  local compactSources = tuneSourceList(tuneSource)
  local labelledSources = tuneSourceFieldList(tuneSourceFields)
  if not compactSources or not labelledSources then return false end
  if not tuneSourcesMatch(compactSources, labelledSources) then return false end
  for _, source in ipairs(compactSources) do
    if source == 'live' or source == 'setup' or source == 'physics' then return true end
  end
  return false
end

local function pressureSourceTyresToken(setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  return setupFingerprint:match('%|pressSrcTyres=([^|]+)') or 'lf:fallback,rf:fallback,lr:fallback,rr:fallback'
end

local function pressureSourceTokensToken(setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  return setupFingerprint:match('%|pressSrc=([^|]+)') or 'fallback:fallback:fallback:fallback'
end

local function labelledPressureSourceTyres(sources)
  sources = sources or {}
  return 'lf:' .. tostring(sources[1] or 'fallback') ..
    ',rf:' .. tostring(sources[2] or 'fallback') ..
    ',lr:' .. tostring(sources[3] or 'fallback') ..
    ',rr:' .. tostring(sources[4] or 'fallback')
end

local function compactPressureSourceTyres(sources)
  sources = sources or {}
  return tostring(sources[1] or 'fallback') .. ':' ..
    tostring(sources[2] or 'fallback') .. ':' ..
    tostring(sources[3] or 'fallback') .. ':' ..
    tostring(sources[4] or 'fallback')
end

local function pressureSourceFieldMap(sourceTokens)
  local sources = pressureSourceList(sourceTokens) or { 'fallback', 'fallback', 'fallback', 'fallback' }
  return {
    lf = tostring(sources[1] or 'fallback'),
    rf = tostring(sources[2] or 'fallback'),
    lr = tostring(sources[3] or 'fallback'),
    rr = tostring(sources[4] or 'fallback'),
  }
end

local function hasMeaningfulSetupFingerprint(car, setupFingerprint)
  setupFingerprint = tostring(setupFingerprint or '')
  if not hasCompleteSetupFingerprint(setupFingerprint) then return false end
  if not hasValidPressureSourceProof(setupFingerprint) then return false end
  if not hasValidTuneSourceProof(setupFingerprint) then return false end

  if hasLiveKnownLoadEvidence(car) then return true end
  if setupFingerprint:find('|tyre=', 1, true) and
    not setupFingerprint:find('|tyre=-1:unknown', 1, true) then return true end
  if hasTrustedPressureSource(setupFingerprint) then return true end
  if setupFingerprint:find('|fuel=', 1, true) and
    not setupFingerprint:find('|fuel=0|', 1, true) then return true end
  if setupFingerprint:find('|ballast=', 1, true) and
    not setupFingerprint:find('|ballast=0|', 1, true) then return true end
  if setupFingerprint:find('|restrictor=', 1, true) and
    not setupFingerprint:find('|restrictor=0|', 1, true) then return true end
  if setupFingerprint:find('|loadSrc=', 1, true) and
    not setupFingerprint:find('|loadSrc=fallback:fallback:fallback', 1, true) then return true end
  if setupFingerprint:find('|brakePower=', 1, true) and
    not setupFingerprint:find('|brakePower=100|', 1, true) then return true end
  if setupFingerprint:find('|bias=', 1, true) and
    not setupFingerprint:find('|bias=0.0|', 1, true) then return true end
  if setupFingerprint:find('|wing=', 1, true) and
    not setupFingerprint:find('|wing=0|', 1, true) then return true end
  if hasTrustedTuneSource(setupFingerprint) then return true end
  if setupFingerprint:find('|aero=', 1, true) and
    not setupFingerprint:find('|aero=none', 1, true) then return true end
  if setupFingerprint:find('|mech=', 1, true) and
    not setupFingerprint:find('|mech=none', 1, true) then return true end
  if setupFingerprint:find('|drive=', 1, true) and
    not setupFingerprint:find('|drive=none', 1, true) then return true end
  if setupFingerprint:find('|align=', 1, true) and
    not setupFingerprint:find('|align=none', 1, true) then return true end
  if setupFingerprint:find('|damp=', 1, true) and
    not setupFingerprint:find('|damp=none', 1, true) then return true end
  if setupFingerprint:find('|gear=', 1, true) and
    not setupFingerprint:find('|gear=none', 1, true) then return true end
  if setupFingerprint:find('|diff=', 1, true) and
    not setupFingerprint:find('|diff=none', 1, true) then return true end
  if setupFingerprint:find('|assist=', 1, true) and
    not setupFingerprint:find('|assist=none', 1, true) then return true end
  if setupFingerprint:find('|physics=', 1, true) and
    not setupFingerprint:find('|physics=none', 1, true) then return true end
  if setupFingerprint:find('|damage=', 1, true) and
    not setupFingerprint:find('|damage=0.0', 1, true) then return true end

  return false
end

local function telemetryIdentity(car)
  local carIdentityKey = tostring(car and (car.carId or car.id or car.name) or 'unknown_car')
  if carIdentityKey == '' then carIdentityKey = 'unknown_car' end
  local setupFingerprint = tostring(car and car.setupFingerprint or '')
  if not hasMeaningfulSetupFingerprint(car, setupFingerprint) then setupFingerprint = 'unknown' end
  return {
    carIdentityKey = carIdentityKey,
    setupFingerprint = setupFingerprint,
    telemetryLearningKey = carIdentityKey .. '|' .. setupFingerprint,
  }
end

function M.resetTelemetryLearning(reason)
  telemetryState = {
    carKey = nil,
    carIdentityKey = nil,
    setupFingerprint = nil,
    currentResetReason = 'none',
    lastResetReason = tostring(reason or 'manual'),
    previousTime = nil,
    previousSpeedKmh = nil,
    previousForward = nil,
    observedBrakeG = 0.0,
    observedCorneringG = 0.0,
    learnedBaseBrakeG = 0.0,
    learnedBaseCorneringG = 0.0,
    learnedBrakeG = 0.0,
    learnedCorneringG = 0.0,
    telemetryBrakeSamples = 0,
    telemetryCornerSamples = 0,
    strongBrakeSamples = 0,
    strongCornerSamples = 0,
    cornerCapabilitySamples = 0,
    brakeSampleThisFrame = false,
    brakeCapabilitySampleThisFrame = false,
    brakeLimitSampleThisFrame = false,
    cornerSampleThisFrame = false,
    cornerLimitSampleThisFrame = false,
    telemetrySampleAccepted = false,
    telemetryRejectReason = tostring(reason or 'manual'),
    telemetryTrafficBlocked = false,
    brakeLimitState = 'not_braking',
    brakeSlipRatio = 0.0,
    frontBrakeSlipRatio = 0.0,
    rearBrakeSlipRatio = 0.0,
    brakeLockupAxle = 'none',
    brakeLearningRejectReason = tostring(reason or 'manual'),
    brakeCapabilitySamples = 0,
    cleanStrongBrakeSamples = 0,
    absInterventionBrakeSamples = 0,
    lockupRiskBrakeSamples = 0,
    aeroHighSpeedCornerSamples = 0,
    aeroHighSpeedLimitSamples = 0,
    observedAeroCorneringG = 0.0,
    observedAeroSpeedKph = 0.0,
    observedSpeedAeroStrength = 0.0,
    learnedSpeedAeroStrength = 0.0,
    aeroStrengthSampleThisFrame = false,
    liveGripEnvelopePenalty = 0.0,
    liveGripEnvelopeConfidence = 1.0,
    liveGripEnvelopeState = 'nominal',
    resetReason = tostring(reason or 'manual'),
  }
end

local function updateLearnedPeak(previous, observed)
  previous = math.max(0.0, finiteNumber(previous, 0.0))
  observed = clamp(observed, 0.0, finiteNumber(settings.TELEMETRY_OBSERVED_MAX_G, 5.50))
  local decay = clamp(settings.TELEMETRY_DECAY, 0.90, 1.0)
  local blend = clamp(settings.TELEMETRY_BLEND, 0.05, 1.0)
  if previous <= 0.0 then return observed end
  local retained = previous * decay
  if observed > retained then
    return retained + (observed - retained) * blend
  end
  return retained
end

local function telemetryTrafficBlock(car)
  local traffic = car and car.trafficProximity or {}
  local aheadM = finiteNumber(traffic.nearestOpponentAheadM, 0.0)
  local lateralM = finiteNumber(traffic.nearestOpponentLateralM, 0.0)
  local maxAheadM = math.max(0.0, finiteNumber(settings.TELEMETRY_TRAFFIC_AHEAD_M, 65.0))
  local maxLateralM = math.max(0.0, finiteNumber(settings.TELEMETRY_TRAFFIC_LATERAL_M, 6.5))
  return {
    blocked = aheadM > 0.0 and aheadM <= maxAheadM and lateralM <= maxLateralM,
    aheadM = aheadM,
    lateralM = lateralM,
    scanStatus = tostring(traffic.trafficScanStatus or 'unknown'),
  }
end

local function telemetrySurfaceInvalid(car)
  for _, wheel in ipairs(car and car.wheels or {}) do
    if wheel and wheel.surfaceValidTrackKnown == true and wheel.surfaceValidTrack ~= true then
      return true
    end
  end
  return false
end

local function telemetrySampleQuality(car, dt, speedKmh)
  local traffic = telemetryTrafficBlock(car)
  if traffic.blocked == true then
    return { accepted = false, reason = 'traffic_ahead', trafficBlocked = true }
  end
  if not dt then return { accepted = false, reason = 'awaiting_history', trafficBlocked = false } end
  local minDt = finiteNumber(settings.TELEMETRY_MIN_DT_S, 0.015)
  local maxDt = finiteNumber(settings.TELEMETRY_MAX_DT_S, 0.35)
  if dt < minDt or dt > maxDt then return { accepted = false, reason = 'dt_out_of_range', trafficBlocked = false } end
  if finiteNumber(speedKmh, 0.0) < finiteNumber(settings.TELEMETRY_MIN_SPEED_KPH, 45.0) then
    return { accepted = false, reason = 'below_min_speed', trafficBlocked = false }
  end
  if telemetrySurfaceInvalid(car) then
    return { accepted = false, reason = 'surface_valid_track_false', trafficBlocked = false }
  end
  local tyreDirty = clamp(math.max(
    wheelAverage(car, 'tyreDirty', 0.0, 0.0, 1.0),
    wheelAverage(car, 'surfaceDirt', 0.0, 0.0, 1.0)), 0.0, 1.0)
  if tyreDirty > finiteNumber(settings.TELEMETRY_MAX_TYRE_DIRTY, 0.45) then
    return { accepted = false, reason = 'dirty_tyres', trafficBlocked = false }
  end
  local slipStress = wheelSlipStress(car, 4.0)
  if slipStress > finiteNumber(settings.TELEMETRY_MAX_SLIP_STRESS, 2.80) then
    return { accepted = false, reason = 'excessive_slip', trafficBlocked = false }
  end
  return { accepted = true, reason = 'accepted', trafficBlocked = false }
end

local function brakeSlipRatio(car)
  return wheelAverageAbs(car, 'slipRatio', 0.0, 0.0, 4.0)
end

local function brakeAxleSlipRatios(car)
  local wheels = car and car.wheels or {}
  local function averageAxle(firstIndex, lastIndex)
    local sum, count = 0.0, 0
    for index = firstIndex, lastIndex do
      local value = tonumber(wheels[index] and wheels[index].slipRatio)
      if value and value == value and value ~= math.huge and value ~= -math.huge then
        value = math.abs(value)
        sum = sum + clamp(value, 0.0, 4.0)
        count = count + 1
      end
    end
    if count == 0 then return 0.0 end
    return sum / count
  end
  return averageAxle(1, 2), averageAxle(3, 4)
end

local function brakeLimitState(car, slipRatio, frontSlipRatio, rearSlipRatio)
  local threshold = finiteNumber(settings.TELEMETRY_BRAKE_LOCKUP_SLIP_RATIO, 0.22)
  local frontLocked = finiteNumber(frontSlipRatio, 0.0) >= threshold
  local rearLocked = finiteNumber(rearSlipRatio, 0.0) >= threshold
  local brakeLockupAxle = 'none'
  if frontLocked and rearLocked then brakeLockupAxle = 'all'
  elseif frontLocked then brakeLockupAxle = 'front'
  elseif rearLocked then brakeLockupAxle = 'rear'
  end
  if car and car.absInAction then return 'abs_intervention', brakeLockupAxle end
  if brakeLockupAxle ~= 'none' or finiteNumber(slipRatio, 0.0) >= threshold then
    return 'lockup_risk', brakeLockupAxle
  end
  return 'clean_threshold', brakeLockupAxle
end

local function learnCapabilityFromTelemetry(car, dtSeconds)
  telemetryState.brakeSampleThisFrame = false
  telemetryState.brakeCapabilitySampleThisFrame = false
  telemetryState.brakeLimitSampleThisFrame = false
  telemetryState.cornerSampleThisFrame = false
  telemetryState.cornerLimitSampleThisFrame = false
  telemetryState.aeroStrengthSampleThisFrame = false
  telemetryState.currentResetReason = 'none'
  telemetryState.telemetrySampleAccepted = false
  telemetryState.telemetryRejectReason = 'telemetry_disabled'
  telemetryState.telemetryTrafficBlocked = false
  telemetryState.brakeLimitState = 'not_braking'
  telemetryState.brakeSlipRatio = 0.0
  telemetryState.frontBrakeSlipRatio = 0.0
  telemetryState.rearBrakeSlipRatio = 0.0
  telemetryState.brakeLockupAxle = 'none'
  telemetryState.brakeLearningRejectReason = 'not_braking'
  if settings.TELEMETRY_LEARNING_ENABLED ~= true then return telemetryState end

  local identity = telemetryIdentity(car)
  if telemetryState.carKey ~= identity.telemetryLearningKey then
    local resetReason = telemetryState.carIdentityKey == identity.carIdentityKey and 'setup_changed' or 'car_changed'
    M.resetTelemetryLearning(resetReason)
    telemetryState.carKey = identity.telemetryLearningKey
    telemetryState.carIdentityKey = identity.carIdentityKey
    telemetryState.setupFingerprint = identity.setupFingerprint
    telemetryState.currentResetReason = resetReason
    telemetryState.lastResetReason = resetReason
  end

  local explicitDt = tonumber(dtSeconds)
  local now = nowSeconds()
  local speedKmh = finiteNumber(car and car.speedKmh, 0.0)
  local brake = clamp(car and car.brake, 0.0, 1.0)
  local gas = clamp(car and car.gas, 0.0, 1.0)
  local steer = math.abs(clamp(car and car.steer, -1.0, 1.0))
  local forward = copyVec(car and car.forward)
  local minDt = finiteNumber(settings.TELEMETRY_MIN_DT_S, 0.015)
  local maxDt = finiteNumber(settings.TELEMETRY_MAX_DT_S, 0.35)
  local minSpeed = finiteNumber(settings.TELEMETRY_MIN_SPEED_KPH, 45.0)
  local dt = nil
  if explicitDt and explicitDt > 0 then
    dt = explicitDt
  elseif telemetryState.previousTime then
    dt = now - telemetryState.previousTime
  end

  local quality = telemetrySampleQuality(car, dt, speedKmh)
  telemetryState.telemetrySampleAccepted = quality.accepted == true
  telemetryState.telemetryRejectReason = tostring(quality.reason or 'unknown')
  telemetryState.telemetryTrafficBlocked = quality.trafficBlocked == true

  if quality.accepted == true then
    if telemetryState.previousSpeedKmh ~= nil and speedKmh >= minSpeed then
      local slipStress = wheelSlipStress(car, 4.0)
      local slipOk = slipStress <= finiteNumber(settings.TELEMETRY_MAX_SLIP_STRESS, 2.80)

      if slipOk and brake >= finiteNumber(settings.TELEMETRY_MIN_BRAKE_INPUT, 0.55) and
        gas <= finiteNumber(settings.TELEMETRY_MAX_BRAKE_GAS_INPUT, 0.35) then
        local decelMps2 = math.max(0.0, ((telemetryState.previousSpeedKmh - speedKmh) / 3.6) / dt)
        local observedBrakeG = decelMps2 / 9.80665
        if observedBrakeG >= finiteNumber(settings.TELEMETRY_MIN_OBSERVED_BRAKE_G, 0.35) then
          local currentBrakeSlipRatio = brakeSlipRatio(car)
          local frontBrakeSlipRatio, rearBrakeSlipRatio = brakeAxleSlipRatios(car)
          local limitState, brakeLockupAxle = brakeLimitState(car, currentBrakeSlipRatio, frontBrakeSlipRatio, rearBrakeSlipRatio)
          telemetryState.observedBrakeG = observedBrakeG
          telemetryState.brakeSlipRatio = currentBrakeSlipRatio
          telemetryState.frontBrakeSlipRatio = frontBrakeSlipRatio
          telemetryState.rearBrakeSlipRatio = rearBrakeSlipRatio
          telemetryState.brakeLimitState = limitState
          telemetryState.brakeLockupAxle = brakeLockupAxle
          telemetryState.telemetryBrakeSamples = telemetryState.telemetryBrakeSamples + 1
          if limitState == 'abs_intervention' then
            telemetryState.absInterventionBrakeSamples = telemetryState.absInterventionBrakeSamples + 1
          elseif limitState == 'lockup_risk' then
            telemetryState.lockupRiskBrakeSamples = telemetryState.lockupRiskBrakeSamples + 1
          end
          if limitState ~= 'clean_threshold' then
            telemetryState.brakeLimitSampleThisFrame = true
          end
          local cleanStrongBrake = brake >= finiteNumber(settings.TELEMETRY_STRONG_BRAKE_INPUT, 0.85) and
            limitState == 'clean_threshold'
          if cleanStrongBrake then
            telemetryState.cleanStrongBrakeSamples = telemetryState.cleanStrongBrakeSamples + 1
            telemetryState.strongBrakeSamples = telemetryState.strongBrakeSamples + 1
            telemetryState.brakeCapabilitySampleThisFrame = true
            telemetryState.brakeCapabilitySamples = telemetryState.brakeCapabilitySamples + 1
            telemetryState.brakeLearningRejectReason = 'accepted_clean_strong'
          elseif limitState ~= 'clean_threshold' then
            telemetryState.brakeLearningRejectReason = limitState
          else
            telemetryState.brakeLearningRejectReason = 'below_strong_brake_input'
          end
          telemetryState.brakeSampleThisFrame = true
        end
      end

      if slipOk and forward and telemetryState.previousForward and
        brake <= finiteNumber(settings.TELEMETRY_MAX_CORNER_BRAKE_INPUT, 0.20) then
        local dot = clamp(math3d.dot(telemetryState.previousForward, forward), -1.0, 1.0)
        local headingDelta = math.acos(dot)
        if steer >= finiteNumber(settings.TELEMETRY_MIN_STEER_INPUT, 0.06) or headingDelta > 0.0015 then
          local observedCorneringG = (headingDelta / dt) * (speedKmh / 3.6) / 9.80665
          if observedCorneringG >= finiteNumber(settings.TELEMETRY_MIN_OBSERVED_CORNERING_G, 0.45) then
            telemetryState.observedCorneringG = observedCorneringG
            telemetryState.telemetryCornerSamples = telemetryState.telemetryCornerSamples + 1
            local highSpeedAeroSample = speedKmh >= finiteNumber(settings.TELEMETRY_AERO_MIN_SPEED_KPH, 145.0)
            if highSpeedAeroSample then
              telemetryState.aeroHighSpeedCornerSamples = telemetryState.aeroHighSpeedCornerSamples + 1
              telemetryState.observedAeroCorneringG = observedCorneringG
              telemetryState.observedAeroSpeedKph = speedKmh
            end
            local cornerLimitSample = steer >= finiteNumber(settings.TELEMETRY_STRONG_STEER_INPUT, 0.55) and
              slipStress >= finiteNumber(settings.TELEMETRY_CORNER_LIMIT_SLIP_STRESS, 0.18)
            if cornerLimitSample then
              telemetryState.strongCornerSamples = telemetryState.strongCornerSamples + 1
              telemetryState.cornerCapabilitySamples = telemetryState.cornerCapabilitySamples + 1
              telemetryState.cornerLimitSampleThisFrame = true
              if highSpeedAeroSample then
                telemetryState.aeroHighSpeedLimitSamples = telemetryState.aeroHighSpeedLimitSamples + 1
                telemetryState.aeroStrengthSampleThisFrame = true
              end
            end
            telemetryState.cornerSampleThisFrame = true
          end
        end
      end
    end
  end

  telemetryState.previousTime = explicitDt and explicitDt > 0 and (telemetryState.previousTime or now) + dt or now
  telemetryState.previousSpeedKmh = speedKmh
  telemetryState.previousForward = forward
  return telemetryState
end

local function carIdentityText(car)
  local parts = {}
  for _, key in ipairs({ 'carId', 'id', 'name', 'displayName', 'brand', 'class', 'className', 'tags', 'tyresName', 'tyresLongName' }) do
    local value = car and car[key]
    if value ~= nil then parts[#parts + 1] = tostring(value) end
  end
  return table.concat(parts, ' '):lower()
end

local function identityHasAny(text, tokens)
  text = tostring(text or ''):lower()
  for _, token in ipairs(tokens or {}) do
    if text:find(tostring(token):lower(), 1, true) ~= nil then return true end
  end
  return false
end

local function looksLikeFormulaDriftIdentity(identity)
  identity = tostring(identity or ''):lower()
  return identityHasAny(identity, { 'formula drift', 'formula_drift', 'formula-drift' }) or
    (identity:find('formula', 1, true) ~= nil and identity:find('drift', 1, true) ~= nil)
end

local function looksLikeClubCupCar(car)
  local identity = carIdentityText(car)
  if not identityHasAny(identity, { 'cup', 'one make', 'one-make', 'one_make', 'trophy', 'challenge' }) then return false end
  if identityHasAny(identity, { 'gt3', 'gt4', 'gte', 'lmp', 'prototype', 'dtm', 'group_c', 'f1_gtr', 'f1 gtr' }) then return false end
  return identityHasAny(identity, {
    'mx5',
    'mx-5',
    'miata',
    'abarth',
    'fiat',
    '500',
    'copen',
    'mini',
    'clio',
    'swift',
    'audi tt',
    'tt cup',
  })
end

local function looksLikePrototypeCar(car)
  if car and car.isPrototype then return true end
  return identityHasAny(carIdentityText(car), {
    'lmp',
    'lmh',
    'lmdh',
    'lemans prototype',
    'le mans prototype',
    'prototype',
    'group_c',
    'group c',
  })
end

local function looksLikeOpenWheeler(car)
  if car and car.isOpenWheeler then return true end
  local identity = carIdentityText(car)
  if looksLikeFormulaDriftIdentity(identity) then return false end
  return identityHasAny(identity, {
    'acfl',
    'rss_formula',
    'formula',
    'f138',
    'f2004',
    'sf15',
    'sf70',
    'exos',
    'indycar',
    'super_formula',
    'dallara',
    'tatuus',
    'open_wheel',
    'open wheel',
  })
end

local function looksLikeRacingCar(car)
  if looksLikeClubCupCar(car) then return false end
  if car and car.isRacingCar then return true end
  return identityHasAny(carIdentityText(car), {
    'gt3',
    'gt2',
    'gt4',
    'gte',
    'f1_gtr',
    'f1 gtr',
    'cup',
    'lmp',
    'lemans',
    'prototype',
    'dtm',
    'group_c',
  })
end

local function looksLikeSportRoadCar(car)
  if car and car.isRacingCar then return false end
  return identityHasAny(carIdentityText(car), {
    'bmw m',
    'm3',
    'm4',
    'm5',
    'amg',
    'rs ',
    'porsche',
    'cayman',
    '911',
    'corvette',
    'viper',
    'lotus',
    'supra',
    'gt-r',
    'gt_r',
    'gtr',
  })
end

local function inferredBaseCapability(car, profile, carProfile)
  local hasExplicitProfile = profile and profile.carKey and tostring(profile.carKey) ~= 'default'
  local baseCorneringG = finiteNumber(settings.DEFAULT_CORNERING_G, 1.05)
  local baseBrakeG = finiteNumber(settings.DEFAULT_BRAKE_G, 1.05)
  local source = 'profile_default'

  if looksLikeOpenWheeler(car) then
    baseCorneringG = math.max(baseCorneringG, finiteNumber(settings.INFER_OPEN_WHEELER_CORNERING_G, 2.70))
    baseBrakeG = math.max(baseBrakeG, finiteNumber(settings.INFER_OPEN_WHEELER_BRAKE_G, 2.20))
    source = 'inferred_open_wheeler'
  elseif looksLikePrototypeCar(car) then
    baseCorneringG = math.max(baseCorneringG, finiteNumber(settings.INFER_PROTOTYPE_CORNERING_G, 2.15))
    baseBrakeG = math.max(baseBrakeG, finiteNumber(settings.INFER_PROTOTYPE_BRAKE_G, 1.90))
    source = 'inferred_prototype_car'
  elseif looksLikeClubCupCar(car) then
    baseCorneringG = math.max(baseCorneringG, finiteNumber(settings.INFER_TRACK_DAY_CORNERING_G, 1.35))
    baseBrakeG = math.max(baseBrakeG, finiteNumber(settings.INFER_TRACK_DAY_BRAKE_G, 1.30))
    source = 'inferred_club_cup_car'
  elseif looksLikeRacingCar(car) then
    baseCorneringG = math.max(baseCorneringG, finiteNumber(settings.INFER_RACING_CAR_CORNERING_G, 1.55))
    baseBrakeG = math.max(baseBrakeG, finiteNumber(settings.INFER_RACING_CAR_BRAKE_G, 1.45))
    source = 'inferred_racing_car'
  elseif looksLikeSportRoadCar(car) then
    baseCorneringG = math.max(baseCorneringG, finiteNumber(settings.INFER_SPORT_ROAD_CORNERING_G, 1.22))
    baseBrakeG = math.max(baseBrakeG, finiteNumber(settings.INFER_SPORT_ROAD_BRAKE_G, 1.18))
    source = 'inferred_sport_road_car'
  else
    baseCorneringG = math.max(baseCorneringG, finiteNumber(settings.INFER_ROAD_CAR_CORNERING_G, 1.05))
    baseBrakeG = math.max(baseBrakeG, finiteNumber(settings.INFER_ROAD_CAR_BRAKE_G, 1.05))
    source = 'inferred_road_car'
  end

  if hasExplicitProfile and carProfile.has_cornering_g == true then
    baseCorneringG = finiteNumber(carProfile.cornering_g, baseCorneringG)
    source = source .. '+profile_cornering'
  end
  if hasExplicitProfile and carProfile.has_brake_decel_g == true then
    baseBrakeG = finiteNumber(carProfile.brake_decel_g, baseBrakeG)
    source = source .. '+profile_brake'
  end

  local mass = finiteNumber(car and car.mass, 0.0)
  if mass > 0 and mass < 720 and looksLikeOpenWheeler(car) then
    baseCorneringG = math.max(baseCorneringG, 2.90)
    baseBrakeG = math.max(baseBrakeG, 2.35)
    source = source .. '_light'
  end

  return baseCorneringG, baseBrakeG, source
end

local function realLifePriorCapability(carProfile, externalRealLife)
  local prior = carProfile and (carProfile.real_life_prior or carProfile.realLifePrior) or externalRealLife
  if type(prior) ~= 'table' then return nil end
  local corneringG = finiteNumber(prior.cornering_g or prior.corneringG, 0.0)
  local brakeG = finiteNumber(prior.brake_decel_g or prior.brakeG or prior.brake_g, 0.0)
  local speedAeroStrength = prior.speed_aero_strength ~= nil and prior.speed_aero_strength or prior.speedAeroStrength
  if corneringG <= 0.0 and brakeG <= 0.0 and speedAeroStrength == nil then return nil end
  return {
    corneringG = corneringG > 0.0 and clamp(corneringG, 0.5, 4.5) or nil,
    brakeG = brakeG > 0.0 and clamp(brakeG, 0.5, finiteNumber(settings.MAX_DYNAMIC_BRAKE_G, 4.50)) or nil,
    speedAeroStrength = speedAeroStrength ~= nil and clamp(speedAeroStrength, 0.0, 0.30) or nil,
    confidence = clamp(prior.confidence, 0.35, 0.62),
    sourceDetail = tostring(prior.sourceDetail or prior.source or 'real_life_prior'),
  }
end

local function hasTrustedPhysicsCorneringCapability(physicsCapability, physicsConfidence)
  if not (physicsCapability and physicsCapability.available == true and finiteNumber(physicsConfidence, 0.0) > 0.0) then
    return false
  end
  return finiteNumber(physicsCapability and physicsCapability.corneringG, 0.0) > 0.0
end

local function hasTrustedPhysicsBrakeCapability(physicsCapability, physicsConfidence)
  if not (physicsCapability and physicsCapability.available == true and finiteNumber(physicsConfidence, 0.0) > 0.0) then
    return false
  end
  return finiteNumber(physicsCapability and physicsCapability.brakeG, 0.0) > 0.0
end

local function isTrustedPhysicsAeroStatus(aeroDataStatus)
  aeroDataStatus = tostring(aeroDataStatus or '')
  return aeroDataStatus == 'aero_wings_present' or
    aeroDataStatus == 'aero_wings_absent' or
    aeroDataStatus == 'aero_no_downforce_sections'
end

local function hasTrustedPhysicsAeroCapability(physicsCapability, physicsConfidence)
  if not (physicsCapability and physicsCapability.available == true and finiteNumber(physicsConfidence, 0.0) > 0.0) then
    return false
  end
  if not isTrustedPhysicsAeroStatus(physicsCapability.aeroDataStatus) then return false end
  return physicsCapability.speedAeroStrength ~= nil
end

local function hasTrustedPhysicsCapability(physicsCapability, physicsConfidence)
  return hasTrustedPhysicsCorneringCapability(physicsCapability, physicsConfidence) or
    hasTrustedPhysicsBrakeCapability(physicsCapability, physicsConfidence) or
    hasTrustedPhysicsAeroCapability(physicsCapability, physicsConfidence)
end

local function selectBaseCapability(car, profile, carProfile)
  local classCorneringG, classBrakeG, classSource = inferredBaseCapability(car, { carKey = 'default' }, {})
  local classConfidence = clamp(settings.CAPABILITY_CLASS_HEURISTIC_CONFIDENCE, 0.35, 0.65)
  local selected = {
    corneringG = classCorneringG,
    brakeG = classBrakeG,
    corneringGSource = 'class_heuristic',
    brakeGSource = 'class_heuristic',
    corneringGConfidence = classConfidence,
    brakeGConfidence = classConfidence,
    speedAeroStrength = nil,
    speedAeroSource = nil,
    speedAeroConfidence = nil,
    source = 'class_heuristic',
    sourceDetail = classSource,
    capabilityTier = 'class_heuristic',
    capabilityConfidence = classConfidence,
  }

  local externalRealLife = real_life_priors.read(car and car.carId)
  local realLife = realLifePriorCapability(carProfile, externalRealLife)
  if realLife then
    local realLifeBaseUsed = realLife.corneringG ~= nil and realLife.brakeG ~= nil
    if realLife.corneringG ~= nil then
      selected.corneringG = finiteNumber(realLife.corneringG, selected.corneringG)
      selected.corneringGSource = 'real_life_prior'
      selected.corneringGConfidence = realLife.confidence
    end
    if realLife.brakeG ~= nil then
      selected.brakeG = finiteNumber(realLife.brakeG, selected.brakeG)
      selected.brakeGSource = 'real_life_prior'
      selected.brakeGConfidence = realLife.confidence
    end
    selected.speedAeroStrength = realLife.speedAeroStrength
    if realLife.speedAeroStrength ~= nil then
      selected.speedAeroSource = 'real_life_prior'
      selected.speedAeroConfidence = realLife.confidence
    end
    selected.realLifePriorSource = realLife.sourceDetail
    selected.realLifePriorConfidence = realLife.confidence
    if realLifeBaseUsed then
      selected.source = 'real_life_prior'
      selected.sourceDetail = realLife.sourceDetail
      selected.capabilityTier = 'real_life_prior'
      selected.capabilityConfidence = realLife.confidence
    end
  end

  local hasExplicitProfile = profile and profile.carKey and tostring(profile.carKey) ~= 'default'
  if hasExplicitProfile and carProfile then
    local profileBaseUsed = carProfile.has_cornering_g == true and carProfile.has_brake_decel_g == true
    local profileConfidence = clamp(carProfile.confidence, 0.55, 0.82)
    if carProfile.has_cornering_g == true then
      selected.corneringG = finiteNumber(carProfile.cornering_g, selected.corneringG)
      selected.corneringGSource = 'curated_profile'
      selected.corneringGConfidence = profileConfidence
    end
    if carProfile.has_brake_decel_g == true then
      selected.brakeG = finiteNumber(carProfile.brake_decel_g, selected.brakeG)
      selected.brakeGSource = 'curated_profile'
      selected.brakeGConfidence = profileConfidence
    end
    if carProfile.has_speed_aero_strength == true then
      selected.speedAeroStrength = clamp(carProfile.speed_aero_strength, 0.0, 0.30)
      selected.speedAeroSource = 'curated_profile'
      selected.speedAeroConfidence = profileConfidence
    end
    if profileBaseUsed then
      selected.source = 'curated_profile'
      selected.sourceDetail = 'curated_profile'
      selected.capabilityTier = 'curated_profile'
      selected.capabilityConfidence = profileConfidence
    end
  end

  local localKnowledge = knowledge_base.carPrior(car)
  if localKnowledge then
    local localBaseUsed = localKnowledge.corneringG ~= nil and localKnowledge.brakeG ~= nil
    local localConfidence = clamp(localKnowledge.confidence, 0.40, finiteNumber(settings.KNOWLEDGE_BASE_CAR_PRIOR_CONFIDENCE_CAP, 0.78))
    if localKnowledge.corneringG ~= nil then
      selected.corneringG = finiteNumber(localKnowledge.corneringG, selected.corneringG)
      selected.corneringGSource = 'local_adaptive_db'
      selected.corneringGConfidence = localConfidence
    end
    if localKnowledge.brakeG ~= nil then
      selected.brakeG = finiteNumber(localKnowledge.brakeG, selected.brakeG)
      selected.brakeGSource = 'local_adaptive_db'
      selected.brakeGConfidence = localConfidence
    end
    if localKnowledge.speedAeroStrength ~= nil then
      selected.speedAeroStrength = clamp(localKnowledge.speedAeroStrength, 0.0, 0.30)
      selected.speedAeroSource = 'local_adaptive_db'
      selected.speedAeroConfidence = localConfidence
    end
    selected.localKnowledgePriorSource = tostring(localKnowledge.sourceDetail or 'local_adaptive_db')
    selected.localKnowledgePriorConfidence = localConfidence
    selected.localKnowledgePriorSamples = finiteNumber(localKnowledge.samples, 0.0)
    if localBaseUsed then
      selected.source = 'local_adaptive_db'
      selected.sourceDetail = tostring(localKnowledge.sourceDetail or 'local_adaptive_db')
      selected.capabilityTier = 'local_adaptive_db'
      selected.capabilityConfidence = localConfidence
    end
  end

  local physicsCapability = car and car.physicsCapability or physics_capability.read(car and car.carId, nil)
  local physicsConfidence = clamp(physicsCapability and physicsCapability.confidence, 0.0, 0.93)
  if hasTrustedPhysicsCapability(physicsCapability, physicsConfidence) then
    local fallbackAeroStrength = selected.speedAeroStrength
    local fallbackAeroSource = tostring(selected.speedAeroSource or '')
    local fallbackAeroConfidence = selected.speedAeroConfidence
    if hasTrustedPhysicsCorneringCapability(physicsCapability, physicsConfidence) then
      selected.corneringG = finiteNumber(physicsCapability.corneringG, selected.corneringG)
      selected.corneringGSource = 'ac_physics_setup'
      selected.corneringGConfidence = physicsConfidence
    end
    if hasTrustedPhysicsBrakeCapability(physicsCapability, physicsConfidence) then
      selected.brakeG = finiteNumber(physicsCapability.brakeG, selected.brakeG)
      selected.brakeGSource = 'ac_physics_setup'
      selected.brakeGConfidence = physicsConfidence
    end
    if physicsCapability.speedAeroStrength ~= nil and
      isTrustedPhysicsAeroStatus(physicsCapability.aeroDataStatus) then
      selected.speedAeroStrength = clamp(physicsCapability.speedAeroStrength, 0.0, 0.30)
      selected.speedAeroSource = 'ac_physics_setup'
      selected.speedAeroConfidence = physicsConfidence
    elseif fallbackAeroStrength ~= nil and
      (fallbackAeroSource == 'curated_profile' or fallbackAeroSource == 'real_life_prior') then
      selected.speedAeroStrength = clamp(fallbackAeroStrength, 0.0, 0.30)
      selected.speedAeroSource = 'ac_physics_setup+' .. fallbackAeroSource .. '_aero_fallback'
      selected.speedAeroConfidence = clamp(
        finiteNumber(fallbackAeroConfidence, finiteNumber(settings.CAPABILITY_REAL_LIFE_PRIOR_CONFIDENCE, 0.55)),
        0.0,
        finiteNumber(settings.AERO_EXPLICIT_FALLBACK_CONFIDENCE_CAP, 0.62))
    else
      selected.speedAeroStrength = nil
      selected.speedAeroSource = nil
      selected.speedAeroConfidence = nil
    end
    selected.source = 'ac_physics_setup'
    selected.sourceDetail = tostring(physicsCapability.source or 'ac_physics_unpacked')
    selected.capabilityTier = 'ac_physics_setup'
    selected.capabilityConfidence = physicsConfidence
  end

  return selected
end

function wheelAverage(car, key, fallback, lo, hi)
  local sum, count = 0, 0
  for _, wheel in ipairs(car and car.wheels or {}) do
    local value = tonumber(wheel and wheel[key])
    if value and value == value and value ~= math.huge and value ~= -math.huge then
      if lo then value = math.max(lo, value) end
      if hi then value = math.min(hi, value) end
      sum = sum + value
      count = count + 1
    end
  end
  if count == 0 then return fallback end
  return sum / count
end

local function wheelRangeAverage(car, key, firstIndex, lastIndex, fallback, lo, hi)
  local wheels = car and car.wheels or {}
  local first = math.max(1, math.floor(finiteNumber(firstIndex, 1) + 0.5))
  local last = math.min(#wheels, math.floor(finiteNumber(lastIndex, #wheels) + 0.5))
  local sum, count = 0, 0
  for index = first, last do
    local wheel = wheels[index]
    local value = tonumber(wheel and wheel[key])
    if value and value == value and value ~= math.huge and value ~= -math.huge then
      if lo then value = math.max(lo, value) end
      if hi then value = math.min(hi, value) end
      sum = sum + value
      count = count + 1
    end
  end
  if count == 0 then return fallback end
  return sum / count
end

local function wheelRangeAverageAbs(car, key, firstIndex, lastIndex, fallback, lo, hi)
  local wheels = car and car.wheels or {}
  local first = math.max(1, math.floor(finiteNumber(firstIndex, 1) + 0.5))
  local last = math.min(#wheels, math.floor(finiteNumber(lastIndex, #wheels) + 0.5))
  local sum, count = 0, 0
  for index = first, last do
    local wheel = wheels[index]
    local value = tonumber(wheel and wheel[key])
    if value and value == value and value ~= math.huge and value ~= -math.huge then
      value = math.abs(value)
      if lo then value = math.max(lo, value) end
      if hi then value = math.min(hi, value) end
      sum = sum + value
      count = count + 1
    end
  end
  if count == 0 then return fallback end
  return sum / count
end

function wheelAverageAbs(car, key, fallback, lo, hi)
  local sum, count = 0, 0
  for _, wheel in ipairs(car and car.wheels or {}) do
    local value = tonumber(wheel and wheel[key])
    if value and value == value and value ~= math.huge and value ~= -math.huge then
      value = math.abs(value)
      if lo then value = math.max(lo, value) end
      if hi then value = math.min(hi, value) end
      sum = sum + value
      count = count + 1
    end
  end
  if count == 0 then return fallback end
  return sum / count
end

local function wheelSlipStressForRange(car, firstIndex, lastIndex, hi)
  hi = math.max(1.0, finiteNumber(hi, 4.0))
  local ndSlipStress = math.max(0.0, wheelRangeAverage(car, 'ndSlip', firstIndex, lastIndex, 1.0, 0.0, hi) - 1.0)
  local ratioStress = wheelRangeAverageAbs(car, 'slipRatio', firstIndex, lastIndex, 0.0, 0.0, hi) *
    finiteNumber(settings.TYRE_SLIP_RATIO_STRESS_SCALE, 6.0)
  local angleStress = wheelRangeAverageAbs(car, 'slipAngle', firstIndex, lastIndex, 0.0, 0.0, hi) *
    finiteNumber(settings.TYRE_SLIP_ANGLE_STRESS_SCALE, 6.0)
  local rawStress = wheelRangeAverageAbs(car, 'slip', firstIndex, lastIndex, 0.0, 0.0, hi) *
    finiteNumber(settings.TYRE_RAW_SLIP_STRESS_SCALE, 1.0)
  return clamp(math.max(ndSlipStress, ratioStress, angleStress, rawStress), 0.0, hi)
end

function wheelSlipStress(car, hi)
  hi = math.max(1.0, finiteNumber(hi, 4.0))
  local ndSlipStress = math.max(0.0, wheelAverage(car, 'ndSlip', 1.0, 0.0, hi) - 1.0)
  local ratioStress = wheelAverageAbs(car, 'slipRatio', 0.0, 0.0, hi) *
    finiteNumber(settings.TYRE_SLIP_RATIO_STRESS_SCALE, 6.0)
  local angleStress = wheelAverageAbs(car, 'slipAngle', 0.0, 0.0, hi) *
    finiteNumber(settings.TYRE_SLIP_ANGLE_STRESS_SCALE, 6.0)
  local rawStress = wheelAverageAbs(car, 'slip', 0.0, 0.0, hi) *
    finiteNumber(settings.TYRE_RAW_SLIP_STRESS_SCALE, 1.0)
  return clamp(math.max(ndSlipStress, ratioStress, angleStress, rawStress), 0.0, hi)
end

local function tyreTemperatureDelta(car)
  local sum, count = 0, 0
  for _, wheel in ipairs(car and car.wheels or {}) do
    local core = tonumber(wheel and wheel.tyreCoreTemperature)
    local optimum = tonumber(wheel and wheel.tyreOptimumTemperature)
    if core and optimum and core > 0 and optimum > 0 then
      sum = sum + math.abs(core - optimum)
      count = count + 1
    end
  end
  if count == 0 then return 0 end
  return sum / count
end

local function tyreTemperatureDeltaRange(car, firstIndex, lastIndex)
  local wheels = car and car.wheels or {}
  local first = math.max(1, math.floor(finiteNumber(firstIndex, 1) + 0.5))
  local last = math.min(#wheels, math.floor(finiteNumber(lastIndex, #wheels) + 0.5))
  local sum, count = 0, 0
  for index = first, last do
    local wheel = wheels[index]
    local core = tonumber(wheel and wheel.tyreCoreTemperature)
    local optimum = tonumber(wheel and wheel.tyreOptimumTemperature)
    if core and optimum and core > 0 and optimum > 0 then
      sum = sum + math.abs(core - optimum)
      count = count + 1
    end
  end
  if count == 0 then return 0 end
  return sum / count
end

local function normalizedPressurePsi(value)
  local pressure = finiteNumber(value, 0.0)
  if pressure <= 0.0 then return 0.0 end
  if pressure <= 5.0 then return pressure * 14.5037738 end
  if pressure > 80.0 and pressure <= 500.0 then return pressure * 0.145037738 end
  return pressure
end

local function setupPressureForWheel(car, wheelIndex)
  local setupSnapshot = car and car.setupSnapshot or {}
  local index = math.floor(finiteNumber(wheelIndex, 0.0) + 0.5)
  if index == 1 then return normalizedPressurePsi(setupSnapshot.pressureLF) end
  if index == 2 then return normalizedPressurePsi(setupSnapshot.pressureRF) end
  if index == 3 then return normalizedPressurePsi(setupSnapshot.pressureLR) end
  if index == 4 then return normalizedPressurePsi(setupSnapshot.pressureRR) end
  return 0.0
end

local function physicsPressureForWheel(car, wheelIndex, frontKey, rearKey, averageKey)
  local physicsCapability = car and car.physicsCapability or {}
  local index = math.floor(finiteNumber(wheelIndex, 0.0) + 0.5)
  local axleValue = 0.0
  if index == 1 or index == 2 then
    axleValue = normalizedPressurePsi(physicsCapability[frontKey])
  elseif index == 3 or index == 4 then
    axleValue = normalizedPressurePsi(physicsCapability[rearKey])
  end
  if axleValue > 0.0 then return axleValue end
  return normalizedPressurePsi(physicsCapability[averageKey])
end

local function physicsPressureIdealForWheel(car, wheelIndex)
  return physicsPressureForWheel(car, wheelIndex, 'tyreFrontPressureIdealPsi', 'tyreRearPressureIdealPsi', 'tyrePressureIdealPsi')
end

local function physicsPressureStaticForWheel(car, wheelIndex)
  return physicsPressureForWheel(car, wheelIndex, 'tyreFrontPressureStaticPsi', 'tyreRearPressureStaticPsi', 'tyrePressureStaticPsi')
end

local function setupPressurePenalty(car, firstIndex, lastIndex)
  local wheels = car and car.wheels or {}
  local first = math.max(1, math.floor(finiteNumber(firstIndex, 1) + 0.5))
  local last = math.min(#wheels, math.floor(finiteNumber(lastIndex, #wheels) + 0.5))
  local mult = math.max(0.0, finiteNumber(settings.SETUP_PRESSURE_FALLBACK_MULT, 0.20))
  local maxPenalty = clamp(settings.SETUP_PRESSURE_FALLBACK_MAX_PENALTY, 0.0, 0.18)
  local sum, deltaSum, count, physicsStaticCount = 0, 0, 0, 0
  local pressureSources = {}
  for index = first, last do
    local setupPressure = setupPressureForWheel(car, index)
    local wheel = wheels[index]
    local wheelStatic = normalizedPressurePsi(wheel and wheel.tyreStaticPressure)
    local static = physicsPressureStaticForWheel(car, index)
    if static > 0.0 then
      physicsStaticCount = physicsStaticCount + 1
    else
      static = wheelStatic
    end
    if setupPressure > 0 and static and static > 0 then
      sum = sum + math.min(maxPenalty, math.abs((setupPressure / static) - 1.0) * mult)
      deltaSum = deltaSum + math.abs(setupPressure - static)
      count = count + 1
      pressureSources[index] = 'setup'
    elseif wheelStatic > 0.0 then
      pressureSources[index] = 'live_static'
    end
  end
  if count == 0 then
    return 0.0, 'none', 0.0, labelledPressureSourceTyres(pressureSources), compactPressureSourceTyres(pressureSources)
  end
  return sum / count, physicsStaticCount > 0 and 'setup_physics_static' or 'setup_static',
    deltaSum / count, labelledPressureSourceTyres(pressureSources), compactPressureSourceTyres(pressureSources)
end

local function pressurePenaltyRange(car, firstIndex, lastIndex)
  local wheels = car and car.wheels or {}
  local first = math.max(1, math.floor(finiteNumber(firstIndex, 1) + 0.5))
  local last = math.min(#wheels, math.floor(finiteNumber(lastIndex, #wheels) + 0.5))
  local setupMult = math.max(0.0, finiteNumber(settings.SETUP_PRESSURE_FALLBACK_MULT, 0.20))
  local setupMaxPenalty = clamp(settings.SETUP_PRESSURE_FALLBACK_MAX_PENALTY, 0.0, 0.18)
  local sum, pressureCount, livePressureCount, physicsIdealCount = 0, 0, 0, 0
  local setupPressureCount, setupDeltaSum, setupStaticCount = 0, 0, 0
  local pressureSources = {}
  for index = first, last do
    local wheel = wheels[index]
    local pressure = normalizedPressurePsi(wheel and wheel.tyrePressure)
    local wheelStatic = normalizedPressurePsi(wheel and wheel.tyreStaticPressure)
    local setupPressure = setupPressureForWheel(car, index)
    local setupStatic = physicsPressureStaticForWheel(car, index)
    local setupUsesPhysicsStatic = setupStatic > 0.0
    if not setupUsesPhysicsStatic then
      setupStatic = wheelStatic
    end
    local baseline = physicsPressureIdealForWheel(car, index)
    if baseline > 0.0 then
      physicsIdealCount = physicsIdealCount + 1
    else
      baseline = wheelStatic
    end
    if pressure > 0 and baseline > 0 then
      sum = sum + math.min(0.18, math.abs((pressure / baseline) - 1.0) * 0.35)
      pressureCount = pressureCount + 1
      livePressureCount = livePressureCount + 1
      pressureSources[index] = 'live_current'
    elseif setupPressure > 0.0 and setupStatic > 0.0 then
      sum = sum + math.min(setupMaxPenalty, math.abs((setupPressure / setupStatic) - 1.0) * setupMult)
      pressureCount = pressureCount + 1
      setupPressureCount = setupPressureCount + 1
      setupDeltaSum = setupDeltaSum + math.abs(setupPressure - setupStatic)
      if setupUsesPhysicsStatic then
        setupStaticCount = setupStaticCount + 1
      end
      pressureSources[index] = 'setup'
    elseif wheelStatic > 0.0 then
      pressureSources[index] = 'live_static'
    end
  end
  if pressureCount > 0 then
    local source = livePressureCount > 0 and (physicsIdealCount > 0 and 'live_physics_ideal' or 'live') or
      (setupStaticCount > 0 and 'setup_physics_static' or 'setup_static')
    local setupDelta = setupPressureCount > 0 and setupDeltaSum / setupPressureCount or 0.0
    return sum / pressureCount, source,
      setupDelta, labelledPressureSourceTyres(pressureSources), compactPressureSourceTyres(pressureSources)
  end
  return setupPressurePenalty(car, firstIndex, lastIndex)
end

local function pressurePenalty(car)
  return pressurePenaltyRange(car, 1, #(car and car.wheels or {}))
end

local function tyreStressConfidence(car, nonPressureStress, slipStress, floor)
  local fullSpeed = math.max(1.0, finiteNumber(settings.TYRE_TEMP_FULL_CONFIDENCE_SPEED_KPH, 110.0))
  local stressReference = math.max(0.01, finiteNumber(settings.TYRE_TEMP_STRESS_CONFIDENCE, 0.18))
  local speedConfidence = clamp(finiteNumber(car and car.speedKmh, 0.0) / fullSpeed, 0.0, 1.0)
  local stress = finiteNumber(nonPressureStress, 0.0) + math.min(0.10, finiteNumber(slipStress, 0.0) * 0.08)
  local stressConfidence = clamp(stress / stressReference, 0.0, 1.0)
  return math.max(clamp(floor, 0.0, 1.0), speedConfidence, stressConfidence)
end

local function tyreTemperatureConfidence(car, nonPressureStress, slipStress)
  return tyreStressConfidence(car, nonPressureStress, slipStress,
    finiteNumber(settings.TYRE_TEMP_UNCORROBORATED_SCALE, 0.25))
end

local function tyrePressureConfidence(car, nonPressureStress, slipStress)
  return tyreStressConfidence(car, nonPressureStress, slipStress,
    finiteNumber(settings.TYRE_PRESSURE_UNCORROBORATED_SCALE, 0.15))
end

local function setupResetReason(telemetry)
  local currentResetReason = tostring(telemetry and telemetry.currentResetReason or 'none')
  if currentResetReason ~= '' and currentResetReason ~= 'none' then return currentResetReason end
  local lastResetReason = tostring(telemetry and telemetry.lastResetReason or 'none')
  if lastResetReason ~= '' and lastResetReason ~= 'none' then return lastResetReason end
  return 'none'
end

local function setupLiveProvenMinSamples(telemetry, minAxisSamples)
  local minSamples = math.max(1.0, finiteNumber(minAxisSamples, 1.0))
  local resetReason = setupResetReason(telemetry)
  if resetReason == 'setup_changed' then
    return math.max(minSamples, finiteNumber(settings.SETUP_CHANGE_LIVE_PROVEN_MIN_SAMPLES, 6.0))
  end
  return minSamples
end

local function setupAdaptationForSamples(car, telemetry, capabilityConfidence, setupMechanicalRisk, sampleCount, minSamples, liveProven, liveProvenMinSamples)
  local baseConfidence = clamp(capabilityConfidence, 0.0, 1.0)
  sampleCount = math.max(0.0, finiteNumber(sampleCount, 0.0))
  liveProvenMinSamples = math.max(math.max(1.0, finiteNumber(minSamples, 1.0)), finiteNumber(liveProvenMinSamples, minSamples))
  local effectiveLiveProven = liveProven == true and sampleCount >= liveProvenMinSamples
  if effectiveLiveProven then return 'live_telemetry_proven', 1.0, 1.0 end

  local setupFingerprint = tostring(car and car.setupFingerprint or '')
  local setupKnown = hasMeaningfulSetupFingerprint(car, setupFingerprint)
  local mechanicalRisk = setupKnown and clamp(setupMechanicalRisk, 0.0, 0.12) or 0.0
  local proof = clamp(sampleCount / liveProvenMinSamples, 0.0, 1.0)
  local capFloor = setupKnown and 0.70 or 0.62
  capFloor = clamp(capFloor - mechanicalRisk, setupKnown and 0.58 or 0.54, capFloor)
  local confidenceCap = clamp(capFloor + (1.0 - capFloor) * proof, 0.0, 1.0)
  local state = 'setup_observed'
  local resetReason = setupResetReason(telemetry)

  if not setupKnown then
    state = 'setup_unknown'
  elseif finiteNumber(sampleCount, 0.0) <= 0.0 then
    state = resetReason == 'setup_changed' and 'setup_changed_unproven' or 'setup_unproven'
  elseif resetReason == 'setup_changed' and proof < 1.0 then
    state = 'setup_changed_warming'
  elseif proof < 1.0 then
    state = 'setup_adapting'
  end

  return state, math.min(baseConfidence, confidenceCap), proof
end

local function setupAdaptation(car, telemetry, capabilityTier, capabilityConfidence, setupMechanicalRisk, brakeLiveProven, cornerLiveProven)
  local brakeSamples = math.max(0.0, finiteNumber(telemetry and (telemetry.brakeCapabilitySamples or telemetry.cleanStrongBrakeSamples), 0.0))
  local cornerSamples = math.max(0.0, finiteNumber(telemetry and (telemetry.cornerCapabilitySamples or telemetry.strongCornerSamples), 0.0))
  local minAxisSamples = math.max(1.0, finiteNumber(settings.TELEMETRY_MIN_SAMPLES, 2.0))
  local liveProvenMinSamples = setupLiveProvenMinSamples(telemetry, minAxisSamples)
  local setupBrakeAdaptationState, setupBrakeAdaptationConfidence, setupBrakeAdaptationProof =
    setupAdaptationForSamples(car, telemetry, capabilityConfidence, setupMechanicalRisk, brakeSamples, minAxisSamples, brakeLiveProven, liveProvenMinSamples)
  local setupCornerAdaptationState, setupCornerAdaptationConfidence, setupCornerAdaptationProof =
    setupAdaptationForSamples(car, telemetry, capabilityConfidence, setupMechanicalRisk, cornerSamples, minAxisSamples, cornerLiveProven, liveProvenMinSamples)
  local setupChangedWarmupActive = setupResetReason(telemetry) == 'setup_changed' and
    (setupBrakeAdaptationProof < 1.0 or setupCornerAdaptationProof < 1.0)
  local brakeAxisLiveProven = setupBrakeAdaptationState == 'live_telemetry_proven'
  local cornerAxisLiveProven = setupCornerAdaptationState == 'live_telemetry_proven'

  local tier = tostring(capabilityTier or '')
  local setupAdaptationState, setupAdaptationConfidence, setupAdaptationProof
  if tier == 'live_telemetry' and brakeAxisLiveProven and cornerAxisLiveProven then
    setupAdaptationState = 'live_telemetry_proven'
    setupAdaptationConfidence = 1.0
    setupAdaptationProof = 1.0
  elseif tier == 'live_telemetry' and (brakeAxisLiveProven or cornerAxisLiveProven) then
    setupAdaptationState = 'partial_live_telemetry'
    setupAdaptationConfidence = math.max(setupBrakeAdaptationConfidence, setupCornerAdaptationConfidence)
    setupAdaptationProof = (setupBrakeAdaptationProof + setupCornerAdaptationProof) * 0.5
  else
    setupAdaptationState, setupAdaptationConfidence, setupAdaptationProof =
      setupAdaptationForSamples(car, telemetry, capabilityConfidence, setupMechanicalRisk,
        brakeSamples + cornerSamples, minAxisSamples * 2.0, false, liveProvenMinSamples * 2.0)
  end

  return setupAdaptationState, setupAdaptationConfidence, setupAdaptationProof,
    setupBrakeAdaptationState, setupBrakeAdaptationConfidence, setupBrakeAdaptationProof,
    setupCornerAdaptationState, setupCornerAdaptationConfidence, setupCornerAdaptationProof,
    liveProvenMinSamples, setupChangedWarmupActive
end

local function telemetrySampleConfidenceBoost(samples)
  local fullSamples = math.max(1.0, finiteNumber(settings.TELEMETRY_CONFIDENCE_FULL_SAMPLES, 12.0))
  local maxBoost = clamp(settings.TELEMETRY_CONFIDENCE_MAX_BOOST, 0.0, 0.10)
  return clamp(finiteNumber(samples, 0.0) / fullSamples, 0.0, 1.0) * maxBoost
end

local function liveEnvelopeAxisPenalty(observedG, modeledG, limitProof)
  if limitProof ~= true then return 0.0 end
  observedG = finiteNumber(observedG, 0.0)
  modeledG = finiteNumber(modeledG, 0.0)
  if observedG <= 0.0 or modeledG <= 0.0 then return 0.0 end

  local deadband = clamp(settings.TELEMETRY_LIVE_ENVELOPE_SHORTFALL_DEADBAND, 0.0, 0.30)
  local fullShortfall = math.max(0.01, finiteNumber(settings.TELEMETRY_LIVE_ENVELOPE_FULL_SHORTFALL, 0.35))
  local maxPenalty = clamp(settings.TELEMETRY_LIVE_ENVELOPE_MAX_CONFIDENCE_PENALTY, 0.0, 0.25)
  local shortfall = 1.0 - observedG / modeledG
  return clamp((shortfall - deadband) / fullShortfall, 0.0, 1.0) * maxPenalty
end

local function liveGripEnvelope(telemetry, brakeG, corneringG, capabilityConfidence)
  local baseConfidence = clamp(capabilityConfidence, 0.0, 1.0)
  if settings.TELEMETRY_LIVE_ENVELOPE_ENABLED ~= true then
    return 'disabled', 0.0, baseConfidence
  end

  local maxPenalty = clamp(settings.TELEMETRY_LIVE_ENVELOPE_MAX_CONFIDENCE_PENALTY, 0.0, 0.25)
  local decay = clamp(settings.TELEMETRY_LIVE_ENVELOPE_DECAY, 0.0, 1.0)
  local brakePenalty = liveEnvelopeAxisPenalty(
    telemetry and telemetry.observedBrakeG,
    brakeG,
    telemetry and telemetry.brakeLimitSampleThisFrame == true)
  local cornerPenalty = liveEnvelopeAxisPenalty(
    telemetry and telemetry.observedCorneringG,
    corneringG,
    telemetry and telemetry.cornerLimitSampleThisFrame == true)
  local decayedPenalty = clamp(telemetry and telemetry.liveGripEnvelopePenalty or 0.0, 0.0, maxPenalty) * decay
  local penalty = clamp(math.max(decayedPenalty, brakePenalty, cornerPenalty), 0.0, maxPenalty)
  local state = 'nominal'
  if brakePenalty > 0.0 and cornerPenalty > 0.0 then
    state = 'brake_and_corner_limit'
  elseif brakePenalty > 0.0 then
    state = 'brake_limit_shortfall'
  elseif cornerPenalty > 0.0 then
    state = 'corner_limit_shortfall'
  elseif penalty > 0.001 then
    state = 'recent_limit_decay'
  end

  local confidence = clamp(baseConfidence - penalty, 0.35, baseConfidence)
  if telemetry then
    telemetry.liveGripEnvelopePenalty = penalty
    telemetry.liveGripEnvelopeConfidence = confidence
    telemetry.liveGripEnvelopeState = state
  end
  return state, penalty, confidence
end

local function finiteSetupCount(values)
  if type(values) ~= 'table' then return 0 end
  local count = 0
  for _, value in ipairs(values) do
    local number = tonumber(value)
    if number and number == number and number ~= math.huge and number ~= -math.huge then
      count = count + 1
    end
  end
  return count
end

local function setupMapEmpty(map)
  if type(map) ~= 'table' then return true end
  return next(map) == nil
end

local function setupValueSpread(snapshot, setupMap, setupKeys, snapshotKeys)
  local minValue = math.huge
  local maxValue = -math.huge
  local count = 0
  local mapAvailable = not setupMapEmpty(setupMap)
  for index, setupKey in ipairs(setupKeys or {}) do
    local value = mapAvailable and finiteNumber(setupMap and setupMap[setupKey], nil) or nil
    if value == nil and not mapAvailable then
      value = finiteNumber(snapshot and snapshot[(snapshotKeys or {})[index]], nil)
    end
    if value ~= nil then
      if value < minValue then minValue = value end
      if value > maxValue then maxValue = value end
      count = count + 1
    end
  end
  if count <= 0 then return 0.0 end
  return clamp(maxValue - minValue, 0.0, 1000.0)
end

local function mechanicalSetupRisk(setupArbBalance, setupCamberSpread, setupToeSpread)
  local arbRisk = clamp((math.abs(finiteNumber(setupArbBalance, 0.0)) - 0.35) / 0.65, 0.0, 1.0) * 0.04
  local camberRisk = clamp((finiteNumber(setupCamberSpread, 0.0) - 2.5) / 7.5, 0.0, 1.0) * 0.03
  local toeRisk = clamp((finiteNumber(setupToeSpread, 0.0) - 0.35) / 1.65, 0.0, 1.0) * 0.04
  return clamp(arbRisk + camberRisk + toeRisk, 0.0, 0.10)
end

local function setupValueRisk(values, countScale, countMaxRisk, spreadStart, spreadRange, spreadMaxRisk, cap)
  if type(values) ~= 'table' or #values <= 0 then return 0.0 end
  local minValue = math.huge
  local maxValue = -math.huge
  local count = 0
  for _, raw in ipairs(values) do
    local value = finiteNumber(raw, nil)
    if value ~= nil then
      value = math.abs(value)
      if value < minValue then minValue = value end
      if value > maxValue then maxValue = value end
      count = count + 1
    end
  end
  if count <= 0 then return 0.0 end
  local countRisk = clamp(count / math.max(1.0, finiteNumber(countScale, 1.0)), 0.0, 1.0) * finiteNumber(countMaxRisk, 0.0)
  local spreadRisk = clamp((maxValue - minValue - finiteNumber(spreadStart, 0.0)) / math.max(1.0, finiteNumber(spreadRange, 1.0)), 0.0, 1.0) *
    finiteNumber(spreadMaxRisk, 0.0)
  return clamp(countRisk + spreadRisk, 0.0, finiteNumber(cap, 0.0))
end

local function drivetrainSetupRisk(values)
  return setupValueRisk(values, 8.0, 0.012, 25.0, 75.0, 0.018, 0.03)
end

local function damperSetupRisk(values)
  return setupValueRisk(values, 12.0, 0.010, 12.0, 36.0, 0.015, 0.025)
end

local function gearSetupRisk(values)
  return setupValueRisk(values, 6.0, 0.006, 6.0, 18.0, 0.009, 0.015)
end

local function diffSetupRisk(values)
  return setupValueRisk(values, 3.0, 0.010, 35.0, 65.0, 0.015, 0.025)
end

local function assistSetupRisk(values)
  return setupValueRisk(values, 4.0, 0.008, 50.0, 50.0, 0.007, 0.015)
end

local function mechanicalSetupCapabilityDeltas(mechanicalRisk, setupAeroRisk)
  mechanicalRisk = clamp(finiteNumber(mechanicalRisk, 0.0), 0.0, 0.10)
  setupAeroRisk = clamp(finiteNumber(setupAeroRisk, 0.0), 0.0, 0.08)
  local corneringDelta = -clamp(mechanicalRisk * 0.65 + setupAeroRisk * 0.50, 0.0, 0.08)
  local brakeDelta = -clamp(mechanicalRisk * 0.35 + setupAeroRisk * 0.20, 0.0, 0.04)
  return corneringDelta, brakeDelta
end

local function aeroSetupBalanceRisk(wingValues)
  if type(wingValues) ~= 'table' or #wingValues < 2 then return 0.0, 0.0, 0.0 end
  local values = {}
  local minValue = math.huge
  local maxValue = -math.huge
  for _, raw in ipairs(wingValues) do
    local value = finiteNumber(raw, nil)
    if value ~= nil then
      value = math.max(0.0, value)
      values[#values + 1] = value
      if value < minValue then minValue = value end
      if value > maxValue then maxValue = value end
    end
  end
  if #values < 2 then return 0.0, 0.0, 0.0 end
  local midpoint = math.max(1, math.floor(#values / 2))
  local frontSum, frontCount = 0.0, 0
  local rearSum, rearCount = 0.0, 0
  for index, value in ipairs(values) do
    if index <= midpoint then
      frontSum = frontSum + value
      frontCount = frontCount + 1
    else
      rearSum = rearSum + value
      rearCount = rearCount + 1
    end
  end
  if frontCount <= 0 or rearCount <= 0 then return 0.0, 0.0, 0.0 end
  local frontAvg = frontSum / frontCount
  local rearAvg = rearSum / rearCount
  local setupAeroBalance = clamp((frontAvg - rearAvg) / math.max(1.0, frontAvg + rearAvg), -1.0, 1.0)
  local setupAeroSpread = clamp(maxValue - minValue, 0.0, 1000.0)
  local balanceRisk = clamp((math.abs(setupAeroBalance) - 0.35) / 0.65, 0.0, 1.0) * 0.06
  local spreadRisk = clamp((setupAeroSpread - 6.0) / 14.0, 0.0, 1.0) * 0.02
  return setupAeroBalance, setupAeroSpread, clamp(balanceRisk + spreadRisk, 0.0, 0.08)
end

local function setupListToken(values, step, decimals)
  if type(values) ~= 'table' or #values == 0 then return 'none' end
  local out = {}
  step = math.max(0.001, finiteNumber(step, 1.0))
  decimals = math.max(0, math.floor(finiteNumber(decimals, 0.0) + 0.5))
  for _, raw in ipairs(values) do
    local value = finiteNumber(raw, 0.0)
    local bucketed = math.floor(value / step + 0.5) * step
    if decimals > 0 then
      out[#out + 1] = string.format('%.' .. tostring(decimals) .. 'f', bucketed)
    else
      out[#out + 1] = tostring(math.floor(bucketed + 0.5))
    end
  end
  return table.concat(out, ',')
end

local damperSetupSections = {
  'DAMP_BUMP_LF', 'DAMP_REBOUND_LF', 'DAMP_FAST_BUMP_LF', 'DAMP_FAST_REBOUND_LF',
  'DAMP_BUMP_RF', 'DAMP_REBOUND_RF', 'DAMP_FAST_BUMP_RF', 'DAMP_FAST_REBOUND_RF',
  'DAMP_BUMP_LR', 'DAMP_REBOUND_LR', 'DAMP_FAST_BUMP_LR', 'DAMP_FAST_REBOUND_LR',
  'DAMP_BUMP_RR', 'DAMP_REBOUND_RR', 'DAMP_FAST_BUMP_RR', 'DAMP_FAST_REBOUND_RR',
  'DAMPER_BUMP_LF', 'DAMPER_REBOUND_LF', 'DAMPER_FAST_BUMP_LF', 'DAMPER_FAST_REBOUND_LF',
  'DAMPER_BUMP_RF', 'DAMPER_REBOUND_RF', 'DAMPER_FAST_BUMP_RF', 'DAMPER_FAST_REBOUND_RF',
  'DAMPER_BUMP_LR', 'DAMPER_REBOUND_LR', 'DAMPER_FAST_BUMP_LR', 'DAMPER_FAST_REBOUND_LR',
  'DAMPER_BUMP_RR', 'DAMPER_REBOUND_RR', 'DAMPER_FAST_BUMP_RR', 'DAMPER_FAST_REBOUND_RR',
}

local gearSetupSections = {
  'FINAL_GEAR_RATIO',
  'GEAR_1', 'GEAR_2', 'GEAR_3', 'GEAR_4', 'GEAR_5', 'GEAR_6', 'GEAR_7',
  'GEAR_8', 'GEAR_9', 'GEAR_10',
}

local diffSetupSections = {
  'DIFF_POWER', 'DIFF_COAST', 'DIFF_PRELOAD',
}

local function setupMapValues(setupMap, setupKeys)
  if type(setupMap) ~= 'table' then return {} end
  local out = {}
  for _, setupKey in ipairs(setupKeys or {}) do
    local value = finiteNumber(setupMap[setupKey], nil)
    if value ~= nil then out[#out + 1] = value end
  end
  return out
end

local function setupMapToken(setupMap, setupKeys, step, decimals)
  if type(setupMap) ~= 'table' then return 'none' end
  local out = {}
  step = math.max(0.001, finiteNumber(step, 1.0))
  decimals = math.max(0, math.floor(finiteNumber(decimals, 0.0) + 0.5))
  for _, setupKey in ipairs(setupKeys or {}) do
    local value = finiteNumber(setupMap[setupKey], nil)
    if value ~= nil then
      local bucketed = math.floor(value / step + 0.5) * step
      local tokenName = tostring(setupKey):lower()
      local valueToken = decimals > 0 and
        string.format('%.' .. tostring(decimals) .. 'f', bucketed) or tostring(math.floor(bucketed + 0.5))
      out[#out + 1] = tokenName .. ':' .. valueToken
    end
  end
  if #out <= 0 then return 'none' end
  return table.concat(out, ',')
end

local function setupMechanicalSummary(car)
  local snapshot = car and car.setupSnapshot or {}
  local mechanicalSetupValues = snapshot.mechanicalSetupValues
  local drivetrainSetupValues = snapshot.drivetrainSetupValues
  local assistSetupValues = snapshot.assistSetupValues
  local mechanicalSetupMap = snapshot.mechanicalSetupMap
  local damperSetupValues = setupMapValues(snapshot.damperSetupMap, damperSetupSections)
  local gearSetupValues = setupMapValues(snapshot.gearSetupMap, gearSetupSections)
  local diffSetupValues = setupMapValues(snapshot.diffSetupMap, diffSetupSections)
  local setupMechanicalCount = finiteSetupCount(mechanicalSetupValues)
  local setupMechanicalSource = setupMechanicalCount > 0 and 'setup_mechanical' or 'none'
  local setupDrivetrainCount = finiteSetupCount(drivetrainSetupValues)
  local setupDamperCount = finiteSetupCount(damperSetupValues)
  local setupGearCount = finiteSetupCount(gearSetupValues)
  local setupDiffCount = finiteSetupCount(diffSetupValues)
  local setupAssistCount = finiteSetupCount(assistSetupValues)
  local mapAvailable = not setupMapEmpty(mechanicalSetupMap)
  local arbFrontRaw = mapAvailable and mechanicalSetupMap.ARB_FRONT or snapshot.arbFront
  local arbRearRaw = mapAvailable and mechanicalSetupMap.ARB_REAR or snapshot.arbRear
  local arbFront = math.abs(finiteNumber(arbFrontRaw, 0.0))
  local arbRear = math.abs(finiteNumber(arbRearRaw, 0.0))
  local setupArbBalance = 0.0
  if arbFront > 0.0 or arbRear > 0.0 then
    setupArbBalance = clamp((arbFront - arbRear) / math.max(1.0, arbFront + arbRear), -1.0, 1.0)
  end
  local setupCamberSpread = setupValueSpread(snapshot, mechanicalSetupMap,
    { 'CAMBER_LF', 'CAMBER_RF', 'CAMBER_LR', 'CAMBER_RR' },
    { 'camberLF', 'camberRF', 'camberLR', 'camberRR' })
  local setupToeSpread = setupValueSpread(snapshot, mechanicalSetupMap,
    { 'TOE_OUT_LF', 'TOE_OUT_RF', 'TOE_OUT_LR', 'TOE_OUT_RR' },
    { 'toeOutLF', 'toeOutRF', 'toeOutLR', 'toeOutRR' })
  local setupAeroBalance, setupAeroSpread, setupAeroRisk = aeroSetupBalanceRisk(snapshot.wingValues)
  local mechanicalRisk = setupMechanicalCount > 0 and
    mechanicalSetupRisk(setupArbBalance, setupCamberSpread, setupToeSpread) or 0.0
  local setupDamperRisk = damperSetupRisk(damperSetupValues)
  local setupGearRisk = gearSetupRisk(gearSetupValues)
  local setupDiffRisk = diffSetupRisk(diffSetupValues)
  local setupDrivetrainRisk = clamp(setupGearRisk + setupDiffRisk, 0.0, 0.04)
  if setupDrivetrainRisk <= 0.0 and setupDrivetrainCount > 0 then
    setupDrivetrainRisk = drivetrainSetupRisk(drivetrainSetupValues)
  end
  local setupAssistRisk = assistSetupRisk(assistSetupValues)
  local setupDomainDrivetrainRisk = setupGearRisk + setupDiffRisk
  if setupDomainDrivetrainRisk <= 0.0 then setupDomainDrivetrainRisk = setupDrivetrainRisk end
  local nonAeroSetupRisk = clamp(mechanicalRisk + setupDamperRisk + setupDomainDrivetrainRisk + setupAssistRisk, 0.0, 0.10)
  local setupMechanicalRisk = clamp(nonAeroSetupRisk + setupAeroRisk, 0.0, 0.12)
  local globalCorneringMechanicalDelta, globalBrakeMechanicalDelta = mechanicalSetupCapabilityDeltas(nonAeroSetupRisk, setupAeroRisk)

  return {
    setupMechanicalCount = setupMechanicalCount,
    setupMechanicalSource = setupMechanicalSource,
    setupDrivetrainCount = setupDrivetrainCount,
    setupDrivetrainSource = setupDrivetrainCount > 0 and 'setup_drivetrain' or 'none',
    setupDrivetrainToken = setupListToken(drivetrainSetupValues, 0.5, 1),
    setupDrivetrainRisk = setupDrivetrainRisk,
    setupDamperCount = setupDamperCount,
    setupDamperSource = setupDamperCount > 0 and 'setup_damper' or 'none',
    setupDamperToken = setupMapToken(snapshot.damperSetupMap, damperSetupSections, 1.0, 0),
    setupDamperRisk = setupDamperRisk,
    setupGearCount = setupGearCount,
    setupGearSource = setupGearCount > 0 and 'setup_gear' or 'none',
    setupGearToken = setupMapToken(snapshot.gearSetupMap, gearSetupSections, 0.01, 2),
    setupGearRisk = setupGearRisk,
    setupDiffCount = setupDiffCount,
    setupDiffSource = setupDiffCount > 0 and 'setup_diff' or 'none',
    setupDiffToken = setupMapToken(snapshot.diffSetupMap, diffSetupSections, 0.5, 1),
    setupDiffRisk = setupDiffRisk,
    setupAssistCount = setupAssistCount,
    setupAssistSource = setupAssistCount > 0 and 'setup_assist' or 'none',
    setupAssistToken = setupListToken(assistSetupValues, 1.0, 0),
    setupAssistRisk = setupAssistRisk,
    setupArbBalance = setupArbBalance,
    setupCamberSpread = setupCamberSpread,
    setupToeSpread = setupToeSpread,
    setupAeroBalance = setupAeroBalance,
    setupAeroSpread = setupAeroSpread,
    setupAeroRisk = setupAeroRisk,
    setupMechanicalRisk = setupMechanicalRisk,
    setupMechanicalConfidencePenalty = setupMechanicalRisk,
    globalCorneringMechanicalDelta = globalCorneringMechanicalDelta,
    globalBrakeMechanicalDelta = globalBrakeMechanicalDelta,
  }
end

local function containsWetTyreName(car)
  local name = tostring(car and (car.tyresName or car.tyresLongName) or ''):lower()
  return name:find('wet', 1, true) ~= nil or
    name:find('rain', 1, true) ~= nil or
    name:find('inter', 1, true) ~= nil
end

local function wetPenalty(car, cornering)
  local sim = car and car.sim or {}
  local rainIntensity = clamp(sim.rainIntensity, 0.0, 1.0)
  local rainWetness = clamp(sim.rainWetness, 0.0, 1.0)
  local rainWater = clamp(sim.rainWater, 0.0, 1.0)
  local penalty = math.max(
    rainIntensity * (cornering and 0.12 or 0.10),
    rainWetness * (cornering and 0.16 or 0.13),
    rainWater * (cornering and 0.28 or 0.24))
  if containsWetTyreName(car) then penalty = penalty * 0.58 end
  return penalty, rainIntensity, rainWetness, rainWater
end

local function trackThermalFactor(car, cornering)
  local sim = car and car.sim or {}
  local ambientTemperatureC = finiteNumber(sim.ambientTemperature, 26.0)
  local roadTemperatureC = finiteNumber(sim.roadTemperature, 32.0)
  local deviation = math.max(0.0, math.abs(roadTemperatureC - 32.0) - 12.0)
  local limit = cornering and 0.10 or 0.07
  local penalty = math.min(limit, deviation / 45.0 * limit)
  if roadTemperatureC < 10.0 then penalty = penalty + (cornering and 0.04 or 0.03) end
  if roadTemperatureC > 60.0 then penalty = penalty + (cornering and 0.04 or 0.03) end
  return clamp(1.0 - penalty, cornering and 0.84 or 0.88, 1.02), roadTemperatureC, ambientTemperatureC
end

local function windStabilityFactor(car)
  local sim = car and car.sim or {}
  local windSpeedKmh = clamp(sim.windSpeedKmh, 0.0, 160.0)
  local penalty = math.min(0.05, windSpeedKmh / 160.0 * 0.05)
  return clamp(1.0 - penalty, 0.94, 1.0), windSpeedKmh
end

local function normalizedBrakeBias(value)
  local bias = finiteNumber(value, 0.0)
  if bias > 1.5 then bias = bias / 100.0 end
  if bias <= 0 then return 0.58 end
  return clamp(bias, 0.35, 0.80)
end

local function liveOrSetupPositive(car, liveKey, setupKey, fallback)
  local liveValue = finiteNumber(car and car[liveKey], 0.0)
  if liveValue > 0.0 then return liveValue end
  local setupSnapshot = car and car.setupSnapshot or {}
  local setupValue = finiteNumber(setupSnapshot[setupKey], fallback)
  if setupValue and setupValue > 0.0 then return setupValue end
  return finiteNumber(setupValue, fallback or 0.0)
end

local function liveKnownOrSetupPositive(car, liveKey, setupKey, fallback)
  local liveKnown = car and car[liveKey .. 'Known'] == true
  local liveValue = finiteNumber(car and car[liveKey], fallback or 0.0)
  if liveKnown then return liveValue end
  return liveOrSetupPositive(car, liveKey, setupKey, fallback)
end

local function setupKnown(car, key)
  local setupSnapshot = car and car.setupSnapshot or {}
  return setupSnapshot[key .. 'Known'] == true
end

local function brakePowerPercentValue(value)
  local brakePower = finiteNumber(value, 100.0)
  if brakePower <= 2.0 then brakePower = brakePower * 100.0 end
  return clamp(brakePower, 0.0, 110.0)
end

local function brakePowerSourceToken(car)
  if car and car.brakePowerMultKnown == true then return 'live' end
  if finiteNumber(car and car.brakePowerMult, 0.0) > 0.0 then return 'live' end
  local setupSnapshot = car and car.setupSnapshot or {}
  if setupKnown(car, 'brakePowerMult') or brakePowerPercentValue(setupSnapshot.brakePowerMult) ~= 100.0 then return 'setup' end
  return 'fallback'
end

local function brakeBiasSourceToken(car)
  if car and car.brakeBiasKnown == true then return 'live' end
  if finiteNumber(car and car.brakeBias, 0.0) > 0.0 then return 'live' end
  local setupSnapshot = car and car.setupSnapshot or {}
  if setupKnown(car, 'frontBias') or finiteNumber(setupSnapshot.frontBias, 0.0) > 0.0 then return 'setup' end
  local physicsCapability = car and car.physicsCapability or {}
  if finiteNumber(physicsCapability.brakeFrontShare, 0.0) > 0.0 then return 'physics' end
  return 'fallback'
end

local function wingSourceToken(car)
  if car and car.wingSettingKnown == true then return 'live' end
  if finiteNumber(car and car.wingSetting, 0.0) > 0.0 then return 'live' end
  local setupSnapshot = car and car.setupSnapshot or {}
  if setupKnown(car, 'wingSetting') or finiteNumber(setupSnapshot.wingSetting, 0.0) > 0.0 then return 'setup' end
  return 'fallback'
end

local function setupBrakeBias(car)
  local setupBias = liveOrSetupPositive(car, 'brakeBias', 'frontBias', 0.0)
  if setupBias > 0 then return setupBias end
  local physicsCapability = car and car.physicsCapability or {}
  return finiteNumber(physicsCapability.brakeFrontShare, 0.0)
end

local function setupFactor(car)
  local state = tostring(car and car.setupState or 'unknown')
  local factor = 1.0
  if state == 'illegal' then
    factor = 0.88
  elseif state == 'validating' then
    factor = 0.94
  end
  return clamp(factor, 0.85, 1.05)
end

local function brakeBiasBrakeFactor(car)
  local brakeBias = normalizedBrakeBias(setupBrakeBias(car))
  local physicsCapability = car and car.physicsCapability or {}
  local referenceBias = normalizedBrakeBias(physicsCapability.brakeFrontShare)
  if referenceBias <= 0.0 then referenceBias = 0.58 end
  local biasPenalty = math.min(0.10, math.abs(brakeBias - referenceBias) * 0.30)
  return clamp(1.0 - biasPenalty, 0.90, 1.0), brakeBias
end

local function assistInterventionPenalty(car)
  local assistPenalty = 1.0
  local brakeAssistPenalty = 1.0
  if car and car.absInAction then
    assistPenalty = assistPenalty * 0.98
    brakeAssistPenalty = brakeAssistPenalty * 0.96
  end
  if car and car.tractionControlInAction then
    assistPenalty = assistPenalty * 0.97
  end
  return clamp(assistPenalty, 0.90, 1.0), clamp(brakeAssistPenalty, 0.88, 1.0)
end

local function setupBrakePowerMult(car)
  local brakePowerMult = liveKnownOrSetupPositive(car, 'brakePowerMult', 'brakePowerMult', 100.0)
  if brakePowerMult > 2.0 then brakePowerMult = brakePowerMult / 100.0 end
  return clamp(brakePowerMult, 0.75, 1.10)
end

local function setupBallastKg(car)
  local ballastKg = liveKnownOrSetupPositive(car, 'ballast', 'ballast', 0.0)
  return clamp(ballastKg, 0.0, 500.0)
end

local function setupRestrictor(car)
  local restrictor = liveKnownOrSetupPositive(car, 'restrictor', 'restrictor', 0.0)
  return clamp(restrictor, 0.0, 100.0)
end

local function setupFuelLoadL(car)
  local setupFuel = liveKnownOrSetupPositive(car, 'fuel', 'fuel', 0.0)
  return clamp(setupFuel, 0.0, 250.0)
end

local function fuelLoadState(car)
  local liveFuel = finiteNumber(car and car.fuel, 0.0)
  local setupFuel = setupFuelLoadL(car)
  local maxFuel = finiteNumber(car and car.maxFuel, 0.0)
  local fuelLoadL = 0.0
  local fuelLoadSource = 'unknown'
  if car and car.fuelKnown == true then
    fuelLoadL = clamp(liveFuel, 0.0, 250.0)
    fuelLoadSource = 'live_car_fuel'
  elseif liveFuel > 0.0 then
    fuelLoadL = clamp(liveFuel, 0.0, 250.0)
    fuelLoadSource = 'live_car_fuel'
  elseif setupFuel > 0.0 then
    fuelLoadL = setupFuel
    fuelLoadSource = 'setup_fuel'
  end
  local fuelCapacityL = maxFuel
  if fuelCapacityL <= 0.0 then
    fuelCapacityL = math.max(fuelLoadL, finiteNumber(settings.FUEL_FALLBACK_REFERENCE_L, 60.0))
  end
  fuelCapacityL = clamp(fuelCapacityL, 0.0, 250.0)
  local fuelFraction = 0.0
  if fuelCapacityL > 0.0 then fuelFraction = clamp(fuelLoadL / fuelCapacityL, 0.0, 1.0) end
  return fuelFraction, fuelLoadL, fuelCapacityL, fuelLoadSource
end

local function fuelMassRatio(car, fuelLoadL)
  fuelLoadL = clamp(fuelLoadL, 0.0, 250.0)
  local fuelMassKg = fuelLoadL * finiteNumber(settings.FUEL_MASS_KG_PER_L, 0.74)
  local physicsCapability = car and car.physicsCapability or {}
  local massKg = finiteNumber(car and car.mass, 0.0)
  if massKg <= 0.0 then massKg = finiteNumber(physicsCapability.massKg, 0.0) end
  if massKg <= 0.0 then return fuelMassKg, 0.0 end
  return fuelMassKg, clamp(fuelMassKg / math.max(250.0, massKg + fuelMassKg), 0.0, 0.30)
end

local function ballastLoadFactor(car)
  local ballastKg = setupBallastKg(car)
  if ballastKg <= 0.0 then return 1.0, ballastKg end
  local physicsCapability = car and car.physicsCapability or {}
  local massKg = finiteNumber(car and car.mass, 0.0)
  if massKg <= 0.0 then massKg = finiteNumber(physicsCapability.massKg, 0.0) end
  if massKg <= 0.0 then return 0.98, ballastKg end
  local ballastRatio = ballastKg / math.max(250.0, massKg + ballastKg)
  return clamp(1.0 - ballastRatio * 0.35, 0.92, 1.0), ballastKg
end

local function normalizedDamageLevel(car)
  local damageLevel = finiteNumber(car and car.damage, 0.0)
  if damageLevel > 1.5 then damageLevel = damageLevel / 100.0 end
  return clamp(damageLevel, 0.0, 1.0)
end

local function damageFactors(car)
  local damageLevel = normalizedDamageLevel(car)
  if damageLevel <= 0.0 then return damageLevel, 1.0, 1.0, 1.0 end
  local cornerFactor = clamp(1.0 - damageLevel * 0.18, 0.82, 1.0)
  local brakeFactor = clamp(1.0 - damageLevel * 0.14, 0.86, 1.0)
  local aeroFactor = clamp(1.0 - damageLevel * 0.22, 0.78, 1.0)
  return damageLevel, cornerFactor, brakeFactor, aeroFactor
end

local function setupAeroFactor(car, aeroStrength)
  local wingSetting = liveKnownOrSetupPositive(car, 'wingSetting', 'wingSetting', 0.0)
  if wingSetting <= 0 then return 1.0, wingSetting end
  local strength = clamp(finiteNumber(aeroStrength, -1.0), -1.0, 0.30)
  local scale = 0.0015
  if strength >= 0.0 then
    scale = clamp(0.0005 + strength * 0.0180, 0.0005, 0.0060)
  elseif looksLikeOpenWheeler(car) then
    scale = 0.0030
  elseif looksLikeRacingCar(car) then
    scale = 0.0022
  end
  return clamp(1.0 + math.min(0.10, wingSetting * scale), 1.0, 1.10), wingSetting
end

local function speedAeroStrength(car, carProfile)
  if carProfile and carProfile.has_speed_aero_strength == true then
    return clamp(carProfile.speed_aero_strength, 0.0, 0.30)
  end
  local profileCorneringG = finiteNumber(carProfile and carProfile.cornering_g, 0.0)
  if looksLikeOpenWheeler(car) then
    return clamp(finiteNumber(settings.INFER_OPEN_WHEELER_SPEED_AERO_STRENGTH, 0.18), 0.0, 0.30)
  elseif looksLikePrototypeCar(car) or profileCorneringG >= finiteNumber(settings.INFER_PROTOTYPE_CORNERING_G, 2.15) then
    return clamp(finiteNumber(settings.INFER_PROTOTYPE_SPEED_AERO_STRENGTH, 0.120), 0.0, 0.30)
  elseif looksLikeClubCupCar(car) then
    return clamp(finiteNumber(settings.INFER_TRACK_DAY_SPEED_AERO_STRENGTH, 0.030), 0.0, 0.30)
  elseif looksLikeRacingCar(car) then
    return clamp(finiteNumber(settings.INFER_RACING_CAR_SPEED_AERO_STRENGTH, 0.055), 0.0, 0.30)
  elseif profileCorneringG >= finiteNumber(settings.INFER_TRACK_DAY_CORNERING_G, 1.35) then
    return clamp(finiteNumber(settings.INFER_TRACK_DAY_SPEED_AERO_STRENGTH, 0.030), 0.0, 0.30)
  elseif looksLikeSportRoadCar(car) then
    return clamp(finiteNumber(settings.INFER_SPORT_ROAD_SPEED_AERO_STRENGTH, 0.015), 0.0, 0.30)
  end
  return 0.0
end

local function aeroConfidenceForSource(source, capabilityConfidence)
  source = tostring(source or 'class_heuristic')
  if source == 'ac_physics_setup' then
    return clamp(capabilityConfidence, 0.65, 0.95)
  elseif source == 'ac_physics_no_aero' then
    return 0.0
  elseif source == 'curated_profile' then
    return clamp(capabilityConfidence, 0.55, 0.84)
  elseif source == 'real_life_prior' then
    return clamp(capabilityConfidence, 0.35, 0.62)
  end
  return clamp(settings.CAPABILITY_CLASS_HEURISTIC_CONFIDENCE, 0.35, 0.60)
end

local function isClassHeuristicAeroSource(source)
  return string.find(tostring(source or ''), 'class_heuristic', 1, true) ~= nil
end

local function isExplicitFallbackAeroSource(source)
  return string.find(tostring(source or ''), 'aero_fallback', 1, true) ~= nil
end

local function trustedAeroStrength(strength, confidence, source)
  strength = clamp(strength, 0.0, 0.30)
  local fullTrust = math.max(0.01, finiteNumber(settings.AERO_CONFIDENCE_FULL_TRUST, 0.90))
  local unprovenScale = clamp(settings.AERO_CONFIDENCE_UNPROVEN_SCALE, 0.0, 1.0)
  local trust = clamp(finiteNumber(confidence, 0.0) / fullTrust, 0.0, 1.0)
  local trusted = clamp(strength * (unprovenScale + (1.0 - unprovenScale) * trust), 0.0, 0.30)
  if isClassHeuristicAeroSource(source) then
    local classMax = clamp(settings.AERO_CLASS_HEURISTIC_MAX_UNPROVEN_STRENGTH, 0.0, 0.30)
    return math.min(trusted, classMax)
  end
  return trusted
end

local function aeroConfidenceWithTelemetry(source, confidence, telemetry)
  local samples = math.max(0, math.floor(finiteNumber(telemetry and telemetry.aeroHighSpeedCornerSamples, 0.0)))
  if samples >= math.max(1, math.floor(finiteNumber(settings.TELEMETRY_AERO_MIN_SAMPLES, 3))) then
    if isClassHeuristicAeroSource(source) then
      local classCap = clamp(settings.AERO_CLASS_HEURISTIC_TELEMETRY_CONFIDENCE_CAP, 0.35, 0.75)
      return math.min(confidence, classCap), tostring(source or 'unknown') .. '+high_speed_telemetry_uncalibrated'
    end
    if isExplicitFallbackAeroSource(source) then
      local fallbackCap = clamp(settings.AERO_EXPLICIT_FALLBACK_CONFIDENCE_CAP, 0.35, 0.75)
      return math.min(confidence, fallbackCap), tostring(source or 'unknown') .. '+high_speed_telemetry_uncalibrated'
    end
    return math.max(confidence, clamp(settings.TELEMETRY_AERO_CONFIDENCE, 0.70, 0.95)),
      tostring(source or 'unknown') .. '+high_speed_telemetry'
  end
  return confidence, tostring(source or 'unknown')
end

local function observedSpeedAeroStrength(observedCorneringG, noSpeedAeroG, speedKmh)
  observedCorneringG = finiteNumber(observedCorneringG, 0.0)
  noSpeedAeroG = finiteNumber(noSpeedAeroG, 0.0)
  speedKmh = finiteNumber(speedKmh, 0.0)
  if speedKmh < finiteNumber(settings.TELEMETRY_AERO_MIN_SPEED_KPH, 145.0) or noSpeedAeroG <= 0.25 then
    return nil
  end
  local reference = math.max(1.0, finiteNumber(settings.SPEED_AERO_REFERENCE_KPH, 260.0))
  local speedRatio = clamp(speedKmh / reference, 0.35, 1.0)
  local observedFactor = clamp(observedCorneringG / math.max(0.25, noSpeedAeroG), 0.0, 1.35)
  if observedFactor <= 1.01 then return 0.0 end
  return clamp((observedFactor - 1.0) / math.max(0.01, speedRatio * speedRatio), 0.0, 0.30)
end

local function updateTelemetrySpeedAeroStrength(telemetry, car, noSpeedAeroG)
  if not (telemetry and telemetry.aeroStrengthSampleThisFrame == true) then return end
  local speedKmh = finiteNumber(telemetry.observedAeroSpeedKph, finiteNumber(car and car.speedKmh, 0.0))
  local observed = observedSpeedAeroStrength(telemetry.observedAeroCorneringG, noSpeedAeroG, speedKmh)
  if observed == nil then return end

  local samples = math.max(1, math.floor(finiteNumber(telemetry.aeroHighSpeedLimitSamples, 1.0)))
  local previous = clamp(telemetry.learnedSpeedAeroStrength, 0.0, 0.30)
  local blend = clamp(settings.TELEMETRY_AERO_STRENGTH_BLEND, 0.05, 1.0)
  telemetry.observedSpeedAeroStrength = observed
  if samples <= 1 or previous <= 0.0 then
    telemetry.learnedSpeedAeroStrength = observed
  else
    telemetry.learnedSpeedAeroStrength = clamp(previous + (observed - previous) * blend, 0.0, 0.30)
  end
end

local function speedAeroFactor(car, strength)
  local speed = clamp(car and car.speedKmh, 0.0, 420.0)
  local reference = math.max(1.0, finiteNumber(settings.SPEED_AERO_REFERENCE_KPH, 260.0))
  local speedRatio = clamp(speed / reference, 0.0, 1.0)
  strength = clamp(strength, 0.0, 0.30)
  return clamp(1.0 + strength * speedRatio * speedRatio, 0.90, 1.22)
end

local function brakeSpeedAeroFactor(car, strength)
  local speed = clamp(car and car.speedKmh, 0.0, 420.0)
  local reference = math.max(1.0, finiteNumber(settings.SPEED_AERO_REFERENCE_KPH, 260.0))
  local speedRatio = clamp(speed / reference, 0.0, 1.0)
  strength = clamp(strength, 0.0, 0.30)
  local scale = math.max(0.0, finiteNumber(settings.BRAKE_SPEED_AERO_EFFECT_SCALE, 0.60))
  local maxFactor = math.max(1.0, finiteNumber(settings.BRAKE_SPEED_AERO_MAX_FACTOR, 1.16))
  return clamp(1.0 + strength * scale * speedRatio * speedRatio, 1.0, maxFactor)
end

local function weightedAxlePositive(frontValue, rearValue, averageValue, frontWeight)
  frontValue = finiteNumber(frontValue, 0.0)
  rearValue = finiteNumber(rearValue, 0.0)
  averageValue = finiteNumber(averageValue, 0.0)
  frontWeight = clamp(finiteNumber(frontWeight, 0.5), 0.15, 0.85)
  local rearWeight = 1.0 - frontWeight
  if frontValue > 0.0 and rearValue > 0.0 then
    return frontValue * frontWeight + rearValue * rearWeight
  end
  if frontValue > 0.0 then return frontValue end
  if rearValue > 0.0 then return rearValue end
  return averageValue
end

local function physicsLoadFrontShare(car, cornering)
  local physicsCapability = car and car.physicsCapability or {}
  local frontShare = finiteNumber(physicsCapability.cgLocation, 0.0)
  if frontShare > 0.0 then
    frontShare = clamp(frontShare, 0.25, 0.75)
  else
    frontShare = 0.50
  end
  if not cornering then
    frontShare = clamp(math.max(frontShare, normalizedBrakeBias(setupBrakeBias(car))), 0.50, 0.85)
  end
  return frontShare
end

local function physicsTyreLoadSensitivityFactor(car, cornering)
  local physicsCapability = car and car.physicsCapability or {}
  local sensitivity = 0.0
  local loadRefN = 0.0
  local frontSensitivity = 0.0
  local rearSensitivity = 0.0
  local frontLoadRefN = finiteNumber(physicsCapability.tyreFrontLoadRefN, 0.0)
  local rearLoadRefN = finiteNumber(physicsCapability.tyreRearLoadRefN, 0.0)
  local frontShare = physicsLoadFrontShare(car, cornering)
  local rearShare = 1.0 - frontShare
  if cornering then
    frontSensitivity = finiteNumber(physicsCapability.tyreFrontLoadSensitivityLat, 0.0)
    rearSensitivity = finiteNumber(physicsCapability.tyreRearLoadSensitivityLat, 0.0)
    sensitivity = weightedAxlePositive(frontSensitivity, rearSensitivity, physicsCapability.tyreLoadSensitivityLat, frontShare)
    loadRefN = weightedAxlePositive(frontLoadRefN, rearLoadRefN, physicsCapability.tyreLoadRefN, frontShare)
  else
    frontSensitivity = finiteNumber(physicsCapability.tyreFrontLoadSensitivityLong, 0.0)
    rearSensitivity = finiteNumber(physicsCapability.tyreRearLoadSensitivityLong, 0.0)
    sensitivity = weightedAxlePositive(frontSensitivity, rearSensitivity, physicsCapability.tyreLoadSensitivityLong, frontShare)
    loadRefN = weightedAxlePositive(frontLoadRefN, rearLoadRefN, physicsCapability.tyreLoadRefN, frontShare)
  end

  local proof = {
    penalty = 0.0,
    loadRatio = 0.0,
    sensitivity = sensitivity,
  }
  proof.frontLoadShare = frontShare
  proof.rearLoadShare = rearShare
  if sensitivity <= 0.0 then return 1.0, proof end

  local _, fuelLoadL = fuelLoadState(car)
  local fuelMassKg = clamp(fuelLoadL, 0.0, 250.0) * finiteNumber(settings.FUEL_MASS_KG_PER_L, 0.74)
  local ballastKg = setupBallastKg(car)
  local massKg = finiteNumber(car and car.mass, 0.0)
  if massKg <= 0.0 then massKg = finiteNumber(physicsCapability.massKg, 0.0) end
  local extraLoadKg = math.max(0.0, fuelMassKg + ballastKg)
  local totalMassKg = math.max(250.0, massKg + extraLoadKg)
  local extraLoadRatio = clamp(extraLoadKg / totalMassKg, 0.0, 0.35)
  local referenceOverloadRatio = 0.0
  if frontLoadRefN > 0.0 and rearLoadRefN > 0.0 and massKg > 0.0 then
    local frontStaticWheelLoadN = massKg * 9.80665 * frontShare / 2.0
    local rearStaticWheelLoadN = massKg * 9.80665 * rearShare / 2.0
    local frontOverloadRatio = clamp(frontStaticWheelLoadN / frontLoadRefN - 1.0, 0.0, 0.50)
    local rearOverloadRatio = clamp(rearStaticWheelLoadN / rearLoadRefN - 1.0, 0.0, 0.50)
    referenceOverloadRatio = frontOverloadRatio * frontShare + rearOverloadRatio * rearShare
  elseif loadRefN > 0.0 and massKg > 0.0 then
    local staticWheelLoadN = massKg * 9.80665 / 4.0
    referenceOverloadRatio = clamp(staticWheelLoadN / loadRefN - 1.0, 0.0, 0.50)
  end

  local loadRatio = clamp(extraLoadRatio +
    referenceOverloadRatio * finiteNumber(settings.PHYSICS_TYRE_LOAD_REF_OVERLOAD_MULT, 0.35), 0.0, 0.50)
  local sensitivityGap = clamp(1.0 - sensitivity, 0.0, 0.35)
  local maxPenalty = clamp(settings.PHYSICS_TYRE_LOAD_SENSITIVITY_MAX_PENALTY, 0.0, 0.12)
  local stressMult = math.max(0.0, finiteNumber(settings.PHYSICS_TYRE_LOAD_SENSITIVITY_STRESS_MULT, 0.80))
  local penalty = clamp(sensitivityGap * loadRatio * stressMult, 0.0, maxPenalty)
  proof.penalty = penalty
  proof.loadRatio = loadRatio
  return clamp(1.0 - penalty, 1.0 - maxPenalty, 1.0), proof
end

local function tyreAxleStress(car, firstIndex, lastIndex, cornering)
  local tyreWear = clamp(wheelRangeAverage(car, 'tyreWear', firstIndex, lastIndex, 0.0, 0.0, 1.0), 0.0, 1.0)
  local tyreDirty = clamp(math.max(
    wheelRangeAverage(car, 'tyreDirty', firstIndex, lastIndex, 0.0, 0.0, 1.0),
    wheelRangeAverage(car, 'surfaceDirt', firstIndex, lastIndex, 0.0, 0.0, 1.0)), 0.0, 1.0)
  local tyreGrain = clamp(wheelRangeAverage(car, 'tyreGrain', firstIndex, lastIndex, 0.0, 0.0, 1.0), 0.0, 1.0)
  local tyreBlister = clamp(wheelRangeAverage(car, 'tyreBlister', firstIndex, lastIndex, 0.0, 0.0, 1.0), 0.0, 1.0)
  local tyreFlatSpot = clamp(wheelRangeAverage(car, 'tyreFlatSpot', firstIndex, lastIndex, 0.0, 0.0, 1.0), 0.0, 1.0)
  local tempDelta = tyreTemperatureDeltaRange(car, firstIndex, lastIndex)
  local pressure = pressurePenaltyRange(car, firstIndex, lastIndex)
  local slipStress = wheelSlipStressForRange(car, firstIndex, lastIndex, 3.0)

  local wearPenalty = tyreWear * (cornering and 0.18 or 0.12)
  local dirtyPenalty = tyreDirty * (cornering and 0.12 or 0.10)
  local grainPenalty = tyreGrain * 0.06
  local blisterPenalty = tyreBlister * 0.08
  local flatSpotPenalty = tyreFlatSpot * 0.05
  local slipPenalty = math.min(0.10, slipStress * 0.08)
  local nonPressureStress = wearPenalty + dirtyPenalty + grainPenalty + blisterPenalty + flatSpotPenalty
  local tempConfidence = tyreTemperatureConfidence(car, nonPressureStress, slipStress)
  local pressureConfidence = tyrePressureConfidence(car, nonPressureStress, slipStress)
  local trustedPressurePenalty = pressure * pressureConfidence
  local temperaturePenalty = math.min(math.abs(tempDelta), 45.0) / 45.0 * (cornering and 0.18 or 0.10) * tempConfidence
  return nonPressureStress + trustedPressurePenalty + slipPenalty + temperaturePenalty
end

local function tyreFactor(car, cornering)
  local tyreWear = clamp(wheelAverage(car, 'tyreWear', 0.0, 0.0, 1.0), 0.0, 1.0)
  local tyreDirty = clamp(math.max(
    wheelAverage(car, 'tyreDirty', 0.0, 0.0, 1.0),
    wheelAverage(car, 'surfaceDirt', 0.0, 0.0, 1.0)), 0.0, 1.0)
  local tyreGrain = clamp(wheelAverage(car, 'tyreGrain', 0.0, 0.0, 1.0), 0.0, 1.0)
  local tyreBlister = clamp(wheelAverage(car, 'tyreBlister', 0.0, 0.0, 1.0), 0.0, 1.0)
  local tyreFlatSpot = clamp(wheelAverage(car, 'tyreFlatSpot', 0.0, 0.0, 1.0), 0.0, 1.0)
  local tempDelta = tyreTemperatureDelta(car)
  local pressure, pressureSource, setupPressureDeltaPsi, pressureSourceTyres, pressureSourceTokens = pressurePenalty(car)
  local pressureSourceFields = pressureSourceFieldMap(pressureSourceTokens)
  local slipStress = wheelSlipStress(car, 3.0)

  local wearPenalty = tyreWear * (cornering and 0.18 or 0.12)
  local dirtyPenalty = tyreDirty * (cornering and 0.12 or 0.10)
  local grainPenalty = tyreGrain * 0.06
  local blisterPenalty = tyreBlister * 0.08
  local flatSpotPenalty = tyreFlatSpot * 0.05
  local slipPenalty = math.min(0.10, slipStress * 0.08)
  local nonPressureStress = wearPenalty + dirtyPenalty + grainPenalty + blisterPenalty + flatSpotPenalty
  local tempConfidence = tyreTemperatureConfidence(car, nonPressureStress, slipStress)
  local pressureConfidence = tyrePressureConfidence(car, nonPressureStress, slipStress)
  local trustedPressurePenalty = pressure * pressureConfidence
  local temperaturePenalty = math.min(math.abs(tempDelta), 45.0) / 45.0 * (cornering and 0.18 or 0.10) * tempConfidence
  local penalty = nonPressureStress + trustedPressurePenalty + slipPenalty + temperaturePenalty
  local frontAxleStress = tyreAxleStress(car, 1, 2, cornering)
  local rearAxleStress = tyreAxleStress(car, 3, 4, cornering)
  local worstAxleStress = math.max(frontAxleStress, rearAxleStress)
  local axleBalancePenalty = math.max(0.0, worstAxleStress - penalty) *
    finiteNumber(settings.TYRE_AXLE_STRESS_BALANCE_MULT, 0.45)
  penalty = penalty + axleBalancePenalty
  local physicsLoadSensitivityFactor, physicsLoadSensitivityProof = physicsTyreLoadSensitivityFactor(car, cornering)
  local tyreFactorValue = clamp(1.0 - penalty, cornering and 0.55 or 0.60, 1.0)
  tyreFactorValue = clamp(tyreFactorValue * physicsLoadSensitivityFactor, cornering and 0.52 or 0.58, 1.0)

  return tyreFactorValue, {
    tyreWear = tyreWear,
    tyreDirty = tyreDirty,
    tyreCoreTemperature = wheelAverage(car, 'tyreCoreTemperature', 0.0, 0.0, 180.0),
    tyreOptimumTemperature = wheelAverage(car, 'tyreOptimumTemperature', 0.0, 0.0, 180.0),
    tyreTempDeltaC = tempDelta,
    pressurePenalty = trustedPressurePenalty,
    pressureSource = pressureSource,
    pressureSourceTokens = pressureSourceTokens,
    pressureSourceTyres = pressureSourceTyres,
    pressureSourceTokenLF = pressureSourceFields.lf,
    pressureSourceTokenRF = pressureSourceFields.rf,
    pressureSourceTokenLR = pressureSourceFields.lr,
    pressureSourceTokenRR = pressureSourceFields.rr,
    setupPressureDeltaPsi = setupPressureDeltaPsi,
    slipStress = slipStress,
    tyreTempConfidence = tempConfidence,
    frontTyreStress = frontAxleStress,
    rearTyreStress = rearAxleStress,
    worstAxleTyreStress = worstAxleStress,
    axleBalancePenalty = axleBalancePenalty,
    physicsTyreLoadSensitivityFactor = physicsLoadSensitivityFactor,
    physicsTyreLoadSensitivityPenalty = physicsLoadSensitivityProof.penalty,
    physicsTyreLoadSensitivityLoadRatio = physicsLoadSensitivityProof.loadRatio,
    physicsTyreLoadSensitivityFrontShare = physicsLoadSensitivityProof.frontLoadShare,
    physicsTyreLoadSensitivityRearShare = physicsLoadSensitivityProof.rearLoadShare,
  }
end

local function summaryFor(context)
  return string.format(
    'roadGrip=%.2f surfaceGrip=%.2f rain=%.2f/%.2f/%.2f tyre=%.2f setup=%.2f aero=%.2f speedAero=%.2f corneringG=%.2f corneringGNoSpeedAero=%.2f brakeG=%.2f',
    context.roadGrip,
    context.surfaceGrip,
    context.rainIntensity,
    context.rainWetness,
    context.rainWater,
    context.tyreFactor,
    context.setupFactor,
    context.aeroFactor,
    context.speedAeroFactor,
    context.corneringG,
    context.corneringGNoSpeedAero,
    context.brakeG)
end

local function scaleBetween(value, lo, hi)
  return clamp((finiteNumber(value, lo) - lo) / math.max(0.01, hi - lo), 0.0, 1.0)
end

local function numericCapabilityClassFor(baseCorneringG, baseBrakeG)
  if baseCorneringG >= finiteNumber(settings.INFER_OPEN_WHEELER_CORNERING_G, 2.70) then
    return 'open_wheel'
  elseif baseCorneringG >= finiteNumber(settings.INFER_PROTOTYPE_CORNERING_G, 2.15) then
    return 'prototype'
  elseif baseCorneringG >= finiteNumber(settings.INFER_RACING_CAR_CORNERING_G, 1.55) then
    return 'race_gt'
  elseif baseCorneringG >= finiteNumber(settings.INFER_TRACK_DAY_CORNERING_G, 1.35) then
    return 'track_day'
  elseif baseCorneringG >= 1.16 then
    return 'sport_road'
  elseif baseCorneringG <= 1.08 and baseBrakeG <= 1.10 then
    return 'city_road'
  end
  return 'road'
end

local function nominalCapabilityClassFor(baseCorneringG, baseBrakeG, car)
  if looksLikeOpenWheeler(car) then
    return 'open_wheel'
  elseif looksLikePrototypeCar(car) then
    return 'prototype'
  elseif looksLikeRacingCar(car) then
    return 'race_gt'
  elseif looksLikeSportRoadCar(car) then
    return 'sport_road'
  end
  return numericCapabilityClassFor(baseCorneringG, baseBrakeG)
end

local function cueTransferScale(momentTransferClassScale, brakeTransferScale, aeroTransferScale)
  local cornerWeight = math.max(0.0, finiteNumber(settings.MOMENT_CUE_CLASS_CORNER_WEIGHT, 0.45))
  local brakeWeight = math.max(0.0, finiteNumber(settings.MOMENT_CUE_CLASS_BRAKE_WEIGHT, 0.40))
  local aeroWeight = math.max(0.0, finiteNumber(settings.MOMENT_CUE_CLASS_AERO_WEIGHT, 0.15))
  local totalWeight = math.max(0.01, cornerWeight + brakeWeight + aeroWeight)
  return clamp((momentTransferClassScale * cornerWeight + brakeTransferScale * brakeWeight +
    aeroTransferScale * aeroWeight) / totalWeight, 0.0, 1.0)
end

function M.read(car, profile, dtSeconds)
  car = car or {}
  local sim = car.sim or {}
  local carProfile = profileCar(profile)
  local trackProfile = profileTrack(profile)
  local roadGrip = clamp(sim.roadGrip or trackProfile.surface_grip_hint, 0.55, 1.25)
  local surfaceGrip = clamp(wheelAverage(car, 'surfaceGrip', trackProfile.surface_grip_hint or roadGrip, 0.25, 1.50), 0.45, 1.20)
  local wetCornerPenalty, rainIntensity, rainWetness, rainWater = wetPenalty(car, true)
  local wetBrakePenalty = wetPenalty(car, false)
  local trackThermalCornerFactor, roadTemperatureC, ambientTemperatureC = trackThermalFactor(car, true)
  local trackThermalBrakeFactor = trackThermalFactor(car, false)
  local windFactor, windSpeedKmh = windStabilityFactor(car)
  local cornerTyreFactor, tyreDetails = tyreFactor(car, true)
  local brakeTyreFactor, brakeTyreDetails = tyreFactor(car, false)
  local setup = setupFactor(car)
  local setupMechanical = setupMechanicalSummary(car)
  local brakeBiasBrakeFactorValue, brakeBias = brakeBiasBrakeFactor(car)
  local brakePowerMult = setupBrakePowerMult(car)
  local brakePowerSource = brakePowerSourceToken(car)
  local brakeBiasSource = brakeBiasSourceToken(car)
  local ballastLoadFactorValue, ballastKg = ballastLoadFactor(car)
  local restrictor = setupRestrictor(car)
  local damageLevel, damageCornerFactor, damageBrakeFactor, damageAeroFactor = damageFactors(car)
  local selectedCapability = selectBaseCapability(car, profile, carProfile)
  local baseCorneringG = finiteNumber(selectedCapability.corneringG, settings.DEFAULT_CORNERING_G)
  local baseBrakeG = finiteNumber(selectedCapability.brakeG, settings.DEFAULT_BRAKE_G)
  local capabilitySource = tostring(selectedCapability.source or 'class_heuristic')
  local capabilityTier = tostring(selectedCapability.capabilityTier or capabilitySource)
  local capabilityConfidence = clamp(selectedCapability.capabilityConfidence, 0.0, 1.0)
  local corneringGSource = tostring(selectedCapability.corneringGSource or capabilityTier)
  local brakeGSource = tostring(selectedCapability.brakeGSource or capabilityTier)
  local corneringGConfidence = clamp(selectedCapability.corneringGConfidence, 0.0, 1.0)
  local brakeGConfidence = clamp(selectedCapability.brakeGConfidence, 0.0, 1.0)
  local physicsCapability = car and car.physicsCapability or {}
  local physicsConfidence = clamp(physicsCapability and physicsCapability.confidence, 0.0, 0.93)
  local physicsCorneringCapabilityAvailable = hasTrustedPhysicsCorneringCapability(physicsCapability, physicsConfidence)
  local physicsBrakeCapabilityAvailable = hasTrustedPhysicsBrakeCapability(physicsCapability, physicsConfidence)
  local physicsAeroCapabilityAvailable = hasTrustedPhysicsAeroCapability(physicsCapability, physicsConfidence)
  local physicsMassKg = finiteNumber(physicsCapability.massKg, 0.0)
  local liveOrUiMassKg = finiteNumber(car and car.mass, 0.0)
  local carMassKg = liveOrUiMassKg
  local carMassSource = 'live_or_ui'
  if carMassKg <= 0.0 then
    if physicsMassKg > 0.0 then
      carMassKg = physicsMassKg
      carMassSource = 'ac_physics'
    else
      carMassKg = 0.0
      carMassSource = 'none'
    end
  end
  local telemetry = learnCapabilityFromTelemetry(car, dtSeconds)
  local aeroStrength = selectedCapability.speedAeroStrength
  local aeroSource = tostring(selectedCapability.speedAeroSource or '')
  local aeroConfidence = selectedCapability.speedAeroConfidence
  if aeroStrength == nil then
    if capabilityTier == 'ac_physics_setup' then
      aeroStrength = 0.0
      aeroSource = 'ac_physics_no_aero'
      aeroConfidence = 0.0
    else
      aeroStrength = speedAeroStrength(car, carProfile)
      aeroSource = 'class_heuristic'
    end
  end
  if aeroSource == '' then aeroSource = tostring(selectedCapability.capabilityTier or 'class_heuristic') end
  if aeroConfidence == nil then aeroConfidence = aeroConfidenceForSource(aeroSource, capabilityConfidence) end
  local aeroConfidenceSource = aeroSource
  local nominalAeroStrength = aeroStrength
  local liveSpeedAeroStrength = clamp(telemetry.learnedSpeedAeroStrength, 0.0, 0.30)
  local liveSpeedAeroSamples = math.max(0, math.floor(finiteNumber(telemetry.aeroHighSpeedLimitSamples, 0.0)))
  local liveAeroMinSamples = math.max(1, math.floor(finiteNumber(settings.TELEMETRY_AERO_STRENGTH_MIN_SAMPLES, 3)))
  if liveSpeedAeroSamples >= liveAeroMinSamples then
    aeroStrength = liveSpeedAeroStrength
    aeroSource = 'live_telemetry_speed_aero'
    aeroConfidence = math.max(aeroConfidence, clamp(settings.TELEMETRY_AERO_CONFIDENCE, 0.70, 0.95))
    aeroConfidenceSource = 'live_telemetry_speed_aero'
  else
    aeroConfidence, aeroConfidenceSource = aeroConfidenceWithTelemetry(aeroSource, aeroConfidence, telemetry)
  end
  aeroStrength = trustedAeroStrength(aeroStrength, aeroConfidence, aeroSource)
  local setupAero, wingSetting = setupAeroFactor(car, aeroStrength)
  local wingSource = wingSourceToken(car)
  local speedAero = speedAeroFactor(car, aeroStrength)
  local fuelFraction, fuelLoadL, fuelCapacityL, fuelLoadSource = fuelLoadState(car)
  local fuelMassKg, fuelMassRatio = fuelMassRatio(car, fuelLoadL)
  local fuelCornerFactor = clamp(1.0 - fuelFraction * 0.05, 0.92, 1.0)
  local fuelBrakeFactor = clamp(1.0 - fuelFraction * 0.04, 0.93, 1.0)
  local fuelMassCornerFactor = clamp(1.0 - fuelMassRatio * finiteNumber(settings.FUEL_MASS_CORNER_PENALTY_MULT, 0.34), 0.94, 1.0)
  local fuelMassBrakeFactor = clamp(1.0 - fuelMassRatio * finiteNumber(settings.FUEL_MASS_BRAKE_PENALTY_MULT, 0.28), 0.95, 1.0)
  local aero = clamp(speedAero * setupAero * damageAeroFactor, 0.84, 1.22)
  local assistPenalty, brakeAssistPenalty = assistInterventionPenalty(car)
  local mechanicalCorneringFactor = clamp(1.0 + setupMechanical.globalCorneringMechanicalDelta, 0.90, 1.02)
  local mechanicalBrakeFactor = clamp(1.0 + setupMechanical.globalBrakeMechanicalDelta, 0.92, 1.02)

  local nominalCapabilityClass = nominalCapabilityClassFor(baseCorneringG, baseBrakeG, car)
  local nominalTransferClassScale = clamp((baseCorneringG - finiteNumber(settings.INFER_ROAD_CAR_CORNERING_G, 1.05)) /
    math.max(0.01, finiteNumber(settings.INFER_OPEN_WHEELER_CORNERING_G, 2.70) -
      finiteNumber(settings.INFER_ROAD_CAR_CORNERING_G, 1.05)), 0.0, 1.0)
  local aeroNoSpeed = clamp(setupAero * damageAeroFactor, 0.84, 1.22)
  local corneringFactor = roadGrip * surfaceGrip * clamp(1.0 - wetCornerPenalty, 0.55, 1.0) *
    trackThermalCornerFactor * windFactor * cornerTyreFactor * fuelCornerFactor * fuelMassCornerFactor * aero * setup * assistPenalty
  local corneringFactorNoSpeedAero = roadGrip * surfaceGrip * clamp(1.0 - wetCornerPenalty, 0.55, 1.0) *
    trackThermalCornerFactor * windFactor * cornerTyreFactor * fuelCornerFactor * fuelMassCornerFactor * aeroNoSpeed * setup * assistPenalty
  local brakeSpeedAeroStrength = aeroStrength
  local brakeSpeedAeroFactorValue = brakeSpeedAeroFactor(car, brakeSpeedAeroStrength)
  local brakeFactor = clamp(roadGrip, 0.55, 1.20) * clamp(surfaceGrip, 0.45, 1.15) *
    clamp(1.0 - wetBrakePenalty, 0.58, 1.0) * trackThermalBrakeFactor * brakeTyreFactor * fuelBrakeFactor * fuelMassBrakeFactor *
    setup * brakePowerMult * brakeBiasBrakeFactorValue * brakeAssistPenalty * brakeSpeedAeroFactorValue
  corneringFactor = corneringFactor * ballastLoadFactorValue * damageCornerFactor
  corneringFactorNoSpeedAero = corneringFactorNoSpeedAero * ballastLoadFactorValue * damageCornerFactor
  brakeFactor = brakeFactor * ballastLoadFactorValue * damageBrakeFactor
  corneringFactor = corneringFactor * mechanicalCorneringFactor
  corneringFactorNoSpeedAero = corneringFactorNoSpeedAero * mechanicalCorneringFactor
  brakeFactor = brakeFactor * mechanicalBrakeFactor
  local maxBrakeG = finiteNumber(settings.MAX_DYNAMIC_BRAKE_G, 4.50)
  local corneringG = clamp(baseCorneringG * corneringFactor, 0.35, 4.50)
  local corneringGNoSpeedAero = clamp(baseCorneringG * corneringFactorNoSpeedAero, 0.35, 4.50)
  updateTelemetrySpeedAeroStrength(telemetry, car, corneringGNoSpeedAero)
  local brakeG = clamp(baseBrakeG * brakeFactor, 0.25, maxBrakeG)
  local learnedCorneringG = 0.0
  local learnedCorneringGNoSpeedAero = 0.0
  local learnedBrakeG = 0.0
  local telemetryUsed = false
  local brakeTelemetryUsed = false
  local cornerTelemetryUsed = false
  local brakeTelemetryLiveProven = false
  local cornerTelemetryLiveProven = false
  local brakeTelemetrySampleConfidence = 0.0
  local cornerTelemetrySampleConfidence = 0.0

  if settings.TELEMETRY_LEARNING_ENABLED == true then
    local minSamples = math.max(1, math.floor(finiteNumber(settings.TELEMETRY_MIN_SAMPLES, 2)))
    local downwardMinSamples = math.max(minSamples, math.floor(finiteNumber(settings.TELEMETRY_DOWNWARD_MIN_SAMPLES, 4)))
    local usageMult = clamp(settings.TELEMETRY_USAGE_MULT, 0.50, 1.05)
    local weakBrakeCapMult = clamp(settings.TELEMETRY_WEAK_BRAKE_CAP_MULT, 1.00, 1.50)
    local weakCornerCapMult = clamp(settings.TELEMETRY_WEAK_CORNER_CAP_MULT, 1.00, 1.50)
    if telemetry.brakeCapabilitySampleThisFrame then
      local observedBaseBrakeG = telemetry.observedBrakeG / math.max(0.25, brakeFactor)
      telemetry.learnedBaseBrakeG = updateLearnedPeak(telemetry.learnedBaseBrakeG, observedBaseBrakeG)
    end
    if telemetry.cornerSampleThisFrame then
      local observedBaseCorneringG = telemetry.observedCorneringG / math.max(0.25, corneringFactor)
      telemetry.learnedBaseCorneringG = updateLearnedPeak(telemetry.learnedBaseCorneringG, observedBaseCorneringG)
    end
    learnedBrakeG = clamp((telemetry.learnedBaseBrakeG or 0.0) * brakeFactor, 0.0, maxBrakeG)
    learnedCorneringG = clamp((telemetry.learnedBaseCorneringG or 0.0) * corneringFactor, 0.0, 4.50)
    learnedCorneringGNoSpeedAero = clamp((telemetry.learnedBaseCorneringG or 0.0) * corneringFactorNoSpeedAero, 0.0, 4.50)
    telemetry.learnedBrakeG = learnedBrakeG
    telemetry.learnedCorneringG = learnedCorneringG
    local brakeCapabilitySamples = telemetry.brakeCapabilitySamples or telemetry.cleanStrongBrakeSamples or 0
    local cornerCapabilitySamples = telemetry.cornerCapabilitySamples or telemetry.strongCornerSamples or 0
    local brakeSampleConfidence = telemetrySampleConfidenceBoost(brakeCapabilitySamples)
    local cornerSampleConfidence = telemetrySampleConfidenceBoost(cornerCapabilitySamples)
    local liveTelemetryConfidence = 0.90
    brakeTelemetrySampleConfidence = brakeSampleConfidence
    cornerTelemetrySampleConfidence = cornerSampleConfidence
    if brakeCapabilitySamples >= minSamples and learnedBrakeG * usageMult > brakeG then
      brakeG = clamp(learnedBrakeG * usageMult, 0.25, maxBrakeG)
      telemetryUsed = true
      brakeTelemetryUsed = true
      brakeTelemetryLiveProven = brakeCapabilitySamples >= minSamples
      brakeGSource = 'live_telemetry'
      brakeGConfidence = math.max(brakeGConfidence, 0.90 + brakeSampleConfidence)
      liveTelemetryConfidence = math.max(liveTelemetryConfidence, 0.90 + brakeSampleConfidence)
    elseif brakeCapabilitySamples >= downwardMinSamples and learnedBrakeG > 0.0 and
      learnedBrakeG * weakBrakeCapMult < brakeG then
      brakeG = clamp(learnedBrakeG * weakBrakeCapMult, 0.25, maxBrakeG)
      telemetryUsed = true
      brakeTelemetryUsed = true
      brakeTelemetryLiveProven = brakeCapabilitySamples >= minSamples
      brakeGSource = 'live_telemetry'
      brakeGConfidence = math.max(brakeGConfidence, 0.90 + brakeSampleConfidence)
      liveTelemetryConfidence = math.max(liveTelemetryConfidence, 0.90 + brakeSampleConfidence)
    end
    if cornerCapabilitySamples >= minSamples and learnedCorneringG * usageMult > corneringG then
      corneringG = clamp(learnedCorneringG * usageMult, 0.35, 4.50)
      corneringGNoSpeedAero = clamp(learnedCorneringGNoSpeedAero * usageMult, 0.35, 4.50)
      telemetryUsed = true
      cornerTelemetryUsed = true
      cornerTelemetryLiveProven = cornerCapabilitySamples >= minSamples
      corneringGSource = 'live_telemetry'
      corneringGConfidence = math.max(corneringGConfidence, 0.90 + cornerSampleConfidence)
      liveTelemetryConfidence = math.max(liveTelemetryConfidence, 0.90 + cornerSampleConfidence)
    elseif (telemetry.strongCornerSamples or 0) >= downwardMinSamples and learnedCorneringG > 0.0 and
      learnedCorneringG * weakCornerCapMult < corneringG then
      corneringG = clamp(learnedCorneringG * weakCornerCapMult, 0.35, 4.50)
      corneringGNoSpeedAero = clamp(learnedCorneringGNoSpeedAero * weakCornerCapMult, 0.35, 4.50)
      telemetryUsed = true
      cornerTelemetryUsed = true
      cornerTelemetryLiveProven = cornerCapabilitySamples >= minSamples
      corneringGSource = 'live_telemetry'
      corneringGConfidence = math.max(corneringGConfidence, 0.90 + cornerSampleConfidence)
      liveTelemetryConfidence = math.max(liveTelemetryConfidence, 0.90 + cornerSampleConfidence)
    end
    if telemetryUsed then
      capabilitySource = capabilitySource .. '+observed_telemetry'
      capabilityTier = 'live_telemetry'
      capabilityConfidence = math.max(capabilityConfidence, liveTelemetryConfidence)
    end
  end
  local setupAdaptationState, setupAdaptationConfidence, setupAdaptationProof,
    setupBrakeAdaptationState, setupBrakeAdaptationConfidence, setupBrakeAdaptationProof,
    setupCornerAdaptationState, setupCornerAdaptationConfidence, setupCornerAdaptationProof,
    liveProvenMinSamples, setupChangedWarmupActive =
    setupAdaptation(car, telemetry, capabilityTier, capabilityConfidence, setupMechanical.setupMechanicalRisk, brakeTelemetryLiveProven, cornerTelemetryLiveProven)
  capabilityConfidence = math.min(capabilityConfidence, setupAdaptationConfidence)
  local liveGripEnvelopeState, liveGripEnvelopePenalty, liveGripEnvelopeConfidence =
    liveGripEnvelope(telemetry, brakeG, corneringG, capabilityConfidence)
  capabilityConfidence = liveGripEnvelopeConfidence
  corneringGConfidence = math.min(corneringGConfidence, capabilityConfidence, setupCornerAdaptationConfidence)
  brakeGConfidence = math.min(brakeGConfidence, capabilityConfidence, setupBrakeAdaptationConfidence)
  local momentTransferClassScale = scaleBetween(corneringG,
    finiteNumber(settings.INFER_ROAD_CAR_CORNERING_G, 1.05),
    finiteNumber(settings.INFER_OPEN_WHEELER_CORNERING_G, 2.70))
  local brakeTransferScale = scaleBetween(brakeG,
    finiteNumber(settings.INFER_ROAD_CAR_BRAKE_G, 1.05),
    finiteNumber(settings.INFER_OPEN_WHEELER_BRAKE_G, 2.20))
  local aeroTransferScale = scaleBetween(aeroStrength,
    finiteNumber(settings.INFER_SPORT_ROAD_SPEED_AERO_STRENGTH, 0.015),
    finiteNumber(settings.INFER_OPEN_WHEELER_SPEED_AERO_STRENGTH, 0.18))
  local cueTransferClassScale = cueTransferScale(momentTransferClassScale, brakeTransferScale, aeroTransferScale)
  local transferClassScale = momentTransferClassScale
  local dynamicCapabilityClass = numericCapabilityClassFor(corneringG, brakeG)
  if brakeTelemetryUsed then
    brakeSpeedAeroStrength = 0.0
    brakeSpeedAeroFactorValue = 1.0
  end
  local setupPressureSourceTokens = pressureSourceTokensToken(car.setupFingerprint)
  local setupPressureSourceFields = pressureSourceFieldMap(setupPressureSourceTokens)
  local knowledgeBaseSetup = knowledge_base.setupSummary(car, { trackId = car.trackId, trackLayout = car.trackLayout }) or {}
  local knowledgeBaseTrack = knowledge_base.trackSummary(car.trackId, car.trackLayout) or {}
  local knowledgeBaseStatus = knowledge_base.status()
  local knowledgeBaseSetupRisk = clamp(knowledgeBaseSetup.rearInstabilityRisk, 0.0, 1.0)
  local knowledgeBaseTrackRisk = clamp(knowledgeBaseTrack.trackRisk, 0.0, 1.0)

  local context = {
    carId = tostring(car.carId or car.id or car.name or 'unknown_car'),
    trackId = tostring(car.trackId or 'unknown_track'),
    trackLayout = tostring(car.trackLayout or 'default'),
    baseCorneringG = baseCorneringG,
    baseBrakeG = baseBrakeG,
    capabilityClass = dynamicCapabilityClass,
    nominalCapabilityClass = nominalCapabilityClass,
    dynamicCapabilityClass = dynamicCapabilityClass,
    capabilityTier = capabilityTier,
    axisTrustOrder = TRUST_ORDER_PROOF,
    capabilityTierRank = capabilitySourceTrustRank(capabilityTier),
    capabilityConfidence = capabilityConfidence,
    corneringGSource = corneringGSource,
    corneringGSourceRank = capabilitySourceTrustRank(corneringGSource),
    corneringGConfidence = corneringGConfidence,
    brakeGSource = brakeGSource,
    brakeGSourceRank = capabilitySourceTrustRank(brakeGSource),
    brakeGConfidence = brakeGConfidence,
    realLifePriorSource = tostring(selectedCapability.realLifePriorSource or 'none'),
    realLifePriorConfidence = clamp(selectedCapability.realLifePriorConfidence, 0.0, 1.0),
    localKnowledgePriorSource = tostring(selectedCapability.localKnowledgePriorSource or 'none'),
    localKnowledgePriorConfidence = clamp(selectedCapability.localKnowledgePriorConfidence, 0.0, 1.0),
    localKnowledgePriorSamples = finiteNumber(selectedCapability.localKnowledgePriorSamples, 0.0),
    knowledgeBaseEnabled = settings.KNOWLEDGE_BASE_ENABLED == true,
    knowledgeBaseStatus = tostring(knowledgeBaseStatus.status or 'unknown'),
    knowledgeBaseLastError = tostring(knowledgeBaseStatus.lastError or 'none'),
    knowledgeBaseCarCount = knowledgeBaseStatus.carCount or 0,
    knowledgeBaseSetupCount = knowledgeBaseStatus.setupCount or 0,
    knowledgeBaseTrackCount = knowledgeBaseStatus.trackCount or 0,
    knowledgeBaseCornerCount = knowledgeBaseStatus.cornerCount or 0,
    knowledgeBaseSetupRisk = knowledgeBaseSetupRisk,
    knowledgeBaseSetupConfidence = clamp(knowledgeBaseSetup.confidence, 0.0, 1.0),
    knowledgeBaseSetupSamples = finiteNumber(knowledgeBaseSetup.samples, 0.0),
    knowledgeBaseTrackRisk = knowledgeBaseTrackRisk,
    knowledgeBaseTrackConfidence = clamp(knowledgeBaseTrack.confidence, 0.0, 1.0),
    knowledgeBaseTrackSamples = finiteNumber(knowledgeBaseTrack.samples, 0.0),
    physicsCapabilitySource = tostring(physicsCapability.source or 'none'),
    physicsDataStatus = tostring(physicsCapability.dataStatus or 'none'),
    tyreDataStatus = tostring(physicsCapability.tyreDataStatus or 'none'),
    physicsAeroDataStatus = tostring(physicsCapability.aeroDataStatus or 'none'),
    physicsCapabilityConfidence = clamp(physicsCapability.confidence, 0.0, 1.0),
    physicsCorneringCapabilityAvailable = physicsCorneringCapabilityAvailable,
    physicsBrakeCapabilityAvailable = physicsBrakeCapabilityAvailable,
    physicsAeroCapabilityAvailable = physicsAeroCapabilityAvailable,
    nominalTransferClassScale = nominalTransferClassScale,
    transferClassScale = transferClassScale,
    momentTransferClassScale = momentTransferClassScale,
    brakeTransferScale = brakeTransferScale,
    aeroTransferScale = aeroTransferScale,
    cueTransferClassScale = cueTransferClassScale,
    carMassKg = carMassKg,
    carMassSource = carMassSource,
    physicsMassKg = physicsMassKg,
    physicsWheelbaseM = finiteNumber(physicsCapability.wheelbaseM, 0.0),
    physicsCgLocation = finiteNumber(physicsCapability.cgLocation, 0.0),
    physicsFrontTrackM = finiteNumber(physicsCapability.frontTrackM, 0.0),
    physicsRearTrackM = finiteNumber(physicsCapability.rearTrackM, 0.0),
    physicsTyreLateralMu = finiteNumber(physicsCapability.tyreLateralMu, 0.0),
    physicsTyreLongitudinalMu = finiteNumber(physicsCapability.tyreLongitudinalMu, 0.0),
    physicsTyreFrontLateralMu = finiteNumber(physicsCapability.tyreFrontLateralMu, 0.0),
    physicsTyreRearLateralMu = finiteNumber(physicsCapability.tyreRearLateralMu, 0.0),
    physicsTyreFrontLongitudinalMu = finiteNumber(physicsCapability.tyreFrontLongitudinalMu, 0.0),
    physicsTyreRearLongitudinalMu = finiteNumber(physicsCapability.tyreRearLongitudinalMu, 0.0),
    physicsTyreLoadRefN = finiteNumber(physicsCapability.tyreLoadRefN, 0.0),
    physicsTyreFrontLoadRefN = finiteNumber(physicsCapability.tyreFrontLoadRefN, 0.0),
    physicsTyreRearLoadRefN = finiteNumber(physicsCapability.tyreRearLoadRefN, 0.0),
    physicsTyreLoadSensitivityLat = finiteNumber(physicsCapability.tyreLoadSensitivityLat, 0.0),
    physicsTyreLoadSensitivityLong = finiteNumber(physicsCapability.tyreLoadSensitivityLong, 0.0),
    physicsTyreFrontLoadSensitivityLat = finiteNumber(physicsCapability.tyreFrontLoadSensitivityLat, 0.0),
    physicsTyreRearLoadSensitivityLat = finiteNumber(physicsCapability.tyreRearLoadSensitivityLat, 0.0),
    physicsTyreFrontLoadSensitivityLong = finiteNumber(physicsCapability.tyreFrontLoadSensitivityLong, 0.0),
    physicsTyreRearLoadSensitivityLong = finiteNumber(physicsCapability.tyreRearLoadSensitivityLong, 0.0),
    physicsTyrePressureStaticPsi = finiteNumber(physicsCapability.tyrePressureStaticPsi, 0.0),
    physicsTyrePressureIdealPsi = finiteNumber(physicsCapability.tyrePressureIdealPsi, 0.0),
    physicsTyreFrontPressureStaticPsi = finiteNumber(physicsCapability.tyreFrontPressureStaticPsi, 0.0),
    physicsTyreRearPressureStaticPsi = finiteNumber(physicsCapability.tyreRearPressureStaticPsi, 0.0),
    physicsTyreFrontPressureIdealPsi = finiteNumber(physicsCapability.tyreFrontPressureIdealPsi, 0.0),
    physicsTyreRearPressureIdealPsi = finiteNumber(physicsCapability.tyreRearPressureIdealPsi, 0.0),
    physicsTyreFalloffLevel = finiteNumber(physicsCapability.tyreFalloffLevel, 0.0),
    physicsTyreFrontFalloffLevel = finiteNumber(physicsCapability.tyreFrontFalloffLevel, 0.0),
    physicsTyreRearFalloffLevel = finiteNumber(physicsCapability.tyreRearFalloffLevel, 0.0),
    physicsTyreFalloffSpeed = finiteNumber(physicsCapability.tyreFalloffSpeed, 0.0),
    physicsTyreFrontFalloffSpeed = finiteNumber(physicsCapability.tyreFrontFalloffSpeed, 0.0),
    physicsTyreRearFalloffSpeed = finiteNumber(physicsCapability.tyreRearFalloffSpeed, 0.0),
    physicsTyreCombinedFactor = finiteNumber(physicsCapability.tyreCombinedFactor, 0.0),
    physicsTyreFrontCombinedFactor = finiteNumber(physicsCapability.tyreFrontCombinedFactor, 0.0),
    physicsTyreRearCombinedFactor = finiteNumber(physicsCapability.tyreRearCombinedFactor, 0.0),
    physicsTyreFrictionLimitAngleDeg = finiteNumber(physicsCapability.tyreFrictionLimitAngleDeg, 0.0),
    physicsTyreFrontFrictionLimitAngleDeg = finiteNumber(physicsCapability.tyreFrontFrictionLimitAngleDeg, 0.0),
    physicsTyreRearFrictionLimitAngleDeg = finiteNumber(physicsCapability.tyreRearFrictionLimitAngleDeg, 0.0),
    physicsTyreBrakeDxMod = finiteNumber(physicsCapability.tyreBrakeDxMod, 0.0),
    physicsTyreFrontBrakeDxMod = finiteNumber(physicsCapability.tyreFrontBrakeDxMod, 0.0),
    physicsTyreRearBrakeDxMod = finiteNumber(physicsCapability.tyreRearBrakeDxMod, 0.0),
    physicsTyreRadiusM = finiteNumber(physicsCapability.tyreRadiusM, 0.0),
    physicsTyreLateralCount = math.max(0, math.floor(finiteNumber(physicsCapability.tyreLateralCount, 0.0) + 0.5)),
    physicsTyreLongitudinalCount = math.max(0, math.floor(finiteNumber(physicsCapability.tyreLongitudinalCount, 0.0) + 0.5)),
    physicsBrakeTorqueNm = finiteNumber(physicsCapability.brakeTorqueNm, 0.0),
    physicsBrakeFrontShare = finiteNumber(physicsCapability.brakeFrontShare, 0.0),
    physicsBrakeDataStatus = tostring(physicsCapability.brakeDataStatus or 'unknown'),
    physicsAeroWingCount = math.max(0, math.floor(finiteNumber(physicsCapability.aeroWingCount, 0.0) + 0.5)),
    physicsAeroScore = finiteNumber(physicsCapability.aeroScore, 0.0),
    currentSpeedKph = finiteNumber(car.speedKmh, 0.0),
    currentSpeedMs = finiteNumber(car.speedMs, 0.0),
    minCornerSpeedKph = finiteNumber(carProfile.min_corner_speed_kph, settings.MIN_CORNER_SPEED_KPH),
    maxTargetSpeedKph = finiteNumber(carProfile.max_target_speed_kph, settings.MAX_TARGET_SPEED_KPH),
    corneringG = corneringG,
    corneringGNoSpeedAero = corneringGNoSpeedAero,
    brakeG = brakeG,
    capabilitySource = capabilitySource,
    observedBrakeG = finiteNumber(telemetry.observedBrakeG, 0.0),
    observedCorneringG = finiteNumber(telemetry.observedCorneringG, 0.0),
    learnedBrakeG = learnedBrakeG,
    learnedCorneringG = learnedCorneringG,
    learnedCorneringGNoSpeedAero = learnedCorneringGNoSpeedAero,
    telemetryBrakeSamples = telemetry.telemetryBrakeSamples or 0,
    telemetryCornerSamples = telemetry.telemetryCornerSamples or 0,
    telemetryBrakeSampleConfidence = brakeTelemetrySampleConfidence,
    telemetryCornerSampleConfidence = cornerTelemetrySampleConfidence,
    strongBrakeSamples = telemetry.strongBrakeSamples or 0,
    strongCornerSamples = telemetry.strongCornerSamples or 0,
    cornerCapabilitySamples = telemetry.cornerCapabilitySamples or telemetry.strongCornerSamples or 0,
    brakeLimitSampleThisFrame = telemetry.brakeLimitSampleThisFrame == true,
    cornerLimitSampleThisFrame = telemetry.cornerLimitSampleThisFrame == true,
    brakeLimitState = telemetry.brakeLimitState,
    brakeSlipRatio = telemetry.brakeSlipRatio,
    frontBrakeSlipRatio = telemetry.frontBrakeSlipRatio,
    rearBrakeSlipRatio = telemetry.rearBrakeSlipRatio,
    brakeLockupAxle = telemetry.brakeLockupAxle,
    brakeCapabilitySamples = telemetry.brakeCapabilitySamples or 0,
    brakeLearningRejectReason = tostring(telemetry.brakeLearningRejectReason or 'unknown'),
    cleanStrongBrakeSamples = telemetry.cleanStrongBrakeSamples or 0,
    absInterventionBrakeSamples = telemetry.absInterventionBrakeSamples or 0,
    lockupRiskBrakeSamples = telemetry.lockupRiskBrakeSamples or 0,
    telemetrySampleAccepted = telemetry.telemetrySampleAccepted == true,
    telemetryRejectReason = tostring(telemetry.telemetryRejectReason or 'unknown'),
    telemetryTrafficBlocked = telemetry.telemetryTrafficBlocked == true,
    aeroHighSpeedCornerSamples = telemetry.aeroHighSpeedCornerSamples or 0,
    aeroHighSpeedLimitSamples = telemetry.aeroHighSpeedLimitSamples or 0,
    aeroObservedCorneringG = telemetry.observedAeroCorneringG or 0.0,
    observedSpeedAeroStrength = telemetry.observedSpeedAeroStrength or 0.0,
    learnedSpeedAeroStrength = telemetry.learnedSpeedAeroStrength or 0.0,
    telemetryLearningKey = tostring(telemetry.carKey or telemetryIdentity(car).telemetryLearningKey),
    telemetryResetReason = setupResetReason(telemetry),
    setupLiveProvenMinSamples = liveProvenMinSamples,
    setupChangedWarmupActive = setupChangedWarmupActive,
    setupAdaptationState = setupAdaptationState,
    setupAdaptationConfidence = setupAdaptationConfidence,
    setupAdaptationProof = setupAdaptationProof,
    setupBrakeAdaptationState = setupBrakeAdaptationState,
    setupBrakeAdaptationConfidence = setupBrakeAdaptationConfidence,
    setupBrakeAdaptationProof = setupBrakeAdaptationProof,
    setupCornerAdaptationState = setupCornerAdaptationState,
    setupCornerAdaptationConfidence = setupCornerAdaptationConfidence,
    setupCornerAdaptationProof = setupCornerAdaptationProof,
    liveGripEnvelopeState = liveGripEnvelopeState,
    liveGripEnvelopePenalty = liveGripEnvelopePenalty,
    liveGripEnvelopeConfidence = liveGripEnvelopeConfidence,
    setupMechanicalSource = setupMechanical.setupMechanicalSource,
    setupMechanicalCount = setupMechanical.setupMechanicalCount,
    setupDrivetrainSource = setupMechanical.setupDrivetrainSource,
    setupDrivetrainCount = setupMechanical.setupDrivetrainCount,
    setupDrivetrainToken = setupMechanical.setupDrivetrainToken,
    setupDrivetrainRisk = setupMechanical.setupDrivetrainRisk,
    setupDamperSource = setupMechanical.setupDamperSource,
    setupDamperCount = setupMechanical.setupDamperCount,
    setupDamperToken = setupMechanical.setupDamperToken,
    setupDamperRisk = setupMechanical.setupDamperRisk,
    setupGearSource = setupMechanical.setupGearSource,
    setupGearCount = setupMechanical.setupGearCount,
    setupGearToken = setupMechanical.setupGearToken,
    setupGearRisk = setupMechanical.setupGearRisk,
    setupDiffSource = setupMechanical.setupDiffSource,
    setupDiffCount = setupMechanical.setupDiffCount,
    setupDiffToken = setupMechanical.setupDiffToken,
    setupDiffRisk = setupMechanical.setupDiffRisk,
    setupAssistSource = setupMechanical.setupAssistSource,
    setupAssistCount = setupMechanical.setupAssistCount,
    setupAssistToken = setupMechanical.setupAssistToken,
    setupAssistRisk = setupMechanical.setupAssistRisk,
    setupArbBalance = setupMechanical.setupArbBalance,
    setupCamberSpread = setupMechanical.setupCamberSpread,
    setupToeSpread = setupMechanical.setupToeSpread,
    setupAeroBalance = setupMechanical.setupAeroBalance,
    setupAeroSpread = setupMechanical.setupAeroSpread,
    setupAeroRisk = setupMechanical.setupAeroRisk,
    setupMechanicalRisk = setupMechanical.setupMechanicalRisk,
    setupMechanicalConfidencePenalty = setupMechanical.setupMechanicalConfidencePenalty,
    globalCorneringMechanicalDelta = setupMechanical.globalCorneringMechanicalDelta,
    globalBrakeMechanicalDelta = setupMechanical.globalBrakeMechanicalDelta,
    roadGrip = roadGrip,
    surfaceGrip = surfaceGrip,
    rainIntensity = rainIntensity,
    rainWetness = rainWetness,
    rainWater = rainWater,
    ambientTemperatureC = ambientTemperatureC,
    roadTemperatureC = roadTemperatureC,
    windSpeedKmh = windSpeedKmh,
    trackThermalCornerFactor = trackThermalCornerFactor,
    trackThermalBrakeFactor = trackThermalBrakeFactor,
    windFactor = windFactor,
    wetFactor = clamp(1.0 - wetCornerPenalty, 0.55, 1.0),
    tyreFactor = cornerTyreFactor,
    tyreWear = tyreDetails.tyreWear,
    tyreDirty = tyreDetails.tyreDirty,
    tyreCoreTemperature = tyreDetails.tyreCoreTemperature,
    tyreOptimumTemperature = tyreDetails.tyreOptimumTemperature,
    tyreTempDeltaC = tyreDetails.tyreTempDeltaC,
    tyreTempConfidence = tyreDetails.tyreTempConfidence,
    pressurePenalty = tyreDetails.pressurePenalty,
    pressureSource = tyreDetails.pressureSource,
    pressureSourceTokens = tyreDetails.pressureSourceTokens,
    pressureSourceTyres = tyreDetails.pressureSourceTyres,
    pressureSourceTokenLF = tyreDetails.pressureSourceTokenLF,
    pressureSourceTokenRF = tyreDetails.pressureSourceTokenRF,
    pressureSourceTokenLR = tyreDetails.pressureSourceTokenLR,
    pressureSourceTokenRR = tyreDetails.pressureSourceTokenRR,
    setupPressureSourceTokens = setupPressureSourceTokens,
    setupPressureSourceTyres = pressureSourceTyresToken(car.setupFingerprint),
    setupPressureSourceTokenLF = setupPressureSourceFields.lf,
    setupPressureSourceTokenRF = setupPressureSourceFields.rf,
    setupPressureSourceTokenLR = setupPressureSourceFields.lr,
    setupPressureSourceTokenRR = setupPressureSourceFields.rr,
    setupPressureDeltaPsi = tyreDetails.setupPressureDeltaPsi,
    slipStress = tyreDetails.slipStress,
    frontTyreStress = tyreDetails.frontTyreStress,
    rearTyreStress = tyreDetails.rearTyreStress,
    worstAxleTyreStress = tyreDetails.worstAxleTyreStress,
    axleBalancePenalty = tyreDetails.axleBalancePenalty,
    absMode = finiteNumber(car.absMode, 0.0),
    tractionControlMode = finiteNumber(car.tractionControlMode, 0.0),
    absInAction = car.absInAction == true,
    tractionControlInAction = car.tractionControlInAction == true,
    physicsTyreLoadSensitivityFactor = tyreDetails.physicsTyreLoadSensitivityFactor,
    physicsTyreBrakeLoadSensitivityFactor = brakeTyreDetails.physicsTyreLoadSensitivityFactor,
    physicsTyreLoadSensitivityPenalty = tyreDetails.physicsTyreLoadSensitivityPenalty,
    physicsTyreLoadSensitivityLoadRatio = tyreDetails.physicsTyreLoadSensitivityLoadRatio,
    physicsTyreLoadSensitivityFrontShare = tyreDetails.physicsTyreLoadSensitivityFrontShare,
    physicsTyreLoadSensitivityRearShare = tyreDetails.physicsTyreLoadSensitivityRearShare,
    physicsTyreBrakeLoadSensitivityFrontShare = brakeTyreDetails.physicsTyreLoadSensitivityFrontShare,
    physicsTyreBrakeLoadSensitivityRearShare = brakeTyreDetails.physicsTyreLoadSensitivityRearShare,
    fuelFraction = fuelFraction,
    fuelLoadL = fuelLoadL,
    fuelCapacityL = fuelCapacityL,
    fuelLoadSource = fuelLoadSource,
    fuelMassKg = fuelMassKg,
    fuelMassRatio = fuelMassRatio,
    brakeBias = brakeBias,
    brakeBiasBrakeFactor = brakeBiasBrakeFactorValue,
    brakePowerMult = brakePowerMult,
    brakePowerSource = brakePowerSource,
    brakeBiasSource = brakeBiasSource,
    ballastKg = ballastKg,
    restrictor = restrictor,
    ballastLoadFactor = ballastLoadFactorValue,
    damageLevel = damageLevel,
    damageCornerFactor = damageCornerFactor,
    damageBrakeFactor = damageBrakeFactor,
    damageAeroFactor = damageAeroFactor,
    setupFactor = setup,
    setupState = tostring(car.setupState or 'unknown'),
    setupSnapshot = car.setupSnapshot or {},
    setupFingerprint = tostring(car.setupFingerprint or ''),
    wingSetting = wingSetting,
    wingSource = wingSource,
    setupAeroFactor = setupAero,
    speedAeroFactor = speedAero,
    speedAeroNominalStrength = nominalAeroStrength,
    speedAeroStrength = aeroStrength,
    brakeSpeedAeroStrength = brakeSpeedAeroStrength,
    brakeSpeedAeroFactor = brakeSpeedAeroFactorValue,
    speedAeroSource = aeroSource,
    speedAeroSourceRank = capabilitySourceTrustRank(aeroSource),
    aeroConfidence = aeroConfidence,
    aeroConfidenceSource = aeroConfidenceSource,
    aeroFactor = aero,
    assistPenalty = assistPenalty,
    brakeAssistPenalty = brakeAssistPenalty,
    confidence = capabilityConfidence,
  }
  context.summary = summaryFor(context)
  return context
end

return M
