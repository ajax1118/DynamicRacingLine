-- DynamicRacingLine line_core/path_resampler.lua
-- Reduces coordinate noise from too-low spacing and avoids oversampling-induced lateral chatter.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config') -- TARGET_SAMPLE_SPACING_M

local M = {}

local function worldOf(s)
  if type(s) == 'table' then return s.world or s.pos or s end
  return s
end

function M.resample(raw, opts)
  opts = opts or {}
  raw = raw or {}
  local n = #raw
  if n < 3 then return raw end
  local target = math.max(1.0, opts.spacing or Config.TARGET_SAMPLE_SPACING_M)
  local out = {}
  local lastWorld = nil
  for i = 1, n do
    local s = raw[i]
    local w = worldOf(s)
    -- U.distance2 returns horizontal distance in meters; the historical name is not squared distance.
    local distanceM = lastWorld and U.distance2(w, lastWorld) or math.huge
    if not lastWorld or distanceM >= target * 0.72 then
      local c = s
      if type(s) == 'table' then
        c = {}
        for k, v in pairs(s) do c[k] = v end
      end
      out[#out + 1] = c
      lastWorld = w
    end
  end
  if #out < 3 then return raw end
  return out
end

return M
