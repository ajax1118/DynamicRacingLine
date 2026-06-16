local settings = require('src/settings')
local M = { onceKeys = {} }

local function logPath()
  local docs = os.getenv('USERPROFILE') or ''
  if docs == '' then return settings.LOG_NAME end
  return docs .. '/Documents/Assetto Corsa/logs/' .. settings.LOG_NAME
end

function M.write(message)
  local line = os.date('!%Y-%m-%dT%H:%M:%SZ') .. ' ' .. tostring(message) .. '\n'
  pcall(function()
    local file = io.open(logPath(), 'a')
    if not file then return end
    local ok, err = pcall(function() file:write(line) end)
    file:close()
    if not ok then error(err) end
  end)
end

function M.once(key, message)
  key = tostring(key or message or 'once')
  if M.onceKeys[key] then return end
  M.onceKeys[key] = true
  M.write(message)
end

function M.clear()
  pcall(function()
    local file = io.open(logPath(), 'w')
    if not file then return end
    local ok, err = pcall(function() file:write('') end)
    file:close()
    if not ok then error(err) end
  end)
  M.onceKeys = {}
end

return M
