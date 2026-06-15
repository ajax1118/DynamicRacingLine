local M = {}

local sentinelKeys = {}
local errorKeys = {}

local function bootstrapLog(message)
  local docs = os.getenv('USERPROFILE') or ''
  local path = docs ~= '' and (docs .. '/Documents/Assetto Corsa/logs/DynamicRacingLine.log') or 'DynamicRacingLine.log'
  pcall(function()
    local file = io.open(path, 'a')
    if not file then return end
    file:write(os.date('!%Y-%m-%dT%H:%M:%SZ') .. ' ' .. tostring(message) .. '\n')
    file:close()
  end)
end

local function loadSettings(entryName)
  local ok, loaded = pcall(require, 'src/settings')
  if ok and type(loaded) == 'table' then return loaded end
  bootstrapLog('DYNAMIC_RACING_LINE_SETTINGS_LOAD_ERROR entry=' .. tostring(entryName) ..
    ' error=' .. tostring(ok and 'settings_not_table' or loaded))
  return {}
end

local function callbackSentinel(name)
  if sentinelKeys[name] then return end
  sentinelKeys[name] = true
  bootstrapLog('DYNAMIC_RACING_LINE_CALLBACK_SENTINEL callback=' .. tostring(name))
end

local function callbackError(name, err)
  local key = tostring(name) .. ':' .. tostring(err)
  if errorKeys[key] then return end
  errorKeys[key] = true
  bootstrapLog('DYNAMIC_RACING_LINE_CALLBACK_ERROR callback=' .. tostring(name) .. ' error=' .. tostring(err))
end

local function installCallbacks(main, entryName)
  function script.update(dt)
    callbackSentinel('update')
    if not main then callbackError('update', 'main_not_loaded'); return end
    local ok, err = pcall(function() main.update(dt or 0) end)
    if not ok then callbackError('update', err) end
  end

  function script.windowMain(dt)
    callbackSentinel('windowMain')
    if not main then callbackError('windowMain', 'main_not_loaded'); return end
    local ok, err = pcall(function() main.windowMain(dt or 0) end)
    if not ok then callbackError('windowMain', err) end
  end

  function script.Draw3D()
    callbackSentinel('Draw3D')
    if not main then callbackError('Draw3D', 'main_not_loaded'); return end
    local ok, err = pcall(function() main.Draw3D() end)
    if not ok then callbackError('Draw3D', err) end
  end

  function script.draw3D()
    callbackSentinel('draw3D')
    if not main then callbackError('draw3D', 'main_not_loaded'); return end
    local ok, err = pcall(function() main.Draw3D() end)
    if not ok then callbackError('draw3D', err) end
  end

  function script.DrawHUD()
    callbackSentinel('DrawHUD')
    if not main then callbackError('DrawHUD', 'main_not_loaded'); return end
    local ok, err = pcall(function() main.DrawHUD() end)
    if not ok then callbackError('DrawHUD', err) end
  end

  function script.fullscreenUI()
    callbackSentinel('fullscreenUI')
    if not main then callbackError('fullscreenUI', 'main_not_loaded'); return end
    local ok, err = pcall(function() main.DrawHUD() end)
    if not ok then callbackError('fullscreenUI', err) end
  end
end

function M.install(entryName)
  entryName = tostring(entryName or 'unknown_entry')
  local settings = loadSettings(entryName)
  bootstrapLog('DYNAMIC_RACING_LINE_BOOTSTRAP_SENTINEL version=' .. tostring(settings.VERSION or 'unknown') ..
    ' buildId=' .. tostring(settings.BUILD_ID or 'unknown') .. ' entry=' .. entryName)

  local okMain, loadedMain = pcall(require, 'src/main')
  local main = okMain and loadedMain or nil
  if not okMain then
    bootstrapLog('DYNAMIC_RACING_LINE_MAIN_LOAD_ERROR entry=' .. entryName .. ' error=' .. tostring(loadedMain))
  end

  installCallbacks(main, entryName)
  return main ~= nil
end

M.bootstrapLog = bootstrapLog

return M
