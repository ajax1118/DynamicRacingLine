local settings = require('src/settings')
local math3d = require('src/math3d')
local logger = require('src/logger')
local safe_struct = require('src/safe_struct')
local M = {
  lastDrawCount = 0,
  nextProofAt = 0,
  nextCanaryProofAt = 0,
  nextCameraCanaryProofAt = 0,
  nextCarDirectionProofAt = 0,
  nextRenderSpaceProofAt = 0,
  nextRenderSpaceSkipProofAt = 0,
  nextScreenRayProofAt = 0,
  nextRenderTargetSkipProofAt = 0,
  lastCanaryDrawn = false,
  lastCameraCanaryDrawn = false,
  lastScreenRayDrawCount = 0,
  renderSpaceMode = 'world',
  renderSpaceFallbackAll = false,
  originShift = nil,
  worldTransformActive = false,
  lineDepthMode = 'unknown',
  quadDepthMode = 'unknown',
  lastLineRenderMode = 'unknown',
}

local fmt, screenPointText, vecText
local QUAD_SHADER_CACHE_KEY = 260528001
local QUAD_SHADER = [[
float4 main(PS_IN pin) {
  return float4(float3(gRed, gGreen, gBlue) * gHdrBoost, gAlpha);
}
]]

local NEON_PALETTE = {
  green = {
    low = { r = 0.10, g = 0.58, b = 0.12 },
    mid = { r = 0.16, g = 0.86, b = 0.18 },
    high = { r = 0.22, g = 1.00, b = 0.24 },
    hex = '#29D63A',
    minM = 8.0,
    midM = 18.0,
    maxM = 24.0,
  },
  yellow = {
    hex = '#FFFF33',
    low = { r = 0.78, g = 0.70, b = 0.02 },
    mid = { r = 1.0, g = 1.0, b = 0x33 / 255 },
    high = { r = 1.0, g = 1.0, b = 0.62 },
    minM = 10.0,
    midM = 22.0,
    maxM = 28.0,
  },
  red = {
    hex = '#FF3131',
    low = { r = 0.75, g = 0.05, b = 0.05 },
    mid = { r = 1.0, g = 0x31 / 255, b = 0x31 / 255 },
    high = { r = 1.0, g = 0.42, b = 0.42 },
    minM = 12.0,
    midM = 26.0,
    maxM = 30.0,
  },
}

local function clamp01(value, fallback)
  local number = tonumber(value) or fallback
  if number < 0 then return 0 end
  if number > 1 then return 1 end
  return number
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

local function lerp(a, b, t)
  return a + (b - a) * math.max(0, math.min(1, tonumber(t) or 0))
end

local function lerpColor(a, b, t)
  return {
    r = lerp(a.r, b.r, t),
    g = lerp(a.g, b.g, t),
    b = lerp(a.b, b.b, t),
  }
end

local function makeVec3(x, y, z)
  local vx = tonumber(x) or 0
  local vy = tonumber(y) or 0
  local vz = tonumber(z) or 0
  if vec3 then
    local ok, converted = pcall(function() return vec3(vx, vy, vz) end)
    if ok and converted then return converted end
  end
  return math3d.vec(vx, vy, vz)
end

local function emptyVec3()
  if vec3 then
    local ok, out = pcall(function() return vec3() end)
    if ok and out then return out end
  end
  return math3d.vec(0, 0, 0)
end

local function makeVec2(x, y)
  local vx = tonumber(x) or 0
  local vy = tonumber(y) or 0
  if vec2 then
    local ok, converted = pcall(function() return vec2(vx, vy) end)
    if ok and converted then return converted end
  end
  return { x = vx, y = vy }
end

local function tileKindAndSeverity(tileOrKind)
  if type(tileOrKind) == 'table' then
    return tileOrKind.visualKind or tileOrKind.kind,
      tileOrKind.visualSeverity or tileOrKind.cueSeverity or tileOrKind.requiredDecelRatio
  end
  return tileOrKind, nil
end

local function brightnessValue()
  local minM = tonumber(settings.COLOR_BRIGHTNESS_MIN_M) or 0.5
  local maxM = tonumber(settings.COLOR_BRIGHTNESS_MAX_M) or 30.0
  return math3d.clamp(tonumber(settings.COLOR_BRIGHTNESS_M) or 18.0, minM, maxM)
end

local function paletteStopForKind(kind)
  local stop = NEON_PALETTE[kind] or NEON_PALETTE.green
  local minM = tonumber(settings.COLOR_BRIGHTNESS_MIN_M) or 0.5
  local neonM = tonumber(settings.COLOR_BRIGHTNESS_NEON_M) or 18.0
  local maxM = tonumber(settings.COLOR_BRIGHTNESS_MAX_M) or 30.0
  local value = brightnessValue()
  local color, mult
  if value <= neonM then
    local t = (value - minM) / math.max(0.001, neonM - minM)
    color = lerpColor(stop.low, stop.mid, t)
    mult = lerp(stop.minM, stop.midM, t)
  else
    local t = (value - neonM) / math.max(0.001, maxM - neonM)
    color = lerpColor(stop.mid, stop.high, t)
    mult = lerp(stop.midM, stop.maxM, t)
  end
  return { r = color.r, g = color.g, b = color.b, mult = mult, hex = stop.hex }
end

local function blendPaletteBySeverity(kind, severity)
  severity = clamp01(severity, kind == 'red' and 0.78 or (kind == 'yellow' and 0.34 or 0.0))
  local green = paletteStopForKind('green')
  local yellow = paletteStopForKind('yellow')
  local red = paletteStopForKind('red')
  if severity <= 0.48 then
    local t = severity / 0.48
    local c = lerpColor(green, yellow, t)
    return {
      r = c.r,
      g = c.g,
      b = c.b,
      mult = lerp(green.mult, yellow.mult, t),
      hex = t > 0.5 and yellow.hex or green.hex,
    }
  end
  local t = (severity - 0.48) / 0.52
  local c = lerpColor(yellow, red, t)
  return {
    r = c.r,
    g = c.g,
    b = c.b,
    mult = lerp(yellow.mult, red.mult, t),
    hex = t > 0.5 and red.hex or yellow.hex,
  }
end

local function paletteFor(tileOrKind)
  local kind, severity = tileKindAndSeverity(tileOrKind)
  if severity ~= nil then return blendPaletteBySeverity(kind, severity) end
  return paletteStopForKind(kind)
end

local function shaderCacheKeyFor(tileOrKind)
  local p = paletteFor(tileOrKind)
  local brightnessBucket = math.floor(brightnessValue() * 10 + 0.5)
  local multBucket = math.floor((tonumber(p.mult) or 0) * 10 + 0.5)
  local kind, severity = tileKindAndSeverity(tileOrKind)
  local kindOffset = kind == 'red' and 30000 or (kind == 'yellow' and 20000 or 10000)
  local severityBucket = math.floor((tonumber(severity) or 0) * 20 + 0.5)
  return QUAD_SHADER_CACHE_KEY + kindOffset + brightnessBucket * 100 + multBucket + severityBucket
end

local function colorFor(tileOrKind, opacity)
  local alpha = clamp01(opacity, settings.OPACITY)
  local p = paletteFor(tileOrKind)
  local boost = math.max(0.01, (tonumber(p.mult) or 1.0) * (tonumber(settings.RGBM_BRIGHTNESS_SCALE) or 0.45))
  return makeRgbm(p.r * boost, p.g * boost, p.b * boost, alpha)
end

local function shaderValuesFor(tileOrKind, opacity)
  local p = paletteFor(tileOrKind)
  local hdrBoost = math.max(tonumber(settings.SHADER_MIN_BOOST) or 1.35,
    (tonumber(p.mult) or 18.0) * (tonumber(settings.SHADER_BOOST_SCALE) or 0.125))
  return {
    gRed = p.r,
    gGreen = p.g,
    gBlue = p.b,
    gAlpha = clamp01(opacity, settings.OPACITY),
    gHdrBoost = hdrBoost,
  }
end

local function rgbmBoostFor(tileOrKind)
  local p = paletteFor(tileOrKind)
  return math.max(0.01, (tonumber(p.mult) or 1.0) * (tonumber(settings.RGBM_BRIGHTNESS_SCALE) or 0.45))
end

local function setRenderTransformIdentity(applySceneOriginOffset)
  if not render or not render.setTransform then return false end
  return pcall(function()
    if mat4x4 and mat4x4.identity then
      render.setTransform(mat4x4.identity(), applySceneOriginOffset == true)
    else
      render.setTransform(makeVec3(0, 0, 0), makeVec3(0, 0, 1), makeVec3(0, 1, 0), applySceneOriginOffset == true)
    end
  end) == true
end

local function linePaintDepthMode()
  if not render or not render.DepthMode then return nil, 'unavailable' end
  local requested = tostring(settings.LINE_DEPTH_OCCLUSION_MODE or 'ReadOnlyLessEqual')
  if requested == 'ReadOnlyLessEqual' and render.DepthMode.ReadOnlyLessEqual then
    return render.DepthMode.ReadOnlyLessEqual, 'ReadOnlyLessEqual'
  end
  if requested == 'ReadOnly' and render.DepthMode.ReadOnly then
    return render.DepthMode.ReadOnly, 'ReadOnly'
  end
  if render.DepthMode.ReadOnlyLessEqual then return render.DepthMode.ReadOnlyLessEqual, 'ReadOnlyLessEqual' end
  if render.DepthMode.ReadOnly then return render.DepthMode.ReadOnly, 'ReadOnly' end
  return nil, 'unavailable'
