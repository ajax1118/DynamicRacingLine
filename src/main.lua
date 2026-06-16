local settings = require('src/settings')
local logger = require('src/logger')
local math3d = require('src/math3d')
local car_state = require('src/car_state')
local profile_loader = require('src/profile_loader')
local dynamic_context = require('src/dynamic_context')
local track_sampler = require('src/track_sampler')
local target_speed_model = require('src/target_speed_model')
local cue_model = require('src/cue_model')
local corner_learning = require('src/corner_learning')
local knowledge_base = require('src/knowledge_base')
local id_normalizer = require('src/id_normalizer')
local profile_store = require('src/profile_store')
local guidance_blender = require('src/guidance_blender')
local runtime_health = require('src/runtime_health')
local frame_budget = require('src/frame_budget')
local snapshot_stager = require('src/snapshot_stager')
local display_diagnostics = require('src/display_diagnostics')
local regression_harness = require('src/regression_harness')
local safe_struct = require('src/safe_struct')
local renderer = require('src/renderer')
local track_file_ingest = require('src.line_core.track_file_ingest')
local line_core_adapter = nil

do
  local ok, moduleOrErr = pcall(require, 'src.line_core.integration_adapter')
  if ok and type(moduleOrErr) == 'table' then
    line_core_adapter = moduleOrErr
  else
    logger.once('line-core-r02-load-failed', 'LINE_CORE_R02_LOAD_FAILED ' .. tostring(moduleOrErr))
  end
end

local M = {
  initialized = false,
  status = 'booting',
  enabled = settings.ENABLED,
  debugVisible = settings.DEBUG_VISIBLE,
  opacity = settings.OPACITY,
  colorBrightnessM = settings.COLOR_BRIGHTNESS_M,
  hudColorBrightnessM = settings.HUD_COLOR_BRIGHTNESS_M,
  visibleAheadM = settings.VISIBLE_AHEAD_M,
  lineStartM = settings.LINE_START_M,
  tileWidthM = settings.TILE_WIDTH_M,
  tileLengthM = settings.TILE_LENGTH_M,
  tileSpacingM = settings.PROFILE_SPACING_M,
  roadHeightM = settings.ROAD_HEIGHT_M,
  quadLineLiftM = settings.QUAD_LINE_LIFT_M,
  brakeTiltDeg = settings.BRAKE_TILT_MAX_DEG,
  brakeEntryLeadM = settings.BRAKE_CORNER_ENTRY_LEAD_M,
  yellowRatio = settings.YELLOW_RATIO,
  redRatio = settings.RED_RATIO,
  frameId = 0,
  lastTiles = {},
  lastCar = nil,
  profile = nil,
  runtimeProfile = nil,
  lastDynamicContext = nil,
  guidanceSession = nil,
  normalizedSession = nil,
  predictiveBaselineSummary = nil,
  lineCoreGuidance = nil,
  lineCoreGuidanceKey = nil,
  lineCoreGuidanceStamp = 0,
  lineCoreGuidanceSummary = nil,
  lineCoreLastError = nil,
  lineCoreStatus = 'not_started',
  lineCoreDataProviderState = nil,
  lineCoreDataConfidence = 0.0,
  lineCoreStale = false,
  lineCoreDisabledForFps = false,
  lineCoreLowFpsHoldUntil = 0,
  trackFileReference = nil,
  lastGoodTiles = {},
  lastGoodTilesAt = 0,
  staleFrameHold = false,
  r02CueState = {},
  r02VisualState = {},
  currentCue = 'green',
  fallbackLineActive = false,
  tileRecoveryActive = false,
  hudRegistered = false,
  hudRegistrationAttempted = false,
  hudDisposable = nil,
  uiFinaleRegistered = false,
  uiFinaleRegistrationAttempted = false,
  uiFinaleDisposable = nil,
  lastHudDrawCount = 0,
  lastDirectHudDrawCount = 0,
  lastChildHudDrawCount = 0,
  lastFinalHudDrawCount = 0,
  lastUiFinaleHudDrawCount = 0,
  lastSyntheticRectCount = 0,
  firstSyntheticP1 = nil,
  firstSyntheticP2 = nil,
  hudProofNextAt = 0,
  directHudProofNextAt = 0,
  childHudProofNextAt = 0,
  finalHudProofNextAt = 0,
  uiFinaleProofNextAt = 0,
  hudCanaryProofNextAt = 0,
  dynamicContextProofNextAt = 0,
  brakeCueTelemetry = {},
  cornerLearningNextAt = 0,
  cornerLearningTelemetry = {},
  cornerLearningTrace = nil,
  lastCornerLearning = nil,
  uiEnabledProofNextAt = 0,
  lastEnabledProofValue = nil,
  logStarted = false,
  nextProfileRetryAt = 0,
  spatialProofNextAt = 0,
  activeCarId = nil,
  activeTrackId = nil,
  activeTrackLayout = nil,
  activeSetupFingerprint = nil,
  runNonce = nil,
  dynamicContextNextAt = 0,
  profileDynamicNextAt = 0,
  tilePrepareNextAt = 0,
  tilePrepareLastAt = 0,
  tilePrepareForceNextAt = 0,
  tilePrepareLastS = nil,
  runtimeSnapshotPromoteNextAt = 0,
}

local function nowSeconds()
  return os.clock and os.clock() or 0
end

local function makeRunNonce()
  local epoch = 0
  pcall(function() epoch = os.time() end)
  local randomPart = 0
  pcall(function() randomPart = math.random(100000, 999999) end)
  return tostring(epoch or 0) .. '-' .. tostring(randomPart or 0)
end

local function retryDelay()
  return math.max(0.25, tonumber(settings.PROFILE_RETRY_DELAY_S) or 1.0)
end

local function logUiEnabledProof(reason, previous)
  local now = nowSeconds()
  local changed = previous ~= nil and (previous == true) ~= (M.enabled == true)
  if not changed and M.lastEnabledProofValue == (M.enabled == true) and now < (M.uiEnabledProofNextAt or 0) then
    return
  end
  M.uiEnabledProofNextAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
  M.lastEnabledProofValue = M.enabled == true
  local previousText = previous == nil and 'none' or tostring(previous == true)
  logger.write('UI_ENABLED_PROOF enabled=' .. tostring(M.enabled == true) ..
    ' previous=' .. previousText ..
    ' changed=' .. tostring(changed == true) ..
    ' reason=' .. tostring(reason or 'periodic') ..
    ' frameId=' .. tostring(M.frameId or 0) ..
    ' runNonce=' .. tostring(M.runNonce or ''))
end

local function sessionIdentity()
  return {
    carId = car_state.carId(),
    trackId = car_state.trackId(),
    trackLayout = car_state.trackLayout(),
  }
end

local function applySessionIdentity(identity)
  identity = identity or {}
  M.activeCarId = identity.carId
  M.activeTrackId = identity.trackId
  M.activeTrackLayout = identity.trackLayout
end

local function sameSession(identity)
  identity = identity or {}
  return tostring(identity.carId or '') == tostring(M.activeCarId or '') and
    tostring(identity.trackId or '') == tostring(M.activeTrackId or '') and
    tostring(identity.trackLayout or '') == tostring(M.activeTrackLayout or '')
end

local function resetCornerLearningFrameState(reason)
  M.cornerLearningTelemetry = {}
  M.cornerLearningTrace = nil
  M.lastCornerLearning = nil
  M.cornerLearningNextAt = 0
  logger.write('CORNER_LEARNING_FRAME_RESET reason=' .. tostring(reason or 'unknown'))
end

local function ensureSetupCurrent(car)
  local setupFingerprint = tostring(car and car.setupFingerprint or '')
  if M.activeSetupFingerprint == nil then
    M.activeSetupFingerprint = setupFingerprint
    return
  end
  if setupFingerprint == tostring(M.activeSetupFingerprint or '') then return end

  local oldSetupFingerprint = tostring(M.activeSetupFingerprint or '')
  M.activeSetupFingerprint = setupFingerprint
  M.dynamicContextNextAt = 0
  M.lineCoreGuidance = nil
  M.lineCoreGuidanceStamp = 0
  M.lineCoreLowFpsHoldUntil = 0
  M.lineCoreStale = false
  M.normalizedSession = id_normalizer.session(sessionIdentity(), car)
  M.guidanceSession = profile_store.loadSession(sessionIdentity(), car, M.runtimeProfile)
  M.guidanceSession.track_file_reference = M.trackFileReference
  M.guidanceSession.trackSplineSamples = M.profile and M.profile.samples or nil
  if type(M.guidanceSession.track_profile) == 'table' then
    M.guidanceSession.track_profile.trackFileReference = M.trackFileReference
    M.guidanceSession.track_profile.trackSplineSamples = M.profile and M.profile.samples or nil
  end
  profile_store.saveRuntimeProfiles(M.guidanceSession, car, M.runtimeProfile, M.lastDynamicContext or {})
  if M.profile and M.profile.samples and settings.PHYSICS_FIRST_GUIDANCE_ENABLED == true then
    M.predictiveBaselineSummary = guidance_blender.apply(M.profile.samples, M.lastDynamicContext or {}, M.guidanceSession, {
      closedLoop = true,
      staticProfile = true,
      reason = 'setup_changed',
    })
    profile_store.saveGeneratedLine(M.guidanceSession, M.profile.samples, M.predictiveBaselineSummary)
  end
  resetCornerLearningFrameState('setup_changed')
  if dynamic_context and dynamic_context.resetTelemetryLearning then
    dynamic_context.resetTelemetryLearning('setup_changed')
  end
  logger.write('SETUP_CHANGED_CORNER_LEARNING_RESET oldSetupFingerprint=' .. oldSetupFingerprint ..
    ' newSetupFingerprint=' .. setupFingerprint)
end

local function resetProfileState(reason)
  M.initialized = false
  M.status = 'rebuilding'
  M.profile = nil
  M.runtimeProfile = nil
  M.lastDynamicContext = nil
  M.guidanceSession = nil
  M.normalizedSession = nil
  M.predictiveBaselineSummary = nil
  M.lineCoreGuidance = nil
  M.lineCoreGuidanceKey = nil
  M.lineCoreGuidanceStamp = 0
  M.lineCoreLowFpsHoldUntil = 0
  M.trackFileReference = nil
  M.lastGoodTiles = {}
  M.lastGoodTilesAt = 0
  M.staleFrameHold = false
  M.r02CueState = {}
  M.r02VisualState = {}
  M.dynamicContextNextAt = 0
  M.lastTiles = {}
  M.fallbackLineActive = false
  M.tileRecoveryActive = false
  M.nextProfileRetryAt = 0
  M.profileDynamicNextAt = 0
  M.tilePrepareNextAt = 0
  M.tilePrepareLastAt = 0
  M.tilePrepareForceNextAt = 0
  M.tilePrepareLastS = nil
  M.runtimeSnapshotPromoteNextAt = 0
  M.activeSetupFingerprint = nil
  resetCornerLearningFrameState(reason or 'profile_reset')
  if dynamic_context and dynamic_context.resetTelemetryLearning then
    dynamic_context.resetTelemetryLearning(reason or 'profile_reset')
  end
  logger.write('PROFILE_RESET reason=' .. tostring(reason or 'unknown'))
end

local function fallbackDebugLineEnabled()
  return settings.FALLBACK_DEBUG_LINE_ENABLED == true and M.debugVisible == true
end

local function ensureSessionCurrent()
  if not M.initialized then return end
  local identity = sessionIdentity()
  if sameSession(identity) then return end
  logger.write('SESSION_CHANGED_REBUILD oldCar=' .. tostring(M.activeCarId or '') ..
    ' oldTrack=' .. tostring(M.activeTrackId or '') ..
    ' oldLayout=' .. tostring(M.activeTrackLayout or '') ..
    ' newCar=' .. tostring(identity.carId or '') ..
    ' newTrack=' .. tostring(identity.trackId or '') ..
    ' newLayout=' .. tostring(identity.trackLayout or ''))
  resetProfileState('session_changed')
end

local function applyUiSettings()
  local previousColorBrightnessM = tonumber(settings.COLOR_BRIGHTNESS_M) or 0
  M.enabled = M.enabled == true
  settings.ENABLED = M.enabled
  settings.OPACITY = math3d.clamp(M.opacity, 0.05, 1.0)
  M.opacity = settings.OPACITY
  M.colorBrightnessM = math3d.clamp(M.colorBrightnessM,
    tonumber(settings.COLOR_BRIGHTNESS_MIN_M) or 0.5,
    tonumber(settings.COLOR_BRIGHTNESS_MAX_M) or 30.0)
  settings.COLOR_BRIGHTNESS_M = M.colorBrightnessM
  if math.abs(previousColorBrightnessM - M.colorBrightnessM) > 0.001 then
    logger.write('UI_SETTINGS_PROOF oldBrightnessM=' .. tostring(previousColorBrightnessM) ..
      ' newBrightnessM=' .. tostring(M.colorBrightnessM) ..
      ' settingsBrightnessM=' .. tostring(settings.COLOR_BRIGHTNESS_M) ..
      ' frameId=' .. tostring(M.frameId or 0))
  end
  M.hudColorBrightnessM = math3d.clamp(M.hudColorBrightnessM, 0.5, 8.0)
  settings.HUD_COLOR_BRIGHTNESS_M = M.hudColorBrightnessM
  settings.VISIBLE_AHEAD_M = math3d.clamp(M.visibleAheadM, 20.0, 350.0)
  M.visibleAheadM = settings.VISIBLE_AHEAD_M
  M.lineStartM = math.max(0.0, math.min(30.0, tonumber(M.lineStartM) or settings.LINE_START_M))
  settings.LINE_START_M = M.lineStartM
  settings.LINE_MIN_AHEAD_M = M.lineStartM
  settings.CAR_CLEARANCE_AHEAD_M = M.lineStartM
  settings.TILE_WIDTH_M = math3d.clamp(M.tileWidthM, 0.25, 5.0)
  M.tileWidthM = settings.TILE_WIDTH_M
  settings.TILE_LENGTH_M = math3d.clamp(M.tileLengthM, 0.5, 15.0)
  M.tileLengthM = settings.TILE_LENGTH_M
  local previousRoadHeightM = tonumber(settings.ROAD_HEIGHT_M) or settings.ROAD_HEIGHT_M
  local previousTileSpacingM = tonumber(settings.PROFILE_SPACING_M) or settings.PROFILE_SPACING_M
  M.roadHeightM = math3d.clamp(M.roadHeightM, 0.0, 0.25)
  settings.ROAD_HEIGHT_M = M.roadHeightM
  M.tileSpacingM = math3d.clamp(M.tileSpacingM, 0.5, 10.0)
  settings.PROFILE_SPACING_M = M.tileSpacingM
  M.quadLineLiftM = math3d.clamp(M.quadLineLiftM, 0.0, 0.25)
  settings.QUAD_LINE_LIFT_M = M.quadLineLiftM
  M.brakeTiltDeg = math3d.clamp(M.brakeTiltDeg, 0.0, 15.0)
  settings.BRAKE_TILT_MAX_DEG = M.brakeTiltDeg
  M.brakeEntryLeadM = math3d.clamp(M.brakeEntryLeadM, 0.0, 50.0)
  settings.BRAKE_CORNER_ENTRY_LEAD_M = M.brakeEntryLeadM
  M.redRatio = math.max(M.yellowRatio + 0.01, M.redRatio)
  M.yellowRatio = math3d.clamp(M.yellowRatio, 0.01, 0.90)
  M.redRatio = math3d.clamp(M.redRatio, 0.05, 1.50)
  settings.YELLOW_RATIO = M.yellowRatio
  settings.RED_RATIO = M.redRatio
  if M.initialized and math.abs((tonumber(settings.ROAD_HEIGHT_M) or 0) - (tonumber(previousRoadHeightM) or 0)) > 0.001 then
    resetProfileState('ui_road_lift_changed')
  elseif M.initialized and math.abs((tonumber(settings.PROFILE_SPACING_M) or 0) - (tonumber(previousTileSpacingM) or 0)) > 0.001 then
    resetProfileState('ui_tile_spacing_changed')
  end
end

