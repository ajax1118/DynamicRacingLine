-- DynamicRacingLine line_core/runtime_context.lua
-- Compatibility wrapper. Cache key contains grip= speed= wet= buckets.

local Dynamic = require('src.line_core.dynamic_context')
local Cache = require('src.line_core.cache_manager')
local M = {}
for k, v in pairs(Dynamic) do M[k] = v end

function M.setupHashFromRuntime(ctx)
  ctx = ctx or {}
  local Setup = require('src.line_core.setup_fingerprint')
  return Setup.hash(ctx.setup or {}, ctx.telemetry or ctx.carState or {})
end

function M.cacheKeyFromRuntime(ctx)
  return Cache.runtimeKey(Dynamic.normalize(ctx or {}))
end

function M.cacheKey(ctx) return M.cacheKeyFromRuntime(ctx) end

return M
