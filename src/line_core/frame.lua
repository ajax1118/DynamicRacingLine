-- DynamicRacingLine line_core/frame.lua
-- One unified progress/world/lateral transform. This replaces ad-hoc coordinate conversion assumptions
-- that place samples laterally wrong on mod tracks.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')

local M = {}

local function sampleWorld(s)
  if s.world then return U.vec(U.x(s.world), U.y(s.world), U.z(s.world)) end
  if s.pos then return U.vec(U.x(s.pos), U.y(s.pos), U.z(s.pos)) end
  return U.vec(U.x(s), U.y(s), U.z(s))
end

local function sampleProgress(s, previousProgress, previousWorld, world)
  local p = s.progress or s.s or s.distance or s.normalizedSplinePosition
  if p ~= nil then return tonumber(p) or 0 end
  if previousWorld then
    return (previousProgress or 0) + U.distance2(previousWorld, world)
  end
  return 0
end

local function sortByProgress(samples)
  table.sort(samples, function(a, b) return (a.progress or 0) < (b.progress or 0) end)
end

function M.prepare(rawSamples, opts)
  opts = opts or {}
  local samples = {}
  local previousWorld, previousProgress

  for i = 1, #(rawSamples or {}) do
    local r = rawSamples[i]
    local world = sampleWorld(r)
    local progress = sampleProgress(r, previousProgress, previousWorld, world)
    local leftWidth = tonumber(r.leftWidth or r.left_width or r.widthLeft or r.trackLeft or r.halfWidth or r.half_width)
    local rightWidth = tonumber(r.rightWidth or r.right_width or r.widthRight or r.trackRight or r.halfWidth or r.half_width)
    local confidence = tonumber(r.confidence or r.widthConfidence or r.sourceConfidence) or opts.sourceConfidence or 0.55

    samples[#samples + 1] = {
      index = #samples + 1,
      progress = progress,
      world = world,
      leftWidth = leftWidth,
      rightWidth = rightWidth,
      confidence = U.clamp(confidence, 0, 1),
      source = r.source or opts.source or 'centerline',
    }
    previousWorld = world
    previousProgress = progress
  end

  if #samples < 3 then
    return {
      ok = false,
      reason = 'not_enough_samples',
      samples = samples,
      length = 0,
      spacing = Config.TARGET_SAMPLE_SPACING_M,
      closed = false,
    }
  end

  sortByProgress(samples)

  -- Ensure strictly increasing progress to avoid seam/duplicate discontinuities.
  for i = 2, #samples do
    if samples[i].progress <= samples[i - 1].progress then
      samples[i].progress = samples[i - 1].progress + U.distance2(samples[i].world, samples[i - 1].world)
    end
  end

  local length
  if opts.trackLength and opts.trackLength > samples[#samples].progress then
    length = opts.trackLength
  else
    local seam = U.distance2(samples[#samples].world, samples[1].world)
    length = samples[#samples].progress + math.max(seam, Config.TARGET_SAMPLE_SPACING_M)
  end

  -- Tangents and normals use neighbor differences in world space, not a separate progress transform.
  for i = 1, #samples do
    local prev = samples[i - 1] or samples[#samples]
    local next = samples[i + 1] or samples[1]
    local tangent = U.sub(next.world, prev.world)
    samples[i].tangent = U.norm2(tangent)
    samples[i].normal = U.leftNormal2(samples[i].tangent)
  end

  -- Smooth normals to reduce coordinate noise without flattening real chicanes.
  local radius = opts.normalSmoothRadius or 2
  for i = 1, #samples do
    local nx, nz, count = 0, 0, 0
    for d = -radius, radius do
      local j = i + d
      while j < 1 do j = j + #samples end
      while j > #samples do j = j - #samples end
      nx = nx + samples[j].normal.x
      nz = nz + samples[j].normal.z
      count = count + 1
    end
    samples[i].normal = U.norm2({ x = nx / count, y = 0, z = nz / count })
    samples[i].tangent = U.norm2({ x = samples[i].normal.z, y = 0, z = -samples[i].normal.x })
  end

  local spacingSum, spacingCount = 0, 0
  for i = 2, #samples do
    spacingSum = spacingSum + math.abs(samples[i].progress - samples[i - 1].progress)
    spacingCount = spacingCount + 1
  end

  return {
    ok = true,
    reason = 'ok',
    samples = samples,
    length = length,
    spacing = spacingSum / math.max(1, spacingCount),
    closed = true,
    source = opts.source or 'prepared_frame',
  }
end

function M.wrapProgress(frame, progress)
  return U.wrap(progress, frame and frame.length or 0)
end

function M.findSegment(frame, progress)
  local samples = frame.samples
  local n = #samples
  if n == 0 then return 1, 1, 0 end
  progress = M.wrapProgress(frame, progress)

  -- Small linear search is fast enough for app tile windows and avoids binary bugs at seam.
  for i = 1, n do
    local a = samples[i]
    local b = samples[i + 1] or samples[1]
    local ap = a.progress
    local bp = b.progress
    if i == n then bp = frame.length end
    if progress >= ap and progress <= bp then
      local t = 0
      if bp > ap then t = (progress - ap) / (bp - ap) end
      return i, (i % n) + 1, U.clamp(t, 0, 1)
    end
  end
  return n, 1, 0
end

function M.interpolateSample(frame, progress)
  local i, j, t = M.findSegment(frame, progress)
  local a, b = frame.samples[i], frame.samples[j]
  local world = U.add(a.world, U.mul(U.sub(b.world, a.world), t))
  local tangent = U.norm2(U.add(U.mul(a.tangent, 1 - t), U.mul(b.tangent, t)))
  local normal = U.leftNormal2(tangent)
  local leftWidth = U.lerp(a.leftWidth or Config.DEFAULT_TRACK_HALF_WIDTH_M, b.leftWidth or Config.DEFAULT_TRACK_HALF_WIDTH_M, t)
  local rightWidth = U.lerp(a.rightWidth or Config.DEFAULT_TRACK_HALF_WIDTH_M, b.rightWidth or Config.DEFAULT_TRACK_HALF_WIDTH_M, t)
  local confidence = U.lerp(a.confidence or 0.55, b.confidence or 0.55, t)
  return {
    indexA = i,
    indexB = j,
    t = t,
    progress = M.wrapProgress(frame, progress),
    world = world,
    tangent = tangent,
    normal = normal,
    leftWidth = leftWidth,
    rightWidth = rightWidth,
    confidence = confidence,
  }
end

function M.worldFromProgressOffset(frame, progress, offsetM)
  local s = M.interpolateSample(frame, progress)
  local world = U.add(s.world, U.mul(s.normal, offsetM or 0))
  return world, s
end

function M.projectWorld(frame, pos, hintProgress, searchRadiusM)
  local samples = frame.samples or {}
  local n = #samples
  if n == 0 then
    return { ok = false, reason = 'empty_frame', progress = 0, lateral = 0, distance = math.huge, index = 1 }
  end

  local bestIndex, bestD = 1, math.huge
  local p = U.vec(U.x(pos), U.y(pos), U.z(pos))
  local useHint = hintProgress ~= nil and searchRadiusM ~= nil and searchRadiusM > 0

  for i = 1, n do
    local s = samples[i]
    if not useHint or math.abs(U.shortProgressDelta(s.progress, hintProgress, frame.length)) <= searchRadiusM then
      local d = U.distance2(p, s.world)
      if d < bestD then
        bestD = d
        bestIndex = i
      end
    end
  end

  -- If hint search missed due to wrap/noise, do one full recovery pass.
  if bestD == math.huge then
    for i = 1, n do
      local d = U.distance2(p, samples[i].world)
      if d < bestD then
        bestD = d
        bestIndex = i
      end
    end
  end

  local a = samples[bestIndex]
  local b = samples[(bestIndex % n) + 1]
  local ab = U.sub(b.world, a.world)
  local ap = U.sub(p, a.world)
  local ab2 = math.max(1e-6, U.dot2(ab, ab))
  local t = U.clamp(U.dot2(ap, ab) / ab2, 0, 1)
  local center = U.add(a.world, U.mul(ab, t))
  local tangent = U.norm2(ab)
  local normal = U.leftNormal2(tangent)
  local lateral = U.dot2(U.sub(p, center), normal)
  local bProgress = b.progress
  if bestIndex == n then bProgress = frame.length end
  local progress = U.lerp(a.progress, bProgress, t)
  progress = M.wrapProgress(frame, progress)

  return {
    ok = true,
    progress = progress,
    lateral = lateral,
    distance = math.abs(lateral),
    index = bestIndex,
    t = t,
    center = center,
    normal = normal,
    tangent = tangent,
  }
end

function M.buildPathPoints(frame, offsets)
  local out = {}
  for i = 1, #(frame.samples or {}) do
    local s = frame.samples[i]
    local o = offsets and offsets[i] or 0
    out[i] = {
      progress = s.progress,
      offset = o,
      world = U.add(s.world, U.mul(s.normal, o)),
      normal = s.normal,
      tangent = s.tangent,
      source = 'line_core_path',
    }
  end
  return out
end


function M.resamplePrepared(frame, targetSpacingM)
  -- Distance-resample after initial preparation. This reduces both low-spacing coordinate
  -- noise and high-sample tiny lateral inconsistency without using a separate transform.
  if not frame or not frame.ok or not frame.samples or #frame.samples < 3 then return frame end
  targetSpacingM = math.max(Config.MIN_SAMPLE_SPACING_M, math.min(Config.MAX_SAMPLE_SPACING_M, targetSpacingM or Config.TARGET_SAMPLE_SPACING_M))
  local count = math.max(3, math.floor((frame.length or 0) / targetSpacingM + 0.5))
  if count <= 3 then return frame end
  local actualSpacing = (frame.length or 0) / count
  local raw = {}
  for i = 1, count do
    local progress = (i - 1) * actualSpacing
    local s = M.interpolateSample(frame, progress)
    raw[i] = {
      progress = progress,
      world = s.world,
      leftWidth = s.leftWidth,
      rightWidth = s.rightWidth,
      confidence = s.confidence,
      source = 'distance_resampled_' .. tostring(frame.source or 'frame'),
    }
  end
  local out = M.prepare(raw, {
    trackLength = frame.length,
    source = 'distance_resampled',
    sourceConfidence = frame.sourceConfidence or 0.55,
    normalSmoothRadius = 2,
  })
  out.originalSampleCount = #(frame.samples or {})
  out.resampled = true
  out.spacing = actualSpacing
  return out
end

return M
