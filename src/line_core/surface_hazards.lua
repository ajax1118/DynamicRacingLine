-- DynamicRacingLine line_core/surface_hazards.lua
-- Risk classifier for unknown kerbs, sausage kerbs, walls, grass, pit entry, wet/dirty surfaces.

local U = require('src.line_core.math_utils')
local M = {}

function M.classify(sample)
  local name = tostring((sample and (sample.name or sample.surface or sample.type or sample.material)) or ''):lower()
  local hazard = { known = name ~= '', risk = 0.35, grip = 1.0, badKerb = false, sausageKerb = false, wall = false, pit = false, pitLane = false, wallDistanceLeft = sample and sample.wallDistanceLeft }
  if name:find('road') or name:find('asphalt') or name:find('tarmac') then hazard.risk = 0.05 end
  if name:find('kerb') or name:find('curb') then hazard.risk = 0.28 end
  if name:find('sausage') or name:find('anti') then hazard.risk = 0.92; hazard.badKerb = true; hazard.sausageKerb = true end
  if name:find('grass') or name:find('gravel') or name:find('sand') then hazard.risk = 0.95; hazard.grip = 0.37 end
  if name:find('wall') or name:find('barrier') or name:find('armco') then hazard.risk = 1.0; hazard.wall = true; hazard.grip = 0 end
  if name:find('pit') then hazard.pit = true; hazard.pitLane = true; hazard.risk = math.max(hazard.risk, 0.72) end
  if sample and sample.grip then hazard.grip = U.clamp(tonumber(sample.grip) or hazard.grip, 0, 1.35) end
  return hazard
end

local function sampleAt(surfaceMap, index)
  if not surfaceMap then return nil end
  if surfaceMap.samples then return surfaceMap.samples[index] end
  return surfaceMap[index]
end

local function riskMapHazard(sample, offset)
  if not sample then return nil end
  if sample.leftRisk ~= nil or sample.rightRisk ~= nil or sample.centerGrip ~= nil or sample.wallRisk ~= nil then
    local lateral = tonumber(offset) or 0.0
    local sideRisk = lateral < -0.05 and sample.leftRisk or (lateral > 0.05 and sample.rightRisk or math.max(sample.leftRisk or 0, sample.rightRisk or 0) * 0.5)
    local gripRisk = 1.0 - U.clamp(tonumber(sample.centerGrip or sample.surfaceGrip or sample.grip) or 1.0, 0.0, 1.35)
    local risk = math.max(tonumber(sideRisk) or 0.0, tonumber(sample.wallRisk) or 0.0, gripRisk)
    return {
      known = sample.source ~= 'unknown',
      risk = U.clamp(risk, 0.0, 1.0),
      grip = U.clamp(tonumber(sample.centerGrip or sample.surfaceGrip or sample.grip) or 1.0, 0.0, 1.35),
      wall = (tonumber(sample.wallRisk) or 0.0) > 0.55,
      wallRisk = tonumber(sample.wallRisk) or 0.0,
      badKerb = (tonumber(sideRisk) or 0.0) > 0.80,
      bad_kerb = (tonumber(sideRisk) or 0.0) > 0.80,
      unknown_surface = sample.source == 'unknown',
    }
  end
  return nil
end

function M.riskForOffset(boundary, surfaceMap, index, offset)
  local h = sampleAt(surfaceMap, index)
  if not h then return 0.15 end
  h = riskMapHazard(h, offset) or (h.risk and h or M.classify(h))
  local risk = h.risk or 0.35
  if boundary then
    local Boundaries = require('src.line_core.boundaries')
    risk = math.max(risk, Boundaries.riskForOffset(boundary, index, offset or 0))
  end
  return U.clamp(risk, 0, 1)
end

