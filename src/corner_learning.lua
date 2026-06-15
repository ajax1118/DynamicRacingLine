local math3d = require('src/math3d')
local settings = require('src/settings')
local knowledge_base = require('src/knowledge_base')
local M = {}

local stateByKey = {}
local learningSummary = {}

local function resetLearningSummary()
  learningSummary = {
    cleanAccepted = 0,
    noBrake = 0,
    weakDecel = 0,
    overspeed = 0,
    resultOverspeed = 0,
    abs = 0,
    frontLockup = 0,
    rearLockup = 0,
    allLockup = 0,
    unknownLockup = 0,
    rejected = 0,
  }
end

resetLearningSummary()

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function clamp(value, lo, hi)
  return math3d.clamp(finiteNumber(value, lo), lo, hi)
end

local function token(value)
  local text = tostring(value or 'unknown'):lower()
  text = text:gsub('[^a-z0-9_%-]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if text == '' then return 'unknown' end
  return text
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

function M.cornerKey(car, cue)
  cue = cue or {}
  car = car or {}
  local progress = finiteNumber(cue.progress, finiteNumber(car.splinePosition, 0.0)) % 1.0
  local trackLengthM = finiteNumber(car.sim and car.sim.trackLengthM, 0.0)
  local targetDistanceM = finiteNumber(cue.targetSampleDistanceM, 0.0)
  if trackLengthM > 1.0 and targetDistanceM > 0.0 then
    progress = (progress + targetDistanceM / trackLengthM) % 1.0
  end
  local bucket = math.floor(progress / 0.005)
  local setupFingerprint = token(cue.setupFingerprint or car.setupFingerprint or 'setup_unknown')
  local trackLayout = token(cue.trackLayout or car.trackLayout or 'layout_default')
  local momentKey = token(cue.cornerLearningMomentKey or cue.momentKey or cue.momentGripKey or
    car.cornerLearningMomentKey or 'moment_unknown')
  return token(car.carId or car.id or car.name) .. '|' .. token(cue.trackId or car.trackId) .. '|' .. trackLayout .. '|' ..
    setupFingerprint .. '|' .. momentKey .. '|' .. string.format('%03d', bucket)
end

local function brakeBiasClamp(value)
  return clamp(finiteNumber(value, 0.0),
    finiteNumber(settings.CORNER_LEARNING_MIN_BRAKE_BIAS_M, -20.0),
    finiteNumber(settings.CORNER_LEARNING_MAX_BRAKE_BIAS_M, 24.0))
end

local function learningConfidenceValue(value)
  local confidence = tonumber(value)
  if not confidence or confidence ~= confidence then
    confidence = finiteNumber(settings.CORNER_LEARNING_CONFIDENCE_START, 1.0)
  end
  return clamp(confidence, finiteNumber(settings.CORNER_LEARNING_CONFIDENCE_MIN, 0.35), 1.0)
end

local function setupTrustScale(car, cue)
  car = car or {}
  cue = cue or {}
  local setupFingerprint = tostring(cue.setupFingerprint or car.setupFingerprint or '')
  local setupKnown = hasMeaningfulSetupFingerprint(car, setupFingerprint)
  if setupKnown then return 1.0, true end
  return clamp(settings.CORNER_LEARNING_UNKNOWN_SETUP_BIAS_SCALE, 0.0, 1.0), false
end

local function isCleanLearningBucket(bucket)
  return tostring(bucket or 'cleanAccepted') == 'cleanAccepted'
end

local function updateLearningWindow(previous, bucket)
  previous = previous or {}
  bucket = tostring(bucket or 'cleanAccepted')
  local decay = clamp(settings.CORNER_LEARNING_WINDOW_DECAY, 0.0, 1.0)
  local cleanWindowSamples = math.max(0.0,
    finiteNumber(previous.cornerLearningCleanWindowSamples or previous.cleanWindowSamples, 0.0)) * decay
  local riskWindowSamples = math.max(0.0,
    finiteNumber(previous.cornerLearningRiskWindowSamples or previous.riskWindowSamples, 0.0)) * decay
  if isCleanLearningBucket(bucket) then
    cleanWindowSamples = cleanWindowSamples + 1.0
  else
    riskWindowSamples = riskWindowSamples + 1.0
  end
  return cleanWindowSamples, riskWindowSamples
end

local function learningConfidenceAfterBucket(previousConfidence, bucket, cleanWindowSamples, riskWindowSamples)
  local confidence = learningConfidenceValue(previousConfidence)
  bucket = tostring(bucket or 'cleanAccepted')
  if isCleanLearningBucket(bucket) then
    local recovery = clamp(settings.CORNER_LEARNING_CONFIDENCE_RECOVERY, 0.0, 1.0)
    confidence = confidence + (1.0 - confidence) * recovery
  elseif bucket == 'rejected' then
    confidence = confidence - finiteNumber(settings.CORNER_LEARNING_CONFIDENCE_REJECTED_DECAY, 0.18)
  elseif bucket == 'noBrake' then
    confidence = confidence - finiteNumber(settings.CORNER_LEARNING_CONFIDENCE_NO_BRAKE_DECAY, 0.12)
  else
    confidence = confidence - finiteNumber(settings.CORNER_LEARNING_CONFIDENCE_LIMIT_DECAY, 0.08)
  end

  cleanWindowSamples = math.max(0.0, finiteNumber(cleanWindowSamples, 0.0))
  riskWindowSamples = math.max(0.0, finiteNumber(riskWindowSamples, 0.0))
  local windowSamples = cleanWindowSamples + riskWindowSamples
  if windowSamples >= 2.0 then
    local riskRate = riskWindowSamples / windowSamples
    local maxPenalty = clamp(settings.CORNER_LEARNING_RISK_WINDOW_MAX_PENALTY, 0.0, 0.85)
    confidence = math.min(confidence, 1.0 - riskRate * maxPenalty)
  end
  return learningConfidenceValue(confidence), cleanWindowSamples, riskWindowSamples
end

local function appliedBrakeBias(rawBrakeBiasM, learningConfidence, setupTrustScaleValue)
  return brakeBiasClamp(finiteNumber(rawBrakeBiasM, 0.0) *
    learningConfidenceValue(learningConfidence) * clamp(finiteNumber(setupTrustScaleValue, 1.0), 0.0, 1.0))
end

local function positiveSpeed(value)
  value = finiteNumber(value, 0.0)
  if value > 0.0 then return value end
  return nil
end

local function capturedPhaseSpeed(speedKph, captureState)
  captureState = token(captureState or 'none')
  if captureState == 'pending' or captureState == 'approach_pending' or
    captureState == 'none' or captureState == 'unknown' then return 0.0 end
  return math.max(0.0, finiteNumber(speedKph, 0.0))
end

local function slowEnoughForEarlyRelax(cue)
  cue = cue or {}
  local targetSpeedKph = finiteNumber(cue.targetSpeedKph, 0.0)
  if targetSpeedKph <= 0.0 then return true end
  local slowest = nil
  for _, speed in ipairs({
    positiveSpeed(capturedPhaseSpeed(cue.turnInSpeedKph, cue.turnInCaptureState)),
    positiveSpeed(capturedPhaseSpeed(cue.apexSpeedKph, cue.apexCaptureState)),
    positiveSpeed(capturedPhaseSpeed(cue.exitSpeedKph, cue.exitCaptureState)),
  }) do
    if speed and (not slowest or speed < slowest) then slowest = speed end
  end
  if not slowest then return false end
  return slowest <= targetSpeedKph + 6.0
end

local function effectiveBrakeInput(cue)
  cue = cue or {}
  local currentBrakeInput = clamp(cue.actualBrakeInput, 0.0, 1.0)
  local onsetBrakeInput = 0.0
  if token(cue.actualBrakeOnsetState or 'none') == 'captured' then
    onsetBrakeInput = clamp(cue.actualBrakeOnsetInput, 0.0, 1.0)
  end
  return math.max(currentBrakeInput, onsetBrakeInput)
end

local function cornerResultOverspeed(cue)
  cue = cue or {}
  local targetSpeedKph = finiteNumber(cue.targetSpeedKph, 0.0)
  if targetSpeedKph <= 0.0 then return 0.0, 'none' end
  local exitTargetSpeedKph = math.max(targetSpeedKph, finiteNumber(cue and cue.exitTargetSpeedKph, targetSpeedKph))
  local phases = {
    { phase = 'turn_in', speed = capturedPhaseSpeed(cue.turnInSpeedKph, cue.turnInCaptureState), target = targetSpeedKph },
    { phase = 'apex', speed = capturedPhaseSpeed(cue.apexSpeedKph, cue.apexCaptureState), target = targetSpeedKph },
    { phase = 'exit', speed = capturedPhaseSpeed(cue.exitSpeedKph, cue.exitCaptureState), target = exitTargetSpeedKph },
  }
  local bestPhase = 'none'
  local bestOverspeedKph = 0.0
  for _, item in ipairs(phases) do
    local overspeedKph = math.max(0.0, item.speed - item.target)
    if overspeedKph > bestOverspeedKph then
      bestOverspeedKph = overspeedKph
      bestPhase = item.phase
    end
  end
  if bestOverspeedKph <= 0.0 then return 0.0, 'none' end
  return bestOverspeedKph, bestPhase
end

local function actualSpeedOverTargetKph(cue)
  local overspeedKph = cornerResultOverspeed(cue)
  return overspeedKph
end

local function measuredBrakePointAdjustment(cue)
  local actualBrakeInput = effectiveBrakeInput(cue)
  if actualBrakeInput < 0.20 then return 0.0 end
  local speedDropKph = finiteNumber(cue.speedDropKph, 0.0)
  local actualBrakePointErrorM = finiteNumber(cue.actualBrakePointErrorM, 0.0)
  actualBrakePointErrorM = clamp(actualBrakePointErrorM, -30.0, 30.0)
  if actualBrakePointErrorM > 1.5 then
    local speedOverTargetKph = actualSpeedOverTargetKph(cue)
    local urgency = speedOverTargetKph > 6.0 and 1.15 or 1.0
    return clamp(actualBrakePointErrorM * 0.22 * urgency, 0.0, 6.0)
  end
  if actualBrakePointErrorM < -1.5 and speedDropKph >= 1.0 and
    slowEnoughForEarlyRelax(cue) then
    return -clamp(math.abs(actualBrakePointErrorM) * 0.18, 0.0, 4.0)
  end
  return 0.0
end

local function cornerResultOverspeedScale(phase)
  phase = tostring(phase or 'none')
  if phase == 'turn_in' then
    return math.max(0.0, finiteNumber(settings.CORNER_LEARNING_TURN_IN_OVERSPEED_SCALE, 1.20))
  end
  if phase == 'apex' then
    return math.max(0.0, finiteNumber(settings.CORNER_LEARNING_APEX_OVERSPEED_SCALE, 1.00))
  end
  if phase == 'exit' then
    return math.max(0.0, finiteNumber(settings.CORNER_LEARNING_EXIT_OVERSPEED_SCALE, 0.60))
  end
  return 1.0
end

local function cornerResultSpeedAdjustment(cue, responseState)
  responseState = tostring(responseState or 'unknown')
  local overspeedKph, overspeedPhase = cornerResultOverspeed(cue)
  local marginKph = math.max(0.0, finiteNumber(settings.CORNER_LEARNING_RESULT_OVERSPEED_MARGIN_KPH, 8.0))
  if overspeedKph <= marginKph then return 0.0, 'speed_result_nominal', overspeedKph, overspeedPhase end
  if responseState == 'brake_overspeed_no_slowdown' then
    return 0.0, 'speed_result_covered_by_weak_decel', overspeedKph, overspeedPhase
  end
  local actualBrakeInput = effectiveBrakeInput(cue)
  local brakeInputThreshold = math.max(0.0, finiteNumber(settings.BRAKE_RESPONSE_INPUT_THRESHOLD, 0.20))
  if actualBrakeInput < brakeInputThreshold then return 0.0, 'speed_result_no_brake', overspeedKph, overspeedPhase end
  local speedDropKph = finiteNumber(cue.speedDropKph, 0.0)
  local speedDropThresholdKph = math.max(0.0, finiteNumber(settings.BRAKE_RESPONSE_SPEED_DROP_KPH, 1.0))
  if speedDropKph < speedDropThresholdKph then return 0.0, 'speed_result_waiting_for_decel', overspeedKph, overspeedPhase end
  local maxAdjust = math.max(0.0, finiteNumber(settings.CORNER_LEARNING_RESULT_OVERSPEED_MAX_ADJUST_M, 3.5))
  return cornerResultOverspeedScale(overspeedPhase) * clamp(0.8 + (overspeedKph - marginKph) * 0.045, 0.8, maxAdjust),
    'speed_result_overspeed_after_decel',
    overspeedKph,
    overspeedPhase
end

local function weakDecelAdjustment(cue, responseState)
  responseState = tostring(responseState or 'unknown')
  if responseState == 'brake_overspeed_no_slowdown' then
    local overspeedKph = actualSpeedOverTargetKph(cue)
    return clamp(1.8 + overspeedKph * 0.035, 1.8, 4.0)
  end
  if responseState == 'brake_input_weak_decel' then
    return 1.1
  end
  return 0.0
end

local function brakeLimitLearning(cue, adjustment)
  local brakeLimitState = tostring(cue.brakeLimitState or 'clean_threshold')
  local brakeLockupAxle = tostring(cue.brakeLockupAxle or 'none')
  if brakeLimitState ~= 'abs_intervention' and brakeLimitState ~= 'lockup_risk' then
    return adjustment, 'clean_threshold'
  end
  if adjustment < 0.0 then
    return 0.0, 'limit_' .. brakeLimitState .. '_' .. brakeLockupAxle .. '_no_relax'
  end
  local axleScale = brakeLockupAxle == 'rear' and 0.58 or
    (brakeLockupAxle == 'all' and 0.50 or (brakeLockupAxle == 'front' and 0.72 or 0.65))
  return adjustment * axleScale, 'limit_' .. brakeLimitState .. '_' .. brakeLockupAxle .. '_reduced_trust'
end

local function learningCauseBucket(cue, sampleAccepted, rejectionReason, cornerResultLearningReason)
  if sampleAccepted == false then return 'rejected' end
  local brakeLimitState = tostring(cue.brakeLimitState or 'clean_threshold')
  local brakeLockupAxle = tostring(cue.brakeLockupAxle or 'none')
  if brakeLimitState == 'abs_intervention' then return 'abs' end
  if brakeLimitState == 'lockup_risk' then
    if brakeLockupAxle == 'front' then return 'frontLockup' end
    if brakeLockupAxle == 'rear' then return 'rearLockup' end
    if brakeLockupAxle == 'all' then return 'allLockup' end
    return 'unknownLockup'
  end
  local responseState = tostring(cue.responseState or 'unknown')
  if responseState == 'late_no_brake' then return 'noBrake' end
  if responseState == 'brake_input_weak_decel' then return 'weakDecel' end
  if responseState == 'brake_overspeed_no_slowdown' then return 'overspeed' end
  cornerResultLearningReason = tostring(cornerResultLearningReason or 'none')
  if cornerResultLearningReason == 'speed_result_overspeed_after_decel' then return 'resultOverspeed' end
  return 'cleanAccepted'
end

local function incrementLearningSummary(bucket)
  bucket = tostring(bucket or 'cleanAccepted')
  if learningSummary[bucket] == nil then bucket = 'cleanAccepted' end
  learningSummary[bucket] = (learningSummary[bucket] or 0) + 1
end

local function cornerRiskSummary()
  local lowConfidenceThreshold = clamp(settings.CORNER_LEARNING_LOW_CONFIDENCE_THRESHOLD, 0.0, 1.0)
  local observedCornerCount = 0
  local lowConfidenceCornerCount = 0
  local riskDominantCornerCount = 0
  local minConfidence = 1.0
  local maxBiasDampingM = 0.0
  local worstKey = 'none'
  local worstCauseBucket = 'none'

  for key, state in pairs(stateByKey) do
    local confidence = learningConfidenceValue(state and state.cornerLearningConfidence)
    local cleanWindowSamples = math.max(0.0,
      finiteNumber(state and (state.cornerLearningCleanWindowSamples or state.cleanWindowSamples), 0.0))
    local riskWindowSamples = math.max(0.0,
      finiteNumber(state and (state.cornerLearningRiskWindowSamples or state.riskWindowSamples), 0.0))
    local windowSamples = cleanWindowSamples + riskWindowSamples
    local samples = math.max(0, math.floor(finiteNumber(state and state.samples, 0.0) + 0.5))

    if samples > 0 or windowSamples > 0.0 then
      observedCornerCount = observedCornerCount + 1
      if confidence < lowConfidenceThreshold then
        lowConfidenceCornerCount = lowConfidenceCornerCount + 1
      end
      if riskWindowSamples > cleanWindowSamples then
        riskDominantCornerCount = riskDominantCornerCount + 1
      end

      local rawBrakeBiasM = brakeBiasClamp(state and (state.rawCornerBrakeBiasM or state.brakeBiasM or state.cornerBrakeBiasM))
      local setupTrustScaleValue = clamp(finiteNumber(state and state.cornerLearningSetupTrustScale, 1.0), 0.0, 1.0)
      local biasDampingM = math.abs(rawBrakeBiasM - appliedBrakeBias(rawBrakeBiasM, confidence, setupTrustScaleValue))
      if confidence < minConfidence or biasDampingM > maxBiasDampingM then
        minConfidence = math.min(minConfidence, confidence)
        maxBiasDampingM = math.max(maxBiasDampingM, biasDampingM)
        worstKey = tostring(key or 'none')
        worstCauseBucket = tostring(state and state.cornerLearningCauseBucket or 'none')
      end
    end
  end

  if observedCornerCount <= 0 then
    minConfidence = 0.0
    worstKey = 'none'
    worstCauseBucket = 'none'
  end

  return {
    observedCornerCount = observedCornerCount,
    lowConfidenceCornerCount = lowConfidenceCornerCount,
    riskDominantCornerCount = riskDominantCornerCount,
    minConfidence = minConfidence,
    maxBiasDampingM = maxBiasDampingM,
    worstKey = worstKey,
    worstCauseBucket = worstCauseBucket,
  }
end

local function classifyAdjustment(cue)
  local cueTimingState = tostring(cue.cueTimingState or 'unknown')
  local responseState = tostring(cue.responseState or 'unknown')
  local actualBrakeInput = effectiveBrakeInput(cue)
  local speedDropKph = finiteNumber(cue.speedDropKph, 0.0)
  local adjustment = measuredBrakePointAdjustment(cue)
  adjustment = adjustment + weakDecelAdjustment(cue, responseState)
  local cornerResultAdjustment, cornerResultLearningReason, cornerSpeedOverTargetKph, cornerResultOverspeedPhase =
    cornerResultSpeedAdjustment(cue, responseState)
  adjustment = adjustment + cornerResultAdjustment

  if cueTimingState:find('late', 1, true) == 1 or responseState == 'late_no_brake' then
    adjustment = adjustment + 4.0
  end
  if cueTimingState:find('early', 1, true) == 1 and actualBrakeInput >= 0.20 and speedDropKph >= 1.0 then
    adjustment = adjustment - 2.5
  end
  local adjusted, brakeLimitLearningReason = brakeLimitLearning(cue, adjustment)
  return adjusted, brakeLimitLearningReason, cornerResultLearningReason, cornerSpeedOverTargetKph, cornerResultOverspeedPhase
end

function M.observe(car, cue)
  cue = cue or {}
  local key = M.cornerKey(car, cue)
  local previous = stateByKey[key] or {
    brakeBiasM = 0.0,
    rawCornerBrakeBiasM = 0.0,
    cornerLearningConfidence = finiteNumber(settings.CORNER_LEARNING_CONFIDENCE_START, 1.0),
    cornerLearningCleanWindowSamples = 0.0,
    cornerLearningRiskWindowSamples = 0.0,
    samples = 0,
    state = 'new',
  }
  local predictedBrakePointM = finiteNumber(cue.predictedBrakePointM, 0.0)
  local actualBrakeInput = finiteNumber(cue.actualBrakeInput, 0.0)
  local speedDropKph = finiteNumber(cue.speedDropKph, 0.0)
  local actualBrakePointErrorM = finiteNumber(cue.actualBrakePointErrorM, 0.0)
  local actualBrakeOnsetState = token(cue.actualBrakeOnsetState or 'none')
  local actualBrakeOnsetZoneStartDistanceM = finiteNumber(cue.actualBrakeOnsetZoneStartDistanceM, 0.0)
  local actualBrakeOnsetInput = clamp(cue.actualBrakeOnsetInput, 0.0, 1.0)
  local effectiveBrakeInputValue = effectiveBrakeInput(cue)
  local actualBrakeOnsetSpeedKph = finiteNumber(cue.actualBrakeOnsetSpeedKph, 0.0)
  local turnInSpeedKph = finiteNumber(cue.turnInSpeedKph, 0.0)
  local turnInCaptureState = token(cue.turnInCaptureState or 'none')
  local turnInSampleZoneStartDistanceM = finiteNumber(cue.turnInSampleZoneStartDistanceM, 0.0)
  local targetSpeedKph = finiteNumber(cue.targetSpeedKph, 0.0)
  local exitTargetSpeedKph = finiteNumber(cue.exitTargetSpeedKph, targetSpeedKph)
  local apexSpeedKph = finiteNumber(cue.apexSpeedKph, 0.0)
  local apexCaptureState = token(cue.apexCaptureState or 'none')
  local exitSpeedKph = finiteNumber(cue.exitSpeedKph, 0.0)
  local exitCaptureState = token(cue.exitCaptureState or 'none')
  local cornerSpeedOverTargetKph = actualSpeedOverTargetKph(cue)
  local traceSamples = math.max(0, math.floor(finiteNumber(cue.traceSamples, 0.0) + 0.5))
  local traceMinZoneStartDistanceM = finiteNumber(cue.traceMinZoneStartDistanceM, 0.0)
  local traceMaxZoneStartDistanceM = finiteNumber(cue.traceMaxZoneStartDistanceM, 0.0)
  local sampleAccepted = cue.sampleAccepted ~= false
  local rejectionReason = sampleAccepted and 'accepted' or token(cue.rejectionReason or 'rejected')
  local adjustment = 0.0
  local brakeLimitLearningReason = 'not_classified'
  local cornerResultLearningReason = sampleAccepted and 'speed_result_nominal' or 'sample_rejected'
  local cornerResultOverspeedPhase = 'none'
  if sampleAccepted then
    adjustment, brakeLimitLearningReason, cornerResultLearningReason, cornerSpeedOverTargetKph, cornerResultOverspeedPhase =
      classifyAdjustment(cue)
  end
  local learningBucket = learningCauseBucket(cue, sampleAccepted, rejectionReason, cornerResultLearningReason)
  incrementLearningSummary(learningBucket)
  local cleanWindowSamples, riskWindowSamples = updateLearningWindow(previous, learningBucket)
  local learningConfidence, cleanWindowSamples, riskWindowSamples = learningConfidenceAfterBucket(
    previous.cornerLearningConfidence, learningBucket, cleanWindowSamples, riskWindowSamples)
  local setupTrustScaleValue, setupKnown = setupTrustScale(car, cue)
  local windowSamples = cleanWindowSamples + riskWindowSamples
  if cue.sampleAccepted == false then
    local brakeBiasM = brakeBiasClamp(previous.rawCornerBrakeBiasM or previous.brakeBiasM or previous.cornerBrakeBiasM)
    local preserved = {
      cornerLearningKey = key,
      cornerLearningMomentKey = token(cue.cornerLearningMomentKey or cue.momentKey or cue.momentGripKey or
        car.cornerLearningMomentKey or 'moment_unknown'),
      cornerLearningState = 'sample_rejected_' .. rejectionReason,
      predictedBrakePointM = predictedBrakePointM,
      actualBrakeInput = actualBrakeInput,
      effectiveBrakeInput = effectiveBrakeInputValue,
      speedDropKph = speedDropKph,
      actualBrakePointErrorM = actualBrakePointErrorM,
      actualBrakeOnsetState = actualBrakeOnsetState,
      actualBrakeOnsetZoneStartDistanceM = actualBrakeOnsetZoneStartDistanceM,
      actualBrakeOnsetInput = actualBrakeOnsetInput,
      actualBrakeOnsetSpeedKph = actualBrakeOnsetSpeedKph,
      turnInSpeedKph = turnInSpeedKph,
      turnInCaptureState = turnInCaptureState,
      turnInSampleZoneStartDistanceM = turnInSampleZoneStartDistanceM,
      targetSpeedKph = targetSpeedKph,
      exitTargetSpeedKph = exitTargetSpeedKph,
      apexSpeedKph = apexSpeedKph,
      apexCaptureState = apexCaptureState,
      exitSpeedKph = exitSpeedKph,
      exitCaptureState = exitCaptureState,
      cornerSpeedOverTargetKph = cornerSpeedOverTargetKph,
      cornerResultLearningReason = 'sample_rejected',
      cornerResultOverspeedPhase = 'none',
      traceSamples = traceSamples,
      traceMinZoneStartDistanceM = traceMinZoneStartDistanceM,
      traceMaxZoneStartDistanceM = traceMaxZoneStartDistanceM,
      sampleAccepted = false,
      cornerLearningRejectReason = rejectionReason,
      cornerLearningBrakeLimitReason = 'sample_rejected_' .. rejectionReason,
      cornerLearningCauseBucket = learningBucket,
      adjustmentScale = 0.0,
      brakeBiasM = brakeBiasM,
      rawCornerBrakeBiasM = brakeBiasM,
      cornerBrakeBiasM = appliedBrakeBias(brakeBiasM, learningConfidence, setupTrustScaleValue),
      cornerLearningConfidence = learningConfidence,
      cornerLearningSetupKnown = setupKnown,
      cornerLearningSetupTrustScale = setupTrustScaleValue,
      cornerLearningCleanWindowSamples = cleanWindowSamples,
      cornerLearningRiskWindowSamples = riskWindowSamples,
      cornerLearningWindowSamples = windowSamples,
      samples = math.max(0, math.floor(finiteNumber(previous.samples, 0) + 0.5)),
      globalCorneringGDelta = 0.0,
      globalBrakeGDelta = 0.0,
    }
    stateByKey[key] = preserved
    knowledge_base.observeCorner(car, cue, preserved)
    return preserved
  end
  local adjustmentScale = clamp(cue.adjustmentScale, 0.05, 1.0)
  adjustment = adjustment * adjustmentScale
  local previousRawBrakeBiasM = brakeBiasClamp(previous.rawCornerBrakeBiasM or previous.brakeBiasM or previous.cornerBrakeBiasM)
  local brakeBiasM = brakeBiasClamp(previousRawBrakeBiasM * 0.82 + adjustment)
  local cornerBrakeBiasM = appliedBrakeBias(brakeBiasM, learningConfidence, setupTrustScaleValue)
  local state = adjustment > 0.0 and 'moving_brake_cue_earlier' or
    (adjustment < 0.0 and 'relaxing_early_brake_cue' or 'observing')

  local updated = {
    cornerLearningKey = key,
    cornerLearningMomentKey = token(cue.cornerLearningMomentKey or cue.momentKey or cue.momentGripKey or
      car.cornerLearningMomentKey or 'moment_unknown'),
    cornerLearningState = state,
    predictedBrakePointM = predictedBrakePointM,
    actualBrakeInput = actualBrakeInput,
    effectiveBrakeInput = effectiveBrakeInputValue,
    speedDropKph = speedDropKph,
    actualBrakePointErrorM = actualBrakePointErrorM,
    actualBrakeOnsetState = actualBrakeOnsetState,
    actualBrakeOnsetZoneStartDistanceM = actualBrakeOnsetZoneStartDistanceM,
    actualBrakeOnsetInput = actualBrakeOnsetInput,
    actualBrakeOnsetSpeedKph = actualBrakeOnsetSpeedKph,
    turnInSpeedKph = turnInSpeedKph,
    turnInCaptureState = turnInCaptureState,
    turnInSampleZoneStartDistanceM = turnInSampleZoneStartDistanceM,
    targetSpeedKph = targetSpeedKph,
    exitTargetSpeedKph = exitTargetSpeedKph,
    apexSpeedKph = apexSpeedKph,
    apexCaptureState = apexCaptureState,
    exitSpeedKph = exitSpeedKph,
    exitCaptureState = exitCaptureState,
    cornerSpeedOverTargetKph = cornerSpeedOverTargetKph,
    cornerResultLearningReason = cornerResultLearningReason,
    cornerResultOverspeedPhase = cornerResultOverspeedPhase,
    traceSamples = traceSamples,
    traceMinZoneStartDistanceM = traceMinZoneStartDistanceM,
    traceMaxZoneStartDistanceM = traceMaxZoneStartDistanceM,
    sampleAccepted = true,
    cornerLearningRejectReason = 'accepted',
    cornerLearningBrakeLimitReason = brakeLimitLearningReason,
    cornerLearningCauseBucket = learningBucket,
    brakeLimitState = tostring(cue.brakeLimitState or 'clean_threshold'),
    brakeLockupAxle = tostring(cue.brakeLockupAxle or 'none'),
    brakeLearningRejectReason = tostring(cue.brakeLearningRejectReason or 'unknown'),
    adjustmentScale = adjustmentScale,
    brakeBiasM = brakeBiasM,
    rawCornerBrakeBiasM = brakeBiasM,
    cornerBrakeBiasM = cornerBrakeBiasM,
    cornerLearningConfidence = learningConfidence,
    cornerLearningSetupKnown = setupKnown,
    cornerLearningSetupTrustScale = setupTrustScaleValue,
    cornerLearningCleanWindowSamples = cleanWindowSamples,
    cornerLearningRiskWindowSamples = riskWindowSamples,
    cornerLearningWindowSamples = windowSamples,
    samples = (previous.samples or 0) + 1,
    globalCorneringGDelta = 0.0,
    globalBrakeGDelta = 0.0,
  }
  stateByKey[key] = updated
  knowledge_base.observeCorner(car, cue, updated)
  return updated
end

function M.biasFor(car, cue)
  local key = M.cornerKey(car, cue)
  local state = stateByKey[key]
  if not state then
    state = knowledge_base.cornerState(key)
    if state then stateByKey[key] = state end
  end
  state = state or {}
  local rawBrakeBiasM = brakeBiasClamp(state.rawCornerBrakeBiasM or state.brakeBiasM or state.cornerBrakeBiasM)
  local learningConfidence = learningConfidenceValue(state.cornerLearningConfidence)
  local setupTrustScaleValue, setupKnown = setupTrustScale(car, cue)
  local cleanWindowSamples = math.max(0.0,
    finiteNumber(state.cornerLearningCleanWindowSamples or state.cleanWindowSamples, 0.0))
  local riskWindowSamples = math.max(0.0,
    finiteNumber(state.cornerLearningRiskWindowSamples or state.riskWindowSamples, 0.0))
  return {
    cornerLearningKey = key,
    cornerLearningMomentKey = token(cue.cornerLearningMomentKey or cue.momentKey or cue.momentGripKey or
      car.cornerLearningMomentKey or 'moment_unknown'),
    cornerLearningState = tostring(state.cornerLearningState or state.state or 'unlearned'),
    cornerBrakeBiasM = appliedBrakeBias(rawBrakeBiasM, learningConfidence, setupTrustScaleValue),
    brakeBiasM = rawBrakeBiasM,
    rawCornerBrakeBiasM = rawBrakeBiasM,
    cornerLearningConfidence = learningConfidence,
    cornerLearningSetupKnown = setupKnown,
    cornerLearningSetupTrustScale = setupTrustScaleValue,
    cornerLearningCleanWindowSamples = cleanWindowSamples,
    cornerLearningRiskWindowSamples = riskWindowSamples,
    cornerLearningWindowSamples = cleanWindowSamples + riskWindowSamples,
    samples = math.max(0, math.floor(finiteNumber(state.samples, 0) + 0.5)),
    traceSamples = math.max(0, math.floor(finiteNumber(state.traceSamples, 0) + 0.5)),
    traceMinZoneStartDistanceM = finiteNumber(state.traceMinZoneStartDistanceM, 0.0),
    traceMaxZoneStartDistanceM = finiteNumber(state.traceMaxZoneStartDistanceM, 0.0),
    sampleAccepted = state.sampleAccepted == true,
    cornerLearningRejectReason = tostring(state.cornerLearningRejectReason or 'none'),
    cornerLearningBrakeLimitReason = tostring(state.cornerLearningBrakeLimitReason or 'none'),
    cornerLearningCauseBucket = tostring(state.cornerLearningCauseBucket or 'none'),
    cornerSpeedOverTargetKph = finiteNumber(state.cornerSpeedOverTargetKph, 0.0),
    cornerResultLearningReason = tostring(state.cornerResultLearningReason or 'none'),
    cornerResultOverspeedPhase = tostring(state.cornerResultOverspeedPhase or 'none'),
    actualBrakeOnsetState = tostring(state.actualBrakeOnsetState or 'none'),
    actualBrakeOnsetZoneStartDistanceM = finiteNumber(state.actualBrakeOnsetZoneStartDistanceM, 0.0),
    actualBrakeOnsetInput = clamp(state.actualBrakeOnsetInput, 0.0, 1.0),
    effectiveBrakeInput = clamp(state.effectiveBrakeInput, 0.0, 1.0),
    actualBrakeOnsetSpeedKph = finiteNumber(state.actualBrakeOnsetSpeedKph, 0.0),
    turnInCaptureState = tostring(state.turnInCaptureState or 'none'),
    turnInSampleZoneStartDistanceM = finiteNumber(state.turnInSampleZoneStartDistanceM, 0.0),
    brakeLimitState = tostring(state.brakeLimitState or 'unknown'),
    brakeLockupAxle = tostring(state.brakeLockupAxle or 'unknown'),
    brakeLearningRejectReason = tostring(state.brakeLearningRejectReason or 'unknown'),
    globalCorneringGDelta = 0.0,
    globalBrakeGDelta = 0.0,
  }
end

function M.summary()
  local riskSummary = cornerRiskSummary()
  return {
    cleanAccepted = learningSummary.cleanAccepted or 0,
    noBrake = learningSummary.noBrake or 0,
    weakDecel = learningSummary.weakDecel or 0,
    overspeed = learningSummary.overspeed or 0,
    resultOverspeed = learningSummary.resultOverspeed or 0,
    abs = learningSummary.abs or 0,
    frontLockup = learningSummary.frontLockup or 0,
    rearLockup = learningSummary.rearLockup or 0,
    allLockup = learningSummary.allLockup or 0,
    unknownLockup = learningSummary.unknownLockup or 0,
    rejected = learningSummary.rejected or 0,
    observedCornerCount = riskSummary.observedCornerCount,
    lowConfidenceCornerCount = riskSummary.lowConfidenceCornerCount,
    riskDominantCornerCount = riskSummary.riskDominantCornerCount,
    minConfidence = riskSummary.minConfidence,
    maxBiasDampingM = riskSummary.maxBiasDampingM,
    worstKey = riskSummary.worstKey,
    worstCauseBucket = riskSummary.worstCauseBucket,
  }
end

function M.reset()
  stateByKey = {}
  resetLearningSummary()
end

return M
