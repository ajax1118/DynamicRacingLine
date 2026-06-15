-- DynamicRacingLine line_core/debug_hud.lua
-- Optional HUD/debug strings. The HUD path can prove line state even if 3D render is hidden.

local Diagnostics = require('src.line_core.diagnostics')
local M = {}
function M.line(guidance, ctx) return Diagnostics.toLogLine(Diagnostics.collect(guidance, ctx)) end
return M
