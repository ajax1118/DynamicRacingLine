-- DynamicRacingLine line_core/integration_adapter.lua
-- R02 drop-in adapter. Call build(runtime) and render guidance.window.tiles.
-- Pipeline internally calls PathResampler.resample, SurfaceHints, Optimizer.solve, BrakeSolver.solve, TileWindow.prepare, QualityReport.build, TrackProfiles.resolve, SurfaceHazards.fromFrame, and reports learnedApplied.

local Config = require('src.line_core.config')
local LegacyConstants = require('src.line_core.legacy_constants_bridge')
LegacyConstants.apply(_G)
local Pipeline = require('src.line_core.guidance_pipeline')
local Cache = require('src.line_core.guidance_cache')
local CacheManager = require('src.line_core.cache_manager')
local LineState = require('src.line_core.line_state')

local M = {}

function M.invalidateCache()
  Cache.clear()
  LineState.reset()
end

function M.build(ctx)
  ctx = ctx or {}
  local now = ctx.now or os.clock()
  local key = ctx.cacheKey or CacheManager.runtimeKey(ctx)
  local cached = Cache.get(key, now, ctx.cacheMaxAgeS or Config.GUIDANCE_CACHE_MAX_AGE_S)
  if cached then
    cached.cacheHit = true
    return cached
  end
  local guidance = Pipeline.build(ctx)
  Cache.put(key, guidance, now)
  return guidance
end

function M.makeGuidance(runtime)
  return M.build(runtime or {})
end

return M