local function init()
  if M.initialized then return true end
  if nowSeconds() < (M.nextProfileRetryAt or 0) then return false end
  if not M.logStarted then
    M.runNonce = M.runNonce or makeRunNonce()
    logger.clear()
    logger.write('DYNAMIC_RACING_LINE_LOADED version=' .. settings.VERSION .. ' buildId=' .. settings.BUILD_ID)
    logger.write('DRL_RUN_NONCE version=' .. settings.VERSION ..
      ' buildId=' .. settings.BUILD_ID ..
      ' runNonce=' .. tostring(M.runNonce or ''))
    M.logStarted = true
  end
  applyUiSettings()
  logUiEnabledProof('init')

  local identity = sessionIdentity()
  local sessionCar = car_state.read() or {}
  sessionCar.carId = identity.carId
  sessionCar.trackId = identity.trackId
  sessionCar.trackLayout = identity.trackLayout
  local normalizedIdentity = id_normalizer.session(identity, sessionCar)
  local runtimeProfile = profile_loader.load(identity.carId, identity.trackId, identity.trackLayout)
  if runtimeProfile and runtimeProfile.track then
    runtimeProfile.track.road_height_m = M.roadHeightM
  end
  local profile = track_sampler.build(runtimeProfile)
  if not profile or not profile.samples or #profile.samples == 0 then
    M.status = 'profile_failed_retrying'
    M.profile = nil
    M.fallbackLineActive = fallbackDebugLineEnabled()
    M.nextProfileRetryAt = nowSeconds() + retryDelay()
    logger.write('PROFILE_FAILED_RETRYING reason=' .. tostring(profile and profile.reason or 'no_profile') ..
      ' retryDelayS=' .. tostring(retryDelay()))
    if fallbackDebugLineEnabled() then
      logger.once('fallback-debug-line-ready', 'FALLBACK_DEBUG_LINE_READY reason=profile_failed placementMode=fallback_debug_line visibleTestLine=true')
    else
      logger.once('fallback-debug-line-disabled', 'FALLBACK_DEBUG_LINE_DISABLED reason=profile_failed visibleTestLine=false')
    end
    return false
  end

  target_speed_model.build(profile.samples, runtimeProfile)
  local guidanceSession = profile_store.loadSession(identity, sessionCar, runtimeProfile)
  local trackFileReference = track_file_ingest.loadReference(identity.trackId, identity.trackLayout, profile.totalLengthM, {
    maxPoints = settings.LINE_CORE_R02_AI_FILE_MAX_POINTS,
  })
  guidanceSession.track_file_reference = trackFileReference
  guidanceSession.trackSplineSamples = profile.samples
  if type(guidanceSession.track_profile) == 'table' then
    guidanceSession.track_profile.trackFileReference = trackFileReference
    guidanceSession.track_profile.trackSplineSamples = profile.samples
  end
  local carProfile = runtimeProfile and runtimeProfile.car or {}
  local initContext = {
    currentSpeedKph = tonumber(sessionCar.speedKmh) or 0.0,
    currentSpeedMs = (tonumber(sessionCar.speedKmh) or 0.0) / 3.6,
    corneringG = tonumber(carProfile.cornering_g) or tonumber(settings.DEFAULT_CORNERING_G) or 1.20,
    brakeG = tonumber(carProfile.brake_decel_g) or tonumber(settings.DEFAULT_BRAKE_G) or 1.15,
    surfaceGrip = 1.0,
    roadGrip = 1.0,
    confidence = math.max(tonumber(carProfile.confidence) or 0.0,
      tonumber(runtimeProfile and runtimeProfile.track and runtimeProfile.track.confidence) or 0.0,
      0.58),
    maxTargetSpeedKph = tonumber(carProfile.max_target_speed_kph) or tonumber(settings.MAX_TARGET_SPEED_KPH) or 340.0,
    minCornerSpeedKph = tonumber(carProfile.min_corner_speed_kph) or tonumber(settings.MIN_CORNER_SPEED_KPH) or 35.0,
  }
  local predictiveSummary = nil
  profile_store.saveRuntimeProfiles(guidanceSession, sessionCar, runtimeProfile, initContext)
  if settings.PHYSICS_FIRST_GUIDANCE_ENABLED == true then
    predictiveSummary = guidance_blender.apply(profile.samples, initContext, guidanceSession, {
      closedLoop = true,
      staticProfile = true,
      reason = 'profile_init',
    })
    profile_store.saveGeneratedLine(guidanceSession, profile.samples, predictiveSummary)
  end
  M.runtimeProfile = runtimeProfile
  M.profile = profile
  M.guidanceSession = guidanceSession
  M.trackFileReference = trackFileReference
  M.normalizedSession = normalizedIdentity
  M.predictiveBaselineSummary = predictiveSummary
  M.fallbackLineActive = false
  M.nextProfileRetryAt = 0
  M.activeSetupFingerprint = tostring(sessionCar.setupFingerprint or '')
  applySessionIdentity(identity)
  M.initialized = true
  M.status = profile.degraded and 'ready_degraded' or 'ready'
  logger.write('PROFILE_READY samples=' .. tostring(#profile.samples) ..
    ' placementMode=' .. tostring(profile.placementMode or 'unknown') ..
    ' degraded=' .. tostring(profile.degraded == true) ..
    ' carId=' .. tostring(identity.carId or '') ..
    ' trackId=' .. tostring(identity.trackId or '') ..
    ' carProfile=' .. tostring(runtimeProfile.carKey or 'default') ..
    ' trackProfile=' .. tostring(runtimeProfile.trackKey or 'default') ..
    ' trackLayout=' .. tostring(identity.trackLayout or '') ..
    ' layoutKey=' .. tostring(runtimeProfile.layoutKey or 'default') ..
    ' normalizedTrack=' .. tostring(normalizedIdentity.track_id or '') ..
    ' normalizedLayout=' .. tostring(normalizedIdentity.layout_id or '') ..
    ' normalizedCar=' .. tostring(normalizedIdentity.car_id or '') ..
    ' setupHash=' .. tostring(normalizedIdentity.setup_hash or '') ..
    ' predictiveCorners=' .. tostring(predictiveSummary and predictiveSummary.corner_count or 0))
  return true
end

local function safeCheckbox(label, value)
  if not ui or not ui.checkbox then return value end
  local current = value == true
  local ok, result, secondary = pcall(function() return ui.checkbox(label, current) end)
  if not ok then return value end
  if type(secondary) == 'boolean' then return secondary end
  local clicked = false
  if ui.itemClicked then
    local okClicked, clickedResult = pcall(function() return ui.itemClicked() end)
    clicked = okClicked and clickedResult == true
  elseif ui.isItemClicked then
    local okClicked, clickedResult = pcall(function() return ui.isItemClicked() end)
    clicked = okClicked and clickedResult == true
  end
  if clicked then
    if type(result) == 'boolean' and result ~= current then return result end
    return not current
  end
  if type(result) == 'boolean' and result == true and current == false then return true end
  return current
end

local function safeSlider(label, value, minValue, maxValue, format)
  if not ui or not ui.slider then return value end
  local ok, result, secondary = pcall(function() return ui.slider(label, value, minValue, maxValue, format) end)
  if ok and type(result) == 'number' then return result end
  if ok and type(secondary) == 'number' then return secondary end
  return value
end

local function cueFrameId(car)
  local progress = tonumber(car and car.splinePosition) or 0
  return tostring(M.frameId) .. ':' .. tostring(math.floor(progress * 100000 + 0.5))
end

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function clamp(value, lo, hi)
  return math3d.clamp(finiteNumber(value, lo), lo, hi)
end

local function cornerLearningMomentKey(context)
  if type(context) ~= 'table' or next(context) == nil then return 'moment_unknown' end
  local gripProduct = clamp(finiteNumber(context.roadGrip, 1.0) * finiteNumber(context.surfaceGrip, 1.0), 0.40, 1.20)
  local wetLoad = math.max(
    clamp(context.rainIntensity, 0.0, 1.0) * 0.80,
    clamp(context.rainWetness, 0.0, 1.0),
    clamp(context.rainWater, 0.0, 1.0) * 1.20)
  local pressureLoad = clamp(finiteNumber(context.pressurePenalty, 0.0) / 0.18, 0.0, 1.0)
  local tyreStress = math.max(
    clamp(context.tyreWear, 0.0, 1.0) * 0.60,
    clamp(context.tyreDirty, 0.0, 1.0),
    clamp(math.abs(finiteNumber(context.tyreTempDeltaC, 0.0)) / 45.0, 0.0, 1.0),
    pressureLoad,
    clamp(context.worstAxleTyreStress or context.slipStress, 0.0, 1.0))
  local thermalLoad = math.max(
    clamp(math.abs(finiteNumber(context.trackThermalCornerFactor, 1.0) - 1.0) / 0.12, 0.0, 1.0),
    clamp(math.abs(finiteNumber(context.trackThermalBrakeFactor, 1.0) - 1.0) / 0.12, 0.0, 1.0))
  local windLoad = math.max(
    clamp(finiteNumber(context.windSpeedKmh, 0.0) / 80.0, 0.0, 1.0),
    clamp(math.abs(finiteNumber(context.windFactor, 1.0) - 1.0) / 0.06, 0.0, 1.0))
  local assist = (context.absInAction == true or context.tractionControlInAction == true) and 1 or 0
  return string.format('grip%03d_wet%02d_tyre%02d_press%02d_therm%02d_wind%02d_assist%d',
    math.floor(gripProduct * 100.0 + 0.5),
    math.floor(clamp(wetLoad, 0.0, 1.0) * 10.0 + 0.5),
    math.floor(clamp(tyreStress, 0.0, 1.0) * 10.0 + 0.5),
    math.floor(clamp(pressureLoad, 0.0, 1.0) * 10.0 + 0.5),
    math.floor(clamp(thermalLoad, 0.0, 1.0) * 10.0 + 0.5),
    math.floor(clamp(windLoad, 0.0, 1.0) * 10.0 + 0.5),
    assist)
end

local function applyCornerLearningBias(tiles, car)
  local momentKey = cornerLearningMomentKey(M.lastDynamicContext)
  for _, tile in ipairs(tiles or {}) do
    local learning = corner_learning.biasFor(car, {
      trackId = M.activeTrackId,
      trackLayout = M.activeTrackLayout,
      progress = tile.progress,
      cornerLearningMomentKey = momentKey,
    })
    tile.cornerBrakeBiasM = tonumber(learning.cornerBrakeBiasM) or 0.0
    tile.rawCornerBrakeBiasM = learning.rawCornerBrakeBiasM
    tile.cornerLearningConfidence = learning.cornerLearningConfidence
    tile.cornerLearningSetupKnown = learning.cornerLearningSetupKnown
    tile.cornerLearningSetupTrustScale = learning.cornerLearningSetupTrustScale
    tile.cornerLearningCleanWindowSamples = learning.cornerLearningCleanWindowSamples
    tile.cornerLearningRiskWindowSamples = learning.cornerLearningRiskWindowSamples
    tile.cornerLearningKey = learning.cornerLearningKey
    tile.cornerLearningMomentKey = learning.cornerLearningMomentKey
    tile.cornerLearningSamples = learning.samples or 0
    tile.cornerLearningState = learning.cornerLearningState
  end
  return tiles
end

local function trafficLearningBlock(car)
  local traffic = car and car.trafficProximity or {}
  local aheadM = tonumber(traffic.nearestOpponentAheadM) or 0.0
  local lateralM = tonumber(traffic.nearestOpponentLateralM) or 0.0
  local distanceM = tonumber(traffic.nearestOpponentDistanceM) or 0.0
  local maxAheadM = math.max(0.0, tonumber(settings.CORNER_LEARNING_TRAFFIC_AHEAD_M) or 55.0)
  local maxLateralM = math.max(0.0, tonumber(settings.CORNER_LEARNING_TRAFFIC_LATERAL_M) or 5.5)
  local blocked = aheadM > 0.0 and aheadM <= maxAheadM and lateralM <= maxLateralM
  return {
    blocked = blocked,
    aheadM = aheadM,
    lateralM = lateralM,
    distanceM = distanceM,
    scanStatus = tostring(traffic.trafficScanStatus or 'unknown'),
    carsCount = math.max(0, math.floor((tonumber(traffic.trafficCarsCount) or 0.0) + 0.5)),
    opponentIndex = math.floor((tonumber(traffic.nearestOpponentIndex) or -1.0) + 0.5),
  }
end

local function fallbackKindForIndex(i)
  if i >= 12 then return 'red' end
  if i >= 7 then return 'yellow' end
  return 'green'
end

local function buildFallbackDebugTiles(car)
  car = car or car_state.read()
  local tiles = {}
  local pos = car.pos
  local forward = car.forward
  local right = car.right
  local normal = car.up
  local fallbackLiftM = math.max(settings.ROAD_HEIGHT_M, settings.FALLBACK_LINE_LIFT_M)
  local spacing = math.max(settings.TILE_LENGTH_M + settings.TILE_GAP_MIN_M, 4.0)
  if not pos or not forward or not right or not normal then return tiles end
  for i = 1, 16 do
    local distance = 6.0 + (i - 1) * spacing
    tiles[#tiles + 1] = {
      index = i,
      pos = math3d.add(math3d.add(pos, math3d.mul(forward, distance)), math3d.mul(normal, fallbackLiftM)),
      forward = forward,
      right = right,
      normal = normal,
      distanceAheadM = distance,
      targetSpeedKph = settings.MAX_TARGET_SPEED_KPH,
      requiredDecelRatio = 0,
      kind = fallbackKindForIndex(i),
      placementMode = 'fallback_debug_line',
      tileWidthM = M.tileWidthM,
      tileLengthM = M.tileLengthM,
    }
  end
  return tiles
end

local function formatMeters(value)
  value = tonumber(value)
  if not value or value == math.huge then return 'none' end
  return string.format('%.1f', value)
end

local function windowSource(tiles)
  for _, tile in ipairs(tiles or {}) do
    if tile.windowSource then return tostring(tile.windowSource) end
  end
  return 'unknown'
end

local function hasUsableForwardTile(tiles, car)
  if not car or not car.pos or not car.forward then return #(tiles or {}) > 0 end
  local maxRight = tonumber(settings.NEAR_FORWARD_MAX_RIGHT_M) or 12.0
  local maxStart = tonumber(settings.NEAR_FORWARD_MAX_START_M) or 18.0
  local maxUp = tonumber(settings.NEAR_FORWARD_MAX_UP_M) or 3.0
  local nearestForwardM = math.huge
  local nearestForwardRightM = math.huge
  local nearestForwardUpM = math.huge
  local nearestForwardFound = false

  for _, tile in ipairs(tiles or {}) do
    if tile.pos then
      local offset = math3d.sub(tile.pos, car.pos)
      local localForward = math3d.dot(offset, car.forward)
      local localRight = math.abs(math3d.dot(offset, car.right or math3d.vec(1, 0, 0)))
      local localUp = math.abs(math3d.dot(offset, car.up or math3d.vec(0, 1, 0)))
      if localForward >= 1.0 and localForward < nearestForwardM then
        nearestForwardM = localForward
        nearestForwardRightM = localRight
        nearestForwardUpM = localUp
        nearestForwardFound = true
      end
    end
  end

  if not nearestForwardFound then
    return false, 'unusable_spline_window', nearestForwardM, nearestForwardRightM, nearestForwardUpM
  end

  local nearestTileUsable = nearestForwardM <= maxStart and
    nearestForwardRightM <= maxRight and
    nearestForwardUpM <= maxUp
  if nearestTileUsable then
    return nearestTileUsable, 'usable', nearestForwardM, nearestForwardRightM, nearestForwardUpM
  end

  return false, 'nearest_visible_tile_spatial_rejected', nearestForwardM, nearestForwardRightM, nearestForwardUpM
end

local function rejectSpatialTileWindow(reason)
  M.spatialPlacementRejected = true
  M.spatialPlacementRejectedReason = reason or 'visible_tile_spatial_rejected'
  return {}
end

local function recoverTilesIfNeeded(tiles, car)
  M.tileRecoveryActive = false
  M.spatialPlacementRejected = false
  M.spatialPlacementRejectedReason = nil
  local usable, reason, nearestForwardM, nearestForwardRightM, nearestForwardUpM = hasUsableForwardTile(tiles, car)
  if usable then return tiles end

  local recovered = track_sampler.tileWindowNearCar(M.profile, car)
  if #recovered > 0 then
    local recoveredUsable, recoveredReason, recoveredForwardM, recoveredRightM, recoveredUpM = hasUsableForwardTile(recovered, car)
    if recoveredUsable then
      M.tileRecoveryActive = true
      logger.once('tile-window-recovery', 'TILE_WINDOW_RECOVERY reason=unusable_spline_window source=car_position previousSource=' ..
        windowSource(tiles) ..
        ' detail=' .. tostring(reason) ..
        ' nearestForwardM=' .. formatMeters(nearestForwardM) ..
        ' nearestForwardRightM=' .. formatMeters(nearestForwardRightM) ..
        ' nearestForwardUpM=' .. formatMeters(nearestForwardUpM) ..
        ' recoveredForwardM=' .. formatMeters(recoveredForwardM) ..
        ' recoveredRightM=' .. formatMeters(recoveredRightM) ..
        ' recoveredUpM=' .. formatMeters(recoveredUpM))
      return recovered
    end

    M.spatialPlacementRejected = true
    M.spatialPlacementRejectedReason = 'visible_tile_spatial_rejected'
    logger.once('tile-window-recovery-failed', 'TILE_WINDOW_RECOVERY_FAILED reason=unusable_recovered_window source=car_position previousSource=' ..
      windowSource(tiles) ..
      ' detail=' .. tostring(recoveredReason) ..
      ' nearestForwardM=' .. formatMeters(nearestForwardM) ..
      ' nearestForwardRightM=' .. formatMeters(nearestForwardRightM) ..
      ' nearestForwardUpM=' .. formatMeters(nearestForwardUpM) ..
      ' recoveredForwardM=' .. formatMeters(recoveredForwardM) ..
      ' recoveredRightM=' .. formatMeters(recoveredRightM) ..
      ' recoveredUpM=' .. formatMeters(recoveredUpM))
    return {}
  end

  if reason == 'nearest_visible_tile_spatial_rejected' or reason == 'unusable_spline_window' then
    return rejectSpatialTileWindow(reason)
  end

  return tiles
end

local function rememberLastGoodTiles(tiles)
  if #(tiles or {}) > 0 then
    M.lastGoodTiles = tiles
    M.lastGoodTilesAt = nowSeconds()
    M.staleFrameHold = false
  end
  return tiles
end

local function holdLastGoodTiles(tiles, reason)
  if #(tiles or {}) > 0 then return rememberLastGoodTiles(tiles) end
  local holdS = math.max(0.0, tonumber(settings.VISIBLE_TILE_STALE_HOLD_S) or 0.0)
  if holdS <= 0.0 then return tiles end
  local lastGood = M.lastGoodTiles or {}
  local age = nowSeconds() - (tonumber(M.lastGoodTilesAt) or 0.0)
  local transientReason = tostring(reason or M.spatialPlacementRejectedReason or ''):lower()
  local transient = transientReason == '' or
    transientReason:find('nearest_visible_tile_spatial_rejected', 1, true) ~= nil or
    transientReason:find('visible_tile_spatial_rejected', 1, true) ~= nil or
    transientReason:find('unusable_recovered_window', 1, true) ~= nil or
    transientReason:find('unusable_spline_window', 1, true) ~= nil or
    transientReason:find('no_visible_tiles', 1, true) ~= nil
  if transient and #lastGood > 0 and age >= 0.0 and age <= holdS then
    M.staleFrameHold = true
    for _, tile in ipairs(lastGood) do
      tile.staleFrameHold = true
      tile.staleFrameHoldAgeS = age
      tile.staleFrameHoldReason = transientReason ~= '' and transientReason or 'no_visible_tiles'
    end
    logger.once('visible-tile-stale-hold', 'VISIBLE_TILE_STALE_HOLD reason=' ..
      tostring(transientReason ~= '' and transientReason or 'no_visible_tiles') ..
      ' ageS=' .. string.format('%.3f', age) ..
      ' tileCount=' .. tostring(#lastGood))
    return lastGood
  end
  M.staleFrameHold = false
  return tiles
end

local function buildCueLookahead(car)
  local aheadM = tonumber(settings.BRAKE_LOOKAHEAD_M) or 550.0
  local carLookahead = nil
  if settings.BRAKE_LOOKAHEAD_PREFER_CAR_POSITION == true and car and car.pos then
    carLookahead = track_sampler.tileWindowNearCarAhead(M.profile, car, aheadM, 'car_position_brake_lookahead')
    local carLookaheadUsable = hasUsableForwardTile(carLookahead, car)
    if carLookaheadUsable then return carLookahead end
  end

  local splineLookahead
  if M.tileRecoveryActive then
    splineLookahead = track_sampler.tileWindowNearCarAhead(M.profile, car,
      aheadM, 'car_position_brake_lookahead')
  else
    splineLookahead = track_sampler.tileWindowAhead(M.profile, car and car.splinePosition or 0,
      aheadM, 'brake_lookahead')
  end

  local splineLookaheadUsable = hasUsableForwardTile(splineLookahead, car)
  if splineLookaheadUsable then return splineLookahead end
  if carLookahead and #carLookahead > 0 then return carLookahead end
  return splineLookahead
end

local function logForwardTileProof(tiles, car)
  if not car or not car.pos or not car.forward then return end
  local now = nowSeconds()
  if now < (M.spatialProofNextAt or 0) then return end
  M.spatialProofNextAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)

  local nearestTile = nil
  local nearestForwardM = math.huge
  local nearestForwardRightM = math.huge
  local nearestForwardUpM = math.huge
  for _, tile in ipairs(tiles or {}) do
    if tile.pos then
      local offset = math3d.sub(tile.pos, car.pos)
      local localForward = math3d.dot(offset, car.forward)
      if localForward >= 0 and localForward < nearestForwardM then
        nearestForwardM = localForward
        nearestForwardRightM = math.abs(math3d.dot(offset, car.right or math3d.vec(1, 0, 0)))
        nearestForwardUpM = math.abs(math3d.dot(offset, car.up or math3d.vec(0, 1, 0)))
        nearestTile = tile
      end
    end
  end

  if nearestTile then
    logger.write('VISIBLE_TILE_SPATIAL_PROOF nearestForwardM=' .. formatMeters(nearestForwardM) ..
      ' nearestForwardRightM=' .. formatMeters(nearestForwardRightM) ..
      ' nearestForwardUpM=' .. formatMeters(nearestForwardUpM) ..
      ' dAhead=' .. formatMeters(nearestTile.distanceAheadM) ..
      ' kind=' .. tostring(nearestTile.kind or 'unknown') ..
      ' lineOffsetM=' .. string.format('%.2f', tonumber(nearestTile.dynamicLineOffsetM or nearestTile.racingLineOffsetM) or 0) ..
      ' lineOffsetScale=' .. string.format('%.2f', tonumber(nearestTile.lineOffsetScale) or 1) ..
      ' racingLineActive=' .. tostring(nearestTile.racingLineActive == true) ..
      ' racingLineFallbackReason=' .. tostring(nearestTile.racingLineFallbackReason or '') ..
      ' linePlacementMode=' .. tostring(nearestTile.linePlacementMode or '') ..
      ' targetSpeedKph=' .. tostring(math.floor((nearestTile.targetSpeedKph or 0) + 0.5)) ..
      ' brakeTargetSpeedKph=' .. tostring(math.floor((nearestTile.brakeTargetSpeedKph or nearestTile.targetSpeedKph or 0) + 0.5)) ..
      ' brakeTargetDistanceM=' .. formatMeters(nearestTile.brakeTargetDistanceM) ..
      ' brakeTargetSampleDistanceM=' .. formatMeters(nearestTile.brakeTargetSampleDistanceM) ..
      ' brakeTargetEntryLeadM=' .. formatMeters(nearestTile.brakeTargetEntryLeadM) ..
      ' targetPointAheadM=' .. formatMeters(nearestTile.targetPointAheadM) ..
      ' requiredBrakeDistanceM=' .. formatMeters(nearestTile.requiredBrakeDistanceM) ..
      ' cueCause=' .. tostring(nearestTile.cueCause or nearestTile.cueReason or 'unknown') ..
      ' brakeZoneStartDistanceM=' .. formatMeters(nearestTile.brakeZoneStartDistanceM) ..
      ' brakeZoneWarningStartDistanceM=' .. formatMeters(nearestTile.brakeZoneWarningStartDistanceM) ..
      ' sequenceAdvisoryRatio=' .. string.format('%.3f', tonumber(nearestTile.sequenceAdvisoryRatio) or 0) ..
      ' sequenceDemand=' .. string.format('%.3f', tonumber(nearestTile.sequenceDemand or nearestTile.sequenceAdvisoryRatio) or 0) ..
      ' requiredDecelRatio=' .. string.format('%.3f', tonumber(nearestTile.requiredDecelRatio) or 0) ..
      ' placementMode=' .. tostring(nearestTile.placementMode or 'unknown') ..
      ' windowSource=' .. tostring(nearestTile.windowSource or windowSource(tiles)) ..
      ' runNonce=' .. tostring(M.runNonce or ''))
  else
    local noVisibleRacingLineReason = M.spatialPlacementRejected == true and
      (M.spatialPlacementRejectedReason or 'visible_tile_spatial_rejected') or 'no_visible_tiles'
    logger.write('VISIBLE_TILE_SPATIAL_PROOF nearestForwardM=none tileCount=' .. tostring(#(tiles or {})) ..
      ' racingLineActive=false' ..
      ' racingLineFallbackReason=' .. tostring(noVisibleRacingLineReason) ..
      ' linePlacementMode=centerline_fallback' ..
      ' windowSource=' .. tostring(windowSource(tiles)) ..
      ' runNonce=' .. tostring(M.runNonce or ''))
  end
end

local function capturedBrakeResponsePhaseSpeed(speedKph, captureState)
  captureState = tostring(captureState or 'captured')
  if captureState == 'pending' or captureState == 'approach_pending' or
    captureState == 'none' or captureState == 'unknown' then return 0.0 end
  return math.max(0.0, tonumber(speedKph) or 0.0)
end

local function brakeResponseOverspeedKph(turnInSpeedKph, apexSpeedKph, exitSpeedKph, targetSpeedKph, exitTargetSpeedKph, turnInCaptureState, apexCaptureState, exitCaptureState)
  local target = tonumber(targetSpeedKph) or 0.0
  if target <= 0.0 then return 0.0 end
  local exitTarget = math.max(target, tonumber(exitTargetSpeedKph) or target)
  return math.max(
    0.0,
    capturedBrakeResponsePhaseSpeed(turnInSpeedKph, turnInCaptureState) - target,
    capturedBrakeResponsePhaseSpeed(apexSpeedKph, apexCaptureState) - target,
    capturedBrakeResponsePhaseSpeed(exitSpeedKph, exitCaptureState) - exitTarget)
end

local function classifyBrakeResponseState(brakeInputSeen, speedDropSeen, historyOk, cueKind, turnInSpeedKph, apexSpeedKph, exitSpeedKph, targetSpeedKph, exitTargetSpeedKph, turnInCaptureState, apexCaptureState, exitCaptureState)
  cueKind = tostring(cueKind or 'none')
  if cueKind == 'none' then return 'no_brake_cue', false end
  if brakeInputSeen then
    if speedDropSeen then return 'brake_input_seen', false end
    if historyOk ~= true then return 'brake_input_seen', false end
    local overspeedMargin = math.max(0.0, tonumber(settings.BRAKE_RESPONSE_OVERSPEED_MARGIN_KPH) or 10.0)
    if brakeResponseOverspeedKph(turnInSpeedKph, apexSpeedKph, exitSpeedKph, targetSpeedKph, exitTargetSpeedKph, turnInCaptureState, apexCaptureState, exitCaptureState) > overspeedMargin then
      return 'brake_overspeed_no_slowdown', true
    end
    return 'brake_input_weak_decel', false
  end
  if speedDropSeen then return 'speed_drop_seen', false end
  if historyOk ~= true then return 'awaiting_history', false end
  if cueKind == 'red' then return 'late_no_brake', true end
  return 'pre_brake_monitoring', false
end

local isBrakeCueReason
local classifyBrakeCueTiming

local function logDynamicContextProof(tiles, car)
  local now = nowSeconds()
  if now < (M.dynamicContextProofNextAt or 0) then return end
  M.dynamicContextProofNextAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
  M.runNonce = M.runNonce or makeRunNonce()
  local context = M.lastDynamicContext
  if not context then return end
  car = car or {}
  local currentBrakeInput = math3d.clamp(tonumber(car.brake) or 0.0, 0.0, 1.0)
  local currentGasInput = math3d.clamp(tonumber(car.gas) or 0.0, 0.0, 1.0)
  local currentSpeedKphForProof = tonumber(car.speedKmh) or tonumber(context.currentSpeedKph) or 0.0
  local previousTelemetry = M.brakeCueTelemetry or {}
  local telemetryDt = previousTelemetry.time and (now - previousTelemetry.time) or 0.0
  local historyOk = previousTelemetry.speedKph ~= nil and
    telemetryDt >= (tonumber(settings.BRAKE_RESPONSE_MIN_DT_S) or 0.05) and
    telemetryDt <= (tonumber(settings.BRAKE_RESPONSE_MAX_DT_S) or 1.0)
  local speedDropSinceLastProofKph = historyOk and
    math.max(0.0, (tonumber(previousTelemetry.speedKph) or currentSpeedKphForProof) - currentSpeedKphForProof) or 0.0

  local minTarget = math.huge
  local maxTarget = 0
  local maxRatio = 0
  local maxCueSeverity = 0
  local greenCount = 0
  local yellowCount = 0
  local redCount = 0
  local speedCapCount = 0
  local isolatedRedCount = 0
  local redClusterCount = 0
  local maxRedClusterTiles = 0
  local persistentRedCount = 0
  local staleRedReleaseCount = 0
  local maxRedFrames = 0
  local currentRedCluster = 0
  local persistentFrameThreshold = math.max(1, tonumber(settings.RED_PERSISTENCE_FRAMES) or 1)
  local firstKind = 'none'
  local firstBrakeCueKind = 'none'
  local firstBrakeCueDistanceAheadM = 0
  local firstBrakeCueTargetSpeedKph = 0
  local firstBrakeCueTargetDistanceM = 0
  local firstBrakeCueTargetSampleDistanceM = 0
  local firstBrakeCueAvailableDistanceM = 0
  local firstBrakeCueEntryLeadM = 0
  local firstBrakeCueRequiredBrakeDistanceM = 0
  local firstBrakeCueTargetPointAheadM = 0
  local firstBrakeCueZoneStartDistanceM = 0
  local firstBrakeCueZoneWarningStartDistanceM = 0
  local firstBrakeCueLeadErrorEstimateM = 0
  local firstBrakeCueClusterConfirmedSamples = 0
  local firstBrakeCueSparseTerminalTarget = false
  local firstBrakeCueSparseTerminalCurvatureOk = false
  local firstBrakeCueTransferClassScale = 0
  local firstBrakeCueCornerBrakeBiasM = 0
  local firstBrakeCueDynamicConfidence = 0
  local firstBrakeCueConfidenceUncertaintyScale = 0
  local firstBrakeCueConfidenceMarginM = 0
  local firstBrakeCueReason = 'none'
  local sequenceAdvisoryCount = 0
  local maxSequenceAdvisoryRatio = 0
  local instabilityAdvisoryCount = 0
  local maxInstabilityAdvisoryRatio = 0
  local knowledgeBaseAdvisoryCount = 0
  local maxKnowledgeBaseAdvisoryRatio = 0
  local maxKnowledgeBaseRisk = 0
  local minKnowledgeBaseTargetScale = 1.0
  local maxLineOffset = 0
  local maxStaticLineOffset = 0
  local maxLineOffsetStepM = 0
  local maxLineOffsetAccelM = 0
  local maxLineOffsetJerkM = 0
  local previousLineOffset = nil
  local previousLineOffsetStep = nil
  local previousLineOffsetAccel = nil
  local brakeProfileEnvelopeCount = 0
  local maxBrakeProfileReductionKph = 0
  local lineOffsetScale = 1.0
  local firstTile = tiles and tiles[1] or nil
  local racingLineActive = false
  local racingLineFallbackReason = 'no_visible_tiles'
  local linePlacementMode = 'centerline_fallback'
  if M.spatialPlacementRejected == true then
    racingLineFallbackReason = M.spatialPlacementRejectedReason or 'visible_tile_spatial_rejected'
  elseif firstTile then
    racingLineActive = firstTile.racingLineActive == true
    racingLineFallbackReason = firstTile.racingLineFallbackReason or ''
    linePlacementMode = firstTile.linePlacementMode or ''
  end
  local function closeRedCluster()
    if currentRedCluster <= 0 then return end
    if currentRedCluster == 1 then isolatedRedCount = isolatedRedCount + 1 end
    if currentRedCluster > maxRedClusterTiles then maxRedClusterTiles = currentRedCluster end
    currentRedCluster = 0
  end

  for _, tile in ipairs(tiles or {}) do
    local target = tonumber(tile and tile.targetSpeedKph)
    if target then
      if target < minTarget then minTarget = target end
      if target > maxTarget then maxTarget = target end
    end
    local ratio = tonumber(tile and tile.requiredDecelRatio) or 0
    if ratio > maxRatio then maxRatio = ratio end
    local severity = tonumber(tile and tile.cueSeverity) or 0
    if severity > maxCueSeverity then maxCueSeverity = severity end
    if tile and tile.brakeProfileEnvelopeLimited == true then brakeProfileEnvelopeCount = brakeProfileEnvelopeCount + 1 end
    local brakeProfileReductionKph = tonumber(tile and tile.brakeProfileReductionKph) or 0
    if brakeProfileReductionKph > maxBrakeProfileReductionKph then
      maxBrakeProfileReductionKph = brakeProfileReductionKph
    end
    local signedLineOffset = tonumber(tile and (tile.dynamicLineOffsetM or tile.racingLineOffsetM)) or 0
    local dynamicLineOffset = math.abs(signedLineOffset)
    local staticLineOffset = math.abs(tonumber(tile and tile.racingLineOffsetM) or 0)
    if dynamicLineOffset > maxLineOffset then maxLineOffset = dynamicLineOffset end
    if staticLineOffset > maxStaticLineOffset then maxStaticLineOffset = staticLineOffset end
    if previousLineOffset ~= nil then
      local lineOffsetStep = signedLineOffset - previousLineOffset
      local absStep = math.abs(lineOffsetStep)
      if absStep > maxLineOffsetStepM then maxLineOffsetStepM = absStep end
      if previousLineOffsetStep ~= nil then
        local lineOffsetAccel = lineOffsetStep - previousLineOffsetStep
        local absAccel = math.abs(lineOffsetAccel)
        if absAccel > maxLineOffsetAccelM then maxLineOffsetAccelM = absAccel end
        if previousLineOffsetAccel ~= nil then
          local lineOffsetJerk = lineOffsetAccel - previousLineOffsetAccel
          local absJerk = math.abs(lineOffsetJerk)
          if absJerk > maxLineOffsetJerkM then maxLineOffsetJerkM = absJerk end
        end
        previousLineOffsetAccel = lineOffsetAccel
      end
      previousLineOffsetStep = lineOffsetStep
    end
    previousLineOffset = signedLineOffset
    if tile and tile.lineOffsetScale then lineOffsetScale = tonumber(tile.lineOffsetScale) or lineOffsetScale end
    local sequenceAdvisory = tonumber(tile and tile.sequenceAdvisoryRatio) or 0
    if sequenceAdvisory > 0 then
      sequenceAdvisoryCount = sequenceAdvisoryCount + 1
      if sequenceAdvisory > maxSequenceAdvisoryRatio then maxSequenceAdvisoryRatio = sequenceAdvisory end
    end
    local instabilityAdvisory = tonumber(tile and tile.instabilityAdvisoryRatio) or 0
    if instabilityAdvisory > 0 then
      instabilityAdvisoryCount = instabilityAdvisoryCount + 1
      if instabilityAdvisory > maxInstabilityAdvisoryRatio then maxInstabilityAdvisoryRatio = instabilityAdvisory end
    end
    local knowledgeBaseAdvisory = tonumber(tile and tile.knowledgeBaseAdvisoryRatio) or 0
    if knowledgeBaseAdvisory > 0 then
      knowledgeBaseAdvisoryCount = knowledgeBaseAdvisoryCount + 1
      if knowledgeBaseAdvisory > maxKnowledgeBaseAdvisoryRatio then maxKnowledgeBaseAdvisoryRatio = knowledgeBaseAdvisory end
    end
    local knowledgeBaseRisk = tonumber(tile and tile.knowledgeBaseRisk) or 0
    if knowledgeBaseRisk > maxKnowledgeBaseRisk then maxKnowledgeBaseRisk = knowledgeBaseRisk end
    local knowledgeBaseTargetScale = tonumber(tile and tile.knowledgeBaseTargetScale) or 1.0
    if knowledgeBaseTargetScale < minKnowledgeBaseTargetScale then minKnowledgeBaseTargetScale = knowledgeBaseTargetScale end
    local redFrames = tonumber(tile and tile.redFrames) or 0
    if redFrames > maxRedFrames then maxRedFrames = redFrames end
    if tile and (tile.cueReason == 'release_from_red' or tile.cueReason == 'recovery_advisory') then
      staleRedReleaseCount = staleRedReleaseCount + 1
    end
    if tile and tile.kind == 'red' then
      redCount = redCount + 1
      currentRedCluster = currentRedCluster + 1
      if currentRedCluster == 1 then redClusterCount = redClusterCount + 1 end
      if redFrames >= persistentFrameThreshold then persistentRedCount = persistentRedCount + 1 end
    elseif tile and tile.kind == 'yellow' then
      closeRedCluster()
      yellowCount = yellowCount + 1
    elseif tile and tile.kind == 'green' then
      closeRedCluster()
      greenCount = greenCount + 1
    else
      closeRedCluster()
    end
    local cueReason = tostring(tile and tile.cueReason or 'unknown')
    if firstBrakeCueKind == 'none' and tile and (tile.kind == 'yellow' or tile.kind == 'red') and isBrakeCueReason(cueReason) then
      firstBrakeCueKind = tostring(tile.kind)
      firstBrakeCueReason = cueReason
      firstBrakeCueDistanceAheadM = tonumber(tile.distanceAheadM) or 0
      firstBrakeCueTargetSpeedKph = tonumber(tile.brakeTargetSpeedKph or tile.targetSpeedKph) or 0
      firstBrakeCueTargetDistanceM = tonumber(tile.brakeTargetDistanceM) or 0
      firstBrakeCueTargetSampleDistanceM = tonumber(tile.brakeTargetSampleDistanceM) or 0
      firstBrakeCueAvailableDistanceM = tonumber(tile.brakeTargetAvailableDistanceM) or 0
      firstBrakeCueEntryLeadM = tonumber(tile.brakeTargetEntryLeadM) or 0
      firstBrakeCueRequiredBrakeDistanceM = tonumber(tile.requiredBrakeDistanceM) or 0
      firstBrakeCueTargetPointAheadM = tonumber(tile.targetPointAheadM or tile.brakeTargetDistanceM) or 0
      firstBrakeCueZoneStartDistanceM = tonumber(tile.brakeZoneStartDistanceM) or 0
      firstBrakeCueZoneWarningStartDistanceM = tonumber(tile.brakeZoneWarningStartDistanceM) or 0
      firstBrakeCueClusterConfirmedSamples = tonumber(tile.brakeClusterConfirmedSamples) or 0
      firstBrakeCueSparseTerminalTarget = tile.brakeSparseTerminalTarget == true
      firstBrakeCueSparseTerminalCurvatureOk = tile.brakeSparseTerminalCurvatureOk == true
      firstBrakeCueTransferClassScale = tonumber(tile.brakeTransferClassScale or tile.transferClassScale) or 0
      firstBrakeCueCornerBrakeBiasM = tonumber(tile.cornerBrakeBiasM) or 0
      firstBrakeCueDynamicConfidence = tonumber(tile.dynamicConfidence) or 0
      firstBrakeCueConfidenceUncertaintyScale = tonumber(tile.confidenceUncertaintyScale) or 0
      firstBrakeCueConfidenceMarginM = tonumber(tile.brakeConfidenceMarginM) or 0
      if firstBrakeCueKind == 'red' then
        firstBrakeCueLeadErrorEstimateM = firstBrakeCueDistanceAheadM - firstBrakeCueZoneStartDistanceM
      else
        firstBrakeCueLeadErrorEstimateM = firstBrakeCueDistanceAheadM - firstBrakeCueZoneWarningStartDistanceM
      end
    end
    if tile and tile.straightSpeedCap == true then speedCapCount = speedCapCount + 1 end
    if firstKind == 'none' and tile and tile.kind then firstKind = tostring(tile.kind) end
  end
  closeRedCluster()
  if minTarget == math.huge then minTarget = 0 end
  local brakeInputThreshold = math.max(0.0, tonumber(settings.BRAKE_RESPONSE_INPUT_THRESHOLD) or 0.20)
  local speedDropThresholdKph = math.max(0.0, tonumber(settings.BRAKE_RESPONSE_SPEED_DROP_KPH) or 1.0)
  local brakeInputSeen = currentBrakeInput >= brakeInputThreshold
  local speedDropSeen = speedDropSinceLastProofKph >= speedDropThresholdKph
  local brakeCueTimingState, brakeCueTimingToleranceM =
    classifyBrakeCueTiming(firstBrakeCueKind, firstBrakeCueLeadErrorEstimateM, firstBrakeCueEntryLeadM)
  local brakeCueResponseState, brakeCueResponseLateRisk = 'no_brake_cue', false
  brakeCueResponseState, brakeCueResponseLateRisk = classifyBrakeResponseState(
    brakeInputSeen,
    speedDropSeen,
    historyOk,
    firstBrakeCueKind,
    currentSpeedKphForProof,
    firstBrakeCueTargetSpeedKph,
    currentSpeedKphForProof,
    firstBrakeCueTargetSpeedKph,
    firstBrakeCueTargetSpeedKph,
    'entry_captured',
    'apex_captured',
    'exit_captured')
  M.brakeCueTelemetry = {
    time = now,
    speedKph = currentSpeedKphForProof,
    brakeInput = currentBrakeInput,
  }
  if settings.PERFORMANCE_SAFE_MODE == true and settings.COMPACT_PROOF_IN_PERFORMANCE_SAFE_MODE == true then
    logger.write('DYNAMIC_CONTEXT_PROOF_COMPACT' ..
      ' speedKph=' .. string.format('%.1f', currentSpeedKphForProof) ..
      ' brakeInput=' .. string.format('%.2f', currentBrakeInput) ..
      ' gasInput=' .. string.format('%.2f', currentGasInput) ..
      ' brakeCueKind=' .. tostring(firstBrakeCueKind) ..
      ' brakeCueReason=' .. tostring(firstBrakeCueReason) ..
      ' brakeCueDistanceM=' .. string.format('%.1f', firstBrakeCueDistanceAheadM) ..
      ' brakeTargetSpeedKph=' .. string.format('%.1f', firstBrakeCueTargetSpeedKph) ..
      ' brakeTargetDistanceM=' .. string.format('%.1f', firstBrakeCueTargetDistanceM) ..
      ' brakeTargetSampleDistanceM=' .. string.format('%.1f', firstBrakeCueTargetSampleDistanceM) ..
      ' brakeZoneStartM=' .. string.format('%.1f', firstBrakeCueZoneStartDistanceM) ..
      ' brakeZoneWarningM=' .. string.format('%.1f', firstBrakeCueZoneWarningStartDistanceM) ..
      ' brakeTimingState=' .. tostring(brakeCueTimingState) ..
      ' brakeResponseState=' .. tostring(brakeCueResponseState) ..
      ' brakeResponseLateRisk=' .. tostring(brakeCueResponseLateRisk == true) ..
      ' minTargetSpeedKph=' .. tostring(math.floor(minTarget + 0.5)) ..
      ' maxTargetSpeedKph=' .. tostring(math.floor(maxTarget + 0.5)) ..
      ' maxRequiredDecelRatio=' .. string.format('%.3f', maxRatio) ..
      ' maxCueSeverity=' .. string.format('%.3f', maxCueSeverity) ..
      ' tileCount=' .. tostring(#(tiles or {})) ..
      ' speedCapCount=' .. tostring(speedCapCount) ..
      ' brakeProfileEnvelopeCount=' .. tostring(brakeProfileEnvelopeCount) ..
      ' maxBrakeProfileReductionKph=' .. string.format('%.1f', maxBrakeProfileReductionKph) ..
      ' greenCount=' .. tostring(greenCount) ..
      ' yellowCount=' .. tostring(yellowCount) ..
      ' redCount=' .. tostring(redCount) ..
      ' maxRedClusterTiles=' .. tostring(maxRedClusterTiles) ..
      ' maxLineOffsetM=' .. string.format('%.2f', maxLineOffset) ..
      ' maxLineOffsetStepM=' .. string.format('%.3f', maxLineOffsetStepM) ..
      ' maxLineOffsetAccelM=' .. string.format('%.3f', maxLineOffsetAccelM) ..
      ' maxLineOffsetJerkM=' .. string.format('%.3f', maxLineOffsetJerkM) ..
      ' lineOffsetScale=' .. string.format('%.2f', tonumber(lineOffsetScale) or 1) ..
      ' racingLineActive=' .. tostring(racingLineActive == true) ..
      ' linePlacementMode=' .. tostring(linePlacementMode or '') ..
      ' roadGrip=' .. string.format('%.2f', tonumber(context.roadGrip) or 0) ..
      ' surfaceGrip=' .. string.format('%.2f', tonumber(context.surfaceGrip) or 0) ..
      ' corneringG=' .. string.format('%.2f', tonumber(context.corneringG) or 0) ..
      ' brakeG=' .. string.format('%.2f', tonumber(context.brakeG) or 0) ..
      ' confidence=' .. string.format('%.2f', tonumber(context.confidence) or 0) ..
      ' version=' .. tostring(settings.VERSION or '') ..
      ' buildId=' .. tostring(settings.BUILD_ID or '') ..
      ' runNonce=' .. tostring(M.runNonce or '') ..
      ' carId=' .. tostring(M.activeCarId or '') ..
      ' trackId=' .. tostring(M.activeTrackId or '') ..
      ' trackLayout=' .. tostring(M.activeTrackLayout or ''))
    return
  end
  local proofMomentKey = cornerLearningMomentKey(context)
  local cornerLearning = M.lastCornerLearning
  if not cornerLearning or tostring(cornerLearning.cornerLearningMomentKey or '') ~= proofMomentKey then
    cornerLearning = corner_learning.biasFor(car, {
      trackId = M.activeTrackId,
      trackLayout = M.activeTrackLayout,
      progress = car and car.splinePosition,
      cornerLearningMomentKey = proofMomentKey,
    })
  end
  local cornerLearningSummary = corner_learning.summary()
  local traffic = trafficLearningBlock(car)

  local proofParts = { 'DYNAMIC_CONTEXT_PROOF' }
  local function addProofField(name, value)
    proofParts[#proofParts + 1] = ' '
    proofParts[#proofParts + 1] = name
    proofParts[#proofParts + 1] = tostring(value)
  end
  addProofField('roadGrip=', string.format('%.2f', tonumber(context.roadGrip) or 0))
  addProofField('surfaceGrip=', string.format('%.2f', tonumber(context.surfaceGrip) or 0))
  addProofField('rain=', string.format('%.2f/%.2f/%.2f',
      tonumber(context.rainIntensity) or 0,
      tonumber(context.rainWetness) or 0,
      tonumber(context.rainWater) or 0))
  addProofField('ambientTemperatureC=', string.format('%.1f', tonumber(context.ambientTemperatureC) or 0))
  addProofField('roadTemperatureC=', string.format('%.1f', tonumber(context.roadTemperatureC) or 0))
  addProofField('windSpeedKmh=', string.format('%.1f', tonumber(context.windSpeedKmh) or 0))
  addProofField('trackThermalCornerFactor=', string.format('%.2f', tonumber(context.trackThermalCornerFactor) or 0))
  addProofField('trackThermalBrakeFactor=', string.format('%.2f', tonumber(context.trackThermalBrakeFactor) or 0))
  addProofField('windFactor=', string.format('%.2f', tonumber(context.windFactor) or 0))
  addProofField('tyreWear=', string.format('%.2f', tonumber(context.tyreWear) or 0))
  addProofField('tyreDirty=', string.format('%.2f', tonumber(context.tyreDirty) or 0))
  addProofField('tyreTempDeltaC=', string.format('%.1f', tonumber(context.tyreTempDeltaC) or 0))
  addProofField('tyreTempConfidence=', string.format('%.2f', tonumber(context.tyreTempConfidence) or 0))
  addProofField('pressurePenalty=', string.format('%.2f', tonumber(context.pressurePenalty) or 0))
  addProofField('pressureSource=', tostring(context.pressureSource or 'none'))
  addProofField('pressureSourceTokens=', tostring(context.pressureSourceTokens or 'fallback:fallback:fallback:fallback'))
  addProofField('pressureSourceTyres=', tostring(context.pressureSourceTyres or 'lf:fallback,rf:fallback,lr:fallback,rr:fallback'))
  addProofField('pressureSourceTokenLF=', tostring(context.pressureSourceTokenLF or 'fallback'))
  addProofField('pressureSourceTokenRF=', tostring(context.pressureSourceTokenRF or 'fallback'))
  addProofField('pressureSourceTokenLR=', tostring(context.pressureSourceTokenLR or 'fallback'))
  addProofField('pressureSourceTokenRR=', tostring(context.pressureSourceTokenRR or 'fallback'))
  addProofField('setupPressureSourceTokens=', tostring(context.setupPressureSourceTokens or 'fallback:fallback:fallback:fallback'))
  addProofField('setupPressureSourceTyres=', tostring(context.setupPressureSourceTyres or 'lf:fallback,rf:fallback,lr:fallback,rr:fallback'))
  addProofField('setupPressureSourceTokenLF=', tostring(context.setupPressureSourceTokenLF or 'fallback'))
  addProofField('setupPressureSourceTokenRF=', tostring(context.setupPressureSourceTokenRF or 'fallback'))
  addProofField('setupPressureSourceTokenLR=', tostring(context.setupPressureSourceTokenLR or 'fallback'))
  addProofField('setupPressureSourceTokenRR=', tostring(context.setupPressureSourceTokenRR or 'fallback'))
  addProofField('setupPressureDeltaPsi=', string.format('%.1f', tonumber(context.setupPressureDeltaPsi) or 0))
  addProofField('setupMechanicalSource=', tostring(context.setupMechanicalSource or 'none'))
  addProofField('setupMechanicalCount=', tostring(context.setupMechanicalCount or 0))
  addProofField('setupDrivetrainSource=', tostring(context.setupDrivetrainSource or 'none'))
  addProofField('setupDrivetrainCount=', tostring(context.setupDrivetrainCount or 0))
  addProofField('setupDrivetrainToken=', tostring(context.setupDrivetrainToken or 'none'))
  addProofField('setupDrivetrainRisk=', string.format('%.3f', tonumber(context.setupDrivetrainRisk) or 0))
  addProofField('setupDamperSource=', tostring(context.setupDamperSource or 'none'))
  addProofField('setupDamperCount=', tostring(context.setupDamperCount or 0))
  addProofField('setupDamperToken=', tostring(context.setupDamperToken or 'none'))
  addProofField('setupDamperRisk=', string.format('%.3f', tonumber(context.setupDamperRisk) or 0))
  addProofField('setupGearSource=', tostring(context.setupGearSource or 'none'))
  addProofField('setupGearCount=', tostring(context.setupGearCount or 0))
  addProofField('setupGearToken=', tostring(context.setupGearToken or 'none'))
  addProofField('setupGearRisk=', string.format('%.3f', tonumber(context.setupGearRisk) or 0))
  addProofField('setupDiffSource=', tostring(context.setupDiffSource or 'none'))
  addProofField('setupDiffCount=', tostring(context.setupDiffCount or 0))
  addProofField('setupDiffToken=', tostring(context.setupDiffToken or 'none'))
  addProofField('setupDiffRisk=', string.format('%.3f', tonumber(context.setupDiffRisk) or 0))
  addProofField('setupAssistSource=', tostring(context.setupAssistSource or 'none'))
  addProofField('setupAssistCount=', tostring(context.setupAssistCount or 0))
  addProofField('setupAssistToken=', tostring(context.setupAssistToken or 'none'))
  addProofField('setupAssistRisk=', string.format('%.3f', tonumber(context.setupAssistRisk) or 0))
  addProofField('setupArbBalance=', string.format('%.3f', tonumber(context.setupArbBalance) or 0))
  addProofField('setupCamberSpread=', string.format('%.1f', tonumber(context.setupCamberSpread) or 0))
  addProofField('setupToeSpread=', string.format('%.1f', tonumber(context.setupToeSpread) or 0))
  addProofField('setupAeroBalance=', string.format('%.3f', tonumber(context.setupAeroBalance) or 0))
  addProofField('setupAeroSpread=', string.format('%.1f', tonumber(context.setupAeroSpread) or 0))
  addProofField('setupAeroRisk=', string.format('%.3f', tonumber(context.setupAeroRisk) or 0))
  addProofField('setupMechanicalRisk=', string.format('%.3f', tonumber(context.setupMechanicalRisk) or 0))
  addProofField('setupMechanicalConfidencePenalty=', string.format('%.3f', tonumber(context.setupMechanicalConfidencePenalty) or 0))
  addProofField('globalCorneringMechanicalDelta=', string.format('%.3f', tonumber(context.globalCorneringMechanicalDelta) or 0))
  addProofField('globalBrakeMechanicalDelta=', string.format('%.3f', tonumber(context.globalBrakeMechanicalDelta) or 0))
  addProofField('liveGripEnvelopeState=', tostring(context.liveGripEnvelopeState or 'nominal'))
  addProofField('liveGripEnvelopePenalty=', string.format('%.3f', tonumber(context.liveGripEnvelopePenalty) or 0))
  addProofField('liveGripEnvelopeConfidence=', string.format('%.3f', tonumber(context.liveGripEnvelopeConfidence) or 0))
  addProofField('slipStress=', string.format('%.2f', tonumber(context.slipStress) or 0))
  addProofField('frontTyreStress=', string.format('%.2f', tonumber(context.frontTyreStress) or 0))
  addProofField('rearTyreStress=', string.format('%.2f', tonumber(context.rearTyreStress) or 0))
  addProofField('worstAxleTyreStress=', string.format('%.2f', tonumber(context.worstAxleTyreStress) or 0))
  addProofField('axleBalancePenalty=', string.format('%.2f', tonumber(context.axleBalancePenalty) or 0))
  addProofField('absMode=', string.format('%.0f', tonumber(context.absMode) or 0))
  addProofField('tractionControlMode=', string.format('%.0f', tonumber(context.tractionControlMode) or 0))
  addProofField('absInAction=', tostring(context.absInAction == true))
  addProofField('tractionControlInAction=', tostring(context.tractionControlInAction == true))
  addProofField('assistPenalty=', string.format('%.3f', tonumber(context.assistPenalty) or 1))
  addProofField('brakeAssistPenalty=', string.format('%.3f', tonumber(context.brakeAssistPenalty) or 1))
  addProofField('fuelFraction=', string.format('%.2f', tonumber(context.fuelFraction) or 0))
  addProofField('fuelLoadL=', string.format('%.1f', tonumber(context.fuelLoadL) or 0))
  addProofField('fuelCapacityL=', string.format('%.1f', tonumber(context.fuelCapacityL) or 0))
  addProofField('fuelLoadSource=', tostring(context.fuelLoadSource or 'unknown'))
  addProofField('fuelMassKg=', string.format('%.1f', tonumber(context.fuelMassKg) or 0))
  addProofField('fuelMassRatio=', string.format('%.3f', tonumber(context.fuelMassRatio) or 0))
  addProofField('currentSpeedKph=', string.format('%.1f', tonumber(context.currentSpeedKph) or 0))
  addProofField('currentSpeedMs=', string.format('%.1f', tonumber(context.currentSpeedMs) or 0))
  addProofField('currentBrakeInput=', string.format('%.2f', currentBrakeInput))
  addProofField('currentGasInput=', string.format('%.2f', currentGasInput))
  addProofField('speedDropSinceLastProofKph=', string.format('%.1f', speedDropSinceLastProofKph))
  addProofField('brakeCueResponseState=', tostring(brakeCueResponseState))
  addProofField('brakeCueResponseLateRisk=', tostring(brakeCueResponseLateRisk == true))
  addProofField('brakeCueTimingState=', tostring(brakeCueTimingState))
  addProofField('brakeCueTimingToleranceM=', string.format('%.1f', brakeCueTimingToleranceM))
  addProofField('cornerLearningKey=', tostring(cornerLearning.cornerLearningKey or ''))
  addProofField('cornerLearningMomentKey=', tostring(cornerLearning.cornerLearningMomentKey or proofMomentKey))
  addProofField('cornerLearningState=', tostring(cornerLearning.cornerLearningState or ''))
  addProofField('cornerLearningSamples=', tostring(cornerLearning.samples or 0))
  addProofField('cornerLearningTraceSamples=', tostring(cornerLearning.traceSamples or 0))
  addProofField('cornerLearningTraceMinZoneStartDistanceM=', string.format('%.1f', tonumber(cornerLearning.traceMinZoneStartDistanceM) or 0))
  addProofField('cornerLearningTraceMaxZoneStartDistanceM=', string.format('%.1f', tonumber(cornerLearning.traceMaxZoneStartDistanceM) or 0))
  addProofField('cornerLearningMaxCueDistanceM=', string.format('%.1f', tonumber(settings.CORNER_LEARNING_MAX_CUE_DISTANCE_M) or 0))
  addProofField('cornerLearningSampleAccepted=', tostring(cornerLearning.sampleAccepted == true))
  addProofField('cornerLearningRejectReason=', tostring(cornerLearning.cornerLearningRejectReason or 'none'))
  addProofField('cornerLearningBrakeLimitReason=', tostring(cornerLearning.cornerLearningBrakeLimitReason or 'none'))
  addProofField('cornerLearningCauseBucket=', tostring(cornerLearning.cornerLearningCauseBucket or 'none'))
  addProofField('cornerLearningConfidence=', string.format('%.2f', tonumber(cornerLearning.cornerLearningConfidence) or 0))
  addProofField('cornerLearningSetupKnown=', tostring(cornerLearning.cornerLearningSetupKnown == true))
  addProofField('cornerLearningSetupTrustScale=', string.format('%.2f', tonumber(cornerLearning.cornerLearningSetupTrustScale) or 0))
  addProofField('cornerLearningCleanWindowSamples=', string.format('%.1f', tonumber(cornerLearning.cornerLearningCleanWindowSamples) or 0))
  addProofField('cornerLearningRiskWindowSamples=', string.format('%.1f', tonumber(cornerLearning.cornerLearningRiskWindowSamples) or 0))
  addProofField('cornerLearningWindowSamples=', string.format('%.1f', tonumber(cornerLearning.cornerLearningWindowSamples) or 0))
  addProofField('cornerLearningCleanAcceptedCount=', tostring(cornerLearningSummary.cleanAccepted or 0))
  addProofField('cornerLearningNoBrakeCount=', tostring(cornerLearningSummary.noBrake or 0))
  addProofField('cornerLearningWeakDecelCount=', tostring(cornerLearningSummary.weakDecel or 0))
  addProofField('cornerLearningOverspeedCount=', tostring(cornerLearningSummary.overspeed or 0))
  addProofField('cornerLearningResultOverspeedCount=', tostring(cornerLearningSummary.resultOverspeed or 0))
  addProofField('cornerLearningAbsCount=', tostring(cornerLearningSummary.abs or 0))
  addProofField('cornerLearningFrontLockupCount=', tostring(cornerLearningSummary.frontLockup or 0))
  addProofField('cornerLearningRearLockupCount=', tostring(cornerLearningSummary.rearLockup or 0))
  addProofField('cornerLearningAllLockupCount=', tostring(cornerLearningSummary.allLockup or 0))
  addProofField('cornerLearningRejectedCount=', tostring(cornerLearningSummary.rejected or 0))
  addProofField('cornerLearningObservedCornerCount=', tostring(cornerLearningSummary.observedCornerCount or 0))
  addProofField('cornerLearningLowConfidenceCornerCount=', tostring(cornerLearningSummary.lowConfidenceCornerCount or 0))
  addProofField('cornerLearningRiskDominantCornerCount=', tostring(cornerLearningSummary.riskDominantCornerCount or 0))
  addProofField('cornerLearningMinConfidence=', string.format('%.2f', tonumber(cornerLearningSummary.minConfidence) or 0))
  addProofField('cornerLearningMaxBiasDampingM=', string.format('%.1f', tonumber(cornerLearningSummary.maxBiasDampingM) or 0))
  addProofField('cornerLearningWorstKey=', tostring(cornerLearningSummary.worstKey or 'none'))
  addProofField('cornerLearningWorstCauseBucket=', tostring(cornerLearningSummary.worstCauseBucket or 'none'))
  addProofField('trafficCarAheadM=', string.format('%.1f', traffic.aheadM))
  addProofField('trafficCarLateralM=', string.format('%.1f', traffic.lateralM))
  addProofField('trafficCarDistanceM=', string.format('%.1f', traffic.distanceM))
  addProofField('trafficLearningClear=', tostring(traffic.blocked ~= true))
  addProofField('trafficScanStatus=', tostring(traffic.scanStatus))
  addProofField('trafficCarsCount=', tostring(traffic.carsCount))
  addProofField('trafficOpponentIndex=', tostring(traffic.opponentIndex))
  addProofField('rawCornerBrakeBiasM=', string.format('%.1f', tonumber(cornerLearning.rawCornerBrakeBiasM) or 0))
  addProofField('cornerBrakeBiasM=', string.format('%.1f', tonumber(cornerLearning.cornerBrakeBiasM) or 0))
  addProofField('cornerLearningCadence=', 'frame')
  addProofField('cornerLearningObserveIntervalS=', string.format('%.2f', tonumber(settings.CORNER_LEARNING_OBSERVE_INTERVAL_S) or 0))
  addProofField('cornerPredictedBrakePointM=', string.format('%.1f', tonumber(cornerLearning.predictedBrakePointM) or 0))
  addProofField('cornerActualBrakePointErrorM=', string.format('%.1f', tonumber(cornerLearning.actualBrakePointErrorM) or 0))
  addProofField('cornerActualBrakeOnsetState=', tostring(cornerLearning.actualBrakeOnsetState or 'none'))
  addProofField('cornerActualBrakeOnsetZoneStartDistanceM=', string.format('%.1f', tonumber(cornerLearning.actualBrakeOnsetZoneStartDistanceM) or 0))
  addProofField('cornerActualBrakeOnsetInput=', string.format('%.2f', tonumber(cornerLearning.actualBrakeOnsetInput) or 0))
  addProofField('cornerEffectiveBrakeInput=', string.format('%.2f', tonumber(cornerLearning.effectiveBrakeInput) or 0))
  addProofField('cornerActualBrakeOnsetSpeedKph=', string.format('%.1f', tonumber(cornerLearning.actualBrakeOnsetSpeedKph) or 0))
  addProofField('cornerSpeedOverTargetKph=', string.format('%.1f', tonumber(cornerLearning.cornerSpeedOverTargetKph) or 0))
  addProofField('cornerResultLearningReason=', tostring(cornerLearning.cornerResultLearningReason or 'none'))
  addProofField('cornerResultOverspeedPhase=', tostring(cornerLearning.cornerResultOverspeedPhase or 'none'))
  addProofField('cornerTurnInSpeedKph=', string.format('%.1f', tonumber(cornerLearning.turnInSpeedKph) or 0))
  addProofField('cornerTurnInCaptureState=', tostring(cornerLearning.turnInCaptureState or 'none'))
  addProofField('cornerTurnInSampleZoneStartDistanceM=', string.format('%.1f', tonumber(cornerLearning.turnInSampleZoneStartDistanceM) or 0))
  addProofField('cornerTargetSpeedKph=', string.format('%.1f', tonumber(cornerLearning.targetSpeedKph) or 0))
  addProofField('cornerExitTargetSpeedKph=', string.format('%.1f', tonumber(cornerLearning.exitTargetSpeedKph) or 0))
  addProofField('cornerApexSpeedKph=', string.format('%.1f', tonumber(cornerLearning.apexSpeedKph) or 0))
  addProofField('cornerApexCaptureState=', tostring(cornerLearning.apexCaptureState or 'none'))
  addProofField('cornerExitSpeedKph=', string.format('%.1f', tonumber(cornerLearning.exitSpeedKph) or 0))
  addProofField('cornerExitCaptureState=', tostring(cornerLearning.exitCaptureState or 'none'))
  addProofField('brakeBias=', string.format('%.2f', tonumber(context.brakeBias) or 0))
  addProofField('brakeBiasBrakeFactor=', string.format('%.3f', tonumber(context.brakeBiasBrakeFactor) or 0))
  addProofField('brakePowerMult=', string.format('%.2f', tonumber(context.brakePowerMult) or 0))
  addProofField('brakePowerSource=', tostring(context.brakePowerSource or 'fallback'))
  addProofField('brakeBiasSource=', tostring(context.brakeBiasSource or 'fallback'))
  addProofField('ballastKg=', string.format('%.1f', tonumber(context.ballastKg) or 0))
  addProofField('restrictor=', string.format('%.1f', tonumber(context.restrictor) or 0))
  addProofField('ballastLoadFactor=', string.format('%.3f', tonumber(context.ballastLoadFactor) or 0))
  addProofField('damageLevel=', string.format('%.2f', tonumber(context.damageLevel) or 0))
  addProofField('damageCornerFactor=', string.format('%.3f', tonumber(context.damageCornerFactor) or 0))
  addProofField('damageBrakeFactor=', string.format('%.3f', tonumber(context.damageBrakeFactor) or 0))
  addProofField('damageAeroFactor=', string.format('%.3f', tonumber(context.damageAeroFactor) or 0))
  addProofField('wing=', string.format('%.2f', tonumber(context.wingSetting) or 0))
  addProofField('wingSource=', tostring(context.wingSource or 'fallback'))
  addProofField('setupState=', tostring(context.setupState or 'unknown'))
  addProofField('setupFingerprint=', tostring(context.setupFingerprint or ''))
  addProofField('telemetryLearningKey=', tostring(context.telemetryLearningKey or ''))
  addProofField('telemetryResetReason=', tostring(context.telemetryResetReason or 'none'))
  addProofField('setupLiveProvenMinSamples=', tostring(context.setupLiveProvenMinSamples or 0))
  addProofField('setupChangedWarmupActive=', tostring(context.setupChangedWarmupActive == true))
  addProofField('setupAdaptationState=', tostring(context.setupAdaptationState or 'unknown'))
  addProofField('setupAdaptationConfidence=', string.format('%.2f', tonumber(context.setupAdaptationConfidence) or 0))
  addProofField('setupAdaptationProof=', string.format('%.2f', tonumber(context.setupAdaptationProof) or 0))
  addProofField('setupBrakeAdaptationState=', tostring(context.setupBrakeAdaptationState or 'unknown'))
  addProofField('setupBrakeAdaptationConfidence=', string.format('%.2f', tonumber(context.setupBrakeAdaptationConfidence) or 0))
  addProofField('setupBrakeAdaptationProof=', string.format('%.2f', tonumber(context.setupBrakeAdaptationProof) or 0))
  addProofField('setupCornerAdaptationState=', tostring(context.setupCornerAdaptationState or 'unknown'))
  addProofField('setupCornerAdaptationConfidence=', string.format('%.2f', tonumber(context.setupCornerAdaptationConfidence) or 0))
  addProofField('setupCornerAdaptationProof=', string.format('%.2f', tonumber(context.setupCornerAdaptationProof) or 0))
  addProofField('capabilitySource=', tostring(context.capabilitySource or 'unknown'))
  addProofField('capabilityTier=', tostring(context.capabilityTier or 'unknown'))
  addProofField('capabilityConfidence=', string.format('%.2f', tonumber(context.capabilityConfidence) or 0))
  addProofField('corneringGSource=', tostring(context.corneringGSource or 'unknown'))
  addProofField('corneringGConfidence=', string.format('%.2f', tonumber(context.corneringGConfidence) or 0))
  addProofField('brakeGSource=', tostring(context.brakeGSource or 'unknown'))
  addProofField('brakeGConfidence=', string.format('%.2f', tonumber(context.brakeGConfidence) or 0))
  addProofField('axisTrustOrder=', tostring(context.axisTrustOrder or ''))
  addProofField('capabilityTierRank=', tostring(context.capabilityTierRank or 0))
  addProofField('corneringGSourceRank=', tostring(context.corneringGSourceRank or 0))
  addProofField('brakeGSourceRank=', tostring(context.brakeGSourceRank or 0))
  addProofField('realLifePriorSource=', tostring(context.realLifePriorSource or 'none'))
  addProofField('realLifePriorConfidence=', string.format('%.2f', tonumber(context.realLifePriorConfidence) or 0))
  addProofField('localKnowledgePriorSource=', tostring(context.localKnowledgePriorSource or 'none'))
  addProofField('localKnowledgePriorConfidence=', string.format('%.2f', tonumber(context.localKnowledgePriorConfidence) or 0))
  addProofField('localKnowledgePriorSamples=', tostring(math.floor((tonumber(context.localKnowledgePriorSamples) or 0) + 0.5)))
  addProofField('knowledgeBaseEnabled=', tostring(context.knowledgeBaseEnabled == true))
  addProofField('knowledgeBaseStatus=', tostring(context.knowledgeBaseStatus or 'unknown'))
  addProofField('knowledgeBaseLastError=', tostring(context.knowledgeBaseLastError or 'none'))
  addProofField('knowledgeBaseCarCount=', tostring(context.knowledgeBaseCarCount or 0))
  addProofField('knowledgeBaseSetupCount=', tostring(context.knowledgeBaseSetupCount or 0))
  addProofField('knowledgeBaseTrackCount=', tostring(context.knowledgeBaseTrackCount or 0))
  addProofField('knowledgeBaseCornerCount=', tostring(context.knowledgeBaseCornerCount or 0))
  addProofField('knowledgeBaseSetupRisk=', string.format('%.3f', tonumber(context.knowledgeBaseSetupRisk) or 0))
  addProofField('knowledgeBaseSetupConfidence=', string.format('%.2f', tonumber(context.knowledgeBaseSetupConfidence) or 0))
  addProofField('knowledgeBaseSetupSamples=', tostring(math.floor((tonumber(context.knowledgeBaseSetupSamples) or 0) + 0.5)))
  addProofField('knowledgeBaseTrackRisk=', string.format('%.3f', tonumber(context.knowledgeBaseTrackRisk) or 0))
  addProofField('knowledgeBaseTrackConfidence=', string.format('%.2f', tonumber(context.knowledgeBaseTrackConfidence) or 0))
  addProofField('knowledgeBaseTrackSamples=', tostring(math.floor((tonumber(context.knowledgeBaseTrackSamples) or 0) + 0.5)))
  addProofField('physicsCapabilitySource=', tostring(context.physicsCapabilitySource or 'none'))
  addProofField('physicsDataStatus=', tostring(context.physicsDataStatus or 'none'))
  addProofField('tyreDataStatus=', tostring(context.tyreDataStatus or 'none'))
  addProofField('physicsAeroDataStatus=', tostring(context.physicsAeroDataStatus or 'none'))
  addProofField('physicsCapabilityConfidence=', string.format('%.2f', tonumber(context.physicsCapabilityConfidence) or 0))
  addProofField('physicsCorneringCapabilityAvailable=', tostring(context.physicsCorneringCapabilityAvailable == true))
  addProofField('physicsBrakeCapabilityAvailable=', tostring(context.physicsBrakeCapabilityAvailable == true))
  addProofField('physicsAeroCapabilityAvailable=', tostring(context.physicsAeroCapabilityAvailable == true))
  addProofField('physicsMassKg=', string.format('%.1f', tonumber(context.physicsMassKg) or 0))
  addProofField('physicsWheelbaseM=', string.format('%.2f', tonumber(context.physicsWheelbaseM) or 0))
  addProofField('physicsCgLocation=', string.format('%.2f', tonumber(context.physicsCgLocation) or 0))
  addProofField('physicsFrontTrackM=', string.format('%.2f', tonumber(context.physicsFrontTrackM) or 0))
  addProofField('physicsRearTrackM=', string.format('%.2f', tonumber(context.physicsRearTrackM) or 0))
  addProofField('physicsTyreLateralMu=', string.format('%.2f', tonumber(context.physicsTyreLateralMu) or 0))
  addProofField('physicsTyreLongitudinalMu=', string.format('%.2f', tonumber(context.physicsTyreLongitudinalMu) or 0))
  addProofField('physicsTyreFrontLateralMu=', string.format('%.2f', tonumber(context.physicsTyreFrontLateralMu) or 0))
  addProofField('physicsTyreRearLateralMu=', string.format('%.2f', tonumber(context.physicsTyreRearLateralMu) or 0))
  addProofField('physicsTyreFrontLongitudinalMu=', string.format('%.2f', tonumber(context.physicsTyreFrontLongitudinalMu) or 0))
  addProofField('physicsTyreRearLongitudinalMu=', string.format('%.2f', tonumber(context.physicsTyreRearLongitudinalMu) or 0))
  addProofField('physicsTyreLoadRefN=', string.format('%.0f', tonumber(context.physicsTyreLoadRefN) or 0))
  addProofField('physicsTyreFrontLoadRefN=', string.format('%.0f', tonumber(context.physicsTyreFrontLoadRefN) or 0))
  addProofField('physicsTyreRearLoadRefN=', string.format('%.0f', tonumber(context.physicsTyreRearLoadRefN) or 0))
  addProofField('physicsTyreLoadSensitivityLat=', string.format('%.2f', tonumber(context.physicsTyreLoadSensitivityLat) or 0))
  addProofField('physicsTyreLoadSensitivityLong=', string.format('%.2f', tonumber(context.physicsTyreLoadSensitivityLong) or 0))
  addProofField('physicsTyreFrontLoadSensitivityLat=', string.format('%.2f', tonumber(context.physicsTyreFrontLoadSensitivityLat) or 0))
  addProofField('physicsTyreRearLoadSensitivityLat=', string.format('%.2f', tonumber(context.physicsTyreRearLoadSensitivityLat) or 0))
  addProofField('physicsTyreFrontLoadSensitivityLong=', string.format('%.2f', tonumber(context.physicsTyreFrontLoadSensitivityLong) or 0))
  addProofField('physicsTyreRearLoadSensitivityLong=', string.format('%.2f', tonumber(context.physicsTyreRearLoadSensitivityLong) or 0))
  addProofField('physicsTyrePressureStaticPsi=', string.format('%.1f', tonumber(context.physicsTyrePressureStaticPsi) or 0))
  addProofField('physicsTyrePressureIdealPsi=', string.format('%.1f', tonumber(context.physicsTyrePressureIdealPsi) or 0))
  addProofField('physicsTyreFrontPressureStaticPsi=', string.format('%.1f', tonumber(context.physicsTyreFrontPressureStaticPsi) or 0))
  addProofField('physicsTyreRearPressureStaticPsi=', string.format('%.1f', tonumber(context.physicsTyreRearPressureStaticPsi) or 0))
  addProofField('physicsTyreFrontPressureIdealPsi=', string.format('%.1f', tonumber(context.physicsTyreFrontPressureIdealPsi) or 0))
  addProofField('physicsTyreRearPressureIdealPsi=', string.format('%.1f', tonumber(context.physicsTyreRearPressureIdealPsi) or 0))
  addProofField('physicsTyreFalloffLevel=', string.format('%.2f', tonumber(context.physicsTyreFalloffLevel) or 0))
  addProofField('physicsTyreFrontFalloffLevel=', string.format('%.2f', tonumber(context.physicsTyreFrontFalloffLevel) or 0))
  addProofField('physicsTyreRearFalloffLevel=', string.format('%.2f', tonumber(context.physicsTyreRearFalloffLevel) or 0))
  addProofField('physicsTyreFalloffSpeed=', string.format('%.1f', tonumber(context.physicsTyreFalloffSpeed) or 0))
  addProofField('physicsTyreFrontFalloffSpeed=', string.format('%.1f', tonumber(context.physicsTyreFrontFalloffSpeed) or 0))
  addProofField('physicsTyreRearFalloffSpeed=', string.format('%.1f', tonumber(context.physicsTyreRearFalloffSpeed) or 0))
  addProofField('physicsTyreCombinedFactor=', string.format('%.2f', tonumber(context.physicsTyreCombinedFactor) or 0))
  addProofField('physicsTyreFrontCombinedFactor=', string.format('%.2f', tonumber(context.physicsTyreFrontCombinedFactor) or 0))
  addProofField('physicsTyreRearCombinedFactor=', string.format('%.2f', tonumber(context.physicsTyreRearCombinedFactor) or 0))
  addProofField('physicsTyreFrictionLimitAngleDeg=', string.format('%.1f', tonumber(context.physicsTyreFrictionLimitAngleDeg) or 0))
  addProofField('physicsTyreFrontFrictionLimitAngleDeg=', string.format('%.1f', tonumber(context.physicsTyreFrontFrictionLimitAngleDeg) or 0))
  addProofField('physicsTyreRearFrictionLimitAngleDeg=', string.format('%.1f', tonumber(context.physicsTyreRearFrictionLimitAngleDeg) or 0))
  addProofField('physicsTyreBrakeDxMod=', string.format('%.2f', tonumber(context.physicsTyreBrakeDxMod) or 0))
  addProofField('physicsTyreFrontBrakeDxMod=', string.format('%.2f', tonumber(context.physicsTyreFrontBrakeDxMod) or 0))
  addProofField('physicsTyreRearBrakeDxMod=', string.format('%.2f', tonumber(context.physicsTyreRearBrakeDxMod) or 0))
  addProofField('physicsTyreLoadSensitivityFactor=', string.format('%.3f', tonumber(context.physicsTyreLoadSensitivityFactor) or 1))
  addProofField('physicsTyreBrakeLoadSensitivityFactor=', string.format('%.3f', tonumber(context.physicsTyreBrakeLoadSensitivityFactor) or 1))
  addProofField('physicsTyreLoadSensitivityPenalty=', string.format('%.3f', tonumber(context.physicsTyreLoadSensitivityPenalty) or 0))
  addProofField('physicsTyreLoadSensitivityLoadRatio=', string.format('%.3f', tonumber(context.physicsTyreLoadSensitivityLoadRatio) or 0))
  addProofField('physicsTyreLoadSensitivityFrontShare=', string.format('%.3f', tonumber(context.physicsTyreLoadSensitivityFrontShare) or 0))
  addProofField('physicsTyreBrakeLoadSensitivityFrontShare=', string.format('%.3f', tonumber(context.physicsTyreBrakeLoadSensitivityFrontShare) or 0))
  addProofField('physicsTyreRadiusM=', string.format('%.2f', tonumber(context.physicsTyreRadiusM) or 0))
  addProofField('physicsTyreLateralCount=', tostring(context.physicsTyreLateralCount or 0))
  addProofField('physicsTyreLongitudinalCount=', tostring(context.physicsTyreLongitudinalCount or 0))
  addProofField('physicsBrakeTorqueNm=', string.format('%.1f', tonumber(context.physicsBrakeTorqueNm) or 0))
  addProofField('physicsBrakeFrontShare=', string.format('%.2f', tonumber(context.physicsBrakeFrontShare) or 0))
  addProofField('physicsBrakeDataStatus=', tostring(context.physicsBrakeDataStatus or 'unknown'))
  addProofField('physicsAeroWingCount=', tostring(context.physicsAeroWingCount or 0))
  addProofField('physicsAeroScore=', string.format('%.2f', tonumber(context.physicsAeroScore) or 0))
  addProofField('capabilityClass=', tostring(context.capabilityClass or ''))
  addProofField('nominalCapabilityClass=', tostring(context.nominalCapabilityClass or context.capabilityClass or ''))
  addProofField('dynamicCapabilityClass=', tostring(context.dynamicCapabilityClass or context.capabilityClass or ''))
  addProofField('nominalTransferClassScale=', string.format('%.3f', tonumber(context.nominalTransferClassScale) or 0))
  addProofField('transferClassScale=', string.format('%.3f', tonumber(context.transferClassScale) or 0))
  addProofField('cueTransferClassScale=', string.format('%.3f', tonumber(context.cueTransferClassScale) or 0))
  addProofField('momentTransferClassScale=', string.format('%.3f', tonumber(context.momentTransferClassScale) or 0))
  addProofField('brakeTransferScale=', string.format('%.3f', tonumber(context.brakeTransferScale) or 0))
  addProofField('aeroTransferScale=', string.format('%.3f', tonumber(context.aeroTransferScale) or 0))
  addProofField('carMassKg=', string.format('%.1f', tonumber(context.carMassKg) or 0))
  addProofField('carMassSource=', tostring(context.carMassSource or 'none'))
  addProofField('baseCorneringG=', string.format('%.2f', tonumber(context.baseCorneringG) or 0))
  addProofField('baseBrakeG=', string.format('%.2f', tonumber(context.baseBrakeG) or 0))
  addProofField('corneringG=', string.format('%.2f', tonumber(context.corneringG) or 0))
  addProofField('effectiveCorneringG=', string.format('%.2f', tonumber(context.corneringG) or 0))
  addProofField('corneringGNoSpeedAero=', string.format('%.2f', tonumber(context.corneringGNoSpeedAero) or 0))
  addProofField('speedAeroFactor=', string.format('%.3f', tonumber(context.speedAeroFactor) or 1))
  addProofField('speedAeroNominalStrength=', string.format('%.3f', tonumber(context.speedAeroNominalStrength) or 0))
  addProofField('speedAeroStrength=', string.format('%.3f', tonumber(context.speedAeroStrength) or 0))
  addProofField('speedAeroSource=', tostring(context.speedAeroSource or 'unknown'))
  addProofField('speedAeroSourceRank=', tostring(context.speedAeroSourceRank or 0))
  addProofField('brakeSpeedAeroStrength=', string.format('%.3f', tonumber(context.brakeSpeedAeroStrength) or 0))
  addProofField('brakeSpeedAeroFactor=', string.format('%.3f', tonumber(context.brakeSpeedAeroFactor) or 1))
  addProofField('aeroConfidence=', string.format('%.3f', tonumber(context.aeroConfidence) or 0))
  addProofField('aeroConfidenceSource=', tostring(context.aeroConfidenceSource or 'unknown'))
  addProofField('aeroHighSpeedCornerSamples=', tostring(context.aeroHighSpeedCornerSamples or 0))
  addProofField('aeroHighSpeedLimitSamples=', tostring(context.aeroHighSpeedLimitSamples or 0))
  addProofField('aeroObservedCorneringG=', string.format('%.2f', tonumber(context.aeroObservedCorneringG) or 0))
  addProofField('observedSpeedAeroStrength=', string.format('%.3f', tonumber(context.observedSpeedAeroStrength) or 0))
  addProofField('learnedSpeedAeroStrength=', string.format('%.3f', tonumber(context.learnedSpeedAeroStrength) or 0))
  addProofField('setupAeroFactor=', string.format('%.3f', tonumber(context.setupAeroFactor) or 0))
  addProofField('brakeG=', string.format('%.2f', tonumber(context.brakeG) or 0))
  addProofField('effectiveBrakeG=', string.format('%.2f', tonumber(context.brakeG) or 0))
  addProofField('observedBrakeG=', string.format('%.2f', tonumber(context.observedBrakeG) or 0))
  addProofField('observedCorneringG=', string.format('%.2f', tonumber(context.observedCorneringG) or 0))
  addProofField('learnedBrakeG=', string.format('%.2f', tonumber(context.learnedBrakeG) or 0))
  addProofField('learnedCorneringG=', string.format('%.2f', tonumber(context.learnedCorneringG) or 0))
  addProofField('learnedCorneringGNoSpeedAero=', string.format('%.2f', tonumber(context.learnedCorneringGNoSpeedAero) or 0))
  addProofField('telemetryBrakeSamples=', tostring(context.telemetryBrakeSamples or 0))
  addProofField('telemetryCornerSamples=', tostring(context.telemetryCornerSamples or 0))
  addProofField('telemetryBrakeSampleConfidence=', string.format('%.3f', tonumber(context.telemetryBrakeSampleConfidence) or 0))
  addProofField('telemetryCornerSampleConfidence=', string.format('%.3f', tonumber(context.telemetryCornerSampleConfidence) or 0))
  addProofField('strongBrakeSamples=', tostring(context.strongBrakeSamples or 0))
  addProofField('strongCornerSamples=', tostring(context.strongCornerSamples or 0))
  addProofField('cornerCapabilitySamples=', tostring(context.cornerCapabilitySamples or 0))
  addProofField('brakeLimitSampleThisFrame=', tostring(context.brakeLimitSampleThisFrame == true))
  addProofField('cornerLimitSampleThisFrame=', tostring(context.cornerLimitSampleThisFrame == true))
  addProofField('brakeLimitState=', tostring(context.brakeLimitState or 'not_braking'))
  addProofField('brakeSlipRatio=', string.format('%.3f', tonumber(context.brakeSlipRatio) or 0))
  addProofField('frontBrakeSlipRatio=', string.format('%.3f', tonumber(context.frontBrakeSlipRatio) or 0))
  addProofField('rearBrakeSlipRatio=', string.format('%.3f', tonumber(context.rearBrakeSlipRatio) or 0))
  addProofField('brakeLockupAxle=', tostring(context.brakeLockupAxle or 'none'))
  addProofField('brakeCapabilitySamples=', tostring(context.brakeCapabilitySamples or 0))
  addProofField('brakeLearningRejectReason=', tostring(context.brakeLearningRejectReason or 'unknown'))
  addProofField('cleanStrongBrakeSamples=', tostring(context.cleanStrongBrakeSamples or 0))
  addProofField('absInterventionBrakeSamples=', tostring(context.absInterventionBrakeSamples or 0))
  addProofField('lockupRiskBrakeSamples=', tostring(context.lockupRiskBrakeSamples or 0))
  addProofField('telemetrySampleAccepted=', tostring(context.telemetrySampleAccepted == true))
  addProofField('telemetryRejectReason=', tostring(context.telemetryRejectReason or 'unknown'))
  addProofField('telemetryTrafficBlocked=', tostring(context.telemetryTrafficBlocked == true))
  addProofField('confidence=', string.format('%.2f', tonumber(context.confidence) or 0))
  addProofField('lineOffsetScale=', string.format('%.2f', tonumber(lineOffsetScale) or 1))
  addProofField('maxLineOffsetM=', string.format('%.2f', maxLineOffset))
  addProofField('maxLineOffsetStepM=', string.format('%.3f', maxLineOffsetStepM))
  addProofField('maxLineOffsetAccelM=', string.format('%.3f', maxLineOffsetAccelM))
  addProofField('maxLineOffsetJerkM=', string.format('%.3f', maxLineOffsetJerkM))
  addProofField('maxStaticLineOffsetM=', string.format('%.2f', maxStaticLineOffset))
  addProofField('racingLineActive=', tostring(racingLineActive == true))
  addProofField('racingLineFallbackReason=', tostring(racingLineFallbackReason or ''))
  addProofField('linePlacementMode=', tostring(linePlacementMode or ''))
  addProofField('tileCount=', tostring(#(tiles or {})))
  addProofField('speedCapCount=', tostring(speedCapCount))
  addProofField('brakeProfileEnvelopeCount=', tostring(brakeProfileEnvelopeCount))
  addProofField('maxBrakeProfileReductionKph=', string.format('%.1f', maxBrakeProfileReductionKph))
  addProofField('firstKind=', tostring(firstKind))
  addProofField('greenCount=', tostring(greenCount))
  addProofField('yellowCount=', tostring(yellowCount))
  addProofField('redCount=', tostring(redCount))
  addProofField('minTargetSpeedKph=', tostring(math.floor(minTarget + 0.5)))
  addProofField('maxTargetSpeedKph=', tostring(math.floor(maxTarget + 0.5)))
  addProofField('maxRequiredDecelRatio=', string.format('%.3f', maxRatio))
  addProofField('maxCueSeverity=', string.format('%.3f', maxCueSeverity))
  addProofField('isolatedRedCount=', tostring(isolatedRedCount))
  addProofField('redClusterCount=', tostring(redClusterCount))
  addProofField('maxRedClusterTiles=', tostring(maxRedClusterTiles))
  addProofField('persistentRedCount=', tostring(persistentRedCount))
  addProofField('staleRedReleaseCount=', tostring(staleRedReleaseCount))
  addProofField('maxRedFrames=', tostring(maxRedFrames))
  addProofField('sequenceAdvisoryCount=', tostring(sequenceAdvisoryCount))
  addProofField('maxSequenceAdvisoryRatio=', string.format('%.3f', maxSequenceAdvisoryRatio))
  addProofField('sequenceDemand=', string.format('%.3f', maxSequenceAdvisoryRatio))
  addProofField('instabilityAdvisoryCount=', tostring(instabilityAdvisoryCount))
  addProofField('maxInstabilityAdvisoryRatio=', string.format('%.3f', maxInstabilityAdvisoryRatio))
  addProofField('spinGuardEnabled=', tostring(settings.SPIN_GUARD_ENABLED == true))
  addProofField('knowledgeBaseAdvisoryCount=', tostring(knowledgeBaseAdvisoryCount))
  addProofField('maxKnowledgeBaseAdvisoryRatio=', string.format('%.3f', maxKnowledgeBaseAdvisoryRatio))
  addProofField('maxKnowledgeBaseRisk=', string.format('%.3f', maxKnowledgeBaseRisk))
  addProofField('minKnowledgeBaseTargetScale=', string.format('%.3f', minKnowledgeBaseTargetScale))
  addProofField('firstBrakeCueDistanceAheadM=', string.format('%.1f', firstBrakeCueDistanceAheadM))
  addProofField('firstBrakeCueKind=', tostring(firstBrakeCueKind))
  addProofField('firstBrakeCueReason=', tostring(firstBrakeCueReason))
  addProofField('cueCause=', tostring(firstBrakeCueReason))
  addProofField('firstBrakeCueTargetDistanceM=', string.format('%.1f', firstBrakeCueTargetDistanceM))
  addProofField('targetPointAheadM=', string.format('%.1f', firstBrakeCueTargetPointAheadM))
  addProofField('firstBrakeCueTargetSampleDistanceM=', string.format('%.1f', firstBrakeCueTargetSampleDistanceM))
  addProofField('firstBrakeCueAvailableDistanceM=', string.format('%.1f', firstBrakeCueAvailableDistanceM))
  addProofField('firstBrakeCueEntryLeadM=', string.format('%.1f', firstBrakeCueEntryLeadM))
  addProofField('firstBrakeCueRequiredBrakeDistanceM=', string.format('%.1f', firstBrakeCueRequiredBrakeDistanceM))
  addProofField('requiredBrakeDistanceM=', string.format('%.1f', firstBrakeCueRequiredBrakeDistanceM))
  addProofField('firstBrakeCueZoneStartDistanceM=', string.format('%.1f', firstBrakeCueZoneStartDistanceM))
  addProofField('firstBrakeCueZoneWarningStartDistanceM=', string.format('%.1f', firstBrakeCueZoneWarningStartDistanceM))
  addProofField('brakeZoneStartAheadM=', string.format('%.1f', firstBrakeCueZoneStartDistanceM))
  addProofField('brakeZoneWarningAheadM=', string.format('%.1f', firstBrakeCueZoneWarningStartDistanceM))
  addProofField('firstBrakeCueClusterConfirmedSamples=', tostring(firstBrakeCueClusterConfirmedSamples))
  addProofField('firstBrakeCueSparseTerminalTarget=', tostring(firstBrakeCueSparseTerminalTarget == true))
  addProofField('firstBrakeCueSparseTerminalCurvatureOk=', tostring(firstBrakeCueSparseTerminalCurvatureOk == true))
  addProofField('firstBrakeCueTransferClassScale=', string.format('%.3f', firstBrakeCueTransferClassScale))
  addProofField('firstBrakeCueCornerBrakeBiasM=', string.format('%.1f', firstBrakeCueCornerBrakeBiasM))
  addProofField('appliedCornerBrakeBiasM=', string.format('%.1f', firstBrakeCueCornerBrakeBiasM))
  addProofField('firstBrakeCueDynamicConfidence=', string.format('%.2f', firstBrakeCueDynamicConfidence))
  addProofField('firstBrakeCueConfidenceUncertaintyScale=', string.format('%.3f', firstBrakeCueConfidenceUncertaintyScale))
  addProofField('firstBrakeCueConfidenceMarginM=', string.format('%.1f', firstBrakeCueConfidenceMarginM))
  addProofField('brakeConfidenceMarginM=', string.format('%.1f', firstBrakeCueConfidenceMarginM))
  addProofField('firstBrakeCueLeadErrorEstimateM=', string.format('%.1f', firstBrakeCueLeadErrorEstimateM))
  addProofField('cueLeadErrorEstimateM=', string.format('%.1f', firstBrakeCueLeadErrorEstimateM))
  addProofField('version=', tostring(settings.VERSION or ''))
  addProofField('buildId=', tostring(settings.BUILD_ID or ''))
  addProofField('runNonce=', tostring(M.runNonce or ''))
  addProofField('carId=', tostring(M.activeCarId or ''))
  addProofField('trackId=', tostring(M.activeTrackId or ''))
  addProofField('trackLayout=', tostring(M.activeTrackLayout or ''))
  logger.write(table.concat(proofParts, ''))
end

isBrakeCueReason = function(reason)
  reason = tostring(reason or 'unknown')
  return reason == 'brake_zone_warning' or
    reason == 'brake_zone_active' or
    reason == 'direct_target_brake' or
    reason == 'brake_now' or
    reason == 'brake_now_hysteresis' or
    reason == 'prepare_or_lift' or
    reason == 'prepare_or_lift_hysteresis' or
    reason == 'knowledge_base_advisory' or
    reason == 'release_from_red'
end

classifyBrakeCueTiming = function(kind, leadErrorM, entryLeadM)
  kind = tostring(kind or 'none')
  if kind == 'none' then return 'no_brake_cue', 0.0 end
  local toleranceM = math.max(1.5, math.min(6.0, (tonumber(entryLeadM) or 0.0) * 0.25))
  local leadError = tonumber(leadErrorM) or 0.0
  if kind == 'red' then
    if leadError > toleranceM then return 'early_red', toleranceM end
    if leadError < -toleranceM then return 'late_red', toleranceM end
    return 'on_time_red', toleranceM
  end
  if leadError > toleranceM then return 'early_warning', toleranceM end
  if leadError < -toleranceM then return 'late_warning', toleranceM end
  return 'on_time_warning', toleranceM
end

local function exitTargetSpeedForLearning(tiles, targetSampleDistanceM, fallbackSpeedKph)
  local fallback = math.max(0.0, tonumber(fallbackSpeedKph) or 0.0)
  local startM = math.max(0.0, tonumber(targetSampleDistanceM) or 0.0)
  local lookaheadM = math.max(0.0,
    tonumber(settings.CORNER_LEARNING_EXIT_TARGET_LOOKAHEAD_M) or tonumber(settings.RACING_LINE_EXIT_M) or 45.0)
  local endM = startM + lookaheadM
  local best = fallback
  for _, tile in ipairs(tiles or {}) do
    local distanceAheadM = tonumber(tile and tile.distanceAheadM) or -1.0
    if distanceAheadM >= startM and distanceAheadM <= endM then
      local targetSpeedKph = tonumber(tile and tile.targetSpeedKph) or 0.0
      if targetSpeedKph > best then best = targetSpeedKph end
    end
  end
  return best
end

local function firstBrakeCueForLearning(tiles)
  for _, tile in ipairs(tiles or {}) do
    local cueReason = tostring(tile and tile.cueReason or 'unknown')
    if tile and (tile.kind == 'yellow' or tile.kind == 'red') and isBrakeCueReason(cueReason) then
      local distanceAheadM = tonumber(tile.distanceAheadM) or 0.0
      local zoneStartDistanceM = tonumber(tile.brakeZoneStartDistanceM) or 0.0
      local zoneWarningStartDistanceM = tonumber(tile.brakeZoneWarningStartDistanceM) or 0.0
      local kind = tostring(tile.kind)
      local leadErrorM = kind == 'red' and (distanceAheadM - zoneStartDistanceM) or
        (distanceAheadM - zoneWarningStartDistanceM)
      local entryLeadM = tonumber(tile.brakeTargetEntryLeadM) or 0.0
      local timingState, timingToleranceM = classifyBrakeCueTiming(kind, leadErrorM, entryLeadM)
      local targetSpeedKph = tonumber(tile.brakeTargetSpeedKph or tile.targetSpeedKph) or 0.0
      local targetSampleDistanceM = tonumber(tile.brakeTargetSampleDistanceM) or 0.0
      return {
        kind = kind,
        reason = cueReason,
        cornerId = tile.cornerId,
        segmentType = tile.segmentType,
        guidanceSource = tile.guidanceSource,
        guidanceConfidence = tile.guidanceConfidence,
        timingState = timingState,
        timingToleranceM = timingToleranceM,
        distanceAheadM = distanceAheadM,
        targetSpeedKph = targetSpeedKph,
        exitTargetSpeedKph = exitTargetSpeedForLearning(tiles, targetSampleDistanceM, targetSpeedKph),
        targetSampleDistanceM = targetSampleDistanceM,
        zoneStartDistanceM = zoneStartDistanceM,
      }
    end
  end
  return nil
end

local function updateTurnInTraceSample(trace, speed, cueZoneStartDistanceM)
  trace = trace or {}
  speed = math.max(0.0, tonumber(speed) or 0.0)
  cueZoneStartDistanceM = math.max(0.0, tonumber(cueZoneStartDistanceM) or 0.0)
  if trace.turnInCaptureState == 'entry_captured' then return trace end

  trace.turnInSpeedKph = math.min(tonumber(trace.turnInSpeedKph) or speed, speed)
  trace.turnInCaptureState = 'approach_pending'
  trace.turnInSampleZoneStartDistanceM = cueZoneStartDistanceM

  local captureZoneM = math.max(0.0, tonumber(settings.CORNER_LEARNING_TURN_IN_SAMPLE_ZONE_M) or 10.0)
  if cueZoneStartDistanceM <= captureZoneM then
    trace.turnInSpeedKph = speed
    trace.turnInCaptureState = 'entry_captured'
    trace.turnInSampleZoneStartDistanceM = cueZoneStartDistanceM
  end
  return trace
end

local function updateBrakeOnsetTraceSample(trace, brakeInput, speed, cueZoneStartDistanceM)
  trace = trace or {}
  if trace.actualBrakeOnsetState == 'captured' then return trace end

  brakeInput = math3d.clamp(tonumber(brakeInput) or 0.0, 0.0, 1.0)
  speed = math.max(0.0, tonumber(speed) or 0.0)
  cueZoneStartDistanceM = tonumber(cueZoneStartDistanceM) or 0.0
  trace.actualBrakeOnsetState = 'pending'
  trace.actualBrakeOnsetZoneStartDistanceM = tonumber(trace.actualBrakeOnsetZoneStartDistanceM) or 0.0
  trace.actualBrakeOnsetInput = tonumber(trace.actualBrakeOnsetInput) or 0.0
  trace.actualBrakeOnsetSpeedKph = tonumber(trace.actualBrakeOnsetSpeedKph) or 0.0

  local threshold = math.max(0.0, tonumber(settings.BRAKE_RESPONSE_INPUT_THRESHOLD) or 0.20)
  if brakeInput >= threshold then
    local maxCueDistanceM = math.max(0.0, tonumber(settings.CORNER_LEARNING_MAX_CUE_DISTANCE_M) or 42.0)
    if cueZoneStartDistanceM > maxCueDistanceM then
      trace.actualBrakeOnsetState = 'pending_far'
      trace.actualBrakeOnsetZoneStartDistanceM = cueZoneStartDistanceM
      trace.actualBrakeOnsetInput = brakeInput
      trace.actualBrakeOnsetSpeedKph = speed
      return trace
    end
    trace.actualBrakeOnsetState = 'captured'
    trace.actualBrakeOnsetZoneStartDistanceM = cueZoneStartDistanceM
    trace.actualBrakeOnsetInput = brakeInput
    trace.actualBrakeOnsetSpeedKph = speed
  end
  return trace
end

local function updateCornerLearningTrace(car, cue, currentSpeedKph, momentKey)
  local seed = corner_learning.biasFor(car, {
    trackId = M.activeTrackId,
    trackLayout = M.activeTrackLayout,
    progress = car and car.splinePosition,
    targetSampleDistanceM = cue and cue.targetSampleDistanceM,
    cornerLearningMomentKey = momentKey,
  })
  local key = tostring(seed.cornerLearningKey or '')
  local speed = tonumber(currentSpeedKph) or 0.0
  local trace = M.cornerLearningTrace
  if not trace or trace.cornerLearningKey ~= key then
    trace = {
      cornerLearningKey = key,
      turnInSpeedKph = speed,
      turnInCaptureState = 'approach_pending',
      turnInSampleZoneStartDistanceM = 0.0,
      actualBrakeOnsetState = 'pending',
      actualBrakeOnsetZoneStartDistanceM = 0.0,
      actualBrakeOnsetInput = 0.0,
      actualBrakeOnsetSpeedKph = 0.0,
      apexSpeedKph = 0.0,
      apexCaptureState = 'pending',
      exitSpeedKph = 0.0,
      exitCaptureState = 'pending',
      exitTargetSpeedKph = tonumber(cue and cue.exitTargetSpeedKph) or tonumber(cue and cue.targetSpeedKph) or 0.0,
      samples = 0,
    }
  end
  trace.exitTargetSpeedKph = math.max(
    tonumber(trace.exitTargetSpeedKph) or 0.0,
    tonumber(cue and cue.exitTargetSpeedKph) or tonumber(cue and cue.targetSpeedKph) or 0.0)
  trace.samples = (tonumber(trace.samples) or 0) + 1
  local cueZoneStartDistanceM = tonumber(cue and cue.zoneStartDistanceM) or 0.0
  trace.traceMinZoneStartDistanceM = math.min(
    tonumber(trace.traceMinZoneStartDistanceM) or cueZoneStartDistanceM,
    cueZoneStartDistanceM)
  trace.traceMaxZoneStartDistanceM = math.max(
    tonumber(trace.traceMaxZoneStartDistanceM) or cueZoneStartDistanceM,
    cueZoneStartDistanceM)
  trace.zoneStartDistanceM = cueZoneStartDistanceM
  updateTurnInTraceSample(trace, speed, cueZoneStartDistanceM)
  if trace.turnInCaptureState == 'entry_captured' then
    if trace.apexCaptureState ~= 'apex_captured' then
      trace.apexSpeedKph = speed
    else
      trace.apexSpeedKph = math.min(tonumber(trace.apexSpeedKph) or speed, speed)
    end
    trace.apexCaptureState = 'apex_captured'
    trace.exitSpeedKph = speed
    trace.exitCaptureState = 'exit_captured'
  end
  M.cornerLearningTrace = trace
  return trace
end

local function hasKnownInvalidTrackSurface(car)
  for _, wheel in ipairs(car and car.wheels or {}) do
    if wheel and wheel.surfaceValidTrackKnown == true and wheel.surfaceValidTrack ~= true then
      return true
    end
  end
  return false
end

local function cornerLearningSampleQuality(car, context, trace, historyOk, currentSpeedKph)
  local traceSamples = math.max(0, math.floor((tonumber(trace and trace.samples) or 0.0) + 0.5))
  local minTraceSamples = math.max(1, math.floor((tonumber(settings.CORNER_LEARNING_MIN_TRACE_SAMPLES) or 3) + 0.5))
  if traceSamples < minTraceSamples then return { accepted = false, reason = 'trace_warming' } end
  if historyOk ~= true then return { accepted = false, reason = 'missing_speed_history' } end
  local traceMinZoneStartDistanceM = math.max(0.0, tonumber(trace and trace.traceMinZoneStartDistanceM) or 9999.0)
  local maxCueDistanceM = math.max(0.0, tonumber(settings.CORNER_LEARNING_MAX_CUE_DISTANCE_M) or 42.0)
  local brakeOnsetCaptured = trace and trace.actualBrakeOnsetState == 'captured'
  if traceMinZoneStartDistanceM > maxCueDistanceM and brakeOnsetCaptured ~= true then
    return { accepted = false, reason = 'cue_too_far_for_learning' }
  end
  if hasKnownInvalidTrackSurface(car) then return { accepted = false, reason = 'surface_valid_track_false' } end
  local traffic = trafficLearningBlock(car)
  if traffic.blocked == true then return { accepted = false, reason = 'traffic_ahead' } end

  local slipStress = tonumber(context and context.slipStress) or 0.0
  local maxSlipStress = math.max(0.0, tonumber(settings.CORNER_LEARNING_MAX_SLIP_STRESS) or 0.75)
  if slipStress > maxSlipStress then return { accepted = false, reason = 'excessive_slip' } end

  local tyreDirty = tonumber(context and context.tyreDirty) or 0.0
  local maxTyreDirty = math.max(0.0, tonumber(settings.CORNER_LEARNING_MAX_TYRE_DIRTY) or 0.40)
  if tyreDirty > maxTyreDirty then return { accepted = false, reason = 'dirty_tyres' } end

  local speedKph = tonumber(currentSpeedKph) or 0.0
  local minSpeedKph = math.max(0.0, tonumber(settings.CORNER_LEARNING_MIN_SPEED_KPH) or 25.0)
  if speedKph < minSpeedKph then return { accepted = false, reason = 'below_min_speed' } end

  return { accepted = true, reason = 'accepted' }
end

local function updateCornerLearningFrame(tiles, car)
  local now = nowSeconds()
  local interval = math.max(0.05, tonumber(settings.CORNER_LEARNING_OBSERVE_INTERVAL_S) or 0.35)

  car = car or {}
  local context = M.lastDynamicContext or {}
  local momentKey = cornerLearningMomentKey(context)
  if now < (M.cornerLearningNextAt or 0) and
    M.lastCornerLearning and tostring(M.lastCornerLearning.cornerLearningMomentKey or '') == momentKey then
    return M.lastCornerLearning
  end
  M.cornerLearningNextAt = now + interval
  local currentBrakeInput = math3d.clamp(tonumber(car.brake) or 0.0, 0.0, 1.0)
  local currentSpeedKph = tonumber(car.speedKmh) or tonumber(context.currentSpeedKph) or 0.0
  local previousTelemetry = M.cornerLearningTelemetry or {}
  local telemetryDt = previousTelemetry.time and (now - previousTelemetry.time) or 0.0
  local historyOk = previousTelemetry.speedKph ~= nil and
    telemetryDt >= (tonumber(settings.BRAKE_RESPONSE_MIN_DT_S) or 0.05) and
    telemetryDt <= (tonumber(settings.BRAKE_RESPONSE_MAX_DT_S) or 1.0)
  local speedDropKph = historyOk and
    math.max(0.0, (tonumber(previousTelemetry.speedKph) or currentSpeedKph) - currentSpeedKph) or 0.0
  M.cornerLearningTelemetry = {
    time = now,
    speedKph = currentSpeedKph,
    brakeInput = currentBrakeInput,
  }

  local cue = firstBrakeCueForLearning(tiles)
  if not cue then
    M.lastCornerLearning = corner_learning.biasFor(car, {
      trackId = M.activeTrackId,
      trackLayout = M.activeTrackLayout,
      progress = car and car.splinePosition,
      cornerLearningMomentKey = momentKey,
    })
    return M.lastCornerLearning
  end

  local brakeInputThreshold = math.max(0.0, tonumber(settings.BRAKE_RESPONSE_INPUT_THRESHOLD) or 0.20)
  local speedDropThresholdKph = math.max(0.0, tonumber(settings.BRAKE_RESPONSE_SPEED_DROP_KPH) or 1.0)
  local brakeInputSeen = currentBrakeInput >= brakeInputThreshold
  local speedDropSeen = speedDropKph >= speedDropThresholdKph
  local cueZoneStartDistanceM = tonumber(cue and cue.zoneStartDistanceM) or 0.0
  local trace = updateCornerLearningTrace(car, cue, currentSpeedKph, momentKey)
  updateBrakeOnsetTraceSample(trace, currentBrakeInput, currentSpeedKph, cueZoneStartDistanceM)
  trace.brakeInputSeen = brakeInputSeen
  trace.speedDropSeen = speedDropSeen
  local responseState = 'pre_brake_monitoring'
  responseState = classifyBrakeResponseState(
    brakeInputSeen,
    speedDropSeen,
    historyOk,
    cue.kind,
    trace.turnInSpeedKph,
    trace.apexSpeedKph,
    trace.exitSpeedKph,
    cue.targetSpeedKph,
    trace.exitTargetSpeedKph,
    trace.turnInCaptureState,
    trace.apexCaptureState,
    trace.exitCaptureState)
  local sampleQuality = cornerLearningSampleQuality(car, context, trace, historyOk, currentSpeedKph)

  local actualBrakePointErrorM = trace.actualBrakeOnsetState == 'captured' and trace.actualBrakeOnsetZoneStartDistanceM or 0.0
  M.lastCornerLearning = corner_learning.observe(car, {
    trackId = M.activeTrackId,
    trackLayout = M.activeTrackLayout,
    progress = car and car.splinePosition,
    predictedBrakePointM = cue.zoneStartDistanceM,
    targetSampleDistanceM = cue.targetSampleDistanceM,
    cornerLearningMomentKey = momentKey,
    actualBrakeInput = currentBrakeInput,
    speedDropKph = speedDropKph,
    actualBrakePointErrorM = actualBrakePointErrorM,
    actualBrakeOnsetState = trace.actualBrakeOnsetState,
    actualBrakeOnsetZoneStartDistanceM = trace.actualBrakeOnsetZoneStartDistanceM,
    actualBrakeOnsetInput = trace.actualBrakeOnsetInput,
    actualBrakeOnsetSpeedKph = trace.actualBrakeOnsetSpeedKph,
    turnInSpeedKph = trace.turnInSpeedKph,
    turnInCaptureState = trace.turnInCaptureState,
    turnInSampleZoneStartDistanceM = trace.turnInSampleZoneStartDistanceM,
    targetSpeedKph = cue.targetSpeedKph,
    exitTargetSpeedKph = trace.exitTargetSpeedKph,
    apexSpeedKph = trace.apexSpeedKph,
    apexCaptureState = trace.apexCaptureState,
    exitSpeedKph = trace.exitSpeedKph,
    exitCaptureState = trace.exitCaptureState,
    traceSamples = trace.samples,
    traceMinZoneStartDistanceM = trace.traceMinZoneStartDistanceM,
    traceMaxZoneStartDistanceM = trace.traceMaxZoneStartDistanceM,
    sampleAccepted = sampleQuality.accepted,
    rejectionReason = sampleQuality.reason,
    cueTimingState = cue.timingState,
    responseState = responseState,
    brakeLimitState = context.brakeLimitState,
    brakeLockupAxle = context.brakeLockupAxle,
    brakeLearningRejectReason = context.brakeLearningRejectReason,
    frontTyreStress = context.frontTyreStress,
    rearTyreStress = context.rearTyreStress,
    slipStress = context.slipStress,
    rainIntensity = context.rainIntensity,
    rainWetness = context.rainWetness,
    rainWater = context.rainWater,
    tractionControlInAction = context.tractionControlInAction,
    instabilityRisk = math.max(tonumber(context.knowledgeBaseSetupRisk) or 0.0, tonumber(context.knowledgeBaseTrackRisk) or 0.0),
    adjustmentScale = settings.CORNER_LEARNING_FRAME_ADJUSTMENT_SCALE,
  })
  profile_store.observeCorner(M.guidanceSession, {
    cornerId = cue.cornerId or trace.cornerLearningKey,
    cornerLearningKey = trace.cornerLearningKey,
    segmentType = cue.segmentType,
    sampleAccepted = sampleQuality.accepted,
    responseState = responseState,
    cueTimingState = cue.timingState,
    speedOverTargetKph = math.max(0.0, currentSpeedKph - (tonumber(cue.targetSpeedKph) or currentSpeedKph)),
    actualBrakePointErrorM = actualBrakePointErrorM,
    brakeInput = currentBrakeInput,
    speedDropKph = speedDropKph,
    spinRisk = tonumber(context.slipStress) or 0.0,
    lockupRisk = tostring(context.brakeLimitState or '') == 'lockup' and 1.0 or 0.0,
    entryInstabilityRisk = math.max(tonumber(context.rearTyreStress) or 0.0, tonumber(context.knowledgeBaseSetupRisk) or 0.0),
    understeerRisk = tonumber(context.frontTyreStress) or 0.0,
    exitInstabilityRisk = tonumber(context.rearTyreStress) or 0.0,
    offtrackRisk = tostring(context.brakeLearningRejectReason or '') == 'offtrack' and 1.0 or 0.0,
  })
  return M.lastCornerLearning
end

local function syncProfileTileDimensions(profile)
  if not profile then return end
  profile.tileWidthM = M.tileWidthM
  profile.tileLengthM = M.tileLengthM
  if settings.PERFORMANCE_SAFE_MODE == true then
    profile.sampleTileDimensionKey = 'performance_safe_skip'
    return
  end

  local width = finiteNumber(M.tileWidthM, settings.TILE_WIDTH_M)
  local length = finiteNumber(M.tileLengthM, settings.TILE_LENGTH_M)
  local sampleTileDimensionKey = string.format('%.4f:%.4f', width, length)
  if profile.sampleTileDimensionKey == sampleTileDimensionKey then return end
  for _, sample in ipairs(profile.samples or {}) do
    sample.tileWidthM = width
    sample.tileLengthM = length
  end
  profile.sampleTileDimensionKey = sampleTileDimensionKey
end

local function carSplineDistanceM(car)
  if not M.profile or not M.profile.totalLengthM or M.profile.totalLengthM <= 0 then return nil end
  local progress = tonumber(car and car.splinePosition)
  if not progress then return nil end
  return (progress % 1.0) * M.profile.totalLengthM
end

local function wrappedDistanceDeltaM(currentS, previousS, totalLengthM)
  currentS = tonumber(currentS)
  previousS = tonumber(previousS)
  totalLengthM = tonumber(totalLengthM)
  if not currentS or not previousS or not totalLengthM or totalLengthM <= 0 then return math.huge end
  local delta = math.abs((currentS - previousS) % totalLengthM)
  if delta > totalLengthM * 0.5 then delta = totalLengthM - delta end
  return delta
end

local function guidanceBudgetKey(car, window)
  local speedBucket = math.floor(((tonumber(car and car.speedKmh) or 0.0) / 12.0) + 0.5)
  local splineBucket = math.floor(((tonumber(car and car.splinePosition) or 0.0) * 1000.0) + 0.5)
  local setupHash = M.guidanceSession and M.guidanceSession.setup_hash or M.activeSetupFingerprint or ''
  return tostring(window or 'window') .. ':' ..
    tostring(M.activeTrackId or '') .. ':' ..
    tostring(M.activeTrackLayout or '') .. ':' ..
    tostring(M.activeCarId or '') .. ':' ..
    tostring(setupHash) .. ':' ..
    tostring(speedBucket) .. ':' ..
    tostring(splineBucket)
end

local function lineCoreEnabled()
  if settings.LINE_CORE_R02_ENABLED ~= true then return false end
  if settings.RACING_LINE_ENABLED ~= true then return false end
  if not line_core_adapter or type(line_core_adapter.build) ~= 'function' then return false end
  if settings.PERFORMANCE_SAFE_MODE == true and settings.LINE_CORE_R02_ALLOW_PERFORMANCE_SAFE_MODE ~= true then return false end
  return true
end

local function lineCoreBudgetKey(car)
  local speedBucket = math.floor(((tonumber(car and car.speedKmh) or 0.0) / 30.0) + 0.5)
  local setupHash = M.guidanceSession and M.guidanceSession.setup_hash or M.activeSetupFingerprint or ''
  local sampleCount = M.profile and M.profile.samples and #M.profile.samples or 0
  local dynamic = M.lastDynamicContext or {}
  local gripBucket = math.floor((finiteNumber(dynamic.roadGrip, 1.0) * finiteNumber(dynamic.surfaceGrip, 1.0)) * 50.0 + 0.5)
  local rainBucket = math.floor(math.max(
    finiteNumber(dynamic.rainIntensity, 0.0),
    finiteNumber(dynamic.rainWetness, 0.0),
    finiteNumber(dynamic.rainWater, 0.0)) * 25.0 + 0.5)
  local dirtyBucket = math.floor(math.max(
    finiteNumber(dynamic.tyreDirty, 0.0),
    finiteNumber(dynamic.surfaceDirt, 0.0),
    finiteNumber(dynamic.dirtyLineRisk, 0.0)) * 20.0 + 0.5)
  local providerState = M.lineCoreDataProviderState or {}
  local providerBucket = tostring(math.floor((tonumber(providerState.confidence) or 0.0) * 20.0 + 0.5)) ..
    ':' .. tostring(providerState.surfaceMapKnown == true) ..
    ':' .. tostring(providerState.trackLimitsKnown == true)
  return tostring(M.activeTrackId or '') .. ':' ..
    tostring(M.activeTrackLayout or '') .. ':' ..
    tostring(M.activeCarId or '') .. ':' ..
    tostring(setupHash) .. ':' ..
    tostring(speedBucket) .. ':' ..
    tostring(sampleCount) .. ':' ..
    tostring(gripBucket) .. ':' ..
    tostring(rainBucket) .. ':' ..
    tostring(dirtyBucket) .. ':' ..
    providerBucket
end

local function lineCoreProgressM(car)
  local total = tonumber(M.profile and M.profile.totalLengthM) or 0.0
  if total <= 0.0 then return nil end
  return (tonumber(car and car.splinePosition) or 0.0) * total
end

local function lineCoreSamplesForProfile(profile)
  local out = {}
  for _, sample in ipairs(profile and profile.samples or {}) do
    local world = sample.centerPos or sample.centerlinePos or sample.pos or sample.world
    if world then
      out[#out + 1] = {
        progress = finiteNumber(sample.s, nil),
        world = world,
        leftWidth = sample.leftWidth or sample.trackLeft or sample.halfWidth,
        rightWidth = sample.rightWidth or sample.trackRight or sample.halfWidth,
        confidence = sample.widthConfidence or sample.dynamicConfidence or 0.55,
        source = 'track_sampler_centerline',
      }
    end
  end
  return out
end

local function nonEmptyTable(value)
  return type(value) == 'table' and next(value) ~= nil
end

local function firstNonEmptyTable(...)
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if nonEmptyTable(value) then return value end
  end
  return nil
end

local function lineCoreTrackProfile()
  return M.guidanceSession and M.guidanceSession.track_profile or {}
end

local function lineCoreTrackFileReference()
  return M.trackFileReference or M.guidanceSession and M.guidanceSession.track_file_reference or
    lineCoreTrackProfile().trackFileReference or {}
end

local function lineCoreTrackLimits()
  local track = lineCoreTrackProfile()
  return firstNonEmptyTable(
    track.trackLimits,
    track.track_limits,
    track.trackLimitSamples,
    track.track_limit_samples,
    track.widthSamples,
    track.boundaries,
    track.boundarySamples)
end

local function lineCoreSurfaceSamples()
  local track = lineCoreTrackProfile()
  local ref = lineCoreTrackFileReference()
  local surface = type(track.surface) == 'table' and track.surface or {}
  return firstNonEmptyTable(
    track.surfaceSamples,
    track.surface_samples,
    track.surfaceMap,
    track.surface_map,
    ref.surfaceSamples,
    surface.samples,
    surface.surfaceSamples)
end

local function lineCoreAiLineSamples()
  local session = M.guidanceSession or {}
  local track = lineCoreTrackProfile()
  local ref = lineCoreTrackFileReference()
  return firstNonEmptyTable(
    ref.fileAiLineSamples,
    ref.aiLineSamples,
    track.aiLineSamples,
    track.ai_line_samples,
    track.referenceLineSamples,
    track.reference_line_samples,
    session.base_line and session.base_line.points,
    session.generated_line and session.generated_line.points)
end

local function lineCoreDataProviderState()
  local track = lineCoreTrackProfile()
  local trackLimits = lineCoreTrackLimits()
  local surfaceSamples = lineCoreSurfaceSamples()
  local aiLineSamples = lineCoreAiLineSamples()
  local ref = lineCoreTrackFileReference()
  local surface = type(track.surface) == 'table' and track.surface or {}
  local trackLimitsKnown = nonEmptyTable(trackLimits) or track.valid_boundaries == true or surface.valid_boundaries == true
  local surfaceMapKnown = nonEmptyTable(surfaceSamples) or surface.grip_hint ~= nil
  local kerbMapKnown = nonEmptyTable(track.kerbSamples or track.kerb_samples)
  local wallMapKnown = nonEmptyTable(track.wallSamples or track.wall_samples)
  local knownCount = (trackLimitsKnown and 1 or 0) + (surfaceMapKnown and 1 or 0) +
    (kerbMapKnown and 1 or 0) + (wallMapKnown and 1 or 0)
  return {
    trackLimitsKnown = trackLimitsKnown,
    surfaceMapKnown = surfaceMapKnown,
    kerbMapKnown = kerbMapKnown,
    wallMapKnown = wallMapKnown,
    aiLineKnown = nonEmptyTable(aiLineSamples),
    trackFileReferenceKnown = ref.geometryOnly == true and nonEmptyTable(ref.aiLineSamples),
    surfaceHintsOnly = type(ref.surfaceHints) == 'table' and not surfaceMapKnown,
    confidence = knownCount / 4.0,
    unknownTrackLimits = trackLimitsKnown ~= true,
    unknownSurfaceMap = surfaceMapKnown ~= true,
  }
end

local function learningState()
  if settings.TELEMETRY_LEARNING_ENABLED ~= true and settings.CORNER_LEARNING_ENABLED ~= true then
    return 'disabled'
  end
  return 'enabled_evidence_gated'
end

local function guidanceCacheState(status, stale)
  status = tostring(status or 'unknown')
  if stale == true then return 'stale' end
  if status == 'cache_hit' or status == 'cached' then return 'hit' end
  if status == 'fresh' then return 'miss' end
  return status
end

local function lineCoreHealthState()
  local guidance = M.lineCoreGuidance or {}
  local diagnostics = guidance.diagnostics or {}
  local dataTruth = diagnostics.dataTruth or {}
  local reference = dataTruth.trackFileReference or {}
  local referenceHints = dataTruth.referenceBrakeSpeedHints or {}
  local brake = guidance.brake or {}
  local points = guidance.points or brake.points or {}
  local firstPoint = points and points[1] or {}
  local lineCoreStatus = M.lineCoreStatus or 'unknown'
  local lineCoreStale = M.lineCoreStale == true
  local fallbackReason = 'none'
  if M.fallbackLineActive == true then
    fallbackReason = 'fallback_line_active'
  elseif M.tileRecoveryActive == true then
    fallbackReason = 'tile_recovery_active'
  elseif M.spatialPlacementRejectedReason then
    fallbackReason = tostring(M.spatialPlacementRejectedReason)
  elseif guidance.reason then
    fallbackReason = tostring(guidance.reason)
  end
  return {
    lineCoreStatus = lineCoreStatus,
    lineCoreDataConfidence = M.lineCoreDataConfidence or 0.0,
    lineCoreStale = lineCoreStale,
    learningState = learningState(),
    rendererMode = tostring(renderer.lastLineRenderMode or renderer.renderSpaceMode or 'unknown'),
    targetSpeedSource = tostring(firstPoint.brakeSpeedFoundationSource or brake.brakeSpeedFoundationSource or
      referenceHints.source or guidance.reason or 'unknown'),
    splineSource = tostring(reference.aiLineSource or reference.source or referenceHints.source or
      dataTruth.sourceOrder or 'unknown'),
    fallbackReason = fallbackReason,
    frameBudgetStatus = lineCoreStatus,
    cacheState = guidanceCacheState(lineCoreStatus, lineCoreStale),
    rejectedLineReason = tostring(M.spatialPlacementRejectedReason or M.lineCoreLastError or 'none'),
  }
end

local function lineCoreSetupFromDynamic(dynamic)
  dynamic = dynamic or {}
  local setup = {}
  local snapshot = dynamic.setupSnapshot or dynamic.setup or {}
  if type(snapshot) == 'table' then
    for k, v in pairs(snapshot) do setup[k] = v end
  end
  setup.fuelKg = setup.fuelKg or setup.fuel or dynamic.fuelKg or dynamic.fuelLoadKg
  setup.brakePowerMult = setup.brakePowerMult or dynamic.brakePowerMult
  setup.brakePowerMultiplier = setup.brakePowerMultiplier or dynamic.brakePowerMult
  setup.brakePower = setup.brakePower or dynamic.brakePowerMult
  setup.brakeBias = setup.brakeBias or setup.frontBias or dynamic.brakeBias or dynamic.brakeBiasFront
  setup.aeroDependency = setup.aeroDependency or dynamic.brakeSpeedAeroStrength or dynamic.speedAeroStrength
  setup.brakeSpeedAeroStrength = setup.brakeSpeedAeroStrength or dynamic.brakeSpeedAeroStrength
  setup.absActive = setup.absActive or dynamic.absActive
  setup.tcActive = setup.tcActive or dynamic.tcActive
  setup.pressurePenalty = setup.pressurePenalty or dynamic.pressurePenalty
  setup.tyrePenalty = setup.tyrePenalty or dynamic.tyrePenalty
  setup.damagePenalty = setup.damagePenalty or dynamic.damagePenalty or dynamic.damage
  return setup
end

local function lineCoreBuildContext(car, key)
  local total = tonumber(M.profile and M.profile.totalLengthM) or 0.0
  local speedMps = math.max(0.0, (tonumber(car and car.speedKmh) or 0.0) / 3.6)
  local dynamic = M.lastDynamicContext or {}
  local setup = lineCoreSetupFromDynamic(dynamic)
  local dataProviderState = lineCoreDataProviderState()
  local trackSplineSamples = lineCoreSamplesForProfile(M.profile)
  local fileAiLineSamples = lineCoreAiLineSamples()
  local trackFileReference = lineCoreTrackFileReference()
  M.lineCoreDataProviderState = dataProviderState
  M.lineCoreDataConfidence = dataProviderState.confidence or 0.0
  return {
    cacheKey = 'line_core_r02:' .. tostring(key or 'default'),
    cacheMaxAgeS = math.max(0.05, tonumber(settings.LINE_CORE_R02_CACHE_MAX_AGE_S) or 0.35),
    maxStaleReuseS = math.max(0.02, tonumber(settings.LINE_CORE_R02_STALE_MAX_AGE_S) or 0.18),
    now = nowSeconds(),
    samples = trackSplineSamples,
    trackSplineSamples = trackSplineSamples,
    centerlineSource = 'track_sampler_centerline',
    centerlineConfidence = 0.58,
    sampleSpacingM = math.max(1.0, tonumber(settings.LINE_CORE_R02_SAMPLE_SPACING_M) or 3.0),
    trackLength = total,
    trackId = M.activeTrackId,
    layoutId = M.activeTrackLayout,
    carId = M.activeCarId,
    setupHash = M.guidanceSession and M.guidanceSession.setup_hash or M.activeSetupFingerprint,
    setup = setup,
    setupSnapshot = dynamic.setupSnapshot,
    telemetry = dynamic,
    carProfile = M.guidanceSession and M.guidanceSession.car_profile or nil,
    physicsProfile = M.guidanceSession and M.guidanceSession.physics_profile or nil,
    learnedProfile = M.guidanceSession and M.guidanceSession.learned_profile or nil,
    trackLimits = lineCoreTrackLimits(),
    surfaceSamples = lineCoreSurfaceSamples(),
    aiLineSamples = fileAiLineSamples,
    fileAiLineSamples = fileAiLineSamples,
    trackFileReference = trackFileReference,
    trackLimitsKnown = dataProviderState.trackLimitsKnown,
    surfaceMapKnown = dataProviderState.surfaceMapKnown,
    kerbMapKnown = dataProviderState.kerbMapKnown,
    wallMapKnown = dataProviderState.wallMapKnown,
    dataProviderState = dataProviderState,
    usedDefaultTrackProfile = M.guidanceSession and tostring(M.guidanceSession.loadStatus and M.guidanceSession.loadStatus.track_profile):find('default', 1, true) ~= nil,
    usedDefaultCarProfile = M.guidanceSession and tostring(M.guidanceSession.loadStatus and M.guidanceSession.loadStatus.car_profile):find('default', 1, true) ~= nil,
    boundariesKnown = dataProviderState.trackLimitsKnown,
    carState = {
      speedMps = speedMps,
      speed = speedMps,
      speedKph = tonumber(car and car.speedKmh) or 0.0,
      position = car and car.pos or nil,
      pos = car and car.pos or nil,
      world = car and car.pos or nil,
      lastProgress = lineCoreProgressM(car),
      brake = car and car.brake or nil,
      gas = car and car.gas or nil,
    },
  }
end

local function maybeBuildLineCoreGuidance(car, dt)
  M.lineCoreDisabledForFps = false
  if not lineCoreEnabled() or not M.profile or #(M.profile.samples or {}) < 3 then
    M.lineCoreStatus = 'disabled_or_no_profile'
    return nil
  end
  local now = nowSeconds()
  local fps = dt and dt > 0 and 1.0 / dt or 0.0
  local lowFpsThreshold = tonumber(settings.LINE_CORE_R02_LOW_FPS_DISABLE_THRESHOLD) or 0.0
  if lowFpsThreshold > 0.0 and fps > 0.0 and fps < lowFpsThreshold then
    M.lineCoreDisabledForFps = true
    M.lineCoreLowFpsHoldUntil = math.max(tonumber(M.lineCoreLowFpsHoldUntil) or 0.0,
      now + math.max(0.10, tonumber(settings.LINE_CORE_R02_LOW_FPS_HOLD_S) or 1.20))
    if settings.LINE_CORE_R02_KEEP_LAST_GOOD_ON_LOW_FPS == true and M.lineCoreGuidance then
      M.lineCoreStatus = 'held_low_fps'
      M.lineCoreStale = true
      return M.lineCoreGuidance
    end
    M.lineCoreStatus = 'disabled_low_fps_no_guidance'
    return nil
  end
  if settings.LINE_CORE_R02_KEEP_LAST_GOOD_ON_LOW_FPS == true and
      M.lineCoreGuidance and now < (tonumber(M.lineCoreLowFpsHoldUntil) or 0.0) then
    M.lineCoreStatus = 'held_low_fps'
    M.lineCoreStale = true
    return M.lineCoreGuidance
  end
  local key = lineCoreBudgetKey(car)
  local shouldRun = frame_budget.shouldRun('line_core_r02', key, {
    minIntervalS = settings.LINE_CORE_R02_MIN_INTERVAL_S,
    maxWorkPerFrame = settings.FRAME_BUDGET_MAX_WORK_PER_FRAME,
  })
  if not shouldRun then
    local cached = frame_budget.getCached('line_core_r02', key)
    if cached then
      M.lineCoreGuidance = cached
      M.lineCoreGuidanceKey = key
      M.lineCoreStatus = 'cached'
      M.lineCoreStale = cached.window and cached.window.stale == true
    end
    return M.lineCoreGuidanceKey == key and M.lineCoreGuidance or nil
  end

  local ok, guidance = pcall(function()
    return line_core_adapter.build(lineCoreBuildContext(car, key))
  end)
  if ok and guidance and guidance.ok ~= false and guidance.points and #guidance.points >= 3 then
    M.lineCoreGuidance = guidance
    M.lineCoreGuidanceKey = key
    M.lineCoreGuidanceStamp = now
    M.lineCoreLastError = nil
    M.lineCoreStatus = guidance.cacheHit and 'cache_hit' or 'fresh'
    M.lineCoreStale = guidance.window and guidance.window.stale == true
    M.lineCoreGuidanceSummary = guidance.diagnostics and guidance.diagnostics.summary or guidance.reason or 'ok'
    frame_budget.remember('line_core_r02', key, guidance)
    return guidance
  end

  M.lineCoreLastError = ok and tostring(guidance and guidance.reason or 'no_guidance') or tostring(guidance)
  if settings.LINE_CORE_R02_KEEP_LAST_GOOD_ON_LOW_FPS == true and M.lineCoreGuidance then
    local maxFailureHoldS = math.max(0.10, tonumber(settings.LINE_CORE_R02_STALE_MAX_AGE_S) or 0.45)
    if now - (tonumber(M.lineCoreGuidanceStamp) or 0.0) <= maxFailureHoldS then
      M.lineCoreStatus = 'held_build_failure'
      M.lineCoreStale = true
      logger.once('line-core-r02-build-failed-held',
        'LINE_CORE_R02_BUILD_FAILED_HELD reason=' .. tostring(M.lineCoreLastError))
      return M.lineCoreGuidance
    end
  end

  M.lineCoreGuidance = nil
  M.lineCoreGuidanceKey = nil
  M.lineCoreGuidanceStamp = 0
  M.lineCoreStatus = 'failed'
  M.lineCoreStale = false
  logger.once('line-core-r02-build-failed', 'LINE_CORE_R02_BUILD_FAILED reason=' .. tostring(M.lineCoreLastError))
  return nil
end

local function lineCorePointWorld(point)
  local world = point and point.world
  if not world then return nil end
  return math3d.vec(math3d.x(world), math3d.y(world), math3d.z(world))
end

local function lineCoreKind(point)
  local brake = tonumber(point and point.brakeIntensity) or 0.0
  local color = tostring(point and point.color or '')
  if point and point.brakeCueEligible == false then return 'green' end
  if point and point.brakeZoneActive == false and brake < (tonumber(settings.YELLOW_RATIO) or 0.09) then return 'green' end
  if color == 'red' or brake >= (tonumber(settings.RED_RATIO) or 0.58) then return 'red' end
  if color == 'orange' or color == 'yellow' or brake >= (tonumber(settings.YELLOW_RATIO) or 0.08) then return 'yellow' end
  return 'green'
end

local function lineCoreTargetSpeedKph(point)
  local solved = tonumber(point and point.solvedSpeedMps)
  local target = tonumber(point and point.targetSpeedMps)
  return math.max(0.0, (solved or target or 0.0) * 3.6)
end

local function lineCoreTileFromPoint(point, basis, car, distanceAheadM, sourceName, index)
  local pos = lineCorePointWorld(point)
  if not pos then return nil end
  basis = basis or {}
  local forward = math3d.norm(point.tangent or basis.forward or car and car.forward, math3d.vec(0, 0, 1))
  local normal = math3d.norm(basis.normal or car and car.up, math3d.vec(0, 1, 0))
  local right = math3d.norm(basis.right or math3d.cross(normal, forward), math3d.vec(1, 0, 0))
  local offsetLeftM = finiteNumber(point.offset, 0.0)
  local dynamicOffsetRightM = -offsetLeftM
  local centerRight = basis.centerRight or right
  local centerPos = basis.centerPos or math3d.add(pos, math3d.mul(centerRight, offsetLeftM))
  local targetSpeedKph = lineCoreTargetSpeedKph(point)
  local brakeIntensity = math3d.clamp(tonumber(point.brakeIntensity) or 0.0, 0.0, 1.0)
  local total = tonumber(M.profile and M.profile.totalLengthM) or 0.0
  local s = finiteNumber(point.progress, 0.0)

  return {
    index = 'line_core_r02_' .. tostring(index or 0),
    progress = total > 0 and (s / total) or 0.0,
    s = s,
    centerPos = centerPos,
    pos = pos,
    forward = forward,
    right = right,
    normal = normal,
    centerForward = basis.centerForward or forward,
    centerRight = centerRight,
    centerNormal = basis.centerNormal or normal,
    lineForward = forward,
    lineRight = right,
    lineNormal = normal,
    curvature = finiteNumber(point.curvature, finiteNumber(basis.curvature, 0.0)),
    signedCurvature = finiteNumber(point.curvature, finiteNumber(basis.signedCurvature, 0.0)),
    brakingCurvature = math.abs(finiteNumber(point.curvature, finiteNumber(basis.brakingCurvature, 0.0))),
    racingLineOffsetM = dynamicOffsetRightM,
    dynamicLineOffsetM = dynamicOffsetRightM,
    lineOffsetScale = 1.0,
    nearOffsetScale = 1.0,
    racingLineActive = true,
    racingLineFallbackReason = 'line_core_r02',
    linePlacementMode = 'line_core_r02',
    baseTargetSpeedKph = targetSpeedKph,
    targetSpeedKph = targetSpeedKph,
    brakeProfileTargetSpeedKph = targetSpeedKph,
    brakeOffsetM = finiteNumber(point.brakeOffsetM, 0.0),
    brakeProfileSpeedCap = false,
    brakeProfileLimited = true,
    brakeProfileEnvelopeLimited = true,
    brakeProfileReductionKph = math.max(0.0, finiteNumber(basis.targetSpeedKph, targetSpeedKph) - targetSpeedKph),
    baseBrakeCapacityMps2 = finiteNumber(basis.baseBrakeCapacityMps2, settings.DEFAULT_BRAKE_G * 9.80665),
    brakeCapacityMps2 = finiteNumber(basis.brakeCapacityMps2, settings.DEFAULT_BRAKE_G * 9.80665),
    brakeSpeedAeroFactor = finiteNumber(basis.brakeSpeedAeroFactor, 1.0),
    transferClassScale = finiteNumber(basis.transferClassScale, 0.0),
    momentTransferClassScale = finiteNumber(basis.momentTransferClassScale, basis.transferClassScale or 0.0),
    brakeTransferScale = finiteNumber(basis.brakeTransferScale, basis.transferClassScale or 0.0),
    aeroTransferScale = finiteNumber(basis.aeroTransferScale, basis.transferClassScale or 0.0),
    cueTransferClassScale = finiteNumber(basis.cueTransferClassScale, basis.transferClassScale or 0.0),
    capabilityClass = basis.capabilityClass or 'r02_dynamic',
    dynamicConfidence = math3d.clamp(finiteNumber(point.confidence, 0.58), 0.0, 1.0),
    requiredDecelRatio = brakeIntensity,
    cueRatio = brakeIntensity,
    cueSeverity = brakeIntensity,
    rawBrakeIntensity = finiteNumber(point.rawBrakeIntensity, brakeIntensity),
    brakeZoneActive = point.brakeZoneActive == true,
    brakeCueEligible = point.brakeCueEligible == true,
    brakeZoneMaxIntensity = finiteNumber(point.brakeZoneMaxIntensity, brakeIntensity),
    brakeZoneId = finiteNumber(point.brakeZoneId, 0),
    kind = lineCoreKind(point),
    placementMode = 'line_core_r02',
    tileWidthM = finiteNumber(M.tileWidthM, settings.TILE_WIDTH_M),
    tileLengthM = math.max(finiteNumber(M.tileLengthM, settings.TILE_LENGTH_M),
      math.min(4.0, math.max(1.6, finiteNumber(settings.LINE_CORE_R02_SAMPLE_SPACING_M, 3.0) * 0.82))),
    distanceAheadM = finiteNumber(distanceAheadM, 0.0),
    windowSource = tostring(sourceName or 'line_core_r02'),
  }
end

local function lineCoreStableCueFromTile(tile)
  local classifiedKind = tostring(tile and tile.kind or 'green')
  local zoneEligible = tile and tile.brakeCueEligible == true and tile.brakeZoneActive == true
  local warningEligible = tile and tile.brakeCueEligible == true and classifiedKind ~= 'green'
  local eligible = zoneEligible or warningEligible
  local ratio = eligible and math3d.clamp(tonumber(tile and (tile.brakeZoneMaxIntensity or tile.requiredDecelRatio or tile.brakeIntensity or tile.cueRatio)) or 0.0, 0.0, 1.0) or 0.0
  local localRatio = eligible and math3d.clamp(tonumber(tile and (tile.requiredDecelRatio or tile.brakeIntensity or tile.cueRatio)) or ratio, 0.0, 1.0) or 0.0
  local kind = eligible and classifiedKind or 'green'
  if zoneEligible and ratio >= settings.RED_RATIO and localRatio >= math.max(settings.YELLOW_RATIO, settings.RED_RATIO * 0.58) then
    kind = 'red'
  elseif zoneEligible and ratio >= settings.YELLOW_RATIO and localRatio >= settings.YELLOW_RATIO * 0.72 then
    kind = 'yellow'
  elseif not warningEligible then
    kind = 'green'
  end
  return {
    kind = kind,
    requiredDecelRatio = localRatio,
    cueRatio = localRatio,
    cueSeverity = localRatio,
    redFrames = kind == 'red' and 1 or 0,
    targetSpeedKph = tile and tile.targetSpeedKph or settings.MAX_TARGET_SPEED_KPH,
    brakeTargetSpeedKph = tile and (tile.brakeProfileTargetSpeedKph or tile.targetSpeedKph) or settings.MAX_TARGET_SPEED_KPH,
    brakeTargetDistanceM = tile and tile.distanceAheadM or 0.0,
    brakeTargetSampleDistanceM = tile and tile.distanceAheadM or 0.0,
    brakeTargetAvailableDistanceM = tile and tile.distanceAheadM or 0.0,
    brakeTargetEntryLeadM = math.max(0.0, tonumber(tile and tile.brakeOffsetM) or 0.0),
    brakeTargetCurvature = tile and tile.brakingCurvature or 0.0,
    brakeClusterConfirmedSamples = 1,
    brakeSparseTerminalTarget = false,
    brakeSparseTerminalCurvatureOk = true,
    brakeTransferClassScale = tile and tile.brakeTransferScale or 0.0,
    cornerBrakeBiasM = tile and tile.cornerBrakeBiasM or 0.0,
    dynamicConfidence = tile and tile.dynamicConfidence or 0.58,
    confidenceUncertaintyScale = 1.0 - math3d.clamp(tile and tile.dynamicConfidence or 0.58, 0.0, 1.0),
    brakeConfidenceMarginM = math.max(0.0, tonumber(settings.BRAKE_CONFIDENCE_UNCERTAINTY_MARGIN_M) or 8.0),
    requiredBrakeDistanceM = tile and tile.distanceAheadM or 0.0,
    targetPointAheadM = tile and tile.distanceAheadM or 0.0,
    brakeZoneStartDistanceM = math.max(0.0, (tile and tile.distanceAheadM or 0.0) - math.max(0.0, tonumber(tile and tile.brakeOffsetM) or 0.0)),
    brakeZoneWarningStartDistanceM = math.max(0.0, (tile and tile.distanceAheadM or 0.0) - math.max(0.0, tonumber(tile and tile.brakeOffsetM) or 0.0) - 18.0),
    cueCause = zoneEligible and 'line_core_r02_authoritative' or (warningEligible and 'line_core_r02_pre_zone_warning' or 'line_core_r02_no_stable_brake_zone'),
    sequenceDemand = 0.0,
    reason = zoneEligible and 'line_core_r02_authoritative' or (warningEligible and 'line_core_r02_pre_zone_warning' or 'line_core_r02_zone_suppressed'),
  }
end

local function lineCoreCueFromTile(tile)
  return lineCoreStableCueFromTile(tile)
end

local function lineCoreCurrentCueScore(tile, cue)
  local kind = cue and cue.kind or 'green'
  if kind == 'green' then return -1.0 end
  local distance = math.max(0.0, tonumber(tile and tile.distanceAheadM) or 999.0)
  local maxAhead = math.max(20.0, tonumber(settings.LINE_CORE_R02_CURRENT_CUE_MAX_AHEAD_M) or 95.0)
  if distance > maxAhead then return -1.0 end
  local severity = kind == 'red' and 3.0 or 1.6
  local urgency = 1.0 - math3d.clamp(distance / maxAhead, 0.0, 1.0)
  return severity + urgency + (tonumber(cue and cue.cueSeverity) or 0.0)
end

local function visualKindForSeverity(severity, previousKind)
  severity = math3d.clamp(tonumber(severity) or 0.0, 0.0, 1.0)
  local yellow = tonumber(settings.FORZA_VISUAL_MIN_YELLOW_SEVERITY) or tonumber(settings.YELLOW_RATIO) or 0.10
  local red = tonumber(settings.FORZA_VISUAL_MIN_RED_SEVERITY) or tonumber(settings.RED_RATIO) or 0.52
  local hysteresis = math.max(0.0, tonumber(settings.FORZA_VISUAL_COLOR_HYSTERESIS) or 0.065)
  if previousKind == 'red' then red = red - hysteresis end
  if previousKind == 'yellow' then yellow = yellow - hysteresis * 0.6 end
  if severity >= red then return 'red' end
  if severity >= yellow then return 'yellow' end
  return 'green'
end

local function lineCoreApplyForzaVisualSmoothing(tiles, dt)
  if settings.FORZA_VISUAL_STYLE_ENABLED ~= true then return tiles end
  local state = M.r02VisualState or {}
  local smoothing = math3d.clamp(tonumber(settings.FORZA_VISUAL_SEVERITY_SMOOTHING) or 0.42, 0.0, 0.92)
  local nearBoostM = math.max(0.0, tonumber(settings.FORZA_VISUAL_NEAR_CUE_BOOST_M) or 42.0)
  local nextState = {}
  local count = #(tiles or {})
  for i, tile in ipairs(tiles or {}) do
    local severity = math3d.clamp(tonumber(tile.cueSeverity or tile.requiredDecelRatio) or 0.0, 0.0, 1.0)
    local zone = math3d.clamp(tonumber(tile.brakeZoneMaxIntensity) or severity, 0.0, 1.0)
    local prev = tiles[i - 1]
    local nextTile = tiles[i + 1]
    local neighbor = math.max(
      tonumber(prev and (prev.cueSeverity or prev.requiredDecelRatio)) or 0.0,
      tonumber(nextTile and (nextTile.cueSeverity or nextTile.requiredDecelRatio)) or 0.0)
    local distance = math.max(0.0, tonumber(tile.distanceAheadM) or 999.0)
    local nearBoost = nearBoostM > 0.0 and math3d.clamp((nearBoostM - distance) / nearBoostM, 0.0, 1.0) * 0.08 or 0.0
    local targetSeverity = math.max(severity, zone * 0.86, neighbor * 0.34) + nearBoost
    targetSeverity = math3d.clamp(targetSeverity, 0.0, 1.0)
    local key = tostring(math.floor((tonumber(tile.s or tile.distanceAheadM) or i) / 6.0 + 0.5))
    local previous = state[key] or {}
    local visualSeverity = previous.visualSeverity and
      (previous.visualSeverity * smoothing + targetSeverity * (1.0 - smoothing)) or targetSeverity
    local visualKind = visualKindForSeverity(visualSeverity, previous.visualKind)
    tile.visualSeverity = visualSeverity
    tile.visualKind = visualKind
    tile.visualCueReason = 'forza_visual_smoothing'
    nextState[key] = { visualSeverity = visualSeverity, visualKind = visualKind }
  end
  if count == 0 then nextState = {} end
  M.r02VisualState = nextState
  return tiles
end

local function lineCoreTilesFromPoints(guidance, basisTiles, car, aheadM, spacingM, sourceName)
  local points = guidance and guidance.points or {}
  local total = tonumber(M.profile and M.profile.totalLengthM) or 0.0
  local carS = lineCoreProgressM(car)
  if #points < 3 or not carS or total <= 0.0 then return nil end
  aheadM = math.max(1.0, tonumber(aheadM) or M.visibleAheadM or settings.VISIBLE_AHEAD_M)
  spacingM = math.max(0.75, tonumber(spacingM) or settings.TILE_LENGTH_M or 1.45)

  local candidates = {}
  for sourceIndex, point in ipairs(points) do
    local s = finiteNumber(point and point.progress, nil)
    if s then
      local distance = track_sampler.distanceAhead(s, carS, total)
      if distance >= 0.0 and distance <= aheadM + spacingM then
        candidates[#candidates + 1] = { point = point, distance = distance, sourceIndex = sourceIndex }
      end
    end
  end
  table.sort(candidates, function(a, b) return (a.distance or math.huge) < (b.distance or math.huge) end)

  local out = {}
  local lastDistance = -math.huge
  for _, candidate in ipairs(candidates) do
    if #out == 0 or candidate.distance >= lastDistance + spacingM * 0.72 then
      local basisIndex = candidate.point and candidate.point.tangent and candidate.sourceIndex or (#out + 1)
      local basis = basisTiles and (basisTiles[basisIndex] or basisTiles[#out + 1] or basisTiles[#basisTiles]) or nil
      local tile = lineCoreTileFromPoint(candidate.point, basis, car, candidate.distance, sourceName, #out + 1)
      if tile then
        out[#out + 1] = tile
        lastDistance = candidate.distance
      end
    end
  end

  if #out < math.max(3, math.floor(tonumber(settings.LINE_CORE_R02_MIN_VISIBLE_TILES) or 8)) and sourceName == 'line_core_r02_visible' then
    return nil
  end
  return out
end

local function tilePrepareDistanceThresholdM(car)
  local base = math.max(0.25, tonumber(settings.TILE_PREPARE_DISTANCE_M) or
    ((tonumber(settings.TILE_LENGTH_M) or 1.45) * 0.75))
  local maxDistance = math.max(base, tonumber(settings.TILE_PREPARE_MAX_DISTANCE_M) or base)
  local targetHz = math.max(1.0, tonumber(settings.TILE_PREPARE_TARGET_FPS) or 30.0)
  local speedMps = math.max(0.0, (tonumber(car and car.speedKmh) or 0.0) / 3.6)
  local speedDistance = speedMps / targetHz
  return math.max(base, math.min(maxDistance, speedDistance))
end

local function shouldPrepareTiles(now, car)
  if #(M.lastTiles or {}) == 0 then return true end
  now = tonumber(now) or nowSeconds()
  local minInterval = math.max(0.0, tonumber(settings.TILE_PREPARE_MIN_INTERVAL_S) or 0.0)
  if now < (tonumber(M.tilePrepareNextAt) or 0.0) and minInterval > 0.0 then return false, 'min_interval' end
  local currentS = carSplineDistanceM(car)
  if currentS and M.tilePrepareLastS ~= nil then
    local distanceThreshold = tilePrepareDistanceThresholdM(car)
    if wrappedDistanceDeltaM(currentS, M.tilePrepareLastS, M.profile and M.profile.totalLengthM) >= distanceThreshold then
      return true, 'distance'
    end
  elseif not currentS or M.tilePrepareLastS == nil then
    return true, 'position_unknown'
  end

  local maxInterval = math.max(minInterval, tonumber(settings.TILE_PREPARE_MAX_INTERVAL_S) or minInterval)
  if maxInterval > 0.0 and now >= (tonumber(M.tilePrepareForceNextAt) or 0.0) then return true, 'max_interval' end
  return minInterval <= 0.0, 'interval_disabled'
end

local function markTilesPrepared(now, car)
  now = tonumber(now) or nowSeconds()
  local minInterval = math.max(0.0, tonumber(settings.TILE_PREPARE_MIN_INTERVAL_S) or 0.0)
  local maxInterval = math.max(minInterval, tonumber(settings.TILE_PREPARE_MAX_INTERVAL_S) or minInterval)
  M.tilePrepareLastAt = now
  M.tilePrepareNextAt = now + minInterval
  M.tilePrepareForceNextAt = now + maxInterval
  M.tilePrepareLastS = carSplineDistanceM(car)
end

local function refreshDynamicContext(car, dt, force)
  local now = nowSeconds()
  local interval = math.max(0.0, tonumber(settings.DYNAMIC_CONTEXT_REFRESH_INTERVAL_S) or 0.05)
  if force == true or M.lastDynamicContext == nil or now >= (tonumber(M.dynamicContextNextAt) or 0.0) then
    M.lastDynamicContext = dynamic_context.read(car, M.runtimeProfile, dt)
    M.dynamicContextNextAt = now + interval
    if M.lastDynamicContext and settings.KNOWLEDGE_BASE_ENABLED == true then
      M.lastDynamicContext.cornerLearningMomentKey = cornerLearningMomentKey(M.lastDynamicContext)
      knowledge_base.observeContext(car, M.lastDynamicContext)
    elseif M.lastDynamicContext then
      M.lastDynamicContext.cornerLearningMomentKey = cornerLearningMomentKey(M.lastDynamicContext)
    end
    if M.lastDynamicContext then
      local normalized = M.normalizedSession or id_normalizer.session(sessionIdentity(), car)
      M.lastDynamicContext.normalizedTrackId = M.guidanceSession and M.guidanceSession.track_id or normalized.track_id
      M.lastDynamicContext.normalizedLayoutId = M.guidanceSession and M.guidanceSession.layout_id or normalized.layout_id
      M.lastDynamicContext.normalizedCarId = M.guidanceSession and M.guidanceSession.car_id or normalized.car_id
      M.lastDynamicContext.setupHash = M.guidanceSession and M.guidanceSession.setup_hash or normalized.setup_hash
      M.lastDynamicContext.guidanceSessionReady = M.guidanceSession ~= nil
    end
  end
  return M.lastDynamicContext
end

local function mergeLiveCarStateIntoDynamicContext(context, car)
  if not context or not car then return context end
  local speedKph = tonumber(car.speedKmh)
  if speedKph then
    context.currentSpeedKph = speedKph
    context.currentSpeedMs = speedKph / 3.6
  end
  context.currentBrakeInput = math3d.clamp(tonumber(car.brake) or tonumber(context.currentBrakeInput) or 0.0, 0.0, 1.0)
  context.currentGasInput = math3d.clamp(tonumber(car.gas) or tonumber(context.currentGasInput) or 0.0, 0.0, 1.0)
  return context
end

local function maybePromoteRuntimeSnapshot(car)
  if not M.guidanceSession or not M.lastDynamicContext then return end
  local now = nowSeconds()
  if now < (M.runtimeSnapshotPromoteNextAt or 0.0) then return end
  M.runtimeSnapshotPromoteNextAt = now + math.max(3.0, tonumber(settings.RUNTIME_SNAPSHOT_PROMOTE_INTERVAL_S) or 15.0)
  local staged = snapshot_stager.stageRuntimeProfiles(M.guidanceSession, car or {}, M.runtimeProfile, M.lastDynamicContext)
  if M.guidanceSession.paths and M.guidanceSession.paths.runtime_snapshot_hint then
    profile_store.saveJson(M.guidanceSession.paths.runtime_snapshot_hint, staged)
  end
  local promoted, status = snapshot_stager.promoteIfStable(M.guidanceSession, staged, M.lastDynamicContext)
  if not promoted then
    logger.write('RUNTIME_PROFILE_PROMOTION_SKIPPED status=' .. tostring(status or 'staged') ..
      ' stableSamples=' .. tostring(staged and staged.stableSamples or 0))
    return
  end
  profile_store.saveJson(M.guidanceSession.paths.car_profile, promoted.car)
  profile_store.saveJson(M.guidanceSession.paths.track_profile, promoted.track)
  logger.write('RUNTIME_PROFILE_PROMOTION_APPLIED status=' .. tostring(status or 'promoted') ..
    ' confidenceCap=' .. tostring(promoted.confidenceCap or 0.0))
end

local function currentDisplayState(tiles)
  return display_diagnostics.renderState({
    enabled = M.enabled,
    status = M.status,
    profileReady = M.profile ~= nil,
    fallbackLineActive = M.fallbackLineActive,
    tileCount = #(tiles or {}),
    hudDrawCount = M.lastHudDrawCount,
    finalHudDrawCount = M.lastFinalHudDrawCount,
  })
end

local function prepareTiles(car, dt)
  if not M.profile then return {} end
  car = car or {}
  car.trackId = M.activeTrackId
  car.trackLayout = M.activeTrackLayout
  ensureSetupCurrent(car)
  frame_budget.beginFrame(cueFrameId(car))
  mergeLiveCarStateIntoDynamicContext(refreshDynamicContext(car, dt), car)
  maybePromoteRuntimeSnapshot(car)
  M.profile.visibleAheadM = M.visibleAheadM
  syncProfileTileDimensions(M.profile)

  local now = nowSeconds()
  if settings.PERFORMANCE_SAFE_MODE ~= true and now >= (M.profileDynamicNextAt or 0) then
    local profileBudgetKey = guidanceBudgetKey(car, 'profile_dynamic')
    local canRunProfileGuidance = frame_budget.shouldRun('profile_dynamic', profileBudgetKey, {
      minIntervalS = settings.FRAME_BUDGET_PROFILE_MIN_INTERVAL_S,
      maxWorkPerFrame = settings.FRAME_BUDGET_MAX_WORK_PER_FRAME,
    })
    if canRunProfileGuidance then
      target_speed_model.applyDynamic(M.profile.samples, M.lastDynamicContext, {
        knowledgeBase = false,
        sequenceAdvisory = false,
        spinGuard = false,
        closedLoop = true,
      })
      if settings.PHYSICS_FIRST_GUIDANCE_ENABLED == true then
        M.predictiveBaselineSummary = guidance_blender.apply(M.profile.samples, M.lastDynamicContext, M.guidanceSession, {
          closedLoop = true,
          profileRefresh = true,
        })
        frame_budget.remember('profile_dynamic', profileBudgetKey, M.predictiveBaselineSummary)
      end
    else
      M.predictiveBaselineSummary = frame_budget.getCached('profile_dynamic', profileBudgetKey) or M.predictiveBaselineSummary
    end
    M.profileDynamicNextAt = now + math.max(0.10, tonumber(settings.DYNAMIC_PROFILE_REFRESH_INTERVAL_S) or 0.50)
  end
  local tiles = track_sampler.tileWindow(M.profile, car and car.splinePosition or 0)
  tiles = recoverTilesIfNeeded(tiles, car)
  local lineCoreGuidance = maybeBuildLineCoreGuidance(car, dt)
  local cueLookahead = buildCueLookahead(car)
  local r02VisibleActive = false
  local r02BrakeLookaheadActive = false
  if lineCoreGuidance then
    local lineCoreCueLookahead = lineCoreTilesFromPoints(lineCoreGuidance, cueLookahead, car,
      settings.BRAKE_LOOKAHEAD_M, settings.BRAKE_LOOKAHEAD_SPACING_M, 'line_core_r02_brake_lookahead')
    if lineCoreCueLookahead and #lineCoreCueLookahead > 0 then
      cueLookahead = lineCoreCueLookahead
      r02BrakeLookaheadActive = true
    end

    local visibleSpacing = math.max(
      finiteNumber(settings.TILE_LENGTH_M, 1.45) + finiteNumber(settings.TILE_GAP_MIN_M, 0.08),
      finiteNumber(settings.LINE_CORE_R02_SAMPLE_SPACING_M, 3.0) * 0.80)
    local lineCoreVisible = lineCoreTilesFromPoints(lineCoreGuidance, tiles, car,
      M.visibleAheadM, visibleSpacing, 'line_core_r02_visible')
    local lineCoreUsable = hasUsableForwardTile(lineCoreVisible, car)
    if lineCoreUsable then
      tiles = lineCoreVisible
      r02VisibleActive = true
      M.tileRecoveryActive = false
      M.spatialPlacementRejected = false
      M.spatialPlacementRejectedReason = nil
    elseif lineCoreVisible and #lineCoreVisible > 0 then
      logger.once('line-core-r02-visible-rejected', 'LINE_CORE_R02_VISIBLE_REJECTED tileCount=' ..
        tostring(#lineCoreVisible))
    end
  end
  if r02BrakeLookaheadActive ~= true then
    target_speed_model.applyDynamic(cueLookahead, M.lastDynamicContext, {
      knowledgeBase = false,
      sequenceAdvisory = false,
      spinGuard = false,
    })
    track_sampler.smoothBrakeLookaheadLine(cueLookahead)
    target_speed_model.refreshTargetsFromGeometry(cueLookahead, M.lastDynamicContext, {
      preserveKnowledgeScale = false,
    })
  end
  if settings.PHYSICS_FIRST_GUIDANCE_ENABLED == true and r02BrakeLookaheadActive ~= true then
    local lookaheadBudgetKey = guidanceBudgetKey(car, 'brake_lookahead')
    if frame_budget.shouldRun('brake_lookahead', lookaheadBudgetKey, {
      minIntervalS = settings.FRAME_BUDGET_LOOKAHEAD_MIN_INTERVAL_S,
      maxWorkPerFrame = settings.FRAME_BUDGET_MAX_WORK_PER_FRAME,
    }) then
      frame_budget.remember('brake_lookahead', lookaheadBudgetKey,
        guidance_blender.apply(cueLookahead, M.lastDynamicContext, M.guidanceSession, {
          closedLoop = false,
          window = 'brake_lookahead',
        }))
    else
      frame_budget.getCached('brake_lookahead', lookaheadBudgetKey)
    end
  end
  local expensiveTileAdvisories = settings.PERFORMANCE_SAFE_MODE ~= true
  if r02VisibleActive ~= true then
    target_speed_model.applyDynamic(tiles, M.lastDynamicContext, {
      knowledgeBase = expensiveTileAdvisories and settings.KNOWLEDGE_BASE_ENABLED == true,
      sequenceAdvisory = expensiveTileAdvisories,
      spinGuard = expensiveTileAdvisories,
    })
  end
  if settings.CORNER_LEARNING_ENABLED ~= false then
    if r02BrakeLookaheadActive ~= true then applyCornerLearningBias(cueLookahead, car) end
    if r02VisibleActive ~= true then applyCornerLearningBias(tiles, car) end
  end
  for _, tile in ipairs(tiles) do
    if tile.linePlacementMode == 'line_core_r02' then
      tile.nearOffsetScale = 1.0
      tile.lineOffsetScale = 1.0
    else
      track_sampler.applyNearCarOffset(tile, tile.distanceAheadM)
    end
  end
  if r02VisibleActive ~= true then
    track_sampler.smoothVisibleWindowLine(tiles)
    target_speed_model.refreshTargetsFromGeometry(tiles, M.lastDynamicContext, {
      preserveKnowledgeScale = expensiveTileAdvisories and settings.KNOWLEDGE_BASE_ENABLED == true,
    })
  end
  if settings.PHYSICS_FIRST_GUIDANCE_ENABLED == true and r02VisibleActive ~= true then
    local visibleBudgetKey = guidanceBudgetKey(car, 'visible')
    if frame_budget.shouldRun('visible_guidance', visibleBudgetKey, {
      minIntervalS = settings.FRAME_BUDGET_VISIBLE_MIN_INTERVAL_S,
      maxWorkPerFrame = settings.FRAME_BUDGET_MAX_WORK_PER_FRAME,
    }) then
      frame_budget.remember('visible_guidance', visibleBudgetKey,
        guidance_blender.apply(tiles, M.lastDynamicContext, M.guidanceSession, {
          closedLoop = false,
          window = 'visible',
        }))
    else
      frame_budget.getCached('visible_guidance', visibleBudgetKey)
    end
  end
  cue_model.beginFrame(cueFrameId(car), dt or 1 / 60)
  local currentCue = 'green'
  local highestSeverity = -1
  for _, tile in ipairs(tiles) do
    local cue
    if settings.LINE_CORE_R02_AUTHORITATIVE_CUES == true and tile.linePlacementMode == 'line_core_r02' then
      cue = lineCoreCueFromTile(tile)
    else
      cue = cue_model.evaluate(tile, car, M.runtimeProfile, cueLookahead)
    end
    tile.kind = cue.kind
    tile.requiredDecelRatio = cue.requiredDecelRatio
    tile.cueRatio = cue.cueRatio
    tile.cueSeverity = cue.cueSeverity
    tile.redFrames = cue.redFrames
    tile.targetSpeedKph = cue.targetSpeedKph
    tile.brakeTargetSpeedKph = cue.brakeTargetSpeedKph
    tile.brakeTargetDistanceM = cue.brakeTargetDistanceM
    tile.brakeTargetSampleDistanceM = cue.brakeTargetSampleDistanceM
    tile.brakeTargetAvailableDistanceM = cue.brakeTargetAvailableDistanceM
    tile.brakeTargetEntryLeadM = cue.brakeTargetEntryLeadM
    tile.brakeTargetCurvature = cue.brakeTargetCurvature
    tile.brakeClusterConfirmedSamples = cue.brakeClusterConfirmedSamples
    tile.brakeSparseTerminalTarget = cue.brakeSparseTerminalTarget
    tile.brakeSparseTerminalCurvatureOk = cue.brakeSparseTerminalCurvatureOk
    tile.brakeTransferClassScale = cue.brakeTransferClassScale
    tile.cornerBrakeBiasM = cue.cornerBrakeBiasM
    tile.dynamicConfidence = cue.dynamicConfidence
    tile.confidenceUncertaintyScale = cue.confidenceUncertaintyScale
    tile.brakeConfidenceMarginM = cue.brakeConfidenceMarginM
    tile.requiredBrakeDistanceM = cue.requiredBrakeDistanceM
    tile.targetPointAheadM = cue.targetPointAheadM
    tile.brakeZoneStartDistanceM = cue.brakeZoneStartDistanceM
    tile.brakeZoneWarningStartDistanceM = cue.brakeZoneWarningStartDistanceM
    tile.cueCause = cue.cueCause
    tile.sequenceDemand = cue.sequenceDemand
    tile.cueReason = cue.reason
    local severity = tonumber(tile.cueSeverity) or 0
    if tile.linePlacementMode == 'line_core_r02' then
      severity = lineCoreCurrentCueScore(tile, cue)
    end
    if severity > highestSeverity then
      highestSeverity = severity
      currentCue = cue.kind or currentCue
    end
  end
  cue_model.endFrame()
  lineCoreApplyForzaVisualSmoothing(tiles, dt or 1 / 60)
  if r02VisibleActive == true then
    local state = M.r02CueState or {}
    local holdUntil = tonumber(state.holdUntil) or 0.0
    if currentCue ~= 'green' then
      state.kind = currentCue
      state.holdUntil = nowSeconds() + math.max(0.0, tonumber(settings.LINE_CORE_R02_CUE_HOLD_S) or 0.18)
    elseif tostring(state.kind or 'green') ~= 'green' and nowSeconds() < holdUntil then
      currentCue = state.kind
    else
      state.kind = 'green'
      state.holdUntil = 0.0
    end
    M.r02CueState = state
  else
    M.r02CueState = {}
  end
  if settings.CORNER_LEARNING_ENABLED ~= false then
    updateCornerLearningFrame(tiles, car)
  else
    M.lastCornerLearning = nil
  end
  M.currentCue = currentCue
  logDynamicContextProof(tiles, car)
  logForwardTileProof(tiles, car)
  local displayState = currentDisplayState(tiles)
  regression_harness.recordFrame({
    car = car,
    tiles = tiles,
    context = M.lastDynamicContext,
    cueState = currentCue,
    displayState = displayState.singleDisplayState,
  })
  local lineCoreHealth = lineCoreHealthState()
  runtime_health.report({
    enabled = M.enabled,
    initialized = M.initialized,
    status = M.status,
    guidanceSessionReady = M.guidanceSession ~= nil,
    predictiveCornerCount = M.predictiveBaselineSummary and M.predictiveBaselineSummary.corner_count or 0,
    renderStatus = displayState.singleDisplayState,
    rendererMode = lineCoreHealth.rendererMode,
    tileCount = #tiles,
    cueState = currentCue,
    fallbackLineActive = M.fallbackLineActive,
    tileRecoveryActive = M.tileRecoveryActive,
    hudDrawCount = M.lastHudDrawCount,
    finalHudDrawCount = M.lastFinalHudDrawCount,
    frameId = M.frameId,
    fps = dt and dt > 0 and 1.0 / dt or 0.0,
    lineCoreStatus = lineCoreHealth.lineCoreStatus,
    lineCoreDataConfidence = lineCoreHealth.lineCoreDataConfidence,
    lineCoreStale = lineCoreHealth.lineCoreStale,
    learningState = lineCoreHealth.learningState,
    targetSpeedSource = lineCoreHealth.targetSpeedSource,
    splineSource = lineCoreHealth.splineSource,
    fallbackReason = lineCoreHealth.fallbackReason,
    frameBudgetStatus = lineCoreHealth.frameBudgetStatus,
    cacheState = lineCoreHealth.cacheState,
    rejectedLineReason = lineCoreHealth.rejectedLineReason,
  })
  return tiles
end

local function asUiVec3(point)
  if vec3 then
    local ok, converted = pcall(function()
      return vec3(math3d.x(point), math3d.y(point), math3d.z(point))
    end)
    if ok and converted then return converted end
  end
  return point
end

local function finiteScreenPoint(point)
  if point == nil then return nil end
  local ok, x, y = pcall(function()
    local px, py = point.x, point.y
    if px == nil then px = point[1] end
    if py == nil then py = point[2] end
    return tonumber(px), tonumber(py)
  end)
  if not ok or not x or not y then return nil end
  if x ~= x or y ~= y or math.abs(x) > 100000 or math.abs(y) > 100000 then return nil end
  return point
end

local function screenPointText(point)
  local ok, x, y = pcall(function()
    return tonumber(point and (point.x or point[1])), tonumber(point and (point.y or point[2]))
  end)
  if not ok or not x or not y then return 'none' end
  return string.format('%.0f,%.0f', x, y)
end

local function makeScreenPoint(x, y)
  if type(vec2) == 'function' then return vec2(x, y) end
  return { x = x, y = y }
end

local function screenSizeFrom(value, fallbackWidth, fallbackHeight)
  local width = tonumber(safe_struct.field(value, 'x', safe_struct.field(value, 1, nil))) or fallbackWidth or 1920
  local height = tonumber(safe_struct.field(value, 'y', safe_struct.field(value, 2, nil))) or fallbackHeight or 1080
  if width <= 0 then width = fallbackWidth or 1920 end
  if height <= 0 then height = fallbackHeight or 1080 end
  return width, height
end

local function scaleUiWindowSize(size, uiScale)
  local rawWidth, rawHeight = screenSizeFrom(size, 1920, 1080)
  local scale = tonumber(uiScale) or 1.0
  if scale > 1.01 then
    return rawWidth / scale, rawHeight / scale, rawWidth, rawHeight, scale
  end
  return rawWidth, rawHeight, rawWidth, rawHeight, scale
end

local function fullUiWindowSize()
  local simWindowWidth, simWindowHeight = nil, nil
  if ac and ac.getSim then
    local ok, sim = pcall(function() return ac.getSim() end)
    if ok and sim then
      local simWindowSize = safe_struct.field(sim, 'windowSize', nil)
      if simWindowSize then
        simWindowWidth, simWindowHeight = screenSizeFrom(simWindowSize, nil, nil)
      else
        simWindowWidth = safe_struct.number(sim, 'windowWidth', nil)
        simWindowHeight = safe_struct.number(sim, 'windowHeight', nil)
      end
    end
  end
  if ac and ac.getUI then
    local ok, state = pcall(function() return ac.getUI() end)
    if ok and state and state.windowSize then
      local width, height, rawWidth, rawHeight, uiScale = scaleUiWindowSize(state.windowSize, state.uiScale)
      if simWindowWidth and simWindowHeight and simWindowWidth > 0 and simWindowHeight > 0 and
          simWindowWidth < rawWidth and simWindowHeight <= rawHeight then
        return makeScreenPoint(simWindowWidth, simWindowHeight), simWindowWidth, simWindowHeight, 'ac.getSim().windowSize', rawWidth, rawHeight, uiScale, simWindowWidth, simWindowHeight
      end
      return makeScreenPoint(width, height), width, height, 'ac.getUI().windowSize/uiScale', rawWidth, rawHeight, uiScale, simWindowWidth, simWindowHeight
    end
  end
  if ui and ui.windowSize then
    local ok, size = pcall(function() return ui.windowSize() end)
    if ok and size then
      local width, height = screenSizeFrom(size, 1920, 1080)
      return makeScreenPoint(width, height), width, height, 'ui.windowSize', width, height, 1.0, simWindowWidth, simWindowHeight
    end
  end
  return makeScreenPoint(1920, 1080), 1920, 1080, 'fallback', 1920, 1080, 1.0, simWindowWidth, simWindowHeight
end

local function pushFullScreenClip()
  if not ui or not ui.pushClipRectFullScreen or not ui.popClipRect then return false end
  local ok, err = pcall(function() ui.pushClipRectFullScreen() end)
  if not ok then
    logger.once('hud-clip-push-failed', 'HUD_CLIP_PUSH_FAILED ' .. tostring(err))
    return false
  end
  return true
end

local function popFullScreenClip(clipped)
  if not clipped or not ui or not ui.popClipRect then return end
  local ok, err = pcall(function() ui.popClipRect() end)
  if not ok then
    logger.once('hud-clip-pop-failed', 'HUD_CLIP_POP_FAILED ' .. tostring(err))
  end
end

local function makeRgbm(r, g, b, alpha)
  if rgbm then
    local okNew, byNew = pcall(function()
      if rgbm.new then return rgbm.new(r, g, b, alpha) end
      return nil
    end)
    if okNew and byNew then return byNew end

    local okCall, byCall = pcall(function() return rgbm(r, g, b, alpha) end)
    if okCall and byCall then return byCall end
  end
  return nil
end

local HUD_NEON_PALETTE = {
  green = { r = 0.16, g = 0.86, b = 0.18, hex = '#29D63A' },
  yellow = { r = 1.0, g = 1.0, b = 0x33 / 255 },
  red = { r = 1.0, g = 0x31 / 255, b = 0x31 / 255 },
}

local function lerpNumber(a, b, t)
  t = math.max(0, math.min(1, tonumber(t) or 0))
  return a + (b - a) * t
end

local function hudPaletteFor(tileOrKind)
  local kind = tileOrKind
  local severity = nil
  if type(tileOrKind) == 'table' then
    kind = tileOrKind.kind
    severity = tileOrKind.cueSeverity
  end
  local value = tonumber(severity)
  if value then
    value = math.max(0, math.min(1, value))
    local a, b, t
    if value <= 0.5 then
      a, b, t = HUD_NEON_PALETTE.green, HUD_NEON_PALETTE.yellow, value * 2.0
    else
      a, b, t = HUD_NEON_PALETTE.yellow, HUD_NEON_PALETTE.red, (value - 0.5) * 2.0
    end
    return {
      r = lerpNumber(a.r, b.r, t),
      g = lerpNumber(a.g, b.g, t),
      b = lerpNumber(a.b, b.b, t),
    }
  end
  return HUD_NEON_PALETTE[kind] or HUD_NEON_PALETTE.green
end

local function hudColorFor(tileOrKind)
  local p = hudPaletteFor(tileOrKind)
  local boost = math.max(0.01, (tonumber(settings.HUD_COLOR_BRIGHTNESS_M) or 2.5) *
    (tonumber(settings.HUD_RGBM_BRIGHTNESS_SCALE) or 0.65))
  return makeRgbm(p.r * boost, p.g * boost, p.b * boost, 1.0)
end

local function hudShadowColor()
  return makeRgbm(0, 0, 0, 0.78)
end

local function hudCanaryColor()
  return makeRgbm(0.0, 1.0, 0.10, 1.0)
end

local function hudCanaryAccentColor()
  return makeRgbm(1.0, 0.0, 1.0, 1.0)
end

local function projectedHudEndpoints(tile)
  if not tile or not tile.pos or not tile.forward then return nil end
  local f = math3d.norm(tile.forward, math3d.vec(0, 0, 1))
  local halfL = (tonumber(tile.tileLengthM) or settings.TILE_LENGTH_M) * 0.5
  local rear = math3d.sub(tile.pos, math3d.mul(f, halfL))
  local front = math3d.add(tile.pos, math3d.mul(f, halfL))
  local ok1, p1 = pcall(function() return ui.projectPoint(asUiVec3(rear)) end)
  local ok2, p2 = pcall(function() return ui.projectPoint(asUiVec3(front)) end)
  if not ok1 or not ok2 then return nil end
  return finiteScreenPoint(p1), finiteScreenPoint(p2)
end

local function drawSyntheticHudRect(x, y1, y2, thickness, progress, tile)
  if not ui or not ui.drawRectFilled then return false end
  local rectHalf = math.max(7.0, thickness * (1.0 - progress * 0.35))
  local rectTop = math.min(y1, y2) - rectHalf * 0.35
  local rectBottom = math.max(y1, y2) + rectHalf * 0.35
  ui.drawRectFilled(makeScreenPoint(x - rectHalf - 2, rectTop - 2), makeScreenPoint(x + rectHalf + 2, rectBottom + 2), hudShadowColor(), 2)
  ui.drawRectFilled(makeScreenPoint(x - rectHalf, rectTop), makeScreenPoint(x + rectHalf, rectBottom), hudColorFor(tile), 2)
  return true
end

local function drawSyntheticHudLine(tiles, thickness, sizeOverride, centerBias)
  if not ui or not ui.drawLine then return 0 end
  M.lastSyntheticRectCount = 0
  M.firstSyntheticP1 = nil
  M.firstSyntheticP2 = nil
  local width, height
  if sizeOverride then
    width, height = screenSizeFrom(sizeOverride, 1920, 1080)
  elseif ui.windowSize then
    local ok, size = pcall(function() return ui.windowSize() end)
    if ok and size then
      width, height = screenSizeFrom(size, 1920, 1080)
    end
  end
  width = width or 1920
  height = height or 1080
  local centerX = width * (tonumber(centerBias) or 0.50)
  local nearY = height * 0.72
  local farY = height * 0.43
  local visibleAhead = math.max(20.0, tonumber(M.visibleAheadM) or settings.VISIBLE_AHEAD_M)
  local count = 0
  for _, tile in ipairs(tiles or {}) do
    local d = tonumber(tile.distanceAheadM)
    if d and d >= 0 and d <= visibleAhead then
      local t = math.max(0, math.min(1, d / visibleAhead))
      local y = nearY - (nearY - farY) * t
      local segmentLength = math.max(8.0, 34.0 * (1.0 - t) + 8.0)
      local lateral = math.max(-80, math.min(80, (tonumber(tile.curvature) or 0) * 2200))
      local x1 = centerX + lateral
      local y1 = y + segmentLength * 0.5
      local x2 = centerX + lateral
      local y2 = y - segmentLength * 0.5
      local p1 = makeScreenPoint(x1, y1)
      local p2 = makeScreenPoint(x2, y2)
      M.firstSyntheticP1 = M.firstSyntheticP1 or p1
      M.firstSyntheticP2 = M.firstSyntheticP2 or p2
      local ok = pcall(function()
        if drawSyntheticHudRect(x1, y1, y2, thickness, t, tile) then
          M.lastSyntheticRectCount = M.lastSyntheticRectCount + 1
        end
        ui.drawLine(makeScreenPoint(x1 - 1, y1 + 1), makeScreenPoint(x2 - 1, y2 + 1), hudShadowColor(), math.max(3.0, thickness * (1.0 - t * 0.45) + 3.0))
        ui.drawLine(p1, p2, hudColorFor(tile), math.max(2.0, thickness * (1.0 - t * 0.55)))
      end)
      if ok then count = count + 1 end
    end
  end
  return count
end

local function drawScaledHudFallbacks(tiles, thickness, size, width, height)
  local totalCount = drawSyntheticHudLine(tiles, thickness, size, 0.50)
  local totalRects = M.lastSyntheticRectCount or 0
  local firstP1 = M.firstSyntheticP1
  local firstP2 = M.firstSyntheticP2
  local scale = tonumber(settings.WINDOWS_DPI_FALLBACK_SCALE) or 0.6666667
  if width > 2500 and height > 1400 and scale > 0.2 and scale < 1.0 then
    local scaledSize = makeScreenPoint(width * scale, height * scale)
    totalCount = totalCount + drawSyntheticHudLine(tiles, thickness, scaledSize, 0.50)
    totalRects = totalRects + (M.lastSyntheticRectCount or 0)
    firstP1 = firstP1 or M.firstSyntheticP1
    firstP2 = firstP2 or M.firstSyntheticP2
    totalCount = totalCount + drawSyntheticHudLine(tiles, thickness, scaledSize, 0.62)
    totalRects = totalRects + (M.lastSyntheticRectCount or 0)
    firstP1 = firstP1 or M.firstSyntheticP1
    firstP2 = firstP2 or M.firstSyntheticP2
  end
  M.lastSyntheticRectCount = totalRects
  M.firstSyntheticP1 = firstP1
  M.firstSyntheticP2 = firstP2
  return totalCount
end

local function drawHudCanary(size, width, height, layer)
  if not settings.HUD_CANARY_ENABLED or not ui or not ui.drawRectFilled then return 0 end
  local sizePx = math.max(48, tonumber(settings.HUD_CANARY_SIZE_PX) or 180)
  local x = math.max(20, (tonumber(width) or 1920) * 0.5 - sizePx * 0.5)
  local y = math.max(20, (tonumber(height) or 1080) * 0.035)
  local p1 = makeScreenPoint(x, y)
  local p2 = makeScreenPoint(x + sizePx, y + sizePx * 0.42)
  local ok, err = pcall(function()
    ui.drawRectFilled(makeScreenPoint(x - 6, y - 6), makeScreenPoint(x + sizePx + 6, y + sizePx * 0.42 + 6), hudShadowColor(), 4)
    ui.drawRectFilled(p1, p2, hudCanaryColor(), 4)
    ui.drawRectFilled(makeScreenPoint(x + 12, y + 12), makeScreenPoint(x + sizePx - 12, y + sizePx * 0.42 - 12), hudCanaryAccentColor(), 2)
  end)
  if not ok then
    logger.once('hud-canary-failed', 'HUD_CANARY_FAILED ' .. tostring(err))
    return 0
  end
  local now = nowSeconds()
  if now >= (M.hudCanaryProofNextAt or 0) then
    M.hudCanaryProofNextAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    logger.write('HUD_CANARY_PROOF drawn=true layer=' .. tostring(layer or 'unknown') ..
      ' x=' .. tostring(math.floor(x + 0.5)) ..
      ' y=' .. tostring(math.floor(y + 0.5)) ..
      ' size=' .. tostring(math.floor(sizePx + 0.5)) ..
      ' windowWidth=' .. tostring(math.floor((width or 0) + 0.5)) ..
      ' windowHeight=' .. tostring(math.floor((height or 0) + 0.5)) ..
      ' sizeObject=' .. tostring(size ~= nil))
  end
  return 1
end

local function drawDirectHudCanary()
  if not settings.HUD_CANARY_ENABLED or not ui or not ui.drawRectFilled then return 0 end
  local ok, err = pcall(function()
    ui.drawRectFilled(makeScreenPoint(820, 44), makeScreenPoint(1120, 116), hudShadowColor(), 0)
    ui.drawRectFilled(makeScreenPoint(832, 54), makeScreenPoint(1108, 106), hudCanaryAccentColor(), 0)
    ui.drawRectFilled(makeScreenPoint(852, 66), makeScreenPoint(1088, 94), hudCanaryColor(), 0)
  end)
  if not ok then
    logger.once('hud-direct-canary-failed', 'HUD_DIRECT_CANARY_FAILED ' .. tostring(err))
    return 0
  end
  return 1
end

local function drawFullscreenDirectHudOverlay(layer)
  layer = layer or 'IN_GAME'
  M.lastDirectHudDrawCount = 0
  if not settings.FINAL_HUD_OVERLAY_VISIBLE or not M.enabled or not ui or not ui.drawLine then
    return 0
  end

  local size
  if ui.windowSize then
    local ok, result = pcall(function() return ui.windowSize() end)
    if ok then size = result end
  end
  if not size then
    size = select(1, fullUiWindowSize())
  end

  local width, height = screenSizeFrom(size, 1920, 1080)
  local thickness = math.max(2.0, tonumber(settings.FINAL_HUD_OVERLAY_THICKNESS) or 11.0)
  local drawCount = 0
  local ok, err = pcall(function()
    drawCount = drawCount + drawDirectHudCanary()
    drawCount = drawCount + drawScaledHudFallbacks(M.lastTiles or {}, thickness, size, width, height)
  end)

  if ok then
    M.lastDirectHudDrawCount = drawCount
  else
    logger.once('hud-direct-draw-failed', 'HUD_DIRECT_IN_GAME_DRAW_FAILED ' .. tostring(err))
  end

  local now = nowSeconds()
  if now >= (M.directHudProofNextAt or 0) then
    M.directHudProofNextAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    logger.write('HUD_DIRECT_IN_GAME_PROOF directHudDrawCount=' .. tostring(M.lastDirectHudDrawCount) ..
      ' tileCount=' .. tostring(#(M.lastTiles or {})) ..
      ' windowWidth=' .. tostring(math.floor(width + 0.5)) ..
      ' windowHeight=' .. tostring(math.floor(height + 0.5)) ..
      ' rectHudCount=' .. tostring(M.lastSyntheticRectCount or 0) ..
      ' firstSyntheticP1=' .. screenPointText(M.firstSyntheticP1) ..
      ' firstSyntheticP2=' .. screenPointText(M.firstSyntheticP2) ..
      ' callback=' .. tostring(layer) ..
      ' fixedCanary=true' ..
      ' thickness=' .. tostring(thickness))
  end

  return M.lastDirectHudDrawCount
end

local function drawRootHudOverlay(size, width, height, thickness, layer)
  if not ui then return 0 end
  local clipped = pushFullScreenClip()
  if ui.setCursor then
    pcall(function() ui.setCursor(makeScreenPoint(0, 0)) end)
  end
  local ok, result = pcall(function()
    return drawHudCanary(size, width, height, tostring(layer or 'ROOT')) +
      drawScaledHudFallbacks(M.lastTiles or {}, thickness, size, width, height)
  end)
  popFullScreenClip(clipped)
  if not ok then
    logger.once('hud-root-draw-failed', 'HUD_ROOT_DRAW_FAILED ' .. tostring(result))
    return 0
  end
  return result or 0
end

local function drawChildHudOverlay(layer)
  layer = layer or 'IN_GAME'
  M.lastChildHudDrawCount = 0
  if not settings.FINAL_HUD_OVERLAY_VISIBLE or not M.enabled or not ui or not ui.childWindow or not ui.drawLine then
    return 0
  end

  local size
  if ui.windowSize then
    local ok, result = pcall(function() return ui.windowSize() end)
    if ok then size = result end
  end
  if not size then
    size = select(1, fullUiWindowSize())
  end
  local width, height = screenSizeFrom(size, 1920, 1080)
  local thickness = math.max(2.0, tonumber(settings.FINAL_HUD_OVERLAY_THICKNESS) or 11.0)
  local drawCount = 0
  local ok, err = pcall(function()
    if ui.setCursor then ui.setCursor(makeScreenPoint(0, 0)) end
    ui.childWindow('DynamicRacingLineHUDChild' .. tostring(layer), size, false, 0, function()
      drawCount = drawCount + drawHudCanary(size, width, height, layer .. '_CHILD')
      drawCount = drawCount + drawScaledHudFallbacks(M.lastTiles or {}, thickness, size, width, height)
    end)
  end)

  if ok then
    M.lastChildHudDrawCount = drawCount
  else
    logger.once('hud-child-draw-failed', 'HUD_CHILD_DRAW_FAILED ' .. tostring(err))
  end

  local now = nowSeconds()
  if now >= (M.childHudProofNextAt or 0) then
    M.childHudProofNextAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    logger.write('HUD_CHILD_IN_GAME_PROOF childDrawCount=' .. tostring(M.lastChildHudDrawCount) ..
      ' tileCount=' .. tostring(#(M.lastTiles or {})) ..
      ' windowWidth=' .. tostring(math.floor(width + 0.5)) ..
      ' windowHeight=' .. tostring(math.floor(height + 0.5)) ..
      ' rectHudCount=' .. tostring(M.lastSyntheticRectCount or 0) ..
      ' firstSyntheticP1=' .. screenPointText(M.firstSyntheticP1) ..
      ' firstSyntheticP2=' .. screenPointText(M.firstSyntheticP2) ..
      ' childWindow=' .. tostring(ok == true) ..
      ' callback=' .. tostring(layer) ..
      ' thickness=' .. tostring(thickness))
  end

  return M.lastChildHudDrawCount
end

local function drawProjectedHudLine()
  M.lastHudDrawCount = 0
  if not settings.HUD_PROJECTED_LINE_VISIBLE or not M.enabled or not ui or not ui.projectPoint or not ui.drawLine then
    return 0
  end
  local thickness = math.max(1.0, tonumber(settings.HUD_PROJECTED_LINE_THICKNESS) or 7.0)
  local firstP1, firstP2 = nil, nil
  for _, tile in ipairs(M.lastTiles or {}) do
    local p1, p2 = projectedHudEndpoints(tile)
    if p1 and p2 then
      local ok = pcall(function() ui.drawLine(p1, p2, hudColorFor(tile), thickness) end)
      if ok then
        M.lastHudDrawCount = M.lastHudDrawCount + 1
        firstP1 = firstP1 or p1
        firstP2 = firstP2 or p2
      end
    end
  end
  local syntheticHudCount = 0
  if M.lastHudDrawCount == 0 then
    syntheticHudCount = drawSyntheticHudLine(M.lastTiles or {}, thickness)
    M.lastHudDrawCount = syntheticHudCount
  end
  local now = nowSeconds()
  if now >= (M.hudProofNextAt or 0) then
    M.hudProofNextAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    logger.write('HUD_PROJECTED_LINE_PROOF hudDrawCount=' .. tostring(M.lastHudDrawCount) ..
      ' syntheticHudCount=' .. tostring(syntheticHudCount) ..
      ' tileCount=' .. tostring(#(M.lastTiles or {})) ..
      ' firstP1=' .. screenPointText(firstP1) ..
      ' firstP2=' .. screenPointText(firstP2) ..
      ' thickness=' .. tostring(thickness))
  end
  return M.lastHudDrawCount
end

local function drawFinalHudOverlay(layer)
  layer = layer or 'IN_GAME'
  local isUiFinale = layer == 'UI_FINALE'
  local lastCountKey = isUiFinale and 'lastUiFinaleHudDrawCount' or 'lastFinalHudDrawCount'
  M[lastCountKey] = 0
  if not settings.FINAL_HUD_OVERLAY_VISIBLE or not M.enabled or not ui or not ui.transparentWindow or not ui.drawLine then
    return 0
  end
  local size, width, height, sizeSource, rawWindowWidth, rawWindowHeight, uiScale, simWindowWidth, simWindowHeight = fullUiWindowSize()
  local thickness = math.max(2.0, tonumber(settings.FINAL_HUD_OVERLAY_THICKNESS) or 11.0)
  local rootDrawCount = drawRootHudOverlay(size, width, height, thickness, layer .. '_ROOT')
  local drawCount = rootDrawCount
  local ok, err = pcall(function()
    ui.transparentWindow('DynamicRacingLineFinalHud' .. layer, makeScreenPoint(0, 0), size, true, false, function()
      local clipped = pushFullScreenClip()
      local okDraw, result = pcall(function()
        return drawHudCanary(size, width, height, layer .. '_WINDOW') +
          drawScaledHudFallbacks(M.lastTiles or {}, thickness, size, width, height)
      end)
      popFullScreenClip(clipped)
      if not okDraw then error(result) end
      drawCount = drawCount + (result or 0)
    end)
  end)
  if ok then
    M[lastCountKey] = drawCount
  else
    logger.once('hud-' .. string.lower(layer) .. '-draw-failed', 'HUD_' .. layer .. '_DRAW_FAILED ' .. tostring(err))
  end

  local now = nowSeconds()
  local proofNextKey = isUiFinale and 'uiFinaleProofNextAt' or 'finalHudProofNextAt'
  if now >= (M[proofNextKey] or 0) then
    M[proofNextKey] = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    local proofName = isUiFinale and 'HUD_UI_FINALE_PROOF' or 'HUD_IN_GAME_PROOF'
    logger.write(proofName .. ' finalHudDrawCount=' .. tostring(M[lastCountKey]) ..
      ' tileCount=' .. tostring(#(M.lastTiles or {})) ..
      ' windowWidth=' .. tostring(math.floor(width + 0.5)) ..
      ' windowHeight=' .. tostring(math.floor(height + 0.5)) ..
      ' rawWindowWidth=' .. tostring(math.floor((rawWindowWidth or width) + 0.5)) ..
      ' rawWindowHeight=' .. tostring(math.floor((rawWindowHeight or height) + 0.5)) ..
      ' simWindowWidth=' .. tostring(math.floor((simWindowWidth or 0) + 0.5)) ..
      ' simWindowHeight=' .. tostring(math.floor((simWindowHeight or 0) + 0.5)) ..
      ' uiScale=' .. tostring(uiScale or 1.0) ..
      ' rectHudCount=' .. tostring(M.lastSyntheticRectCount or 0) ..
      ' dpiFallbackScale=' .. tostring(settings.WINDOWS_DPI_FALLBACK_SCALE) ..
      ' firstSyntheticP1=' .. screenPointText(M.firstSyntheticP1) ..
      ' firstSyntheticP2=' .. screenPointText(M.firstSyntheticP2) ..
      ' sizeSource=' .. tostring(sizeSource) ..
      ' transparentWindow=' .. tostring(ok == true) ..
      ' rootDrawCount=' .. tostring(rootDrawCount) ..
      ' callback=' .. tostring(layer) ..
      ' thickness=' .. tostring(thickness))
  end
  return M[lastCountKey]
end

local function registerHudOverlay()
  if settings.HUD_PROJECTED_LINE_VISIBLE ~= true then return end
  if M.hudRegistered then return end
  if M.hudRegistrationAttempted then return end
  if not ui or not ui.onExclusiveHUD then return end
  M.hudRegistrationAttempted = true
  local ok, disposableOrErr = pcall(function()
    return ui.onExclusiveHUD(function(mode)
      if mode == 'game' then drawProjectedHudLine() end
      return false
    end)
  end)
  M.hudRegistered = ok == true
  if ok then
    M.hudDisposable = disposableOrErr
  else
    M.hudRegistrationAttempted = false
    logger.once('hud-register-failed', 'HUD_PROJECTED_LINE_REGISTER_FAILED ' .. tostring(disposableOrErr))
  end
  logger.write('HUD_PROJECTED_LINE_REGISTERED registered=' .. tostring(M.hudRegistered) ..
    ' visible=' .. tostring(settings.HUD_PROJECTED_LINE_VISIBLE == true))
end

local function registerUiFinaleOverlay()
  if settings.FINAL_HUD_OVERLAY_VISIBLE ~= true then return end
  if M.uiFinaleRegistered then return end
  if M.uiFinaleRegistrationAttempted then return end
  if not ui or not ui.onUIFinale then return end
  M.uiFinaleRegistrationAttempted = true
  local ok, disposableOrErr = pcall(function()
    return ui.onUIFinale(function()
      drawFinalHudOverlay('UI_FINALE')
    end)
  end)
  M.uiFinaleRegistered = ok == true
  if ok then
    M.uiFinaleDisposable = disposableOrErr
  else
    M.uiFinaleRegistrationAttempted = false
    logger.once('ui-finale-register-failed', 'HUD_UI_FINALE_REGISTER_FAILED ' .. tostring(disposableOrErr))
  end
  logger.write('HUD_UI_FINALE_REGISTERED registered=' .. tostring(M.uiFinaleRegistered) ..
    ' visible=' .. tostring(settings.FINAL_HUD_OVERLAY_VISIBLE == true))
end

function M.update(dt)
  ensureSessionCurrent()
  init()
  registerHudOverlay()
  registerUiFinaleOverlay()
  applyUiSettings()
  logUiEnabledProof('update')
  M.frameId = M.frameId + 1
  if not M.enabled then
    M.lastTiles = {}
    M.currentCue = 'disabled'
    local displayState = currentDisplayState(M.lastTiles)
    local lineCoreHealth = lineCoreHealthState()
    runtime_health.report({
      enabled = M.enabled,
      initialized = M.initialized,
      status = M.status,
      guidanceSessionReady = M.guidanceSession ~= nil,
      predictiveCornerCount = M.predictiveBaselineSummary and M.predictiveBaselineSummary.corner_count or 0,
      renderStatus = displayState.singleDisplayState,
      rendererMode = lineCoreHealth.rendererMode,
      tileCount = 0,
      cueState = M.currentCue,
      fallbackLineActive = M.fallbackLineActive,
      tileRecoveryActive = M.tileRecoveryActive,
      hudDrawCount = M.lastHudDrawCount,
      finalHudDrawCount = M.lastFinalHudDrawCount,
      frameId = M.frameId,
      fps = dt and dt > 0 and 1.0 / dt or 0.0,
      lineCoreStatus = lineCoreHealth.lineCoreStatus,
      lineCoreDataConfidence = lineCoreHealth.lineCoreDataConfidence,
      lineCoreStale = lineCoreHealth.lineCoreStale,
      learningState = lineCoreHealth.learningState,
      targetSpeedSource = lineCoreHealth.targetSpeedSource,
      splineSource = lineCoreHealth.splineSource,
      fallbackReason = lineCoreHealth.fallbackReason,
      frameBudgetStatus = lineCoreHealth.frameBudgetStatus,
      cacheState = lineCoreHealth.cacheState,
      rejectedLineReason = lineCoreHealth.rejectedLineReason,
    })
    return
  end
  M.lastCar = car_state.read()
  if M.profile then
    local now = nowSeconds()
    if shouldPrepareTiles(now, M.lastCar) then
      M.lastTiles = holdLastGoodTiles(prepareTiles(M.lastCar, dt or 1 / 60),
        M.spatialPlacementRejectedReason or 'no_visible_tiles')
      markTilesPrepared(now, M.lastCar)
    end
  else
    M.lastTiles = {}
    M.currentCue = 'profile_failed'
    local displayState = currentDisplayState(M.lastTiles)
    local lineCoreHealth = lineCoreHealthState()
    runtime_health.report({
      enabled = M.enabled,
      initialized = M.initialized,
      status = M.status,
      guidanceSessionReady = M.guidanceSession ~= nil,
      predictiveCornerCount = M.predictiveBaselineSummary and M.predictiveBaselineSummary.corner_count or 0,
      renderStatus = displayState.singleDisplayState,
      rendererMode = lineCoreHealth.rendererMode,
      tileCount = 0,
      cueState = M.currentCue,
      fallbackLineActive = M.fallbackLineActive,
      tileRecoveryActive = M.tileRecoveryActive,
      hudDrawCount = M.lastHudDrawCount,
      finalHudDrawCount = M.lastFinalHudDrawCount,
      frameId = M.frameId,
      fps = dt and dt > 0 and 1.0 / dt or 0.0,
      lineCoreStatus = lineCoreHealth.lineCoreStatus,
      lineCoreDataConfidence = lineCoreHealth.lineCoreDataConfidence,
      lineCoreStale = lineCoreHealth.lineCoreStale,
      learningState = lineCoreHealth.learningState,
      targetSpeedSource = lineCoreHealth.targetSpeedSource,
      splineSource = lineCoreHealth.splineSource,
      fallbackReason = lineCoreHealth.fallbackReason,
      frameBudgetStatus = lineCoreHealth.frameBudgetStatus,
      cacheState = lineCoreHealth.cacheState,
      rejectedLineReason = lineCoreHealth.rejectedLineReason,
    })
  end
end

function M.Draw3D()
  init()
  if M.enabled and (M.profile or M.fallbackLineActive) then
    if M.fallbackLineActive and #(M.lastTiles or {}) == 0 then
      M.lastTiles = buildFallbackDebugTiles(M.lastCar or car_state.read())
    end
    renderer.render(M.lastTiles or {}, {
      opacity = M.opacity,
      widthScale = 1.0,
      lengthScale = 1.0,
      car = M.lastCar or car_state.read(),
      runNonce = M.runNonce or '',
    })
  end
end

function M.DrawHUD()
  init()
  if not M.enabled then
    return
  end
  if #(M.lastTiles or {}) == 0 then
    M.lastCar = M.lastCar or car_state.read()
    if M.profile then
      M.lastTiles = holdLastGoodTiles(prepareTiles(M.lastCar, 1 / 60),
        M.spatialPlacementRejectedReason or 'no_visible_tiles')
    elseif M.fallbackLineActive then
      M.lastTiles = buildFallbackDebugTiles(M.lastCar)
    end
  end
  drawFullscreenDirectHudOverlay('IN_GAME')
  drawChildHudOverlay('IN_GAME')
  drawFinalHudOverlay()
end

function M.fullscreenUI()
  init()
  if not M.enabled then
    return
  end
  drawFullscreenDirectHudOverlay('FULLSCREEN_UI')
end

function M.windowMain(dt)
  init()
  if not ui then return end
  registerHudOverlay()
  registerUiFinaleOverlay()

  ui.text(settings.DISPLAY_NAME)
  ui.text('Status: ' .. tostring(M.status))
  local previousEnabled = M.enabled
  M.enabled = safeCheckbox('Enabled', M.enabled)
  M.debugVisible = safeCheckbox('Debug', M.debugVisible)
  M.opacity = safeSlider('Opacity', M.opacity, 0.05, 1.0, '%.2f')
  M.colorBrightnessM = safeSlider('Neon brightness', M.colorBrightnessM, 0.5, 30.0, '%.1f x')
  M.hudColorBrightnessM = safeSlider('HUD brightness', M.hudColorBrightnessM, 0.5, 8.0, '%.1f x')
  M.visibleAheadM = safeSlider('Visible distance', M.visibleAheadM, 20.0, 350.0, '%.0f m')
  M.lineStartM = safeSlider('Line start', M.lineStartM, 0.0, 30.0, '%.1f m')
  M.tileWidthM = safeSlider('Tile width', M.tileWidthM, 0.25, 5.0, '%.2f m')
  M.tileLengthM = safeSlider('Tile length', M.tileLengthM, 0.5, 15.0, '%.1f m')
  M.tileSpacingM = safeSlider('Tile spacing', M.tileSpacingM, 0.5, 10.0, '%.1f m')
  M.roadHeightM = safeSlider('Road lift', M.roadHeightM, 0.00, 0.25, '%.3f m')
  M.quadLineLiftM = safeSlider('Line floatiness', M.quadLineLiftM, 0.00, 0.25, '%.3f m')
  M.brakeTiltDeg = safeSlider('Brake tilt', M.brakeTiltDeg, 0.0, 15.0, '%.0f deg')
  M.brakeEntryLeadM = safeSlider('Brake cue lead', M.brakeEntryLeadM, 0.0, 50.0, '%.0f m')
  M.yellowRatio = safeSlider('Yellow threshold', M.yellowRatio, 0.01, 0.90, '%.2f')
  M.redRatio = safeSlider('Red threshold', M.redRatio, 0.05, 1.50, '%.2f')
  applyUiSettings()
  logUiEnabledProof('windowMain', previousEnabled)

  if ui.button and ui.button('Rebuild profile') then
    resetProfileState('manual_rebuild')
    init()
  end

  if M.debugVisible then
    local car = M.lastCar or {}
    ui.text('Speed: ' .. tostring(math.floor((car.speedKmh or 0) + 0.5)) .. ' km/h')
    ui.text('Draw count: ' .. tostring(renderer.lastDrawCount or 0))
    ui.text('Line start: ' .. string.format('%.1f m', M.lineStartM or settings.LINE_START_M))
    ui.text('Neon: ' .. string.format('%.1f x', M.colorBrightnessM or settings.COLOR_BRIGHTNESS_M))
    ui.text('HUD neon: ' .. string.format('%.1f x', M.hudColorBrightnessM or settings.HUD_COLOR_BRIGHTNESS_M))
    ui.text('Lift: ' .. string.format('%.3f / %.3f m',
      M.roadHeightM or settings.ROAD_HEIGHT_M,
      M.quadLineLiftM or settings.QUAD_LINE_LIFT_M))
    ui.text('Brake tilt: ' .. string.format('%.0f deg', M.brakeTiltDeg or settings.BRAKE_TILT_MAX_DEG))
    ui.text('Brake lead: ' .. string.format('%.0f m', M.brakeEntryLeadM or settings.BRAKE_CORNER_ENTRY_LEAD_M))
    ui.text('Tile spacing: ' .. string.format('%.1f m', M.tileSpacingM or settings.PROFILE_SPACING_M))
    ui.text('HUD draw: ' .. tostring(M.lastHudDrawCount or 0))
    ui.text('Direct HUD: ' .. tostring(M.lastDirectHudDrawCount or 0))
    ui.text('Final HUD: ' .. tostring(M.lastFinalHudDrawCount or 0))
    ui.text('Top HUD: ' .. tostring(M.lastUiFinaleHudDrawCount or 0))
    ui.text('Placement: ' .. tostring(M.profile and M.profile.placementMode or 'fallback_debug_line'))
    ui.text('Window: ' .. tostring(M.tileRecoveryActive and 'car position recovery' or 'spline progress'))
    ui.text('Cue: ' .. tostring(M.currentCue or 'none'))
    ui.text('Grip: ' .. string.format('%.2f / %.2f',
      M.lastDynamicContext and M.lastDynamicContext.roadGrip or 1.0,
      M.lastDynamicContext and M.lastDynamicContext.surfaceGrip or 1.0))
    ui.text('Capability: ' .. string.format('%.2fg / %.2fg',
      M.lastDynamicContext and M.lastDynamicContext.corneringG or settings.DEFAULT_CORNERING_G,
      M.lastDynamicContext and M.lastDynamicContext.brakeG or settings.DEFAULT_BRAKE_G))
    ui.text('Yellow/Red: ' .. string.format('%.2f / %.2f', M.yellowRatio, M.redRatio))
  end
end

return M
