-- DynamicRacingLine line_core/setup_fingerprint.lua
-- Stable setup fingerprinting for braking/line behavior. Runtime snapshots are hints, not truth.

local U = require('src.line_core.math_utils')

local M = {}

local IMPORTANT_KEYS = {
  'tyreCompound', 'compound', 'tyres', 'frontTyreCompound', 'rearTyreCompound',
  'fuelKg', 'fuel', 'fuelLiters', 'ballastKg', 'ballast', 'restrictor',
  'brakeBias', 'brakePower', 'brakePowerMultiplier', 'engineLimiter',
  'wingFront', 'wingRear', 'frontWing', 'rearWing', 'aeroBalance',
  'pressureFL', 'pressureFR', 'pressureRL', 'pressureRR',
  'camberFL', 'camberFR', 'camberRL', 'camberRR',
  'toeFL', 'toeFR', 'toeRL', 'toeRR',
  'rideHeightFront', 'rideHeightRear', 'rideHeightF', 'rideHeightR',
  'arbFront', 'arbRear', 'tc', 'abs', 'damage', 'damageEngine', 'damageSuspension',
  'trackGrip', 'surfaceGrip', 'trackTemp', 'ambientTemp'
}

local ALIASES = {
  tyre_compound = 'tyreCompound', tireCompound = 'tyreCompound', tire_compound = 'tyreCompound',
  fuel_kg = 'fuelKg', fuelMass = 'fuelKg', currentFuel = 'fuelKg', ballast_kg = 'ballastKg',
  brake_bias = 'brakeBias', brakeBiasLive = 'brakeBias', brake_power = 'brakePower',
  brake_power_multiplier = 'brakePowerMultiplier', front_wing = 'wingFront', rear_wing = 'wingRear',
  pressure_fl = 'pressureFL', pressure_fr = 'pressureFR', pressure_rl = 'pressureRL', pressure_rr = 'pressureRR',
  camber_fl = 'camberFL', camber_fr = 'camberFR', camber_rl = 'camberRL', camber_rr = 'camberRR',
  toe_fl = 'toeFL', toe_fr = 'toeFR', toe_rl = 'toeRL', toe_rr = 'toeRR',
  ride_height_front = 'rideHeightFront', ride_height_rear = 'rideHeightRear',
  track_grip = 'trackGrip', surface_grip = 'surfaceGrip', track_temp = 'trackTemp',
}

local BUCKETS = {
  fuelKg = 2.5, fuel = 2.5, fuelLiters = 2.5, ballastKg = 5.0, ballast = 5.0,
  restrictor = 1.0, brakeBias = 0.5, brakePower = 0.02, brakePowerMultiplier = 0.02,
  wingFront = 1.0, wingRear = 1.0, frontWing = 1.0, rearWing = 1.0, aeroBalance = 0.03,
  pressureFL = 0.5, pressureFR = 0.5, pressureRL = 0.5, pressureRR = 0.5,
  camberFL = 0.1, camberFR = 0.1, camberRL = 0.1, camberRR = 0.1,
  toeFL = 0.02, toeFR = 0.02, toeRL = 0.02, toeRR = 0.02,
  rideHeightFront = 1.0, rideHeightRear = 1.0, rideHeightF = 1.0, rideHeightR = 1.0,
  arbFront = 1.0, arbRear = 1.0, trackGrip = 0.02, surfaceGrip = 0.02,
  trackTemp = 2.0, ambientTemp = 2.0, damage = 0.02, damageEngine = 0.02, damageSuspension = 0.02,
}

local function canonicalKey(k)
  k = tostring(k or '')
  return ALIASES[k] or k
end

local function bucket(v, step)
  local n = tonumber(v)
  if n == nil then return tostring(v) end
  step = step or 0.01
  return tostring(math.floor(n / step + 0.5) * step)
end

local function simple(v)
  if type(v) == 'boolean' then return v and '1' or '0' end
  if type(v) == 'string' then return v:lower():gsub('%s+', '_') end
  return tostring(v)
end

local function addFlat(out, prefix, t)
  if type(t) ~= 'table' then return end
  for k, v in pairs(t) do
    local direct = canonicalKey(k)
    local joined = canonicalKey(prefix and (prefix .. '.' .. tostring(k)) or tostring(k))
    if type(v) == 'table' then addFlat(out, joined, v) else out[direct] = v; out[joined] = v end
  end
end

function M.fingerprint(setup, telemetry, opts)
  opts = opts or {}
  local flat = {}
  addFlat(flat, nil, setup or {})
  addFlat(flat, 'telemetry', telemetry or {})
  local normalized = {}
  for _, k in ipairs(IMPORTANT_KEYS) do
    if flat[k] ~= nil then normalized[k] = bucket(flat[k], BUCKETS[k]) end
  end
  if opts.includeExtraKeys then
    for k, v in pairs(flat) do
      if normalized[k] == nil and type(v) ~= 'table' then
        local kl = tostring(k):lower()
        if kl:find('wing') or kl:find('brake') or kl:find('pressure') or kl:find('camber') or kl:find('toe') or kl:find('fuel') or kl:find('tyre') or kl:find('tire') or kl:find('rideheight') then
          normalized[k] = bucket(v, BUCKETS[k])
        end
      end
    end
  end
  local keys = {}
  for k in pairs(normalized) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. simple(normalized[k]) end
  local raw = table.concat(parts, ';')
  if raw == '' then raw = 'default_setup_unknown_runtime_hints' end
  return { raw = raw, normalized = normalized, keys = keys, hash = U.hashString(raw), confidence = #keys >= 6 and 0.72 or (#keys >= 3 and 0.52 or 0.28), source = 'setup_fingerprint_r02' }
end

function M.hash(setup, telemetry, opts)
  return M.fingerprint(setup, telemetry, opts).hash
end

function M.diff(a, b)
  local fa = (a and a.normalized) or a or {}
  local fb = (b and b.normalized) or b or {}
  local seen, changed = {}, {}
  for k in pairs(fa) do seen[k] = true end
  for k in pairs(fb) do seen[k] = true end
  for k in pairs(seen) do if tostring(fa[k]) ~= tostring(fb[k]) then changed[#changed + 1] = k end end
  table.sort(changed)
  return { changed = changed, count = #changed, importantCount = #changed }
end

return M
