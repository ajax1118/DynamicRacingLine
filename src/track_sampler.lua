local settings = require('src/settings')
local math3d = require('src/math3d')
local logger = require('src/logger')
local optimal_line_solver = require('src/optimal_line_solver')
local safe_struct = require('src/safe_struct')
local M = {}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function finiteVec(p)
  if not p then return false end
  local x, y, z = math3d.x(p), math3d.y(p), math3d.z(p)
  return x == x and y == y and z == z and math.abs(x) < 100000 and math.abs(y) < 100000 and math.abs(z) < 100000
end

local function trackValue(runtimeProfile, key, fallback)
  local track = runtimeProfile and runtimeProfile.track or {}
  return finiteNumber(track[key], fallback)
end

local function currentTrackLengthM()
  if not ac or not ac.getSim then return 0 end
  local ok, sim = pcall(function() return ac.getSim() end)
  if not ok or not sim then return 0 end
  return finiteNumber(safe_struct.number(sim, 'trackLengthM', 0), 0)
end

local function adaptiveSampleCount(runtimeProfile)
  local requested = math.floor(trackValue(runtimeProfile, 'track_sample_count', settings.TRACK_SAMPLE_COUNT) + 0.5)
  local spacingM = math.max(0.5, finiteNumber(settings.PROFILE_SPACING_M, 5.0))
  local trackLengthM = currentTrackLengthM()
  local lengthBased = 0
  if trackLengthM > 0 then
    lengthBased = math.ceil(trackLengthM / spacingM)
  end
  return math.min(4000, math.max(80, requested, lengthBased)), trackLengthM, spacingM
end

local function progressToWorld(progress)
  if ac and ac.trackProgressToWorldCoordinate then
    local ok, p = pcall(function() return ac.trackProgressToWorldCoordinate(progress, true) end)
    if ok and p and finiteVec(p) then
      return math3d.vec(math3d.x(p), math3d.y(p), math3d.z(p)), 'trackProgressToWorldCoordinate'
    end
  end

  return nil, 'none'
end

local function coordinateProgressTolerance(lateral, height)
  local base = math.max(2.0, finiteNumber(settings.TRACK_COORDINATE_MAX_PROGRESS_DELTA_M, 12.0))
  local lateralAllowance = math.abs(finiteNumber(lateral, 0.0)) * 20.0
  local heightAllowance = math.abs(finiteNumber(height, 0.0)) * 2.0
  return base + lateralAllowance + heightAllowance
end

local function toWorld(progress, lateral, height)
  local progressPos, progressMode = progressToWorld(progress)

  if ac and ac.trackCoordinateToWorld and vec3 then
    local ok, p = pcall(function() return ac.trackCoordinateToWorld(vec3(lateral, height, progress)) end)
    if ok and p and finiteVec(p) then
      local coordinatePos = math3d.vec(math3d.x(p), math3d.y(p), math3d.z(p))
      local coordinateDeltaM = progressPos and math3d.dist(coordinatePos, progressPos) or 0.0
      if not progressPos or coordinateDeltaM <= coordinateProgressTolerance(lateral, height) then
        return coordinatePos, 'trackCoordinateToWorld', coordinateDeltaM
      end

      logger.once('track-coordinate-rejected', 'TRACK_COORDINATE_REJECTED reason=progress_disagreement' ..
        ' progress=' .. tostring(progress) ..
        ' deltaM=' .. tostring(coordinateDeltaM) ..
        ' toleranceM=' .. tostring(coordinateProgressTolerance(lateral, height)) ..
        ' fallback=' .. tostring(progressMode))
      return progressPos, progressMode, coordinateDeltaM
    end
  end

  if progressPos then return progressPos, progressMode, nil end

  return nil, 'none', nil
end

local function wrapIndex(points, index)
  local count = #points
  if count <= 0 then return nil end
  return ((index - 1) % count) + 1
end

local function fallbackNormal(forward)
  local up = math3d.vec(0, 1, 0)
  if math.abs(math3d.dot(forward, up)) > 0.96 then
    return math3d.vec(1, 0, 0)
  end
  return up
end

local function sign(value)
  value = tonumber(value) or 0
  if value < 0 then return -1 end
  return 1
end

local function lerpNumber(a, b, t)
  return a + (b - a) * math3d.clamp(t, 0.0, 1.0)
end

local function nearCarOffsetScale(distanceAheadM)
  local blendM = math.max(0.1, finiteNumber(settings.RACING_LINE_NEAR_OFFSET_BLEND_M, 12.0))
  local minScale = math3d.clamp(finiteNumber(settings.RACING_LINE_NEAR_OFFSET_MIN_SCALE, 0.18), 0.0, 1.0)
  local t = math3d.clamp(math.max(0.0, finiteNumber(distanceAheadM, 0.0)) / blendM, 0.0, 1.0)
  t = t * t * (3.0 - 2.0 * t)
  return minScale + (1.0 - minScale) * t
end

local function applyNearCarOffset(tile, distanceAheadM)
  if not tile or not tile.centerPos or not tile.right then return tile end
  if settings.RACING_LINE_ENABLED ~= true then
    tile.nearOffsetScale = 0.0
    tile.lineOffsetScale = 0.0
    tile.dynamicLineOffsetM = 0.0
    tile.pos = tile.centerPos
    return tile
  end
  if tile.racingLineActive ~= true then
    tile.nearOffsetScale = 0.0
    tile.lineOffsetScale = 0.0
    tile.dynamicLineOffsetM = 0.0
    tile.pos = tile.centerPos
    return tile
  end
  local racingLineOffsetM = finiteNumber(tile.racingLineOffsetM, 0.0)
  local lineOffsetScale = finiteNumber(tile.lineOffsetScale, 1.0)
  local lateralRight = tile.centerRight or tile.right
  local nearOffsetScale = nearCarOffsetScale(distanceAheadM)
  tile.nearOffsetScale = nearOffsetScale
  tile.dynamicLineOffsetM = racingLineOffsetM * lineOffsetScale * nearOffsetScale
  tile.pos = math3d.add(tile.centerPos, math3d.mul(lateralRight, tile.dynamicLineOffsetM))
  return tile
end

function M.applyNearCarOffset(tile, distanceAheadM)
  return applyNearCarOffset(tile, distanceAheadM)
end

local function smoothVisibleOffsetPass(offsets)
  local count = #(offsets or {})
  if count < 3 then return offsets end
  local smoothed = {}
  smoothed[1] = offsets[1] * 0.75 + offsets[2] * 0.25
  for j = 2, count - 1 do
    smoothed[j] = offsets[j - 1] * 0.25 + offsets[j] * 0.50 + offsets[j + 1] * 0.25
  end
  smoothed[count] = offsets[count] * 0.75 + offsets[count - 1] * 0.25
  return smoothed
end

local function maxVisibleOffsetStep(offsets)
  local count = #(offsets or {})
  if count < 2 then return 0.0 end
  local maxStep = 0.0
  for j = 2, count do
    maxStep = math.max(maxStep, math.abs(offsets[j] - offsets[j - 1]))
  end
  return maxStep
end

local function maxVisibleOffsetAccel(offsets)
  local count = #(offsets or {})
  if count < 3 then return 0.0 end
  local maxAccel = 0.0
  for j = 3, count do
    local step = offsets[j] - offsets[j - 1]
    local prevStep = offsets[j - 1] - offsets[j - 2]
    maxAccel = math.max(maxAccel, math.abs(step - prevStep))
  end
  return maxAccel
end

local function maxVisibleOffsetJerk(offsets)
  local count = #(offsets or {})
  if count < 4 then return 0.0 end
  local maxJerk = 0.0
  for j = 4, count do
    local step = offsets[j] - offsets[j - 1]
    local prevStep = offsets[j - 1] - offsets[j - 2]
    local olderStep = offsets[j - 2] - offsets[j - 3]
    maxJerk = math.max(maxJerk, math.abs((step - prevStep) - (prevStep - olderStep)))
  end
  return maxJerk
end

local function limitVisibleOffsetSteps(offsets, maxStepM)
  local count = #(offsets or {})
  if count < 2 then return offsets end
  local step = math.max(0.05, finiteNumber(maxStepM, 0.42))
  for _ = 1, 2 do
    for j = 2, count do
      local delta = offsets[j] - offsets[j - 1]
      offsets[j] = offsets[j - 1] + math3d.clamp(delta, -step, step)
    end
    for j = count - 1, 1, -1 do
      local delta = offsets[j] - offsets[j + 1]
      offsets[j] = offsets[j + 1] + math3d.clamp(delta, -step, step)
    end
  end
  return offsets
end

local function limitVisibleOffsetAccel(offsets, maxAccelM)
  local count = #(offsets or {})
  if count < 3 then return offsets end
  local accel = math.max(0.03, finiteNumber(maxAccelM, 0.18))
  for _ = 1, 12 do
    if maxVisibleOffsetAccel(offsets) <= accel + 0.001 then return offsets end
    offsets = smoothVisibleOffsetPass(offsets)
  end
  return offsets
end

local function limitVisibleOffsetJerk(offsets, maxJerkM)
  local count = #(offsets or {})
  if count < 4 then return offsets end
  local jerk = math.max(0.02, finiteNumber(maxJerkM, 0.12))
  local passes = math.max(2, math.floor(finiteNumber(settings.RACING_LINE_RELAXATION_PASSES, 6) + 0.5))
  for _ = 1, passes do
    if maxVisibleOffsetJerk(offsets) <= jerk + 0.001 then return offsets end
    offsets = smoothVisibleOffsetPass(offsets)
  end
  return offsets
end

local function visibleOffsetSign(value, deadbandM)
  value = finiteNumber(value, 0.0)
  local deadband = math.max(0.0, finiteNumber(deadbandM, 0.0))
  if math.abs(value) <= deadband then return 0 end
  return value < 0 and -1 or 1
end

local function dampCenterlineOffset(value, deadbandM)
  value = finiteNumber(value, 0.0)
  local deadband = math.max(0.0, finiteNumber(deadbandM, 0.0))
  if deadband <= 0.0 then return value end
  local magnitude = math.abs(value)
  if magnitude <= deadband then return 0.0 end
  local fadeEnd = deadband * 2.5
  if magnitude >= fadeEnd then return value end
  local t = (magnitude - deadband) / math.max(0.001, fadeEnd - deadband)
  local eased = t * t * (3.0 - 2.0 * t)
  return value * eased
end

