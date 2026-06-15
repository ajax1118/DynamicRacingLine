-- DynamicRacingLine line_core/config.lua
-- R02 values intentionally relax the old over-strict lateral validator.
-- Previous fixed accel/jerk limits were too low for Monaco/old/narrow/mod tracks
-- and for real left-right transitions.

local U = require('src.line_core.math_utils')

local M = {
  VERSION = 'line-core-fix-r02',

  -- Sampling/window behavior
  TARGET_SAMPLE_SPACING_M = 5.0,
  MIN_SAMPLE_SPACING_M = 2.0,
  MAX_SAMPLE_SPACING_M = 8.0,
  MIN_VISIBLE_TILES = 10,
  MAX_VISIBLE_TILES = 90,
  VISIBLE_LOOKAHEAD_MIN_M = 90,
  VISIBLE_LOOKAHEAD_MAX_M = 360,
  PREP_DISTANCE_BASE_M = 140,
  PREP_DISTANCE_SPEED_GAIN = 2.2, -- m of prep per m/s

  -- Boundary defaults: only used when real boundaries are unavailable.
  DEFAULT_TRACK_HALF_WIDTH_M = 5.25,
  NARROW_TRACK_HALF_WIDTH_M = 3.75,
  MIN_HALF_WIDTH_M = 2.85,
  MAX_HALF_WIDTH_M = 11.5,
  UNKNOWN_BOUNDARY_SAFETY_MARGIN_M = 1.10,
  WALL_RISK_EXTRA_MARGIN_M = 0.65,
  KERB_UNKNOWN_EXTRA_MARGIN_M = 0.35,

  -- Dynamic offset constraints. These replace the old hard fixed limits.
  OFFSET_ACCEL_BASE_M = 0.090,
  OFFSET_ACCEL_MAX_M = 0.280,
  OFFSET_JERK_BASE_M = 0.040,
  OFFSET_JERK_MAX_M = 0.165,
  OFFSET_STEP_BASE_M = 0.68,
  OFFSET_STEP_MAX_M = 2.25,

  -- If validator fails, preserve the useful line and relax/squash progressively.
  VALIDATION_MAX_REPAIR_PASSES = 5,
  VALIDATION_RELAX_PER_PASS = 0.32,
  VALIDATION_AMPLITUDE_DECAY = 0.90,
  CENTERLINE_FALLBACK_AFTER_REPAIR = false,

  -- Projection/recovery. Old fixed 12 m lateral reject caused tile dropouts.
  RECOVERY_BASE_LATERAL_M = 12.0,
  RECOVERY_SPEED_GAIN = 0.11, -- m lateral tolerance per m/s
  RECOVERY_WIDTH_GAIN = 1.65,
  SEAM_WRAP_GUARD_M = 25,

  -- Renderer safety: bumps/depth/road mesh irregularities need more lift.
  LINE_LIFT_M = 0.105,
  QUAD_EXTRA_LIFT_M = 0.035,
  BUMPY_TRACK_EXTRA_LIFT_M = 0.055,
  MIN_RENDER_ALPHA = 0.38,
  READ_ONLY_DEPTH_RECOMMENDED = false,

  -- Corner detection and grouping.
  CURVATURE_SMOOTH_RADIUS = 4,
  CURVATURE_MIN_ABS = 0.0022, -- shallow important corners are now detected.
  CURVATURE_STRONG_ABS = 0.0065,
  CORNER_MIN_LENGTH_M = 18,
  CORNER_MERGE_GAP_M = 22,
  CHICANE_SIGN_CHANGE_KEEP_M = 55,
  KINK_MAX_DIRECTION_CHANGE_DEG = 4.0,

  -- Baseline path generation.
  MAX_BASELINE_OFFSET_RATIO = 0.78,
  ENTRY_OUTSIDE_RATIO = 0.56,
  APEX_INSIDE_RATIO = 0.70,
  EXIT_OUTSIDE_RATIO = 0.62,
  CHICANE_OUTSIDE_RATIO = 0.46,
  STREET_OFFSET_RATIO_SCALE = 0.72,

  -- Brake/speed model. These are safe defaults only; car/setup telemetry overrides them.
  GRAVITY = 9.80665,
  DEFAULT_MU = 1.18,
  DEFAULT_BRAKE_DECEL_MPS2 = 9.2,
  DEFAULT_TRACTION_ACCEL_MPS2 = 4.0,
  DEFAULT_TOP_SPEED_MPS = 95.0,
  LOW_CONFIDENCE_BRAKE_MARGIN_M = 18.0,
  MIN_BRAKE_ZONE_M = 12.0,

  -- Cache refresh and stale-data guards.
  DYNAMIC_CONTEXT_MAX_AGE_S = 0.20,
  GUIDANCE_CACHE_MAX_AGE_S = 0.24,
  SETUP_HASH_BUCKET_FINE = true,

  -- R02: transform/cache/profile guardrails.
  AI_REFERENCE_MAX_WEIGHT = 0.34,
  AI_REFERENCE_MIN_CONFIDENCE = 0.35,
  SEAM_OFFSET_BLEND_M = 42,
  CHICANE_SIGN_CHATTER_MIN_GAP_M = 12,
  NEAR_CAR_BLEND_MIN_CONFIDENCE = 0.46,
  TILE_EMPTY_RECOVERY_LOOKAHEAD_M = 80,
  PROFILE_DEFAULT_WARNING = true,
  SURFACE_UNKNOWN_GRIP_CONFIDENCE = 0.10,
  SURFACE_HAZARD_MAX_RISK = 0.82,
  PIT_ENTRY_WIDTH_PENALTY_M = 0.65,
  JOINT_PATH_EVAL_PASSES = 2,
  JOINT_PATH_CANDIDATE_BAND_M = 0.55,
  JOINT_PATH_CANDIDATE_STEP_M = 0.22,
}

