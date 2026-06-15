-- DynamicRacingLine line_core/learned_profile.lua
-- Per-corner learned corrections. This is deliberately a refinement layer; baseline line
-- must work without it.

local U = require('src.line_core.math_utils')
local Profiles = require('src.line_core.profile_resolver')

local M = {}

local function nowStamp()
  return os.date and os.date('!%Y-%m-%dT%H:%M:%SZ') or tostring(os.clock())
end

function M.empty(trackId, layoutId, carId, setup)
  local setupHash = type(setup) == 'string' and setup or Profiles.setupHash(setup or {})
  return {
    schema = 1,
    track_id = Profiles.normalizeTrackId(trackId),
    layout_id = Profiles.normalizeLayoutId(layoutId),
    car_id = Profiles.normalizeCarId(carId),
    setup_hash = setupHash,
    confidence = 0,
    observations = 0,
    valid_laps_used = 0,
    rejected_laps = 0,
    corners = {},
    updated_at = nowStamp(),
  }
end

local function corner(profile, cornerId)
  profile.corners = profile.corners or {}
  profile.corners[cornerId] = profile.corners[cornerId] or {
    brake_offset_m = 0,
    brake_pressure_adjustment = 0,
    brake_ramp_adjustment = 0,
    turn_in_offset_m = 0,
    apex_position_offset_m = 0,
    apex_speed_offset_kmh = 0,
    exit_line_offset_m = 0,
    exit_throttle_offset = 0,
    spin_risk = 0,
    lockup_risk = 0,
    entry_instability_risk = 0,
    mid_corner_understeer_risk = 0,
    exit_instability_risk = 0,
    offtrack_risk = 0,
    confidence = 0,
    observations = 0,
    valid_laps_used = 0,
    rejected_laps = 0,
  }
  return profile.corners[cornerId]
end

local function weighted(current, delta, weight, minV, maxV)
  local v = (current or 0) + (delta or 0) * weight
  return U.clamp(v, minV, maxV)
end

local function observationWeight(obs)
  local w = U.clamp(obs.confidence or 0.45, 0.05, 0.9)
  if obs.offtrack then w = w * 0.15 end
  if obs.spin then w = w * 0.12 end
  if obs.majorCorrection then w = w * 0.35 end
  if obs.followedCue == false then w = w * 0.45 end
  if obs.stable == true then w = w * 1.18 end
  return U.clamp(w, 0.02, 0.65)
end

function M.updateCorner(profile, cornerId, obs)
  obs = obs or {}
  local c = corner(profile, cornerId)
  local reject = obs.reject == true

  -- Reject truly bad laps but still keep risk statistics so sparse learning does not stall.
  if obs.offtrack or obs.spin or obs.majorCorrection then
    c.offtrack_risk = weighted(c.offtrack_risk, obs.offtrack and 0.20 or 0.03, 1, 0, 1)
    c.spin_risk = weighted(c.spin_risk, obs.spin and 0.22 or 0.02, 1, 0, 1)
    c.entry_instability_risk = weighted(c.entry_instability_risk, obs.entryInstability and 0.20 or 0.02, 1, 0, 1)
    c.exit_instability_risk = weighted(c.exit_instability_risk, obs.exitInstability and 0.20 or 0.02, 1, 0, 1)
  end

  if reject or (obs.offtrack and obs.followedCue ~= true) then
    c.rejected_laps = (c.rejected_laps or 0) + 1
    profile.rejected_laps = (profile.rejected_laps or 0) + 1
    c.confidence = U.clamp((c.confidence or 0) * 0.96, 0, 1)
    profile.updated_at = nowStamp()
    return c, { accepted = false, reason = 'rejected_unstable_or_offcue_observation' }
  end

  local w = observationWeight(obs)

  -- Brake cue correction in meters. Positive means brake earlier/upstream.
  if obs.overshot or obs.missedApexLate or (obs.offtrack and obs.followedCue == true) then
    c.brake_offset_m = weighted(c.brake_offset_m, 4.0, w, -35, 65)
    c.brake_pressure_adjustment = weighted(c.brake_pressure_adjustment, -0.025, w, -0.28, 0.18)
  elseif obs.tooSlowAtApex and obs.stable then
    c.brake_offset_m = weighted(c.brake_offset_m, -2.2, w, -35, 65)
    c.brake_pressure_adjustment = weighted(c.brake_pressure_adjustment, 0.010, w, -0.28, 0.18)
  end

  if obs.lockup then
    c.lockup_risk = weighted(c.lockup_risk, 0.22, 1, 0, 1)
    c.brake_pressure_adjustment = weighted(c.brake_pressure_adjustment, -0.04, w, -0.28, 0.18)
    c.brake_ramp_adjustment = weighted(c.brake_ramp_adjustment, -0.05, w, -0.35, 0.25)
  end

  -- Racing line corrections. Positive/negative sign should match your existing lateral convention.
  if obs.turnInDeltaM then
    c.turn_in_offset_m = weighted(c.turn_in_offset_m, obs.turnInDeltaM, w * 0.35, -9, 9)
  end
  if obs.apexDeltaM then
    c.apex_position_offset_m = weighted(c.apex_position_offset_m, obs.apexDeltaM, w * 0.35, -8, 8)
  end
  if obs.exitDeltaM then
    c.exit_line_offset_m = weighted(c.exit_line_offset_m, obs.exitDeltaM, w * 0.35, -8, 8)
  end
  if obs.apexSpeedDeltaKmh then
    -- Wider than old tiny bounds so baseline errors can actually be corrected.
    c.apex_speed_offset_kmh = weighted(c.apex_speed_offset_kmh, obs.apexSpeedDeltaKmh, w * 0.28, -35, 22)
  end
  if obs.exitThrottleDelta then
    c.exit_throttle_offset = weighted(c.exit_throttle_offset, obs.exitThrottleDelta, w * 0.25, -0.35, 0.35)
  end

  if obs.understeer then c.mid_corner_understeer_risk = weighted(c.mid_corner_understeer_risk, 0.18, 1, 0, 1) end
  if obs.entryInstability then c.entry_instability_risk = weighted(c.entry_instability_risk, 0.18, 1, 0, 1) end
  if obs.exitInstability then c.exit_instability_risk = weighted(c.exit_instability_risk, 0.18, 1, 0, 1) end

  c.observations = (c.observations or 0) + 1
  c.valid_laps_used = (c.valid_laps_used or 0) + 1
  c.confidence = U.clamp((c.confidence or 0) + 0.035 * w + (obs.stable and 0.018 or 0), 0, 0.92)

  profile.observations = (profile.observations or 0) + 1
  profile.valid_laps_used = (profile.valid_laps_used or 0) + 1
  profile.confidence = U.clamp((profile.confidence or 0) * 0.97 + c.confidence * 0.03, 0, 0.90)
  profile.updated_at = nowStamp()

  return c, { accepted = true, weight = w, reason = 'accepted_per_corner_learning_update' }
end

return M
