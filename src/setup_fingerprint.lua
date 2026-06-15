local M = {}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function textToken(value)
  local text = tostring(value or ''):lower()
  text = text:gsub('[^a-z0-9_%-]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if text == '' then return 'unknown' end
  return text
end

local function meaningfulText(value)
  local text = textToken(value)
  if text == 'unknown' or text == 'none' or text == 'n_a' or text == 'na' then return nil end
  return text
end

local function firstMeaningfulText(...)
  for index = 1, select('#', ...) do
    local text = meaningfulText(select(index, ...))
    if text then return text end
  end
  return 'unknown'
end

local function tyreIdentityToken(tyreName, tyreLongName)
  local shortToken = meaningfulText(tyreName)
  local longToken = meaningfulText(tyreLongName)
  if shortToken and longToken and shortToken ~= longToken then
    return shortToken .. '+' .. longToken
  end
  return shortToken or longToken or 'unknown'
end

local function bucketFloor(value, step, fallback)
  step = math.max(0.001, finiteNumber(step, 1.0))
  value = finiteNumber(value, fallback or 0.0)
  return math.floor(value / step) * step
end

local function bucketRound(value, step, fallback)
  step = math.max(0.001, finiteNumber(step, 1.0))
  value = finiteNumber(value, fallback or 0.0)
  return math.floor(value / step + 0.5) * step
end

local function setupValue(car, key, fallback)
  local setupSnapshot = car and car.setupSnapshot or {}
  return finiteNumber(setupSnapshot[key], fallback)
end

local function liveOrSetupPositive(car, liveKey, setupKey, fallback)
  local liveValue = finiteNumber(car and car[liveKey], 0.0)
  if liveValue > 0.0 then return liveValue end
  local setup = setupValue(car, setupKey, fallback)
  if setup and setup > 0.0 then return setup end
  return finiteNumber(setup, fallback or 0.0)
end

local function liveKnownOrSetupPositive(car, liveKey, setupKey, fallback)
  local liveKnown = car and car[liveKey .. 'Known'] == true
  local liveValue = finiteNumber(car and car[liveKey], fallback or 0.0)
  if liveKnown then return liveValue end
  return liveOrSetupPositive(car, liveKey, setupKey, fallback)
end

local function setupKnown(car, key)
  local setupSnapshot = car and car.setupSnapshot or {}
  return setupSnapshot[key .. 'Known'] == true
end

local function loadSourceToken(car, liveKey, setupKey)
  if car and car[liveKey .. 'Known'] == true then return 'live' end
  if finiteNumber(car and car[liveKey], 0.0) > 0.0 then return 'live' end
  if setupKnown(car, setupKey) then return 'setup' end
  if setupValue(car, setupKey, 0.0) > 0.0 then return 'setup' end
  return 'fallback'
end

local function brakePowerPercentValue(value)
  local brakePower = finiteNumber(value, 100.0)
  if brakePower <= 2.0 then brakePower = brakePower * 100.0 end
  return math.max(0.0, math.min(110.0, brakePower))
end

local function brakePowerSourceToken(car)
  if car and car.brakePowerMultKnown == true then return 'live' end
  if finiteNumber(car and car.brakePowerMult, 0.0) > 0.0 then return 'live' end
  if setupKnown(car, 'brakePowerMult') or brakePowerPercentValue(setupValue(car, 'brakePowerMult', 100.0)) ~= 100.0 then return 'setup' end
  return 'fallback'
end

local function brakeBiasSourceToken(car)
  if car and car.brakeBiasKnown == true then return 'live' end
  if finiteNumber(car and car.brakeBias, 0.0) > 0.0 then return 'live' end
  if setupKnown(car, 'frontBias') or setupValue(car, 'frontBias', 0.0) > 0.0 then return 'setup' end
  local physicsCapability = car and car.physicsCapability or {}
  if finiteNumber(physicsCapability.brakeFrontShare, 0.0) > 0.0 then return 'physics' end
  return 'fallback'
end

local function wingSourceToken(car)
  if car and car.wingSettingKnown == true then return 'live' end
  if finiteNumber(car and car.wingSetting, 0.0) > 0.0 then return 'live' end
  if setupKnown(car, 'wingSetting') or setupValue(car, 'wingSetting', 0.0) > 0.0 then return 'setup' end
  return 'fallback'
end

local function normalizedPressurePsi(value)
  local pressure = finiteNumber(value, 0.0)
  if pressure <= 0.0 then return 0.0 end
  if pressure <= 5.0 then return pressure * 14.5037738 end
  if pressure > 80.0 and pressure <= 500.0 then return pressure * 0.145037738 end
  return pressure
end

local function pressureAt(car, setupKey, wheelIndex)
  local wheel = car and car.wheels and car.wheels[wheelIndex]
  local liveStaticPressure = normalizedPressurePsi(wheel and wheel.tyreStaticPressure)
  if liveStaticPressure > 0 then return liveStaticPressure end
  local setupPressure = normalizedPressurePsi(setupValue(car, setupKey, 0.0))
  if setupPressure > 0 then return setupPressure end
  return normalizedPressurePsi(wheel and wheel.tyrePressure)
end

local function pressureSourceToken(car, setupKey, wheelIndex)
  local wheel = car and car.wheels and car.wheels[wheelIndex]
  if normalizedPressurePsi(wheel and wheel.tyreStaticPressure) > 0 then return 'live_static' end
  if normalizedPressurePsi(setupValue(car, setupKey, 0.0)) > 0 then return 'setup' end
  if normalizedPressurePsi(wheel and wheel.tyrePressure) > 0 then return 'live_current' end
  if setupKnown(car, setupKey) then return 'fallback' end
  return 'fallback'
end

local function formatOne(value)
  return string.format('%.1f', finiteNumber(value, 0.0))
end

local function formatTwo(value)
  return string.format('%.2f', finiteNumber(value, 0.0))
end

local function formatInt(value)
  return tostring(math.floor(finiteNumber(value, 0.0) + 0.5))
end

local function bucketedListToken(values, step, decimals)
  if type(values) ~= 'table' or #values == 0 then return 'none' end
  local out = {}
  for _, value in ipairs(values) do
    local bucketed = bucketRound(value, step, 0.0)
    if decimals and decimals > 0 then
      out[#out + 1] = string.format('%.' .. tostring(decimals) .. 'f', bucketed)
    else
      out[#out + 1] = formatInt(bucketed)
    end
  end
  return table.concat(out, ',')
end

local function groupedSetupToken(setupMap, sections, step, decimals)
  if type(setupMap) ~= 'table' then return 'none' end
  local out = {}
  for _, section in ipairs(sections or {}) do
    local value = setupMap[section]
    if value ~= nil then
      local bucketed = bucketRound(value, step, 0.0)
      local valueToken = decimals and decimals > 0 and
        string.format('%.' .. tostring(decimals) .. 'f', bucketed) or formatInt(bucketed)
      out[#out + 1] = textToken(section) .. ':' .. valueToken
    end
  end
  if #out == 0 then return 'none' end
  return table.concat(out, ',')
end

local function liveAssistToken(car, setupAssistToken)
  setupAssistToken = tostring(setupAssistToken or 'none')
  local absKnown = car and car.absModeKnown == true
  local tcKnown = car and car.tractionControlModeKnown == true
  if not absKnown and not tcKnown then return setupAssistToken end
  local absToken = absKnown and formatInt(bucketRound(car.absMode, 1.0, 0.0)) or 'unknown'
  local tcToken = tcKnown and formatInt(bucketRound(car.tractionControlMode, 1.0, 0.0)) or 'unknown'
  return 'live:abs' .. absToken .. ':tc' .. tcToken .. ':setup' .. setupAssistToken
end

local function damageValue(car)
  local damage = finiteNumber(car and car.damage, 0.0)
  if damage > 1.5 then damage = damage / 100.0 end
  return damage
end

local function normalizedBrakePowerPercent(car)
  local brakePower = liveKnownOrSetupPositive(car, 'brakePowerMult', 'brakePowerMult', 100.0)
  return brakePowerPercentValue(brakePower)
end

local function physicsBackedBrakeBias(car)
  local frontBias = liveOrSetupPositive(car, 'brakeBias', 'frontBias', 0.0)
  if frontBias > 0.0 then return frontBias end
  local physicsCapability = car and car.physicsCapability or {}
  return finiteNumber(physicsCapability.brakeFrontShare, 0.0)
end

local function normalizedBrakeBiasPercent(car)
  local frontBias = physicsBackedBrakeBias(car)
  if frontBias <= 1.5 then frontBias = frontBias * 100.0 end
  return math.max(0.0, math.min(100.0, frontBias))
end

local function physicsStatusHasEvidence(dataStatus, tyreDataStatus, brakeDataStatus, aeroDataStatus)
  if dataStatus == 'missing_physics_data' or dataStatus == 'packed_acd_unavailable' then return false end
  if tyreDataStatus:find('selected_tyre_compound', 1, true) then return true end
  if brakeDataStatus == 'brake_torque_present' then return true end
  if aeroDataStatus == 'aero_wings_present' or
    aeroDataStatus == 'aero_wings_absent' or
    aeroDataStatus == 'aero_no_downforce_sections' then return true end
  return false
end

local function physicsEvidenceToken(car)
  local physicsCapability = car and car.physicsCapability or {}
  local source = textToken(physicsCapability.source or 'none')
  local dataStatus = textToken(physicsCapability.dataStatus or 'none')
  local tyreDataStatus = textToken(physicsCapability.tyreDataStatus or 'none')
  local brakeDataStatus = textToken(physicsCapability.brakeDataStatus or 'unknown')
  local aeroDataStatus = textToken(physicsCapability.aeroDataStatus or 'unknown')
  local hasEvidence = physicsStatusHasEvidence(dataStatus, tyreDataStatus, brakeDataStatus, aeroDataStatus) or
    finiteNumber(physicsCapability.massKg, 0.0) > 0.0 or
    finiteNumber(physicsCapability.wheelbaseM, 0.0) > 0.0 or
    finiteNumber(physicsCapability.cgLocation, 0.0) > 0.0 or
    finiteNumber(physicsCapability.frontTrackM, 0.0) > 0.0 or
    finiteNumber(physicsCapability.rearTrackM, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreLateralMu, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreLongitudinalMu, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontLateralMu, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearLateralMu, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontLongitudinalMu, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearLongitudinalMu, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreLoadRefN, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontLoadRefN, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearLoadRefN, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreLoadSensitivityLat, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreLoadSensitivityLong, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontLoadSensitivityLat, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearLoadSensitivityLat, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontLoadSensitivityLong, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearLoadSensitivityLong, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyrePressureStaticPsi, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyrePressureIdealPsi, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontPressureStaticPsi, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearPressureStaticPsi, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontPressureIdealPsi, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearPressureIdealPsi, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFalloffLevel, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontFalloffLevel, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearFalloffLevel, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFalloffSpeed, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontFalloffSpeed, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearFalloffSpeed, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreCombinedFactor, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontCombinedFactor, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearCombinedFactor, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrictionLimitAngleDeg, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontFrictionLimitAngleDeg, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearFrictionLimitAngleDeg, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreBrakeDxMod, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreFrontBrakeDxMod, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRearBrakeDxMod, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreRadiusM, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreLateralCount, 0.0) > 0.0 or
    finiteNumber(physicsCapability.tyreLongitudinalCount, 0.0) > 0.0 or
    finiteNumber(physicsCapability.brakeTorqueNm, 0.0) > 0.0 or
    finiteNumber(physicsCapability.brakeFrontShare, 0.0) > 0.0 or
    finiteNumber(physicsCapability.aeroScore, 0.0) > 0.0
  if not hasEvidence then return 'none' end
  return table.concat({
    source,
    dataStatus,
    tyreDataStatus,
    brakeDataStatus,
    aeroDataStatus,
    formatInt(bucketRound(physicsCapability.massKg, 10.0, 0.0)),
    formatTwo(bucketRound(physicsCapability.wheelbaseM, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.cgLocation, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.frontTrackM, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.rearTrackM, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreLateralMu, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreLongitudinalMu, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFrontLateralMu, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRearLateralMu, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFrontLongitudinalMu, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRearLongitudinalMu, 0.05, 0.0)),
    formatInt(bucketRound(physicsCapability.tyreLoadRefN, 100.0, 0.0)),
    formatInt(bucketRound(physicsCapability.tyreFrontLoadRefN, 100.0, 0.0)),
    formatInt(bucketRound(physicsCapability.tyreRearLoadRefN, 100.0, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreLoadSensitivityLat, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreLoadSensitivityLong, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFrontLoadSensitivityLat, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRearLoadSensitivityLat, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFrontLoadSensitivityLong, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRearLoadSensitivityLong, 0.01, 0.0)),
    formatOne(bucketRound(normalizedPressurePsi(physicsCapability.tyrePressureStaticPsi), 0.5, 0.0)),
    formatOne(bucketRound(normalizedPressurePsi(physicsCapability.tyrePressureIdealPsi), 0.5, 0.0)),
    formatOne(bucketRound(normalizedPressurePsi(physicsCapability.tyreFrontPressureStaticPsi), 0.5, 0.0)),
    formatOne(bucketRound(normalizedPressurePsi(physicsCapability.tyreRearPressureStaticPsi), 0.5, 0.0)),
    formatOne(bucketRound(normalizedPressurePsi(physicsCapability.tyreFrontPressureIdealPsi), 0.5, 0.0)),
    formatOne(bucketRound(normalizedPressurePsi(physicsCapability.tyreRearPressureIdealPsi), 0.5, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFalloffLevel, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFrontFalloffLevel, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRearFalloffLevel, 0.01, 0.0)),
    formatOne(bucketRound(physicsCapability.tyreFalloffSpeed, 0.1, 0.0)),
    formatOne(bucketRound(physicsCapability.tyreFrontFalloffSpeed, 0.1, 0.0)),
    formatOne(bucketRound(physicsCapability.tyreRearFalloffSpeed, 0.1, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreCombinedFactor, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFrontCombinedFactor, 0.05, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRearCombinedFactor, 0.05, 0.0)),
    formatOne(bucketRound(physicsCapability.tyreFrictionLimitAngleDeg, 0.1, 0.0)),
    formatOne(bucketRound(physicsCapability.tyreFrontFrictionLimitAngleDeg, 0.1, 0.0)),
    formatOne(bucketRound(physicsCapability.tyreRearFrictionLimitAngleDeg, 0.1, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreBrakeDxMod, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreFrontBrakeDxMod, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRearBrakeDxMod, 0.01, 0.0)),
    formatTwo(bucketRound(physicsCapability.tyreRadiusM, 0.01, 0.0)),
    formatInt(bucketRound(physicsCapability.tyreLateralCount, 1.0, 0.0)),
    formatInt(bucketRound(physicsCapability.tyreLongitudinalCount, 1.0, 0.0)),
    formatInt(bucketRound(physicsCapability.brakeTorqueNm, 100.0, 0.0)),
    formatTwo(bucketRound(physicsCapability.brakeFrontShare, 0.01, 0.0)),
    formatInt(bucketRound(physicsCapability.aeroWingCount, 1.0, 0.0)),
    formatTwo(bucketRound(physicsCapability.aeroScore, 0.05, 0.0)),
  }, ':')
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

local gearSetupSections = {
  'FINAL_GEAR_RATIO',
  'GEAR_1', 'GEAR_2', 'GEAR_3', 'GEAR_4', 'GEAR_5', 'GEAR_6', 'GEAR_7',
  'GEAR_8', 'GEAR_9', 'GEAR_10',
}

local diffSetupSections = {
  'DIFF_POWER', 'DIFF_COAST', 'DIFF_PRELOAD',
}

function M.build(car)
  car = car or {}
  local compoundIndex = math.floor(finiteNumber(car.compoundIndex, -1) + 0.5)
  local tyreName = tyreIdentityToken(car.tyresName, car.tyresLongName)
  local pressureLF = bucketFloor(pressureAt(car, 'pressureLF', 1), 0.5, 0.0)
  local pressureRF = bucketFloor(pressureAt(car, 'pressureRF', 2), 0.5, 0.0)
  local pressureLR = bucketFloor(pressureAt(car, 'pressureLR', 3), 0.5, 0.0)
  local pressureRR = bucketFloor(pressureAt(car, 'pressureRR', 4), 0.5, 0.0)
  local pressureSourceLF = pressureSourceToken(car, 'pressureLF', 1)
  local pressureSourceRF = pressureSourceToken(car, 'pressureRF', 2)
  local pressureSourceLR = pressureSourceToken(car, 'pressureLR', 3)
  local pressureSourceRR = pressureSourceToken(car, 'pressureRR', 4)
  local pressureSource = pressureSourceLF .. ':' .. pressureSourceRF .. ':' ..
    pressureSourceLR .. ':' .. pressureSourceRR
  local pressureSourceTyres = 'lf:' .. pressureSourceLF .. ',rf:' .. pressureSourceRF ..
    ',lr:' .. pressureSourceLR .. ',rr:' .. pressureSourceRR
  local fuel = bucketFloor(liveKnownOrSetupPositive(car, 'fuel', 'fuel', 0.0), 5.0, 0.0)
  local ballast = bucketRound(liveKnownOrSetupPositive(car, 'ballast', 'ballast', 0.0), 5.0, 0.0)
  local restrictor = bucketRound(liveKnownOrSetupPositive(car, 'restrictor', 'restrictor', 0.0), 1.0, 0.0)
  local loadSource = loadSourceToken(car, 'fuel', 'fuel') .. ':' ..
    loadSourceToken(car, 'ballast', 'ballast') .. ':' ..
    loadSourceToken(car, 'restrictor', 'restrictor')
  local brakePowerMult = bucketRound(normalizedBrakePowerPercent(car), 1.0, 100.0)
  local frontBias = bucketRound(normalizedBrakeBiasPercent(car), 0.5, 0.0)
  local wingSetting = bucketRound(liveKnownOrSetupPositive(car, 'wingSetting', 'wingSetting', 0.0), 1.0, 0.0)
  local tuneSource = brakePowerSourceToken(car) .. ':' .. brakeBiasSourceToken(car) .. ':' .. wingSourceToken(car)
  local tuneSourceFields = 'brakePower:' .. brakePowerSourceToken(car) .. ',brakeBias:' .. brakeBiasSourceToken(car) .. ',wing:' .. wingSourceToken(car)
  local setupSnapshot = car and car.setupSnapshot or {}
  local aeroToken = bucketedListToken(setupSnapshot.wingValues, 1.0, 0)
  if car and car.wingSettingKnown == true then aeroToken = 'live:' .. formatInt(wingSetting) end
  local mechanicalToken = bucketedListToken(setupSnapshot.mechanicalSetupValues, 0.5, 1)
  local drivetrainToken = bucketedListToken(setupSnapshot.drivetrainSetupValues, 0.5, 1)
  local alignmentToken = groupedSetupToken(setupSnapshot.alignmentSetupMap, alignmentSetupSections, 0.05, 2)
  local damperToken = groupedSetupToken(setupSnapshot.damperSetupMap, damperSetupSections, 1.0, 0)
  local gearToken = groupedSetupToken(setupSnapshot.gearSetupMap, gearSetupSections, 0.01, 2)
  local diffToken = groupedSetupToken(setupSnapshot.diffSetupMap, diffSetupSections, 0.5, 1)
  local setupAssistToken = bucketedListToken(setupSnapshot.assistSetupValues, 1.0, 0)
  local assistToken = liveAssistToken(car, setupAssistToken)
  local physicsToken = physicsEvidenceToken(car)
  local damage = bucketFloor(damageValue(car), 0.1, 0.0)

  return table.concat({
    'car=' .. textToken(car.carId or car.id or car.name),
    'tyre=' .. tostring(compoundIndex) .. ':' .. tyreName,
    'press=' .. formatOne(pressureLF) .. '/' .. formatOne(pressureRF) .. '/' ..
      formatOne(pressureLR) .. '/' .. formatOne(pressureRR),
    'pressSrc=' .. pressureSource,
    'pressSrcTyres=' .. pressureSourceTyres,
    'fuel=' .. formatInt(fuel),
    'ballast=' .. formatInt(ballast),
    'restrictor=' .. formatInt(restrictor),
    'loadSrc=' .. loadSource,
    'brakePower=' .. formatInt(brakePowerMult),
    'bias=' .. formatOne(frontBias),
    'wing=' .. formatInt(wingSetting),
    'tuneSrc=' .. tuneSource,
    'tuneSrcFields=' .. tuneSourceFields,
    'aero=' .. aeroToken,
    'mech=' .. mechanicalToken,
    'drive=' .. drivetrainToken,
    'align=' .. alignmentToken,
    'damp=' .. damperToken,
    'gear=' .. gearToken,
    'diff=' .. diffToken,
    'assist=' .. assistToken,
    'physics=' .. physicsToken,
    'damage=' .. formatOne(damage),
  }, '|')
end

return M
