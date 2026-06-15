local settings = require('src/settings')
local math_utils = require('src.line_core.math_utils')
local M = {}

local SCHEMA_VERSION = 1
local state = {
  loaded = false,
  db = nil,
  dirty = false,
  lastSaveAt = 0.0,
  nextSaveAt = 0.0,
  lastContextObserveAt = 0.0,
  status = 'not_loaded',
  lastError = 'none',
}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function clamp(value, lo, hi)
  value = finiteNumber(value, lo)
  if value < lo then return lo end
  if value > hi then return hi end
  return value
end

local function nowSeconds()
  return os.clock and os.clock() or 0.0
end

local function nowEpoch()
  local ok, value = pcall(function() return os.time() end)
  if ok and value then return value end
  return 0
end

local function token(value)
  local text = tostring(value or 'unknown'):lower()
  text = text:gsub('[^a-z0-9_%-]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if text == '' then return 'unknown' end
  return text
end

local function safeSetupFingerprint(value)
  local text = tostring(value or 'unknown')
  if text == '' then return 'unknown' end
  if #text > 900 then
    local hash = math_utils.hashString(text)
    text = text:sub(1, 420) .. '~' .. text:sub(#text - 419) .. '~h' .. hash .. '~l' .. tostring(#text)
  end
  return text
end

local function emptyDb()
  return {
    schemaVersion = SCHEMA_VERSION,
    app = 'DynamicRacingLine',
    createdBy = 'adaptive_knowledge_base',
    cars = {},
    setups = {},
    tracks = {},
    corners = {},
    stats = {
      loads = 0,
      saves = 0,
      corruptLoads = 0,
    },
  }
end

local function ensureTables(db)
  if type(db) ~= 'table' then db = emptyDb() end
  db.schemaVersion = finiteNumber(db.schemaVersion, SCHEMA_VERSION)
  if type(db.cars) ~= 'table' then db.cars = {} end
  if type(db.setups) ~= 'table' then db.setups = {} end
  if type(db.tracks) ~= 'table' then db.tracks = {} end
  if type(db.corners) ~= 'table' then db.corners = {} end
  if type(db.stats) ~= 'table' then db.stats = {} end
  db.stats.loads = math.floor(finiteNumber(db.stats.loads, 0) + 0.5)
  db.stats.saves = math.floor(finiteNumber(db.stats.saves, 0) + 0.5)
  db.stats.corruptLoads = math.floor(finiteNumber(db.stats.corruptLoads, 0) + 0.5)
  return db
end

local function assettoRoot()
  if not ac or not ac.getFolder or not ac.FolderID or not ac.FolderID.Root then return nil end
  local ok, root = pcall(function() return ac.getFolder(ac.FolderID.Root) end)
  if ok and root and root ~= '' then return tostring(root):gsub('[\\/]+$', '') end
  return nil
end

local function userProfileRoot()
  local ok, root = pcall(function() return os.getenv('USERPROFILE') end)
  if ok and root and root ~= '' then return tostring(root):gsub('[\\/]+$', '') end
  return nil
end

local function runtimePath()
  local profile = userProfileRoot()
  if profile then
    return profile .. '/Documents/Assetto Corsa/cfg/DynamicRacingLine_knowledge_base.json'
  end
  return 'DynamicRacingLine_knowledge_base.json'
end

local function seedPaths()
  local paths = {}
  local root = assettoRoot()
  if root then paths[#paths + 1] = root .. '/apps/lua/DynamicRacingLine/configs/knowledge_base/default.json' end
  paths[#paths + 1] = 'configs/knowledge_base/default.json'
  return paths
end

local function parseJsonFile(path)
  if not io or not io.load or not JSON or not JSON.parse then return nil, 'json_unavailable' end
  local loaded, data = pcall(function() return io.load(path, nil) end)
  if not loaded or not data or data == '' then return nil, 'missing_or_empty' end
  local ok, parsed = pcall(function() return JSON.parse(data) end)
  if ok and type(parsed) == 'table' then return parsed, 'loaded' end
  return nil, 'parse_failed'
end

local function sortedKeys(tbl)
  local keys = {}
  for key, _ in pairs(tbl or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function jsonEscape(text)
  text = tostring(text or '')
  text = text:gsub('\\', '\\\\')
  text = text:gsub('"', '\\"')
  text = text:gsub('\b', '\\b')
  text = text:gsub('\f', '\\f')
  text = text:gsub('\n', '\\n')
  text = text:gsub('\r', '\\r')
  text = text:gsub('\t', '\\t')
  return text
end

local encodeValue

local function isArray(tbl)
  if type(tbl) ~= 'table' then return false end
  local maxKey = 0
  local count = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then return false end
    if key > maxKey then maxKey = key end
    count = count + 1
  end
  return maxKey == count
end

encodeValue = function(value, depth)
  depth = depth or 0
  if depth > 8 then return 'null' end
  local valueType = type(value)
  if valueType == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then return '0' end
    return string.format('%.6g', value)
  elseif valueType == 'boolean' then
    return value and 'true' or 'false'
  elseif valueType == 'string' then
    return '"' .. jsonEscape(value) .. '"'
  elseif valueType ~= 'table' then
    return 'null'
  end

  local parts = {}
  if isArray(value) then
    for index = 1, #value do parts[#parts + 1] = encodeValue(value[index], depth + 1) end
    return '[' .. table.concat(parts, ',') .. ']'
  end

  for _, key in ipairs(sortedKeys(value)) do
    local keyType = type(key)
    if keyType == 'string' or keyType == 'number' then
      parts[#parts + 1] = '"' .. jsonEscape(key) .. '":' .. encodeValue(value[key], depth + 1)
    end
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

local function readRuntimeDb()
  local parsed, status = parseJsonFile(runtimePath())
  if type(parsed) == 'table' then return ensureTables(parsed), status end
  local db = emptyDb()
  if status == 'parse_failed' then db.stats.corruptLoads = 1 end
  return db, status
end

local function mergeSeedInto(db)
  if settings.KNOWLEDGE_BASE_SEED_ENABLED ~= true then return db end
  for _, path in ipairs(seedPaths()) do
    local seed = parseJsonFile(path)
    if type(seed) == 'table' then
      if type(seed.cars) == 'table' then
        for key, value in pairs(seed.cars) do
          local normalized = token(key)
          if type(value) == 'table' and db.cars[normalized] == nil then
            value.seedOnly = true
            value.source = tostring(value.source or 'seed_knowledge_base')
            db.cars[normalized] = value
          end
        end
      end
      if type(seed.tracks) == 'table' then
        for key, value in pairs(seed.tracks) do
          local normalized = tostring(key)
          if type(value) == 'table' and db.tracks[normalized] == nil then
            value.seedOnly = true
            value.source = tostring(value.source or 'seed_knowledge_base')
            db.tracks[normalized] = value
          end
        end
      end
      return db
    end
  end
  return db
end

local function db()
  if state.loaded and state.db then return state.db end
  local loaded, status = readRuntimeDb()
  loaded = mergeSeedInto(loaded)
  loaded.stats.loads = (loaded.stats.loads or 0) + 1
  state.db = loaded
  state.loaded = true
  state.status = status or 'empty'
  state.lastError = 'none'
  return state.db
end

local function markDirty()
  state.dirty = true
  local delay = math.max(0.5, finiteNumber(settings.KNOWLEDGE_BASE_FLUSH_INTERVAL_S, 6.0))
  local now = nowSeconds()
  if state.nextSaveAt <= 0.0 then state.nextSaveAt = now + delay end
end

local function writeRuntimeDb(force)
  if settings.KNOWLEDGE_BASE_WRITE_ENABLED ~= true then return false, 'write_disabled' end
  if not state.loaded or not state.db then return false, 'not_loaded' end
  if state.dirty ~= true and force ~= true then return false, 'not_dirty' end
  local now = nowSeconds()
  if force ~= true and now < (state.nextSaveAt or 0.0) then return false, 'not_due' end

  local snapshot = state.db
  snapshot.schemaVersion = SCHEMA_VERSION
  snapshot.version = tostring(settings.VERSION or '')
  snapshot.buildId = tostring(settings.BUILD_ID or '')
  snapshot.updatedAt = nowEpoch()
  snapshot.stats = snapshot.stats or {}
  snapshot.stats.saves = finiteNumber(snapshot.stats.saves, 0) + 1
  local payload = encodeValue(snapshot)
  local ok, err = pcall(function()
    local path = runtimePath()
    local tmpPath = path .. '.tmp'
    local file = io.open(tmpPath, 'w')
    if not file then error('open_failed') end
    local wrote, writeErr = file:write(payload)
    local closed, closeErr = file:close()
    if not wrote then error(writeErr or 'write_failed') end
    if not closed then error(closeErr or 'close_failed') end
    local renamed, renameErr = os.rename(tmpPath, path)
    if not renamed then
      pcall(function() os.remove(path) end)
      renamed, renameErr = os.rename(tmpPath, path)
      if not renamed then error(renameErr or 'rename_failed') end
    end
  end)
  if ok then
    state.dirty = false
    state.lastSaveAt = now
    state.nextSaveAt = 0.0
    state.status = 'saved'
    state.lastError = 'none'
    return true, 'saved'
  end
  state.status = 'save_failed'
  state.lastError = tostring(err or 'save_failed')
  state.nextSaveAt = now + math.max(1.0, finiteNumber(settings.KNOWLEDGE_BASE_FLUSH_INTERVAL_S, 6.0))
  return false, state.lastError
end

local function blend(previous, observed, alpha)
  previous = finiteNumber(previous, 0.0)
  observed = finiteNumber(observed, previous)
  alpha = clamp(alpha, 0.0, 1.0)
  if previous <= 0.0 then return observed end
  return previous + (observed - previous) * alpha
end

local function increment(entry, key, amount)
  entry[key] = finiteNumber(entry[key], 0.0) + finiteNumber(amount, 1.0)
  return entry[key]
end

local function carKey(car)
  return token(car and (car.carId or car.id or car.name) or 'unknown_car')
end

local function trackKey(trackId, trackLayout)
  local track = token(trackId or 'unknown_track')
  local layout = token(trackLayout or 'default')
  return track .. '|' .. layout
end

local function setupKey(car, trackId, trackLayout)
  return carKey(car) .. '|' .. trackKey(trackId or (car and car.trackId), trackLayout or (car and car.trackLayout)) .. '|' .. safeSetupFingerprint(car and car.setupFingerprint)
end

local function cornerBucket(progress)
  local p = finiteNumber(progress, 0.0) % 1.0
  return math.floor(p / 0.005)
end

local function cornerKeyFromContext(context, sample)
  context = context or {}
  sample = sample or {}
  return token(context.carId or 'unknown_car') .. '|' .. token(context.trackId or 'unknown_track') .. '|' ..
    token(context.trackLayout or 'default') .. '|' .. safeSetupFingerprint(context.setupFingerprint) .. '|' ..
    token(context.cornerLearningMomentKey or 'moment_unknown') .. '|' .. string.format('%03d', cornerBucket(sample.progress))
end

local function entryConfidence(samples, floor, cap, fullSamples)
  samples = math.max(0.0, finiteNumber(samples, 0.0))
  floor = clamp(finiteNumber(floor, 0.40), 0.0, 1.0)
  cap = clamp(finiteNumber(cap, 0.75), floor, 1.0)
  fullSamples = math.max(1.0, finiteNumber(fullSamples, 12.0))
  return clamp(floor + (cap - floor) * clamp(samples / fullSamples, 0.0, 1.0), floor, cap)
end

function M.carPrior(car)
  if settings.KNOWLEDGE_BASE_ENABLED ~= true then return nil end
  local key = carKey(car)
  if key == 'unknown_car' then return nil end
  local entry = db().cars[key]
  if type(entry) ~= 'table' then return nil end
  local samples = finiteNumber(entry.samples, 0.0)
  local minSamples = math.max(0.0, finiteNumber(settings.KNOWLEDGE_BASE_CAR_PRIOR_MIN_SAMPLES, 4.0))
  if entry.seedOnly ~= true and samples < minSamples then return nil end

  local corneringG = finiteNumber(entry.corneringG or entry.cornering_g, 0.0)
  local brakeG = finiteNumber(entry.brakeG or entry.brake_decel_g or entry.brake_g, 0.0)
  local speedAeroStrength = entry.speedAeroStrength or entry.speed_aero_strength
  if corneringG <= 0.0 and brakeG <= 0.0 and speedAeroStrength == nil then return nil end

  return {
    corneringG = corneringG > 0.0 and clamp(corneringG, 0.5, 4.5) or nil,
    brakeG = brakeG > 0.0 and clamp(brakeG, 0.5, finiteNumber(settings.MAX_DYNAMIC_BRAKE_G, 4.5)) or nil,
    speedAeroStrength = speedAeroStrength ~= nil and clamp(speedAeroStrength, 0.0, 0.30) or nil,
    confidence = clamp(entry.confidence, 0.40, finiteNumber(settings.KNOWLEDGE_BASE_CAR_PRIOR_CONFIDENCE_CAP, 0.78)),
    samples = samples,
    sourceDetail = tostring(entry.source or (entry.seedOnly and 'seed_knowledge_base' or 'local_adaptive_db')) .. ':' .. key,
  }
end

local function normalDryContext(context)
  context = context or {}
  local wet = math.max(clamp(context.rainIntensity, 0.0, 1.0), clamp(context.rainWetness, 0.0, 1.0), clamp(context.rainWater, 0.0, 1.0))
  if wet > 0.05 then return false end
  if finiteNumber(context.tyreFactor, 1.0) < 0.82 then return false end
  if finiteNumber(context.surfaceGrip, 1.0) < 0.86 then return false end
  if finiteNumber(context.damageLevel, 0.0) > 0.05 then return false end
  return true
end

local function riskFromContext(context)
  context = context or {}
  local frontStress = finiteNumber(context.frontTyreStress, 0.0)
  local rearStress = finiteNumber(context.rearTyreStress, 0.0)
  local rearBias = math.max(0.0, rearStress - frontStress * 0.82)
  local slipStress = finiteNumber(context.slipStress, 0.0)
  local wetLoad = math.max(clamp(context.rainIntensity, 0.0, 1.0) * 0.60, clamp(context.rainWetness, 0.0, 1.0), clamp(context.rainWater, 0.0, 1.0) * 1.20)
  local tc = context.tractionControlInAction == true and 0.20 or 0.0
  local rearLock = tostring(context.brakeLockupAxle or '') == 'rear' and 0.20 or 0.0
  return clamp(rearBias * 0.75 + slipStress * 0.25 + wetLoad * 0.25 + tc + rearLock, 0.0, 1.0)
end

local function updateSetupMemory(car, context, extraRisk, cause)
  if settings.KNOWLEDGE_BASE_SETUP_MEMORY_ENABLED ~= true then return nil end
  local key = setupKey(car, context and context.trackId, context and context.trackLayout)
  if key:find('unknown_car', 1, true) then return nil end
  local root = db().setups
  local entry = root[key] or {}
  root[key] = entry
  entry.key = key
  entry.carId = carKey(car)
  entry.trackKey = trackKey(context and context.trackId or car and car.trackId, context and context.trackLayout or car and car.trackLayout)
  entry.setupFingerprint = safeSetupFingerprint(car and car.setupFingerprint)
  entry.updatedAt = nowEpoch()
  local observedRisk = math.max(riskFromContext(context), finiteNumber(extraRisk, 0.0))
  if observedRisk > 0.0 then
    entry.rearInstabilityRisk = blend(entry.rearInstabilityRisk, observedRisk, finiteNumber(settings.KNOWLEDGE_BASE_RISK_BLEND, 0.18))
    entry.riskSamples = increment(entry, 'riskSamples', observedRisk > 0.20 and 1.0 or 0.25)
  else
    entry.rearInstabilityRisk = finiteNumber(entry.rearInstabilityRisk, 0.0) * clamp(settings.KNOWLEDGE_BASE_RISK_DECAY, 0.0, 1.0)
  end
  if context then
    entry.frontTyreStress = blend(entry.frontTyreStress, context.frontTyreStress, 0.12)
    entry.rearTyreStress = blend(entry.rearTyreStress, context.rearTyreStress, 0.12)
    entry.slipStress = blend(entry.slipStress, context.slipStress, 0.12)
    entry.brakeLockupAxle = tostring(context.brakeLockupAxle or entry.brakeLockupAxle or 'none')
  end
  entry.lastCause = tostring(cause or entry.lastCause or 'context')
  entry.samples = increment(entry, 'samples', 1.0)
  entry.confidence = entryConfidence(entry.samples, 0.35, finiteNumber(settings.KNOWLEDGE_BASE_SETUP_CONFIDENCE_CAP, 0.82), 18.0)
  markDirty()
  return entry
end

local function updateTrackMemory(car, context)
  if settings.KNOWLEDGE_BASE_TRACK_MEMORY_ENABLED ~= true then return nil end
  context = context or {}
  local key = trackKey(context.trackId or car and car.trackId, context.trackLayout or car and car.trackLayout)
  if key:find('unknown_track', 1, true) then return nil end
  local root = db().tracks
  local entry = root[key] or {}
  root[key] = entry
  entry.key = key
  entry.updatedAt = nowEpoch()
  if normalDryContext(context) then
    entry.surfaceGripObserved = blend(entry.surfaceGripObserved, context.surfaceGrip, 0.10)
    entry.roadGripObserved = blend(entry.roadGripObserved, context.roadGrip, 0.10)
  end
  local risk = riskFromContext(context)
  entry.trackRisk = blend(entry.trackRisk, risk, 0.08)
  entry.samples = increment(entry, 'samples', 1.0)
  entry.confidence = entryConfidence(entry.samples, 0.30, finiteNumber(settings.KNOWLEDGE_BASE_TRACK_CONFIDENCE_CAP, 0.70), 30.0)
  markDirty()
  return entry
end

local function updateCarCapability(car, context)
  if settings.KNOWLEDGE_BASE_CAR_MEMORY_ENABLED ~= true then return nil end
  if not normalDryContext(context) then return nil end
  local key = carKey(car)
  if key == 'unknown_car' then return nil end
  context = context or {}
  local root = db().cars
  local entry = root[key] or {}
  if entry.seedOnly == true then entry = {} end
  root[key] = entry
  entry.key = key
  entry.updatedAt = nowEpoch()
  local updatedAxis = false
  local cornerSource = tostring(context.corneringGSource or '')
  local brakeSource = tostring(context.brakeGSource or '')
  local cornerSamples = finiteNumber(context.cornerCapabilitySamples or context.strongCornerSamples, 0.0)
  local brakeSamples = finiteNumber(context.brakeCapabilitySamples or context.cleanStrongBrakeSamples, 0.0)
  local minSamples = math.max(1.0, finiteNumber(settings.KNOWLEDGE_BASE_CAR_PRIOR_MIN_SAMPLES, 4.0))
  if cornerSource == 'live_telemetry' and cornerSamples >= minSamples then
    local value = finiteNumber(context.learnedCorneringG, finiteNumber(context.corneringG, 0.0))
    if value > 0.5 then
      entry.corneringG = blend(entry.corneringG, value, finiteNumber(settings.KNOWLEDGE_BASE_CAPABILITY_BLEND, 0.12))
      updatedAxis = true
    end
  end
  if brakeSource == 'live_telemetry' and brakeSamples >= minSamples then
    local value = finiteNumber(context.learnedBrakeG, finiteNumber(context.brakeG, 0.0))
    if value > 0.5 then
      entry.brakeG = blend(entry.brakeG, value, finiteNumber(settings.KNOWLEDGE_BASE_CAPABILITY_BLEND, 0.12))
      updatedAxis = true
    end
  end
  local aeroSamples = finiteNumber(context.aeroHighSpeedLimitSamples, 0.0)
  if aeroSamples >= math.max(1.0, finiteNumber(settings.TELEMETRY_AERO_STRENGTH_MIN_SAMPLES, 3.0)) then
    entry.speedAeroStrength = blend(entry.speedAeroStrength, context.learnedSpeedAeroStrength, 0.15)
    updatedAxis = true
  end
  if not updatedAxis then return nil end
  entry.samples = increment(entry, 'samples', 1.0)
  entry.confidence = entryConfidence(entry.samples, 0.45, finiteNumber(settings.KNOWLEDGE_BASE_CAR_PRIOR_CONFIDENCE_CAP, 0.78), 24.0)
  entry.source = 'local_adaptive_db'
  markDirty()
  return entry
end

function M.observeContext(car, context)
  if settings.KNOWLEDGE_BASE_ENABLED ~= true then return nil end
  local now = nowSeconds()
  local interval = math.max(0.25, finiteNumber(settings.KNOWLEDGE_BASE_OBSERVE_INTERVAL_S, 2.0))
  if now < (state.lastContextObserveAt or 0.0) + interval then
    writeRuntimeDb(false)
    return nil
  end
  state.lastContextObserveAt = now
  car = car or {}
  context = context or {}
  updateCarCapability(car, context)
  local setup = updateSetupMemory(car, context, 0.0, 'context')
  local track = updateTrackMemory(car, context)
  writeRuntimeDb(false)
  return { setup = setup, track = track }
end

local function cornerRiskFromState(entry)
  entry = entry or {}
  local clean = math.max(0.0, finiteNumber(entry.cornerLearningCleanWindowSamples or entry.cleanWindowSamples, 0.0))
  local risk = math.max(0.0, finiteNumber(entry.cornerLearningRiskWindowSamples or entry.riskWindowSamples, 0.0))
  local total = clean + risk
  local riskRate = total > 0.0 and risk / total or 0.0
  local overspeed = clamp(finiteNumber(entry.cornerSpeedOverTargetKph, 0.0) / 35.0, 0.0, 1.0)
  local brakeBias = clamp(math.max(0.0, finiteNumber(entry.rawCornerBrakeBiasM or entry.brakeBiasM, 0.0)) / math.max(1.0, finiteNumber(settings.CORNER_LEARNING_MAX_BRAKE_BIAS_M, 24.0)), 0.0, 1.0)
  return clamp(math.max(riskRate, overspeed * 0.60, brakeBias * 0.70), 0.0, 1.0)
end

function M.observeCorner(car, cue, learnedState)
  if settings.KNOWLEDGE_BASE_ENABLED ~= true or settings.KNOWLEDGE_BASE_CORNER_MEMORY_ENABLED ~= true then return nil end
  learnedState = learnedState or {}
  cue = cue or {}
  local key = tostring(learnedState.cornerLearningKey or '')
  if key == '' then return nil end
  if learnedState.sampleAccepted ~= true then return nil end
  local root = db().corners
  local entry = root[key] or {}
  root[key] = entry
  entry.key = key
  entry.updatedAt = nowEpoch()
  entry.carId = carKey(car)
  entry.trackId = token(cue.trackId or car and car.trackId or 'unknown_track')
  entry.trackLayout = token(cue.trackLayout or car and car.trackLayout or 'default')
  entry.setupFingerprint = safeSetupFingerprint(car and car.setupFingerprint)
  entry.cornerLearningMomentKey = token(learnedState.cornerLearningMomentKey or cue.cornerLearningMomentKey or 'moment_unknown')
  entry.cornerLearningState = tostring(learnedState.cornerLearningState or 'unknown')
  entry.cornerLearningCauseBucket = tostring(learnedState.cornerLearningCauseBucket or 'none')
  entry.cornerLearningConfidence = clamp(learnedState.cornerLearningConfidence, 0.0, 1.0)
  entry.cornerLearningCleanWindowSamples = finiteNumber(learnedState.cornerLearningCleanWindowSamples, 0.0)
  entry.cornerLearningRiskWindowSamples = finiteNumber(learnedState.cornerLearningRiskWindowSamples, 0.0)
  entry.rawCornerBrakeBiasM = clamp(learnedState.rawCornerBrakeBiasM or learnedState.brakeBiasM, finiteNumber(settings.CORNER_LEARNING_MIN_BRAKE_BIAS_M, -20.0), finiteNumber(settings.CORNER_LEARNING_MAX_BRAKE_BIAS_M, 24.0))
  entry.brakeBiasM = entry.rawCornerBrakeBiasM
  entry.cornerBrakeBiasM = clamp(learnedState.cornerBrakeBiasM, finiteNumber(settings.CORNER_LEARNING_MIN_BRAKE_BIAS_M, -20.0), finiteNumber(settings.CORNER_LEARNING_MAX_BRAKE_BIAS_M, 24.0))
  entry.cornerSpeedOverTargetKph = finiteNumber(learnedState.cornerSpeedOverTargetKph, 0.0)
  entry.cornerResultLearningReason = tostring(learnedState.cornerResultLearningReason or 'none')
  entry.cornerResultOverspeedPhase = tostring(learnedState.cornerResultOverspeedPhase or 'none')
  entry.sampleAccepted = learnedState.sampleAccepted == true
  entry.cornerLearningRejectReason = tostring(learnedState.cornerLearningRejectReason or 'none')
  entry.cornerLearningBrakeLimitReason = tostring(learnedState.cornerLearningBrakeLimitReason or 'none')
  entry.samples = math.max(finiteNumber(entry.samples, 0.0), finiteNumber(learnedState.samples, 0.0))
  entry.risk = cornerRiskFromState(entry)
  entry.confidence = clamp(entry.cornerLearningConfidence * entryConfidence(entry.samples, 0.45, finiteNumber(settings.KNOWLEDGE_BASE_CORNER_CONFIDENCE_CAP, 0.84), 10.0), 0.0, 0.84)
  entry.source = 'local_corner_memory'

  local contextRisk = math.max(
    finiteNumber(cue.instabilityRisk, 0.0),
    finiteNumber(cue.instabilityAdvisoryRatio, 0.0) / math.max(0.01, finiteNumber(settings.RED_RATIO, 0.50)),
    entry.risk)
  updateSetupMemory(car, {
    trackId = cue.trackId or car and car.trackId,
    trackLayout = cue.trackLayout or car and car.trackLayout,
    frontTyreStress = cue.frontTyreStress,
    rearTyreStress = cue.rearTyreStress,
    slipStress = cue.slipStress,
    rainIntensity = cue.rainIntensity,
    rainWetness = cue.rainWetness,
    rainWater = cue.rainWater,
    tractionControlInAction = cue.tractionControlInAction,
    brakeLockupAxle = cue.brakeLockupAxle,
  }, contextRisk, entry.cornerLearningCauseBucket)
  markDirty()
  writeRuntimeDb(false)
  return entry
end

function M.cornerState(key)
  if settings.KNOWLEDGE_BASE_ENABLED ~= true or settings.KNOWLEDGE_BASE_CORNER_MEMORY_ENABLED ~= true then return nil end
  key = tostring(key or '')
  if key == '' then return nil end
  local entry = db().corners[key]
  if type(entry) ~= 'table' then return nil end
  local samples = finiteNumber(entry.samples, 0.0)
  if samples < math.max(0.0, finiteNumber(settings.KNOWLEDGE_BASE_CORNER_MIN_SAMPLES, 1.0)) then return nil end
  return entry
end

function M.setupSummary(car, context)
  if settings.KNOWLEDGE_BASE_ENABLED ~= true then return nil end
  local entry = db().setups[setupKey(car, context and context.trackId, context and context.trackLayout)]
  if type(entry) ~= 'table' then return nil end
  return entry
end

function M.trackSummary(trackId, trackLayout)
  if settings.KNOWLEDGE_BASE_ENABLED ~= true then return nil end
  local entry = db().tracks[trackKey(trackId, trackLayout)]
  if type(entry) ~= 'table' then return nil end
  return entry
end

function M.sampleRisk(context, sample)
  if settings.KNOWLEDGE_BASE_ENABLED ~= true then
    return { risk = 0.0, confidence = 0.0, targetScale = 1.0, advisoryRatio = 0.0, source = 'disabled' }
  end
  context = context or {}
  sample = sample or {}
  local key = cornerKeyFromContext(context, sample)
  local corner = M.cornerState(key)
  local setup = db().setups[setupKey({ carId = context.carId, setupFingerprint = context.setupFingerprint, trackId = context.trackId, trackLayout = context.trackLayout }, context.trackId, context.trackLayout)]
  local track = db().tracks[trackKey(context.trackId, context.trackLayout)]
  local cornerRisk = type(corner) == 'table' and finiteNumber(corner.risk, 0.0) * clamp(corner.confidence, 0.0, 1.0) or 0.0
  local setupRisk = type(setup) == 'table' and finiteNumber(setup.rearInstabilityRisk, 0.0) * clamp(setup.confidence, 0.0, 1.0) * 0.65 or 0.0
  local trackRisk = type(track) == 'table' and finiteNumber(track.trackRisk, 0.0) * clamp(track.confidence, 0.0, 1.0) * 0.25 or 0.0
  local risk = clamp(math.max(cornerRisk, setupRisk, trackRisk), 0.0, 1.0)
  local confidence = clamp(math.max(
    type(corner) == 'table' and finiteNumber(corner.confidence, 0.0) or 0.0,
    type(setup) == 'table' and finiteNumber(setup.confidence, 0.0) * 0.65 or 0.0,
    type(track) == 'table' and finiteNumber(track.confidence, 0.0) * 0.25 or 0.0), 0.0, 1.0)
  local maxReduction = clamp(settings.KNOWLEDGE_BASE_TARGET_SPEED_MAX_REDUCTION, 0.0, 0.12)
  local targetScale = clamp(1.0 - risk * maxReduction, 1.0 - maxReduction, 1.0)
  local yellow = finiteNumber(settings.YELLOW_RATIO, 0.09)
  local red = math.max(yellow + 0.01, finiteNumber(settings.RED_RATIO, 0.50))
  local advisory = risk > 0.03 and clamp(yellow + risk * finiteNumber(settings.KNOWLEDGE_BASE_ADVISORY_RATIO_MULT, 0.30), yellow, red - 0.001) or 0.0
  return {
    key = key,
    risk = risk,
    confidence = confidence,
    targetScale = targetScale,
    advisoryRatio = advisory,
    source = cornerRisk >= setupRisk and cornerRisk >= trackRisk and 'corner_memory' or (setupRisk >= trackRisk and 'setup_memory' or 'track_memory'),
    cornerSamples = type(corner) == 'table' and finiteNumber(corner.samples, 0.0) or 0.0,
  }
end

function M.status()
  local database = db()
  return {
    enabled = settings.KNOWLEDGE_BASE_ENABLED == true,
    status = state.status,
    path = runtimePath(),
    lastError = state.lastError or 'none',
    dirty = state.dirty == true,
    carCount = database.cars and #(sortedKeys(database.cars)) or 0,
    setupCount = database.setups and #(sortedKeys(database.setups)) or 0,
    trackCount = database.tracks and #(sortedKeys(database.tracks)) or 0,
    cornerCount = database.corners and #(sortedKeys(database.corners)) or 0,
  }
end

function M.flush(force)
  return writeRuntimeDb(force == true)
end

M.carKey = carKey
M.trackKey = trackKey
M.setupKey = setupKey
M.cornerKeyFromContext = cornerKeyFromContext
M.encodeValue = encodeValue
M.runtimePath = runtimePath
M.parseJsonFile = parseJsonFile

return M
