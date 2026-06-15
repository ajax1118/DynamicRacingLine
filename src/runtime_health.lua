local logger = require('src/logger')
local settings = require('src/settings')

local M = {}
local healthCache = {
  nextAt = 0.0,
  lastSignature = '',
}

local function nowSeconds()
  return os and os.clock and os.clock() or 0.0
end

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function boolText(value)
  return value == true and 'true' or 'false'
end

function M.report(state)
  state = state or {}
  local predictiveCornerCount = math.max(0, math.floor(finiteNumber(state.predictiveCornerCount, 0) + 0.5))
  local tileCount = math.max(0, math.floor(finiteNumber(state.tileCount, 0) + 0.5))
  local guidanceSessionReady = state.guidanceSessionReady == true
  local renderStatus = tostring(state.renderStatus or 'unknown')
  local cueState = tostring(state.cueState or 'none')
  local lineCoreStatus = tostring(state.lineCoreStatus or 'unknown')
  local lineCoreDataConfidence = finiteNumber(state.lineCoreDataConfidence, 0.0)
  local lineCoreStale = state.lineCoreStale == true
  local learningState = tostring(state.learningState or 'unknown')
  local signature = table.concat({
    boolText(state.enabled == true),
    boolText(state.initialized == true),
    tostring(state.status or ''),
    boolText(guidanceSessionReady),
    tostring(predictiveCornerCount),
    renderStatus,
    tostring(tileCount),
    cueState,
    lineCoreStatus,
    string.format('%.2f', lineCoreDataConfidence),
    boolText(lineCoreStale),
    learningState,
  }, ':')

  local now = nowSeconds()
  local interval = math.max(0.25, finiteNumber(settings.RUNTIME_HEALTH_INTERVAL_S, 2.0))
  if signature == healthCache.lastSignature and now < healthCache.nextAt then
    return {
      guidanceSessionReady = guidanceSessionReady,
      predictiveCornerCount = predictiveCornerCount,
      renderStatus = renderStatus,
      tileCount = tileCount,
      cueState = cueState,
      lineCoreStatus = lineCoreStatus,
      lineCoreDataConfidence = lineCoreDataConfidence,
      lineCoreStale = lineCoreStale,
      learningState = learningState,
    }
  end

  healthCache.lastSignature = signature
  healthCache.nextAt = now + interval
  logger.write('DRL_RUNTIME_HEALTH enabled=' .. boolText(state.enabled == true) ..
    ' initialized=' .. boolText(state.initialized == true) ..
    ' status=' .. tostring(state.status or 'unknown') ..
    ' guidanceSessionReady=' .. boolText(guidanceSessionReady) ..
    ' predictiveCornerCount=' .. tostring(predictiveCornerCount) ..
    ' renderStatus=' .. renderStatus ..
    ' tileCount=' .. tostring(tileCount) ..
    ' cueState=' .. cueState ..
    ' lineCoreStatus=' .. lineCoreStatus ..
    ' lineCoreDataConfidence=' .. string.format('%.2f', lineCoreDataConfidence) ..
    ' lineCoreStale=' .. boolText(lineCoreStale) ..
    ' learningState=' .. learningState ..
    ' fallbackLineActive=' .. boolText(state.fallbackLineActive == true) ..
    ' tileRecoveryActive=' .. boolText(state.tileRecoveryActive == true) ..
    ' hudDrawCount=' .. tostring(math.floor(finiteNumber(state.hudDrawCount, 0) + 0.5)) ..
    ' finalHudDrawCount=' .. tostring(math.floor(finiteNumber(state.finalHudDrawCount, 0) + 0.5)) ..
    ' frameId=' .. tostring(math.floor(finiteNumber(state.frameId, 0) + 0.5)) ..
    ' fps=' .. string.format('%.1f', finiteNumber(state.fps, 0.0)))
  return {
    guidanceSessionReady = guidanceSessionReady,
    predictiveCornerCount = predictiveCornerCount,
    renderStatus = renderStatus,
    tileCount = tileCount,
    cueState = cueState,
    lineCoreStatus = lineCoreStatus,
    lineCoreDataConfidence = lineCoreDataConfidence,
    lineCoreStale = lineCoreStale,
    learningState = learningState,
  }
end

M.healthCache = healthCache

return M
