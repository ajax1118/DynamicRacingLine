local M = {}

function M.vec(x, y, z)
  return { x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0 }
end

function M.x(v) return tonumber(v and (v.x or v[1])) or 0 end
function M.y(v) return tonumber(v and (v.y or v[2])) or 0 end
function M.z(v) return tonumber(v and (v.z or v[3])) or 0 end

function M.add(a, b) return M.vec(M.x(a) + M.x(b), M.y(a) + M.y(b), M.z(a) + M.z(b)) end
function M.sub(a, b) return M.vec(M.x(a) - M.x(b), M.y(a) - M.y(b), M.z(a) - M.z(b)) end
function M.mul(a, s) return M.vec(M.x(a) * s, M.y(a) * s, M.z(a) * s) end
function M.dot(a, b) return M.x(a) * M.x(b) + M.y(a) * M.y(b) + M.z(a) * M.z(b) end

function M.cross(a, b)
  return M.vec(
    M.y(a) * M.z(b) - M.z(a) * M.y(b),
    M.z(a) * M.x(b) - M.x(a) * M.z(b),
    M.x(a) * M.y(b) - M.y(a) * M.x(b))
end

function M.len(a) return math.sqrt(M.dot(a, a)) end

function M.norm(a, fallback)
  local l = M.len(a)
  if l < 0.000001 then return fallback or M.vec(0, 1, 0) end
  return M.mul(a, 1 / l)
end

function M.dist(a, b) return M.len(M.sub(a, b)) end

function M.lerp(a, b, t)
  t = math.max(0, math.min(1, tonumber(t) or 0))
  return M.add(M.mul(a, 1 - t), M.mul(b, t))
end

function M.clamp(value, lo, hi)
  value = tonumber(value) or lo
  if value < lo then return lo end
  if value > hi then return hi end
  return value
end

function M.safeNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

return M
