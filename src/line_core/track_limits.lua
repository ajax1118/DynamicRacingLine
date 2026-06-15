-- DynamicRacingLine line_core/track_limits.lua
-- Provider adapter for real width/kerb/wall/AI-line data when available.

local U = require('src.line_core.math_utils')
local M = {}

function M.newProvider(opts)
  opts = opts or {}
  local provider = {
    trackLength = opts.trackLength,
    widthSamples = opts.widthSamples or opts.trackLimitSamples or {},
    surfaceSamples = opts.surfaceSamples or {},
    aiLineSamples = opts.aiLineSamples or {},
    wallSamples = opts.wallSamples or {},
    kerbSamples = opts.kerbSamples or {},
  }
  function provider:sample(progress, world)
    local toleranceM = opts.sampleToleranceM or 10
    local width, wd = U.nearestByProgress(self.widthSamples, progress, self.trackLength)
    local ai, ad = U.nearestByProgress(self.aiLineSamples, progress, self.trackLength)
    local kerb, kd = U.nearestByProgress(self.kerbSamples, progress, self.trackLength)
    local wall, wd2 = U.nearestByProgress(self.wallSamples, progress, self.trackLength)
    local left, right, source, confidence
    if width and (wd or 999) < toleranceM then
      left = tonumber(width.leftWidth or width.left or width.widthLeft or width.trackLeft)
      right = tonumber(width.rightWidth or width.right or width.widthRight or width.trackRight)
      source = width.source or 'track_limit_width_samples'
      confidence = tonumber(width.confidence) or 0.82
    end
    if (not left or not right) and ai and (ad or 999) < toleranceM then
      left = tonumber(ai.leftWidth or ai.widthLeft)
      right = tonumber(ai.rightWidth or ai.widthRight)
      source = 'ai_line_width_hint'
      confidence = tonumber(ai.widthConfidence) or 0.55
    end
    if not left or not right then return nil end
    return { left = left, right = right, confidence = confidence, source = source, kerbKnown = kerb ~= nil and (kd or 999) < 8, wallKnown = wall ~= nil and (wd2 or 999) < 12 }
  end
  return provider
end

function M.extractAiOffsets(frame, aiLineSamples)
  if not frame or not frame.samples or not aiLineSamples then return nil end
  local offsets = {}
  local Frame = require('src.line_core.frame')
  for i, s in ipairs(frame.samples) do
    local ai = U.nearestByProgress(aiLineSamples, s.progress, frame.length)
    if ai then
      if ai.offset then offsets[i] = tonumber(ai.offset) else
        local p = ai.world or ai.pos or ai
        local proj = Frame.projectWorld(frame, p, s.progress, 25)
        offsets[i] = proj.ok and proj.lateral or nil
      end
    end
  end
  return offsets
end

return M
