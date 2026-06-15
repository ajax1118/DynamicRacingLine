-- DynamicRacingLine line_core/profile_io.lua
-- Safe JSON profile IO. Uses ac.storage/json if provided; otherwise returns fallback safely.

local M = {}

function M.safeLoad(path, jsonDecode, fallback)
  local ok, data = false, nil
  if type(jsonDecode) == 'function' then
    local f = io and io.open and io.open(path, 'r')
    if f then local text = f:read('*a'); f:close(); ok, data = pcall(jsonDecode, text) end
  end
  if ok and type(data) == 'table' then data.__profilePath = path; return data end
  return fallback or { __missing = true, __profilePath = path }
end

function M.safeSave(path, value, jsonEncode)
  if type(jsonEncode) ~= 'function' or not io then return false, 'json_or_io_unavailable' end
  local ok, text = pcall(jsonEncode, value)
  if not ok then return false, 'json_encode_failed' end
  local f = io.open(path, 'w')
  if not f then return false, 'open_failed' end
  f:write(text); f:close(); return true, 'saved'
end

return M