local function dampCenterlineOffsets(offsets, active)
  local deadband = math.max(0.0, finiteNumber(settings.RACING_LINE_CENTER_DEADBAND_M, 0.0))
  if deadband <= 0.0 then return offsets end
  for index, value in ipairs(offsets or {}) do
    if not active or active[index] == true then
      offsets[index] = dampCenterlineOffset(value, deadband)
    end
  end
  return offsets
end

local function nearestVisibleOffsetSign(signs, active, index, direction, maxSkip)
  local count = #(signs or {})
  local remaining = math.max(0, math.floor(finiteNumber(maxSkip, 0.0) + 0.5))
  while index >= 1 and index <= count and remaining >= 0 do
    if active[index] == true then
      local signValue = signs[index] or 0
      if signValue ~= 0 then return signValue, index end
    end
    index = index + direction
    remaining = remaining - 1
  end
  return 0, nil
end

local function stabilizeVisibleOffsetSigns(offsets, active, spacingM)
  local count = #(offsets or {})
  if count < 5 then return offsets, 0 end
  spacingM = math.max(0.5, finiteNumber(spacingM, settings.TILE_LENGTH_M))
  local minHoldM = math.max(spacingM * 2.0, finiteNumber(settings.RACING_LINE_CHATTER_MIN_SIGN_HOLD_M, 24.0))
  local minHoldSamples = math.max(2, math.floor((minHoldM / spacingM) + 0.5))
  local maxAmplitudeM = math.max(0.05, finiteNumber(settings.RACING_LINE_CHATTER_MAX_AMPLITUDE_M, 2.20))
  local deadbandM = math.max(0.0, finiteNumber(settings.RACING_LINE_CHATTER_DEADBAND_M, 0.22))
  local signs = {}
  for index, value in ipairs(offsets) do
    signs[index] = active[index] == true and visibleOffsetSign(value, deadbandM) or 0
  end

  local suppressed = 0
  local index = 2
  while index <= count - 1 do
    local islandSign = signs[index] or 0
    if islandSign == 0 or active[index] ~= true then
      index = index + 1
    else
      local startIndex = index
      local endIndex = index
      local maxAbsOffset = math.abs(finiteNumber(offsets[index], 0.0))
      while endIndex + 1 <= count - 1 and signs[endIndex + 1] == islandSign and active[endIndex + 1] == true do
        endIndex = endIndex + 1
        maxAbsOffset = math.max(maxAbsOffset, math.abs(finiteNumber(offsets[endIndex], 0.0)))
      end

      local length = endIndex - startIndex + 1
      local searchLimit = math.max(2, minHoldSamples)
      local leftSign, leftIndex = nearestVisibleOffsetSign(signs, active, startIndex - 1, -1, searchLimit)
      local rightSign, rightIndex = nearestVisibleOffsetSign(signs, active, endIndex + 1, 1, searchLimit)
      if length < minHoldSamples and maxAbsOffset <= maxAmplitudeM and
        leftSign ~= 0 and rightSign ~= 0 and leftSign == rightSign and leftSign ~= islandSign and
        leftIndex ~= nil and rightIndex ~= nil then
        local leftValue = finiteNumber(offsets[leftIndex], 0.0)
        local rightValue = finiteNumber(offsets[rightIndex], leftValue)
        for fillIndex = startIndex, endIndex do
          local t = (fillIndex - startIndex + 1) / math.max(1, length + 1)
          offsets[fillIndex] = lerpNumber(leftValue, rightValue, t)
          signs[fillIndex] = visibleOffsetSign(offsets[fillIndex], deadbandM)
        end
        suppressed = suppressed + 1
      end
      index = endIndex + 1
    end
  end
  return offsets, suppressed
end

local function visibleWindowSpacingM(tiles)
  local total = 0.0
  local counted = 0
  for index = 2, #(tiles or {}) do
    local previous = tiles[index - 1]
    local current = tiles[index]
    local previousDistance = finiteNumber(previous and previous.distanceAheadM, nil)
    local currentDistance = finiteNumber(current and current.distanceAheadM, nil)
    if previousDistance and currentDistance then
      local delta = math.abs(currentDistance - previousDistance)
      if delta > 0.01 and delta < 25.0 then
        total = total + delta
        counted = counted + 1
      end
    end
  end
  if counted > 0 then return math.max(0.5, total / counted) end
  return math.max(0.5, finiteNumber(settings.TILE_LENGTH_M, 1.45))
end

local function smoothVisibleLineOffsets(offsets, active, spacingM)
  local count = #(offsets or {})
  if count < 2 then return offsets end
  offsets = stabilizeVisibleOffsetSigns(offsets, active, spacingM)
  local passes = math.max(2, math.floor(finiteNumber(settings.RACING_LINE_SMOOTHING_PASSES, 5) + 0.5))
  for _ = 1, passes do
    offsets = smoothVisibleOffsetPass(offsets)
    for j = 1, count do
      if active[j] ~= true then offsets[j] = 0.0 end
    end
  end
  offsets = dampCenterlineOffsets(offsets, active)
  offsets = stabilizeVisibleOffsetSigns(offsets, active, spacingM)
  local maxStep = math.max(0.05, finiteNumber(settings.RACING_LINE_MAX_OFFSET_STEP_M, 0.42))
  local maxAccel = math.max(0.03, finiteNumber(settings.RACING_LINE_MAX_OFFSET_ACCEL_M, 0.18))
  local maxJerk = math.max(0.02, finiteNumber(settings.RACING_LINE_MAX_OFFSET_JERK_M, 0.12))
  offsets = limitVisibleOffsetSteps(offsets, maxStep)
  offsets = limitVisibleOffsetAccel(offsets, maxAccel)
  offsets = limitVisibleOffsetJerk(offsets, maxJerk)
  offsets = stabilizeVisibleOffsetSigns(offsets, active, spacingM)
  offsets = dampCenterlineOffsets(offsets, active)
  offsets = limitVisibleOffsetAccel(offsets, maxAccel)
  offsets = limitVisibleOffsetSteps(offsets, maxStep)
  for j = 1, count do
    if active[j] ~= true then offsets[j] = 0.0 end
  end
  return offsets
end

local function visibleLinePositionForOffset(tile, offsetM)
  if not tile or not tile.centerPos or not finiteVec(tile.centerPos) then return nil end
  local lateralRight = tile.centerRight or tile.right
  if not lateralRight or not finiteVec(lateralRight) then return nil end
  return math3d.add(tile.centerPos, math3d.mul(lateralRight, finiteNumber(offsetM, 0.0)))
end

local function relaxVisibleLineWorldOffsets(tiles, offsets, active, spacingM)
  local count = #(offsets or {})
  if count < 3 then return offsets end
  local passes = math.max(0, math.floor(finiteNumber(settings.RACING_LINE_WORLD_RELAXATION_PASSES, 0) + 0.5))
  local blend = math3d.clamp(finiteNumber(settings.RACING_LINE_WORLD_RELAXATION_BLEND, 0.0), 0.0, 0.75)
  if passes <= 0 or blend <= 0.0 then return offsets end

  local maxOffset = math.max(0.0, finiteNumber(settings.RACING_LINE_MAX_OFFSET_M, 3.2))
  local working = {}
  for index, value in ipairs(offsets) do
    working[index] = finiteNumber(value, 0.0)
  end

  for _ = 1, passes do
    local relaxed = {}
    for index, value in ipairs(working) do
      relaxed[index] = value
    end
    for index = 2, count - 1 do
      if active[index] == true and active[index - 1] == true and active[index + 1] == true then
        local tile = tiles[index]
        local centerPos = tile and tile.centerPos
        local lateralRight = tile and (tile.centerRight or tile.right)
        local previousPos = visibleLinePositionForOffset(tiles[index - 1], working[index - 1])
        local currentPos = visibleLinePositionForOffset(tile, working[index])
        local nextPos = visibleLinePositionForOffset(tiles[index + 1], working[index + 1])
        if centerPos and lateralRight and previousPos and currentPos and nextPos and
          finiteVec(centerPos) and finiteVec(lateralRight) and
          finiteVec(previousPos) and finiteVec(currentPos) and finiteVec(nextPos) then
          local smoothPos = math3d.add(
            math3d.add(math3d.mul(previousPos, 0.25), math3d.mul(currentPos, 0.50)),
            math3d.mul(nextPos, 0.25))
          local projectedOffset = math3d.dot(math3d.sub(smoothPos, centerPos), lateralRight)
          projectedOffset = math3d.clamp(finiteNumber(projectedOffset, working[index]), -maxOffset, maxOffset)
          relaxed[index] = lerpNumber(working[index], projectedOffset, blend)
        end
      end
    end
    working = relaxed
  end

  local maxStep = math.max(0.05, finiteNumber(settings.RACING_LINE_MAX_OFFSET_STEP_M, 0.42))
  local maxAccel = math.max(0.03, finiteNumber(settings.RACING_LINE_MAX_OFFSET_ACCEL_M, 0.18))
  local maxJerk = math.max(0.02, finiteNumber(settings.RACING_LINE_MAX_OFFSET_JERK_M, 0.12))
  working = dampCenterlineOffsets(working, active)
  working = limitVisibleOffsetSteps(working, maxStep)
  working = limitVisibleOffsetAccel(working, maxAccel)
  working = limitVisibleOffsetJerk(working, maxJerk)
  working = limitVisibleOffsetSteps(working, maxStep)
  for index = 1, count do
    if active[index] ~= true then working[index] = 0.0 end
  end
  return working
end

local function visibleLineContinuity(offsets)
  local maxStep = math.max(0.05, finiteNumber(settings.RACING_LINE_MAX_OFFSET_STEP_M, 0.42)) + 0.01
  local maxAccel = math.max(0.03, finiteNumber(settings.RACING_LINE_MAX_OFFSET_ACCEL_M, 0.18)) + 0.01
  local maxJerk = math.max(0.02, finiteNumber(settings.RACING_LINE_MAX_OFFSET_JERK_M, 0.12)) + 0.01
  if maxVisibleOffsetStep(offsets) > maxStep then return false, 'visible_line_lateral_step_implausible' end
  if maxVisibleOffsetAccel(offsets) > maxAccel then return false, 'visible_line_lateral_accel_implausible' end
  if maxVisibleOffsetJerk(offsets) > maxJerk then return false, 'visible_line_lateral_jerk_implausible' end
  return true, 'visible_line_continuity_ok'
end

