-- DynamicRacingLine line_core/surface_hints.lua
-- Optional parser for width/surface/AI/kerb/wall hints. Unknown data stays unknown.

local TrackLimits = require('src.line_core.track_limits')

local M = {}

function M.makeBoundaryProvider(opts)
  return TrackLimits.newProvider(opts or {})
end

function M.surfaceSamples(samples)
  -- Normalizes raw surface samples into a stable array. The surface_hazards module
  -- does risk/grip interpretation; this helper only keeps provider data together.
  local out = {}
  for i, s in ipairs(samples or {}) do
    out[i] = {
      progress = s.progress or s.s or s.distance,
      surface = s.surface or s.surfaceName or s.material or 'unknown_surface',
      grip = s.grip or s.gripFactor or s.surfaceGrip,
      kerb = s.kerb or s.isKerb,
      sausageKerb = s.sausageKerb or s.sausage,
      pitLane = s.pitLane or s.isPitLane,
      wallDistanceLeft = s.wallDistanceLeft or s.wallLeft,
      wallDistanceRight = s.wallDistanceRight or s.wallRight,
      confidence = s.confidence or s.surfaceConfidence,
    }
  end
  return out
end

function M.aiOffsetsFromReference(frame, aiLineSamples)
  return TrackLimits.extractAiOffsets(frame, aiLineSamples)
end

return M
