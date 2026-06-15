-- DynamicRacingLine line_core/visibility_guard.lua
-- Renderer safety pass: lift tiles and prevent renderer-active/zero-tile state.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local M = {}

function M.apply(guidance, opts)
  opts = opts or {}
  if not guidance or not guidance.window then return guidance end
  local tiles = guidance.window.tiles or {}
  for _, t in ipairs(tiles) do
    if t.world then t.world = { x = U.x(t.world), y = U.y(t.world) + (opts.extraLiftM or Config.QUAD_EXTRA_LIFT_M), z = U.z(t.world) } end
    t.alpha = math.max(t.alpha or 1, Config.MIN_RENDER_ALPHA)
  end
  if #tiles == 0 then guidance.window.ok = false; guidance.window.reason = 'visibility_guard_zero_tiles' end
  return guidance
end

return M
