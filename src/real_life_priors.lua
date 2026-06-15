local settings = require('src/settings')
local M = {}

local cache = {}

local function numeric(value, fallback, lo, hi)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then
    number = fallback
  end
  if lo and number < lo then return lo end
  if hi and number > hi then return hi end
  return number
end

local function normId(value)
  value = tostring(value or ''):lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if value == '' then return 'unknown' end
  return value
end

local function parseJsonFile(path)
  if not io or not io.load or not JSON or not JSON.parse then return nil end
  local loaded, data = pcall(function() return io.load(path, nil) end)
  if not loaded or not data or data == '' then return nil end
  local ok, parsed = pcall(function() return JSON.parse(data) end)
  if ok and type(parsed) == 'table' then return parsed end
  return nil
end

local function assettoRoot()
  if not ac or not ac.getFolder or not ac.FolderID or not ac.FolderID.Root then return nil end
  local ok, root = pcall(function() return ac.getFolder(ac.FolderID.Root) end)
  if ok and root and root ~= '' then return tostring(root):gsub('[\\/]+$', '') end
  return nil
end

local function priorPath(id)
  return string.format('configs/real_life_priors/%s.json', normId(id))
end

local function installedPriorPath(root, id)
  return string.format('%s/apps/lua/DynamicRacingLine/configs/real_life_priors/%s.json', root, normId(id))
end

local function priorPaths(id)
  local paths = {}
  local root = assettoRoot()
  if root then paths[#paths + 1] = installedPriorPath(root, id) end
  paths[#paths + 1] = priorPath(id)
  return paths
end

local function validatePrior(raw, key)
  if type(raw) ~= 'table' then return nil end
  local prior = raw.real_life_prior or raw.realLifePrior or raw
  if type(prior) ~= 'table' then return nil end

  local corneringG = numeric(prior.cornering_g or prior.corneringG, 0.0, 0.0, 4.5)
  local brakeG = numeric(prior.brake_decel_g or prior.brakeG or prior.brake_g, 0.0, 0.0, settings.MAX_DYNAMIC_BRAKE_G)
  local hasAero = prior.speed_aero_strength ~= nil or prior.speedAeroStrength ~= nil
  local speedAeroStrength = hasAero and numeric(prior.speed_aero_strength or prior.speedAeroStrength, 0.0, 0.0, 0.30) or nil
  if corneringG <= 0.0 and brakeG <= 0.0 and speedAeroStrength == nil then return nil end

  return {
    id = tostring(raw.id or prior.id or key or 'unknown'),
    cornering_g = corneringG > 0.0 and corneringG or nil,
    brake_decel_g = brakeG > 0.0 and brakeG or nil,
    speed_aero_strength = speedAeroStrength,
    confidence = numeric(prior.confidence, settings.CAPABILITY_REAL_LIFE_PRIOR_CONFIDENCE, 0.35, 0.62),
    source = 'real_life_prior_file',
    sourceDetail = 'real_life_prior_file:' .. tostring(key or 'unknown'),
  }
end

function M.read(carId)
  local key = normId(carId)
  if key == 'unknown' then return nil end
  if cache[key] ~= nil then
    if cache[key] == false then return nil end
    return cache[key]
  end

  for _, path in ipairs(priorPaths(key)) do
    local parsed = parseJsonFile(path)
    local prior = validatePrior(parsed, key)
    if prior then
      cache[key] = prior
      return prior
    end
  end

  cache[key] = false
  return nil
end

M.validatePrior = validatePrior
M.parseJsonFile = parseJsonFile
M.installedPriorPath = installedPriorPath

return M