local function visibleLineTemporalKey(tile, spacingM)
  local trackDistanceM = finiteNumber(tile and tile.s, nil)
  if not trackDistanceM then return nil end
  local keyM = math.max(0.5, finiteNumber(settings.RACING_LINE_TEMPORAL_KEY_M,
    finiteNumber(spacingM, settings.TILE_LENGTH_M)))
  return tostring(math.floor(trackDistanceM / keyM + 0.5))
end

local function sameVisibleTemporalSide(currentOffset, previousOffset, deadbandM)
  local currentSign = visibleOffsetSign(currentOffset, deadbandM)
  local previousSign = visibleOffsetSign(previousOffset, deadbandM)
  return currentSign == 0 or previousSign == 0 or currentSign == previousSign
end

local function visibleTemporalEntryOffset(entry)
  if type(entry) == 'table' then return finiteNumber(entry.offset, nil) end
  return finiteNumber(entry, nil)
end

local function visibleTemporalAnchorCompatible(tile, previousEntry)
  if type(previousEntry) ~= 'table' then return false end
  local previousCenter = previousEntry.centerPos
  local currentCenter = tile and tile.centerPos
  if not finiteVec(previousCenter) or not finiteVec(currentCenter) then return false end
  local maxAnchorDeltaM = math.max(0.0, finiteNumber(settings.RACING_LINE_TEMPORAL_MAX_ANCHOR_DELTA_M, 8.0))
  return math3d.dist(previousCenter, currentCenter) <= maxAnchorDeltaM
end

local function blendVisibleTemporalOffsets(tiles, offsets, active, spacingM)
  if settings.RACING_LINE_TEMPORAL_SMOOTHING ~= true then return offsets end
  local previousState = M.visibleLineTemporalOffsets or {}
  local blend = math3d.clamp(finiteNumber(settings.RACING_LINE_TEMPORAL_BLEND, 0.35), 0.0, 0.85)
  if blend <= 0.0 then return offsets end
  local maxDeltaM = math.max(0.0, finiteNumber(settings.RACING_LINE_TEMPORAL_MAX_DELTA_M, 0.30))
  local deadbandM = math.max(0.0, finiteNumber(settings.RACING_LINE_CHATTER_DEADBAND_M, 0.22))
  for index, tile in ipairs(tiles or {}) do
    if active[index] == true then
      local key = visibleLineTemporalKey(tile, spacingM)
      local previousEntry = key and previousState[key]
      local previousOffset = visibleTemporalEntryOffset(previousEntry)
      local currentOffset = finiteNumber(offsets[index], 0.0)
      if previousOffset ~= nil and visibleTemporalAnchorCompatible(tile, previousEntry) and
        sameVisibleTemporalSide(currentOffset, previousOffset, deadbandM) and
        math.abs(currentOffset - previousOffset) <= maxDeltaM then
        offsets[index] = lerpNumber(currentOffset, previousOffset, blend)
      end
    end
  end
  return offsets
end

local function rememberVisibleTemporalOffsets(tiles, offsets, active, spacingM)
  if settings.RACING_LINE_TEMPORAL_SMOOTHING ~= true then
    M.visibleLineTemporalOffsets = nil
    return
  end
  local nextState = {}
  for index, tile in ipairs(tiles or {}) do
    if active[index] == true then
      local key = visibleLineTemporalKey(tile, spacingM)
      if key then
        nextState[key] = {
          offset = finiteNumber(offsets[index], 0.0),
          centerPos = tile.centerPos,
        }
      end
    end
  end
  M.visibleLineTemporalOffsets = nextState
end

local function failClosedVisibleLine(tiles, reason)
  M.visibleLineTemporalOffsets = nil
  for _, tile in ipairs(tiles or {}) do
    if tile and tile.centerPos then
      tile.pos = tile.centerPos
      tile.dynamicLineOffsetM = 0.0
      tile.nearOffsetScale = 0.0
      tile.lineOffsetScale = 0.0
      tile.racingLineActive = false
      tile.racingLineFallbackReason = reason or 'visible_line_continuity_rejected'
      tile.linePlacementMode = 'centerline_fallback'
      tile.visibleLineContinuity = 'fail_closed'
    end
  end
  return tiles
end

local function refreshVisibleLineBasis(tiles)
  local count = #(tiles or {})
  if count < 2 then return tiles end
  for index, tile in ipairs(tiles) do
    if tile and finiteVec(tile.pos) then
      local previous = tiles[math.max(1, index - 1)]
      local nextTile = tiles[math.min(count, index + 1)]
      local forwardSource = nil
      if previous and nextTile and previous ~= nextTile and finiteVec(previous.pos) and finiteVec(nextTile.pos) then
        forwardSource = math3d.sub(nextTile.pos, previous.pos)
      elseif nextTile and nextTile ~= tile and finiteVec(nextTile.pos) then
        forwardSource = math3d.sub(nextTile.pos, tile.pos)
      elseif previous and previous ~= tile and finiteVec(previous.pos) then
        forwardSource = math3d.sub(tile.pos, previous.pos)
      end
      if forwardSource and finiteVec(forwardSource) then
        local forward = math3d.norm(forwardSource, tile.forward or math3d.vec(0, 0, 1))
        local normal = math3d.norm(tile.lineNormal or tile.normal, fallbackNormal(forward))
        local right = math3d.norm(math3d.cross(normal, forward), tile.lineRight or tile.right or math3d.vec(1, 0, 0))
        tile.forward = forward
        tile.right = right
        tile.normal = normal
        tile.lineForward = forward
        tile.lineRight = right
        tile.lineNormal = normal
      end
    end
  end
  return tiles
end

local function failClosedBrakeLookaheadLine(tiles, reason)
  for _, tile in ipairs(tiles or {}) do
    if tile and tile.centerPos then
      tile.pos = tile.centerPos
      tile.dynamicLineOffsetM = 0.0
      tile.nearOffsetScale = 0.0
      tile.lineOffsetScale = 0.0
      tile.racingLineActive = false
      tile.racingLineFallbackReason = reason or 'brake_lookahead_line_continuity_rejected'
      tile.linePlacementMode = 'centerline_fallback'
      tile.brakeLookaheadLineContinuity = 'fail_closed'
    end
  end
  return tiles
end

function M.smoothBrakeLookaheadLine(tiles)
  local count = #(tiles or {})
  if count < 2 or settings.RACING_LINE_ENABLED ~= true or settings.BRAKE_LOOKAHEAD_SMOOTH_LINE ~= true then
    return tiles
  end
  local maxTiles = math.max(0, math.floor(finiteNumber(settings.BRAKE_LOOKAHEAD_SMOOTH_MAX_TILES,
    finiteNumber(settings.BRAKE_LOOKAHEAD_MAX_TILES, 170)) + 0.5))
  if maxTiles > 0 and count > maxTiles + 2 then return tiles end

  local offsets = {}
  local active = {}
  for index, tile in ipairs(tiles) do
    active[index] = tile and tile.racingLineActive == true and tile.linePlacementMode == 'lateral_optimal' and
      tile.centerPos ~= nil and tile.right ~= nil
    offsets[index] = active[index] and finiteNumber(tile.dynamicLineOffsetM, 0.0) or 0.0
  end

  local spacingM = visibleWindowSpacingM(tiles)
  offsets = smoothVisibleLineOffsets(offsets, active, spacingM)
  offsets = relaxVisibleLineWorldOffsets(tiles, offsets, active, spacingM)
  local ok, reason = visibleLineContinuity(offsets)
  if not ok then
    offsets = smoothVisibleLineOffsets(offsets, active, spacingM)
    ok, reason = visibleLineContinuity(offsets)
    if not ok then return failClosedBrakeLookaheadLine(tiles, reason) end
  end

  for index, tile in ipairs(tiles) do
    if tile and tile.centerPos and tile.right then
      tile.dynamicLineOffsetM = offsets[index] or 0.0
      local lateralRight = tile.centerRight or tile.right
      tile.pos = math3d.add(tile.centerPos, math3d.mul(lateralRight, tile.dynamicLineOffsetM))
      tile.brakeLookaheadLineContinuity = 'ok'
    end
  end
  refreshVisibleLineBasis(tiles)
  return tiles
end

function M.smoothVisibleWindowLine(tiles)
  local count = #(tiles or {})
  if count < 2 or settings.RACING_LINE_ENABLED ~= true then return tiles end
  local offsets = {}
  local active = {}
  for j, tile in ipairs(tiles) do
    active[j] = tile and tile.racingLineActive == true and tile.linePlacementMode == 'lateral_optimal' and
      tile.centerPos ~= nil and tile.right ~= nil
    offsets[j] = active[j] and finiteNumber(tile.dynamicLineOffsetM, 0.0) or 0.0
  end
  local spacingM = visibleWindowSpacingM(tiles)
  local visibleChatterSuppressed = 0
  offsets, visibleChatterSuppressed = stabilizeVisibleOffsetSigns(offsets, active, spacingM)
  offsets = smoothVisibleLineOffsets(offsets, active, spacingM)
  offsets = blendVisibleTemporalOffsets(tiles, offsets, active, spacingM)
  offsets = dampCenterlineOffsets(offsets, active)
  offsets = relaxVisibleLineWorldOffsets(tiles, offsets, active, spacingM)
  local ok, reason = visibleLineContinuity(offsets)
  if not ok then
    offsets = smoothVisibleLineOffsets(offsets, active, spacingM)
    ok, reason = visibleLineContinuity(offsets)
    if not ok then
      return failClosedVisibleLine(tiles, reason)
    end
  end
  rememberVisibleTemporalOffsets(tiles, offsets, active, spacingM)
  for j, tile in ipairs(tiles) do
    if tile and tile.centerPos and tile.right then
      tile.dynamicLineOffsetM = offsets[j] or 0.0
      local lateralRight = tile.centerRight or tile.right
      tile.pos = math3d.add(tile.centerPos, math3d.mul(lateralRight, tile.dynamicLineOffsetM))
      tile.visibleLineContinuity = 'ok'
    end
  end
  refreshVisibleLineBasis(tiles)
  return tiles
end

local function curvatureAt(points, index)
  local prev = points[wrapIndex(points, index - 2)]
  local cur = points[index]
  local nxt = points[wrapIndex(points, index + 2)]
  if not prev or not cur or not nxt then return 0 end
  local a = math3d.norm(math3d.sub(cur.pos, prev.pos), math3d.vec(0, 0, 1))
  local b = math3d.norm(math3d.sub(nxt.pos, cur.pos), math3d.vec(0, 0, 1))
  local turn = math3d.len(math3d.sub(b, a))
  local span = math.max(1.0, math3d.dist(prev.pos, nxt.pos))
  return turn / span
end

