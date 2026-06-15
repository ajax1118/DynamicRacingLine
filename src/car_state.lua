local math3d = require('src/math3d')
local physics_capability = require('src/physics_capability')
local setup_fingerprint = require('src/setup_fingerprint')
local M = {}
local metadataCache = {}

local function safeCall(fn, fallback)
  local ok, value = pcall(fn)
  if ok and value ~= nil then return value end
  return fallback
end

local function safeField(obj, key, fallback)
  if obj == nil then return fallback end
  local ok, value = pcall(function() return obj[key] end)
  if ok and value ~= nil then return value end
  return fallback
end

local function safeNumber(obj, key, fallback)
  local value = tonumber(safeField(obj, key, fallback))
  if not value or value ~= value or value == math.huge or value == -math.huge then return fallback end
  return value
end

local function safeNumberState(obj, key, fallback)
  local raw = safeField(obj, key, nil)
  local value = tonumber(raw)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return fallback, false
  end
  return value, true
end

local function safeBool(obj, key)
  return safeField(obj, key, false) == true
end

local function fallbackVec(x, y, z)
  if vec3 then
    local ok, converted = pcall(function() return vec3(x, y, z) end)
    if ok and converted then return converted end
  end
  return math3d.vec(x, y, z)
end

local function assettoRoot()
  if not ac or not ac.getFolder or not ac.FolderID or not ac.FolderID.Root then return nil end
  local ok, root = pcall(function() return ac.getFolder(ac.FolderID.Root) end)
  if ok and root and root ~= '' then return tostring(root):gsub('[\\/]+$', '') end
  return nil
end

