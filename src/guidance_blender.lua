local settings = require('src/settings')
local predictive_baseline = require('src/predictive_baseline')

local M = {}

local confidenceOrder = {
  liveTelemetry = 8,
  physicsSetup = 7,
  predictiveBaseline = 6,
  learnedProfile = 5,
  curatedProfile = 4,
  classHeuristic = 3,
  genericFallback = 2,
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

local function sourceConfidence(context, session)
  context = context or {}
  session = session or {}
  local liveTelemetry = finiteNumber(context.liveGripEnvelopeConfidence, 0.0)
  if finiteNumber(context.currentSpeedKph, 0.0) > 5.0 then liveTelemetry = math.max(liveTelemetry, 0.65) end
  local physicsSetup = math.max(
    finiteNumber(context.confidence, 0.0),
    finiteNumber(context.setupBrakeAdaptationConfidence, 0.0),
    finiteNumber(context.aeroConfidence, 0.0))
  local predictiveBaseline = clamp(0.62 + physicsSetup * 0.22, 0.40, 0.86)
  local learnedProfile = finiteNumber(session.learned_profile and session.learned_profile.confidence, 0.0)
  local curatedProfile = math.max(
    finiteNumber(session.track_profile and session.track_profile.confidence, 0.0),
    finiteNumber(session.car_profile and session.car_profile.confidence, 0.0))
  local classHeuristic = finiteNumber(context.classConfidence, 0.35)
  local genericFallback = 0.22
  return {
    liveTelemetry = liveTelemetry,
    physicsSetup = physicsSetup,
    predictiveBaseline = predictiveBaseline,
    learnedProfile = learnedProfile,
    curatedProfile = curatedProfile,
    classHeuristic = classHeuristic,
    genericFallback = genericFallback,
  }
end

local function bestSource(scores)
  local bestName = 'genericFallback'
  local bestRank = -1
  local bestScore = -1
  for name, score in pairs(scores or {}) do
    local rank = confidenceOrder[name] or 0
    local trustedScore = finiteNumber(score, 0.0)
    if trustedScore > 0.05 and (rank > bestRank or (rank == bestRank and trustedScore > bestScore)) then
      bestName = name
      bestRank = rank
      bestScore = trustedScore
    end
  end
  return bestName, clamp(bestScore, 0.0, 1.0)
end

local function learnedCorner(session, sample)
  local learned = session and session.learned_profile
  local corners = learned and learned.corners
  if type(corners) ~= 'table' then return nil end
  return corners[tostring(sample and sample.cornerId or '')]
end

local function learnedCorrectionScale(source)
  source = tostring(source or '')
  if source == 'liveTelemetry' or source == 'physicsSetup' then return 0.25 end
  if source == 'predictiveBaseline' then return 0.40 end
  return 1.0
end

local function applyLearnedCorrection(sample, correction, source)
  if type(correction) ~= 'table' then return end
  local confidence = clamp(finiteNumber(correction.confidence, 0.0), 0.0, 1.0)
  if confidence <= 0.01 then return end
  local authority = learnedCorrectionScale(source)
  local brakeOffset = clamp(finiteNumber(correction.brake_offset_m, 0.0) * confidence * authority, -6.0, 18.0)
  sample.cornerBrakeBiasM = finiteNumber(sample.cornerBrakeBiasM, 0.0) + brakeOffset
  local storedTargetOffset = finiteNumber(correction.target_speed_offset_kmh,
    finiteNumber(correction.apex_speed_offset_kmh, 0.0))
  local apexOffset = clamp(storedTargetOffset * confidence * authority, -12.0, 6.0)
  if apexOffset ~= 0.0 and tostring(sample.segmentType or '') ~= 'straight' then
    sample.targetSpeedKph = math.max(settings.MIN_CORNER_SPEED_KPH,
      finiteNumber(sample.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH) + apexOffset)
    sample.brakeProfileTargetSpeedKph = math.min(finiteNumber(sample.brakeProfileTargetSpeedKph, sample.targetSpeedKph), sample.targetSpeedKph)
  end
  sample.learnedProfileConfidence = confidence
  sample.learnedBrakeOffsetM = brakeOffset
end

function M.apply(samples, context, session, options)
  samples = samples or {}
  context = context or {}
  session = session or {}
  options = options or {}
  local baseline = predictive_baseline.apply(samples, context, session, options)
  local scores = sourceConfidence(context, session)
  local source, confidence = bestSource(scores)
  for _, sample in ipairs(samples) do
    applyLearnedCorrection(sample, learnedCorner(session, sample), source)
    sample.guidanceConfidence = clamp(math.max(confidence, finiteNumber(sample.predictiveConfidence, 0.0)), 0.0, 1.0)
    sample.guidanceSource = source
    sample.guidanceConfidenceOrder = 'liveTelemetry>physicsSetup>predictiveBaseline>learnedProfile>curatedProfile>classHeuristic>genericFallback'
    sample.guidanceBrakeIntensity = math.max(finiteNumber(sample.predictiveBrakeIntensity, 0.0), finiteNumber(sample.cueSeverity, 0.0))
  end
  return baseline
end

M.confidenceOrder = confidenceOrder

return M
