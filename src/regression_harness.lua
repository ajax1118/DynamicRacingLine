local logger = require('src/logger')
local settings = require('src/settings')

local M = {}
local nextRecordAt = 0.0

local function nowSeconds()
  return os and os.clock and os.clock() or 0.0
end

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function firstBrakeTile(tiles)
  for _, tile in ipairs(tiles or {}) do
    local kind = tostring(tile.kind or '')
    if kind == 'yellow' or kind == 'red' then return tile end
  end
  return nil
end

local function lineSmoothnessScore(tiles)
  local previous = nil
  local previousStep = nil
  local maxJerk = 0.0
  local count = 0
  for _, tile in ipairs(tiles or {}) do
    local offset = finiteNumber(tile.dynamicLineOffsetM, finiteNumber(tile.racingLineOffsetM, 0.0))
    if previous then
      local step = offset - previous
      if previousStep then maxJerk = math.max(maxJerk, math.abs(step - previousStep)) end
      previousStep = step
      count = count + 1
    end
    previous = offset
  end
  if count <= 1 then return 1.0 end
  return math.max(0.0, 1.0 - math.min(maxJerk / 0.18, 1.0))
end

function M.evaluateBrakeCue(tiles, car)
  local tile = firstBrakeTile(tiles)
  if not tile then
    return {
      brakeCueErrorM = 0.0,
      cueState = 'green',
      targetSpeedKph = finiteNumber(car and car.speedKmh, 0.0),
    }
  end
  local brakeZoneStart = tonumber(tile.brakeZoneStartDistanceM)
  local brakeCueErrorM = nil
  if brakeZoneStart ~= nil and brakeZoneStart == brakeZoneStart and brakeZoneStart ~= math.huge and brakeZoneStart ~= -math.huge then
    brakeCueErrorM = brakeZoneStart - finiteNumber(tile.distanceAheadM, 0.0)
  end
  return {
    brakeCueErrorM = brakeCueErrorM,
    brakeCueMissingZoneStart = brakeCueErrorM == nil,
    cueState = tostring(tile.kind or 'unknown'),
    targetSpeedKph = finiteNumber(tile.brakeTargetSpeedKph, finiteNumber(tile.targetSpeedKph, 0.0)),
    requiredBrakeDistanceM = finiteNumber(tile.requiredBrakeDistanceM, 0.0),
  }
end

function M.recordFrame(state)
  if settings.REGRESSION_HARNESS_ENABLED ~= true then return nil end
  state = state or {}
  local now = nowSeconds()
  local interval = math.max(0.25, finiteNumber(settings.REGRESSION_HARNESS_INTERVAL_S, 2.0))
  if now < nextRecordAt then return nil end
  nextRecordAt = now + interval
  local car = state.car or {}
  local tiles = state.tiles or {}
  local brake = M.evaluateBrakeCue(tiles, car)
  local smoothness = lineSmoothnessScore(tiles)
  local replayableTelemetry = {
    speedKph = finiteNumber(car.speedKmh, 0.0),
    brake = finiteNumber(car.brake, 0.0),
    gas = finiteNumber(car.gas, 0.0),
    splinePosition = finiteNumber(car.splinePosition, 0.0),
    cueState = brake.cueState,
  }
  logger.write('DRL_REGRESSION_FRAME replayableTelemetry=' ..
    'speedKph:' .. string.format('%.1f', replayableTelemetry.speedKph) ..
    ',brake:' .. string.format('%.3f', replayableTelemetry.brake) ..
    ',gas:' .. string.format('%.3f', replayableTelemetry.gas) ..
    ',spline:' .. string.format('%.6f', replayableTelemetry.splinePosition) ..
    ',cueState:' .. replayableTelemetry.cueState ..
    ' brakeCueErrorM=' .. string.format('%.2f', brake.brakeCueErrorM) ..
    ' lineSmoothnessScore=' .. string.format('%.3f', smoothness) ..
    ' tileCount=' .. tostring(#tiles) ..
    ' displayState=' .. tostring(state.displayState or 'unknown'))
  return {
    replayableTelemetry = replayableTelemetry,
    brakeCueErrorM = brake.brakeCueErrorM,
    lineSmoothnessScore = smoothness,
  }
end

return M