local function signedCurvatureAt(points, index)
  local prev = points[wrapIndex(points, index - 2)]
  local cur = points[index]
  local nxt = points[wrapIndex(points, index + 2)]
  if not prev or not cur or not nxt then return 0 end
  local a = math3d.norm(math3d.sub(cur.pos, prev.pos), math3d.vec(0, 0, 1))
  local b = math3d.norm(math3d.sub(nxt.pos, cur.pos), math3d.vec(0, 0, 1))
  local normal = cur.normal or fallbackNormal(a)
  local signedTurn = math3d.dot(math3d.cross(a, b), normal)
  return curvatureAt(points, index) * sign(signedTurn)
end

local function frameFor(points, index, lateral, height)
  local prev = points[wrapIndex(points, index - 1)].pos
  local nxt = points[wrapIndex(points, index + 1)].pos
  local center = points[index].pos
  local forward = math3d.norm(math3d.sub(nxt, prev), math3d.vec(0, 0, 1))
  local normal = fallbackNormal(forward)
  local higher, higherMode = toWorld(points[index].progress, lateral, height + 0.25)
  if higher and higherMode == 'trackCoordinateToWorld' then
    normal = math3d.norm(math3d.sub(higher, center), normal)
  end
  local right = math3d.norm(math3d.cross(normal, forward), math3d.vec(1, 0, 0))
  return forward, right, normal
end

local function applyProgressFallbackOffsets(samples, lateral, height)
  for _, sample in ipairs(samples or {}) do
    if sample.placementMode == 'trackProgressToWorldCoordinate' then
      sample.pos = math3d.add(sample.pos, math3d.add(math3d.mul(sample.right, lateral), math3d.mul(sample.normal, height)))
    end
  end
end

local function applyStoredLineOffset(sample, scale)
  if not sample or not sample.centerPos or not sample.right then return end
  if settings.RACING_LINE_ENABLED ~= true then
    sample.lineOffsetScale = 0.0
    sample.dynamicLineOffsetM = 0.0
    sample.pos = sample.centerPos
    return
  end
  scale = finiteNumber(scale, 1.0)
  local staticOffset = finiteNumber(sample.racingLineOffsetM, 0.0)
  local lateralRight = sample.centerRight or sample.right
  sample.lineOffsetScale = scale
  sample.dynamicLineOffsetM = staticOffset * scale
  sample.pos = math3d.add(sample.centerPos, math3d.mul(lateralRight, sample.dynamicLineOffsetM))
end

local function failClosedRacingLine(samples, reason)
  for _, sample in ipairs(samples or {}) do
    sample.centerPos = sample.centerPos or sample.pos
    sample.racingLineOffsetM = 0.0
    sample.dynamicLineOffsetM = 0.0
    sample.lineOffsetScale = 0.0
    sample.racingLineActive = false
    sample.racingLineFallbackReason = tostring(reason or 'unknown')
    sample.linePlacementMode = 'centerline_fallback'
    sample.pos = sample.centerPos
  end
  return {
    active = false,
    maxAbsOffsetM = 0,
    activeCount = 0,
    fallbackReason = tostring(reason or 'unknown'),
    linePlacementMode = 'centerline_fallback',
  }
end

local function validateRacingLineProof(samples, maxRightM, maxUpM, maxCoordinateDeltaM)
  for _, sample in ipairs(samples or {}) do
    if sample.placementMode ~= 'trackCoordinateToWorld' then
      return false, 'track_coordinate_unavailable'
    end
    local coordinateDeltaM = tonumber(sample.coordinateDeltaM)
    if coordinateDeltaM and math.abs(coordinateDeltaM) > maxCoordinateDeltaM then
      return false, 'track_coordinate_disagreement'
    end
    local center = sample.centerPos or sample.pos
    if center and sample.pos and sample.right and sample.normal then
      local delta = math3d.sub(sample.pos, center)
      if math.abs(math3d.dot(delta, sample.right)) > maxRightM then
        return false, 'visible_tile_lateral_implausible'
      end
      if math.abs(math3d.dot(delta, sample.normal)) > maxUpM then
        return false, 'visible_tile_vertical_implausible'
      end
    else
      return false, 'missing_spatial_basis'
    end
  end
  return true, 'active'
end

local function maxRacingLineOffsetStepM(sampleSpacingM)
  local configured = math.max(0.05, finiteNumber(settings.RACING_LINE_MAX_OFFSET_STEP_M, 0.42))
  local referenceSpacing = math.max(0.5, finiteNumber(settings.PROFILE_SPACING_M, 1.35))
  local spacingScale = math3d.clamp(finiteNumber(sampleSpacingM, referenceSpacing) / referenceSpacing, 0.50, 3.0)
  local dynamicHeadroom = math.max(1.0, finiteNumber(settings.RACING_LINE_MAX_DYNAMIC_SCALE, 1.12))
  return configured * spacingScale / dynamicHeadroom
end

local function maxRacingLineOffsetAccelM(sampleSpacingM)
  local configured = math.max(0.03, finiteNumber(settings.RACING_LINE_MAX_OFFSET_ACCEL_M, 0.18))
  local referenceSpacing = math.max(0.5, finiteNumber(settings.PROFILE_SPACING_M, 1.35))
  local spacingScale = math3d.clamp(finiteNumber(sampleSpacingM, referenceSpacing) / referenceSpacing, 0.50, 3.0)
  local dynamicHeadroom = math.max(1.0, finiteNumber(settings.RACING_LINE_MAX_DYNAMIC_SCALE, 1.12))
  return configured * spacingScale / dynamicHeadroom
end

local function maxRacingLineOffsetJerkM(sampleSpacingM)
  local configured = math.max(0.02, finiteNumber(settings.RACING_LINE_MAX_OFFSET_JERK_M, 0.12))
  local referenceSpacing = math.max(0.5, finiteNumber(settings.PROFILE_SPACING_M, 1.35))
  local spacingScale = math3d.clamp(finiteNumber(sampleSpacingM, referenceSpacing) / referenceSpacing, 0.50, 3.0)
  local dynamicHeadroom = math.max(1.0, finiteNumber(settings.RACING_LINE_MAX_DYNAMIC_SCALE, 1.12))
  return configured * spacingScale / dynamicHeadroom
end

local function smoothRacingLineOffsetPass(offsets)
  local count = #(offsets or {})
  if count < 3 then return offsets end
  local smoothed = {}
  for j = 1, count do
    smoothed[j] = offsets[wrapIndex(offsets, j - 1)] * 0.25 + offsets[j] * 0.50 +
      offsets[wrapIndex(offsets, j + 1)] * 0.25
  end
  return smoothed
end

local function smoothRacingLineOffsets(offsets)
  local count = #(offsets or {})
  if count < 3 then return offsets end
  local passes = math.max(2, math.floor(finiteNumber(settings.RACING_LINE_SMOOTHING_PASSES, 5) + 0.5))
  for _ = 1, passes do
    offsets = smoothRacingLineOffsetPass(offsets)
  end
  return offsets
end

local function maxOffsetStepChange(offsets)
  local count = #(offsets or {})
  if count < 3 then return 0.0 end
  local maxChange = 0.0
  for j = 1, count do
    local prevIndex = wrapIndex(offsets, j - 1)
    local prevPrevIndex = wrapIndex(offsets, j - 2)
    local currentStep = offsets[j] - offsets[prevIndex]
    local previousStep = offsets[prevIndex] - offsets[prevPrevIndex]
    local change = math.abs(currentStep - previousStep)
    if change > maxChange then maxChange = change end
  end
  return maxChange
end

local function maxOffsetJerkChange(offsets)
  local count = #(offsets or {})
  if count < 4 then return 0.0 end
  local maxChange = 0.0
  for j = 1, count do
    local previousIndex = wrapIndex(offsets, j - 1)
    local previousPreviousIndex = wrapIndex(offsets, j - 2)
    local previousPreviousPreviousIndex = wrapIndex(offsets, j - 3)
    local currentStep = offsets[j] - offsets[previousIndex]
    local previousStep = offsets[previousIndex] - offsets[previousPreviousIndex]
    local olderStep = offsets[previousPreviousIndex] - offsets[previousPreviousPreviousIndex]
    local currentAccel = currentStep - previousStep
    local previousAccel = previousStep - olderStep
    local change = math.abs(currentAccel - previousAccel)
    if change > maxChange then maxChange = change end
  end
  return maxChange
end

local function limitRacingLineOffsetAcceleration(offsets, maxAccelM)
  local count = #(offsets or {})
  if count < 3 then return offsets end
  local accel = math.max(0.03, finiteNumber(maxAccelM, 0.18))
  for _ = 1, 12 do
    if maxOffsetStepChange(offsets) <= accel + 0.001 then return offsets end
    local smoothed = {}
    for j = 1, count do
      smoothed[j] = offsets[wrapIndex(offsets, j - 1)] * 0.25 + offsets[j] * 0.50 +
        offsets[wrapIndex(offsets, j + 1)] * 0.25
    end
    offsets = smoothed
  end
  return offsets
end

local function limitRacingLineOffsetSteps(offsets, maxStepM)
  local count = #(offsets or {})
  if count < 2 then return offsets end
  local step = math.max(0.05, finiteNumber(maxStepM, 0.42))
  for _ = 1, 2 do
    for j = 1, count do
      local prev = offsets[wrapIndex(offsets, j - 1)]
      local delta = offsets[j] - prev
      offsets[j] = prev + math3d.clamp(delta, -step, step)
    end
    for j = count, 1, -1 do
      local nxt = offsets[wrapIndex(offsets, j + 1)]
      local delta = offsets[j] - nxt
      offsets[j] = nxt + math3d.clamp(delta, -step, step)
    end
  end
  return offsets
end

local function limitRacingLineOffsetJerk(offsets, maxJerkM)
  local count = #(offsets or {})
  if count < 4 then return offsets end
  local jerk = math.max(0.02, finiteNumber(maxJerkM, 0.12))
  local passes = math.max(2, math.floor(finiteNumber(settings.RACING_LINE_RELAXATION_PASSES, 6) + 0.5))
  for _ = 1, passes do
    if maxOffsetJerkChange(offsets) <= jerk + 0.001 then return offsets end
    offsets = smoothRacingLineOffsetPass(offsets)
  end
  return offsets
end

local function offsetSign(value, deadbandM)
  value = finiteNumber(value, 0.0)
  local deadband = math.max(0.0, finiteNumber(deadbandM, 0.0))
  if math.abs(value) <= deadband then return 0 end
  return value < 0 and -1 or 1
