-- DynamicRacingLine line_core/lap_validator.lua
-- R02 telemetry-driven validation hooks. This is not a full simulator; it records whether
-- generated cues produced stable corner completion so logs/static tests are not the only proof.

local U = require('src.line_core.math_utils')

local M = {}

local function validSample(s)
  return s and s.progress and s.speedMps and s.position
end

function M.newSession()
  return { corners = {}, laps = {}, rejected = 0, accepted = 0 }
end

function M.scoreCorner(predicted, observed)
  predicted = predicted or {}
  observed = observed or {}
  local score = 1.0
  local reasons = {}

  local function penalize(code, amount)
    score = score - amount
    reasons[#reasons + 1] = code
  end

  if observed.offTrack then penalize('offtrack', 0.50) end
  if observed.spin or observed.largeCorrection then penalize('instability', 0.45) end
  if observed.lockup then penalize('lockup', 0.22) end
  if observed.apexMissM and observed.apexMissM > 2.0 then penalize('apex_miss', U.clamp(observed.apexMissM / 8.0, 0.12, 0.38)) end
  if observed.exitTrackOutMissM and observed.exitTrackOutMissM > 2.5 then penalize('exit_miss', U.clamp(observed.exitTrackOutMissM / 9.0, 0.10, 0.32)) end

  local predBrake = tonumber(predicted.brakeStartProgress)
  local actualBrake = tonumber(observed.brakeStartProgress)
  if predBrake and actualBrake and observed.trackLength then
    local err = math.abs(U.shortProgressDelta(predBrake, actualBrake, observed.trackLength))
    if err > 28 then penalize('brake_timing_error', U.clamp(err / 120.0, 0.08, 0.35)) end
  end

  return { valid = score >= 0.55, score = U.clamp(score, 0, 1), reasons = reasons }
end

function M.recordCorner(session, cornerId, predicted, observed)
  session = session or M.newSession()
  cornerId = tostring(cornerId or 'unknown_corner')
  local score = M.scoreCorner(predicted, observed)
  local c = session.corners[cornerId] or { observations = 0, accepted = 0, rejected = 0, avgScore = 0 }
  c.observations = c.observations + 1
  c.avgScore = c.avgScore + (score.score - c.avgScore) / c.observations
  if score.valid then c.accepted = c.accepted + 1; session.accepted = session.accepted + 1 else c.rejected = c.rejected + 1; session.rejected = session.rejected + 1 end
  c.lastReasons = score.reasons
  session.corners[cornerId] = c
  return score, session
end

function M.summary(session)
  session = session or {}
  local total = (session.accepted or 0) + (session.rejected or 0)
  return {
    total = total,
    accepted = session.accepted or 0,
    rejected = session.rejected or 0,
    acceptanceRate = total > 0 and ((session.accepted or 0) / total) or 0,
    corners = session.corners or {},
  }
end

return M
