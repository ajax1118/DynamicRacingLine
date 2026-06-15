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

local function rejectBadMoment(observation)
  observation = observation or {}
  if observation.sampleAccepted ~= true then return true, tostring(observation.rejectionReason or 'sample_rejected') end
  if finiteNumber(observation.offtrackRisk, 0.0) > 0.20 then return true, 'offtrack' end
  if finiteNumber(observation.spinRisk, 0.0) > 0.82 then return true, 'spin_risk' end
  if finiteNumber(observation.lockupRisk, 0.0) > 0.92 then return true, 'hard_lockup' end
  local brakeReason = tostring(observation.brakeLearningRejectReason or '')
  if brakeReason ~= '' and brakeReason ~= 'accepted' and brakeReason ~= 'accepted_clean' and brakeReason ~= 'accepted_clean_strong' then
    return true, brakeReason
  end
  return false, 'accepted'
end

local function driverConsistency(observation)
  observation = observation or {}
  local brakeInput = clamp(finiteNumber(observation.brakeInput, 0.0), 0.0, 1.0)
  local speedDrop = math.max(0.0, finiteNumber(observation.speedDropKph, 0.0))
  local traceSamples = math.max(0.0, finiteNumber(observation.traceSamples, 2.0))
  local inputScore = brakeInput >= 0.15 and 0.35 or 0.12
  local speedScore = clamp(speedDrop / 5.0, 0.0, 0.35)
  local traceScore = clamp(traceSamples / 8.0, 0.0, 0.30)
  return clamp(inputScore + speedScore + traceScore, 0.0, 1.0)
end

local function cueAlignmentConfidence(observation)
  observation = observation or {}
  local error = math.abs(finiteNumber(observation.actualBrakePointErrorM, 0.0))
  local targetDistance = math.max(8.0, finiteNumber(observation.targetSampleDistanceM, 45.0))
  local confidence = 1.0 - clamp(error / math.max(18.0, targetDistance * 0.75), 0.0, 0.72)
  local timing = tostring(observation.cueTimingState or '')
  if timing:find('late', 1, true) or timing:find('early', 1, true) then confidence = confidence * 0.86 end
  return clamp(confidence, 0.18, 1.0)
end

local function consecutiveEvidence(corner, observation)
  corner = corner or {}
  observation = observation or {}
  local response = tostring(observation.responseState or '')
  local overspeed = finiteNumber(observation.speedOverTargetKph, 0.0)
  local polarity = (response:find('late', 1, true) or response:find('overspeed', 1, true) or overspeed > 4.0) and 'later' or 'neutral'
  local previous = tostring(corner.lastEvidencePolarity or '')
  local count = previous == polarity and (finiteNumber(corner.consecutiveEvidence, 0.0) + 1.0) or 1.0
  return polarity, count, clamp(0.70 + math.min(count, 4.0) * 0.075, 0.70, 1.0)
end

function M.scoreObservation(session, observation, corner)
  observation = observation or {}
  corner = corner or {}
  local rejected, reason = rejectBadMoment(observation)
  local consistency = driverConsistency(observation)
  local alignment = cueAlignmentConfidence(observation)
  local polarity, consecutive, consecutiveScale = consecutiveEvidence(corner, observation)
  local maxSingleLapDelta = math.max(0.25, finiteNumber(settings.LEARNING_MAX_SINGLE_LAP_DELTA, 1.0))
  local minConsecutiveEvidence = math.max(1.0, finiteNumber(settings.LEARNING_EVIDENCE_MIN_CONSECUTIVE, 2.0))
  if rejected then
    return {
      accepted = false,
      reason = reason,
      rejectBadMoment = true,
      driverConsistency = consistency,
      cueAlignmentConfidence = alignment,
      consecutiveEvidence = consecutive,
      minConsecutiveEvidence = minConsecutiveEvidence,
      maxSingleLapDelta = maxSingleLapDelta,
      adaptationScale = 0.0,
      polarity = polarity,
    }
  end
  local evidenceGateOpen = consecutive >= minConsecutiveEvidence or observation.forceLearn == true or observation.forceSave == true
  local scale = clamp(consistency * 0.45 + alignment * 0.40 + consecutiveScale * 0.15, 0.18, 1.0)
  local accepted = consistency >= 0.22 and alignment >= 0.24 and evidenceGateOpen
  local reason = 'accepted'
  if consistency < 0.22 then
    reason = 'driver_inconsistent'
  elseif alignment < 0.24 then
    reason = 'cue_alignment_low'
  elseif consecutive < minConsecutiveEvidence then
    reason = 'needs_more_consecutive_evidence'
  end
  return {
    accepted = accepted,
    reason = reason,
    rejectBadMoment = false,
    driverConsistency = consistency,
    cueAlignmentConfidence = alignment,
    consecutiveEvidence = consecutive,
    minConsecutiveEvidence = minConsecutiveEvidence,
    maxSingleLapDelta = maxSingleLapDelta,
    adaptationScale = accepted and scale or 0.0,
    polarity = polarity,
  }
end

return M
