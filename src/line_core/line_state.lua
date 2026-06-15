-- DynamicRacingLine line_core/line_state.lua
-- Keeps active/generated and fallback/centerline states from being interpolated together.

local M = { epoch = 0, mode = 'empty', lastGood = nil }

local function modeOf(g)
  if not g or not g.ok then return 'fallback' end
  if g.reason and tostring(g.reason):find('fallback', 1, true) then return 'fallback' end
  return 'active'
end

function M.accept(g)
  local m = modeOf(g)
  if m ~= M.mode then M.epoch = M.epoch + 1; M.mode = m end
  if g then g.stateEpoch = M.epoch; g.stateMode = M.mode end
  if g and g.ok then M.lastGood = g elseif M.lastGood then return M.lastGood end
  return g
end

function M.reset() M.epoch = M.epoch + 1; M.mode = 'empty'; M.lastGood = nil end
function M.shouldInterpolate(a, b) return a and b and a.stateEpoch == b.stateEpoch and a.stateMode == b.stateMode end

return M