function M.dynamicOffsetStepLimit(ds, speedMps, halfWidth, confidence)
  ds = math.max(0.5, ds or M.TARGET_SAMPLE_SPACING_M)
  speedMps = math.max(0, speedMps or 0)
  halfWidth = math.max(M.MIN_HALF_WIDTH_M, halfWidth or M.DEFAULT_TRACK_HALF_WIDTH_M)
  confidence = U.clamp(confidence or 0.55, 0, 1)

  local spacingGain = U.clamp(ds * 0.18, 0, 0.70)
  local speedGain = U.clamp(speedMps * 0.010, 0, 0.35)
  local widthGain = U.clamp((halfWidth - 4.0) * 0.11, 0, 0.55)
  local confidenceGain = (1.0 - confidence) * 0.16
  return U.clamp(M.OFFSET_STEP_BASE_M + spacingGain + speedGain + widthGain + confidenceGain, 0.35, M.OFFSET_STEP_MAX_M)
end

function M.dynamicOffsetAccelLimit(ds, curvatureAbs, halfWidth, confidence)
  ds = math.max(0.5, ds or M.TARGET_SAMPLE_SPACING_M)
  curvatureAbs = math.abs(curvatureAbs or 0)
  halfWidth = math.max(M.MIN_HALF_WIDTH_M, halfWidth or M.DEFAULT_TRACK_HALF_WIDTH_M)
  confidence = U.clamp(confidence or 0.55, 0, 1)

  local spacingGain = U.clamp((ds - 3.0) * 0.010, 0, 0.050)
  local curveGain = U.clamp(curvatureAbs * 9.0, 0, 0.070)
  local widthGain = U.clamp((halfWidth - 4.0) * 0.012, 0, 0.060)
  local confidenceGain = (1.0 - confidence) * 0.020
  return U.clamp(M.OFFSET_ACCEL_BASE_M + spacingGain + curveGain + widthGain + confidenceGain, M.OFFSET_ACCEL_BASE_M, M.OFFSET_ACCEL_MAX_M)
end

function M.dynamicOffsetJerkLimit(ds, curvatureAbs, halfWidth, confidence)
  ds = math.max(0.5, ds or M.TARGET_SAMPLE_SPACING_M)
  curvatureAbs = math.abs(curvatureAbs or 0)
  halfWidth = math.max(M.MIN_HALF_WIDTH_M, halfWidth or M.DEFAULT_TRACK_HALF_WIDTH_M)
  confidence = U.clamp(confidence or 0.55, 0, 1)

  local spacingGain = U.clamp((ds - 3.0) * 0.006, 0, 0.035)
  local curveGain = U.clamp(curvatureAbs * 5.0, 0, 0.035)
  local widthGain = U.clamp((halfWidth - 4.0) * 0.006, 0, 0.025)
  local confidenceGain = (1.0 - confidence) * 0.016
  return U.clamp(M.OFFSET_JERK_BASE_M + spacingGain + curveGain + widthGain + confidenceGain, M.OFFSET_JERK_BASE_M, M.OFFSET_JERK_MAX_M)
end

function M.dynamicRecoveryLateralLimit(speedMps, halfWidth, confidence)
  speedMps = math.max(0, speedMps or 0)
  halfWidth = math.max(M.MIN_HALF_WIDTH_M, halfWidth or M.DEFAULT_TRACK_HALF_WIDTH_M)
  confidence = U.clamp(confidence or 0.55, 0, 1)
  local bySpeed = speedMps * M.RECOVERY_SPEED_GAIN
  local byWidth = halfWidth * M.RECOVERY_WIDTH_GAIN
  local lowConfidence = (1.0 - confidence) * 4.0
  return math.max(M.RECOVERY_BASE_LATERAL_M, byWidth + bySpeed + lowConfidence)
end

function M.visibleLookahead(speedMps)
  speedMps = math.max(0, speedMps or 0)
  return U.clamp(M.PREP_DISTANCE_BASE_M + speedMps * M.PREP_DISTANCE_SPEED_GAIN, M.VISIBLE_LOOKAHEAD_MIN_M, M.VISIBLE_LOOKAHEAD_MAX_M)
end

return M
