-- DynamicRacingLine line_core/track_data_ingest.lua
-- R02: converts runtime width/surface/AI-line hints into boundary providers and AI offsets.

local TrackLimits = require('src.line_core.track_limits')
local Config = require('src.line_core.config')
local U = require('src.line_core.math_utils')
local M = {}

local function nonEmptyList(value)
  return type(value) == 'table' and #value > 0 and value or nil
end

local function signedAngle(y, x)
  y = tonumber(y) or 0.0
  x = tonumber(x) or 0.0
  if math.atan2 then return math.atan2(y, x) end
  if math.abs(x) < 1e-9 then
    if y > 0 then return math.pi * 0.5 end
    if y < 0 then return -math.pi * 0.5 end
    return 0.0
  end
  local angle = math.atan(y / x)
  if x < 0 then
    return angle + (y >= 0 and math.pi or -math.pi)
  end
  return angle
end

local function samplesFromRuntime(runtime)
  runtime = runtime or {}
  local ref = runtime.trackFileReference or {}
  return nonEmptyList(runtime.aiLineSamples) or nonEmptyList(runtime.fileAiLineSamples) or
    nonEmptyList(ref.aiLineSamples) or nonEmptyList(ref.fileAiLineSamples) or
    nonEmptyList(runtime.aiSplineSamples) or nonEmptyList(runtime.aiLine) or
    nonEmptyList(runtime.referenceLineSamples)
end

