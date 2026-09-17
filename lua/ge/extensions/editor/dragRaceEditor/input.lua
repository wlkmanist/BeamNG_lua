-- Mouse input for zone editing (same pattern as crawl editor).
local M = {}
local im = ui_imgui
local mouseInfo

local function updateMouseInfo()
  if not mouseInfo then mouseInfo = {} end
  if core_forest and core_forest.getForestObject then
    local fo = core_forest.getForestObject()
    if fo then fo:disableCollision() end
  end
  mouseInfo.camPos = core_camera.getPosition()
  mouseInfo.ray = getCameraMouseRay()
  mouseInfo.rayDir = vec3(mouseInfo.ray.dir)
  mouseInfo.rayCast = cameraMouseRayCast()
  if core_forest and core_forest.getForestObject then
    local fo = core_forest.getForestObject()
    if fo then fo:enableCollision() end
  end
  mouseInfo.valid = true
  local io = im and im.GetIO and im.GetIO()
  local inZoneEdit = editor and editor.editMode and editor.editMode.displayName == "Edit Drag Zone"
  local allowClick = not io or not io.WantCaptureMouse or inZoneEdit
  mouseInfo.down = im and im.IsMouseClicked and im.IsMouseClicked(0) and allowClick
  mouseInfo.hold = im and im.IsMouseDown and im.IsMouseDown(0) and allowClick
  mouseInfo.up = im and im.IsMouseReleased and im.IsMouseReleased(0) and allowClick
  local hitPos = mouseInfo.rayCast and vec3(mouseInfo.rayCast.pos) or (mouseInfo.camPos + mouseInfo.rayDir * 100)
  local hitNormal = mouseInfo.rayCast and vec3(mouseInfo.rayCast.normal) or vec3(0, 0, 1)
  if mouseInfo.down then
    mouseInfo.hold = false
    mouseInfo._downPos = hitPos
    mouseInfo._downNormal = hitNormal
  end
  if mouseInfo.hold then
    mouseInfo._holdPos = hitPos
    mouseInfo._holdNormal = hitNormal
  end
  if mouseInfo.up then
    mouseInfo._upPos = hitPos
    mouseInfo._upNormal = hitNormal
  end
end

M.getMouseInfo = function()
  return mouseInfo
end

M.updateMouseInfo = updateMouseInfo

return M
