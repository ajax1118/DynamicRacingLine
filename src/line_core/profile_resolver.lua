-- DynamicRacingLine line_core/profile_resolver.lua
-- Safer profile keys and default-profile warnings. This prevents silent overuse of
-- default track/car profiles and fixes unsafe path/key normalization.

local U = require('src.line_core.math_utils')

local M = {}

local function stringifyValue(v)
  if type(v) == 'table' then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. stringifyValue(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return tostring(v)
end

function M.normalizeTrackId(track)
  if type(track) == 'table' then
    return U.safeKey(track.id or track.trackId or track.folder or track.name or 'unknown_track', 'unknown_track')
  end
  return U.safeKey(track, 'unknown_track')
end

function M.normalizeLayoutId(layout)
  if type(layout) == 'table' then
    return U.safeKey(layout.id or layout.layoutId or layout.folder or layout.name or 'default', 'default')
  end
  return U.safeKey(layout or 'default', 'default')
end

function M.normalizeCarId(car)
  if type(car) == 'table' then
    return U.safeKey(car.id or car.carId or car.folder or car.acId or car.name or 'unknown_car', 'unknown_car')
  end
  return U.safeKey(car, 'unknown_car')
end

function M.setupFingerprint(setup)
  setup = setup or {}
  local fields = {
    'tyreCompound', 'compound', 'fuelKg', 'fuel', 'ballast', 'restrictor',
    'brakePower', 'brake_power', 'brakeBias', 'brake_bias', 'frontWing', 'rearWing',
    'wing', 'aero', 'tyrePressureFL', 'tyrePressureFR', 'tyrePressureRL', 'tyrePressureRR',
    'damage', 'damageState', 'absActive', 'tcActive'
  }
  local parts = {}
  for _, f in ipairs(fields) do
    local v = setup[f]
    if v ~= nil then
      if type(v) == 'number' then
        -- Fine buckets: enough to catch meaningful changes without hashing telemetry noise.
        parts[#parts + 1] = f .. '=' .. string.format('%.3f', v)
      else
        parts[#parts + 1] = f .. '=' .. stringifyValue(v)
      end
    end
  end
  table.sort(parts)
  if #parts == 0 then parts[1] = 'setup=unknown' end
  return table.concat(parts, '|')
end

function M.setupHash(setup)
  return U.hashString(M.setupFingerprint(setup))
end

function M.profilePaths(root, trackId, layoutId, carId, setupHash)
  root = root or 'data'
  trackId = M.normalizeTrackId(trackId)
  layoutId = M.normalizeLayoutId(layoutId)
  carId = M.normalizeCarId(carId)
  setupHash = U.safeKey(setupHash or 'default_setup', 'default_setup')
  return {
    trackProfile = string.format('%s/tracks/%s/%s/track_profile.json', root, trackId, layoutId),
    corners = string.format('%s/tracks/%s/%s/corners.json', root, trackId, layoutId),
    baseLine = string.format('%s/tracks/%s/%s/base_line.json', root, trackId, layoutId),
    generatedLine = string.format('%s/tracks/%s/%s/generated_line.json', root, trackId, layoutId),
    carProfile = string.format('%s/cars/%s/car_profile.json', root, carId),
    physicsProfile = string.format('%s/cars/%s/physics_profile.json', root, carId),
    learnedProfile = string.format('%s/learned/%s/%s/%s/%s.json', root, trackId, layoutId, carId, setupHash),
  }
end

function M.defaultWarning(kind, id)
  return {
    kind = kind or 'profile',
    id = id or 'unknown',
    warning = 'default_profile_used',
    confidencePenalty = 0.22,
    message = 'Exact profile was not found; generated predictive baseline should be used before default assumptions.',
  }
end

return M