end

local function nearestNonZeroOffsetSign(signs, index, direction, maxSkip)
  local count = #(signs or {})
  local remaining = math.max(0, math.floor(finiteNumber(maxSkip, 0.0) + 0.5))
  while index >= 1 and index <= count and remaining >= 0 do
    local signValue = signs[index] or 0
    if signValue ~= 0 then return signValue, index end
    index = index + direction
    remaining = remaining - 1
  end
  return 0, nil
end

local function suppressRacingLineOffsetChatter(offsets, spacingM)
  local count = #(offsets or {})
  if count < 5 then return offsets, 0 end
  spacingM = math.max(0.5, finiteNumber(spacingM, settings.PROFILE_SPACING_M))
  local minHoldM = math.max(spacingM * 2.0, finiteNumber(settings.RACING_LINE_CHATTER_MIN_SIGN_HOLD_M, 10.0))
  local minHoldSamples = math.max(2, math.floor((minHoldM / spacingM) + 0.5))
  local maxAmplitudeM = math.max(0.05, finiteNumber(settings.RACING_LINE_CHATTER_MAX_AMPLITUDE_M, 0.75))
  local deadbandM = math.max(0.0, finiteNumber(settings.RACING_LINE_CHATTER_DEADBAND_M, 0.16))
  local signs = {}
  for index, value in ipairs(offsets) do
    signs[index] = offsetSign(value, deadbandM)
  end

  local suppressed = 0
  local index = 2
  while index <= count - 1 do
    local islandSign = signs[index] or 0
    if islandSign == 0 then
      index = index + 1
    else
      local startIndex = index
      local endIndex = index
      local maxAbsOffset = math.abs(finiteNumber(offsets[index], 0.0))
      while endIndex + 1 <= count - 1 and signs[endIndex + 1] == islandSign do
        endIndex = endIndex + 1
        maxAbsOffset = math.max(maxAbsOffset, math.abs(finiteNumber(offsets[endIndex], 0.0)))
      end

      local length = endIndex - startIndex + 1
      local searchLimit = math.max(2, minHoldSamples)
      local leftSign, leftIndex = nearestNonZeroOffsetSign(signs, startIndex - 1, -1, searchLimit)
      local rightSign, rightIndex = nearestNonZeroOffsetSign(signs, endIndex + 1, 1, searchLimit)
      if length < minHoldSamples and maxAbsOffset <= maxAmplitudeM and
        leftSign ~= 0 and rightSign ~= 0 and leftSign == rightSign and leftSign ~= islandSign and
        leftIndex ~= nil and rightIndex ~= nil then
        local leftValue = finiteNumber(offsets[leftIndex], 0.0)
        local rightValue = finiteNumber(offsets[rightIndex], leftValue)
        for fillIndex = startIndex, endIndex do
          local t = (fillIndex - startIndex + 1) / math.max(1, length + 1)
          offsets[fillIndex] = lerpNumber(leftValue, rightValue, t)
          signs[fillIndex] = offsetSign(offsets[fillIndex], deadbandM)
        end
        suppressed = suppressed + 1
      end
      index = endIndex + 1
    end
  end
  return offsets, suppressed
end

local function validateRacingLineContinuity(offsets, maxStepM)
  local count = #(offsets or {})
  if count < 2 then return true, 'active' end
  local maxStep = math.max(0.05, finiteNumber(maxStepM, 0.42)) + 0.01
  for j = 1, count do
    local delta = offsets[j] - offsets[wrapIndex(offsets, j - 1)]
    if math.abs(delta) > maxStep then
      return false, 'racing_line_lateral_step_implausible'
    end
  end
  return true, 'active'
end

local function validateRacingLineAcceleration(offsets, maxAccelM)
  local count = #(offsets or {})
  if count < 3 then return true, 'active' end
  local maxAccel = math.max(0.03, finiteNumber(maxAccelM, 0.18)) + 0.01
  if maxOffsetStepChange(offsets) > maxAccel then
    return false, 'racing_line_lateral_accel_implausible'
  end
  return true, 'active'
end

local function validateRacingLineJerk(offsets, maxJerkM)
  local count = #(offsets or {})
  if count < 4 then return true, 'active' end
  local maxJerk = math.max(0.02, finiteNumber(maxJerkM, 0.12)) + 0.01
  if maxOffsetJerkChange(offsets) > maxJerk then
    return false, 'racing_line_lateral_jerk_implausible'
  end
  return true, 'active'
end

local function blendWeightForTarget(strength, t)
  local phase = 1.0 - math.abs(math3d.clamp(finiteNumber(t, 0.5), 0.0, 1.0) * 2.0 - 1.0)
  return math.max(0.05, finiteNumber(strength, 1.0)) * (0.65 + phase * 0.35)
end

local function addRacingLineTarget(offsetSums, offsetWeights, offsets, index, target, weight)
  if settings.RACING_LINE_BLEND_OPPOSING_CORNERS == true then
    offsetSums[index] = (offsetSums[index] or 0.0) + target * weight
    offsetWeights[index] = (offsetWeights[index] or 0.0) + weight
  elseif math.abs(target) > math.abs(offsets[index]) then
    offsets[index] = target
  end
end

local function buildRacingLineCurvatureField(samples, threshold)
  local count = #(samples or {})
  local field = {}
  if count == 0 then return field end
  for index, sample in ipairs(samples) do
    field[index] = finiteNumber(sample and sample.signedCurvature, 0.0)
  end
  local passes = math.max(1, math.min(4, math.floor(finiteNumber(settings.RACING_LINE_SMOOTHING_PASSES, 5) * 0.5 + 0.5)))
  for _ = 1, passes do
    local smoothed = {}
    for index = 1, count do
      smoothed[index] = field[wrapIndex(field, index - 1)] * 0.20 + field[index] * 0.60 +
        field[wrapIndex(field, index + 1)] * 0.20
    end
    field = smoothed
  end
  local deadband = math.max(0.00001, finiteNumber(threshold, 0.0012))
  for index = 1, count do
    if math.abs(field[index]) < deadband then field[index] = 0.0 end
  end
  return field
end

local function applyRacingLineOffsets(samples, runtimeProfile, sampleSpacingM)
  local maxAbsOffset = 0
  local activeCount = 0
  if not settings.RACING_LINE_ENABLED then
    return failClosedRacingLine(samples, 'disabled')
  end

  local count = #(samples or {})
  if count < 3 then return failClosedRacingLine(samples, 'too_few_samples') end
  local spacingM = math.max(0.5, finiteNumber(sampleSpacingM, settings.PROFILE_SPACING_M))
  local maxOffset = math.max(0.0, trackValue(runtimeProfile, 'racing_line_max_offset_m', settings.RACING_LINE_MAX_OFFSET_M))
  local apexOffset = math.max(0.0, trackValue(runtimeProfile, 'racing_line_apex_offset_m', settings.RACING_LINE_APEX_OFFSET_M))
  if maxOffset > finiteNumber(settings.RACING_LINE_MAX_OFFSET_M, 3.2) + 0.001 then
    return failClosedRacingLine(samples, 'offset_exceeds_configured_bounds')
  end
  if apexOffset > maxOffset + 0.001 then
    return failClosedRacingLine(samples, 'apex_offset_exceeds_max_offset')
  end
  local maxRightM = math.max(0.0, finiteNumber(settings.RACING_LINE_FAIL_CLOSED_MAX_RIGHT_M, 8.0))
  local maxUpM = math.max(0.0, finiteNumber(settings.RACING_LINE_FAIL_CLOSED_MAX_UP_M, 1.5))
  local maxCoordinateDeltaM = math.max(0.0, finiteNumber(settings.RACING_LINE_FAIL_CLOSED_MAX_COORDINATE_DELTA_M, 12.0))
  local proofOk, proofReason = validateRacingLineProof(samples, maxRightM, maxUpM, maxCoordinateDeltaM)
  if not proofOk then return failClosedRacingLine(samples, proofReason) end
  local approachSamples = math.max(1, math.floor((finiteNumber(settings.RACING_LINE_APPROACH_M, 42.0) / spacingM) + 0.5))
  local exitSamples = math.max(1, math.floor((finiteNumber(settings.RACING_LINE_EXIT_M, 36.0) / spacingM) + 0.5))
  local threshold = math.max(0.00001, finiteNumber(settings.RACING_LINE_CURVATURE_THRESHOLD, 0.0012))
  local racingLineCurvatures = buildRacingLineCurvatureField(samples, threshold)
  local minCornerSamples = math.max(3, math.floor(math.min(approachSamples, exitSamples) * 0.08 + 0.5))
  local offsets = {}
  local offsetSums = {}
  local offsetWeights = {}
  local chatterSuppressed = 0
  local optimalLineSummary = nil
  for i = 1, count do
    offsets[i] = 0.0
    offsetSums[i] = 0.0
    offsetWeights[i] = 0.0
  end

  local i = 1
  while i <= count do
    local signed = finiteNumber(racingLineCurvatures[i], 0.0)
    if math.abs(signed) < threshold then
      i = i + 1
    else
      local turnSign = sign(signed)
      local startIndex = i
      local endIndex = i
      local apexIndex = i
      local apexCurvature = math.abs(signed)
      while endIndex + 1 <= count do
        local nextSigned = finiteNumber(racingLineCurvatures[endIndex + 1], 0.0)
        if math.abs(nextSigned) < threshold or sign(nextSigned) ~= turnSign then break end
        endIndex = endIndex + 1
        local absNext = math.abs(nextSigned)
        if absNext > apexCurvature then
          apexCurvature = absNext
          apexIndex = endIndex
        end
      end

      if endIndex - startIndex + 1 < minCornerSamples then
        i = endIndex + 1
      else
        local expandedStart = startIndex - approachSamples
        local expandedEnd = endIndex + exitSamples
        local strength = math3d.clamp(apexCurvature / (threshold * 5.0), 0.20, 1.0)
        for virtualJ = expandedStart, expandedEnd do
          local j = wrapIndex(offsets, virtualJ)
          local target
          local t
          if virtualJ <= apexIndex then
            t = (virtualJ - expandedStart) / math.max(1, apexIndex - expandedStart)
            target = lerpNumber(-turnSign * maxOffset, turnSign * apexOffset, t)
          else
            t = (virtualJ - apexIndex) / math.max(1, expandedEnd - apexIndex)
            target = lerpNumber(turnSign * apexOffset, -turnSign * maxOffset, t)
          end
          target = target * strength
          addRacingLineTarget(offsetSums, offsetWeights, offsets, j, target, blendWeightForTarget(strength, t))
        end
        i = endIndex + 1
      end
    end
  end

  if settings.RACING_LINE_BLEND_OPPOSING_CORNERS == true then
    for j = 1, count do
      if offsetWeights[j] > 0.0 then
        offsets[j] = offsetSums[j] / offsetWeights[j]
      end
    end
  end

  offsets, optimalLineSummary = optimal_line_solver.refineOffsets(samples, offsets, {
    spacingM = spacingM,
    maxOffset = maxOffset,
    apexOffset = apexOffset,
    threshold = threshold,
    trackLimitMarginM = finiteNumber(settings.OPTIMAL_LINE_TRACK_LIMIT_MARGIN_M, 0.35),
  })

  local maxStepM = maxRacingLineOffsetStepM(spacingM)
  local maxAccelM = maxRacingLineOffsetAccelM(spacingM)
  local maxJerkM = maxRacingLineOffsetJerkM(spacingM)
  offsets = smoothRacingLineOffsets(offsets)
  offsets = dampCenterlineOffsets(offsets)
  offsets, chatterSuppressed = suppressRacingLineOffsetChatter(offsets, spacingM)
  offsets = limitRacingLineOffsetSteps(offsets, maxStepM)
  offsets = limitRacingLineOffsetAcceleration(offsets, maxAccelM)
  offsets = limitRacingLineOffsetJerk(offsets, maxJerkM)
  local additionalChatterSuppressed = 0
  offsets, additionalChatterSuppressed = suppressRacingLineOffsetChatter(offsets, spacingM)
  chatterSuppressed = chatterSuppressed + additionalChatterSuppressed
  offsets = dampCenterlineOffsets(offsets)
  offsets = limitRacingLineOffsetAcceleration(offsets, maxAccelM)
  offsets = limitRacingLineOffsetSteps(offsets, maxStepM)
  proofOk, proofReason = validateRacingLineContinuity(offsets, maxStepM)
  if not proofOk then return failClosedRacingLine(samples, proofReason) end
  proofOk, proofReason = validateRacingLineAcceleration(offsets, maxAccelM)
  if not proofOk then return failClosedRacingLine(samples, proofReason) end
  proofOk, proofReason = validateRacingLineJerk(offsets, maxJerkM)
  if not proofOk then return failClosedRacingLine(samples, proofReason) end

  for index, sample in ipairs(samples) do
    sample.centerPos = sample.pos
    sample.racingLineOffsetM = offsets[index]
    sample.optimalLineSource = optimalLineSummary and optimalLineSummary.source or 'heuristic'
    sample.optimalLineIterations = optimalLineSummary and optimalLineSummary.iterations or 0
    sample.optimalLineCurvatureCost = optimalLineSummary and optimalLineSummary.maxCurvatureCost or 0.0
    applyStoredLineOffset(sample, 1.0)
    local absOffset = math.abs(sample.racingLineOffsetM or 0)
    if absOffset > 0.05 then activeCount = activeCount + 1 end
    if absOffset > maxAbsOffset then maxAbsOffset = absOffset end
  end
  proofOk, proofReason = validateRacingLineProof(samples, maxRightM, maxUpM, maxCoordinateDeltaM)
  if not proofOk then return failClosedRacingLine(samples, proofReason) end

  local fallbackReason = activeCount > 0 and 'active' or 'no_curvature_offsets'
  local linePlacementMode = activeCount > 0 and 'lateral_optimal' or 'centerline_fallback'
  for _, sample in ipairs(samples or {}) do
    sample.racingLineActive = activeCount > 0
    sample.racingLineFallbackReason = fallbackReason
    sample.linePlacementMode = linePlacementMode
  end

  return {
    active = activeCount > 0,
    maxAbsOffsetM = maxAbsOffset,
    activeCount = activeCount,
    maxConfiguredOffsetM = maxOffset,
    apexConfiguredOffsetM = apexOffset,
    chatterSuppressed = chatterSuppressed,
    optimalLineSource = optimalLineSummary and optimalLineSummary.source or 'heuristic',
    optimalLineIterations = optimalLineSummary and optimalLineSummary.iterations or 0,
    optimalLineMaxCurvatureCost = optimalLineSummary and optimalLineSummary.maxCurvatureCost or 0.0,
    fallbackReason = fallbackReason,
    linePlacementMode = linePlacementMode,
  }
