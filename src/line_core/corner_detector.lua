-- DynamicRacingLine line_core/corner_detector.lua
-- Smoother curvature and hysteresis grouping for shallow corners, chicanes, kinks,
-- Monaco/old/narrow layouts, and noisy mod splines.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')

local M = {}

local function signedHeadingDelta(a, b)
  local dot = U.clamp(U.dot2(a, b), -1, 1)
  local crossY = a.x * b.z - a.z * b.x
  local angle = math.atan2 and math.atan2(crossY, dot) or math.atan(crossY, dot)
  return angle
end

function M.computeCurvature(frame)
  local samples = frame.samples or {}
  local n = #samples
  local raw, smooth = {}, {}
  if n < 3 then return raw, smooth end

  for i = 1, n do
    local prev = samples[i - 1] or samples[n]
    local curr = samples[i]
    local next = samples[i + 1] or samples[1]
    local t1 = U.norm2(U.sub(curr.world, prev.world))
    local t2 = U.norm2(U.sub(next.world, curr.world))
    local ds = math.max(0.75, (U.distance2(prev.world, curr.world) + U.distance2(curr.world, next.world)) * 0.5)
    raw[i] = signedHeadingDelta(t1, t2) / ds
  end

  local radius = Config.CURVATURE_SMOOTH_RADIUS
  for i = 1, n do
    -- Median suppresses one-sample spline spikes, moving average preserves shallow bends.
    local med = U.median3(raw[i - 1] or raw[n], raw[i], raw[i + 1] or raw[1])
    local avg = U.average(raw, radius, i)
    smooth[i] = med * 0.45 + avg * 0.55
  end

  return raw, smooth
end

local function progressDistance(frame, aIndex, bIndex)
  local samples = frame.samples
  local a = samples[aIndex]
  local b = samples[bIndex]
  if not a or not b then return 0 end
  local d = b.progress - a.progress
  if d < 0 then d = d + frame.length end
  return d
end

local function classifyCorner(lengthM, absK, signChanges)
  if signChanges and signChanges > 0 then return 'chicane_or_esses' end
  if lengthM < 35 and absK > Config.CURVATURE_STRONG_ABS then return 'slow_hairpin_or_tight' end
  if absK > Config.CURVATURE_STRONG_ABS then return 'medium_or_tight' end
  if lengthM > 85 and absK < Config.CURVATURE_STRONG_ABS then return 'fast_sweeper' end
  return 'standard'
end

