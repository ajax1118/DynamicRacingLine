local settings = require('src/settings')
local M = {}

local function clone(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = clone(v) end
  return out
end

local function numeric(value, fallback, lo, hi)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then
    number = fallback
  end
  if lo and number < lo then return lo end
  if hi and number > hi then return hi end
  return number
end

local function normId(value)
  value = tostring(value or 'default'):lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if value == '' then return 'default' end
  return value
end

local function firstValue(t, names)
  t = t or {}
  for _, name in ipairs(names or {}) do
    if t[name] ~= nil then return t[name] end
  end
  return nil
end

local function carCapabilityValue(car, names)
  local direct = firstValue(car, names)
  if direct ~= nil then return direct end
  return firstValue(type(car and car.capability) == 'table' and car.capability or {}, names)
end

local function parseJsonFile(path)
  if not io or not io.load or not JSON or not JSON.parse then return nil end
  local loaded, data = pcall(function() return io.load(path, nil) end)
  if not loaded or not data or data == '' then return nil end
  local ok, parsed = pcall(function() return JSON.parse(data) end)
  if ok and type(parsed) == 'table' then return parsed end
  return nil
end

local function assettoRoot()
  if not ac or not ac.getFolder or not ac.FolderID or not ac.FolderID.Root then return nil end
  local ok, root = pcall(function() return ac.getFolder(ac.FolderID.Root) end)
  if ok and root and root ~= '' then return tostring(root):gsub('[\\/]+$', '') end
  return nil
end

local function profilePath(kind, id)
  return string.format('configs/%s/%s.json', kind, normId(id))
end

local function installedProfilePath(root, kind, id)
  return string.format('%s/apps/lua/DynamicRacingLine/configs/%s/%s.json', root, kind, normId(id))
end

local function profilePaths(kind, id)
  local paths = {}
  local root = assettoRoot()
  if root then paths[#paths + 1] = installedProfilePath(root, kind, id) end
  paths[#paths + 1] = profilePath(kind, id)
  return paths
end

local function loadFirst(kind, id)
  for _, path in ipairs(profilePaths(kind, id)) do
    local parsed = parseJsonFile(path)
    if parsed then return parsed, normId(id) end
  end
  return nil, normId(id)
end

local function loadProfile(kind, id)
  local profile, key = loadFirst(kind, id)
  if profile then return profile, key end
  profile = loadFirst(kind, 'default')
  if profile then return profile, 'default' end
  return {}, 'default'
end

local function loadProfileCandidates(kind, ids)
  for _, id in ipairs(ids or {}) do
    local profile, key = loadFirst(kind, id)
    if profile then return profile, key end
  end
  local profile = loadFirst(kind, 'default')
  if profile then return profile, 'default' end
  return {}, 'default'
end

local function trackProfileIds(trackId, trackLayout)
  local ids = {}
  trackId = tostring(trackId or 'default')
  trackLayout = tostring(trackLayout or '')
  if trackId ~= '' and trackLayout ~= '' then
    ids[#ids + 1] = trackId .. '_' .. trackLayout
  end
  if trackId ~= '' then ids[#ids + 1] = trackId end
  return ids
end

local function validateCar(raw)
  local car = clone(raw or {})
  car.id = tostring(car.id or 'default')
  car.name = tostring(car.name or car.id)
  local corneringG = carCapabilityValue(car, {'cornering_g', 'corneringG'})
  local brakeG = carCapabilityValue(car, {'brake_decel_g', 'brake_g', 'braking_g', 'brakeG', 'brakingG'})
  local speedAero = carCapabilityValue(car, {'speed_aero_strength', 'speedAeroStrength', 'aero_dependency'})
  car.has_cornering_g = raw ~= nil and corneringG ~= nil
  car.has_brake_decel_g = raw ~= nil and brakeG ~= nil
  car.has_speed_aero_strength = raw ~= nil and speedAero ~= nil
  car.cornering_g = numeric(corneringG, settings.DEFAULT_CORNERING_G, 0.5, 4.5)
  car.brake_decel_g = numeric(brakeG, settings.DEFAULT_BRAKE_G, 0.5, settings.MAX_DYNAMIC_BRAKE_G)
  if car.has_speed_aero_strength then
    car.speed_aero_strength = numeric(speedAero, 0.0, 0.0, 0.30)
  else
    car.speed_aero_strength = nil
  end
  car.min_corner_speed_kph = numeric(carCapabilityValue(car, {'min_corner_speed_kph', 'minCornerSpeedKph'}), settings.MIN_CORNER_SPEED_KPH, 20.0, 180.0)
  car.max_target_speed_kph = numeric(carCapabilityValue(car, {'max_target_speed_kph', 'maxTargetSpeedKph'}), settings.MAX_TARGET_SPEED_KPH, 80.0, 450.0)
  car.confidence = numeric(car.confidence, 0.5, 0.0, 1.0)
  return car
end

local function validateTrack(raw)
  local track = clone(raw or {})
  track.id = tostring(track.id or 'default')
  track.name = tostring(track.name or track.id)
  track.surface_grip_hint = numeric(track.surface_grip_hint, 1.0, 0.5, 1.5)
  track.track_lateral_m = numeric(track.track_lateral_m, settings.TRACK_LATERAL, -12.0, 12.0)
  track.road_height_m = numeric(track.road_height_m, settings.ROAD_HEIGHT_M, settings.MIN_ROAD_HEIGHT_M, 0.80)
  track.visible_ahead_m = numeric(track.visible_ahead_m, settings.VISIBLE_AHEAD_M, 20.0, 350.0)
  track.visible_behind_m = numeric(track.visible_behind_m, settings.VISIBLE_BEHIND_M, 0.0, 50.0)
  track.tile_width_m = numeric(track.tile_width_m, settings.TILE_WIDTH_M, 0.25, 5.0)
  track.tile_length_m = numeric(track.tile_length_m, settings.TILE_LENGTH_M, 0.5, 15.0)
  track.track_sample_count = math.floor(numeric(track.track_sample_count, settings.TRACK_SAMPLE_COUNT, 80.0, 4000.0) + 0.5)
  track.confidence = numeric(track.confidence, 0.5, 0.0, 1.0)
  return track
end

function M.load(carId, trackId, trackLayout)
  local car, carKey = loadProfile('cars', carId)
  local track, trackKey = loadProfileCandidates('tracks', trackProfileIds(trackId, trackLayout))
  local layoutKey = normId(trackLayout)
  return {
    car = validateCar(car),
    track = validateTrack(track),
    carKey = carKey,
    trackKey = trackKey,
    layoutKey = layoutKey,
  }
end

M.validateCar = validateCar
M.validateTrack = validateTrack

return M