end

local function updateRacingLineCurvature(samples, racingLineActive)
  local count = #(samples or {})
  if count < 3 then return end
  for _, sample in ipairs(samples) do
    sample.centerCurvature = finiteNumber(sample.curvature, 0.0)
    sample.centerSignedCurvature = finiteNumber(sample.signedCurvature, 0.0)
    sample.centerForward = sample.forward
    sample.centerRight = sample.right
    sample.centerNormal = sample.normal
  end
  for index, sample in ipairs(samples) do
    sample.lineCurvature = curvatureAt(samples, index)
    sample.lineSignedCurvature = signedCurvatureAt(samples, index)
    local previous = samples[wrapIndex(samples, index - 1)]
    local nextSample = samples[wrapIndex(samples, index + 1)]
    local lineForward = previous and nextSample and
      math3d.norm(math3d.sub(nextSample.pos, previous.pos), sample.forward or math3d.vec(0, 0, 1)) or sample.forward
    local lineNormal = math3d.norm(sample.normal, fallbackNormal(lineForward))
    local lineRight = math3d.norm(math3d.cross(lineNormal, lineForward), sample.right or math3d.vec(1, 0, 0))
    sample.lineForward = lineForward
    sample.lineRight = lineRight
    sample.lineNormal = lineNormal
  end
  if racingLineActive == true then
    for _, sample in ipairs(samples) do
      sample.curvature = finiteNumber(sample.lineCurvature, sample.curvature or 0.0)
      sample.signedCurvature = finiteNumber(sample.lineSignedCurvature, sample.signedCurvature or 0.0)
      sample.forward = sample.lineForward
      sample.right = sample.lineRight
      sample.normal = sample.lineNormal
    end
  end
end

