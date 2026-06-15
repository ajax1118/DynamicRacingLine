local settings = require('src/settings')

local M = {}
local FRAME_BUDGET_CACHE = {}
local frameWorkCount = {}
local currentFrameId = -1
local monotonicFrameId = 0

local function nowSeconds()
  return os and os.clock and os.clock() or 0.0
end

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function budgetKey(name, key)
  return tostring(name or 'work') .. ':' .. tostring(key or 'default')
end

local function frameId()
  if currentFrameId < 0 then
    monotonicFrameId = monotonicFrameId + 1
    currentFrameId = monotonicFrameId
    frameWorkCount = {}
  end
  return currentFrameId
end

function M.beginFrame(frameKey)
  local nextId = tonumber(frameKey)
  if not nextId or nextId ~= nextId or nextId == math.huge or nextId == -math.huge then
    monotonicFrameId = monotonicFrameId + 1
    nextId = monotonicFrameId
  else
    nextId = math.floor(nextId + 0.5)
    if nextId <= monotonicFrameId then
      monotonicFrameId = monotonicFrameId + 1
      nextId = monotonicFrameId
    else
      monotonicFrameId = nextId
    end
  end
  if nextId ~= currentFrameId then
    currentFrameId = nextId
    frameWorkCount = {}
  end
  return currentFrameId
end

function M.shouldRun(name, key, options)
  options = options or {}
  local id = frameId()
  if id ~= currentFrameId then
    currentFrameId = id
    frameWorkCount = {}
  end
  local fullKey = budgetKey(name, key)
  local entry = FRAME_BUDGET_CACHE[fullKey] or {}
  local now = nowSeconds()
  local minIntervalS = math.max(0.0, finiteNumber(options.minIntervalS, settings.FRAME_BUDGET_DEFAULT_MIN_INTERVAL_S))
  local maxWorkPerFrame = math.max(1, math.floor(finiteNumber(options.maxWorkPerFrame, settings.FRAME_BUDGET_MAX_WORK_PER_FRAME) + 0.5))
  local bucket = tostring(name or 'work')
  local used = frameWorkCount[bucket] or 0
  if entry.lastRunAt and now - entry.lastRunAt < minIntervalS then
    return false, 'min_interval'
  end
  if used >= maxWorkPerFrame then
    return false, 'maxWorkPerFrame'
  end
  frameWorkCount[bucket] = used + 1
  entry.lastRunAt = now
  FRAME_BUDGET_CACHE[fullKey] = entry
  return true, 'run'
end

function M.remember(name, key, value)
  local fullKey = budgetKey(name, key)
  local entry = FRAME_BUDGET_CACHE[fullKey] or {}
  entry.value = value
  entry.savedAt = nowSeconds()
  FRAME_BUDGET_CACHE[fullKey] = entry
  return value
end

function M.getCached(name, key)
  local entry = FRAME_BUDGET_CACHE[budgetKey(name, key)]
  return entry and entry.value or nil
end

M.FRAME_BUDGET_CACHE = FRAME_BUDGET_CACHE
M.budgetKey = budgetKey
M.frameId = frameId

return M
