-- DynamicRacingLine line_core/renderer_safety.lua
-- Rendering guardrails for bumpy tracks, depth/occlusion issues, origin shift and stale app state.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')

local M = {}

function M.applyTileLift(tile, opts)
  opts = opts or {}
  if not tile or not tile.world then return tile end
  local extra = Config.QUAD_EXTRA_LIFT_M
  if opts.bumpyTrack or opts.lowRoadMeshConfidence then
    extra = extra + Config.BUMPY_TRACK_EXTRA_LIFT_M
  end
  tile.world = {
    x = U.x(tile.world),
    y = U.y(tile.world) + Config.LINE_LIFT_M + extra,
    z = U.z(tile.world),
  }
  return tile
end

function M.rendererOptions(opts)
  opts = opts or {}
  return {
    lineLiftM = Config.LINE_LIFT_M + (opts.bumpyTrack and Config.BUMPY_TRACK_EXTRA_LIFT_M or 0),
    quadExtraLiftM = Config.QUAD_EXTRA_LIFT_M,
    minAlpha = Config.MIN_RENDER_ALPHA,
    readOnlyDepth = Config.READ_ONLY_DEPTH_RECOMMENDED,
    disableDepthWhenDebugging = true,
    rebuildProfileAfterSettingsChange = true,
    avoidRenderWhenTileCountZero = true,
    staleSettingsWarning = 'If CSP app reload state looks wrong, fully restart AC and Content Manager after replacing DynamicRacingLine.',
  }
end

return M
