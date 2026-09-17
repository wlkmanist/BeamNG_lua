-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
C.__index = C

function C:init()
  self.isGlobal = true
  self.runningOrder = 1
  self.isFilter = true
  self.hidden = true
end

-- Push a non-main camera context to its own RenderView (the player view goes
-- through the C++ main-camera path below). The view's resolution / texture target
-- are owned by whoever created the context; here we only drive the camera each frame.
local function updateRenderView(name, res)
  if not RenderViewManagerInstance then return end
  local rv = RenderViewManagerInstance:getView(name)
  if not rv then return end -- view not set up (yet); nothing to drive
  local mat = QuatF(res.rot.x, res.rot.y, res.rot.z, res.rot.w):getMatrix()
  mat:setPosition(res.pos)
  rv.cameraMatrix = mat
  local resol = rv.resolution
  local aspect = (resol and resol.y > 0) and (resol.x / resol.y) or (16 / 9)
  if res.ortho then
    -- size the ortho box to frame the same area the perspective view would at the target distance,
    -- so the fov slider keeps zooming and switching projection doesn't jump the scale
    local dx, dy, dz = res.pos.x - res.targetPos.x, res.pos.y - res.targetPos.y, res.pos.z - res.targetPos.z
    local halfH = math.tan(math.rad(res.fov) * 0.5) * math.sqrt(dx * dx + dy * dy + dz * dz)
    local halfW = halfH * aspect
    rv.frustum = Frustum.constructOrtho(-halfW, halfW, halfH, -halfH, res.nearClip or 0.1, 2000)
  else
    rv.frustum = Frustum.construct(false, math.rad(res.fov), aspect, res.nearClip or 0.1, 2000)
  end
  rv.isOrtho = res.ortho == true
  rv.fov = res.fov
end

local gameNotified
function C:update(data)
  -- extra contexts render to their own RenderView, independent of level/openxr/main
  if data.renderView and data.renderView ~= "main" then
    if levelLoaded then updateRenderView(data.renderView, data.res) end
    return
  end

  if not levelLoaded then
    if data.openxrSessionRunning then OpenXR.setGeluaCameraPosRot(0, 0, 0, 0, 0, 0, 1) end
    if not gameNotified then
      log("W", "", "No camera available, no level loaded either")
      gameNotified = true
    end
    return
  end
  gameNotified = nil

  if data.openxrSessionRunning then
    OpenXR.setGeluaCameraPosRot(
      data.res.pos.x, data.res.pos.y, data.res.pos.z,
      data.res.rot.x, data.res.rot.y, data.res.rot.z, data.res.rot.w
    )

    local posX, posY, posZ, rotX, rotY, rotZ, rotW = OpenXR.getCameraPosRotPredictedXYZXYZW()
    data.res.pos:setAddXYZ(posX, posY, posZ)
    data.res.rot:setMulXYZW(rotX, rotY, rotZ, rotW, data.res.rot.x, data.res.rot.y, data.res.rot.z, data.res.rot.w)
  end

  setCameraPosRotFovNearClipC(
    data.res.pos.x, data.res.pos.y, data.res.pos.z,
    data.res.rot.x, data.res.rot.y, data.res.rot.z, data.res.rot.w,
    data.res.fov,
    data.res.nearClip
  )
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
