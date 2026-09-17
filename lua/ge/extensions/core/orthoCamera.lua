-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local debugMode = false

local useWindowAspectRatio = true

local enabled
local left
local right
local top
local bottom
local nearClip
local farClip
local size = 1

local function updateValues()
  scenetree.OnlyGui:setOrthoMainView(
    nearClip,
    farClip,
    left,
    right,
    top,
    bottom,
    enabled
  )
end

local function updateAspectRatio()
  if useWindowAspectRatio then
    local resolutionString = extensions.core_settings_settings.getValue("GraphicDisplayResolutions")
    local w, h = 1280, 720
    if resolutionString and resolutionString ~= "" then
      w, h = resolutionString:match("(%d+)%s+(%d+)")
      w = tonumber(w)
      h = tonumber(h)
    end

    local aspect = (h ~= 0) and (w / h) or 16/9
    -- horizontal size scales with aspect, vertical is 'size'
    local halfH = size * 0.5
    local halfW = size * aspect * 0.5
    left, right = -halfW, halfW
    bottom, top = -halfH, halfH
  end
end

local function enable(_enabled, options)
  options = options or {}
  if options.useWindowAspectRatio ~= nil then
    useWindowAspectRatio = options.useWindowAspectRatio
  else
    useWindowAspectRatio = true
  end
  enabled = _enabled
  left, right, top, bottom, nearClip, farClip, size = options.left or -1, options.right or 1, options.top or 1, options.bottom or -1, options.nearClip or 1, options.farClip or 5000, options.size or 1

  updateAspectRatio()

  scenetree.OnlyGui:setOrthoMainView(
    nearClip,
    farClip,
    left,
    right,
    top,
    bottom,
    enabled
  )
end

local function setOptions(options)
  options = options or {}
  size = options.size or 1
  nearClip = options.nearClip or 1
  farClip = options.farClip or 5000

  updateAspectRatio()
  updateValues()
end

local function getSize()
  return size
end

local function onWindowResized(size)
  updateAspectRatio()
  updateValues()
end

local onlyGuiOrthoDebug = {
  nearClip = 1,
  farClip  = 1000,
  left     = -1,
  right    = 1,
  top      = 1,
  bottom   = -1,
  enabled  = false,
  keepAspect = true,
  size     = 1
}

local function onUpdate(dtReal, dtSim, dtRaw)
  local im = ui_imgui
  if not im or not debugMode or not scenetree or not scenetree.OnlyGui then return end

  if not im.Begin("OnlyGui OrthoMainView") then
    im.End()
    return
  end

  local changed = false

  -- Near clip
  local nearPtr = im.FloatPtr(onlyGuiOrthoDebug.nearClip)
  im.PushItemWidth(120)
  if im.InputFloat("Near clip", nearPtr, 1.0, 10.0, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
    onlyGuiOrthoDebug.nearClip = nearPtr[0]
    changed = true
  end

  -- Far clip
  local farPtr = im.FloatPtr(onlyGuiOrthoDebug.farClip)
  if im.InputFloat("Far clip", farPtr, 1.0, 10.0, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
    onlyGuiOrthoDebug.farClip = farPtr[0]
    changed = true
  end

  -- Keep aspect ratio toggle
  local keepAspectPtr = im.BoolPtr(onlyGuiOrthoDebug.keepAspect)
  if im.Checkbox("Keep aspect ratio", keepAspectPtr) then
    onlyGuiOrthoDebug.keepAspect = keepAspectPtr[0]
    changed = true
  end

  -- Either edit size (aspect-locked) or full bounds
  if onlyGuiOrthoDebug.keepAspect then
    local sizePtr = im.FloatPtr(onlyGuiOrthoDebug.size)
    if im.InputFloat("Size", sizePtr, 0.1, 1.0, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
      onlyGuiOrthoDebug.size = sizePtr[0]
      changed = true
    end
  else
    -- Left
    local leftPtr = im.FloatPtr(onlyGuiOrthoDebug.left)
    if im.InputFloat("Left", leftPtr, 1.0, 10.0, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
      onlyGuiOrthoDebug.left = leftPtr[0]
      changed = true
    end

    -- Right
    local rightPtr = im.FloatPtr(onlyGuiOrthoDebug.right)
    if im.InputFloat("Right", rightPtr, 1.0, 10.0, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
      onlyGuiOrthoDebug.right = rightPtr[0]
      changed = true
    end

    -- Top
    local topPtr = im.FloatPtr(onlyGuiOrthoDebug.top)
    if im.InputFloat("Top", topPtr, 1.0, 10.0, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
      onlyGuiOrthoDebug.top = topPtr[0]
      changed = true
    end

    -- Bottom
    local bottomPtr = im.FloatPtr(onlyGuiOrthoDebug.bottom)
    if im.InputFloat("Bottom", bottomPtr, 1.0, 10.0, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
      onlyGuiOrthoDebug.bottom = bottomPtr[0]
      changed = true
    end
  end

  -- Enable
  local enabledPtr = im.BoolPtr(onlyGuiOrthoDebug.enabled)
  if im.Checkbox("Enable", enabledPtr) then
    onlyGuiOrthoDebug.enabled = enabledPtr[0]
    changed = true
  end

  if changed then
    local leftVal, rightVal, topVal, bottomVal = onlyGuiOrthoDebug.left, onlyGuiOrthoDebug.right, onlyGuiOrthoDebug.top, onlyGuiOrthoDebug.bottom

    enable(onlyGuiOrthoDebug.enabled, {
      left = leftVal,
      right = rightVal,
      top = topVal,
      bottom = bottomVal,
      nearClip = onlyGuiOrthoDebug.nearClip,
      farClip = onlyGuiOrthoDebug.farClip,
      useWindowAspectRatio = onlyGuiOrthoDebug.keepAspect,
      size = onlyGuiOrthoDebug.size,
    })
  end
  im.End()
end

M.onWindowResized = onWindowResized

M.enable = enable
M.setOptions = setOptions
M.getSize = getSize
M.onUpdate = onUpdate

return M