function M.mergeRuntimeReference(runtime)
  runtime = runtime or {}
  local ref = runtime.trackFileReference or runtime.acTrackReference
  if type(ref) ~= 'table' then return runtime end
  if runtime.aiLineSamples == nil and ref.aiLineSamples then runtime.aiLineSamples = ref.aiLineSamples end
  if runtime.fileAiLineSamples == nil and ref.fileAiLineSamples then runtime.fileAiLineSamples = ref.fileAiLineSamples end
  if runtime.surfaceHints == nil and ref.surfaceHints then runtime.surfaceHints = ref.surfaceHints end
  if runtime.aiHints == nil and ref.aiHints then runtime.aiHints = ref.aiHints end
  if runtime.speedHints == nil and ref.speedHints then runtime.speedHints = ref.speedHints end
  if runtime.brakeHints == nil and ref.brakeHints then runtime.brakeHints = ref.brakeHints end
  if runtime.dangerHints == nil and ref.dangerHints then runtime.dangerHints = ref.dangerHints end
  runtime.trackFileReference = ref
  runtime.trackSplineSamples = runtime.trackSplineSamples or runtime.centerlineSamples or runtime.samples
  runtime.trackFileReferenceKnown = (ref.aiLineSamples and #ref.aiLineSamples > 0) == true
  return runtime
end

function M.boundaryProviderFromLimits(runtime, frame)
  runtime = runtime or {}
  if runtime.boundaryProvider then return runtime.boundaryProvider end
  local limits = runtime.trackLimits
  if limits and not limits.samples and (limits.left or limits.right or limits.leftWidth or limits.rightWidth) then limits = { limits } end
  if limits and limits.samples then
    return TrackLimits.newProvider({ trackLength = frame and frame.length or runtime.trackLength, widthSamples = limits.samples, surfaceSamples = runtime.surfaceSamples, aiLineSamples = samplesFromRuntime(runtime), wallSamples = runtime.wallSamples, kerbSamples = runtime.kerbSamples })
  end
  if runtime.widthSamples or runtime.trackLimitSamples or runtime.surfaceSamples or samplesFromRuntime(runtime) then
    return TrackLimits.newProvider({ trackLength = frame and frame.length or runtime.trackLength, widthSamples = runtime.widthSamples or runtime.trackLimitSamples, surfaceSamples = runtime.surfaceSamples, aiLineSamples = samplesFromRuntime(runtime), wallSamples = runtime.wallSamples, kerbSamples = runtime.kerbSamples })
  end
  return nil
end

function M.projectReferenceOffsets(frame, runtimeOrSamples)
  if not frame then return nil end
  if runtimeOrSamples and runtimeOrSamples.aiOffsets then return runtimeOrSamples.aiOffsets end
  local samples = samplesFromRuntime(runtimeOrSamples) or runtimeOrSamples
  if not samples or #samples == 0 then return nil end
  return TrackLimits.extractAiOffsets(frame, samples)
end

local function worldFromSample(sample)
  if not sample then return nil end
  return sample.world or sample.pos or sample.position or sample.centerPos or sample.centerlinePos or sample
end

local function referenceWorldsForFrame(frame, samples)
  local out = {}
  local frameSamples = frame and frame.samples or {}
  for i, s in ipairs(frameSamples) do
    local ref, distance = U.nearestByProgress(samples, s.progress, frame.length)
    if ref and (distance or math.huge) <= math.max(18.0, (frame.spacing or Config.TARGET_SAMPLE_SPACING_M) * 4.0) then
      out[i] = worldFromSample(ref)
    end
    if out[i] == nil then out[i] = s.world end
  end
  return out
end

local function referenceQualityForFrame(frame, samples, sourceName)
  local frameSamples = frame and frame.samples or {}
  if not samples or #samples < 3 or #frameSamples < 3 then
    return {
      accepted = false,
      confidence = 0.0,
      coverage = 0.0,
      maxLateralM = math.huge,
      reason = 'not_enough_reference_points',
      source = sourceName or 'unknown_reference',
    }
  end

  local Frame = require('src.line_core.frame')
  local matched, badLateral, maxLateral = 0, 0, 0.0
  local toleranceM = math.max(18.0, (frame.spacing or Config.TARGET_SAMPLE_SPACING_M) * 5.0)
  for _, s in ipairs(frameSamples) do
    local ref, distance = U.nearestByProgress(samples, s.progress, frame.length)
    if ref and (distance or math.huge) <= toleranceM then
      local world = worldFromSample(ref)
      local projected = world and Frame.projectWorld(frame, world, s.progress, toleranceM)
      if projected and projected.ok then
        matched = matched + 1
        local lateral = math.abs(tonumber(projected.lateral) or 0.0)
        maxLateral = math.max(maxLateral, lateral)
        local limit = math.max(3.0,
          math.max(tonumber(s.leftWidth) or Config.DEFAULT_TRACK_HALF_WIDTH_M,
            tonumber(s.rightWidth) or Config.DEFAULT_TRACK_HALF_WIDTH_M) + 2.0)
        if lateral > limit then badLateral = badLateral + 1 end
      end
    end
  end

  local coverage = matched / math.max(1, #frameSamples)
  local badRatio = badLateral / math.max(1, matched)
  local confidence = U.clamp(coverage * (1.0 - badRatio * 1.35), 0.0, 1.0)
  local reason = 'ok'
  local accepted = confidence >= Config.AI_REFERENCE_MIN_CONFIDENCE
  if coverage < 0.42 then
    accepted = false
    reason = 'low_coverage'
  elseif badRatio > 0.20 then
    accepted = false
    reason = 'lateral_out_of_bounds'
  end
  return {
    accepted = accepted,
    confidence = confidence,
    coverage = coverage,
    badLateralRatio = badRatio,
    maxLateralM = maxLateral,
    reason = reason,
    source = sourceName or 'unknown_reference',
  }
end

local function curvatureAt(worlds, i)
  local n = #worlds
  if n < 3 then return 0 end
  local a = worlds[i - 1] or worlds[n]
  local b = worlds[i]
  local c = worlds[i + 1] or worlds[1]
  if not a or not b or not c then return 0 end
  local ab = U.norm2(U.sub(b, a))
  local bc = U.norm2(U.sub(c, b))
  local dot = U.clamp(U.dot2(ab, bc), -1, 1)
  local crossY = ab.x * bc.z - ab.z * bc.x
  local angle = signedAngle(crossY, dot)
  local ds = math.max(0.75, (U.distance2(a, b) + U.distance2(b, c)) * 0.5)
  return angle / ds
end

local function genericReferenceSpeedCap(curvature)
  local ak = math.abs(curvature or 0)
  if ak < 0.0007 then return Config.DEFAULT_TOP_SPEED_MPS end
  local mu = Config.DEFAULT_MU * 1.35
  local cap = math.sqrt(math.max(1.0, mu * Config.GRAVITY / ak))
  return U.clamp(cap, 7.0, Config.DEFAULT_TOP_SPEED_MPS)
end

local function progressInRange(progress01, startProgress, endProgress)
  progress01 = (tonumber(progress01) or 0.0) % 1.0
  startProgress = (tonumber(startProgress) or 0.0) % 1.0
  endProgress = (tonumber(endProgress) or 0.0) % 1.0
  if startProgress <= endProgress then
    return progress01 >= startProgress and progress01 <= endProgress
  end
  return progress01 >= startProgress or progress01 <= endProgress
end

local function hintScaleForProgress(progressM, trackLength, runtime)
  runtime = runtime or {}
  local progress01 = trackLength and trackLength > 0 and ((progressM or 0.0) / trackLength) % 1.0 or 0.0
  local aiHints = runtime.aiHints or {}
  local speedHints = nonEmptyList(runtime.speedHints) or nonEmptyList(aiHints.speedHints) or {}
  local brakeHints = nonEmptyList(runtime.brakeHints) or nonEmptyList(aiHints.brakeHints) or {}
  local dangerHints = nonEmptyList(runtime.dangerHints) or nonEmptyList(aiHints.dangerHints) or {}
  local scale = 1.0
  local risk = 0.0
  for _, hint in ipairs(speedHints) do
    if progressInRange(progress01, hint.startProgress, hint.endProgress) then
      scale = math.min(scale, U.clamp(tonumber(hint.value) or 1.0, 0.62, 1.08))
    end
  end
  for _, hint in ipairs(brakeHints) do
    if progressInRange(progress01, hint.startProgress, hint.endProgress) then
      local value = U.clamp(tonumber(hint.value) or 1.0, 0.0, 1.25)
      scale = math.min(scale, U.clamp(0.78 + value * 0.18, 0.58, 1.0))
      risk = math.max(risk, 1.0 - math.min(value, 1.0))
    end
  end
  for _, hint in ipairs(dangerHints) do
    if progressInRange(progress01, hint.startProgress, hint.endProgress) then
      local danger = math.max(tonumber(hint.left) or 0.0, tonumber(hint.right) or 0.0, tonumber(hint.value) or 0.0)
      danger = U.clamp(danger, 0.0, 1.0)
      scale = math.min(scale, 1.0 - danger * 0.18)
      risk = math.max(risk, danger)
    end
  end
  return scale, risk
end

function M.referenceBrakeSpeedHints(frame, runtime)
  runtime = M.mergeRuntimeReference(runtime or {})
  if not frame or not frame.samples or #frame.samples < 3 then return nil end
  local aiLineSamples = samplesFromRuntime(runtime)
  local trackSplineSamples = nonEmptyList(runtime.trackSplineSamples) or nonEmptyList(runtime.centerlineSamples) or
    nonEmptyList(runtime.trackSamples) or nonEmptyList(runtime.samples)
  local aiQuality = aiLineSamples and referenceQualityForFrame(frame, aiLineSamples, 'ai_spline_reference') or nil
  local trackQuality = trackSplineSamples and referenceQualityForFrame(frame, trackSplineSamples, 'track_spline_reference') or nil
  local acceptedAiLineSamples = aiQuality and aiQuality.accepted == true and aiLineSamples or nil
  local acceptedTrackSplineSamples = trackQuality and trackQuality.accepted == true and trackSplineSamples or nil
  local referenceSamples = acceptedAiLineSamples or acceptedTrackSplineSamples
  if not referenceSamples or #referenceSamples < 3 then return nil end
  local referenceQuality = acceptedAiLineSamples and aiQuality or trackQuality
  local source = acceptedAiLineSamples and 'ai_spline_reference' or 'track_spline_reference'
  if aiLineSamples and not acceptedAiLineSamples then
    source = 'track_spline_reference_rejected_ai_reference_quality'
  end

  local worlds = referenceWorldsForFrame(frame, referenceSamples)
  local referenceCurvatureByIndex = {}
  local referenceSpeedCapMpsByIndex = {}
  local referenceHintScaleByIndex = {}
  local referenceRiskByIndex = {}
  for i = 1, #frame.samples do
    local k = curvatureAt(worlds, i)
    local hintScale, hintRisk = hintScaleForProgress(frame.samples[i].progress, frame.length, runtime)
    referenceCurvatureByIndex[i] = k
    referenceHintScaleByIndex[i] = hintScale
    referenceRiskByIndex[i] = hintRisk
    referenceSpeedCapMpsByIndex[i] = genericReferenceSpeedCap(k)
  end
  return {
    source = source,
    geometryOnly = true,
    trackSplineSamples = acceptedTrackSplineSamples,
    rejectedTrackSplineSamples = trackSplineSamples and not acceptedTrackSplineSamples and trackSplineSamples or nil,
    aiLineSamples = acceptedAiLineSamples,
    rejectedAiLineSamples = aiLineSamples and not acceptedAiLineSamples and aiLineSamples or nil,
    referenceQuality = referenceQuality,
    rejectedAiReferenceQuality = aiLineSamples and not acceptedAiLineSamples and aiQuality or nil,
    rejectedTrackSplineReferenceQuality = trackSplineSamples and not acceptedTrackSplineSamples and trackQuality or nil,
    referenceCurvatureByIndex = referenceCurvatureByIndex,
    referenceSpeedCapMpsByIndex = referenceSpeedCapMpsByIndex,
    referenceHintScaleByIndex = referenceHintScaleByIndex,
    referenceRiskByIndex = referenceRiskByIndex,
    confidence = U.clamp((referenceQuality and referenceQuality.confidence or 0.50) *
      (acceptedAiLineSamples and 0.82 or 0.58), 0.18, acceptedAiLineSamples and 0.72 or 0.50),
  }
end

M.hintScaleForProgress = hintScaleForProgress
M.referenceQualityForFrame = referenceQualityForFrame

return M
