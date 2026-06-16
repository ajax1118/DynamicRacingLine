-- DynamicRacingLine line_core/optimizer.lua
-- Unified baseline racing-line optimizer. It does not run separate minimum-curvature
-- and lap-time passes that fight each other; the same cost/constraints produce the line.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local Boundaries = require('src.line_core.boundaries')
local Validator = require('src.line_core.validator')
local SurfaceHazards = require('src.line_core.surface_hazards')
local PathEvaluator = require('src.line_core.path_evaluator')
local SeamGuard = require('src.line_core.seam_guard')

local M = {}

local function wrappedIndex(i, n)
  while i < 1 do i = i + n end
  while i > n do i = i - n end
  return i
end

local function applyOffset(offsets, n, index, value, weight, boundary)
  index = wrappedIndex(index, n)
  local previous = offsets[index] or 0
  local nextValue = previous * (1 - weight) + value * weight
  offsets[index] = Boundaries.clampOffset(boundary, index, nextValue)
end

local function signedUsable(boundary, index, sign, ratio)
  local b = Boundaries.at(boundary, index)
  local width = sign >= 0 and b.usableLeft or b.usableRight
  return sign * width * ratio
end

local function cornerIndexSpan(corner, n)
  local indices = {}
  local i = corner.startIndex
  local guard = 0
  while true do
    indices[#indices + 1] = i
    if i == corner.endIndex then break end
    i = (i % n) + 1
    guard = guard + 1
    if guard > n then break end
  end
  return indices
end

local function influenceAcrossCorner(offsets, boundary, corner, n, opts)
  local indices = cornerIndexSpan(corner, n)
  local count = #indices
  if count < 3 then return end

  local sign = corner.sign
  if sign == 0 then
    -- Chicane/esses: use local curvature sign per sample when available.
    sign = U.sign(opts.curvatures and opts.curvatures[corner.apexIndex] or 0)
    if sign == 0 then sign = 1 end
  end

  local narrowScale = (opts.narrow or false) and Config.STREET_OFFSET_RATIO_SCALE or 1.0
  local entryOutsideRatio = Config.ENTRY_OUTSIDE_RATIO * narrowScale
  local apexInsideRatio = Config.APEX_INSIDE_RATIO * narrowScale
  local exitOutsideRatio = Config.EXIT_OUTSIDE_RATIO * narrowScale

  if corner.kind == 'chicane_or_esses' then
    entryOutsideRatio = Config.CHICANE_OUTSIDE_RATIO * narrowScale
    apexInsideRatio = Config.APEX_INSIDE_RATIO * 0.86 * narrowScale
    exitOutsideRatio = Config.CHICANE_OUTSIDE_RATIO * narrowScale
  elseif corner.kind == 'fast_sweeper' then
    apexInsideRatio = Config.APEX_INSIDE_RATIO * 0.70 * narrowScale
    entryOutsideRatio = Config.ENTRY_OUTSIDE_RATIO * 0.72 * narrowScale
    exitOutsideRatio = Config.EXIT_OUTSIDE_RATIO * 0.72 * narrowScale
  elseif corner.kind == 'slow_hairpin_or_tight' then
    apexInsideRatio = Config.APEX_INSIDE_RATIO * 0.96 * narrowScale
    exitOutsideRatio = Config.EXIT_OUTSIDE_RATIO * 0.92 * narrowScale
  end

  for localIndex = 1, count do
    local idx = indices[localIndex]
    local t = (localIndex - 1) / math.max(1, count - 1)
    local desired

    if t < 0.32 then
      -- Outside entry: opposite side of corner.
      local w = U.smootherstep(t / 0.32)
      local outside = signedUsable(boundary, idx, -sign, entryOutsideRatio)
      local inside = signedUsable(boundary, idx, sign, apexInsideRatio * 0.25)
      desired = U.lerp(outside, inside, w)
    elseif t < 0.62 then
      -- Apex zone: move inside, but not necessarily to kerb if kerbs unknown.
      local w = U.smootherstep((t - 0.32) / 0.30)
      local pre = signedUsable(boundary, idx, sign, apexInsideRatio * 0.35)
      local apex = signedUsable(boundary, idx, sign, apexInsideRatio)
      desired = U.lerp(pre, apex, w)
    else
      -- Exit: track out opposite side unless next opposite corner is close.
      local w = U.smootherstep((t - 0.62) / 0.38)
      local apex = signedUsable(boundary, idx, sign, apexInsideRatio * 0.84)
      local outside = signedUsable(boundary, idx, -sign, exitOutsideRatio)
      desired = U.lerp(apex, outside, w)
    end

    -- Stronger confidence/curvature allows more movement; weak track width data keeps it safer.
    local b = Boundaries.at(boundary, idx)
    local confidenceWeight = U.clamp((b.confidence or 0.4) * 0.75 + (corner.confidence or 0.5) * 0.35, 0.22, 0.92)
    local curveWeight = U.clamp((corner.absCurvature or 0) / Config.CURVATURE_STRONG_ABS, 0.25, 1.0)
    local weight = U.clamp(confidenceWeight * curveWeight, 0.16, 0.90)
    applyOffset(offsets, n, idx, desired, weight, boundary)
  end
end

local function blendOpposingCorners(offsets, corners, boundary, n, curvatures)
  -- Prevent sign chatter from creating impossible left-right-left jitter while preserving
  -- real chicane transitions. This is not a center deadband: it only softens noise.
  for i = 2, n - 1 do
    local s1 = U.sign(offsets[i - 1] or 0)
    local s2 = U.sign(offsets[i] or 0)
    local s3 = U.sign(offsets[i + 1] or 0)
    local k = math.abs(curvatures and curvatures[i] or 0)
    if s1 ~= 0 and s3 ~= 0 and s1 == s3 and s2 ~= s1 and math.abs(offsets[i] or 0) < 0.45 and k < Config.CURVATURE_STRONG_ABS then
      offsets[i] = Boundaries.clampOffset(boundary, i, (offsets[i - 1] + offsets[i + 1]) * 0.5)
    end
  end
end

local function applyAiReference(offsets, aiOffsets, boundary, opts)
  if not aiOffsets then return offsets end
  local n = #offsets
  local weight = U.clamp(opts.aiReferenceWeight or 0.18, 0, 0.42)
  for i = 1, n do
    local ai = aiOffsets[i]
    if ai ~= nil then
      local b = Boundaries.at(boundary, i)
      -- Real AI line is a reference, not an unquestioned answer.
      local w = weight * U.clamp((b.confidence or 0.4) + 0.15, 0.15, 0.85)
      offsets[i] = Boundaries.clampOffset(boundary, i, U.lerp(offsets[i] or 0, ai, w))
    end
  end
  return offsets
end

function M.solve(frame, boundary, corners, opts)
  opts = opts or {}
  local samples = frame.samples or {}
  local n = #samples
  local offsets = {}
  local diagnostics = { stages = {}, warnings = {} }
  if n < 3 then
    return {
      ok = false,
      reason = 'not_enough_frame_samples',
      offsets = offsets,
      diagnostics = diagnostics,
    }
  end

  for i = 1, n do offsets[i] = 0 end

  -- Unified path generation: corner geometry, boundary risk, AI reference and dynamic
  -- constraints are applied before validation. There is no later pass that invalidates it.
  for _, c in ipairs(corners or {}) do
    influenceAcrossCorner(offsets, boundary, c, n, {
      curvatures = opts.curvatures,
      narrow = boundary and boundary.narrow,
    })
  end
  diagnostics.stages[#diagnostics.stages + 1] = 'corner_geometry_offsets'

  offsets = applyAiReference(offsets, opts.aiOffsets, boundary, opts)
  diagnostics.stages[#diagnostics.stages + 1] = 'ai_reference_blend'

  blendOpposingCorners(offsets, corners, boundary, n, opts.curvatures)
  diagnostics.stages[#diagnostics.stages + 1] = 'sign_chatter_guard'

  -- Keep within dynamic search band based on actual or estimated width.
  for i = 1, n do
    local maxAbs = Boundaries.maxUsableAbs(boundary, i) * Config.MAX_BASELINE_OFFSET_RATIO
    offsets[i] = U.clamp(offsets[i] or 0, -maxAbs, maxAbs)
    offsets[i] = Boundaries.clampOffset(boundary, i, offsets[i])
  end
  diagnostics.stages[#diagnostics.stages + 1] = 'dynamic_offset_band'

  offsets, diagnostics.jointPathEval = PathEvaluator.refine(frame, boundary, offsets, {
    curvatures = opts.curvatures,
    car = opts.car,
    confidence = opts.confidence or (boundary and boundary.confidence) or 0.55,
    surfaceMap = opts.surfaceMap or opts.hazards,
    aiOffsets = opts.aiOffsets,
  })
  diagnostics.stages[#diagnostics.stages + 1] = 'joint_path_brake_laptime_refine'

  if opts.surfaceMap or opts.hazards then
    local repairedOffsets, hazardRepairs = SurfaceHazards.repairOffsets(boundary, offsets, opts.surfaceMap or opts.hazards, {
      maxRisk = Config.SURFACE_HAZARD_MAX_RISK,
      frame = frame,
      curvatures = opts.curvatures,
      speedMps = opts.speedMps or 0,
      confidence = opts.confidence or (boundary and boundary.confidence) or 0.55,
    })
    offsets = repairedOffsets
    diagnostics.surfaceHazardRepairs = hazardRepairs
    diagnostics.stages[#diagnostics.stages + 1] = 'surface_hazard_repair'
  end

  offsets, diagnostics.seamGuard = SeamGuard.repairOffsetSeam(offsets, frame, boundary)
  offsets, diagnostics.signChatterGuard2 = SeamGuard.guardSignChatter(offsets, opts.curvatures, { spacing = frame.spacing })
  diagnostics.stages[#diagnostics.stages + 1] = 'seam_and_chicane_guard'

  local repaired, validation = Validator.repair(offsets, frame, boundary, {
    curvatures = opts.curvatures,
    speedMps = opts.speedMps or 0,
    confidence = opts.confidence or (boundary and boundary.confidence) or 0.55,
    allowCenterlineFallback = false,
  })
  offsets = repaired
  diagnostics.validation = validation
  diagnostics.stages[#diagnostics.stages + 1] = 'adaptive_validation_repair'

  local path = require('src.line_core.frame').buildPathPoints(frame, offsets)
  local confidence = U.clamp(((boundary and boundary.confidence) or 0.35) * 0.45 + 0.35 + ((validation and validation.ok) and 0.15 or 0.04), 0.15, 0.88)
  if validation and not validation.ok then
    diagnostics.warnings[#diagnostics.warnings + 1] = 'line_kept_after_repair_with_validation_warnings'
    confidence = math.min(confidence, 0.58)
  end

  return {
    ok = true,
    reason = 'generated_predictive_baseline',
    offsets = offsets,
    path = path,
    confidence = confidence,
    diagnostics = diagnostics,
  }
end

return M
