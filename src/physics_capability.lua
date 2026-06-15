local settings = require('src/settings')
local math3d = require('src/math3d')
local M = {}

local cache = {}
local DATA_CAR_INI = 'data/car.ini'
local DATA_TYRES_INI = 'data/tyres.ini'
local DATA_BRAKES_INI = 'data/brakes.ini'
local DATA_AERO_INI = 'data/aero.ini'
local DATA_SUSPENSIONS_INI = 'data/suspensions.ini'
local TYRE_NUMBER_KEYS = { 'DY_REF', 'DY0', 'DX_REF', 'DX0', 'FZ0', 'LS_EXPY', 'LS_EXPX', 'PRESSURE_STATIC', 'PRESSURE_IDEAL', 'FALLOFF_LEVEL', 'FALLOFF_SPEED', 'COMBINED_FACTOR', 'FRICTION_LIMIT_ANGLE', 'BRAKE_DX_MOD', 'RADIUS' }
local TYRE_STRING_KEYS = { 'NAME', 'SHORT_NAME' }

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function clamp(value, lo, hi)
  return math3d.clamp(finiteNumber(value, lo), lo, hi)
end

local function safeCarFolderId(carId)
  local id = tostring(carId or ''):gsub('%.%.', ''):gsub('[\\/]+', '')
  id = id:gsub('[^%w_%-%+%.]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if id == '' then return 'unknown_car' end
  return id
end

local function genericTyreToken(token)
  token = tostring(token or '')
  return token == 'slick' or token == 'tyre' or token == 'tire' or token == 'compound' or token == 'front' or token == 'rear'
end

local function normalizedTyreToken(value)
  local text = tostring(value or ''):lower()
  text = text:gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if text == '' or text == 'nil' or text == 'unknown' then return nil end
  local token = text
  if genericTyreToken(token) then return nil end
  return token
end

local function addTyreToken(tokens, value)
  local token = normalizedTyreToken(value)
  if token then tokens[token] = true end
end

local function addTyreTextTokens(tokens, value)
  addTyreToken(tokens, value)
end

local function tyreIdentityTokens(tyreName, tyreLongName)
  local tokens = {}
  addTyreTextTokens(tokens, tyreName)
  addTyreTextTokens(tokens, tyreLongName)
  return tokens
end

local function tyreNameCacheToken(tyreName, tyreLongName)
  local tokens = tyreIdentityTokens(tyreName, tyreLongName)
  local ordered = {}
  for token in pairs(tokens) do ordered[#ordered + 1] = token end
  table.sort(ordered)
  if #ordered == 0 then return 'no_tyre_name' end
  return table.concat(ordered, '+')
end

local function loadText(path)
  if not io or not io.load then return nil end
  local ok, data = pcall(function() return io.load(path, nil) end)
  if ok and data and data ~= '' then return data end
  return nil
end

local function fileExists(path)
  return loadText(path) ~= nil
end

local function stripComment(line)
  line = tostring(line or '')
  line = line:gsub('%s*;.*$', '')
  line = line:gsub('%s*//.*$', '')
  return line
end

local function parseIniFile(path)
  local text = loadText(path)
  if not text then return nil end
  local out = {}
  local section = nil
  for rawLine in text:gmatch('[^\r\n]+') do
    local line = stripComment(rawLine):gsub('^%s+', ''):gsub('%s+$', '')
    local sectionName = line:match('^%[([^%]]+)%]$')
    if sectionName then
      section = tostring(sectionName):upper()
      out[section] = out[section] or {}
    elseif section then
      local key, value = line:match('^([%w_]+)%s*=%s*(.-)%s*$')
      if key then out[section][tostring(key):upper()] = tostring(value or ''):gsub('%s+$', '') end
    end
  end
  return out
end

local function parseLutPeak(path)
  local text = loadText(path)
  if not text then return 0.0 end
  local peak = 0.0
  for rawLine in text:gmatch('[^\r\n]+') do
    local line = stripComment(rawLine)
    local value = line:match('|%s*([%+%-]?%d+%.?%d*)')
    if value then peak = math.max(peak, math.abs(finiteNumber(value, 0.0))) end
  end
  return peak
end

local function iniNumber(section, key, fallback)
  if type(section) ~= 'table' then return fallback end
  return finiteNumber(section[tostring(key):upper()], fallback)
end

local function iniText(section, key)
  if type(section) ~= 'table' then return '' end
  return tostring(section[tostring(key):upper()] or '')
end

local function average(values)
  local sum, count = 0.0, 0
  for _, value in ipairs(values or {}) do
    local number = tonumber(value)
    if number and number == number and number ~= math.huge and number ~= -math.huge and number > 0 then
      sum = sum + number
      count = count + 1
    end
  end
  if count == 0 then return 0.0, 0 end
  return sum / count, count
end

local function normalizedShare(value)
  local share = finiteNumber(value, 0.0)
  if share > 1.5 then share = share / 100.0 end
  return clamp(share, 0.0, 1.0)
end

local function normalizedPressurePsi(value)
  local pressure = finiteNumber(value, 0.0)
  if pressure <= 0.0 then return 0.0 end
  if pressure <= 5.0 then return pressure * 14.5037738 end
  if pressure > 80.0 and pressure <= 500.0 then return pressure * 0.145037738 end
  return pressure
end

local function tyreEvidence(tyres)
  local lateral, longitudinal, loadRefs, loadSensitivityLat, loadSensitivityLong, pressureStatic, pressureIdeal, radii = {}, {}, {}, {}, {}, {}, {}, {}
  local falloffLevel, falloffSpeed, combinedFactor, frictionLimitAngleDeg, brakeDxMod = {}, {}, {}, {}, {}
  local frontLateral, rearLateral = {}, {}
  local frontLongitudinal, rearLongitudinal = {}, {}
  local frontLoadRefs, rearLoadRefs = {}, {}
  local frontLoadSensitivityLat, rearLoadSensitivityLat = {}, {}
  local frontLoadSensitivityLong, rearLoadSensitivityLong = {}, {}
  local frontPressureStatic, rearPressureStatic = {}, {}
  local frontPressureIdeal, rearPressureIdeal = {}, {}
  local frontFalloffLevel, rearFalloffLevel = {}, {}
  local frontFalloffSpeed, rearFalloffSpeed = {}, {}
  local frontCombinedFactor, rearCombinedFactor = {}, {}
  local frontFrictionLimitAngleDeg, rearFrictionLimitAngleDeg = {}, {}
  local frontBrakeDxMod, rearBrakeDxMod = {}, {}
  for sectionName, section in pairs(tyres or {}) do
    if sectionName:find('^FRONT') or sectionName:find('^REAR') then
      local lateralMu = iniNumber(section, 'DY_REF', iniNumber(section, 'DY0', 0.0))
      local longitudinalMu = iniNumber(section, 'DX_REF', iniNumber(section, 'DX0', 0.0))
      local loadRefN = iniNumber(section, 'FZ0', 0.0)
      local loadSensitivityLatValue = iniNumber(section, 'LS_EXPY', 0.0)
      local loadSensitivityLongValue = iniNumber(section, 'LS_EXPX', 0.0)
      local pressureStaticPsi = normalizedPressurePsi(iniNumber(section, 'PRESSURE_STATIC', 0.0))
      local pressureIdealPsi = normalizedPressurePsi(iniNumber(section, 'PRESSURE_IDEAL', 0.0))
      local falloffLevelValue = iniNumber(section, 'FALLOFF_LEVEL', 0.0)
      local falloffSpeedValue = iniNumber(section, 'FALLOFF_SPEED', 0.0)
      local combinedFactorValue = iniNumber(section, 'COMBINED_FACTOR', 0.0)
      local frictionLimitAngleValue = iniNumber(section, 'FRICTION_LIMIT_ANGLE', 0.0)
      local brakeDxModValue = iniNumber(section, 'BRAKE_DX_MOD', 0.0)
      lateral[#lateral + 1] = lateralMu
      longitudinal[#longitudinal + 1] = longitudinalMu
      loadRefs[#loadRefs + 1] = loadRefN
      loadSensitivityLat[#loadSensitivityLat + 1] = loadSensitivityLatValue
      loadSensitivityLong[#loadSensitivityLong + 1] = loadSensitivityLongValue
      pressureStatic[#pressureStatic + 1] = pressureStaticPsi
      pressureIdeal[#pressureIdeal + 1] = pressureIdealPsi
      falloffLevel[#falloffLevel + 1] = falloffLevelValue
      falloffSpeed[#falloffSpeed + 1] = falloffSpeedValue
      combinedFactor[#combinedFactor + 1] = combinedFactorValue
      frictionLimitAngleDeg[#frictionLimitAngleDeg + 1] = frictionLimitAngleValue
      brakeDxMod[#brakeDxMod + 1] = brakeDxModValue
      radii[#radii + 1] = iniNumber(section, 'RADIUS', 0.0)
      if sectionName:find('^FRONT') then
        frontLateral[#frontLateral + 1] = lateralMu
        frontLongitudinal[#frontLongitudinal + 1] = longitudinalMu
        frontLoadRefs[#frontLoadRefs + 1] = loadRefN
        frontLoadSensitivityLat[#frontLoadSensitivityLat + 1] = loadSensitivityLatValue
        frontLoadSensitivityLong[#frontLoadSensitivityLong + 1] = loadSensitivityLongValue
        frontPressureStatic[#frontPressureStatic + 1] = pressureStaticPsi
        frontPressureIdeal[#frontPressureIdeal + 1] = pressureIdealPsi
        frontFalloffLevel[#frontFalloffLevel + 1] = falloffLevelValue
        frontFalloffSpeed[#frontFalloffSpeed + 1] = falloffSpeedValue
        frontCombinedFactor[#frontCombinedFactor + 1] = combinedFactorValue
        frontFrictionLimitAngleDeg[#frontFrictionLimitAngleDeg + 1] = frictionLimitAngleValue
        frontBrakeDxMod[#frontBrakeDxMod + 1] = brakeDxModValue
      elseif sectionName:find('^REAR') then
        rearLateral[#rearLateral + 1] = lateralMu
        rearLongitudinal[#rearLongitudinal + 1] = longitudinalMu
        rearLoadRefs[#rearLoadRefs + 1] = loadRefN
        rearLoadSensitivityLat[#rearLoadSensitivityLat + 1] = loadSensitivityLatValue
        rearLoadSensitivityLong[#rearLoadSensitivityLong + 1] = loadSensitivityLongValue
        rearPressureStatic[#rearPressureStatic + 1] = pressureStaticPsi
        rearPressureIdeal[#rearPressureIdeal + 1] = pressureIdealPsi
        rearFalloffLevel[#rearFalloffLevel + 1] = falloffLevelValue
        rearFalloffSpeed[#rearFalloffSpeed + 1] = falloffSpeedValue
        rearCombinedFactor[#rearCombinedFactor + 1] = combinedFactorValue
        rearFrictionLimitAngleDeg[#rearFrictionLimitAngleDeg + 1] = frictionLimitAngleValue
        rearBrakeDxMod[#rearBrakeDxMod + 1] = brakeDxModValue
      end
    end
  end
  local lateralMu, lateralCount = average(lateral)
  local longitudinalMu, longitudinalCount = average(longitudinal)
  local frontLateralMu = select(1, average(frontLateral))
  local rearLateralMu = select(1, average(rearLateral))
  local frontLongitudinalMu = select(1, average(frontLongitudinal))
  local rearLongitudinalMu = select(1, average(rearLongitudinal))
  local loadRefN = select(1, average(loadRefs))
  local frontLoadRefN = select(1, average(frontLoadRefs))
  local rearLoadRefN = select(1, average(rearLoadRefs))
  local loadSensitivityLatValue = select(1, average(loadSensitivityLat))
  local loadSensitivityLongValue = select(1, average(loadSensitivityLong))
  local frontLoadSensitivityLatValue = select(1, average(frontLoadSensitivityLat))
  local rearLoadSensitivityLatValue = select(1, average(rearLoadSensitivityLat))
  local frontLoadSensitivityLongValue = select(1, average(frontLoadSensitivityLong))
  local rearLoadSensitivityLongValue = select(1, average(rearLoadSensitivityLong))
  local pressureStaticPsi = select(1, average(pressureStatic))
  local pressureIdealPsi = select(1, average(pressureIdeal))
  local frontPressureStaticPsi = select(1, average(frontPressureStatic))
  local rearPressureStaticPsi = select(1, average(rearPressureStatic))
  local frontPressureIdealPsi = select(1, average(frontPressureIdeal))
  local rearPressureIdealPsi = select(1, average(rearPressureIdeal))
  local falloffLevelValue = select(1, average(falloffLevel))
  local frontFalloffLevelValue = select(1, average(frontFalloffLevel))
  local rearFalloffLevelValue = select(1, average(rearFalloffLevel))
  local falloffSpeedValue = select(1, average(falloffSpeed))
  local frontFalloffSpeedValue = select(1, average(frontFalloffSpeed))
  local rearFalloffSpeedValue = select(1, average(rearFalloffSpeed))
  local combinedFactorValue = select(1, average(combinedFactor))
  local frontCombinedFactorValue = select(1, average(frontCombinedFactor))
  local rearCombinedFactorValue = select(1, average(rearCombinedFactor))
  local frictionLimitAngleDegValue = select(1, average(frictionLimitAngleDeg))
  local frontFrictionLimitAngleDegValue = select(1, average(frontFrictionLimitAngleDeg))
  local rearFrictionLimitAngleDegValue = select(1, average(rearFrictionLimitAngleDeg))
  local brakeDxModValue = select(1, average(brakeDxMod))
  local frontBrakeDxModValue = select(1, average(frontBrakeDxMod))
  local rearBrakeDxModValue = select(1, average(rearBrakeDxMod))
  local radiusM = select(1, average(radii))
  if radiusM <= 0 then radiusM = 0.32 end
  return {
    lateralMu = lateralMu,
    longitudinalMu = longitudinalMu,
    frontLateralMu = frontLateralMu,
    rearLateralMu = rearLateralMu,
    frontLongitudinalMu = frontLongitudinalMu,
    rearLongitudinalMu = rearLongitudinalMu,
    loadRefN = loadRefN,
    frontLoadRefN = frontLoadRefN,
    rearLoadRefN = rearLoadRefN,
    loadSensitivityLat = loadSensitivityLatValue,
    loadSensitivityLong = loadSensitivityLongValue,
    frontLoadSensitivityLat = frontLoadSensitivityLatValue,
    rearLoadSensitivityLat = rearLoadSensitivityLatValue,
    frontLoadSensitivityLong = frontLoadSensitivityLongValue,
    rearLoadSensitivityLong = rearLoadSensitivityLongValue,
    pressureStaticPsi = pressureStaticPsi,
    pressureIdealPsi = pressureIdealPsi,
    frontPressureStaticPsi = frontPressureStaticPsi,
    rearPressureStaticPsi = rearPressureStaticPsi,
    frontPressureIdealPsi = frontPressureIdealPsi,
    rearPressureIdealPsi = rearPressureIdealPsi,
    falloffLevel = falloffLevelValue,
    frontFalloffLevel = frontFalloffLevelValue,
    rearFalloffLevel = rearFalloffLevelValue,
    falloffSpeed = falloffSpeedValue,
    frontFalloffSpeed = frontFalloffSpeedValue,
    rearFalloffSpeed = rearFalloffSpeedValue,
    combinedFactor = combinedFactorValue,
    frontCombinedFactor = frontCombinedFactorValue,
    rearCombinedFactor = rearCombinedFactorValue,
    frictionLimitAngleDeg = frictionLimitAngleDegValue,
    frontFrictionLimitAngleDeg = frontFrictionLimitAngleDegValue,
    rearFrictionLimitAngleDeg = rearFrictionLimitAngleDegValue,
    brakeDxMod = brakeDxModValue,
    frontBrakeDxMod = frontBrakeDxModValue,
    rearBrakeDxMod = rearBrakeDxModValue,
    radiusM = radiusM,
    lateralCount = lateralCount,
    longitudinalCount = longitudinalCount,
  }
end

local function defaultLutPeak(dataDir, lutName)
  return parseLutPeak(dataDir .. '/' .. tostring(lutName or ''))
end

local function suspensionEvidence(suspensions)
  local basic = suspensions and suspensions.BASIC or {}
  local front = suspensions and suspensions.FRONT or {}
  local rear = suspensions and suspensions.REAR or {}
  local wheelbaseM = iniNumber(basic, 'WHEELBASE', 0.0)
  local cgLocation = iniNumber(basic, 'CG_LOCATION', 0.0)
  local frontTrackM = iniNumber(front, 'TRACK', 0.0)
  local rearTrackM = iniNumber(rear, 'TRACK', 0.0)
  local count = 0
  if wheelbaseM > 0.0 then count = count + 1 end
  if cgLocation > 0.0 then count = count + 1 end
  if frontTrackM > 0.0 then count = count + 1 end
  if rearTrackM > 0.0 then count = count + 1 end
  return {
    wheelbaseM = wheelbaseM,
    cgLocation = cgLocation,
    frontTrackM = frontTrackM,
    rearTrackM = rearTrackM,
    count = count,
  }
end

local function aeroEvidence(aero, dataDir, lutPeakFor)
  local score = 0.0
  local wings = 0
  lutPeakFor = lutPeakFor or defaultLutPeak
  for sectionName, section in pairs(aero or {}) do
    if sectionName:find('^WING_') then
      local chord = iniNumber(section, 'CHORD', 0.0)
      local span = iniNumber(section, 'SPAN', 0.0)
      local clGain = math.abs(iniNumber(section, 'CL_GAIN', 0.0))
      local lutName = iniText(section, 'LUT_AOA_CL')
      local lutPeak = 0.0
      if lutName ~= '' then lutPeak = lutPeakFor(dataDir, lutName) end
      if clGain > 0.0 or lutPeak > 0.0 then
        local area = math.max(0.10, chord * span)
        local liftPeak = math.max(lutPeak, clGain > 0 and 0.45 or 0.0)
        score = score + area * math.max(0.05, clGain) * liftPeak
        wings = wings + 1
      end
    end
  end
  return score, wings
end

local function aeroDataStatus(aero, aeroWings)
  if type(aero) ~= 'table' or next(aero) == nil then return 'aero_data_missing' end
  if finiteNumber(aeroWings, 0.0) > 0.0 then return 'aero_wings_present' end
  return 'aero_no_downforce_sections'
end

local function estimateFromPhysics(dataDir, carIni, tyresIni, brakesIni, aeroIni, suspensionsIni, lutPeakFor)
  local basic = carIni and carIni.BASIC or {}
  local massKg = iniNumber(basic, 'TOTALMASS', 0.0)
  local tyre = tyreEvidence(tyresIni)
  local suspension = suspensionEvidence(suspensionsIni)
  local brakeData = brakesIni and brakesIni.DATA or {}
  local maxTorque = iniNumber(brakeData, 'MAX_TORQUE', 0.0)
  local brakeFrontShare = normalizedShare(iniNumber(brakeData, 'FRONT_SHARE', 0.0))
  local aeroScore, aeroWings = aeroEvidence(aeroIni, dataDir, lutPeakFor)
  local aeroStatus = aeroDataStatus(aeroIni, aeroWings)
  local hasCorneringTyres = tyre.lateralCount > 0
  local hasBrakeTyres = tyre.longitudinalCount > 0
  local hasBrakes = maxTorque > 0 and massKg > 0
  local hasLateralOnlyBrakeEstimate = not hasBrakeTyres and hasBrakes and hasCorneringTyres
  local hasTyres = hasCorneringTyres or hasBrakeTyres
  local brakeDataStatus = hasBrakes and 'brake_torque_present' or 'brake_torque_missing'
  local confidence = 0.42

  if massKg > 0 then confidence = confidence + 0.06 end
  if hasCorneringTyres then confidence = confidence + 0.12 end
  if hasBrakeTyres then confidence = confidence + 0.08 end
  if hasLateralOnlyBrakeEstimate then confidence = confidence + 0.04 end
  if hasBrakes then confidence = confidence + 0.12 end
  if aeroWings > 0 then confidence = confidence + 0.10 end
  if suspension.count > 0 then confidence = confidence + 0.04 end
  if not hasBrakes then
    confidence = math.min(confidence, finiteNumber(settings.PHYSICS_MISSING_BRAKE_TORQUE_CONFIDENCE_CAP, 0.72))
  end

  if not hasTyres then
    return {
      available = false,
      source = 'ac_physics_incomplete',
      dataStatus = 'unpacked_data_incomplete',
      confidence = clamp(confidence, 0.0, 0.55),
      massKg = massKg,
      wheelbaseM = suspension.wheelbaseM,
      cgLocation = suspension.cgLocation,
      frontTrackM = suspension.frontTrackM,
      rearTrackM = suspension.rearTrackM,
      tyreLateralMu = tyre.lateralMu,
      tyreLongitudinalMu = tyre.longitudinalMu,
      tyreFrontLateralMu = tyre.frontLateralMu,
      tyreRearLateralMu = tyre.rearLateralMu,
      tyreFrontLongitudinalMu = tyre.frontLongitudinalMu,
      tyreRearLongitudinalMu = tyre.rearLongitudinalMu,
      tyreLoadRefN = tyre.loadRefN,
      tyreFrontLoadRefN = tyre.frontLoadRefN,
      tyreRearLoadRefN = tyre.rearLoadRefN,
      tyreLoadSensitivityLat = tyre.loadSensitivityLat,
      tyreLoadSensitivityLong = tyre.loadSensitivityLong,
      tyreFrontLoadSensitivityLat = tyre.frontLoadSensitivityLat,
      tyreRearLoadSensitivityLat = tyre.rearLoadSensitivityLat,
      tyreFrontLoadSensitivityLong = tyre.frontLoadSensitivityLong,
      tyreRearLoadSensitivityLong = tyre.rearLoadSensitivityLong,
      tyrePressureStaticPsi = tyre.pressureStaticPsi,
      tyrePressureIdealPsi = tyre.pressureIdealPsi,
      tyreFrontPressureStaticPsi = tyre.frontPressureStaticPsi,
      tyreRearPressureStaticPsi = tyre.rearPressureStaticPsi,
      tyreFrontPressureIdealPsi = tyre.frontPressureIdealPsi,
      tyreRearPressureIdealPsi = tyre.rearPressureIdealPsi,
      tyreFalloffLevel = tyre.falloffLevel,
      tyreFrontFalloffLevel = tyre.frontFalloffLevel,
      tyreRearFalloffLevel = tyre.rearFalloffLevel,
      tyreFalloffSpeed = tyre.falloffSpeed,
      tyreFrontFalloffSpeed = tyre.frontFalloffSpeed,
      tyreRearFalloffSpeed = tyre.rearFalloffSpeed,
      tyreCombinedFactor = tyre.combinedFactor,
      tyreFrontCombinedFactor = tyre.frontCombinedFactor,
      tyreRearCombinedFactor = tyre.rearCombinedFactor,
      tyreFrictionLimitAngleDeg = tyre.frictionLimitAngleDeg,
      tyreFrontFrictionLimitAngleDeg = tyre.frontFrictionLimitAngleDeg,
      tyreRearFrictionLimitAngleDeg = tyre.rearFrictionLimitAngleDeg,
      tyreBrakeDxMod = tyre.brakeDxMod,
      tyreFrontBrakeDxMod = tyre.frontBrakeDxMod,
      tyreRearBrakeDxMod = tyre.rearBrakeDxMod,
      tyreRadiusM = tyre.radiusM,
      tyreLateralCount = tyre.lateralCount,
      tyreLongitudinalCount = tyre.longitudinalCount,
      brakeTorqueNm = maxTorque,
      brakeFrontShare = brakeFrontShare,
      brakeDataStatus = brakeDataStatus,
      aeroDataStatus = aeroStatus,
      aeroScore = aeroScore,
      aeroWingCount = aeroWings,
    }
  end

  local corneringG = nil
  if hasCorneringTyres then corneringG = clamp(tyre.lateralMu * 0.98, 0.65, 3.20) end
  local brakeG = nil
  if hasBrakeTyres or hasLateralOnlyBrakeEstimate then
    local brakeGripG = tyre.longitudinalMu * 1.00
    if not hasBrakeTyres then
      brakeGripG = math.min(
        tyre.lateralMu * finiteNumber(settings.PHYSICS_LATERAL_ONLY_BRAKE_GRIP_SCALE, 0.72),
        finiteNumber(settings.PHYSICS_LATERAL_ONLY_BRAKE_MAX_G, 1.55))
    end
    local torqueBrakeG = 0.0
    if hasBrakes then torqueBrakeG = maxTorque * 4.0 / math.max(0.10, tyre.radiusM) / massKg / 9.80665 * 0.30 end
    brakeG = brakeGripG
    if torqueBrakeG > 0.0 then
      brakeG = math.min(brakeGripG * 1.04, torqueBrakeG)
      if hasBrakeTyres and brakeGripG > 0.0 then
        local underreadMinRawShare = finiteNumber(settings.PHYSICS_TORQUE_UNDERREAD_MIN_RAW_GRIP_SHARE, 0.55)
        local underreadFloorScale = finiteNumber(settings.PHYSICS_TORQUE_UNDERREAD_GRIP_FLOOR_SCALE, 0.86)
        local rawShare = torqueBrakeG / brakeGripG
        local underreadFloorG = math.min(
          brakeGripG * underreadFloorScale,
          finiteNumber(settings.PHYSICS_MISSING_BRAKE_TORQUE_MAX_G, 1.45))
        if rawShare >= underreadMinRawShare and brakeG < underreadFloorG then
          brakeG = math.min(brakeGripG * 1.04, underreadFloorG)
          brakeDataStatus = 'brake_torque_underread_grip_floor'
          confidence = math.min(confidence, finiteNumber(settings.PHYSICS_TORQUE_UNDERREAD_CONFIDENCE_CAP, 0.82))
        end
      end
    else
      brakeG = clamp(math.min(brakeGripG * finiteNumber(settings.PHYSICS_MISSING_BRAKE_TORQUE_SCALE, 0.82),
        finiteNumber(settings.PHYSICS_MISSING_BRAKE_TORQUE_MAX_G, 1.45)), 0.55, finiteNumber(settings.MAX_DYNAMIC_BRAKE_G, 4.50))
    end
    brakeG = clamp(brakeG, 0.55, finiteNumber(settings.MAX_DYNAMIC_BRAKE_G, 4.50))
  end

  local speedAeroStrength = nil
  if aeroStatus ~= 'aero_data_missing' then
    local aeroPerKg = massKg > 0 and aeroScore / massKg or 0.0
    speedAeroStrength = clamp(aeroPerKg * 22.0, 0.0, 0.30)
    if aeroWings == 0 then speedAeroStrength = 0.0 end
  end

  return {
    available = true,
    source = 'ac_physics_unpacked',
    dataStatus = 'unpacked_data',
    confidence = clamp(confidence, 0.65, 0.92),
    corneringG = corneringG,
    brakeG = brakeG,
    speedAeroStrength = speedAeroStrength,
    massKg = massKg,
    wheelbaseM = suspension.wheelbaseM,
    cgLocation = suspension.cgLocation,
    frontTrackM = suspension.frontTrackM,
    rearTrackM = suspension.rearTrackM,
    tyreLateralMu = tyre.lateralMu,
    tyreLongitudinalMu = tyre.longitudinalMu,
    tyreFrontLateralMu = tyre.frontLateralMu,
    tyreRearLateralMu = tyre.rearLateralMu,
    tyreFrontLongitudinalMu = tyre.frontLongitudinalMu,
    tyreRearLongitudinalMu = tyre.rearLongitudinalMu,
    tyreLoadRefN = tyre.loadRefN,
    tyreFrontLoadRefN = tyre.frontLoadRefN,
    tyreRearLoadRefN = tyre.rearLoadRefN,
    tyreLoadSensitivityLat = tyre.loadSensitivityLat,
    tyreLoadSensitivityLong = tyre.loadSensitivityLong,
    tyreFrontLoadSensitivityLat = tyre.frontLoadSensitivityLat,
    tyreRearLoadSensitivityLat = tyre.rearLoadSensitivityLat,
    tyreFrontLoadSensitivityLong = tyre.frontLoadSensitivityLong,
    tyreRearLoadSensitivityLong = tyre.rearLoadSensitivityLong,
    tyrePressureStaticPsi = tyre.pressureStaticPsi,
    tyrePressureIdealPsi = tyre.pressureIdealPsi,
    tyreFrontPressureStaticPsi = tyre.frontPressureStaticPsi,
    tyreRearPressureStaticPsi = tyre.rearPressureStaticPsi,
    tyreFrontPressureIdealPsi = tyre.frontPressureIdealPsi,
    tyreRearPressureIdealPsi = tyre.rearPressureIdealPsi,
    tyreFalloffLevel = tyre.falloffLevel,
    tyreFrontFalloffLevel = tyre.frontFalloffLevel,
    tyreRearFalloffLevel = tyre.rearFalloffLevel,
    tyreFalloffSpeed = tyre.falloffSpeed,
    tyreFrontFalloffSpeed = tyre.frontFalloffSpeed,
    tyreRearFalloffSpeed = tyre.rearFalloffSpeed,
    tyreCombinedFactor = tyre.combinedFactor,
    tyreFrontCombinedFactor = tyre.frontCombinedFactor,
    tyreRearCombinedFactor = tyre.rearCombinedFactor,
    tyreFrictionLimitAngleDeg = tyre.frictionLimitAngleDeg,
    tyreFrontFrictionLimitAngleDeg = tyre.frontFrictionLimitAngleDeg,
    tyreRearFrictionLimitAngleDeg = tyre.rearFrictionLimitAngleDeg,
    tyreBrakeDxMod = tyre.brakeDxMod,
    tyreFrontBrakeDxMod = tyre.frontBrakeDxMod,
    tyreRearBrakeDxMod = tyre.rearBrakeDxMod,
    tyreRadiusM = tyre.radiusM,
    tyreLateralCount = tyre.lateralCount,
    tyreLongitudinalCount = tyre.longitudinalCount,
    brakeTorqueNm = maxTorque,
    brakeFrontShare = brakeFrontShare,
    brakeDataStatus = brakeDataStatus,
    aeroDataStatus = aeroStatus,
    aeroScore = aeroScore,
    aeroWingCount = aeroWings,
  }
end

local function cfgValue(cfg, section, key, fallback)
  if not cfg or not cfg.get then return fallback end
  local ok, value = pcall(function() return cfg:get(section, key, fallback) end)
  if ok and value ~= nil then return value end
  return fallback
end

local function cfgNumberText(cfg, section, key)
  local sentinel = -987654321.0
  local value = tonumber(cfgValue(cfg, section, key, sentinel))
  if value and value ~= sentinel then return tostring(value) end
  return nil
end

local function cfgStringText(cfg, section, key)
  local value = tostring(cfgValue(cfg, section, key, ''))
  if value ~= '' then return value end
  return nil
end

local function buildCfgSection(cfg, sectionName, numberKeys, stringKeys)
  local section = {}
  local any = false
  for _, key in ipairs(numberKeys or {}) do
    local value = cfgNumberText(cfg, sectionName, key)
    if value ~= nil then
      section[key] = value
      any = true
    end
  end
  for _, key in ipairs(stringKeys or {}) do
    local value = cfgStringText(cfg, sectionName, key)
    if value ~= nil then
      section[key] = value
      any = true
    end
  end
  return any and section or nil
end

local function loadCspCarDataIni(carIndex, fileName)
  if not ac or not ac.INIConfig or not ac.INIConfig.carData then return nil end
  local ok, cfg = pcall(function() return ac.INIConfig.carData(carIndex, fileName) end)
  if ok and cfg then return cfg end
  return nil
end

local function compoundIndexKnown(compoundIndex)
  local raw = tonumber(compoundIndex)
  if not raw or raw ~= raw or raw == math.huge or raw == -math.huge then return false end
  return raw >= 0.0
end

local function selectedTyreSections(compoundIndex)
  local known = compoundIndexKnown(compoundIndex)
  if not known then return { 'FRONT', 'REAR' }, false end
  local index = math.floor(finiteNumber(compoundIndex, 0.0) + 0.5)
  if index <= 0 then return { 'FRONT', 'REAR' }, true end
  return { 'FRONT_' .. tostring(index), 'REAR_' .. tostring(index) }, true
end

local function tyreSectionSuffix(sectionName)
  local name = tostring(sectionName or ''):upper()
  if name == 'FRONT' or name == 'REAR' then return '' end
  local frontSuffix = name:match('^FRONT(_%d+)$')
  if frontSuffix then return frontSuffix end
  local rearSuffix = name:match('^REAR(_%d+)$')
  if rearSuffix then return rearSuffix end
  return nil
end

local function tyreSectionAxle(sectionName)
  local name = tostring(sectionName or ''):upper()
  if name:find('^FRONT') then return 'FRONT' end
  if name:find('^REAR') then return 'REAR' end
  return nil
end

local function tyreSectionMatchesName(section, liveTyreTokens)
  if type(section) ~= 'table' or type(liveTyreTokens) ~= 'table' then return false end
  for _, key in ipairs({ 'NAME', 'SHORT_NAME' }) do
    local text = iniText(section, key)
    if text ~= '' then
      local sectionTokens = {}
      addTyreTextTokens(sectionTokens, text)
      for token in pairs(sectionTokens) do
        if liveTyreTokens[token] then return true end
      end
    end
  end
  return false
end

local function matchedTyreSectionsByName(tyresIni, tyreName, tyreLongName)
  local liveTyreTokens = tyreIdentityTokens(tyreName, tyreLongName)
  local hasLiveTyreToken = false
  for _ in pairs(liveTyreTokens) do
    hasLiveTyreToken = true
    break
  end
  if not hasLiveTyreToken then return nil, nil end

  local candidates, suffixes = {}, {}
  for sectionName, section in pairs(tyresIni or {}) do
    local axle = tyreSectionAxle(sectionName)
    local suffix = tyreSectionSuffix(sectionName)
    if axle and suffix ~= nil then
      if not candidates[suffix] then
        candidates[suffix] = {}
        suffixes[#suffixes + 1] = suffix
      end
      candidates[suffix][axle] = section
      candidates[suffix][axle .. 'Match'] = tyreSectionMatchesName(section, liveTyreTokens)
    end
  end
  table.sort(suffixes)

  local partial = nil
  for _, suffix in ipairs(suffixes) do
    local candidate = candidates[suffix]
    if candidate.FRONT and candidate.REAR and candidate.FRONTMatch and candidate.REARMatch then
      return { FRONT = candidate.FRONT, REAR = candidate.REAR }, 'selected_tyre_compound_name_match'
    end
    if not partial and ((candidate.FRONT and candidate.FRONTMatch) or (candidate.REAR and candidate.REARMatch)) then
      partial = candidate
    end
  end
  if partial then
    local out = {}
    if partial.FRONT and partial.FRONTMatch then out.FRONT = partial.FRONT end
    if partial.REAR and partial.REARMatch then out.REAR = partial.REAR end
    return out, 'selected_tyre_compound_name_match_partial_axle'
  end
  return nil, nil
end

local function buildCspCarIni(cfg)
  local basic = buildCfgSection(cfg, 'BASIC', { 'TOTALMASS' }, nil)
  return basic and { BASIC = basic } or {}
end

local function buildCspTyreSection(cfg, sectionName)
  return buildCfgSection(cfg, sectionName, TYRE_NUMBER_KEYS, TYRE_STRING_KEYS)
end

local function buildCspAllTyresIni(cfg)
  local out = {}
  for _, prefix in ipairs({ 'FRONT', 'REAR' }) do
    for i = 0, 8 do
      local sectionName = i == 0 and prefix or (prefix .. '_' .. tostring(i))
      local section = buildCspTyreSection(cfg, sectionName)
      if section then out[sectionName] = section end
    end
  end
  return out
end

local function buildCspTyresIni(cfg, compoundIndex, tyreName, tyreLongName)
  local out = {}
  local sections, compoundKnown = selectedTyreSections(compoundIndex)
  if not compoundKnown then
    local namedTyresIni, namedTyreDataStatus = matchedTyreSectionsByName(buildCspAllTyresIni(cfg), tyreName, tyreLongName)
    if namedTyresIni then return namedTyresIni, namedTyreDataStatus end
  end
  for i, sectionName in ipairs(sections) do
    local section = buildCspTyreSection(cfg, sectionName)
    if section then out[i == 1 and 'FRONT' or 'REAR'] = section end
  end
  if out.FRONT and out.REAR then
    if compoundKnown then return out, 'selected_tyre_compound' end
    return out, 'selected_tyre_compound_unknown_index'
  end
  if out.FRONT or out.REAR then
    if compoundKnown then return out, 'selected_tyre_compound_partial_axle' end
    return out, 'selected_tyre_compound_unknown_index_partial_axle'
  end
  for _, prefix in ipairs({ 'FRONT', 'REAR' }) do
    for i = 0, 8 do
      local sectionName = i == 0 and prefix or (prefix .. '_' .. tostring(i))
      local section = buildCspTyreSection(cfg, sectionName)
      if section then out[sectionName] = section end
    end
  end
  for _ in pairs(out) do return out, 'compound_fallback_all_tyres' end
  return out, 'tyre_sections_missing'
end

local function filterTyresForCompound(tyresIni, compoundIndex, tyreName, tyreLongName)
  local out = {}
  local sections, compoundKnown = selectedTyreSections(compoundIndex)
  if not compoundKnown then
    local namedTyresIni, namedTyreDataStatus = matchedTyreSectionsByName(tyresIni or {}, tyreName, tyreLongName)
    if namedTyresIni then return namedTyresIni, namedTyreDataStatus end
  end
  for i, sectionName in ipairs(sections) do
    local section = tyresIni and tyresIni[sectionName] or nil
    if section then out[i == 1 and 'FRONT' or 'REAR'] = section end
  end
  if out.FRONT and out.REAR then
    if compoundKnown then return out, 'selected_tyre_compound' end
    return out, 'selected_tyre_compound_unknown_index'
  end
  if out.FRONT or out.REAR then
    if compoundKnown then return out, 'selected_tyre_compound_partial_axle' end
    return out, 'selected_tyre_compound_unknown_index_partial_axle'
  end

  for sectionName, section in pairs(tyresIni or {}) do
    if sectionName:find('^FRONT') or sectionName:find('^REAR') then
      out[sectionName] = section
    end
  end
  for _ in pairs(out) do return out, 'compound_fallback_all_tyres' end
  return out, 'tyre_sections_missing'
end

local function buildCspBrakesIni(cfg)
  local data = buildCfgSection(cfg, 'DATA', { 'MAX_TORQUE', 'FRONT_SHARE' }, nil)
  return data and { DATA = data } or {}
end

local function buildCspSuspensionsIni(cfg)
  local basic = buildCfgSection(cfg, 'BASIC', { 'WHEELBASE', 'CG_LOCATION' }, nil)
  local front = buildCfgSection(cfg, 'FRONT', { 'TRACK' }, nil)
  local rear = buildCfgSection(cfg, 'REAR', { 'TRACK' }, nil)
  local out = {}
  if basic then out.BASIC = basic end
  if front then out.FRONT = front end
  if rear then out.REAR = rear end
  for _ in pairs(out) do return out end
  return {}
end

local function buildCspAeroIni(cfg)
  if not cfg then return nil end
  local out = {}
  for i = 0, 9 do
    local sectionName = 'WING_' .. tostring(i)
    local section = buildCfgSection(cfg, sectionName, { 'CHORD', 'SPAN', 'CL_GAIN' }, { 'LUT_AOA_CL' })
    if section then out[sectionName] = section end
  end
  return out
end

local function cspCarDataLutPeak(carIndex, lutName)
  if not ac or not ac.DataLUT11 or not ac.DataLUT11.carData then return 0.0 end
  local ok, lut = pcall(function() return ac.DataLUT11.carData(carIndex, lutName) end)
  if not ok or not lut or not lut.bounds then return 0.0 end
  local okBounds, minBound, maxBound = pcall(function() return lut:bounds() end)
  if not okBounds then return 0.0 end
  return math.max(math.abs(math3d.y(minBound)), math.abs(math3d.y(maxBound)))
end

local function tyreStatusConfidenceCap(tyreDataStatus)
  tyreDataStatus = tostring(tyreDataStatus or '')
  if tyreDataStatus == 'selected_tyre_compound_name_match_partial_axle' then
    return '_tyre_compound_name_match_partial_axle', 0.50, 0.72
  end
  if tyreDataStatus == 'selected_tyre_compound_name_match' then
    return '_tyre_compound_name_match', 0.56, 0.82
  end
  if tyreDataStatus == 'selected_tyre_compound_unknown_index_partial_axle' then
    return '_tyre_compound_unknown_index_partial_axle', 0.45, 0.68
  end
  if tyreDataStatus == 'selected_tyre_compound_unknown_index' then
    return '_tyre_compound_unknown_index', 0.50, 0.74
  end
  if tyreDataStatus == 'selected_tyre_compound_partial_axle' then
    return '_tyre_compound_partial_axle', 0.50, 0.74
  end
  if tyreDataStatus ~= 'selected_tyre_compound' then
    return '_tyre_compound_estimated', 0.60, 0.82
  end
  return nil, nil, nil
end

local function appendTyreStatusSuffix(dataStatus, tyreStatusSuffix)
  dataStatus = tostring(dataStatus or 'unpacked_data')
  tyreStatusSuffix = tostring(tyreStatusSuffix or '')
  if dataStatus == 'unpacked_data' and tyreStatusSuffix == '_tyre_compound_name_match' then
    return 'unpacked_data_tyre_compound_name_match'
  end
  if dataStatus == 'unpacked_data' and tyreStatusSuffix == '_tyre_compound_name_match_partial_axle' then
    return 'unpacked_data_tyre_compound_name_match_partial_axle'
  end
  if dataStatus == 'unpacked_data' and tyreStatusSuffix == '_tyre_compound_partial_axle' then
    return 'unpacked_data_tyre_compound_partial_axle'
  end
  if dataStatus == 'unpacked_data' and tyreStatusSuffix == '_tyre_compound_unknown_index' then
    return 'unpacked_data_tyre_compound_unknown_index'
  end
  if dataStatus == 'unpacked_data' and tyreStatusSuffix == '_tyre_compound_unknown_index_partial_axle' then
    return 'unpacked_data_tyre_compound_unknown_index_partial_axle'
  end
  if dataStatus == 'unpacked_data' and tyreStatusSuffix == '_tyre_compound_estimated' then
    return 'unpacked_data_tyre_compound_estimated'
  end
  return dataStatus .. tyreStatusSuffix
end

local function readFromCspCarData(carIndex, hasPackedAcd, compoundIndex, tyreName, tyreLongName)
  carIndex = math.floor(finiteNumber(carIndex, -1.0) + 0.5)
  if carIndex < 0 then return nil end

  local carIniCfg = loadCspCarDataIni(carIndex, 'car.ini')
  local tyresIniCfg = loadCspCarDataIni(carIndex, 'tyres.ini')
  local brakesIniCfg = loadCspCarDataIni(carIndex, 'brakes.ini')
  local aeroIniCfg = loadCspCarDataIni(carIndex, 'aero.ini')
  local suspensionsIniCfg = loadCspCarDataIni(carIndex, 'suspensions.ini')
  if not carIniCfg and not tyresIniCfg and not brakesIniCfg and not aeroIniCfg and not suspensionsIniCfg then return nil end

  local tyresIni, tyreDataStatus = buildCspTyresIni(tyresIniCfg, compoundIndex, tyreName, tyreLongName)
  local capability = estimateFromPhysics('', buildCspCarIni(carIniCfg), tyresIni,
    buildCspBrakesIni(brakesIniCfg), buildCspAeroIni(aeroIniCfg), buildCspSuspensionsIni(suspensionsIniCfg),
    function(_, lutName) return cspCarDataLutPeak(carIndex, lutName) end)
  capability.tyreDataStatus = tyreDataStatus
  if capability.available == true then
    capability.source = 'ac_physics_csp_car_data'
    capability.dataStatus = hasPackedAcd == true and 'packed_acd_via_csp_car_data' or 'csp_car_data'
    capability.confidence = clamp(capability.confidence, 0.72, 0.94)
    local tyreStatusSuffix, confidenceMin, confidenceMax = tyreStatusConfidenceCap(tyreDataStatus)
    if tyreStatusSuffix then
      capability.dataStatus = capability.dataStatus .. tyreStatusSuffix
      capability.confidence = clamp(capability.confidence, confidenceMin, confidenceMax)
    end
  else
    capability.source = 'ac_physics_csp_incomplete'
    capability.dataStatus = hasPackedAcd == true and 'packed_acd_csp_incomplete' or 'csp_car_data_incomplete'
    capability.confidence = clamp(capability.confidence, 0.0, 0.60)
  end
  return capability
end

function M.read(carId, root, carIndex, compoundIndex, tyreName, tyreLongName)
  local rootPath = tostring(root or ''):gsub('[\\/]+$', '')
  local id = safeCarFolderId(carId)
  local liveTyreNameCacheToken = tyreNameCacheToken(tyreName, tyreLongName)
  local cacheKey = rootPath .. '|' .. id .. '|' .. tostring(carIndex or 'no_index') .. '|' .. tostring(compoundIndex or 'no_compound') .. '|' .. liveTyreNameCacheToken
  if cache[cacheKey] ~= nil then return cache[cacheKey] end

  if rootPath == '' then
    local cspOnly = readFromCspCarData(carIndex, false, compoundIndex, tyreName, tyreLongName)
    cache[cacheKey] = cspOnly or { available = false, source = 'ac_physics_no_root', dataStatus = 'missing_physics_data', confidence = 0.0 }
    return cache[cacheKey]
  end

  local carDir = rootPath .. '/content/cars/' .. id
  local dataDir = carDir .. '/data'
  local hasPackedAcd = fileExists(carDir .. '/data.acd')
  local carIni = parseIniFile(carDir .. '/' .. DATA_CAR_INI)
  local tyresIni = parseIniFile(carDir .. '/' .. DATA_TYRES_INI)
  local brakesIni = parseIniFile(carDir .. '/' .. DATA_BRAKES_INI)
  local aeroIni = parseIniFile(carDir .. '/' .. DATA_AERO_INI)
  local suspensionsIni = parseIniFile(carDir .. '/' .. DATA_SUSPENSIONS_INI)
  if carIni or tyresIni or brakesIni or aeroIni or suspensionsIni then
    local filteredTyresIni, tyreDataStatus = filterTyresForCompound(tyresIni or {}, compoundIndex, tyreName, tyreLongName)
    local capability = estimateFromPhysics(dataDir, carIni or {}, filteredTyresIni, brakesIni or {}, aeroIni, suspensionsIni or {})
    capability.tyreDataStatus = tyreDataStatus
    if capability.available == true and tyreDataStatus ~= 'selected_tyre_compound' then
      local dataStatus = tostring(capability.dataStatus or 'unpacked_data')
      local tyreStatusSuffix, confidenceMin, confidenceMax = tyreStatusConfidenceCap(tyreDataStatus)
      if tyreStatusSuffix then
        capability.dataStatus = appendTyreStatusSuffix(dataStatus, tyreStatusSuffix)
        capability.confidence = clamp(capability.confidence, confidenceMin, confidenceMax)
      end
    end
    cache[cacheKey] = capability
    return cache[cacheKey]
  end

  local cspCapability = readFromCspCarData(carIndex, hasPackedAcd, compoundIndex, tyreName, tyreLongName)
  if cspCapability then
    cache[cacheKey] = cspCapability
    return cache[cacheKey]
  end

  if hasPackedAcd then
    cache[cacheKey] = {
      available = false,
      source = 'ac_physics_packed_unavailable',
      dataStatus = 'packed_acd_unavailable',
      confidence = 0.0,
    }
    return cache[cacheKey]
  end

  cache[cacheKey] = {
    available = false,
    source = 'ac_physics_missing',
    dataStatus = 'missing_physics_data',
    confidence = 0.0,
  }
  return cache[cacheKey]
end

M.parseIniFile = parseIniFile
M.parseLutPeak = parseLutPeak
M.estimateFromPhysics = estimateFromPhysics
M.readFromCspCarData = readFromCspCarData

return M