function M.detect(frame, opts)
  opts = opts or {}
  local raw, curvature = M.computeCurvature(frame)
  local samples = frame.samples or {}
  local n = #samples
  local corners = {}
  if n < 6 then return corners, curvature, raw end

  local minAbs = opts.minAbsCurvature or Config.CURVATURE_MIN_ABS
  local strongAbs = opts.strongAbsCurvature or Config.CURVATURE_STRONG_ABS
  local active = false
  local startIndex, lastActive, dominantSign = nil, nil, 0
  local signChanges = 0
  local lastSign = 0

  local function finishCorner(endIndex)
    if not startIndex then return end
    local lengthM = progressDistance(frame, startIndex, endIndex)
    if lengthM < Config.CORNER_MIN_LENGTH_M then
      active, startIndex, lastActive, dominantSign, signChanges, lastSign = false, nil, nil, 0, 0, 0
      return
    end

    local apexIndex = startIndex
    local maxAbs = 0
    local signedSum = 0
    local count = 0
    local i = startIndex
    while true do
      local k = curvature[i] or 0
      local ak = math.abs(k)
      if ak > maxAbs then maxAbs = ak; apexIndex = i end
      signedSum = signedSum + k
      count = count + 1
      if i == endIndex then break end
      i = (i % n) + 1
      if count > n then break end
    end

    local finalSign = U.sign(signedSum)
    if finalSign == 0 then finalSign = dominantSign end
    local degrees = math.abs(signedSum) * (frame.spacing or Config.TARGET_SAMPLE_SPACING_M) * 57.2958

    -- Suppress tiny kinks unless they are part of a signed transition/chicane.
    if degrees < Config.KINK_MAX_DIRECTION_CHANGE_DEG and signChanges == 0 then
      active, startIndex, lastActive, dominantSign, signChanges, lastSign = false, nil, nil, 0, 0, 0
      return
    end

    corners[#corners + 1] = {
      id = string.format('c%03d', #corners + 1),
      startIndex = startIndex,
      apexIndex = apexIndex,
      endIndex = endIndex,
      startProgress = samples[startIndex].progress,
      apexProgress = samples[apexIndex].progress,
      endProgress = samples[endIndex].progress,
      sign = finalSign,
      absCurvature = maxAbs,
      lengthM = lengthM,
      directionChangeDeg = degrees,
      signChanges = signChanges,
      kind = classifyCorner(lengthM, maxAbs, signChanges),
      confidence = U.clamp(0.45 + maxAbs * 38 + math.min(0.25, lengthM / 350), 0.15, 0.92),
    }

    active, startIndex, lastActive, dominantSign, signChanges, lastSign = false, nil, nil, 0, 0, 0
  end

  for i = 1, n do
    local k = curvature[i] or 0
    local ak = math.abs(k)
    local s = U.sign(k)
    local enter = ak >= minAbs or (active and ak >= minAbs * 0.55)
    local strong = ak >= strongAbs

    if enter then
      if not active then
        active = true
        startIndex = math.max(1, i - 2)
        dominantSign = s
        signChanges = 0
        lastSign = s
      else
        if s ~= 0 and lastSign ~= 0 and s ~= lastSign then
          local sinceStart = progressDistance(frame, startIndex, i)
          if sinceStart <= Config.CHICANE_SIGN_CHANGE_KEEP_M then
            signChanges = signChanges + 1
          else
            -- Separate corner, but keep a small gap so chicanes do not flatten.
            finishCorner(math.max(1, i - 2))
            active = true
            startIndex = math.max(1, i - 2)
            signChanges = 0
          end
        end
        if strong then dominantSign = s end
        if s ~= 0 then lastSign = s end
      end
      lastActive = i
    elseif active and lastActive then
      local gapM = progressDistance(frame, lastActive, i)
      if gapM > Config.CORNER_MERGE_GAP_M then
        finishCorner(lastActive)
      end
    end
  end

  if active and lastActive then finishCorner(lastActive) end

  -- Merge pieces split by noisy one-sample threshold drop, but do not merge opposite-direction
  -- separate corners unless they are an intentional short chicane.
  local merged = {}
  local i = 1
  while i <= #corners do
    local c = corners[i]
    local nextC = corners[i + 1]
    if nextC then
      local gap = nextC.startProgress - c.endProgress
      if gap < 0 then gap = gap + frame.length end
      local sameSign = c.sign == nextC.sign
      local chicaneGap = gap <= Config.CHICANE_SIGN_CHANGE_KEEP_M and c.sign ~= nextC.sign
      if gap <= Config.CORNER_MERGE_GAP_M and (sameSign or chicaneGap) then
        local combined = {
          id = string.format('c%03d', #merged + 1),
          startIndex = c.startIndex,
          apexIndex = (c.absCurvature >= nextC.absCurvature) and c.apexIndex or nextC.apexIndex,
          endIndex = nextC.endIndex,
          startProgress = c.startProgress,
          apexProgress = (c.absCurvature >= nextC.absCurvature) and c.apexProgress or nextC.apexProgress,
          endProgress = nextC.endProgress,
          sign = sameSign and c.sign or 0,
          absCurvature = math.max(c.absCurvature, nextC.absCurvature),
          lengthM = c.lengthM + gap + nextC.lengthM,
          directionChangeDeg = c.directionChangeDeg + nextC.directionChangeDeg,
          signChanges = c.signChanges + nextC.signChanges + (sameSign and 0 or 1),
          kind = chicaneGap and 'chicane_or_esses' or classifyCorner(c.lengthM + gap + nextC.lengthM, math.max(c.absCurvature, nextC.absCurvature), 0),
          confidence = math.min(c.confidence, nextC.confidence),
        }
        merged[#merged + 1] = combined
        i = i + 2
      else
        c.id = string.format('c%03d', #merged + 1)
        merged[#merged + 1] = c
        i = i + 1
      end
    else
      c.id = string.format('c%03d', #merged + 1)
      merged[#merged + 1] = c
      i = i + 1
    end
  end

  return merged, curvature, raw
end

return M