end

local function applyLinePaintDepthMode()
  local depthMode, depthModeName = linePaintDepthMode()
  if not depthMode or not render or not render.setDepthMode then return false, depthModeName end
  local ok = pcall(function() render.setDepthMode(depthMode) end)
  return ok == true, depthModeName
end

local function resetLinePaintDepthMode()
  return applyLinePaintDepthMode()
end

local function configureRenderState()
  local blend = false
  local depth = false
  local depthName = 'unavailable'
  local cull = false
  if render and render.setBlendMode and render.BlendMode and render.BlendMode.AlphaBlend then
    blend = pcall(function() render.setBlendMode(render.BlendMode.AlphaBlend) end) == true
  end
  depth, depthName = applyLinePaintDepthMode()
  if render and render.setCullMode and render.CullMode and render.CullMode.None then
    cull = pcall(function() render.setCullMode(render.CullMode.None) end) == true
  end
  local transform = setRenderTransformIdentity(true)
  M.worldTransformActive = transform
  return {
    blend = blend,
    depth = depth,
    depthName = depthName,
    cull = cull,
    transform = transform,
  }
end

local function restoreRenderTransformState()
  if setRenderTransformIdentity(false) then
    M.worldTransformActive = false
    return true
  end
  return false
end

local function restoreRenderState(state)
  state = state or {}
  if state.transform then restoreRenderTransformState() end
  if state.blend and render and render.setBlendMode and render.BlendMode and render.BlendMode.Opaque then
    pcall(function() render.setBlendMode(render.BlendMode.Opaque) end)
  end
  if state.depth and render and render.setDepthMode and render.DepthMode and render.DepthMode.Normal then
    pcall(function() render.setDepthMode(render.DepthMode.Normal) end)
  end
  if state.cull and render and render.setCullMode and render.CullMode and render.CullMode.Back then
    pcall(function() render.setCullMode(render.CullMode.Back) end)
  end
end

local function vecComponents(v)
  if v == nil then return nil end
  local ok, x, y, z = pcall(function()
    local vx, vy, vz = v.x, v.y, v.z
    if vx == nil then vx = v[1] end
    if vy == nil then vy = v[2] end
    if vz == nil then vz = v[3] end
    return tonumber(vx), tonumber(vy), tonumber(vz)
  end)
  if not ok or not x or not y or not z then return nil end
  return x, y, z
end

local function vec2Components(v)
  if v == nil then return nil end
  local ok, x, y = pcall(function()
    local vx, vy = v.x, v.y
    if vx == nil then vx = v[1] end
    if vy == nil then vy = v[2] end
    return tonumber(vx), tonumber(vy)
  end)
  if not ok or not x or not y then return nil end
  return x, y
end

local function renderTargetDimensions()
  if not render or not render.getRenderTargetSize then return nil, nil end
  local ok, size = pcall(function() return render.getRenderTargetSize() end)
  local sx, sy = vec2Components(ok and size or nil)
  if sx and sy and sx > 0 and sy > 0 then return sx, sy end
  return nil, nil
end

local function mainWindowDimensions()
  if not ac or not ac.getSim then return nil, nil, 'unavailable' end
  local ok, sim = pcall(function() return ac.getSim() end)
  if not ok or not sim then return nil, nil, 'unavailable' end
  local wx, wy = vec2Components(safe_struct.field(sim, 'windowSize', nil))
  if wx and wy and wx > 0 and wy > 0 then return wx, wy, 'safe_window_size' end
  wx = safe_struct.number(sim, 'windowWidth', nil)
  wy = safe_struct.number(sim, 'windowHeight', nil)
  if wx and wy and wx > 0 and wy > 0 then return wx, wy, 'safe_window_dimensions' end
  return nil, nil, 'unknown'
end

local function classifyRenderTargetSize(width, height, windowWidth, windowHeight)
  local aspect = width / math.max(1.0, height)
  local windowAspect = nil
  local minWindowFraction = math3d.clamp(tonumber(settings.MAIN_RENDER_TARGET_MIN_WINDOW_FRACTION) or 0.98, 0.10, 1.0)
  local scaledMinWindowFraction = math3d.clamp(tonumber(settings.MAIN_RENDER_TARGET_SCALED_MIN_WINDOW_FRACTION) or 0.60, 0.50, 1.0)
  local aspectTolerance = math.max(0.02, tonumber(settings.MAIN_RENDER_TARGET_ASPECT_TOLERANCE) or 0.04)
  local dimensionTolerance = math3d.clamp(tonumber(settings.MAIN_RENDER_TARGET_DIMENSION_TOLERANCE) or 0.02, 0.0, 0.25)
  local widthRatio = 0.0
  local heightRatio = 0.0
  local targetScale = 0.0
  if not windowWidth or not windowHeight then
    return false, 'unknown_main_window', aspect, windowAspect,
      minWindowFraction, aspectTolerance, dimensionTolerance, widthRatio, heightRatio, targetScale
  end
  if windowWidth and windowHeight then
    windowAspect = windowWidth / math.max(1.0, windowHeight)
    widthRatio = width / math.max(1.0, windowWidth)
    heightRatio = height / math.max(1.0, windowHeight)
    targetScale = math.min(widthRatio, heightRatio)
    local aspectMatches = math.abs(aspect - windowAspect) <= aspectTolerance
    local fullWindowTarget = widthRatio >= minWindowFraction and
      heightRatio >= minWindowFraction and
      math.abs(widthRatio - 1.0) <= dimensionTolerance and
      math.abs(heightRatio - 1.0) <= dimensionTolerance and
      aspectMatches
    -- Live proof: 3431x1448 in a 5120x2160 AC window has widthRatio=0.670 and heightRatio=0.670.
    local scaledMainViewport = widthRatio >= scaledMinWindowFraction and
      heightRatio >= scaledMinWindowFraction and
      math.abs(widthRatio - heightRatio) <= dimensionTolerance and
      aspectMatches
    if not fullWindowTarget and not scaledMainViewport then
      return true, 'offscreen_render_target', aspect, windowAspect,
        minWindowFraction, aspectTolerance, dimensionTolerance, widthRatio, heightRatio, targetScale
    end
    if scaledMainViewport and not fullWindowTarget then
      local reason = 'scaled_main_render_target'
      local minHeight = math.max(1.0, tonumber(settings.MIN_MAIN_RENDER_HEIGHT_PX) or 600)
      local maxAspect = math.max(1.0, tonumber(settings.MAX_MAIN_RENDER_ASPECT) or 3.85)
      if height < minHeight or aspect > maxAspect then
        return true, 'non_main_render_target', aspect, windowAspect,
          minWindowFraction, aspectTolerance, dimensionTolerance, widthRatio, heightRatio, targetScale
      end
      return false, reason, aspect, windowAspect,
        minWindowFraction, aspectTolerance, dimensionTolerance, widthRatio, heightRatio, targetScale
    end
  end
  local minHeight = math.max(1.0, tonumber(settings.MIN_MAIN_RENDER_HEIGHT_PX) or 600)
  local maxAspect = math.max(1.0, tonumber(settings.MAX_MAIN_RENDER_ASPECT) or 3.85)
  if height < minHeight or aspect > maxAspect then
    return true, 'non_main_render_target', aspect, windowAspect,
      minWindowFraction, aspectTolerance, dimensionTolerance, widthRatio, heightRatio, targetScale
  end
  return false, 'main_render_target', aspect, windowAspect,
    minWindowFraction, aspectTolerance, dimensionTolerance, widthRatio, heightRatio, targetScale
end

local function shouldSkipRenderTarget()
  if settings.MAIN_CAMERA_ONLY_RENDER_TARGETS ~= true then return false, 'disabled' end
  local width, height = renderTargetDimensions()
  if not width or not height then return true, 'unknown_render_target' end
  local windowWidth, windowHeight, windowSource = mainWindowDimensions()
  local skip, reason, aspect, windowAspect, minWindowFraction, aspectTolerance, dimensionTolerance,
    widthRatio, heightRatio, targetScale =
    classifyRenderTargetSize(width, height, windowWidth, windowHeight)
  return skip, reason, width, height, aspect,
    windowWidth, windowHeight, windowAspect, windowSource, minWindowFraction, aspectTolerance, dimensionTolerance,
    widthRatio, heightRatio, targetScale
end

local function finiteVec(v)
  local x, y, z = vecComponents(v)
  if not x then return false end
  return x == x and y == y and z == z and
    math.abs(x) < 100000 and math.abs(y) < 100000 and math.abs(z) < 100000
end

local function directionVec(v)
  if not finiteVec(v) then return false end
  return math3d.len(v) > 0.000001
end

local function asRenderVec3(point)
  return makeVec3(math3d.x(point), math3d.y(point), math3d.z(point))
end

local function currentSim()
  if not ac or not ac.getSim then return nil end
  local ok, sim = pcall(function() return ac.getSim() end)
  if ok then return sim end
  return nil
end

local function currentOriginShift()
  local sim = currentSim()
  local shift = safe_struct.field(sim, 'originShift', nil)
  if finiteVec(shift) then
    return math3d.vec(math3d.x(shift), math3d.y(shift), math3d.z(shift))
  end
  return nil
