-- DynamicRacingLine line_core/boundaries.lua
-- Explicit boundary-confidence layer. When real track limits are unavailable, do not pretend
-- they are known; shrink usable width and raise risk instead of generating impossible offsets.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')

local M = {}

local function looksStreetOrNarrow(trackId)
  local id = tostring(trackId or ''):lower()
  return id:find('monaco', 1, true)
    or id:find('cote', 1, true)
    or id:find('long_beach', 1, true)
    or id:find('macau', 1, true)
    or id:find('pau', 1, true)
    or id:find('baku', 1, true)
    or id:find('norisring', 1, true)
    or id:find('street', 1, true)
end

local function readWidthFromSample(s)
  local l = tonumber(s.leftWidth or s.left_width or s.widthLeft or s.trackLeft)
  local r = tonumber(s.rightWidth or s.right_width or s.widthRight or s.trackRight)
  if l and r then return l, r, 'sample_width', tonumber(s.confidence) or 0.62 end
  local hw = tonumber(s.halfWidth or s.half_width or s.width)
  if hw then return hw, hw, 'sample_half_width', tonumber(s.confidence) or 0.55 end
  return nil, nil, nil, nil
end

function M.new(frame, opts)
  opts = opts or {}
  local trackId = opts.trackId or opts.track_id or 'unknown'
  local narrow = opts.forceNarrow or looksStreetOrNarrow(trackId)
  local defaultHalfWidth = narrow and Config.NARROW_TRACK_HALF_WIDTH_M or Config.DEFAULT_TRACK_HALF_WIDTH_M
  local samples = {}
  local frameSamples = frame and frame.samples or {}

  for i = 1, #frameSamples do
    local fs = frameSamples[i]
    local left, right, source, confidence = readWidthFromSample(fs)

    if opts.boundaryProvider and opts.boundaryProvider.sample then
      local b = opts.boundaryProvider:sample(fs.progress, fs.world)
      if b then
        left = tonumber(b.left) or left
        right = tonumber(b.right) or right
        source = b.source or source or 'boundary_provider'
        confidence = tonumber(b.confidence) or confidence or 0.78
      end
    end

    if not left or not right then
      left = defaultHalfWidth
      right = defaultHalfWidth
      source = narrow and 'narrow_unknown_default' or 'unknown_default'
      confidence = narrow and 0.36 or 0.32
    end

    left = U.clamp(left, Config.MIN_HALF_WIDTH_M, Config.MAX_HALF_WIDTH_M)
    right = U.clamp(right, Config.MIN_HALF_WIDTH_M, Config.MAX_HALF_WIDTH_M)
    confidence = U.clamp(confidence or 0.35, 0, 1)

    local margin = opts.marginM or Config.UNKNOWN_BOUNDARY_SAFETY_MARGIN_M
    local kerbKnown = opts.kerbMapKnown == true or fs.kerbKnown == true
    local wallKnown = opts.wallMapKnown == true or fs.wallKnown == true

    -- Unknown kerbs/walls should shrink usable road, not allow guessed kerb abuse.
    if not kerbKnown then margin = margin + Config.KERB_UNKNOWN_EXTRA_MARGIN_M end
    if narrow and not wallKnown then margin = margin + Config.WALL_RISK_EXTRA_MARGIN_M end

    samples[i] = {
      progress = fs.progress,
      left = left,
      right = right,
      usableLeft = math.max(0.15, left - margin),
      usableRight = math.max(0.15, right - margin),
      confidence = confidence,
      source = source,
      narrow = narrow,
      kerbKnown = kerbKnown,
      wallKnown = wallKnown,
      margin = margin,
    }
  end

  return {
    samples = samples,
    trackId = trackId,
    narrow = narrow,
    source = 'boundary_model',
    confidence = M.averageConfidence(samples),
  }
end

function M.averageConfidence(samples)
  local sum, count = 0, 0
  for i = 1, #(samples or {}) do
    sum = sum + (samples[i].confidence or 0)
    count = count + 1
  end
  return count > 0 and sum / count or 0
end

function M.at(boundary, index)
  local samples = boundary and boundary.samples or {}
  local n = #samples
  if n == 0 then
    return {
      left = Config.DEFAULT_TRACK_HALF_WIDTH_M,
      right = Config.DEFAULT_TRACK_HALF_WIDTH_M,
      usableLeft = Config.DEFAULT_TRACK_HALF_WIDTH_M - Config.UNKNOWN_BOUNDARY_SAFETY_MARGIN_M,
      usableRight = Config.DEFAULT_TRACK_HALF_WIDTH_M - Config.UNKNOWN_BOUNDARY_SAFETY_MARGIN_M,
      confidence = 0.25,
      source = 'no_boundary',
    }
  end
  while index < 1 do index = index + n end
  while index > n do index = index - n end
  return samples[index]
end

function M.clampOffset(boundary, index, offset)
  local b = M.at(boundary, index)
  -- Positive offset is left of centerline; negative is right.
  return U.clamp(offset or 0, -b.usableRight, b.usableLeft)
end

function M.maxUsableAbs(boundary, index)
  local b = M.at(boundary, index)
  return math.max(0.15, math.min(b.usableLeft, b.usableRight))
end

function M.riskForOffset(boundary, index, offset)
  local b = M.at(boundary, index)
  local usable = offset >= 0 and b.usableLeft or b.usableRight
  local absOffset = math.abs(offset or 0)
  if usable <= 0.01 then return 1 end
  local ratio = absOffset / usable
  local risk = U.clamp((ratio - 0.72) / 0.28, 0, 1)
  if b.confidence < 0.45 then risk = U.clamp(risk + 0.20, 0, 1) end
  if b.narrow and not b.wallKnown then risk = U.clamp(risk + 0.18, 0, 1) end
  return risk
end

function M.debugSummary(boundary)
  local samples = boundary and boundary.samples or {}
  local minL, minR, maxL, maxR = math.huge, math.huge, 0, 0
  local sourceCounts = {}
  for i = 1, #samples do
    local b = samples[i]
    minL = math.min(minL, b.usableLeft or 0)
    minR = math.min(minR, b.usableRight or 0)
    maxL = math.max(maxL, b.usableLeft or 0)
    maxR = math.max(maxR, b.usableRight or 0)
    sourceCounts[b.source or 'unknown'] = (sourceCounts[b.source or 'unknown'] or 0) + 1
  end
  return {
    confidence = boundary and boundary.confidence or 0,
    narrow = boundary and boundary.narrow or false,
    minUsableLeft = minL == math.huge and 0 or minL,
    minUsableRight = minR == math.huge and 0 or minR,
    maxUsableLeft = maxL,
    maxUsableRight = maxR,
    sourceCounts = sourceCounts,
  }
end

return M