function M.repairOffsets(boundary, offsets, surfaceMap, opts)
  opts = opts or {}
  local out, repairs = {}, { changed = 0, reason = 'surface_hazard_repair' }
  local maxRisk = opts.maxRisk or 0.78
  for i = 1, #(offsets or {}) do
    local o = offsets[i] or 0
    local risk = M.riskForOffset(boundary, surfaceMap, i, o)
    if risk > maxRisk then
      o = o * 0.82
      repairs.changed = repairs.changed + 1
    end
    if boundary then
      local Boundaries = require('src.line_core.boundaries')
      o = Boundaries.clampOffset(boundary, i, o)
    end
    out[i] = o
  end
  return out, repairs
end


function M.fromFrame(frame, opts)
  opts = opts or {}
  local map = { samples = {}, confidence = 0, source = 'surface_hazard_map' }
  local known, count = 0, 0
  for i, s in ipairs(frame and frame.samples or {}) do
    local raw = nil
    if opts.surfaceProvider and opts.surfaceProvider.sample then raw = opts.surfaceProvider:sample(s.progress, s.world) end
    if not raw and opts.surfaceMap then raw = sampleAt(opts.surfaceMap, i) or opts.surfaceMap[s.progress] end
    raw = raw or s.surface or s.material or { name = 'unknown_surface' }
    local h = riskMapHazard(raw, 0.0) or M.classify(raw)
    h.progress = s.progress
    h.unknown_surface = not h.known
    h.wallRisk = h.wall and 1 or 0
    h.bad_kerb = h.badKerb == true
    if opts.wetness or opts.rain then
      local wet = tonumber(opts.wetness or opts.rain) or 0
      h.grip = math.max(0.35, (h.grip or 1) * (1 - 0.18 * wet))
      h.risk = math.min(1, (h.risk or 0.35) + 0.14 * wet)
    end
    map.samples[i] = h
    if h.known then known = known + 1 end
    count = count + 1
  end
  map.confidence = count > 0 and known / count or 0
  return map
end

function M.at(map, index)
  local sample = sampleAt(map, index)
  return riskMapHazard(sample, 0.0) or sample or { known = false, risk = 0.35, grip = 1.0, unknown_surface = true, wallRisk = 0, bad_kerb = false }
end

function M.gripAt(map, index)
  local sample = M.at(map, index)
  return U.clamp(tonumber(sample.grip or sample.centerGrip or sample.surfaceGrip) or 1.0, 0.35, 1.35)
end

function M.adjustBoundary(boundary, surfaceMap, ctx)
  if not boundary or not boundary.samples then return boundary end
  for i, b in ipairs(boundary.samples) do
    local h = M.at(surfaceMap, i)
    local shrink = 0
    if h.wall then shrink = shrink + 0.65 end
    if h.badKerb or h.bad_kerb then shrink = shrink + 0.45 end
    if h.risk and h.risk > 0.75 then shrink = shrink + 0.30 end
    if h.unknown_surface then shrink = shrink + 0.08 end
    b.usableLeft = math.max(0.15, (b.usableLeft or b.left or 3.0) - shrink)
    b.usableRight = math.max(0.15, (b.usableRight or b.right or 3.0) - shrink)
    b.surfaceRisk = h.risk or 0.35
    b.surfaceGrip = h.grip or 1.0
    b.confidence = math.max(0.05, (b.confidence or 0.35) - (h.unknown_surface and 0.03 or 0))
  end
  return boundary
end

function M.debugSummary(surfaceMap)
  local samples = surfaceMap and surfaceMap.samples or {}
  local maxRisk, badKerbs, walls, unknown = 0, 0, 0, 0
  for _, h in ipairs(samples) do
    maxRisk = math.max(maxRisk, h.risk or 0)
    if h.badKerb or h.bad_kerb then badKerbs = badKerbs + 1 end
    if h.wall then walls = walls + 1 end
    if h.unknown_surface then unknown = unknown + 1 end
  end
  return { confidence = surfaceMap and surfaceMap.confidence or 0, maxRisk = maxRisk, badKerbs = badKerbs, walls = walls, unknown = unknown }
end

return M