function M.build(runtimeProfile)
  local lateral = trackValue(runtimeProfile, 'track_lateral_m', settings.TRACK_LATERAL)
  local height = trackValue(runtimeProfile, 'road_height_m', settings.ROAD_HEIGHT_M)
  local count, trackLengthHintM, sampleSpacingM = adaptiveSampleCount(runtimeProfile)
  local samples = {}
  local source = 'none'
  local degraded = false

  for i = 0, count - 1 do
    local progress = i / count
    local pos, mode, coordinateDeltaM = toWorld(progress, lateral, height)
    if pos then
      if mode ~= 'trackCoordinateToWorld' then degraded = true end
      source = mode
      samples[#samples + 1] = {
        index = #samples + 1,
        progress = progress,
        coordinateDeltaM = coordinateDeltaM,
        pos = pos,
        placementMode = mode,
        tileWidthM = trackValue(runtimeProfile, 'tile_width_m', settings.TILE_WIDTH_M),
        tileLengthM = trackValue(runtimeProfile, 'tile_length_m', settings.TILE_LENGTH_M),
      }
    end
  end

  if #samples < 40 then
    logger.write('TRACK_SAMPLER_FAILED samples=' .. tostring(#samples) .. ' source=' .. tostring(source) .. ' degraded=true')
    return {
      samples = {},
      totalLengthM = 0,
      source = source,
      placementMode = source,
      degraded = true,
      reason = 'too_few_samples',
    }
  end

  local total = 0
  samples[1].s = 0
  for i = 2, #samples do
    total = total + math3d.dist(samples[i - 1].pos, samples[i].pos)
    samples[i].s = total
  end
  total = total + math3d.dist(samples[#samples].pos, samples[1].pos)

  for i = 1, #samples do
    local forward, right, normal = frameFor(samples, i, lateral, height)
    samples[i].forward = forward
    samples[i].right = right
    samples[i].normal = normal
    samples[i].curvature = curvatureAt(samples, i)
    samples[i].signedCurvature = signedCurvatureAt(samples, i)
  end
  applyProgressFallbackOffsets(samples, lateral, height)
  local racingLine = applyRacingLineOffsets(samples, runtimeProfile, sampleSpacingM)
  updateRacingLineCurvature(samples, racingLine.active == true)

  logger.write('TRACK_SAMPLER_OK samples=' .. tostring(#samples) ..
    ' totalLengthM=' .. tostring(total) ..
    ' placementMode=' .. tostring(source) ..
    ' degraded=' .. tostring(degraded) ..
    ' trackLateralM=' .. tostring(lateral) ..
    ' roadHeightM=' .. tostring(height) ..
    ' trackLengthHintM=' .. tostring(trackLengthHintM) ..
    ' sampleSpacingM=' .. tostring(sampleSpacingM) ..
    ' racingLineActive=' .. tostring(racingLine.active == true) ..
    ' racingLineSamples=' .. tostring(racingLine.activeCount or 0) ..
    ' racingLineMaxOffsetM=' .. tostring(racingLine.maxAbsOffsetM or 0) ..
    ' racingLineChatterSuppressed=' .. tostring(racingLine.chatterSuppressed or 0) ..
    ' racingLineFallbackReason=' .. tostring(racingLine.fallbackReason or '') ..
    ' linePlacementMode=' .. tostring(racingLine.linePlacementMode or ''))

  return {
    samples = samples,
    totalLengthM = total,
    source = source,
    placementMode = source,
    degraded = degraded,
    visibleAheadM = trackValue(runtimeProfile, 'visible_ahead_m', settings.VISIBLE_AHEAD_M),
    visibleBehindM = trackValue(runtimeProfile, 'visible_behind_m', settings.VISIBLE_BEHIND_M),
    tileWidthM = trackValue(runtimeProfile, 'tile_width_m', settings.TILE_WIDTH_M),
    tileLengthM = trackValue(runtimeProfile, 'tile_length_m', settings.TILE_LENGTH_M),
    trackLateralM = lateral,
    roadHeightM = height,
    racingLine = racingLine,
    trackLengthHintM = trackLengthHintM,
    sampleSpacingM = sampleSpacingM,
  }
end

function M.distanceAhead(tileS, carS, totalLength)
  local d = tileS - carS
  if d < -totalLength * 0.5 then d = d + totalLength end
  if d > totalLength * 0.5 then d = d - totalLength end
  return d
end

function M.forwardDistanceAhead(tileS, carS, totalLength)
  if not totalLength or totalLength <= 0 then return 0 end
  local d = (tileS - carS) % totalLength
  if d < 0 then d = d + totalLength end
  return d
end

local function sortByDistanceAhead(a, b)
  return (tonumber(a and a.distanceAheadM) or math.huge) < (tonumber(b and b.distanceAheadM) or math.huge)
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function lerpVec(a, b, t)
  if not a then return b end
  if not b then return a end
  return math3d.vec(
    lerp(math3d.x(a), math3d.x(b), t),
    lerp(math3d.y(a), math3d.y(b), t),
    lerp(math3d.z(a), math3d.z(b), t)
  )
end

local function lineStartCenterDistance(profile)
  local startM = math.max(0.0, finiteNumber(settings.LINE_START_M, 0.0))
  local lengthM = math.max(0.2, finiteNumber(profile and profile.tileLengthM, settings.TILE_LENGTH_M))
  return startM + lengthM * 0.5
end

local function windowStepM(profile, stepOverrideM)
  local override = tonumber(stepOverrideM)
  if override and override > 0 then return math.max(0.5, override) end
  return math.max(0.5, finiteNumber(profile and profile.sampleSpacingM, settings.PROFILE_SPACING_M))
end

local function brakeLookaheadStepM(profile, aheadM)
  local visualStep = windowStepM(profile)
  local brakeStep = math.max(0.5, finiteNumber(settings.BRAKE_LOOKAHEAD_SPACING_M, visualStep))
  local ahead = math.max(0.0, finiteNumber(aheadM, 0.0))
  local maxTiles = math.max(0.0, finiteNumber(settings.BRAKE_LOOKAHEAD_MAX_TILES, 0.0))
  local maxTileStep = ahead > 0.0 and maxTiles > 0.0 and ahead / maxTiles or 0.0
  return math.max(visualStep, brakeStep, maxTileStep)
end

local function segmentForTargetS(profile, targetS, cursor)
  local samples = profile and profile.samples
  local total = finiteNumber(profile and profile.totalLengthM, 0.0)
  local count = #(samples or {})
  if count < 2 or total <= 0 then return nil, nil, 0.0, 0.0, cursor end

  cursor = math.max(1, math.min(count, math.floor(finiteNumber(cursor, 1.0) + 0.5)))
  local cursorSample = samples[cursor]
  if cursorSample and targetS < finiteNumber(cursorSample.s, 0.0) then cursor = 1 end

  local guard = 0
  while guard < count do
    local left = samples[cursor]
    local right = samples[cursor + 1] or samples[1]
    local leftS = finiteNumber(left and left.s, 0.0)
    local rightS = cursor < count and finiteNumber(right and right.s, total) or total
    if targetS >= leftS and targetS <= rightS then
      return left, right, leftS, rightS, cursor
    end
    if targetS < leftS then break end
    cursor = cursor + 1
    if cursor > count then cursor = 1 end
    guard = guard + 1
  end

  for index = 1, count do
    local left = samples[index]
    local right = samples[index + 1] or samples[1]
    local leftS = finiteNumber(left and left.s, 0.0)
    local rightS = index < count and finiteNumber(right and right.s, total) or total
    if targetS >= leftS and targetS <= rightS then
      return left, right, leftS, rightS, index
    end
  end

  return samples[count], samples[1], finiteNumber(samples[count] and samples[count].s, 0.0), total, count
end

local function sampleAtDistanceAheadCursor(profile, carS, distanceAheadM, sourceName, cursor)
  if not profile or not profile.samples or not profile.totalLengthM or profile.totalLengthM <= 0 then return nil end
  local samples = profile.samples
  if #samples < 2 then return nil end

  local total = profile.totalLengthM
  local targetS = (carS + distanceAheadM) % total
  local left, right, leftS, rightS, nextCursor = segmentForTargetS(profile, targetS, cursor)
  if not left or not right then return nil, cursor end

  local span = math.max(0.001, rightS - leftS)
  local t = math.max(0.0, math.min(1.0, (targetS - leftS) / span))
  local centerPos = lerpVec(left.centerPos or left.pos, right.centerPos or right.pos, t)
  if not centerPos or not finiteVec(centerPos) then return nil end

  local forward = math3d.norm(lerpVec(left.forward, right.forward, t), math3d.norm(math3d.sub(right.pos, left.pos), math3d.vec(0, 0, 1)))
  local normal = math3d.norm(lerpVec(left.normal, right.normal, t), fallbackNormal(forward))
  local rightVec = math3d.norm(math3d.cross(normal, forward), math3d.vec(1, 0, 0))
  local racingLineOffsetM = lerp(finiteNumber(left.racingLineOffsetM, 0), finiteNumber(right.racingLineOffsetM, 0), t)
  local leftEndpointActive = left.racingLineActive == true and left.linePlacementMode == 'lateral_optimal'
  local rightEndpointActive = right.racingLineActive == true and right.linePlacementMode == 'lateral_optimal'
  local interpolatedRacingLineActive = settings.RACING_LINE_ENABLED == true and leftEndpointActive and rightEndpointActive
  local interpolationFallbackReason = 'disabled'
  if settings.RACING_LINE_ENABLED == true then
    if interpolatedRacingLineActive then
      interpolationFallbackReason = left.racingLineFallbackReason or right.racingLineFallbackReason or 'active'
    elseif left.racingLineActive ~= right.racingLineActive or left.linePlacementMode ~= right.linePlacementMode then
      interpolationFallbackReason = 'interpolation_metadata_disagreement'
    else
      interpolationFallbackReason = left.racingLineFallbackReason or right.racingLineFallbackReason or 'centerline_fallback'
    end
  end
  local linePlacementMode = interpolatedRacingLineActive and 'lateral_optimal' or 'centerline_fallback'
  local lineOffsetScale = interpolatedRacingLineActive and
    lerp(finiteNumber(left.lineOffsetScale, 1), finiteNumber(right.lineOffsetScale, 1), t) or 0.0
  local centerRight = math3d.norm(lerpVec(left.centerRight or left.right, right.centerRight or right.right, t), rightVec)
  local fullLinePos = interpolatedRacingLineActive and lerpVec(left.pos, right.pos, t) or centerPos
  local curvature = lerp(finiteNumber(left.curvature, 0), finiteNumber(right.curvature, 0), t)
  local centerCurvature = lerp(finiteNumber(left.centerCurvature, left.curvature or 0),
    finiteNumber(right.centerCurvature, right.curvature or 0), t)
  local centerSignedCurvature = lerp(finiteNumber(left.centerSignedCurvature, left.signedCurvature or 0),
    finiteNumber(right.centerSignedCurvature, right.signedCurvature or 0), t)
  local lineCurvature = lerp(finiteNumber(left.lineCurvature, left.curvature or 0),
    finiteNumber(right.lineCurvature, right.curvature or 0), t)
  local lineSignedCurvature = lerp(finiteNumber(left.lineSignedCurvature, left.signedCurvature or 0),
    finiteNumber(right.lineSignedCurvature, right.signedCurvature or 0), t)
  local brakingCurvature = math.max(
    math.abs(lerp(finiteNumber(left.brakingCurvature, left.curvature or 0),
      finiteNumber(right.brakingCurvature, right.curvature or 0), t)),
    math.abs(curvature),
    math.abs(centerCurvature),
    math.abs(lineCurvature))
  local nearOffsetScale = settings.RACING_LINE_ENABLED == true and nearCarOffsetScale(distanceAheadM) or 0.0
  local centerToFullLine = math3d.sub(fullLinePos, centerPos)
  local dynamicLineOffsetM = settings.RACING_LINE_ENABLED == true and
    math3d.dot(centerToFullLine, centerRight) * nearOffsetScale or 0.0
  local pos = settings.RACING_LINE_ENABLED == true and
    math3d.add(centerPos, math3d.mul(centerToFullLine, nearOffsetScale)) or centerPos
  if not pos or not finiteVec(pos) then return nil end
  local targetSpeedKph = lerp(finiteNumber(left.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH), finiteNumber(right.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH), t)
  local brakeProfileTargetSpeedKph = lerp(
    finiteNumber(left.brakeProfileTargetSpeedKph, finiteNumber(left.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH)),
    finiteNumber(right.brakeProfileTargetSpeedKph, finiteNumber(right.targetSpeedKph, settings.MAX_TARGET_SPEED_KPH)),
    t)
  local straightSpeedCap = (left.straightSpeedCap == true and right.straightSpeedCap == true) or
    targetSpeedKph >= finiteNumber(settings.MAX_TARGET_SPEED_KPH, 315.0) - 0.25
  local brakeProfileSpeedCap = (left.brakeProfileSpeedCap == true and right.brakeProfileSpeedCap == true) or
    brakeProfileTargetSpeedKph >= finiteNumber(settings.MAX_TARGET_SPEED_KPH, 315.0) - 0.25
  local brakeProfileEnvelopeLimited = left.brakeProfileEnvelopeLimited == true or right.brakeProfileEnvelopeLimited == true
  local brakeProfileReductionKph = lerp(
    finiteNumber(left.brakeProfileReductionKph, 0.0),
    finiteNumber(right.brakeProfileReductionKph, 0.0),
    t)
  local transferClassScale = math3d.clamp(
    lerp(finiteNumber(left.transferClassScale, 0.0), finiteNumber(right.transferClassScale, 0.0), t),
    0.0,
    1.0)
  local momentTransferClassScale = math3d.clamp(
    lerp(finiteNumber(left.momentTransferClassScale, transferClassScale), finiteNumber(right.momentTransferClassScale, transferClassScale), t),
    0.0,
    1.0)
  local brakeTransferScale = math3d.clamp(
    lerp(finiteNumber(left.brakeTransferScale, transferClassScale), finiteNumber(right.brakeTransferScale, transferClassScale), t),
    0.0,
    1.0)
  local aeroTransferScale = math3d.clamp(
    lerp(finiteNumber(left.aeroTransferScale, transferClassScale), finiteNumber(right.aeroTransferScale, transferClassScale), t),
    0.0,
    1.0)
  local cueTransferClassScale = math3d.clamp(
    lerp(finiteNumber(left.cueTransferClassScale, transferClassScale), finiteNumber(right.cueTransferClassScale, transferClassScale), t),
    0.0,
    1.0)
  local defaultBrakeCapacityMps2 = settings.DEFAULT_BRAKE_G * 9.80665
  local baseBrakeCapacityMps2 = lerp(finiteNumber(left.baseBrakeCapacityMps2, finiteNumber(left.brakeCapacityMps2, defaultBrakeCapacityMps2)),
    finiteNumber(right.baseBrakeCapacityMps2, finiteNumber(right.brakeCapacityMps2, defaultBrakeCapacityMps2)),
    t)
  local brakeCapacityMps2 = lerp(
    finiteNumber(left.brakeCapacityMps2, defaultBrakeCapacityMps2),
    finiteNumber(right.brakeCapacityMps2, defaultBrakeCapacityMps2),
    t)
  local brakeSpeedAeroFactor = lerp(finiteNumber(left.brakeSpeedAeroFactor, 1.0), finiteNumber(right.brakeSpeedAeroFactor, 1.0), t)
  local dynamicConfidence = math3d.clamp(
    lerp(finiteNumber(left.dynamicConfidence, 0.70), finiteNumber(right.dynamicConfidence, 0.70), t),
    0.0,
    1.0)
  local capabilityClass = left.capabilityClass or right.capabilityClass or 'road'

  return {
    index = 'line_start',
    progress = targetS / total,
    s = targetS,
    centerPos = centerPos,
    pos = pos,
    forward = forward,
    right = rightVec,
    normal = normal,
    centerForward = lerpVec(left.centerForward or left.forward, right.centerForward or right.forward, t),
    centerRight = centerRight,
    centerNormal = lerpVec(left.centerNormal or left.normal, right.centerNormal or right.normal, t),
    lineForward = lerpVec(left.lineForward or left.forward, right.lineForward or right.forward, t),
    lineRight = lerpVec(left.lineRight or left.right, right.lineRight or right.right, t),
    lineNormal = lerpVec(left.lineNormal or left.normal, right.lineNormal or right.normal, t),
    curvature = curvature,
    signedCurvature = lerp(finiteNumber(left.signedCurvature, 0), finiteNumber(right.signedCurvature, 0), t),
    brakingCurvature = brakingCurvature,
    centerCurvature = centerCurvature,
    centerSignedCurvature = centerSignedCurvature,
    lineCurvature = lineCurvature,
    lineSignedCurvature = lineSignedCurvature,
    sequenceAdvisoryRatio = lerp(finiteNumber(left.sequenceAdvisoryRatio, 0), finiteNumber(right.sequenceAdvisoryRatio, 0), t),
    instabilityAdvisoryRatio = lerp(finiteNumber(left.instabilityAdvisoryRatio, 0), finiteNumber(right.instabilityAdvisoryRatio, 0), t),
    knowledgeBaseAdvisoryRatio = lerp(finiteNumber(left.knowledgeBaseAdvisoryRatio, 0), finiteNumber(right.knowledgeBaseAdvisoryRatio, 0), t),
    knowledgeBaseRisk = lerp(finiteNumber(left.knowledgeBaseRisk, 0), finiteNumber(right.knowledgeBaseRisk, 0), t),
    knowledgeBaseConfidence = lerp(finiteNumber(left.knowledgeBaseConfidence, 0), finiteNumber(right.knowledgeBaseConfidence, 0), t),
    knowledgeBaseTargetScale = lerp(finiteNumber(left.knowledgeBaseTargetScale, 1), finiteNumber(right.knowledgeBaseTargetScale, 1), t),
    knowledgeBaseSource = left.knowledgeBaseSource or right.knowledgeBaseSource or 'none',
    knowledgeBaseMemoryKey = left.knowledgeBaseMemoryKey or right.knowledgeBaseMemoryKey or '',
    straightSpeedCap = straightSpeedCap,
    racingLineOffsetM = racingLineOffsetM,
    dynamicLineOffsetM = dynamicLineOffsetM,
    lineOffsetScale = lineOffsetScale,
    nearOffsetScale = nearOffsetScale,
    racingLineActive = interpolatedRacingLineActive,
    racingLineFallbackReason = interpolationFallbackReason,
    linePlacementMode = linePlacementMode,
    baseTargetSpeedKph = lerp(finiteNumber(left.baseTargetSpeedKph, settings.MAX_TARGET_SPEED_KPH), finiteNumber(right.baseTargetSpeedKph, settings.MAX_TARGET_SPEED_KPH), t),
    targetSpeedKph = targetSpeedKph,
    brakeProfileTargetSpeedKph = brakeProfileTargetSpeedKph,
    brakeProfileSpeedCap = brakeProfileSpeedCap,
    brakeProfileLimited = brakeProfileTargetSpeedKph < targetSpeedKph - 0.25,
    brakeProfileEnvelopeLimited = brakeProfileEnvelopeLimited,
    brakeProfileReductionKph = brakeProfileReductionKph,
    baseBrakeCapacityMps2 = baseBrakeCapacityMps2,
    brakeCapacityMps2 = brakeCapacityMps2,
    brakeSpeedAeroFactor = brakeSpeedAeroFactor,
    transferClassScale = transferClassScale,
    momentTransferClassScale = momentTransferClassScale,
    brakeTransferScale = brakeTransferScale,
    aeroTransferScale = aeroTransferScale,
    cueTransferClassScale = cueTransferClassScale,
    capabilityClass = capabilityClass,
    dynamicConfidence = dynamicConfidence,
    placementMode = profile.placementMode or left.placementMode or right.placementMode,
    tileWidthM = finiteNumber(profile.tileWidthM, settings.TILE_WIDTH_M),
    tileLengthM = finiteNumber(profile.tileLengthM, settings.TILE_LENGTH_M),
    distanceAheadM = distanceAheadM,
    windowSource = tostring(sourceName or 'spline_progress') .. '_line_start',
    virtualLineStartTile = true,
  }, nextCursor
end

local function sampleAtDistanceAhead(profile, carS, distanceAheadM, sourceName)
  return sampleAtDistanceAheadCursor(profile, carS, distanceAheadM, sourceName, nil)
end

local function appendFixedStepWindowTiles(out, profile, carS, sourceName, startDistanceM, endDistanceM, cursor, stepOverrideM)
  local step = windowStepM(profile, stepOverrideM)
  local distanceAheadM = finiteNumber(startDistanceM, 0.0)
  local endM = finiteNumber(endDistanceM, distanceAheadM)
  local maxTiles = math.min(4000, math.max(0, math.floor(((endM - distanceAheadM) / step) + 2.0)))
  local guard = 0
  while distanceAheadM <= endM + 0.001 and guard < maxTiles do
    local tile
    tile, cursor = sampleAtDistanceAheadCursor(profile, carS, distanceAheadM, sourceName, cursor)
    if tile then
      tile.index = 'fixed_' .. tostring(#out + 1)
      tile.virtualLineStartTile = false
      tile.windowSource = tostring(sourceName or 'spline_progress') .. '_fixed_step'
      out[#out + 1] = tile
    end
    distanceAheadM = distanceAheadM + step
    guard = guard + 1
  end
  return cursor
end

local function collectWindow(profile, carS, sourceName, aheadOverrideM, behindOverrideM, includeLineStart, stepOverrideM)
  local out = {}
  if not profile or not profile.samples or not profile.totalLengthM or profile.totalLengthM <= 0 then return out end
  local behind = tonumber(behindOverrideM) or tonumber(profile.visibleBehindM) or settings.VISIBLE_BEHIND_M
  local ahead = tonumber(aheadOverrideM) or tonumber(profile.visibleAheadM) or settings.VISIBLE_AHEAD_M
  local firstCenter = lineStartCenterDistance(profile)
  local startDistance = behind > 0 and -behind or (includeLineStart ~= false and firstCenter or 0.0)
  local cursor = nil
  if includeLineStart ~= false then
    local firstTile
    if firstCenter <= ahead then
      firstTile, cursor = sampleAtDistanceAheadCursor(profile, carS, firstCenter, sourceName, cursor)
    end
    if firstTile then out[#out + 1] = firstTile end
    startDistance = math.max(startDistance, firstCenter + windowStepM(profile, stepOverrideM))
  end
  appendFixedStepWindowTiles(out, profile, carS, sourceName, startDistance, ahead, cursor, stepOverrideM)
  table.sort(out, sortByDistanceAhead)
  return out
end

local function nearestSampleIndex(profile, car)
  local carPos = car and car.pos or car
  local carForward = car and car.forward or nil
  if not profile or not profile.samples or not carPos then return nil end
  local nearest = nil
  local nearestScore = math.huge
  for index, sample in ipairs(profile.samples) do
    local samplePos = sample.centerPos or sample.pos
    if samplePos then
      local offset = math3d.sub(samplePos, carPos)
      local distance = math3d.dist(samplePos, carPos)
      local alignmentPenalty = 0.0
      local behindPenalty = 0.0
      if carForward then
        local sampleForward = sample.centerForward or sample.forward
        if sampleForward then
          local alignment = math.max(-1.0, math.min(1.0, math3d.dot(sampleForward, carForward)))
          alignmentPenalty = math.max(0.0, 1.0 - alignment) * 18.0
        end
        local ahead = math3d.dot(offset, carForward)
        if ahead < -2.0 then behindPenalty = math.min(30.0, math.abs(ahead) * 1.5) end
      end
      local score = distance + alignmentPenalty + behindPenalty
      if score < nearestScore then
        nearest = index
        nearestScore = score
      end
    end
  end
  return nearest
end

function M.tileWindow(profile, carProgress)
  if not profile or not profile.totalLengthM or profile.totalLengthM <= 0 then return {} end
  local progress = tonumber(carProgress)
  if not progress then return {} end
  local carS = (progress % 1.0) * profile.totalLengthM
  return collectWindow(profile, carS, 'spline_progress')
end

function M.tileWindowAhead(profile, carProgress, aheadM, sourceName)
  if not profile or not profile.totalLengthM or profile.totalLengthM <= 0 then return {} end
  local progress = tonumber(carProgress)
  if not progress then return {} end
  local carS = (progress % 1.0) * profile.totalLengthM
  return collectWindow(profile, carS, sourceName or 'spline_brake_lookahead', aheadM, 0.0, false, brakeLookaheadStepM(profile, aheadM))
end

function M.tileWindowNearCar(profile, car)
  local index = nearestSampleIndex(profile, car)
  if not index then return {} end
  local sample = profile.samples[index]
  if not sample then return {} end
  return collectWindow(profile, sample.s or 0, 'car_position')
end

function M.tileWindowNearCarAhead(profile, car, aheadM, sourceName)
  local index = nearestSampleIndex(profile, car)
  if not index then return {} end
  local sample = profile.samples[index]
  if not sample then return {} end
  return collectWindow(profile, sample.s or 0, sourceName or 'car_position_brake_lookahead', aheadM, 0.0, false, brakeLookaheadStepM(profile, aheadM))
end

return M
