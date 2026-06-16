-- DynamicRacingLine line_core/guidance_pipeline.lua
-- Single guidance pipeline: transform -> boundaries -> optimizer -> brake -> throttle -> tile -> visibility.
-- Learned behavior is refinement, not foundation.

local U = require('src.line_core.math_utils')
local Frame = require('src.line_core.frame')
local PathResampler = require('src.line_core.path_resampler')
local Boundaries = require('src.line_core.boundaries')
local CornerDetector = require('src.line_core.corner_detector')
local Optimizer = require('src.line_core.optimizer')
local BrakeSolver = require('src.line_core.brake_solver')
local ThrottleSolver = require('src.line_core.throttle_solver')
local TileWindow = require('src.line_core.tile_window')
local Visibility = require('src.line_core.visibility_guard')
local TrackIngest = require('src.line_core.track_data_ingest')
local DynamicContext = require('src.line_core.dynamic_context')
local RiskMap = require('src.line_core.risk_map')
local LineState = require('src.line_core.line_state')
local Diagnostics = require('src.line_core.diagnostics')

local M = {}

local function indicesForCorner(c, n)
  local out, i, guard = {}, c.startIndex, 0
  while i do
    out[#out + 1] = i
    if i == c.endIndex then break end
    i = (i % n) + 1
    guard = guard + 1
    if guard > n then break end
  end
  return out
end

function M.applyLearnedLateral(offsets, learned, corners, boundary)
  if not learned or not learned.corners then return offsets, 0 end
  local Bound = require('src.line_core.boundaries')
  local n, applied = #offsets, 0
  for _, c in ipairs(corners or {}) do
    local lc = learned.corners[c.id]
    if lc and (lc.confidence or 0) > 0.25 then
      for localIndex, idx in ipairs(indicesForCorner(c, n)) do
        local t = (localIndex - 1) / math.max(1, #indicesForCorner(c, n) - 1)
        local delta = t < 0.4 and (lc.turn_in_offset_m or 0) or (t < 0.7 and (lc.apex_position_offset_m or 0) or (lc.exit_line_offset_m or 0))
        offsets[idx] = Bound.clampOffset(boundary, idx, U.lerp(offsets[idx] or 0, (offsets[idx] or 0) + delta, (lc.confidence or 0) * 0.28))
        applied = applied + 1
      end
    end
  end
  return offsets, applied
end

function M.applyLearnedBrake(points, learned, corners)
  if not learned or not learned.corners then return points, 0 end
  local n, applied = #points, 0
  for _, c in ipairs(corners or {}) do
    local lc = learned.corners[c.id]
    if lc and (lc.confidence or 0) > 0.25 then
      for _, idx in ipairs(indicesForCorner(c, n)) do
        points[idx].brakeOffsetM = lc.brake_offset_m or 0
        points[idx].targetSpeedMps = points[idx].targetSpeedMps and math.max(3, points[idx].targetSpeedMps + (lc.apex_speed_offset_kmh or 0) / 3.6) or nil
        applied = applied + 1
      end
    end
  end
  return points, applied
end

function M.build(runtime)
  local ctx = TrackIngest.mergeRuntimeReference(DynamicContext.withFineSetup(runtime or {}))
  local raw = PathResampler.resample(ctx.centerlineSamples or ctx.trackSamples or ctx.samples or {}, { spacing = ctx.sampleSpacingM })
  local frame = Frame.prepare(raw, { trackLength = ctx.trackLength, source = ctx.centerlineSource or 'runtime_samples', sourceConfidence = ctx.centerlineConfidence or 0.55 })
  if not frame.ok then return { ok = false, reason = frame.reason, frame = frame, window = { ok = false, tiles = {}, tileCount = 0 } } end

  local boundaryProvider = TrackIngest.boundaryProviderFromLimits(ctx, frame)
  local boundary = Boundaries.new(frame, { trackId = ctx.trackId, layoutId = ctx.layoutId, boundaryProvider = boundaryProvider, kerbMapKnown = ctx.kerbMapKnown, wallMapKnown = ctx.wallMapKnown })
  local surfaceMap = RiskMap.build(frame, { surfaceSamples = ctx.surfaceSamples })
  local referenceBrakeSpeedHints = TrackIngest.referenceBrakeSpeedHints(frame, ctx)
  local referenceBrakeSpeedHintSummary = referenceBrakeSpeedHints and {
    source = referenceBrakeSpeedHints.source,
    geometryOnly = referenceBrakeSpeedHints.geometryOnly == true,
    confidence = referenceBrakeSpeedHints.confidence or 0,
    referenceQuality = referenceBrakeSpeedHints.referenceQuality,
    rejectedAiReferenceQuality = referenceBrakeSpeedHints.rejectedAiReferenceQuality,
    rejectedTrackSplineReferenceQuality = referenceBrakeSpeedHints.rejectedTrackSplineReferenceQuality,
    curvatureSamples = #(referenceBrakeSpeedHints.referenceCurvatureByIndex or {}),
    speedCapSamples = #(referenceBrakeSpeedHints.referenceSpeedCapMpsByIndex or {}),
    hintScaleSamples = #(referenceBrakeSpeedHints.referenceHintScaleByIndex or {}),
    riskSamples = #(referenceBrakeSpeedHints.referenceRiskByIndex or {}),
  } or nil
  boundary = RiskMap.applyToBoundary(boundary, surfaceMap)
  local dataTruth = {
    boundary = Boundaries.debugSummary(boundary),
    surface = RiskMap.debugSummary(surfaceMap),
    trackLimitsKnown = ctx.trackLimitsKnown == true or boundaryProvider ~= nil,
    surfaceMapKnown = ctx.surfaceMapKnown == true or (surfaceMap and (surfaceMap.confidence or 0) > 0.45),
      kerbMapKnown = ctx.kerbMapKnown == true,
      wallMapKnown = ctx.wallMapKnown == true,
      trackFileReference = ctx.trackFileReference,
      referenceBrakeSpeedHints = referenceBrakeSpeedHintSummary,
      providerState = ctx.dataProviderState,
  }
  local corners, curvatures = CornerDetector.detect(frame, ctx.cornerOptions or {})
  local carModel = DynamicContext.estimateCarPhysics(ctx)

  local solved = Optimizer.solve(frame, boundary, corners, {
    curvatures = curvatures,
    aiOffsets = TrackIngest.projectReferenceOffsets(frame, ctx),
    confidence = boundary.confidence,
    speedMps = ctx.carState and ctx.carState.speedMps or 0,
    car = carModel,
    surfaceMap = surfaceMap,
  })

  local learnedLateral = 0
  if solved.ok and ctx.learnedProfile then
    solved.offsets, learnedLateral = M.applyLearnedLateral(solved.offsets, ctx.learnedProfile, corners, boundary)
    solved.path = Frame.buildPathPoints(frame, solved.offsets)
  end

  local brake = BrakeSolver.solve(solved.path or {}, frame, {
    car = carModel,
    setup = ctx.setup,
    telemetry = ctx.telemetry or ctx.carState or ctx,
    surfaceMap = surfaceMap,
    referenceBrakeSpeedHints = referenceBrakeSpeedHints,
    confidence = solved.confidence or boundary.confidence,
  })
  brake.points = ThrottleSolver.apply(brake.points or {}, frame, { car = carModel, confidence = brake.confidence })
  local learnedBrake = 0
  brake.points, learnedBrake = M.applyLearnedBrake(brake.points or {}, ctx.learnedProfile, corners)
  local window = TileWindow.prepare(frame, brake.points or {}, ctx.carState or ctx.telemetry or {}, {
    confidence = brake.confidence or solved.confidence,
    maxStaleReuseS = ctx.maxStaleReuseS,
  })
  local out = {
    ok = solved.ok and brake.ok and window.ok,
    reason = 'generated_predictive_baseline',
    frame = frame, boundary = boundary, surfaceMap = surfaceMap, corners = corners,
    offsets = solved.offsets, path = solved.path, brake = brake, points = brake.points, window = window,
    confidence = U.clamp((brake.confidence or 0.4) * 0.55 + (solved.confidence or 0.4) * 0.45, 0.12, 0.90),
    diagnostics = {
      learnedLateral = learnedLateral,
      learnedBrake = learnedBrake,
      dataTruth = dataTruth,
      sourceOrder = 'telemetry > AC physics/setup > generated predictive baseline > learned profile > curated profile > class heuristic > generic fallback',
    },
  }
  out = Visibility.apply(out)
  out.diagnostics.summary = Diagnostics.collect(out, ctx)
  return LineState.accept(out)
end

return M