end

local function renderSpacePoint(point, mode, originShift)
  mode = mode or M.renderSpaceMode or 'world'
  originShift = originShift or M.originShift
  if mode == 'origin_add' and originShift then return math3d.add(point, originShift) end
  if mode == 'origin_sub' and originShift then return math3d.sub(point, originShift) end
  return point
end

local function asDrawVec3(point, mode)
  return asRenderVec3(renderSpacePoint(point, mode, M.originShift))
end

local function isVisibleForMode(point, mode, radius)
  if not render or not render.isVisible or not finiteVec(point) then return false, 'unknown' end
  local gSpace = mode ~= 'world'
  local p = mode == 'world' and asRenderVec3(point) or asDrawVec3(point, mode)
  local ok, result = pcall(function() return render.isVisible(p, radius or 2.0, gSpace, false) end)
  if not ok then return false, 'error:' .. tostring(result) end
  return result == true, tostring(result == true)
end

local function mainCameraVisibleText(point, radius)
  if not ac or not ac.isVisibleInMainCamera or not finiteVec(point) then return 'unknown' end
  local ok, result = pcall(function() return ac.isVisibleInMainCamera(asRenderVec3(point), radius or 2.0, false, false) end)
  return ok and tostring(result == true) or ('error:' .. tostring(result))
end

local function modeProjectionText(point, mode)
  if not render or not render.projectPoint or not finiteVec(point) then return 'unknown' end
  local okProjected, result = pcall(function() return render.projectPoint(asDrawVec3(point, mode)) end)
  return okProjected and screenPointText(result) or ('error:' .. tostring(result))
end