local function safeCarFolderId(carId)
  local id = tostring(carId or ''):gsub('%.%.', ''):gsub('[\\/]+', '')
  id = id:gsub('[^%w_%-%+%.]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if id == '' then return 'unknown_car' end
  return id
end

local function parseJsonFile(path)
  if not io or not io.load or not JSON or not JSON.parse then return nil end
  local loaded, data = pcall(function() return io.load(path, nil) end)
  if not loaded or not data or data == '' then return nil end
  local ok, parsed = pcall(function() return JSON.parse(data) end)
  if ok and type(parsed) == 'table' then return parsed end
  return nil
end

local function carUiMetadata(carId)
  local cacheKey = tostring(carId or 'unknown_car')
  if metadataCache[cacheKey] ~= nil then return metadataCache[cacheKey] end
  local root = assettoRoot()
  local metadata = {}
  if root then
    metadata = parseJsonFile(root .. '/content/cars/' .. safeCarFolderId(carId) .. '/ui/ui_car.json') or {}
  end
  metadataCache[cacheKey] = metadata
  return metadata
end

local function tagsText(tags)
  if type(tags) ~= 'table' then return tostring(tags or '') end
  local out = {}
  for _, value in pairs(tags) do
    if value ~= nil then out[#out + 1] = tostring(value) end
  end
  return table.concat(out, ' ')
end

local function uiSpecsWeightKg(uiMeta)
  local specs = type(uiMeta and uiMeta.specs) == 'table' and uiMeta.specs or {}
  local raw = specs.weight or uiMeta.weight or uiMeta.mass
  if type(raw) == 'number' then return raw end
  local text = tostring(raw or ''):gsub(',', '')
  local number = tonumber(text:match('(%d+%.?%d*)'))
  return number or 0.0
end

local function positiveCarMassKg(car, uiMeta)
  local liveMass = safeNumber(car, 'mass', 0.0)
  if liveMass and liveMass > 0 then return liveMass end
  return uiSpecsWeightKg(uiMeta)
end

local function readSpeed(car)
  local explicitKmh = safeNumber(car, 'speedKmh', -1.0)
  local explicitMs = safeNumber(car, 'speedMs', -1.0)
  if explicitKmh >= 0 then
    local speedMs = explicitMs >= 0 and explicitMs or explicitKmh / 3.6
    return explicitKmh, speedMs
  end
  if explicitMs >= 0 then return explicitMs * 3.6, explicitMs end
  local rawSpeed = safeNumber(car, 'speed', 0.0)
  return rawSpeed * 3.6, rawSpeed
end

function M.trackId()
  return tostring(safeCall(function() return ac and ac.getTrackID and ac.getTrackID() end, 'unknown_track'))
end

local function raceConfigTrackLayout()
  local cfg = safeCall(function()
    if not ac or not ac.INIConfig then return nil end
    if ac.INIConfig.raceConfig then return ac.INIConfig.raceConfig() end
    if ac.INIConfig.load and ac.getFolder and ac.FolderID and ac.FolderID.Cfg then
      return ac.INIConfig.load(ac.getFolder(ac.FolderID.Cfg) .. '/race.ini', ac.INIFormat and ac.INIFormat.Default)
    end
    return nil
  end, nil)
  return tostring(safeCall(function() return cfg and cfg:get('RACE', 'CONFIG_TRACK', '') end, ''))
end

function M.trackLayout()
  local layout = tostring(safeCall(function() return ac and ac.getTrackLayout and ac.getTrackLayout() end, ''))
  if layout ~= '' then return layout end
  return raceConfigTrackLayout()
end

function M.carId()
  return tostring(safeCall(function() return ac and ac.getCarID and ac.getCarID(0) end, 'unknown_car'))
end

local function tyresName()
  return tostring(safeCall(function() return ac and ac.getTyresName and ac.getTyresName(0, -1) end, 'unknown'))
end

local function tyresLongName()
  return tostring(safeCall(function() return ac and ac.getTyresLongName and ac.getTyresLongName(0, -1, true) end, tyresName()))
end

local function setupState()
  if not ac or not ac.getCarSetupState then return 'unknown', '' end
  local ok, state, reason = pcall(function() return ac.getCarSetupState() end)
  if not ok then return 'unknown', '' end
  return tostring(state or 'unknown'), tostring(reason or '')
end

local function setupValue(cfg, section, fallback)
  return safeCall(function() return cfg and cfg:get(section, 'VALUE', fallback) end, fallback)
end

local function collectSetupValues(cfg, sections)
  local out = {}
  for _, section in ipairs(sections or {}) do
    local value = tonumber(setupValue(cfg, section, nil))
    if value then out[#out + 1] = value end
  end
  return out
end

local function collectSetupMap(cfg, sections)
  local out = {}
  for _, section in ipairs(sections or {}) do
    local value = tonumber(setupValue(cfg, section, nil))
    if value then out[section] = value end
  end
  return out
end

local function finiteProgress(value)
  local progress = tonumber(value)
  if not progress or progress ~= progress or progress == math.huge or progress == -math.huge then return nil end
  if progress > 1.5 then progress = progress / 100.0 end
  return progress % 1.0
end

local function readSetupSnapshot()
  local cfg = safeCall(function()
    if ac and ac.INIConfig and ac.INIConfig.currentSetup then return ac.INIConfig.currentSetup() end
    return nil
  end, nil)
  if not cfg then return {} end

  local wingSum, wingCount = 0, 0
  local wingValues = {}
  for _, section in ipairs({ 'WING_0', 'WING_1', 'WING_2', 'WING_3', 'WING_4', 'WING_5', 'WING_6', 'WING_7', 'WING_8', 'WING_9' }) do
    local value = tonumber(setupValue(cfg, section, nil))
    if value then
      wingValues[#wingValues + 1] = value
      wingSum = wingSum + value
      wingCount = wingCount + 1
    end
  end
  local alignmentSetupSections = {
    'CAMBER_LF', 'CAMBER_RF', 'CAMBER_LR', 'CAMBER_RR',
    'TOE_OUT_LF', 'TOE_OUT_RF', 'TOE_OUT_LR', 'TOE_OUT_RR',
  }
  local damperSetupSections = {
    'DAMP_BUMP_LF', 'DAMP_REBOUND_LF', 'DAMP_FAST_BUMP_LF', 'DAMP_FAST_REBOUND_LF',
    'DAMP_BUMP_RF', 'DAMP_REBOUND_RF', 'DAMP_FAST_BUMP_RF', 'DAMP_FAST_REBOUND_RF',
    'DAMP_BUMP_LR', 'DAMP_REBOUND_LR', 'DAMP_FAST_BUMP_LR', 'DAMP_FAST_REBOUND_LR',
    'DAMP_BUMP_RR', 'DAMP_REBOUND_RR', 'DAMP_FAST_BUMP_RR', 'DAMP_FAST_REBOUND_RR',
    'DAMPER_BUMP_LF', 'DAMPER_REBOUND_LF', 'DAMPER_FAST_BUMP_LF', 'DAMPER_FAST_REBOUND_LF',
    'DAMPER_BUMP_RF', 'DAMPER_REBOUND_RF', 'DAMPER_FAST_BUMP_RF', 'DAMPER_FAST_REBOUND_RF',
    'DAMPER_BUMP_LR', 'DAMPER_REBOUND_LR', 'DAMPER_FAST_BUMP_LR', 'DAMPER_FAST_REBOUND_LR',
    'DAMPER_BUMP_RR', 'DAMPER_REBOUND_RR', 'DAMPER_FAST_BUMP_RR', 'DAMPER_FAST_REBOUND_RR',
  }
  local mechanicalSetupSections = {
    'ARB_FRONT', 'ARB_REAR',
    'CAMBER_LF', 'CAMBER_RF', 'CAMBER_LR', 'CAMBER_RR',
    'TOE_OUT_LF', 'TOE_OUT_RF', 'TOE_OUT_LR', 'TOE_OUT_RR',
    'ROD_LENGTH_LF', 'ROD_LENGTH_RF', 'ROD_LENGTH_LR', 'ROD_LENGTH_RR',
    'SPRING_RATE_LF', 'SPRING_RATE_RF', 'SPRING_RATE_LR', 'SPRING_RATE_RR',
    'BUMP_STOP_RATE_LF', 'BUMP_STOP_RATE_RF', 'BUMP_STOP_RATE_LR', 'BUMP_STOP_RATE_RR',
    'DAMP_BUMP_LF', 'DAMP_REBOUND_LF', 'DAMP_FAST_BUMP_LF', 'DAMP_FAST_REBOUND_LF',
    'DAMP_BUMP_RF', 'DAMP_REBOUND_RF', 'DAMP_FAST_BUMP_RF', 'DAMP_FAST_REBOUND_RF',
    'DAMP_BUMP_LR', 'DAMP_REBOUND_LR', 'DAMP_FAST_BUMP_LR', 'DAMP_FAST_REBOUND_LR',
    'DAMP_BUMP_RR', 'DAMP_REBOUND_RR', 'DAMP_FAST_BUMP_RR', 'DAMP_FAST_REBOUND_RR',
    'DAMPER_BUMP_LF', 'DAMPER_REBOUND_LF', 'DAMPER_FAST_BUMP_LF', 'DAMPER_FAST_REBOUND_LF',
    'DAMPER_BUMP_RF', 'DAMPER_REBOUND_RF', 'DAMPER_FAST_BUMP_RF', 'DAMPER_FAST_REBOUND_RF',
    'DAMPER_BUMP_LR', 'DAMPER_REBOUND_LR', 'DAMPER_FAST_BUMP_LR', 'DAMPER_FAST_REBOUND_LR',
    'DAMPER_BUMP_RR', 'DAMPER_REBOUND_RR', 'DAMPER_FAST_BUMP_RR', 'DAMPER_FAST_REBOUND_RR',
  }
  local diffSetupSections = {
    'DIFF_POWER', 'DIFF_COAST', 'DIFF_PRELOAD',
  }
  local gearSetupSections = {
    'FINAL_GEAR_RATIO',
    'GEAR_1', 'GEAR_2', 'GEAR_3', 'GEAR_4', 'GEAR_5', 'GEAR_6', 'GEAR_7',
    'GEAR_8', 'GEAR_9', 'GEAR_10',
  }
  local drivetrainSetupSections = {
    'DIFF_POWER', 'DIFF_COAST', 'DIFF_PRELOAD',
    'FINAL_GEAR_RATIO',
    'GEAR_1', 'GEAR_2', 'GEAR_3', 'GEAR_4', 'GEAR_5', 'GEAR_6', 'GEAR_7',
    'GEAR_8', 'GEAR_9', 'GEAR_10',
  }
  local assistSetupSections = {
    'ABS', 'ABS_LEVEL', 'TC', 'TC_LEVEL', 'TRACTION_CONTROL',
    'ENGINE_LIMITER', 'ENGINE_BRAKE', 'BRAKE_MAP', 'ENGINE_MAP', 'POWER_MAP',
    'TURBO', 'TURBO_BOOST', 'KERS', 'ERS_DELIVERY', 'ERS_RECOVERY',
    'MGU_H_MODE', 'MGU_K_DELIVERY', 'MGU_K_RECOVERY',
  }
  local mechanicalSetupValues = collectSetupValues(cfg, mechanicalSetupSections)
  local mechanicalSetupMap = collectSetupMap(cfg, mechanicalSetupSections)
  local drivetrainSetupValues = collectSetupValues(cfg, drivetrainSetupSections)
  local drivetrainSetupMap = collectSetupMap(cfg, drivetrainSetupSections)
  local alignmentSetupMap = collectSetupMap(cfg, alignmentSetupSections)
  local damperSetupMap = collectSetupMap(cfg, damperSetupSections)
  local gearSetupMap = collectSetupMap(cfg, gearSetupSections)
  local diffSetupMap = collectSetupMap(cfg, diffSetupSections)
  local assistSetupValues = collectSetupValues(cfg, assistSetupSections)
  local assistSetupMap = collectSetupMap(cfg, assistSetupSections)
  local brakePowerMultRaw = setupValue(cfg, 'BRAKE_POWER_MULT', nil)
  local frontBiasRaw = setupValue(cfg, 'FRONT_BIAS', nil)
  local fuelRaw = setupValue(cfg, 'FUEL', nil)
  local ballastRaw = setupValue(cfg, 'BALLAST', nil)
  local restrictorRaw = setupValue(cfg, 'RESTRICTOR', nil)
  local pressureLFRaw = setupValue(cfg, 'PRESSURE_LF', nil)
  local pressureRFRaw = setupValue(cfg, 'PRESSURE_RF', nil)
  local pressureLRRaw = setupValue(cfg, 'PRESSURE_LR', nil)
  local pressureRRRaw = setupValue(cfg, 'PRESSURE_RR', nil)

  return {
    brakePowerMult = tonumber(brakePowerMultRaw) or 100.0,
    brakePowerMultKnown = brakePowerMultRaw ~= nil,
    frontBias = tonumber(frontBiasRaw) or 0.0,
    frontBiasKnown = frontBiasRaw ~= nil,
    fuel = tonumber(fuelRaw) or 0.0,
    fuelKnown = fuelRaw ~= nil,
    ballast = tonumber(ballastRaw) or 0.0,
    ballastKnown = ballastRaw ~= nil,
    restrictor = tonumber(restrictorRaw) or 0.0,
    restrictorKnown = restrictorRaw ~= nil,
    pressureLF = tonumber(pressureLFRaw) or 0.0,
    pressureLFKnown = pressureLFRaw ~= nil,
    pressureRF = tonumber(pressureRFRaw) or 0.0,
    pressureRFKnown = pressureRFRaw ~= nil,
    pressureLR = tonumber(pressureLRRaw) or 0.0,
    pressureLRKnown = pressureLRRaw ~= nil,
    pressureRR = tonumber(pressureRRRaw) or 0.0,
    pressureRRKnown = pressureRRRaw ~= nil,
    arbFront = tonumber(setupValue(cfg, 'ARB_FRONT', 0.0)) or 0.0,
    arbRear = tonumber(setupValue(cfg, 'ARB_REAR', 0.0)) or 0.0,
    camberLF = tonumber(setupValue(cfg, 'CAMBER_LF', 0.0)) or 0.0,
    camberRF = tonumber(setupValue(cfg, 'CAMBER_RF', 0.0)) or 0.0,
    camberLR = tonumber(setupValue(cfg, 'CAMBER_LR', 0.0)) or 0.0,
    camberRR = tonumber(setupValue(cfg, 'CAMBER_RR', 0.0)) or 0.0,
    toeOutLF = tonumber(setupValue(cfg, 'TOE_OUT_LF', 0.0)) or 0.0,
    toeOutRF = tonumber(setupValue(cfg, 'TOE_OUT_RF', 0.0)) or 0.0,
    toeOutLR = tonumber(setupValue(cfg, 'TOE_OUT_LR', 0.0)) or 0.0,
    toeOutRR = tonumber(setupValue(cfg, 'TOE_OUT_RR', 0.0)) or 0.0,
    springRateLF = tonumber(setupValue(cfg, 'SPRING_RATE_LF', 0.0)) or 0.0,
    springRateRF = tonumber(setupValue(cfg, 'SPRING_RATE_RF', 0.0)) or 0.0,
    springRateLR = tonumber(setupValue(cfg, 'SPRING_RATE_LR', 0.0)) or 0.0,
    springRateRR = tonumber(setupValue(cfg, 'SPRING_RATE_RR', 0.0)) or 0.0,
    bumpStopRateLF = tonumber(setupValue(cfg, 'BUMP_STOP_RATE_LF', 0.0)) or 0.0,
    bumpStopRateRF = tonumber(setupValue(cfg, 'BUMP_STOP_RATE_RF', 0.0)) or 0.0,
    bumpStopRateLR = tonumber(setupValue(cfg, 'BUMP_STOP_RATE_LR', 0.0)) or 0.0,
    bumpStopRateRR = tonumber(setupValue(cfg, 'BUMP_STOP_RATE_RR', 0.0)) or 0.0,
    wingSetting = wingCount > 0 and (wingSum / wingCount) or 0.0,
    wingSettingKnown = wingCount > 0,
    wingValues = wingValues,
    mechanicalSetupValues = mechanicalSetupValues,
    mechanicalSetupMap = mechanicalSetupMap,
    drivetrainSetupValues = drivetrainSetupValues,
    drivetrainSetupMap = drivetrainSetupMap,
    alignmentSetupMap = alignmentSetupMap,
    damperSetupMap = damperSetupMap,
    gearSetupMap = gearSetupMap,
    diffSetupMap = diffSetupMap,
    assistSetupValues = assistSetupValues,
    assistSetupMap = assistSetupMap,
  }
end

local function normalizedSplinePosition(car)
  return finiteProgress(safeField(car, 'splinePosition', nil)) or
    finiteProgress(safeField(car, 'normalizedSplinePosition', nil)) or
    finiteProgress(safeField(car, 'trackProgress', nil)) or
    finiteProgress(safeField(car, 'spline', nil)) or
    0
end

local function readSim()
  local sim = safeCall(function() return ac and ac.getSim and ac.getSim() end, nil) or {}
  return {
    roadGrip = safeNumber(sim, 'roadGrip', 1.0),
    ambientTemperature = safeNumber(sim, 'ambientTemperature', 26.0),
    roadTemperature = safeNumber(sim, 'roadTemperature', 32.0),
    rainIntensity = safeNumber(sim, 'rainIntensity', 0.0),
    rainWetness = safeNumber(sim, 'rainWetness', 0.0),
    rainWater = safeNumber(sim, 'rainWater', 0.0),
    windSpeedKmh = safeNumber(sim, 'windSpeedKmh', 0.0),
    trackLengthM = safeNumber(sim, 'trackLengthM', 0.0),
    carsCount = safeNumber(sim, 'carsCount', 1.0),
    gravity = math.abs(safeNumber(sim, 'gravity', -9.80665)),
  }
end

local function wheelAt(wheels, index)
  if safeField(wheels, 0, nil) ~= nil then
    return safeField(wheels, index, nil)
  end
  return safeField(wheels, index + 1, nil)
end

local function readWheel(wheel)
  wheel = wheel or {}
  return {
    tyreDirty = safeNumber(wheel, 'tyreDirty', 0.0),
    tyreWear = safeNumber(wheel, 'tyreWear', 0.0),
    tyreGrain = safeNumber(wheel, 'tyreGrain', 0.0),
    tyreBlister = safeNumber(wheel, 'tyreBlister', 0.0),
    tyreFlatSpot = safeNumber(wheel, 'tyreFlatSpot', 0.0),
    tyrePressure = safeNumber(wheel, 'tyrePressure', 0.0),
    tyreStaticPressure = safeNumber(wheel, 'tyreStaticPressure', 0.0),
    tyreCoreTemperature = safeNumber(wheel, 'tyreCoreTemperature', 0.0),
    tyreOptimumTemperature = safeNumber(wheel, 'tyreOptimumTemperature', 0.0),
    surfaceGrip = safeNumber(wheel, 'surfaceGrip', 1.0),
    surfaceDirt = safeNumber(wheel, 'surfaceDirt', 0.0),
    surfaceValidTrackKnown = safeField(wheel, 'surfaceValidTrack', nil) ~= nil,
    surfaceValidTrack = safeBool(wheel, 'surfaceValidTrack'),
    waterThickness = safeNumber(wheel, 'waterThickness', 0.0),
    slip = safeNumber(wheel, 'slip', 0.0),
    slipAngle = safeNumber(wheel, 'slipAngle', 0.0),
    slipRatio = safeNumber(wheel, 'slipRatio', 0.0),
    ndSlip = safeNumber(wheel, 'ndSlip', 0.0),
    loadK = safeNumber(wheel, 'loadK', 0.0),
  }
end

local function readWheels(car, physicsState)
  local wheels = safeField(car, 'wheels', nil) or safeField(physicsState, 'wheels', nil)
  local out = {}
  for i = 0, 3 do
    local wheel = wheelAt(wheels, i)
    if wheel then out[#out + 1] = readWheel(wheel) end
  end
  return out
end

local function normalizedDamage(value)
  local damage = tonumber(value)
  if not damage or damage ~= damage or damage == math.huge or damage == -math.huge then return 0.0 end
  if damage > 1.5 then damage = damage / 100.0 end
  if damage < 0 then return 0.0 end
  if damage > 1 then return 1.0 end
  return damage
end

local function readDamage(car, physicsState)
  local damage = 0.0
  for _, key in ipairs({ 'damage', 'damageLevel', 'bodyDamage', 'aeroDamage', 'engineDamage', 'suspensionDamage' }) do
    damage = math.max(damage, normalizedDamage(safeField(car, key, 0.0)))
    damage = math.max(damage, normalizedDamage(safeField(physicsState, key, 0.0)))
  end
  return damage
end

local function carIsUsableTrafficCandidate(other)
  if not other then return false end
  local activeKnown = safeField(other, 'isActive', nil)
  if activeKnown ~= nil and activeKnown ~= true then return false end
  local connectedKnown = safeField(other, 'isConnected', nil)
  if connectedKnown ~= nil and connectedKnown ~= true then return false end
  if safeBool(other, 'isInPit') or safeBool(other, 'isInPitlane') or safeBool(other, 'isRetired') then return false end
  return true
end

local function progressAheadMeters(playerProgress, otherProgress, trackLengthM)
  playerProgress = finiteProgress(playerProgress)
  otherProgress = finiteProgress(otherProgress)
  trackLengthM = tonumber(trackLengthM) or 0.0
  if not playerProgress or not otherProgress or trackLengthM <= 1.0 then return nil end
  local delta = (otherProgress - playerProgress) % 1.0
  if delta <= 0.00001 then return nil end
  return delta * trackLengthM
end

local function readTrafficProximity(playerCar, playerPos, playerForward, playerRight, sim)
  local carsCount = math.max(0, math.floor(safeField(sim, 'carsCount', 0.0) + 0.5))
  if carsCount <= 1 or not ac or not ac.getCar then
    return {
      trafficScanStatus = carsCount <= 1 and 'single_car' or 'unavailable',
      trafficCarsCount = carsCount,
      nearestOpponentAheadM = 0.0,
      nearestOpponentLateralM = 0.0,
      nearestOpponentDistanceM = 0.0,
      nearestOpponentIndex = -1,
    }
  end

  local playerProgress = normalizedSplinePosition(playerCar)
  local trackLengthM = safeNumber(sim, 'trackLengthM', 0.0)
  local nearest = nil
  for i = 1, math.min(carsCount - 1, 63) do
    local other = safeCall(function() return ac.getCar(i) end, nil)
    if carIsUsableTrafficCandidate(other) then
      local otherPosRaw = safeField(other, 'position', nil) or safeField(other, 'pos', nil)
      if otherPosRaw then
        local otherPos = math3d.vec(math3d.x(otherPosRaw), math3d.y(otherPosRaw), math3d.z(otherPosRaw))
        local delta = math3d.sub(otherPos, playerPos)
        local forwardM = math3d.dot(delta, playerForward)
        local lateralM = math.abs(math3d.dot(delta, playerRight))
        local distanceM = math3d.len(delta)
        local splineAheadM = progressAheadMeters(playerProgress, safeField(other, 'splinePosition', nil), trackLengthM)
        local aheadM = nil
        if splineAheadM and splineAheadM <= 200.0 then
          aheadM = splineAheadM
        elseif forwardM > 0.0 then
          aheadM = forwardM
        end
        if aheadM and aheadM > 0.0 and (not nearest or aheadM < nearest.nearestOpponentAheadM) then
          nearest = {
            nearestOpponentAheadM = aheadM,
            nearestOpponentLateralM = lateralM,
            nearestOpponentDistanceM = distanceM,
            nearestOpponentIndex = i,
          }
        end
      end
    end
  end

  if not nearest then
    return {
      trafficScanStatus = 'clear',
      trafficCarsCount = carsCount,
      nearestOpponentAheadM = 0.0,
      nearestOpponentLateralM = 0.0,
      nearestOpponentDistanceM = 0.0,
      nearestOpponentIndex = -1,
    }
  end
  nearest.trafficScanStatus = 'candidate_ahead'
  nearest.trafficCarsCount = carsCount
  return nearest
end

function M.read()
  local car = safeCall(function() return ac and ac.getCar and ac.getCar(0) end, nil) or {}
  local physicsState = safeCall(function() return ac and ac.getCarPhysics and ac.getCarPhysics(0) end, nil) or {}
  local state, reason = setupState()
  local carId = M.carId()
  local trackId = M.trackId()
  local trackLayout = M.trackLayout()
  local uiMeta = carUiMetadata(carId)
  local pos = safeField(car, 'position', nil) or safeField(car, 'pos', nil) or fallbackVec(0, 0, 0)
  local forward = safeField(car, 'look', nil) or safeField(car, 'forward', nil) or fallbackVec(0, 0, 1)
  local up = safeField(car, 'up', nil) or fallbackVec(0, 1, 0)
  local right = safeField(car, 'side', nil) or safeField(car, 'right', nil) or math3d.cross(up, forward)
  local speedKmh, speedMs = readSpeed(car)
  local setupSnapshot = readSetupSnapshot()
  local wheels = readWheels(car, physicsState)
  local sim = readSim()
  local fuel, fuelKnown = safeNumberState(car, 'fuel', 0.0)
  if not fuelKnown then fuel, fuelKnown = safeNumberState(physicsState, 'fuel', 0.0) end
  local ballast, ballastKnown = safeNumberState(car, 'ballast', 0.0)
  if not ballastKnown then ballast, ballastKnown = safeNumberState(physicsState, 'ballast', 0.0) end
  local restrictor, restrictorKnown = safeNumberState(car, 'restrictor', 0.0)
  if not restrictorKnown then restrictor, restrictorKnown = safeNumberState(physicsState, 'restrictor', 0.0) end
  local brakePowerMult, brakePowerMultKnown = safeNumberState(car, 'brakePowerMult', 0.0)
  if not brakePowerMultKnown then brakePowerMult, brakePowerMultKnown = safeNumberState(physicsState, 'brakePowerMult', 0.0) end
  local brakeBias, brakeBiasKnown = safeNumberState(car, 'brakeBias', 0.0)
  if not brakeBiasKnown then brakeBias, brakeBiasKnown = safeNumberState(physicsState, 'brakeBias', 0.0) end
  local absMode, absModeKnown = safeNumberState(car, 'absMode', 0.0)
  if not absModeKnown then absMode, absModeKnown = safeNumberState(physicsState, 'absMode', 0.0) end
  local tractionControlMode, tractionControlModeKnown = safeNumberState(car, 'tractionControlMode', 0.0)
  if not tractionControlModeKnown then tractionControlMode, tractionControlModeKnown = safeNumberState(physicsState, 'tractionControlMode', 0.0) end
  local wingSetting, wingSettingKnown = safeNumberState(car, 'wingSetting', 0.0)
  if not wingSettingKnown then wingSetting, wingSettingKnown = safeNumberState(physicsState, 'wingSetting', 0.0) end
  if not wingSettingKnown then wingSetting, wingSettingKnown = safeNumberState(car, 'wing', 0.0) end
  if not wingSettingKnown then wingSetting, wingSettingKnown = safeNumberState(physicsState, 'wing', 0.0) end
  local playerPos = math3d.vec(math3d.x(pos), math3d.y(pos), math3d.z(pos))
  local playerForward = math3d.norm(math3d.vec(math3d.x(forward), math3d.y(forward), math3d.z(forward)), math3d.vec(0, 0, 1))
  local playerUp = math3d.norm(math3d.vec(math3d.x(up), math3d.y(up), math3d.z(up)), math3d.vec(0, 1, 0))
  local playerRight = math3d.norm(math3d.vec(math3d.x(right), math3d.y(right), math3d.z(right)), math3d.vec(1, 0, 0))
  local result = {
    raw = car,
    index = safeNumber(car, 'index', 0.0),
    carId = carId,
    trackId = trackId,
    trackLayout = trackLayout,
    id = carId,
    name = tostring(safeField(car, 'name', uiMeta.name or '')),
    displayName = tostring(uiMeta.name or ''),
    brand = tostring(uiMeta.brand or ''),
    class = tostring(uiMeta.class or ''),
    className = tostring(uiMeta.class or ''),
    tags = tagsText(uiMeta.tags),
    speedKmh = speedKmh,
    speedMs = speedMs,
    splinePosition = normalizedSplinePosition(car),
    gear = safeNumber(car, 'gear', 0.0),
    gas = safeNumber(car, 'gas', safeNumber(car, 'throttle', 0.0)),
    brake = safeNumber(car, 'brake', 0.0),
    steer = safeNumber(car, 'steer', 0.0),
    mass = positiveCarMassKg(car, uiMeta),
    maxFuel = safeNumber(car, 'maxFuel', 0.0),
    fuel = fuel,
    fuelKnown = fuelKnown,
    ballast = ballast,
    ballastKnown = ballastKnown,
    restrictor = restrictor,
    restrictorKnown = restrictorKnown,
    brakePowerMult = brakePowerMult,
    brakePowerMultKnown = brakePowerMultKnown,
    wingSetting = wingSetting,
    wingSettingKnown = wingSettingKnown,
    brakeBias = brakeBias,
    brakeBiasKnown = brakeBiasKnown,
    absMode = absMode,
    absModeKnown = absModeKnown,
    tractionControlMode = tractionControlMode,
    tractionControlModeKnown = tractionControlModeKnown,
    absInAction = safeBool(car, 'absInAction'),
    tractionControlInAction = safeBool(car, 'tractionControlInAction'),
    isRacingCar = safeBool(car, 'isRacingCar'),
    isOpenWheeler = safeBool(car, 'isOpenWheeler'),
    extendedPhysics = safeBool(car, 'extendedPhysics'),
    physicsAvailable = safeBool(car, 'physicsAvailable') or safeBool(physicsState, 'isAvailable'),
    compoundIndex = safeNumber(car, 'compoundIndex', -1),
    tyresName = tyresName(),
    tyresLongName = tyresLongName(),
    setupState = state,
    setupReason = reason,
    setupSnapshot = setupSnapshot,
    damage = readDamage(car, physicsState),
    sim = sim,
    wheels = wheels,
    trafficProximity = readTrafficProximity(car, playerPos, playerForward, playerRight, sim),
    pos = playerPos,
    forward = playerForward,
    up = playerUp,
    right = playerRight,
  }
  result.physicsCapability = physics_capability.read(carId, assettoRoot(), result.index, result.compoundIndex, result.tyresName, result.tyresLongName)
  local setupFingerprint = setup_fingerprint.build(result)
  result.setupFingerprint = setupFingerprint
  return result
end

return M
