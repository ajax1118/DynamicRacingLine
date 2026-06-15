-- DynamicRacingLine line_core/seam_guard.lua
-- Start/finish seam and sign-chatter repair. Keeps real chicanes while smoothing spline noise.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')

local M = {}

local function wrapIndex(i, n)
  while i < 1 do i = i + n end
  while i > n do i = i - n end
  return i
end

function M.unwrapProgressSeries(progresses, length)
  local out = {}
  if #(progresses or {}) == 0 then return out end
  out[1] = progresses[1]
  for i = 2, #progresses do
    local p = progresses[i]
    while p - out[i - 1] > length * 0.5 do p = p - length end
    while p - out[i - 1] < -length * 0.5 do p = p + length end
    out[i] = p
  end
  return out
end

function M.repairOffsetSeam(offsets, frame, boundary)
  local n = #(offsets or {})
  if n < 4 then return offsets, { changed = 0 } end
  local ds = math.max(1, frame and frame.spacing or Config.TARGET_SAMPLE_SPACING_M)
  local limit = Config.dynamicOffsetStepLimit(ds, 0, nil, boundary and boundary.confidence or 0.5) * 1.35
  local jump = math.abs((offsets[1] or 0) - (offsets[n] or 0))
  if jump <= limit then return offsets, { changed = 0, seamJump = jump, limit = limit } end
  local count = math.max(2, math.min(math.floor(Config.SEAM_WRAP_GUARD_M / ds), math.floor(n / 5)))
  local target = ((offsets[1] or 0) + (offsets[n] or 0)) * 0.5
  local changed = 0
  for d = 0, count - 1 do
    local w = U.smootherstep(1 - d / math.max(1, count - 1)) * 0.45
    local a, b = wrapIndex(1 + d, n), wrapIndex(n - d, n)
    offsets[a] = U.lerp(offsets[a] or 0, target, w)
    offsets[b] = U.lerp(offsets[b] or 0, target, w)
    changed = changed + 2
  end
  return offsets, { changed = changed, seamJump = jump, limit = limit }
end

function M.guardSignChatter(offsets, curvatures, opts)
  opts = opts or {}
  local n, changed = #(offsets or {}), 0
  if n < 5 then return offsets, { changed = 0 } end
  for i = 1, n do
    local p, c, nx = offsets[wrapIndex(i - 1, n)] or 0, offsets[i] or 0, offsets[wrapIndex(i + 1, n)] or 0
    local k = math.abs(curvatures and curvatures[i] or 0)
    if U.sign(p) == U.sign(nx) and U.sign(c) ~= U.sign(p) and math.abs(c) < 0.45 and k < Config.CURVATURE_STRONG_ABS then
      offsets[i] = (p + nx) * 0.5
      changed = changed + 1
    end
  end
  return offsets, { changed = changed, reason = 'sign_chatter_guard_preserves_real_chicanes' }
end

return M