local function referenceProbePoints(tiles, car)
  local points = {}
  if car and finiteVec(car.pos) then
    points[#points + 1] = car.pos
    if directionVec(car.forward) and directionVec(car.up) then
      local f = math3d.norm(car.forward, math3d.vec(0, 0, 1))
      local u = math3d.norm(car.up, math3d.vec(0, 1, 0))
      points[#points + 1] = math3d.add(math3d.add(car.pos, math3d.mul(f, 12.0)), math3d.mul(u, 1.2))
      points[#points + 1] = math3d.add(math3d.sub(car.pos, math3d.mul(f, 12.0)), math3d.mul(u, 1.2))
    end
  end
  for _, tile in ipairs(tiles or {}) do
    if finiteVec(tile.pos) then
      points[#points + 1] = tile.pos
      if #points >= 8 then break end
    end
  end
  return points
end

local function renderModesToDraw()
  return { M.renderSpaceMode or 'world' }
end

local function shouldSkipAmbiguousRenderSpace()
  return M.renderSpaceFallbackAll == true
end

local function chooseRenderSpace(tiles, car)
  M.originShift = currentOriginShift()
  if M.worldTransformActive == true then
    M.renderSpaceMode = 'world'
    M.renderSpaceFallbackAll = false
    local now = os.clock and os.clock() or 0
    if now >= (M.nextRenderSpaceProofAt or 0) then
      M.nextRenderSpaceProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
      logger.write('RENDER_SPACE_PROOF mode=world fallbackAll=false' ..
        ' worldVisibleCount=skipped originAddVisibleCount=skipped originSubVisibleCount=skipped' ..
        ' pointCount=0 originShift=' .. (M.originShift and vecText(M.originShift) or 'none') ..
        ' reason=world_transform_active')
    end
    return
  end
  local modes = (M.worldTransformActive or not M.originShift) and { 'world' } or { 'world', 'origin_add', 'origin_sub' }
  local points = referenceProbePoints(tiles, car)
  local counts = { world = 0, origin_add = 0, origin_sub = 0 }
  local firstPoint = points[1]
  for _, point in ipairs(points) do
    for _, mode in ipairs(modes) do
      local visible = isVisibleForMode(point, mode, 3.0)
      if visible then counts[mode] = (counts[mode] or 0) + 1 end
    end
  end

  local bestMode = 'world'
  local bestCount = counts.world or 0
  for _, mode in ipairs({ 'origin_add', 'origin_sub' }) do
    if (counts[mode] or 0) > bestCount then
      bestMode = mode
      bestCount = counts[mode] or 0
    end
  end
  M.renderSpaceMode = bestMode
  M.renderSpaceFallbackAll = not M.worldTransformActive and M.originShift ~= nil and bestCount == 0

  local now = os.clock and os.clock() or 0
  if now >= (M.nextRenderSpaceProofAt or 0) then
    M.nextRenderSpaceProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    logger.write('RENDER_SPACE_PROOF mode=' .. tostring(M.renderSpaceMode) ..
      ' fallbackAll=' .. tostring(M.renderSpaceFallbackAll == true) ..
      ' worldVisibleCount=' .. tostring(counts.world or 0) ..
      ' originAddVisibleCount=' .. tostring(counts.origin_add or 0) ..
      ' originSubVisibleCount=' .. tostring(counts.origin_sub or 0) ..
      ' pointCount=' .. tostring(#points) ..
      ' originShift=' .. (M.originShift and vecText(M.originShift) or 'none') ..
      ' firstPoint=' .. (firstPoint and vecText(firstPoint) or 'none') ..
      ' mainCameraWorldVisible=' .. (firstPoint and mainCameraVisibleText(firstPoint, 3.0) or 'none') ..
      ' projectWorld=' .. (firstPoint and modeProjectionText(firstPoint, 'world') or 'none') ..
      ' projectOriginAdd=' .. (firstPoint and modeProjectionText(firstPoint, 'origin_add') or 'none') ..
      ' projectOriginSub=' .. (firstPoint and modeProjectionText(firstPoint, 'origin_sub') or 'none'))
  end
end

local function logAmbiguousRenderSpaceSkip()
  local now = os.clock and os.clock() or 0
  if now < (M.nextRenderSpaceSkipProofAt or 0) then return end
  M.nextRenderSpaceSkipProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
  logger.write('RENDER_SPACE_AMBIGUOUS_SKIP_PROOF renderSpaceFallbackAll=true' ..
    ' mode=' .. tostring(M.renderSpaceMode or 'unknown') ..
    ' originShift=' .. (M.originShift and vecText(M.originShift) or 'none') ..
    ' drawCount=0' ..
    ' renderModeCount=0')
end

local function buildQuad(tile, widthScale, lengthScale, mode)
  if not tile or
      not finiteVec(tile.pos) or
      not directionVec(tile.forward) or
      not directionVec(tile.right) or
      not directionVec(tile.normal) then
    return nil
  end

  local n = math3d.norm(tile.normal, math3d.vec(0, 1, 0))
  local lift = tonumber(settings.QUAD_LINE_LIFT_M) or 0.012
  local center = math3d.add(tile.pos, math3d.mul(n, lift))
  local f = math3d.norm(tile.forward, math3d.vec(0, 0, 1))
  local r = math3d.norm(tile.right, math3d.vec(1, 0, 0))
  local halfW = (tonumber(tile.tileWidthM) or settings.TILE_WIDTH_M) * (tonumber(widthScale) or 1) * 0.5
  local halfL = (tonumber(tile.tileLengthM) or settings.TILE_LENGTH_M) * (tonumber(lengthScale) or 1) * 0.5
  local tiltRatio = math.max(0, math.min(1.25, tonumber(tile.requiredDecelRatio) or 0))
  local yellow = tonumber(settings.YELLOW_RATIO) or 0.14
  local red = math.max(yellow + 0.01, tonumber(settings.RED_RATIO) or 0.58)
  local tiltIntensity = math.max(0, math.min(1, (tiltRatio - yellow) / (red - yellow)))
  if tile.kind == 'yellow' then tiltIntensity = math.max(tiltIntensity, 0.5) end
  if tile.kind == 'red' then tiltIntensity = 1.0 end
  local maxTiltDeg = math.max(0, math.min(15.0, tonumber(settings.BRAKE_TILT_MAX_DEG) or 0))
  local maxDelta = math.max(0, math.min(0.035, tonumber(settings.BRAKE_TILT_MAX_DELTA_M) or 0.025))
  local rearMinLift = math.max(0, math.min(0.025, tonumber(settings.BRAKE_TILT_REAR_MIN_LIFT_M) or 0.006))
  local angleDelta = math.tan(math.rad(maxTiltDeg * tiltIntensity)) * halfL * 2.0
  local rearSafeDelta = math.max(0, (lift - rearMinLift) * 2.0)
  local tiltDelta = math.min(maxDelta, rearSafeDelta, angleDelta)
  local rear = math3d.sub(math3d.sub(center, math3d.mul(f, halfL)), math3d.mul(n, tiltDelta * 0.5))
  local front = math3d.add(math3d.add(center, math3d.mul(f, halfL)), math3d.mul(n, tiltDelta * 0.5))
  local rearLeft = math3d.sub(rear, math3d.mul(r, halfW))
  local rearRight = math3d.add(rear, math3d.mul(r, halfW))
  local frontRight = math3d.add(front, math3d.mul(r, halfW))
  local frontLeft = math3d.sub(front, math3d.mul(r, halfW))
  return asDrawVec3(rearLeft, mode), asDrawVec3(frontLeft, mode), asDrawVec3(frontRight, mode), asDrawVec3(rearRight, mode)
end

local function tileHalfLengthM(tile, lengthScale)
  return (tonumber(tile and tile.tileLengthM) or settings.TILE_LENGTH_M) *
    (tonumber(lengthScale) or 1) * 0.5
end

local function tileRearEdgeForwardM(tile, car, lengthScale)
  if not tile or not car or not finiteVec(tile.pos) or not finiteVec(car.pos) or not directionVec(car.forward) then
    return nil
  end
  local centerForwardM = math3d.dot(math3d.sub(tile.pos, car.pos), car.forward)
  return centerForwardM - tileHalfLengthM(tile, lengthScale)
end

fmt = function(value)
  return string.format('%.3f', tonumber(value) or 0)
end

screenPointText = function(point)
  local ok, x, y = pcall(function()
    return tonumber(point and (point.x or point[1])), tonumber(point and (point.y or point[2]))
  end)
  if not ok or not x or not y or x ~= x or y ~= y then return 'none' end
  if x == math.huge or y == math.huge or x == -math.huge or y == -math.huge then return 'inf' end
  return string.format('%.0f,%.0f', x, y)
end

local function drawShaderedTile(tile, options, p1, p2, p3, p4)
  if not render or not render.shaderedQuad then return false end
  local reusedPassDepth = options and options._lineDepthReady == true
  local depthApplied, depthName
  if reusedPassDepth then
    depthApplied, depthName = true, options and options._lineDepthName or M.quadDepthMode
  else
    depthApplied, depthName = applyLinePaintDepthMode()
  end
  M.quadDepthMode = depthApplied and depthName or 'unavailable'
  if settings.QUAD_LINE_DEPTH_READ_ONLY and not depthApplied then
    logger.once('quad-depth-mode-unavailable', 'RENDER_QUAD_DEPTH_MODE_UNAVAILABLE requested=' ..
      tostring(settings.LINE_DEPTH_OCCLUSION_MODE or 'ReadOnlyLessEqual'))
    return false
  end
  local ok, result = pcall(function()
    return render.shaderedQuad({
      p1 = p1,
      p2 = p2,
      p3 = p3,
      p4 = p4,
      async = true,
      cacheKey = shaderCacheKeyFor(tile),
      depthMode = linePaintDepthMode(),
      values = shaderValuesFor(tile, options.opacity),
      shader = QUAD_SHADER,
    })
  end)
  if not reusedPassDepth then resetLinePaintDepthMode() end
  if not ok then logger.once('shadered-quad-failed', 'RENDER_SHADERED_QUAD_FAILED ' .. tostring(result)) end
  return ok and result ~= false
end

local function drawQuadTile(tile, options, p1, p2, p3, p4, opacityScale)
  if not render or not render.quad then return false end
  local reusedPassDepth = options and options._lineDepthReady == true
  local depthApplied, depthName
  if reusedPassDepth then
    depthApplied, depthName = true, options and options._lineDepthName or M.quadDepthMode
  else
    depthApplied, depthName = applyLinePaintDepthMode()
  end
  M.quadDepthMode = depthApplied and depthName or 'unavailable'
  if settings.QUAD_LINE_DEPTH_READ_ONLY and not depthApplied then
    logger.once('quad-fallback-depth-mode-unavailable', 'RENDER_QUAD_FALLBACK_DEPTH_MODE_UNAVAILABLE requested=' ..
      tostring(settings.LINE_DEPTH_OCCLUSION_MODE or 'ReadOnlyLessEqual'))
    return false
  end
  local ok, result = pcall(function()
    local opacity = (tonumber(options.opacity) or settings.OPACITY) * (tonumber(opacityScale) or 1.0)
    return render.quad(p1, p2, p3, p4, colorFor(tile, opacity))
  end)
  if not reusedPassDepth then resetLinePaintDepthMode() end
  if not ok then logger.once('render-quad-failed', 'RENDER_QUAD_FAILED ' .. tostring(result)) end
  return ok and result ~= false
end

local function neonExtraPassCount(tile)
  local kind = tile and (tile.visualKind or tile.kind)
  if kind == 'red' then return 2 end
  if kind == 'yellow' then return 2 end
  return 1
end

local function drawNeonTile(tile, options, p1, p2, p3, p4)
  local shaderDrawn = drawShaderedTile(tile, options, p1, p2, p3, p4)
  local quadDrawn = false
  local extraPasses = neonExtraPassCount(tile)
  for _ = 1, extraPasses do
    if drawQuadTile(tile, options, p1, p2, p3, p4, 0.72) then
      quadDrawn = true
    end
  end
  return shaderDrawn or quadDrawn,
    shaderDrawn and 'render.shaderedQuadNeon' or (quadDrawn and 'render.quadNeonFallback' or 'no_backend'),
    extraPasses
end

local function safetySpineEndpoints(tile, options, mode)
  if not tile or not finiteVec(tile.pos) or not directionVec(tile.forward) or not directionVec(tile.normal) then
    return nil
  end
  local f = math3d.norm(tile.forward, math3d.vec(0, 0, 1))
  local n = math3d.norm(tile.normal, math3d.vec(0, 1, 0))
  local halfL = (tonumber(tile.tileLengthM) or settings.TILE_LENGTH_M) * (tonumber(options.lengthScale) or 1) * 0.5
  local height = tonumber(settings.SAFETY_SPINE_HEIGHT_M) or 0.25
  local center = math3d.add(tile.pos, math3d.mul(n, height))
  return asDrawVec3(math3d.sub(center, math3d.mul(f, halfL)), mode),
    asDrawVec3(math3d.add(center, math3d.mul(f, halfL)), mode)
end

local function lineSegmentEndpoints(tile, options, mode, lateralOffset)
  if not tile or not finiteVec(tile.pos) or not directionVec(tile.forward) or
      not directionVec(tile.right) or not directionVec(tile.normal) then
    return nil
  end
  local f = math3d.norm(tile.forward, math3d.vec(0, 0, 1))
  local r = math3d.norm(tile.right, math3d.vec(1, 0, 0))
  local n = math3d.norm(tile.normal, math3d.vec(0, 1, 0))
  local halfL = (tonumber(tile.tileLengthM) or settings.TILE_LENGTH_M) *
    (tonumber(options.lengthScale) or 1) * 0.58
  local lift = tonumber(settings.LINE_LIFT_M) or 0.045
  local center = math3d.add(math3d.add(tile.pos, math3d.mul(n, lift)), math3d.mul(r, lateralOffset or 0))
  return asDrawVec3(math3d.sub(center, math3d.mul(f, halfL)), mode),
    asDrawVec3(math3d.add(center, math3d.mul(f, halfL)), mode)
end

local function drawLineSegmentTile(tile, options, mode)
  if not settings.LINE_SEGMENT_RENDERER_ENABLED or not render or not render.debugLine then return false end
  if not tile or not directionVec(tile.right) then return false end
  local reusedPassDepth = options and options._lineDepthReady == true
  local depthApplied, depthName
  if reusedPassDepth then
    depthApplied, depthName = true, options and options._lineDepthName or M.lineDepthMode
  else
    depthApplied, depthName = applyLinePaintDepthMode()
  end
  M.lineDepthMode = depthApplied and depthName or 'unavailable'
  if settings.LINE_DEPTH_READ_ONLY and not depthApplied then
    logger.once('line-depth-mode-unavailable', 'RENDER_LINE_DEPTH_MODE_UNAVAILABLE requested=' ..
      tostring(settings.LINE_DEPTH_OCCLUSION_MODE or 'ReadOnlyLessEqual'))
    return false
  end
  local stripeCount = math.max(1, math.floor((tonumber(settings.LINE_STRIPE_COUNT) or 1) + 0.5))
  local halfW = (tonumber(tile.tileWidthM) or settings.TILE_WIDTH_M) *
    (tonumber(options.widthScale) or 1) * 0.5
  local color = colorFor(tile, options.opacity)
  local drawn = 0
  for i = 1, stripeCount do
    local offset = 0
    if stripeCount > 1 then
      offset = -halfW + ((i - 1) / (stripeCount - 1)) * halfW * 2.0
    end
    local from, to = lineSegmentEndpoints(tile, options, mode, offset)
    if from then
      local ok = pcall(function() render.debugLine(from, to, color, color) end)
      if ok then drawn = drawn + 1 end
    end
  end
  if not reusedPassDepth then resetLinePaintDepthMode() end
  return drawn > 0
end

local function drawSafetySpine(tile, options, mode)
  if not settings.SAFETY_SPINE_VISIBLE or not render or not render.debugLine then return false end
  local from, to = safetySpineEndpoints(tile, options, mode)
  if not from then return false end
  local color = colorFor(tile, options.opacity)
  local ok = pcall(function() render.debugLine(from, to, color, color) end)
  return ok == true
end

local function canaryColor()
  return makeRgbm(0.0, 2.0, 0.30, 1.0)
end

local function canaryShadowColor()
  return makeRgbm(0, 0, 0, 0.55)
end

local function cameraCanaryColor()
  return makeRgbm(2.0, 0.0, 2.0, 1.0)
end

local function cameraCanaryAccentColor()
  return makeRgbm(0.0, 2.0, 0.20, 1.0)
end

local function reverseCanaryColor()
  return makeRgbm(2.0, 0.0, 2.0, 1.0)
end

vecText = function(v)
  return fmt(math3d.x(v)) .. ',' .. fmt(math3d.y(v)) .. ',' .. fmt(math3d.z(v))
end

local function vectorCopy(value)
  if not finiteVec(value) then return nil end
  return math3d.vec(math3d.x(value), math3d.y(value), math3d.z(value))
end

local function readCameraVec(toMethod, valueMethod, fallback)
  if ac and type(toMethod) == 'function' then
    local out = emptyVec3()
    local ok = pcall(function() toMethod(out) end)
    local copied = ok and vectorCopy(out) or nil
    if copied then return copied, true, 'to_api' end
  end

  if ac and type(valueMethod) == 'function' then
    local ok, result = pcall(function() return valueMethod() end)
    local copied = ok and vectorCopy(result) or nil
    if copied then return copied, true, 'value_api' end
  end

  local copiedFallback = vectorCopy(fallback)
  if copiedFallback then return copiedFallback, false, 'sim_fallback' end
  return fallback, false, 'missing'
end

local function readCameraBasis()
  local sim = nil
  if ac and ac.getSim then
    local ok, result = pcall(function() return ac.getSim() end)
    if ok then sim = result end
  end

  local posFallback = safe_struct.field(sim, 'cameraPosition', nil)
  local forwardFallback = safe_struct.field(sim, 'cameraLook', nil)
  local upFallback = safe_struct.field(sim, 'cameraUp', nil)
  local sideFallback = safe_struct.field(sim, 'cameraSide', nil)
  local pos, posApi, posSource = readCameraVec(ac and ac.getCameraPositionTo, ac and ac.getCameraPosition, posFallback)
  local forward, forwardApi, forwardSource = readCameraVec(ac and ac.getCameraForwardTo, ac and ac.getCameraForward, forwardFallback)
  local up, upApi, upSource = readCameraVec(ac and ac.getCameraUpTo, ac and ac.getCameraUp, upFallback)
  local side, sideApi, sideSource = readCameraVec(ac and ac.getCameraSideTo, ac and ac.getCameraSide, sideFallback)

  if not finiteVec(pos) or not directionVec(forward) then return nil end
  forward = math3d.norm(forward, math3d.vec(0, 0, 1))
  up = math3d.norm(up, math3d.vec(0, 1, 0))
  side = math3d.norm(side, math3d.cross(forward, up))
  if not directionVec(side) then side = math3d.norm(math3d.cross(forward, up), math3d.vec(1, 0, 0)) end
  if not directionVec(up) then up = math3d.norm(math3d.cross(side, forward), math3d.vec(0, 1, 0)) end

  return {
    pos = math3d.vec(math3d.x(pos), math3d.y(pos), math3d.z(pos)),
    forward = forward,
    up = up,
    side = side,
    posApi = posApi,
    forwardApi = forwardApi,
    upApi = upApi,
    sideApi = sideApi,
    posSource = posSource,
    forwardSource = forwardSource,
    upSource = upSource,
    sideSource = sideSource,
  }
end

local function projectedText(center)
  local renderProjected = 'unknown'
  if render and render.projectPoint then
    local okProjected, result = pcall(function() return render.projectPoint(asDrawVec3(center)) end)
    renderProjected = okProjected and screenPointText(result) or ('error:' .. tostring(result))
  end
  local uiProjected = 'unknown'
  if ui and ui.projectPoint then
    local okProjected, result = pcall(function() return ui.projectPoint(asRenderVec3(center), false) end)
    uiProjected = okProjected and screenPointText(result) or ('error:' .. tostring(result))
  end
  return renderProjected, uiProjected
end

local function fieldText(obj, key)
  if obj == nil then return 'nil' end
  local ok, value = pcall(function() return obj[key] end)
  if not ok or value == nil then return 'nil' end
  return tostring(value)
end

local function visibleText(center, radius)
  if not render or not render.isVisible then return 'unknown' end
  local modeVisible, modeText = isVisibleForMode(center, M.renderSpaceMode or 'world', radius)
  local worldVisible = 'unknown'
  local okVisible, result = pcall(function() return render.isVisible(asRenderVec3(center), radius or 2.0, false, false) end)
  if okVisible then worldVisible = tostring(result == true) else worldVisible = 'error:' .. tostring(result) end
  return tostring(modeVisible == true) .. '(mode=' .. tostring(M.renderSpaceMode or 'world') ..
    ',modeRaw=' .. tostring(modeText) .. ',world=' .. tostring(worldVisible) .. ')'
end

local function drawCameraRelativeCanary()
  M.lastCameraCanaryDrawn = false
  if not settings.VISIBLE_3D_CANARY_ENABLED or not render or not render.quad then return false end
  local basis = readCameraBasis()
  if not basis then
    logger.once('camera-3d-canary-no-basis', 'CAMERA_3D_CANARY_FAILED reason=no_camera_basis')
    return false
  end

  local distance = 7.0
  local width = 3.8
  local height = 1.35
  local center = math3d.add(math3d.add(basis.pos, math3d.mul(basis.forward, distance)), math3d.mul(basis.up, -0.65))
  local halfW = width * 0.5
  local halfH = height * 0.5
  local p1 = asDrawVec3(math3d.sub(math3d.sub(center, math3d.mul(basis.side, halfW)), math3d.mul(basis.up, halfH)))
  local p2 = asDrawVec3(math3d.add(math3d.sub(center, math3d.mul(basis.side, halfW)), math3d.mul(basis.up, halfH)))
  local p3 = asDrawVec3(math3d.add(math3d.add(center, math3d.mul(basis.side, halfW)), math3d.mul(basis.up, halfH)))
  local p4 = asDrawVec3(math3d.sub(math3d.add(center, math3d.mul(basis.side, halfW)), math3d.mul(basis.up, halfH)))

  local ok, err = pcall(function()
    render.quad(p1, p2, p3, p4, cameraCanaryColor())
    if render.rectangle then
      render.rectangle(asDrawVec3(center), asRenderVec3(basis.forward), width * 0.75, height * 0.35, cameraCanaryAccentColor())
    end
    if render.debugLine then
      render.debugLine(asDrawVec3(math3d.sub(center, math3d.mul(basis.side, halfW))), asDrawVec3(math3d.add(center, math3d.mul(basis.side, halfW))), canaryShadowColor(), cameraCanaryAccentColor())
      render.debugLine(asDrawVec3(math3d.sub(center, math3d.mul(basis.up, halfH))), asDrawVec3(math3d.add(center, math3d.mul(basis.up, halfH))), canaryShadowColor(), cameraCanaryColor())
    end
    if render.debugSphere then
      render.debugSphere(asDrawVec3(center), 0.35, cameraCanaryAccentColor())
    end
  end)
  if not ok then
    logger.once('camera-3d-canary-failed', 'CAMERA_3D_CANARY_FAILED ' .. tostring(err))
    return false
  end

  M.lastCameraCanaryDrawn = true
  local now = os.clock and os.clock() or 0
  if now >= (M.nextCameraCanaryProofAt or 0) then
    local renderProjected, uiProjected = projectedText(center)
    M.nextCameraCanaryProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    logger.write('CAMERA_3D_CANARY_PROOF drawn=true distanceM=' .. fmt(distance) ..
      ' renderVisible=' .. visibleText(center, 2.0) ..
      ' renderProjected=' .. tostring(renderProjected) ..
      ' uiProjected=' .. tostring(uiProjected) ..
      ' pos=' .. vecText(center) ..
      ' cameraPos=' .. vecText(basis.pos) ..
      ' cameraForward=' .. vecText(basis.forward) ..
      ' cameraUp=' .. vecText(basis.up) ..
      ' cameraSide=' .. vecText(basis.side) ..
      ' apiPosition=' .. tostring(basis.posApi == true) ..
      ' apiForward=' .. tostring(basis.forwardApi == true) ..
      ' apiUp=' .. tostring(basis.upApi == true) ..
      ' apiSide=' .. tostring(basis.sideApi == true) ..
      ' sourcePosition=' .. tostring(basis.posSource) ..
      ' sourceForward=' .. tostring(basis.forwardSource) ..
      ' sourceUp=' .. tostring(basis.upSource) ..
      ' sourceSide=' .. tostring(basis.sideSource) ..
      ' focusedCar=' .. fieldText(currentSim(), 'focusedCar') ..
      ' closelyFocusedCar=' .. fieldText(currentSim(), 'closelyFocusedCar') ..
      ' cameraMode=' .. fieldText(currentSim(), 'cameraMode') ..
      ' isReplayActive=' .. fieldText(currentSim(), 'isReplayActive'))
  end
  return true
end

local function drawCarDirectionProbe(car, sign, proofName, color)
  if not settings.VISIBLE_3D_CANARY_ENABLED or not render or not render.quad then return false end
  if not car or not finiteVec(car.pos) or not directionVec(car.forward) or not directionVec(car.right) or not directionVec(car.up) then return false end

  local distance = tonumber(settings.VISIBLE_3D_CANARY_DISTANCE_M) or 12.0
  local lift = tonumber(settings.VISIBLE_3D_CANARY_HEIGHT_M) or 1.2
  local width = (tonumber(settings.VISIBLE_3D_CANARY_WIDTH_M) or 3.0) * 0.70
  local height = (tonumber(settings.VISIBLE_3D_CANARY_HEIGHT_SIZE_M) or 1.2) * 0.70
  local f = math3d.mul(math3d.norm(car.forward, math3d.vec(0, 0, 1)), sign or 1)
  local r = math3d.norm(car.right, math3d.vec(1, 0, 0))
  local u = math3d.norm(car.up, math3d.vec(0, 1, 0))
  local center = math3d.add(math3d.add(car.pos, math3d.mul(f, distance)), math3d.mul(u, lift + 0.9))
  local halfW = width * 0.5
  local halfH = height * 0.5
  local p1 = asDrawVec3(math3d.sub(math3d.sub(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))
  local p2 = asDrawVec3(math3d.add(math3d.sub(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))
  local p3 = asDrawVec3(math3d.add(math3d.add(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))
  local p4 = asDrawVec3(math3d.sub(math3d.add(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))

  local ok = pcall(function()
    render.quad(p1, p2, p3, p4, color)
    if render.debugLine then
      render.debugLine(asDrawVec3(car.pos), asDrawVec3(center), canaryShadowColor(), color)
    end
  end)
  if not ok then return false end

  local now = os.clock and os.clock() or 0
  if now >= (M.nextCarDirectionProofAt or 0) then
    local renderProjected, uiProjected = projectedText(center)
    logger.write(proofName .. ' drawn=true sign=' .. tostring(sign or 1) ..
      ' distanceM=' .. fmt(distance) ..
      ' renderVisible=' .. visibleText(center, 2.0) ..
      ' renderProjected=' .. tostring(renderProjected) ..
      ' uiProjected=' .. tostring(uiProjected) ..
      ' pos=' .. vecText(center) ..
      ' carPos=' .. vecText(car.pos) ..
      ' carForward=' .. vecText(car.forward))
  end
  return true
end

local function drawCarRelativeCanary(car)
  M.lastCanaryDrawn = false
  if not settings.VISIBLE_3D_CANARY_ENABLED or not render or not render.quad then return false end
  if not car or not finiteVec(car.pos) or not directionVec(car.forward) or not directionVec(car.right) or not directionVec(car.up) then return false end

  local distance = tonumber(settings.VISIBLE_3D_CANARY_DISTANCE_M) or 12.0
  local lift = tonumber(settings.VISIBLE_3D_CANARY_HEIGHT_M) or 1.2
  local width = tonumber(settings.VISIBLE_3D_CANARY_WIDTH_M) or 3.0
  local height = tonumber(settings.VISIBLE_3D_CANARY_HEIGHT_SIZE_M) or 1.2
  local f = math3d.norm(car.forward, math3d.vec(0, 0, 1))
  local r = math3d.norm(car.right, math3d.vec(1, 0, 0))
  local u = math3d.norm(car.up, math3d.vec(0, 1, 0))
  local center = math3d.add(math3d.add(car.pos, math3d.mul(f, distance)), math3d.mul(u, lift))
  local halfW = width * 0.5
  local halfH = height * 0.5
  local p1 = asDrawVec3(math3d.sub(math3d.sub(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))
  local p2 = asDrawVec3(math3d.add(math3d.sub(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))
  local p3 = asDrawVec3(math3d.add(math3d.add(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))
  local p4 = asDrawVec3(math3d.sub(math3d.add(center, math3d.mul(r, halfW)), math3d.mul(u, halfH)))

  local ok, err = pcall(function()
    if render.debugSphere then
      render.debugSphere(asDrawVec3(center), 1.25, canaryColor())
    end
    render.quad(p1, p2, p3, p4, canaryColor())
    if render.debugLine then
      render.debugLine(asDrawVec3(math3d.sub(center, math3d.mul(r, halfW))), asDrawVec3(math3d.add(center, math3d.mul(r, halfW))), canaryShadowColor(), canaryColor())
      render.debugLine(asDrawVec3(math3d.sub(center, math3d.mul(u, halfH))), asDrawVec3(math3d.add(center, math3d.mul(u, halfH))), canaryShadowColor(), canaryColor())
    end
  end)
  if not ok then
    logger.once('visible-3d-canary-failed', 'VISIBLE_3D_CANARY_FAILED ' .. tostring(err))
    return false
  end

  M.lastCanaryDrawn = true
  local now = os.clock and os.clock() or 0
  if now >= (M.nextCanaryProofAt or 0) then
    local visible = 'unknown'
    if render.isVisible then visible = visibleText(center, 2.0) end
    local projected = 'unknown'
    if ui and ui.projectPoint then
      local okProjected, result = pcall(function() return ui.projectPoint(asRenderVec3(center), false) end)
      projected = okProjected and screenPointText(result) or ('error:' .. tostring(result))
    end
    M.nextCanaryProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    logger.write('VISIBLE_3D_CANARY_PROOF drawn=true distanceM=' .. fmt(distance) ..
      ' heightM=' .. fmt(lift) ..
      ' widthM=' .. fmt(width) ..
      ' renderVisible=' .. tostring(visible) ..
      ' projected=' .. tostring(projected) ..
      ' depthMode=Off pos=' .. fmt(math3d.x(center)) .. ',' .. fmt(math3d.y(center)) .. ',' .. fmt(math3d.z(center)))
  end
  return true
end

local function drawTile(tile, options, mode)
  local minAhead = tonumber(settings.LINE_MIN_AHEAD_M) or 0.0
  local distanceAhead = tonumber(tile and tile.distanceAheadM)
  if distanceAhead and distanceAhead < minAhead then
    return false, 'skipped:min_ahead', false
  end
  local carClearance = tonumber(settings.CAR_CLEARANCE_AHEAD_M) or 0.0
  if carClearance > 0 then
    local rearEdgeForwardM = tileRearEdgeForwardM(tile, options and (options.car or options.lastCar), options and options.lengthScale)
    local clearanceEpsilonM = 0.05
    if rearEdgeForwardM and rearEdgeForwardM + clearanceEpsilonM < carClearance then
      return false, 'skipped:car_clearance', false
    end
  end

  local p1, p2, p3, p4 = buildQuad(tile, options.widthScale, options.lengthScale, mode)
  local safety = drawSafetySpine(tile, options, mode)
  local renderMode = tostring(settings.LINE_RENDER_MODE or 'quad'):lower()
  M.lastLineRenderMode = renderMode

  if renderMode == 'neon' then
    if p1 then
      local drawn, backend = drawNeonTile(tile, options, p1, p2, p3, p4)
      if drawn then return true, backend .. ':' .. tostring(mode), safety end
    end
    local lineFallback = drawLineSegmentTile(tile, options, mode)
    return lineFallback or safety,
      lineFallback and ('render.debugLineStripFallback:' .. tostring(mode)) or (safety and 'render.debugLine' or 'no_backend'),
      safety
  end

  if renderMode == 'quad' or settings.FORCE_RENDER_QUAD then
    if p1 and drawQuadTile(tile, options, p1, p2, p3, p4) then
      return true, 'render.quad:' .. tostring(mode), safety
    end
    local lineFallback = drawLineSegmentTile(tile, options, mode)
    return lineFallback or safety,
      lineFallback and ('render.debugLineStripFallback:' .. tostring(mode)) or (safety and 'render.debugLine' or 'no_backend'),
      safety
  end

  local lineDrawn = drawLineSegmentTile(tile, options, mode)
  if lineDrawn then return true, 'render.debugLineStrip:' .. tostring(mode), safety end
  if renderMode == 'strip' then return safety, safety and 'render.debugLine' or 'no_backend', safety end

  if not p1 then return safety, safety and ('render.debugLine:' .. tostring(mode)) or 'invalid_geometry', safety end
  if drawShaderedTile(tile, options, p1, p2, p3, p4) then return true, 'render.shaderedQuad:' .. tostring(mode), safety end
  if drawQuadTile(tile, options, p1, p2, p3, p4) then return true, 'render.quad:' .. tostring(mode), safety end
  return safety, safety and 'render.debugLine' or 'no_backend', safety
end

local function renderTargetPoint(xBias, yBias)
  local width, height = 1920, 1080
  if render and render.getRenderTargetSize then
    local ok, size = pcall(function() return render.getRenderTargetSize() end)
    local x, y = vec2Components(ok and size or nil)
    if x and y and x > 0 and y > 0 then
      width, height = x, y
    end
  end
  return makeVec2(width * (tonumber(xBias) or 0.5), height * (tonumber(yBias) or 0.62)), width, height
end

local function normalizeHitNormal(normal)
  local copied = vectorCopy(normal)
  if copied and directionVec(copied) then return math3d.norm(copied, math3d.vec(0, 1, 0)) end
  return math3d.vec(0, 1, 0)
end

local function projectOntoPlane(direction, normal)
  if not directionVec(direction) or not directionVec(normal) then return nil end
  local projected = math3d.sub(direction, math3d.mul(normal, math3d.dot(direction, normal)))
  if not directionVec(projected) then return nil end
  return math3d.norm(projected, math3d.vec(0, 0, 1))
end

local function castVisibleTrackRay(xBias, yBias)
  if not render or not render.createPointRay then return nil end
  local point, width, height = renderTargetPoint(xBias, yBias)
  local okRay, ray = pcall(function() return render.createPointRay(point) end)
  if not okRay or not ray then return nil end

  local hit = emptyVec3()
  local normal = emptyVec3()
  local distance = -1
  local source = 'none'
  if physics and physics.raycastTrack and finiteVec(ray.pos) and directionVec(ray.dir) then
    local okPhysics, result = pcall(function() return physics.raycastTrack(ray.pos, ray.dir, 800, hit, normal) end)
    if okPhysics and tonumber(result) and tonumber(result) > 0 and finiteVec(hit) then
      distance = tonumber(result)
      source = 'physics.raycastTrack'
    end
  end

  if distance <= 0 then
    local okRayPhysics, result = pcall(function()
      if ray.physics then return ray:physics(hit, normal) end
      return -1
    end)
    if okRayPhysics and tonumber(result) and tonumber(result) > 0 and finiteVec(hit) then
      distance = tonumber(result)
      source = 'ray:physics'
    end
  end

  local hitPos = vectorCopy(hit)
  if distance > 0 and hitPos then
    return {
      pos = hitPos,
      normal = normalizeHitNormal(normal),
      distance = distance,
      source = source,
      screenPoint = point,
      targetWidth = width,
      targetHeight = height,
      ray = ray,
    }
  end

  return nil
end

local function screenRaySourceTiles(tiles)
  local out = {}
  for _, tile in ipairs(tiles or {}) do
    local d = tonumber(tile and tile.distanceAheadM)
    if not d or d >= -0.5 then out[#out + 1] = tile end
  end
  if #out == 0 then
    for _, tile in ipairs(tiles or {}) do out[#out + 1] = tile end
  end
  return out
end

local function drawScreenRayMarker(center, normal, forward)
  local basis = readCameraBasis()
  local viewDir = basis and math3d.sub(basis.pos, center) or math3d.mul(forward or normal, -1)
  pcall(function()
    if render.circle then
      render.circle(asDrawVec3(center, 'world'), asRenderVec3(viewDir), 0.42, cameraCanaryAccentColor(), canaryColor())
    end
    if render.debugSphere then
      render.debugSphere(asDrawVec3(math3d.add(center, math3d.mul(normal, 0.25)), 'world'), 0.25, cameraCanaryAccentColor())
    end
  end)
end

local function drawScreenRayFallbackLine(tiles, options, car)
  M.lastScreenRayDrawCount = 0
  if not settings.SCREEN_RAY_FALLBACK_ENABLED or not render or not render.quad or not render.createPointRay then
    return 0
  end

  local hit = castVisibleTrackRay(0.5, tonumber(settings.SCREEN_RAY_FALLBACK_Y) or 0.62) or
    castVisibleTrackRay(0.5, 0.70) or
    castVisibleTrackRay(0.5, 0.55)
  if not hit or not finiteVec(hit.pos) then return 0 end

  local normal = normalizeHitNormal(hit.normal)
  local basis = readCameraBasis()
  local forward = projectOntoPlane(car and car.forward, normal)
  if not forward and basis then forward = projectOntoPlane(basis.forward, normal) end
  if not forward and hit.ray then forward = projectOntoPlane(hit.ray.dir, normal) end
  forward = forward or math3d.vec(0, 0, 1)
  if basis and directionVec(basis.forward) and math3d.dot(forward, basis.forward) < 0 then
    forward = math3d.mul(forward, -1)
  end
  local right = math3d.norm(math3d.cross(normal, forward), math3d.vec(1, 0, 0))
  local sourceTiles = screenRaySourceTiles(tiles)
  local desired = math.max(6, math.floor((tonumber(settings.SCREEN_RAY_FALLBACK_TILES) or 24) + 0.5))
  local countLimit = math.min(desired, math.max(#sourceTiles, 16))
  local spacing = math.max(settings.TILE_LENGTH_M + settings.TILE_GAP_MIN_M, 3.2)
  local firstKind = 'green'
  local firstBackend = nil

  drawScreenRayMarker(math3d.add(hit.pos, math3d.mul(normal, 0.28)), normal, forward)
  for i = 1, countLimit do
    local src = sourceTiles[i] or sourceTiles[#sourceTiles] or {}
    local center = math3d.add(math3d.add(hit.pos, math3d.mul(normal, 0.16)), math3d.mul(forward, 0.8 + (i - 1) * spacing))
    local tile = {
      pos = center,
      forward = forward,
      right = right,
      normal = normal,
      distanceAheadM = tonumber(src.distanceAheadM) or ((i - 1) * spacing),
      targetSpeedKph = src.targetSpeedKph,
      requiredDecelRatio = src.requiredDecelRatio,
      kind = src.kind or (i > 14 and 'red' or i > 8 and 'yellow' or 'green'),
      placementMode = 'screen_ray_track_fallback',
      tileWidthM = src.tileWidthM or settings.TILE_WIDTH_M,
      tileLengthM = src.tileLengthM or settings.TILE_LENGTH_M,
    }
    local drawn, backend = drawTile(tile, options, 'world')
    if drawn then
      M.lastScreenRayDrawCount = M.lastScreenRayDrawCount + 1
      firstBackend = firstBackend or backend
      firstKind = tile.kind or firstKind
    end
  end

  local now = os.clock and os.clock() or 0
  if now >= (M.nextScreenRayProofAt or 0) then
    M.nextScreenRayProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    local renderProjected, uiProjected = projectedText(hit.pos)
    logger.write('SCREEN_RAY_LINE_PROOF drawCount=' .. tostring(M.lastScreenRayDrawCount) ..
      ' hitSource=' .. tostring(hit.source) ..
      ' rayDistanceM=' .. fmt(hit.distance or 0) ..
      ' screenPoint=' .. screenPointText(hit.screenPoint) ..
      ' targetWidth=' .. tostring(math.floor((hit.targetWidth or 0) + 0.5)) ..
      ' targetHeight=' .. tostring(math.floor((hit.targetHeight or 0) + 0.5)) ..
      ' hit=' .. vecText(hit.pos) ..
      ' normal=' .. vecText(normal) ..
      ' forward=' .. vecText(forward) ..
      ' firstKind=' .. tostring(firstKind) ..
      ' backend=' .. tostring(firstBackend or 'none') ..
      ' renderProjected=' .. tostring(renderProjected) ..
      ' uiProjected=' .. tostring(uiProjected) ..
      ' focusedCar=' .. fieldText(currentSim(), 'focusedCar') ..
      ' cameraMode=' .. fieldText(currentSim(), 'cameraMode'))
  end

  return M.lastScreenRayDrawCount
end

local function renderTargetProofValues()
  local skipTarget, skipReason, targetWidth, targetHeight, targetAspect,
    windowWidth, windowHeight, windowAspect, windowSource, minWindowFraction, aspectTolerance, dimensionTolerance,
    widthRatio, heightRatio, targetScale = shouldSkipRenderTarget()
  return {
    skipTarget = skipTarget,
    skipReason = skipReason,
    targetWidth = targetWidth,
    targetHeight = targetHeight,
    targetAspect = targetAspect,
    windowWidth = windowWidth,
    windowHeight = windowHeight,
    windowAspect = windowAspect,
    windowSource = windowSource,
    minWindowFraction = minWindowFraction,
    aspectTolerance = aspectTolerance,
    dimensionTolerance = dimensionTolerance,
    widthRatio = widthRatio,
    heightRatio = heightRatio,
    targetScale = targetScale,
  }
end

local function logRenderTargetSkipProof(targetProof)
  local now = os.clock and os.clock() or 0
  if now < (M.nextRenderTargetSkipProofAt or 0) then return end
  M.nextRenderTargetSkipProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
  logger.write('RENDER_TARGET_SKIP_PROOF reason=' .. tostring(targetProof.skipReason) ..
    ' width=' .. tostring(math.floor((targetProof.targetWidth or 0) + 0.5)) ..
    ' height=' .. tostring(math.floor((targetProof.targetHeight or 0) + 0.5)) ..
    ' aspect=' .. fmt(targetProof.targetAspect or 0) ..
    ' windowWidth=' .. tostring(math.floor((targetProof.windowWidth or 0) + 0.5)) ..
    ' windowHeight=' .. tostring(math.floor((targetProof.windowHeight or 0) + 0.5)) ..
    ' windowAspect=' .. fmt(targetProof.windowAspect or 0) ..
    ' windowSource=' .. tostring(targetProof.windowSource or 'unknown') ..
    ' minWindowFraction=' .. fmt(targetProof.minWindowFraction or 0) ..
    ' aspectTolerance=' .. fmt(targetProof.aspectTolerance or 0) ..
    ' dimensionTolerance=' .. fmt(targetProof.dimensionTolerance or 0) ..
    ' widthRatio=' .. fmt(targetProof.widthRatio or 0) ..
    ' heightRatio=' .. fmt(targetProof.heightRatio or 0) ..
    ' targetScale=' .. fmt(targetProof.targetScale or 0) ..
    ' minMainHeight=' .. tostring(settings.MIN_MAIN_RENDER_HEIGHT_PX) ..
    ' maxMainAspect=' .. tostring(settings.MAX_MAIN_RENDER_ASPECT))
end

local function renderLinePass(tiles, options, car, state, targetProof)
  chooseRenderSpace(tiles, car)
  if shouldSkipAmbiguousRenderSpace() then
    logAmbiguousRenderSpaceSkip()
    return 0
  end
  options._lineDepthReady = state.depth == true
  options._lineDepthName = state.depthName
  drawCameraRelativeCanary()
  drawCarRelativeCanary(car)
  drawCarDirectionProbe(car, 1, 'CAR_FORWARD_3D_CANARY_PROOF', canaryColor())
  drawCarDirectionProbe(car, -1, 'CAR_REVERSE_3D_CANARY_PROOF', reverseCanaryColor())
  local nowForDirectionProof = os.clock and os.clock() or 0
  if nowForDirectionProof >= (M.nextCarDirectionProofAt or 0) then
    M.nextCarDirectionProofAt = nowForDirectionProof + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
  end
  local firstDrawn = nil
  local firstBackend = nil
  local safetyDrawCount = 0
  local modes = renderModesToDraw()
  local renderModeCount = #modes
  for _, tile in ipairs(tiles or {}) do
    local tileDrawn = false
    for _, mode in ipairs(modes) do
      local drawn, backend, safety = drawTile(tile, options, mode)
      if safety then safetyDrawCount = safetyDrawCount + 1 end
      if drawn then
        tileDrawn = true
        firstDrawn = firstDrawn or tile
        firstBackend = firstBackend or backend
      end
    end
    if tileDrawn then
      M.lastDrawCount = M.lastDrawCount + 1
    end
  end
  local tileDrawCount = M.lastDrawCount
  local screenRayDrawCount = 0
  if tileDrawCount == 0 then
    screenRayDrawCount = drawScreenRayFallbackLine(tiles or {}, options, car)
  end
  local totalDrawCount = tileDrawCount + screenRayDrawCount
  M.lastDrawCount = totalDrawCount

  local now = os.clock and os.clock() or 0
  if totalDrawCount > 0 and now >= (M.nextProofAt or 0) then
    M.nextProofAt = now + math.max(0.5, tonumber(settings.RENDER_PROOF_INTERVAL_S) or 2.0)
    local backendProof = firstBackend == 'render.shaderedQuad' and 'backend=render.shaderedQuad' or ('backend=' .. tostring(firstBackend or 'none'))
    local depthModeProof = state.depthName == 'ReadOnlyLessEqual' and 'depthMode=ReadOnlyLessEqual' or
      ('depthMode=' .. tostring(state.depthName or 'unavailable'))
    logger.write('DYNAMIC_LINE_RENDER_PROOF drawCount=' .. tostring(totalDrawCount) ..
      ' tileDrawCount=' .. tostring(tileDrawCount) ..
      ' runNonce=' .. tostring(options and options.runNonce or '') ..
      ' firstDistanceAheadM=' .. fmt(firstDrawn and firstDrawn.distanceAheadM or 0) ..
      ' firstCarRearEdgeM=' .. fmt(tileRearEdgeForwardM(firstDrawn, car, options.lengthScale) or 0) ..
      ' firstKind=' .. tostring(firstDrawn and firstDrawn.kind or 'unknown') ..
      ' placementMode=' .. tostring(firstDrawn and firstDrawn.placementMode or 'unknown') ..
      ' ' .. backendProof ..
      ' fallbackBackend=' .. tostring(settings.FORCE_RENDER_QUAD and 'render.quad' or 'disabled') ..
      ' blendState=' .. tostring(state.blend == true) ..
      ' depthState=' .. tostring(state.depth == true) ..
      ' ' .. depthModeProof ..
      ' lineOcclusionMode=' .. tostring(settings.LINE_DEPTH_OCCLUSION_MODE or 'ReadOnlyLessEqual') ..
      ' cullState=' .. tostring(state.cull == true) ..
      ' transformState=' .. tostring(state.transform == true) ..
      ' renderSpaceMode=' .. tostring(M.renderSpaceMode) ..
      ' renderSpaceFallbackAll=' .. tostring(M.renderSpaceFallbackAll == true) ..
      ' renderModeCount=' .. tostring(renderModeCount) ..
      ' renderTargetReason=' .. tostring(targetProof.skipReason or 'unknown') ..
      ' renderTargetMainAccepted=' .. tostring(targetProof.skipTarget == false) ..
      ' targetWidth=' .. tostring(math.floor((targetProof.targetWidth or 0) + 0.5)) ..
      ' targetHeight=' .. tostring(math.floor((targetProof.targetHeight or 0) + 0.5)) ..
      ' targetAspect=' .. fmt(targetProof.targetAspect or 0) ..
      ' windowWidth=' .. tostring(math.floor((targetProof.windowWidth or 0) + 0.5)) ..
      ' windowHeight=' .. tostring(math.floor((targetProof.windowHeight or 0) + 0.5)) ..
      ' windowAspect=' .. fmt(targetProof.windowAspect or 0) ..
      ' widthRatio=' .. fmt(targetProof.widthRatio or 0) ..
      ' heightRatio=' .. fmt(targetProof.heightRatio or 0) ..
      ' targetScale=' .. fmt(targetProof.targetScale or 0) ..
      ' originShift=' .. (M.originShift and vecText(M.originShift) or 'none') ..
      ' brightnessM=' .. tostring(settings.COLOR_BRIGHTNESS_M) ..
      ' firstPaletteRgb=' .. (firstDrawn and (fmt(paletteFor(firstDrawn).r) .. ',' .. fmt(paletteFor(firstDrawn).g) .. ',' .. fmt(paletteFor(firstDrawn).b)) or 'none') ..
      ' firstPaletteMult=' .. fmt(firstDrawn and paletteFor(firstDrawn).mult or 0) ..
      ' firstRgbmBoost=' .. fmt(firstDrawn and rgbmBoostFor(firstDrawn) or 0) ..
      ' firstShaderHdrBoost=' .. fmt(firstDrawn and shaderValuesFor(firstDrawn, options.opacity).gHdrBoost or 0) ..
      ' firstShaderCacheKey=' .. tostring(firstDrawn and shaderCacheKeyFor(firstDrawn) or 0) ..
      ' lineRenderMode=' .. tostring(M.lastLineRenderMode or settings.LINE_RENDER_MODE) ..
      ' firstCueSeverity=' .. fmt(firstDrawn and firstDrawn.cueSeverity or 0) ..
      ' firstStraightSpeedCap=' .. tostring(firstDrawn and firstDrawn.straightSpeedCap == true) ..
      ' firstBrakeTargetSpeedKph=' .. fmt(firstDrawn and firstDrawn.brakeTargetSpeedKph or 0) ..
      ' firstBrakeTargetDistanceM=' .. fmt(firstDrawn and firstDrawn.brakeTargetDistanceM or 0) ..
      ' firstBrakeTargetSampleDistanceM=' .. fmt(firstDrawn and firstDrawn.brakeTargetSampleDistanceM or 0) ..
      ' firstBrakeTargetEntryLeadM=' .. fmt(firstDrawn and firstDrawn.brakeTargetEntryLeadM or 0) ..
      ' firstLineOffsetM=' .. fmt(firstDrawn and (firstDrawn.dynamicLineOffsetM or firstDrawn.racingLineOffsetM) or 0) ..
      ' firstLineOffsetScale=' .. fmt(firstDrawn and firstDrawn.lineOffsetScale or 1) ..
      ' lineStartM=' .. tostring(settings.LINE_START_M) ..
      ' lineMinAheadM=' .. tostring(settings.LINE_MIN_AHEAD_M) ..
      ' carClearanceAheadM=' .. tostring(settings.CAR_CLEARANCE_AHEAD_M) ..
      ' quadDepthMode=' .. tostring(M.quadDepthMode or 'unknown') ..
      ' quadLiftM=' .. tostring(settings.QUAD_LINE_LIFT_M) ..
      ' brakeTiltDeg=' .. tostring(settings.BRAKE_TILT_MAX_DEG) ..
      ' brakeTiltMaxDeltaM=' .. tostring(settings.BRAKE_TILT_MAX_DELTA_M) ..
      ' lineSegmentRenderer=' .. tostring(settings.LINE_SEGMENT_RENDERER_ENABLED == true) ..
      ' lineStripeCount=' .. tostring(settings.LINE_STRIPE_COUNT) ..
      ' lineDepthMode=' .. tostring(M.lineDepthMode or 'unknown') ..
      ' safetySpine=' .. tostring(safetyDrawCount > 0) ..
      ' safetySpineCount=' .. tostring(safetyDrawCount) ..
      ' screenRayFallback=' .. tostring(screenRayDrawCount > 0) ..
      ' screenRayDrawCount=' .. tostring(screenRayDrawCount) ..
      ' oneTilePerSample=true')
  end

  return totalDrawCount
end

function M.render(tiles, options)
  options = options or {}
  M.lastDrawCount = 0
  if not render or (not render.shaderedQuad and not render.quad and not render.debugLine) then
    logger.once('render-api-missing', 'RENDER_API_MISSING render.shaderedQuad/render.quad/render.debugLine unavailable')
    return 0
  end

  local targetProof = renderTargetProofValues()
  if targetProof.skipTarget then
    logRenderTargetSkipProof(targetProof)
    return 0
  end

  local car = options.car or options.lastCar
  local state = configureRenderState()
  local ok, result = xpcall(function()
    return renderLinePass(tiles, options, car, state, targetProof)
  end, function(err)
    if debug and debug.traceback then return debug.traceback(err) end
    return tostring(err)
  end)
  restoreRenderState(state)
  if ok then return tonumber(result) or M.lastDrawCount end
  logger.once('render-line-pass-error', 'DYNAMIC_LINE_RENDER_ERROR ' .. tostring(result))
  return 0
end

M.buildQuad = buildQuad
M.finiteVec = finiteVec
M.asRenderVec3 = asRenderVec3
M.configureRenderState = configureRenderState
M.drawShaderedTile = drawShaderedTile
M.drawSafetySpine = drawSafetySpine
M.drawCarRelativeCanary = drawCarRelativeCanary

return M
