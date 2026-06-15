local id_normalizer = require('src/id_normalizer')
local settings = require('src/settings')
local logger = require('src/logger')
local learning_guard = require('src/learning_guard')
local snapshot_stager = require('src/snapshot_stager')

local M = {}
local ensuredDirectories = {}
local saveClockByPath = {}

local function finiteNumber(value, fallback)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
  return number
end

local function nowStamp()
  local ok, value = pcall(function() return os.time() end)
  return ok and value or 0
end

local function nowClock()
  local ok, value = pcall(function() return os.clock() end)
  return ok and tonumber(value) or 0.0
end

local function assettoRoot()
  if not ac or not ac.getFolder or not ac.FolderID or not ac.FolderID.Root then return nil end
  local ok, root = pcall(function() return ac.getFolder(ac.FolderID.Root) end)
  if ok and root and root ~= '' then return tostring(root):gsub('[\\/]+$', '') end
  return nil
end

local function appRoot()
  local root = assettoRoot()
  if root then return root .. '/apps/lua/DynamicRacingLine' end
  return 'C:/Program Files (x86)/Steam/steamapps/common/assettocorsa/apps/lua/DynamicRacingLine'
end

local function joinPath(...)
  local parts = {}
  for i = 1, select('#', ...) do
    local part = tostring(select(i, ...) or ''):gsub('\\', '/')
    if part ~= '' then parts[#parts + 1] = part end
  end
  local joined = table.concat(parts, '/'):gsub('/+', '/')
  return joined
end

local function loadSafeJson(path)
  if not io or not io.load or not JSON or not JSON.parse then return nil, 'json_unavailable' end
  local ok, data = pcall(function() return io.load(path, nil) end)
  if not ok or not data or data == '' then return nil, 'missing' end
  local parsedOk, parsed = pcall(function() return JSON.parse(data) end)
  if parsedOk and type(parsed) == 'table' then return parsed, 'ok' end
  logger.write('PROFILE_STORE_JSON_IGNORED path=' .. tostring(path) .. ' reason=malformed_json')
  return nil, 'malformed_json'
end

local function jsonEscape(text)
  text = tostring(text or '')
  text = text:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return text
end

local function sortedKeys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function encodeValue(value, depth)
  depth = tonumber(depth) or 0
  if depth > 8 then return 'null' end
  local valueType = type(value)
  if valueType == 'nil' then return 'null' end
  if valueType == 'boolean' then return value and 'true' or 'false' end
  if valueType == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then return '0' end
    return tostring(value)
  end
  if valueType == 'string' then return '"' .. jsonEscape(value) .. '"' end
  if valueType ~= 'table' then return '"' .. jsonEscape(tostring(value)) .. '"' end

  local array = true
  local maxIndex = 0
  local count = 0
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= 'number' or key < 1 or math.floor(key) ~= key then array = false end
    if type(key) == 'number' and key > maxIndex then maxIndex = key end
  end
  if array and maxIndex == count then
    local parts = {}
    for i = 1, maxIndex do parts[#parts + 1] = encodeValue(value[i], depth + 1) end
    return '[' .. table.concat(parts, ',') .. ']'
  end

  local parts = {}
  for _, key in ipairs(sortedKeys(value)) do
    parts[#parts + 1] = '"' .. jsonEscape(key) .. '":' .. encodeValue(value[key], depth + 1)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

local function parentPath(path)
  return tostring(path or ''):gsub('\\', '/'):match('^(.*)/[^/]+$')
end

local function ensureDirectory(path)
  if not path or path == '' then return false end
  local normalized = tostring(path):gsub('\\', '/')
  if ensuredDirectories[normalized] then return true end
  if io and io.createDir then pcall(function() io.createDir(normalized) end) end
  if io and io.createDirectory then pcall(function() io.createDirectory(normalized) end) end

  local root = appRoot():gsub('\\', '/')
  if normalized:sub(1, #root) == root then
    local current = root
    local suffix = normalized:sub(#root + 2)
    for part in suffix:gmatch('[^/]+') do
      current = joinPath(current, part)
      if not ensuredDirectories[current] then
        if io and io.createDir then pcall(function() io.createDir(current) end) end
        if io and io.createDirectory then pcall(function() io.createDirectory(current) end) end
        ensuredDirectories[current] = true
      end
    end
  end
  ensuredDirectories[normalized] = true
  return true
end

local function saveJson(path, value)
  ensureDirectory(parentPath(path))
  if not io or not io.open then return false, 'io_open_unavailable' end
  local file, err = io.open(path, 'w')
  if not file then return false, tostring(err or 'open_failed') end
  file:write(encodeValue(value))
  file:close()
  return true, 'ok'
end

local function shouldSave(path, force)
  if force == true then
    saveClockByPath[path] = nowClock()
    return true
  end
  local interval = math.max(1.0, tonumber(settings.PROFILE_STORE_SAVE_INTERVAL_S) or 8.0)
  local now = nowClock()
  local previous = saveClockByPath[path]
  if previous and now - previous < interval then return false end
  saveClockByPath[path] = now
  return true
end

local function dataPath(...)
  return joinPath(appRoot(), 'data', ...)
end

local function loadWithDefault(path, defaultPath)
  local value, status = loadSafeJson(path)
  if value then return value, status, path end
  local fallback, fallbackStatus = loadSafeJson(defaultPath)
  if fallback then return fallback, 'fallback_' .. tostring(status), defaultPath end
  return {}, status, path
end

local function sessionPaths(keys)
  local trackBase = dataPath('tracks', keys.track_id, keys.layout_id)
  local defaultTrack = dataPath('tracks', 'default', 'default')
  local carBase = dataPath('cars', keys.car_id)
  local defaultCar = dataPath('cars', 'default')
  local learnedBase = dataPath('learned', keys.track_id, keys.layout_id, keys.car_id)
  return {
    track_profile = joinPath(trackBase, 'track_profile.json'),
    corners = joinPath(trackBase, 'corners.json'),
    base_line = joinPath(trackBase, 'base_line.json'),
    generated_line = joinPath(trackBase, 'generated_line.json'),
    car_profile = joinPath(carBase, 'car_profile.json'),
    physics_profile = joinPath(carBase, 'physics_profile.json'),
    learned_profile = joinPath(learnedBase, keys.setup_hash .. '.json'),
    runtime_snapshot_hint = joinPath(learnedBase, keys.setup_hash .. '_runtime_snapshot_hint.json'),
    default_track_profile = joinPath(defaultTrack, 'track_profile.json'),
    default_corners = joinPath(defaultTrack, 'corners.json'),
    default_base_line = joinPath(defaultTrack, 'base_line.json'),
    default_generated_line = joinPath(defaultTrack, 'generated_line.json'),
    default_car_profile = joinPath(defaultCar, 'car_profile.json'),
    default_physics_profile = joinPath(defaultCar, 'physics_profile.json'),
  }
end

function M.loadSession(identity, car, runtimeProfile)
  local keys = id_normalizer.session(identity, car)
  local paths = sessionPaths(keys)
  local trackProfile, trackStatus = loadWithDefault(paths.track_profile, paths.default_track_profile)
  local corners, cornersStatus = loadWithDefault(paths.corners, paths.default_corners)
  local baseLine, baseLineStatus = loadWithDefault(paths.base_line, paths.default_base_line)
  local generatedLine, generatedLineStatus = loadWithDefault(paths.generated_line, paths.default_generated_line)
  local carProfile, carStatus = loadWithDefault(paths.car_profile, paths.default_car_profile)
  local physicsProfile, physicsStatus = loadWithDefault(paths.physics_profile, paths.default_physics_profile)
  local learnedProfile, learnedStatus = loadSafeJson(paths.learned_profile)
  if type(learnedProfile) ~= 'table' then
    learnedProfile = {
      track_id = keys.track_id,
      layout_id = keys.layout_id,
      car_id = keys.car_id,
      setup_hash = keys.setup_hash,
      confidence = 0.0,
      corners = {},
    }
  end
  if type(learnedProfile.corners) ~= 'table' then learnedProfile.corners = {} end

  local session = {
    rawTrackId = keys.rawTrackId,
    rawLayoutId = keys.rawLayoutId,
    rawCarId = keys.rawCarId,
    track_id = keys.track_id,
    layout_id = keys.layout_id,
    car_id = keys.car_id,
    setup_fingerprint = keys.setup_fingerprint,
    setup_hash = keys.setup_hash,
    paths = paths,
    track_profile = trackProfile,
    corners = corners,
    base_line = baseLine,
    generated_line = generatedLine,
    car_profile = carProfile,
    physics_profile = physicsProfile,
    learned_profile = learnedProfile,
    runtimeProfile = runtimeProfile,
    loadStatus = {
      track_profile = trackStatus,
      corners = cornersStatus,
      base_line = baseLineStatus,
      generated_line = generatedLineStatus,
      car_profile = carStatus,
      physics_profile = physicsStatus,
      learned_profile = learnedStatus or 'missing',
    },
  }
  logger.write('GUIDANCE_PROFILE_STORE_READY track=' .. keys.track_id ..
    ' layout=' .. keys.layout_id ..
    ' car=' .. keys.car_id ..
    ' setup_hash=' .. keys.setup_hash ..
    ' learnedStatus=' .. tostring(session.loadStatus.learned_profile))
  return session
end

function M.saveGeneratedLine(session, samples, summary)
  if type(session) ~= 'table' or not session.paths then return false, 'missing_session' end
  summary = summary or {}
  local payload = {
    track_id = session.track_id,
    layout_id = session.layout_id,
    source = 'predictive_baseline',
    generated_at = nowStamp(),
    sample_count = #(samples or {}),
    confidence = tonumber(summary.confidence) or 0.60,
    corner_count = tonumber(summary.corner_count) or 0,
    notes = 'Generated from AC/CSP geometry and predictive physics; not hand-authored.',
  }
  return saveJson(session.paths.generated_line, payload)
end

function M.saveRuntimeProfiles(session, car, runtimeProfile, context)
  if type(session) ~= 'table' or not session.paths then return false, 'missing_session' end
  car = car or {}
  runtimeProfile = runtimeProfile or session.runtimeProfile or {}
  context = context or {}
  local staged = snapshot_stager.stageRuntimeProfiles(session, car, runtimeProfile, context)
  local hintOk, hintStatus = saveJson(session.paths.runtime_snapshot_hint, staged)
  local promoted, promoteStatus = snapshot_stager.promoteIfStable(session, staged, context)
  if not promoted then
    logger.write('RUNTIME_PROFILE_SNAPSHOT_STAGED runtime_snapshot_hint=' .. tostring(session.paths.runtime_snapshot_hint) ..
      ' hintOk=' .. tostring(hintOk == true) ..
      ' hintStatus=' .. tostring(hintStatus or 'ok') ..
      ' promoteStatus=' .. tostring(promoteStatus or 'staged') ..
      ' car_profile.json=' .. tostring(session.paths.car_profile) ..
      ' track_profile.json=' .. tostring(session.paths.track_profile))
    return hintOk == true, tostring(promoteStatus or hintStatus or 'staged')
  end

  local carOk, carStatus = saveJson(session.paths.car_profile, promoted.car)
  local trackOk, trackStatus = saveJson(session.paths.track_profile, promoted.track)
  logger.write('RUNTIME_PROFILE_SNAPSHOT_PROMOTED car_profile.json=' .. tostring(session.paths.car_profile) ..
    ' carOk=' .. tostring(carOk == true) ..
    ' carStatus=' .. tostring(carStatus or 'ok') ..
    ' track_profile.json=' .. tostring(session.paths.track_profile) ..
    ' trackOk=' .. tostring(trackOk == true) ..
    ' trackStatus=' .. tostring(trackStatus or 'ok') ..
    ' confidenceCap=' .. tostring(promoted.confidenceCap or 0.0))
  return carOk == true and trackOk == true, tostring(carStatus or 'ok') .. ',' .. tostring(trackStatus or 'ok')
end

function M.observeCorner(session, observation)
  if type(session) ~= 'table' or type(session.learned_profile) ~= 'table' then return nil end
  observation = observation or {}
  local learned = session.learned_profile
  learned.track_id = session.track_id
  learned.layout_id = session.layout_id
  learned.car_id = session.car_id
  learned.setup_hash = session.setup_hash
  learned.corners = learned.corners or {}
  local key = id_normalizer.normalize(observation.cornerId or observation.cornerLearningKey, 'unknown_corner')
  local corner = learned.corners[key] or {
    brake_offset_m = 0.0,
    brake_pressure_adjustment = 0.0,
    brake_ramp_adjustment = 'neutral',
    turn_in_offset_m = 0.0,
    apex_speed_offset_kmh = 0.0,
    target_speed_offset_kmh = 0.0,
    apex_position_offset = {},
    exit_line_offset = {},
    spin_risk = 0.0,
    lockup_risk = 0.0,
    entry_instability_risk = 0.0,
    mid_corner_understeer_risk = 0.0,
    exit_instability_risk = 0.0,
    offtrack_risk = 0.0,
    confidence = 0.0,
    observations = 0,
    valid_laps_used = 0,
    rejected_laps = 0,
    consecutiveEvidence = 0,
    lastEvidencePolarity = 'none',
  }

  corner.observations = (tonumber(corner.observations) or 0) + 1
  local evidence = learning_guard.scoreObservation(session, observation, corner)
  corner.learning_guard_reason = evidence.reason
  corner.learning_guard_scale = evidence.adaptationScale
  corner.driverConsistency = evidence.driverConsistency
  corner.cueAlignmentConfidence = evidence.cueAlignmentConfidence
  corner.consecutiveEvidence = evidence.consecutiveEvidence
  corner.lastEvidencePolarity = evidence.polarity
  if evidence.accepted == true then
    corner.valid_laps_used = (tonumber(corner.valid_laps_used) or 0) + 1
    local response = tostring(observation.responseState or '')
    local overspeed = math.max(0.0, tonumber(observation.speedOverTargetKph) or 0.0)
    local actualBrakePointErrorM = finiteNumber(observation.actualBrakePointErrorM, 0.0)
    local lateDistanceM = math.max(0.0, actualBrakePointErrorM)
    local earlyDistanceM = math.max(0.0, -actualBrakePointErrorM)
    local adaptationScale = math.max(0.0, finiteNumber(evidence.adaptationScale, 0.0))
    local maxSingleLapDelta = math.max(0.25, finiteNumber(evidence.maxSingleLapDelta, 1.0))
    local fast_adaptation = response:find('late', 1, true) ~= nil or
      response:find('overspeed', 1, true) ~= nil or overspeed > 4.0 or lateDistanceM > 8.0
    if response:find('late', 1, true) or response:find('overspeed', 1, true) or overspeed > 8.0 then
      local brakeStep = math.min(7.0, 1.4 + overspeed * 0.18 + lateDistanceM * 0.08) * adaptationScale
      local speedStep = math.min(5.0, 0.5 + overspeed * 0.16 + lateDistanceM * 0.035) * adaptationScale
      brakeStep = math.min(brakeStep, maxSingleLapDelta * 7.0)
      speedStep = math.min(speedStep, maxSingleLapDelta * 4.0)
      corner.brake_offset_m = math.min(45.0, (tonumber(corner.brake_offset_m) or 0.0) + brakeStep)
      corner.apex_speed_offset_kmh = math.max(-30.0, (tonumber(corner.apex_speed_offset_kmh) or 0.0) - speedStep)
      corner.target_speed_offset_kmh = math.max(-28.0, (tonumber(corner.target_speed_offset_kmh) or 0.0) - speedStep * 0.75)
    elseif response == 'brake_input_seen' or response == 'speed_drop_seen' then
      local relief = math.min(2.5, earlyDistanceM * 0.04) * adaptationScale
      corner.brake_offset_m = math.max(-8.0, (tonumber(corner.brake_offset_m) or 0.0) * 0.96 - relief)
      corner.target_speed_offset_kmh = (tonumber(corner.target_speed_offset_kmh) or 0.0) * 0.98
    end
    corner.confidence = math.min(0.98, (tonumber(corner.confidence) or 0.0) +
      (fast_adaptation and 0.060 or 0.040) * adaptationScale)
  else
    corner.rejected_laps = (tonumber(corner.rejected_laps) or 0) + 1
    corner.confidence = math.max(0.0, (tonumber(corner.confidence) or 0.0) - 0.020)
  end

  corner.spin_risk = math.max(tonumber(corner.spin_risk) or 0.0, tonumber(observation.spinRisk) or 0.0)
  corner.lockup_risk = math.max(tonumber(corner.lockup_risk) or 0.0, tonumber(observation.lockupRisk) or 0.0)
  corner.entry_instability_risk = math.max(tonumber(corner.entry_instability_risk) or 0.0, tonumber(observation.entryInstabilityRisk) or 0.0)
  corner.mid_corner_understeer_risk = math.max(tonumber(corner.mid_corner_understeer_risk) or 0.0, tonumber(observation.understeerRisk) or 0.0)
  corner.exit_instability_risk = math.max(tonumber(corner.exit_instability_risk) or 0.0, tonumber(observation.exitInstabilityRisk) or 0.0)
  corner.offtrack_risk = math.max(tonumber(corner.offtrack_risk) or 0.0, tonumber(observation.offtrackRisk) or 0.0)
  corner.last_updated = nowStamp()
  learned.corners[key] = corner

  local confidenceSum = 0.0
  local confidenceCount = 0
  for _, value in pairs(learned.corners) do
    confidenceSum = confidenceSum + (tonumber(value.confidence) or 0.0)
    confidenceCount = confidenceCount + 1
  end
  learned.confidence = confidenceCount > 0 and confidenceSum / confidenceCount or 0.0
  session.learnedProfileDirty = true
  if shouldSave(session.paths.learned_profile, observation.forceSave == true) then
    saveJson(session.paths.learned_profile, learned)
    session.learnedProfileDirty = false
  end
  return corner
end

M.loadSafeJson = loadSafeJson
M.saveJson = saveJson
M.dataPath = dataPath

return M
