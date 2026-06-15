-- DynamicRacingLine line_core/tile_window.lua
-- Consistent visible/brake tile window. Prevents empty windows, centerline collapse near car,
-- active/fallback interpolation mixups, seam jumps, and stale tile prep after FPS spikes.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local Frame = require('src.line_core.frame')

local M = {}

local lastGoodWindow = nil
local lastGoodStamp = 0
local staleReuseCount = 0

local function pointCountForLookahead(frame, lookaheadM)
  local spacing = math.max(1, frame and frame.spacing or Config.TARGET_SAMPLE_SPACING_M)
  return U.clamp(math.floor(lookaheadM / spacing), Config.MIN_VISIBLE_TILES, Config.MAX_VISIBLE_TILES)
end

local function nearestGuidanceIndex(guidancePoints, progress, trackLength)
  local bestI, bestD = 1, math.huge
  for i = 1, #(guidancePoints or {}) do
    local p = guidancePoints[i].progress or 0
    local d = math.abs(U.shortProgressDelta(p, progress, trackLength))
    if d < bestD then bestD = d; bestI = i end
  end
  return bestI, bestD
end

local function cloneTile(p)
  return {
    progress = p.progress,
    world = p.world,
    offset = p.offset or 0,
    color = p.color or 'green',
    brakeIntensity = p.brakeIntensity or 0,
    tileTilt = p.tileTilt or 0,
    confidence = p.confidence or 0.4,
    targetSpeedMps = p.targetSpeedMps,
    solvedSpeedMps = p.solvedSpeedMps,
    source = p.source or 'guidance',
    active = p.active ~= false,
  }
end

local function cloneWindow(window)
  local out = {}
  for k, v in pairs(window or {}) do out[k] = v end
  if type(window and window.tiles) == 'table' then
    local tiles = {}
    for i, tile in ipairs(window.tiles) do tiles[i] = tile end
    out.tiles = tiles
  end
  return out
end

function M.prepare(frame, guidancePoints, carState, opts)
  opts = opts or {}
  local now = opts.now or os.clock()
  local speed = tonumber(carState and (carState.speedMps or carState.speed_ms or carState.speed)) or 0
  local carPos = carState and (carState.position or carState.pos or carState.world)
  local lastProgress = carState and carState.lastProgress
  local confidence = opts.confidence or 0.5
  local lookahead = opts.lookaheadM or Config.visibleLookahead(speed)
  local trackLength = frame and frame.length or 0
  local maxStaleReuseS = opts.maxStaleReuseS or Config.GUIDANCE_CACHE_MAX_AGE_S

  if not frame or not frame.ok or not guidancePoints or #guidancePoints == 0 then
    if lastGoodWindow and now - lastGoodStamp < maxStaleReuseS then
      staleReuseCount = staleReuseCount + 1
      local reused = cloneWindow(lastGoodWindow)
      reused.stale = true
      reused.staleReuseCount = staleReuseCount
      reused.reason = 'reused_last_good_window_no_guidance'
      return reused
    end
    lastGoodWindow = nil
    return { ok = false, tiles = {}, reason = 'no_frame_or_guidance', tileCount = 0 }
  end

  local projection
  if carPos then
    projection = Frame.projectWorld(frame, carPos, lastProgress, math.max(lookahead, 120))
  else
    projection = { ok = true, progress = lastProgress or 0, lateral = 0, distance = 0 }
  end

  local interp = Frame.interpolateSample(frame, projection.progress or 0)
  local halfWidth = math.min(interp.leftWidth or Config.DEFAULT_TRACK_HALF_WIDTH_M, interp.rightWidth or Config.DEFAULT_TRACK_HALF_WIDTH_M)
  local lateralLimit = Config.dynamicRecoveryLateralLimit(speed, halfWidth, confidence)

  if projection.ok and math.abs(projection.lateral or 0) > lateralLimit then
    -- Do not reject tiles just because a mod track's centerline is >12m away.
    -- Mark low confidence and use progress recovery from nearest guidance point.
    projection.recoveredFromLargeLateral = true
    projection.recoveryLateralLimit = lateralLimit
  end

  local startIndex = nearestGuidanceIndex(guidancePoints, projection.progress or 0, trackLength)
  local count = pointCountForLookahead(frame, lookahead)
  local tiles = {}
  local n = #guidancePoints
  for j = 0, count - 1 do
    local idx = ((startIndex + j - 1) % n) + 1
    local p = cloneTile(guidancePoints[idx])

    -- Near-car visual collapse fix: never blend the generated offset back to zero just
    -- because the car is close. If blending is needed, blend from current projected lateral
    -- to the solved line, not from centerline to the solved line.
    if j < 4 and projection and projection.ok and opts.nearCarBlend ~= false then
      local t = U.smoothstep(j / 4)
      local currentLat = projection.lateral or p.offset or 0
      p.offset = U.lerp(currentLat, p.offset or 0, t)
      local world = Frame.worldFromProgressOffset(frame, p.progress, p.offset)
      p.world = world
    end

    -- Lift is attached here so the renderer does not hide line behind road mesh.
    if p.world then
      p.world = { x = U.x(p.world), y = U.y(p.world) + Config.LINE_LIFT_M, z = U.z(p.world) }
    end

    tiles[#tiles + 1] = p
  end

  if #tiles == 0 then
    if lastGoodWindow and now - lastGoodStamp < maxStaleReuseS then
      staleReuseCount = staleReuseCount + 1
      local reused = cloneWindow(lastGoodWindow)
      reused.stale = true
      reused.staleReuseCount = staleReuseCount
      reused.reason = 'reused_last_good_window_empty_tiles'
      return reused
    end
    lastGoodWindow = nil
    return { ok = false, tiles = {}, reason = 'empty_tile_window', tileCount = 0 }
  end

  local out = {
    ok = true,
    tiles = tiles,
    tileCount = #tiles,
    reason = projection and projection.recoveredFromLargeLateral and 'large_lateral_recovery' or 'ok',
    projection = projection,
    lookaheadM = lookahead,
    startIndex = startIndex,
    confidence = confidence,
  }
  lastGoodWindow = out
  lastGoodStamp = now
  staleReuseCount = 0
  return out
end

function M.clearCache()
  lastGoodWindow = nil
  lastGoodStamp = 0
  staleReuseCount = 0
end

return M
