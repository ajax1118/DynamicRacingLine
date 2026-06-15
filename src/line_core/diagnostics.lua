-- DynamicRacingLine line_core/diagnostics.lua
-- Logs default profile use, unknown track limits, and generated baseline status.

local Quality = require('src.line_core.line_quality_monitor')
local QualityReport = require('src.line_core.quality_report')
local M = {}
function M.collect(guidance, ctx)
  if type(guidance) ~= 'table' then
    local q = QualityReport.build(nil)
    q.runtime = Quality.evaluate(nil)
    q.defaultTrackProfile = ctx and ctx.usedDefaultTrackProfile
    q.defaultCarProfile = ctx and ctx.usedDefaultCarProfile
    q.defaultProfilePenalty = ((ctx and ctx.usedDefaultTrackProfile) and 0.10 or 0.0) +
      ((ctx and ctx.usedDefaultCarProfile) and 0.08 or 0.0)
    q.dataTruth = {}
    q.unknownTrackLimits = true
    q.unknownSurfaceMap = true
    q.invalidGuidance = true
    return q
  end
  local q = QualityReport.build(guidance)
  q.runtime = Quality.evaluate(guidance)
  q.defaultTrackProfile = ctx and ctx.usedDefaultTrackProfile
  q.defaultCarProfile = ctx and ctx.usedDefaultCarProfile
  q.defaultProfilePenalty = ((ctx and ctx.usedDefaultTrackProfile) and 0.10 or 0.0) +
    ((ctx and ctx.usedDefaultCarProfile) and 0.08 or 0.0)
  q.dataTruth = guidance and guidance.diagnostics and guidance.diagnostics.dataTruth or {}
  q.unknownTrackLimits = not (q.dataTruth and q.dataTruth.trackLimitsKnown == true)
  q.unknownSurfaceMap = not (q.dataTruth and q.dataTruth.surfaceMapKnown == true)
  return q
end
function M.toLogLine(diag) return '[DRL] ' .. QualityReport.format(diag or {}) end
return M
