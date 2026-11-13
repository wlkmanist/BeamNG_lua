-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
C.__index = C

local splitScreenReferenceAspect = 16 / 9
local splitScreenFovCompensation = 0.33
-- local splitScreenFovDebug = {}

function C:init()
  self.isGlobal = true
  self.runningOrder = 1
  self.isFilter = true
  self.hidden = true
end

-- Camera modes choose the base vertical FOV. Narrow split-screen views widen it
-- slightly so their horizontal visibility is not excessively cropped.
local function compensateNarrowSplitScreenFov(name, fov)
  if string.sub(name, 1, 11) ~= "splitscreen" or not render_splitScreen or not render_splitScreen.getCurrentConfiguration() then
    return fov
  end

  local renderView = RenderViewManagerInstance:getView(name)
  local resolution = renderView and renderView.resolution
  if not resolution or resolution.x <= 0 or resolution.y <= 0 then return fov end

  local aspect = resolution.x / resolution.y
  if aspect >= splitScreenReferenceAspect then return fov end

  -- local originalFov = fov
  local targetFov = math.deg(2 * math.atan(math.tan(math.rad(fov) * 0.5) * splitScreenReferenceAspect / aspect))
  fov = fov + (targetFov - fov) * splitScreenFovCompensation
  -- local percentChange = originalFov ~= 0 and (fov - originalFov) / originalFov * 100 or 0
  -- local debugText = string.format("Split-screen FOV [%s]: %.2f -> %.2f (%+.1f%%)", name, originalFov, fov, percentChange)
  -- if splitScreenFovDebug[name] ~= debugText then
  --   print(debugText)
  --   splitScreenFovDebug[name] = debugText
  -- end
  return fov
end

-- Push a non-main camera context to its own RenderView (the player view goes
-- through the C++ main-camera path below). The view's resolution / texture target
-- are owned by whoever created the context; here we only drive the camera each frame.
local function updateRenderView(name, res)
  if not RenderViewManagerInstance then return end
  local fov = compensateNarrowSplitScreenFov(name, res.fov)

  local ortho = res.ortho == true
  local orthoHalfHeight = 0
  if ortho then
    -- size the ortho box to frame the same area the perspective view would at the target distance,
    -- so the fov slider keeps zooming and switching projection doesn't jump the scale
    local dx, dy, dz = res.pos.x - res.targetPos.x, res.pos.y - res.targetPos.y, res.pos.z - res.targetPos.z
    orthoHalfHeight = math.tan(math.rad(fov) * 0.5) * math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  RenderViewManagerInstance:updateViewCamera(name,
    res.pos.x, res.pos.y, res.pos.z,
    res.rot.x, res.rot.y, res.rot.z, res.rot.w,
    fov, res.nearClip or 0.1, 2000, ortho, orthoHalfHeight)
end

-- core/cameraUpdate.lua only runs the camera loop while levelLoaded, so no level check is needed here
function C:update(data)
  local dataRes = data.res

  -- extra contexts render to their own RenderView, independent of openxr/main
  if data.renderView and data.renderView ~= "main" then
    updateRenderView(data.renderView, dataRes)
    return
  end

  if data.openxrSessionRunning then
    OpenXR.setGeluaCameraPosRot(dataRes.pos.x, dataRes.pos.y, dataRes.pos.z, dataRes.rot.x, dataRes.rot.y, dataRes.rot.z, dataRes.rot.w)

    local posX, posY, posZ, rotX, rotY, rotZ, rotW = OpenXR.getCameraPosRotPredictedXYZXYZW()
    dataRes.pos:setAddXYZ(posX, posY, posZ)
    dataRes.rot:setMulXYZW(rotX, rotY, rotZ, rotW, dataRes.rot.x, dataRes.rot.y, dataRes.rot.z, dataRes.rot.w)
  end

  local inBigMap = freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive() or false
  local inTransition = freeroam_bigMapMode and freeroam_bigMapMode.isTransitionActive() or false
  local motionContinuous = not not (inTransition or (inBigMap and self.wasBigMap))
  if motionContinuous or self.motionContinuous then
    local renderView = RenderViewManagerInstance and RenderViewManagerInstance:getView("main")
    if renderView then
      renderView.cameraMotionContinuous = motionContinuous
    end
  end
  self.motionContinuous = motionContinuous
  self.wasBigMap = inBigMap

  setCameraPosRotFovNearClipC(dataRes.pos.x, dataRes.pos.y, dataRes.pos.z, dataRes.rot.x, dataRes.rot.y, dataRes.rot.z, dataRes.rot.w, dataRes.fov, dataRes.nearClip)
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
