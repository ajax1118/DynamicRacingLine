local M = {}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function modeText(enabled, active)
  if enabled ~= true then return 'disabled' end
  return active == true and 'active' or 'idle'
end

function M.renderState(state)
  state = state or {}
  local tileCount = math.max(0, math.floor(finiteNumber(state.tileCount, 0) + 0.5))
  local enabled = state.enabled == true
  local profileReady = state.profileReady == true
  local fallbackActive = state.fallbackLineActive == true
  local rendererMode = modeText(enabled, profileReady and tileCount > 0)
  local hudMode = modeText(enabled, finiteNumber(state.hudDrawCount, 0) > 0 or finiteNumber(state.finalHudDrawCount, 0) > 0)
  local fallbackMode = modeText(enabled, fallbackActive)
  local cspAppState = enabled and tostring(state.status or 'unknown') or 'disabled'
  local lineVisibleReason = 'tiles_ready'
  if not enabled then
    lineVisibleReason = 'app_disabled'
  elseif not profileReady and not fallbackActive then
    lineVisibleReason = 'profile_not_ready'
  elseif tileCount <= 0 and not fallbackActive then
    lineVisibleReason = 'no_tiles'
  elseif fallbackActive then
    lineVisibleReason = 'fallback_line'
  end
  local singleDisplayState = tostring(cspAppState) .. ':' .. tostring(lineVisibleReason) ..
    ':renderer=' .. rendererMode .. ':hud=' .. hudMode .. ':fallback=' .. fallbackMode
  return {
    singleDisplayState = singleDisplayState,
    rendererMode = rendererMode,
    hudMode = hudMode,
    fallbackMode = fallbackMode,
    cspAppState = cspAppState,
    lineVisibleReason = lineVisibleReason,
    tileCount = tileCount,
  }
end

return M
