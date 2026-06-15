-- DynamicRacingLine line_core/surface_mapper.lua
-- Alias layer for risk_map; kept for integration variants that call SurfaceMapper.

local RiskMap = require('src.line_core.risk_map')
local M = {}

function M.build(frame, opts) return RiskMap.build(frame, opts or {}) end
function M.at(map, index) return RiskMap.at(map, index) end
function M.applyToBoundary(boundary, map)
  if not boundary or not boundary.samples then return boundary end
  for i, b in ipairs(boundary.samples) do
    local r = RiskMap.at(map, i)
    local centerGrip = tonumber(r.centerGrip or r.surfaceGrip or r.grip) or 1.0
    local leftRisk = tonumber(r.leftRisk or r.risk) or 0.0
    local rightRisk = tonumber(r.rightRisk or r.risk) or 0.0
    local wallRisk = tonumber(r.wallRisk) or (r.wall and 1.0 or 0.0)
    b.surfaceGrip = centerGrip
    b.surfaceRiskLeft = leftRisk
    b.surfaceRiskRight = rightRisk
    b.wallRisk = wallRisk
    if wallRisk > 0.45 or leftRisk > 0.75 or rightRisk > 0.75 then
      b.confidence = math.min(b.confidence or 0.35, 0.45)
      b.usableLeft = math.max(0.15, (b.usableLeft or 0.15) - leftRisk * 0.45 - wallRisk * 0.35)
      b.usableRight = math.max(0.15, (b.usableRight or 0.15) - rightRisk * 0.45 - wallRisk * 0.35)
    end
  end
  return boundary
end

return M
