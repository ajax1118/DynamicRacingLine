local M = {}

local function text(value)
  return tostring(value or ''):lower()
end

local function normalize(value, fallback)
  local out = text(value)
  out = out:gsub('%.%.', ''):gsub('[\\/]+', '_')
  out = out:gsub('[^a-z0-9_%-]+', '_'):gsub('_+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if out == '' or out == 'unknown' or out == 'none' or out == 'nil' then
    return fallback or 'unknown'
  end
  return out
end

local function stableHash(textValue)
  local h = 5381
  local input = tostring(textValue or '')
  for i = 1, #input do
    h = (h * 33 + string.byte(input, i)) % 4294967296
  end
  return string.format('%08x', math.floor(h))
end

function M.normalize(value, fallback)
  return normalize(value, fallback)
end

function M.track(trackId)
  return normalize(trackId, 'unknown_track')
end

function M.layout(layoutId)
  local layout = normalize(layoutId, 'default')
  if layout == 'unknown_track' or layout == 'unknown_layout' or layout == 'unknown' then return 'default' end
  return layout
end

function M.car(carId)
  return normalize(carId, 'unknown_car')
end

function M.setupHash(setupFingerprint)
  local fingerprint = tostring(setupFingerprint or '')
  if fingerprint == '' or fingerprint == 'unknown' or fingerprint == 'nil' then return 'default_setup' end
  return stableHash(fingerprint)
end

function M.session(identity, car)
  identity = identity or {}
  car = car or {}
  local rawTrack = identity.trackId or identity.track_id or car.trackId or 'unknown_track'
  local rawLayout = identity.trackLayout or identity.layout_id or car.trackLayout or 'default'
  local rawCar = identity.carId or identity.car_id or car.carId or car.id or 'unknown_car'
  local fingerprint = tostring(car.setupFingerprint or identity.setupFingerprint or identity.setup_fingerprint or '')
  local setupHash = identity.setup_hash and fingerprint == '' and tostring(identity.setup_hash) or M.setupHash(fingerprint)
  return {
    rawTrackId = tostring(rawTrack or ''),
    rawLayoutId = tostring(rawLayout or ''),
    rawCarId = tostring(rawCar or ''),
    track_id = M.track(rawTrack),
    layout_id = M.layout(rawLayout),
    car_id = M.car(rawCar),
    setup_fingerprint = fingerprint,
    setup_hash = setupHash,
  }
end

return M
