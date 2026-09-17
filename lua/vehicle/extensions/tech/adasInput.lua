-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local pedalKeys = {"throttle", "brake", "parkingbrake"}

local function applyFilter(checkResult, key)
  if checkResult then
    input.setAllowedInputSource(key, 'adas', true)
    input.setAllowedInputSource(key, 'local', false)
  else
    input.setAllowedInputSource(key, 'local', true)
    input.setAllowedInputSource(key, 'adas', false)
  end
  return checkResult
end

local function filter(val, key)
  if key == 'throttle' then
    return applyFilter((val < (input.lastInputs["local"][key] or 1)), key)
  elseif key == 'brake' then
    return applyFilter((val > (input.lastInputs["local"][key] or 0)), key)
  else
    return true
  end
end

local function setAiEnabled(enabled)
  for _, key in ipairs(pedalKeys) do
    input.setAllowedInputSource(key, "local", true)
    input.setAllowedInputSource(key, "adas", true)
    input.event(key, 0, 1, nil, nil, nil, "ai")
    input.setAllowedInputSource(key, "ai", enabled)
  end
end

local function applySafe(value, key)
  if not filter(value, key) then return false end
  if key == 'steering' then
    hydros.setExternalForce(value)
  else
    input.event(key, value, 1, nil, nil, nil, 'adas')
  end
  return true
end

local function applyStandard(throttle, brake)
  input.event('throttle', throttle, 1, nil, nil, nil, 'adas')
  input.event('brake', brake, 1, nil, nil, nil, 'adas')
  return true
end

local function apply(a, b, mode)
  mode = mode or "safe"

  if mode == "safe" then
    return applySafe(a, b)
  elseif mode == "standard" then
    return applyStandard(a, b)
  else
    return false
  end
end

local function onReset()
  setAiEnabled(true)
end

local function onUnload()
  setAiEnabled(true)
end

-- Public interface
M.apply = apply
M.setAiEnabled = setAiEnabled
M.onReset = onReset
M.onUnload = onUnload

return M
