local M = {}

function M.field(value, key, fallback)
  if value == nil then return fallback end
  local ok, result = pcall(function() return value[key] end)
  if ok and result ~= nil then return result end
  return fallback
end

function M.number(value, key, fallback)
  local result = tonumber(M.field(value, key, fallback))
  if not result or result ~= result or result == math.huge or result == -math.huge then return fallback end
  return result
end

function M.bool(value, key, fallback)
  local result = M.field(value, key, nil)
  if result == nil then return fallback == true end
  return result == true
end

return M
