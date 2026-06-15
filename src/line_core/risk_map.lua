-- DynamicRacingLine line_core/risk_map.lua
-- R02: risk/confidence overlay for surfaces, kerbs, wet/dirty line, wall proximity and unknown collision data.

local U = require('src.line_core.math_utils')
local Config = require('src.line_core.config')
local M = {}

local function fallbackSample(progress)
  return {
    progress = progress,
    known = false,
    leftRisk = 0.20,
    rightRisk = 0.20,
    centerGrip = 1.0,
    wallRisk = 0.0,
    kerbKnown = false,
    wallKnown = false,
    source = 'unknown',
    confidence = 0.0,
  }
end

local function surfaceRisk(surface)
  local s = tostring(surface or ''):lower()
  if s == '' then return 0.15, 0.35, 'unknown_surface' end
  if s:find('grass', 1, true) or s:find('sand', 1, true) or s:find('gravel', 1, true) then return 0.95, 0.85, 'invalid_runoff' end
  if s:find('sausage', 1, true) or s:find('anti_cut', 1, true) then return 0.85, 0.78, 'bad_kerb' end
  if s:find('kerb', 1, true) or s:find('curb', 1, true) then return 0.35, 0.60, 'kerb' end
  if s:find('dirty', 1, true) or s:find('dust', 1, true) or s:find('offline', 1, true) then return 0.48, 0.55, 'dirty_surface' end
  if s:find('road', 1, true) or s:find('asphalt', 1, true) or s:find('tarmac', 1, true) then return 0.05, 0.72, 'road' end
  return 0.22, 0.45, 'unclassified_surface'
end

local function normalizedProgress(value, frame)
  local p = tonumber(value)
  if p == nil then return nil end
  local length = tonumber(frame and frame.length) or 0.0
  if length > 1.0 and p >= 0.0 and p <= 1.0 then return p * length end
  return p
end

local function progressDistance(a, b, frame)
  local length = tonumber(frame and frame.length) or 0.0
  if length > 0.0 then return math.abs(U.shortProgressDelta(a or 0.0, b or 0.0, length)) end
  return math.abs((a or 0.0) - (b or 0.0))
end

function M.fromSurfaceSamples(frame, surfaceSamples)
  local map = { samples = {}, confidence = 0, source = 'risk_map' }
  local n = frame and frame.samples and #frame.samples or 0
  for i = 1, n do
    map.samples[i] = {
      progress = frame.samples[i].progress,
      leftRisk = 0.20,
      rightRisk = 0.20,
      centerGrip = 1.0,
      wallRisk = 0.0,
      kerbKnown = false,
      wallKnown = false,
      source = 'unknown',
      confidence = 0.25,
    }
  end
  for _, ss in ipairs(surfaceSamples or {}) do
    local progress = normalizedProgress(ss.progress or ss.s or ss.distance, frame)
    local idx, bestD = 1, math.huge
    if progress ~= nil then
      for i = 1, n do
        local d = progressDistance(normalizedProgress(frame.samples[i].progress, frame), progress, frame)
        if d < bestD then bestD = d; idx = i end
      end
    elseif ss.world or ss.pos or ss.position then
      local p = ss.world or ss.pos or ss.position
      for i = 1, n do local d = U.distance2(frame.samples[i].world, p); if d < bestD then bestD = d; idx = i end end
    end
    local risk, conf, source = surfaceRisk(ss.surface or ss.surfaceName or ss.tag)
    local side = tostring(ss.side or 'center'):lower()
    local m = map.samples[idx]
    if side == 'left' then
      m.leftRisk = math.max(m.leftRisk, risk)
    elseif side == 'right' then
      m.rightRisk = math.max(m.rightRisk, risk)
    else
      m.leftRisk = math.max(m.leftRisk, risk * 0.5)
      m.rightRisk = math.max(m.rightRisk, risk * 0.5)
      m.centerGrip = math.min(m.centerGrip, ss.grip or (1.0 - risk * 0.35))
    end
    if source == 'kerb' or source == 'bad_kerb' then m.kerbKnown = true end
    m.confidence = math.max(m.confidence, conf)
    m.source = source
    if ss.wallDistanceM then
      m.wallKnown = true
      m.wallRisk = math.max(m.wallRisk, U.clamp((2.2 - tonumber(ss.wallDistanceM)) / 2.2, 0, 1))
    end
  end
  local sum = 0
  for i = 1, n do sum = sum + (map.samples[i].confidence or 0) end
  map.confidence = n > 0 and sum / n or 0
  return map
end

function M.applyToBoundary(boundary, riskMap)
  if not boundary or not boundary.samples or not riskMap or not riskMap.samples then return boundary end
  for i, b in ipairs(boundary.samples) do
    local r = riskMap.samples[i]
    if r then
      b.usableLeft = math.max(0.15, (b.usableLeft or 0) - (r.leftRisk * 0.70 + r.wallRisk * Config.WALL_RISK_EXTRA_MARGIN_M))
      b.usableRight = math.max(0.15, (b.usableRight or 0) - (r.rightRisk * 0.70 + r.wallRisk * Config.WALL_RISK_EXTRA_MARGIN_M))
      b.confidence = U.clamp((b.confidence or 0.3) * 0.75 + (r.confidence or 0.25) * 0.25, 0, 1)
      b.kerbKnown = b.kerbKnown or r.kerbKnown
      b.wallKnown = b.wallKnown or r.wallKnown
      b.surfaceGrip = r.centerGrip or 1.0
      b.surfaceRiskSource = r.source
    end
  end
  local sum = 0
  for i = 1, #boundary.samples do sum = sum + (boundary.samples[i].confidence or 0) end
  boundary.confidence = #boundary.samples > 0 and sum / #boundary.samples or boundary.confidence
  return boundary
end

function M.build(frame, opts)
  opts = opts or {}
  return M.fromSurfaceSamples(frame, opts.surfaceSamples or opts.surfaces or {})
end

function M.at(map, index)
  if map and map.samples then return map.samples[index] or fallbackSample(-1) end
  return map and map[index] or fallbackSample(-1)
end

function M.debugSummary(map)
  local samples = map and map.samples or {}
  local maxRisk, minGrip, knownKerbs, knownWalls, unknown = 0, 1.0, 0, 0, 0
  for _, sample in ipairs(samples) do
    maxRisk = math.max(maxRisk, sample.leftRisk or 0, sample.rightRisk or 0, sample.wallRisk or 0)
    minGrip = math.min(minGrip, sample.centerGrip or 1.0)
    if sample.kerbKnown then knownKerbs = knownKerbs + 1 end
    if sample.wallKnown then knownWalls = knownWalls + 1 end
    if tostring(sample.source or 'unknown') == 'unknown' then unknown = unknown + 1 end
  end
  return {
    confidence = map and map.confidence or 0,
    maxRisk = maxRisk,
    minGrip = minGrip,
    knownKerbs = knownKerbs,
    knownWalls = knownWalls,
    unknownSurfaceMap = unknown,
    source = map and map.source or 'none',
  }
end

return M
