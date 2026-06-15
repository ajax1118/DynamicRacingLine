-- DynamicRacingLine line_core/math_utils.lua
-- Small dependency-free math helpers for CSP Lua apps.
-- Keep this module pure Lua so it can be tested outside Assetto Corsa.

local M = {}

function M.clamp(v, lo, hi)
  if v == nil then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function M.sign(v)
  if v > 0 then return 1 end
  if v < 0 then return -1 end
  return 0
end

function M.lerp(a, b, t)
  return a + (b - a) * M.clamp(t or 0, 0, 1)
end

function M.smoothstep(t)
  t = M.clamp(t or 0, 0, 1)
  return t * t * (3 - 2 * t)
end

function M.smootherstep(t)
  t = M.clamp(t or 0, 0, 1)
  return t * t * t * (t * (t * 6 - 15) + 10)
end

function M.wrap(v, length)
  if not length or length <= 0 then return v or 0 end
  v = v or 0
  v = v % length
  if v < 0 then v = v + length end
  return v
end

function M.shortProgressDelta(a, b, length)
  if not length or length <= 0 then return (a or 0) - (b or 0) end
  local d = (a or 0) - (b or 0)
  if d > length * 0.5 then d = d - length end
  if d < -length * 0.5 then d = d + length end
  return d
end

function M.nearestByProgress(list, progress, trackLength)
  if not list or #list == 0 then return nil end
  local best, bestD = nil, math.huge
  for _, item in ipairs(list) do
    local p = tonumber(item.progress or item.s or item.distance or 0) or 0
    local d = math.abs(M.shortProgressDelta(p, progress or 0, trackLength or 0))
    if d < bestD then best, bestD = item, d end
  end
  return best, bestD
end

local function component(v, named, indexed, default)
  if not v then return default or 0 end
  local n = v[named]
  if n ~= nil then return n end
  local i = v[indexed]
  if i ~= nil then return i end
  return default or 0
end

function M.vec(x, y, z)
  return { x = x or 0, y = y or 0, z = z or 0 }
end

function M.x(v) return component(v, 'x', 1, 0) end
function M.y(v) return component(v, 'y', 2, 0) end
function M.z(v) return component(v, 'z', 3, 0) end

function M.add(a, b)
  return { x = M.x(a) + M.x(b), y = M.y(a) + M.y(b), z = M.z(a) + M.z(b) }
end

function M.sub(a, b)
  return { x = M.x(a) - M.x(b), y = M.y(a) - M.y(b), z = M.z(a) - M.z(b) }
end

function M.mul(a, s)
  return { x = M.x(a) * s, y = M.y(a) * s, z = M.z(a) * s }
end

function M.dot(a, b)
  return M.x(a) * M.x(b) + M.y(a) * M.y(b) + M.z(a) * M.z(b)
end

function M.dot2(a, b)
  return M.x(a) * M.x(b) + M.z(a) * M.z(b)
end

function M.len(a)
  return math.sqrt(M.dot(a, a))
end

function M.len2(a)
  return math.sqrt(M.x(a) * M.x(a) + M.z(a) * M.z(a))
end

function M.norm(a)
  local l = M.len(a)
  if l < 1e-9 then return { x = 0, y = 0, z = 0 } end
  return { x = M.x(a) / l, y = M.y(a) / l, z = M.z(a) / l }
end

function M.norm2(a)
  local l = M.len2(a)
  if l < 1e-9 then return { x = 0, y = 0, z = 1 } end
  return { x = M.x(a) / l, y = 0, z = M.z(a) / l }
end

function M.leftNormal2(tangent)
  -- Horizontal left normal for x/z track plane.
  local t = M.norm2(tangent)
  return { x = -t.z, y = 0, z = t.x }
end

function M.distance(a, b)
  return M.len(M.sub(a, b))
end

function M.distance2(a, b)
  local dx = M.x(a) - M.x(b)
  local dz = M.z(a) - M.z(b)
  return math.sqrt(dx * dx + dz * dz)
end

function M.average(values, radius, index)
  local n = #values
  if n == 0 then return 0 end
  local sum, count = 0, 0
  for d = -radius, radius do
    local j = index + d
    while j < 1 do j = j + n end
    while j > n do j = j - n end
    sum = sum + (values[j] or 0)
    count = count + 1
  end
  return sum / math.max(1, count)
end

function M.median3(a, b, c)
  if a > b then a, b = b, a end
  if b > c then b, c = c, b end
  if a > b then a, b = b, a end
  return b
end

function M.isFinite(v)
  return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

function M.safeNumber(v, default)
  if M.isFinite(v) then return v end
  return default or 0
end

function M.hashString(s)
  -- Deterministic 32-bit DJB2-style hash using only Lua 5.1-safe arithmetic.
  s = tostring(s or '')
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 4294967296
  end
  return string.format('%08x', h)
end

function M.safeKey(s, fallback)
  s = tostring(s or fallback or 'unknown')
  s = s:gsub('^%s+', ''):gsub('%s+$', ''):lower()
  s = s:gsub('[\\/]+', '_')
  s = s:gsub('[^%w_%-.]+', '_')
  s = s:gsub('_+', '_')
  s = s:gsub('^_+', ''):gsub('_+$', '')
  if s == '' then s = fallback or 'unknown' end
  return s
end

return M
