-- DynamicRacingLine line_core/track_file_ingest.lua
-- Geometry-only AC track-file reader. It uses the track spline as the primary
-- center foundation and fast_lane/ideal_line files only as line-placement hints.

local U = require('src.line_core.math_utils')

local M = {}
local cache = {}

local function assettoRoot()
  if ac and ac.getFolder and ac.FolderID and ac.FolderID.Root then
    local ok, root = pcall(function() return ac.getFolder(ac.FolderID.Root) end)
    if ok and root and root ~= '' then return tostring(root):gsub('[\\/]+$', '') end
  end
  return 'C:/Program Files (x86)/Steam/steamapps/common/assettocorsa'
end

local function joinPath(...)
  local parts = {}
  for i = 1, select('#', ...) do
    local part = tostring(select(i, ...) or ''):gsub('\\', '/')
    if part ~= '' then parts[#parts + 1] = part end
  end
  return table.concat(parts, '/'):gsub('/+', '/')
end

local function safeSegment(value)
  local text = tostring(value or ''):gsub('%.%.', ''):gsub('[\\/]+', '')
  text = text:gsub('[^%w_%-%+%.]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if text == '' or text == 'default' or text == 'unknown' then return nil end
  return text
end

local function readAll(path, binary)
  if not io then return nil end
  if io.load then
    local ok, data = pcall(function() return io.load(path, nil) end)
    if ok and data and data ~= '' then return data end
  end
  if not io.open then return nil end
  local file = io.open(path, binary and 'rb' or 'r')
  if not file then return nil end
  local data = file:read('*all')
  file:close()
  return data
end

local function fileReadable(path)
  if not io or not io.open then return false end
  local file = io.open(path, 'rb')
  if not file then return false end
  file:close()
  return true
end

local function readInt32LE(data, offset)
  local b1, b2, b3, b4 = string.byte(data or '', offset, offset + 3)
  if not b4 then return nil end
  local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  if value >= 2147483648 then value = value - 4294967296 end
  return value
end

function M.readFloat32LE(data, offset)
  local b1, b2, b3, b4 = string.byte(data or '', offset, offset + 3)
  if not b4 then return nil end
  local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  local sign = 1
  if value >= 2147483648 then
    sign = -1
    value = value - 2147483648
  end
  local exponent = math.floor(value / 8388608) % 256
  local mantissa = value % 8388608
  if exponent == 255 then return sign * math.huge end
  if exponent == 0 then
    if mantissa == 0 then return sign * 0.0 end
    return sign * (mantissa / 8388608) * 2 ^ -126
  end
  return sign * (1.0 + mantissa / 8388608) * 2 ^ (exponent - 127)
end

local function readFloat32LE(data, offset)
  return M.readFloat32LE(data, offset)
end

local function parseFastLane(path, opts)
  opts = opts or {}
  local data = readAll(path, true)
  if not data or #data < 16 then return nil, 'missing_or_too_small' end
  local version = readInt32LE(data, 1)
  local count = readInt32LE(data, 5)
  if not count or count < 3 or count > 500000 then return nil, 'bad_count' end
  local expected = 16 + count * 20
  if #data < expected then return nil, 'truncated' end

  local maxPoints = math.max(80, tonumber(opts.maxPoints) or 1800)
  local step = math.max(1, math.floor(count / maxPoints + 0.5))
  local samples = {}
  local lastDistance = 0.0
  for i = 0, count - 1, step do
    local offset = 17 + i * 20
    local x = readFloat32LE(data, offset)
    local y = readFloat32LE(data, offset + 4)
    local z = readFloat32LE(data, offset + 8)
    local distanceM = readFloat32LE(data, offset + 12)
    if U.isFinite(x) and U.isFinite(y) and U.isFinite(z) and U.isFinite(distanceM) then
      lastDistance = math.max(lastDistance, distanceM)
      samples[#samples + 1] = {
        progress = distanceM,
        distance = distanceM,
        world = { x = x, y = y, z = z },
        source = 'ac_fast_lane_ai',
        geometryOnly = true,
        confidence = 0.78,
      }
    end
  end
  return {
    version = version,
    source = path,
    totalLengthM = lastDistance,
    sampleCount = #samples,
    points = samples,
    samples = samples,
    geometryOnly = true,
  }, 'ok'
end

local function parseSurfaces(path)
  local data = readAll(path, false)
  if not data or data == '' then return nil, 'missing' end
  local hints = { source = path, valid = 0, invalid = 0, pit = 0, minFriction = 1.0, maxFriction = 1.0 }
  local current = nil
  for raw in tostring(data):gmatch('[^\r\n]+') do
    local section = raw:match('^%s*%[([^%]]+)%]')
    if section then
      current = {}
    elseif current then
      local key, value = raw:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
      if key then
        current[key] = value
        if key == 'FRICTION' then
          local friction = tonumber(value)
          if friction then
            hints.minFriction = math.min(hints.minFriction, friction)
            hints.maxFriction = math.max(hints.maxFriction, friction)
          end
        elseif key == 'IS_VALID_TRACK' then
          if tostring(value) == '1' then hints.valid = hints.valid + 1 else hints.invalid = hints.invalid + 1 end
        elseif key == 'IS_PITLANE' and tostring(value) == '1' then
          hints.pit = hints.pit + 1
        end
      end
    end
  end
  hints.confidence = (hints.valid + hints.invalid) > 0 and 0.45 or 0.18
  return hints, 'ok'
end

local function pushAiHint(hints, section, values)
  values = values or {}
  local startProgress = tonumber(values.START or values.start)
  local endProgress = tonumber(values.END or values['end'])
  if not startProgress or not endProgress or startProgress == endProgress then return end
  local kind = tostring(section or ''):upper()
  local defaultValue = kind:find('DANGER', 1, true) and 0.0 or 1.0
  local item = {
    startProgress = startProgress % 1.0,
    endProgress = endProgress % 1.0,
    value = tonumber(values.VALUE or values.value) or defaultValue,
    left = tonumber(values.LEFT or values.left),
    right = tonumber(values.RIGHT or values.right),
    section = section,
    source = 'ai_hints.ini',
  }
  if kind:find('BRAKEHINT', 1, true) then
    hints.brakeHints[#hints.brakeHints + 1] = item
  elseif kind:find('DANGER', 1, true) then
    hints.dangerHints[#hints.dangerHints + 1] = item
  elseif kind:find('HINT', 1, true) then
    hints.speedHints[#hints.speedHints + 1] = item
  end
end

local function parseAiHints(path)
  local data = readAll(path, false)
  if not data or data == '' then return nil, 'missing' end
  local hints = {
    source = path,
    speedHints = {},
    brakeHints = {},
    dangerHints = {},
    geometryOnly = true,
    confidence = 0.62,
  }
  local currentSection = nil
  local currentValues = {}
  for raw in tostring(data):gmatch('[^\r\n]+') do
    local line = raw:gsub(';.*$', ''):gsub('#.*$', '')
    local section = line:match('^%s*%[([^%]]+)%]')
    if section then
      if currentSection then pushAiHint(hints, currentSection, currentValues) end
      currentSection = section
      currentValues = {}
    elseif currentSection then
      local key, value = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
      if key and value then currentValues[key:upper()] = value end
    end
  end
  if currentSection then pushAiHint(hints, currentSection, currentValues) end
  hints.count = #hints.speedHints + #hints.brakeHints + #hints.dangerHints
  if hints.count <= 0 then hints.confidence = 0.0 end
  return hints, hints.count > 0 and 'ok' or 'empty'
end

local function candidateTrackDirs(root, trackId, layoutId)
  local track = safeSegment(trackId)
  if not track then return {} end
  local layout = safeSegment(layoutId)
  local base = joinPath(root, 'content/tracks', track)
  local dirs = {}
  if layout then dirs[#dirs + 1] = joinPath(base, layout) end
  dirs[#dirs + 1] = base
  return dirs
end

local function findFirst(paths)
  for _, path in ipairs(paths or {}) do
    if fileReadable(path) then return path end
  end
  return nil
end

function M.loadReference(trackId, layoutId, trackLengthM, opts)
  opts = opts or {}
  local root = opts.root or assettoRoot()
  local key = tostring(root) .. '|' .. tostring(trackId or '') .. '|' .. tostring(layoutId or '') ..
    '|' .. tostring(math.floor((tonumber(trackLengthM) or 0) + 0.5))
  if cache[key] then return cache[key] end

  local fastLaneCandidates = {}
  local surfaceCandidates = {}
  local aiHintCandidates = {}
  for _, dir in ipairs(candidateTrackDirs(root, trackId, layoutId)) do
    fastLaneCandidates[#fastLaneCandidates + 1] = joinPath(dir, 'ai/fast_lane.ai')
    fastLaneCandidates[#fastLaneCandidates + 1] = joinPath(dir, 'data/ideal_line.ai')
    surfaceCandidates[#surfaceCandidates + 1] = joinPath(dir, 'data/surfaces.ini')
    aiHintCandidates[#aiHintCandidates + 1] = joinPath(dir, 'data/ai_hints.ini')
  end

  local aiPath = findFirst(fastLaneCandidates)
  local ai, aiStatus = nil, 'missing'
  if aiPath then ai, aiStatus = parseFastLane(aiPath, opts) end

  local surfacePath = findFirst(surfaceCandidates)
  local surfaceHints, surfaceStatus = nil, 'missing'
  if surfacePath then surfaceHints, surfaceStatus = parseSurfaces(surfacePath) end

  local aiHintsPath = findFirst(aiHintCandidates)
  local aiHints, aiHintsStatus = nil, 'missing'
  if aiHintsPath then aiHints, aiHintsStatus = parseAiHints(aiHintsPath) end

  local samples = ai and ai.samples or {}
  local confidence = #samples > 0 and 0.72 or 0.0
  if surfaceHints then confidence = math.max(confidence, surfaceHints.confidence or 0.0) end
  if aiHints then confidence = math.max(confidence, aiHints.confidence or 0.0) end
  local out = {
    trackId = tostring(trackId or ''),
    layoutId = tostring(layoutId or ''),
    source = 'ac_track_files',
    aiLineSource = aiPath,
    aiLineStatus = aiStatus,
    surfaceSource = surfacePath,
    surfaceStatus = surfaceStatus,
    aiHintsSource = aiHintsPath,
    aiHintsStatus = aiHintsStatus,
    aiLineSamples = samples,
    fileAiLineSamples = samples,
    surfaceHints = surfaceHints,
    aiHints = aiHints,
    speedHints = aiHints and aiHints.speedHints or {},
    brakeHints = aiHints and aiHints.brakeHints or {},
    dangerHints = aiHints and aiHints.dangerHints or {},
    geometryOnly = true,
    trackSplineFoundation = true,
    confidence = confidence,
  }
  cache[key] = out
  return out
end

M.parseFastLane = parseFastLane
M.parseSurfaces = parseSurfaces
M.parseAiHints = parseAiHints

return M
