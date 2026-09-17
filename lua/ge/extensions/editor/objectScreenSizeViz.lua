-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'editor_objectScreenSizeViz'
local imgui = ui_imgui
local toolWindowName = "objectScreenSizeViz"

local lineColor = ColorF(1, 0, 1, 1)
local bboxColor = ColorF(1, 0.5, 0, 1)
local overlayRectColor = imgui.GetColorU322(imgui.ImVec4(1, 0.5, 0, 1))
local overlayTextColor = imgui.GetColorU322(imgui.ImVec4(1, 1, 1, 1))
local overlayTextBgColor = imgui.GetColorU322(imgui.ImVec4(0, 0, 0, 0.6))

local showBBox = imgui.BoolPtr(true)
local showCameraLine = imgui.BoolPtr(true)
local showScreenRect = imgui.BoolPtr(true)

-- world to normalized screen (0..1), returns nil if behind camera
local function worldToScreen01(worldPos, camPos, camRight, camForward, camUp, halfTan, aspect)
  local toPoint = worldPos - camPos
  local depth = toPoint:dot(camForward)
  if depth <= 0 then return nil end
  local nx = toPoint:dot(camRight) / (depth * halfTan * aspect)
  local ny = toPoint:dot(camUp) / (depth * halfTan)
  return (nx + 1) * 0.5, (1 - ny) * 0.5
end

local function getBoxCorners(box)
  local mn, mx = box.minExtents, box.maxExtents
  return {
    vec3(mn.x, mn.y, mn.z), vec3(mx.x, mn.y, mn.z),
    vec3(mn.x, mx.y, mn.z), vec3(mx.x, mx.y, mn.z),
    vec3(mn.x, mn.y, mx.z), vec3(mx.x, mn.y, mx.z),
    vec3(mn.x, mx.y, mx.z), vec3(mx.x, mx.y, mx.z),
  }
end

-- compute distance and screen-space pixel size from a world bounding box, returns a result table or nil
local function computeBoxMetrics(box, cam)
  if not box or not box.minExtents or not box.maxExtents then return nil end
  if box.minExtents.x > box.maxExtents.x then return nil end

  local center = box:getCenter()
  local distance = (cam.pos - center):length()

  local corners = getBoxCorners(box)
  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge
  local visibleCorners = 0
  for i = 1, #corners do
    local sx, sy = worldToScreen01(corners[i], cam.pos, cam.right, cam.forward, cam.up, cam.halfTan, cam.aspect)
    if sx then
      visibleCorners = visibleCorners + 1
      local px = sx * cam.pixelW
      local py = sy * cam.pixelH
      if px < minX then minX = px end
      if py < minY then minY = py end
      if px > maxX then maxX = px end
      if py > maxY then maxY = py end
    end
  end

  local res = {
    distance = distance,
    center = center,
    box = box,
    onScreen = visibleCorners == #corners,
  }
  if visibleCorners > 0 then
    res.pixelW = maxX - minX
    res.pixelH = maxY - minY
    res.pixelArea = res.pixelW * res.pixelH
    res.screenMinX = minX
    res.screenMinY = minY
    res.screenMaxX = maxX
    res.screenMaxY = maxY
  end
  return res
end

local function computeForObject(obj, cam)
  if not obj or not obj.getWorldBox then return nil end
  local res = computeBoxMetrics(obj:getWorldBox(), cam)
  if not res then return nil end
  local name = obj:getName()
  if not name or name == "" then name = "#" .. tostring(obj:getID()) end
  res.name = name
  res.className = obj:getClassName()
  return res
end

local function computeForForestItem(item, cam)
  if not item or not item.getWorldBox then return nil end
  local res = computeBoxMetrics(item:getWorldBox(), cam)
  if not res then return nil end
  local data = item.getData and item:getData() or nil
  local shape = data and data.getShapeFile and tostring(data:getShapeFile()) or nil
  if shape and shape ~= "" then
    res.name = shape:match("([^/\\]+)$") or shape
  else
    res.name = "forestItem"
  end
  res.className = "ForestItem"
  return res
end

local function getCameraContext()
  if not core_camera then return nil end
  local camPos = core_camera.getPosition()
  local camRot = core_camera.getQuat()
  if not camPos or not camRot then return nil end

  local canvas = scenetree.findObject("Canvas")
  if not canvas or not canvas.getWindowClientSizeXY then return nil end
  local clientW, clientH = canvas:getWindowClientSizeXY()
  if not clientW or not clientH or clientW <= 0 or clientH <= 0 then return nil end

  local fovRad = core_camera.getFovRad and core_camera.getFovRad() or nil
  if not fovRad or fovRad <= 0 then return nil end

  local halfTan = math.tan(fovRad * 0.5)
  if halfTan == 0 then return nil end

  return {
    pos = vec3(camPos),
    right = quat(camRot) * vec3(1, 0, 0),
    forward = quat(camRot) * vec3(0, 1, 0),
    up = quat(camRot) * vec3(0, 0, 1),
    halfTan = halfTan,
    aspect = clientW / clientH,
    pixelW = clientW,
    pixelH = clientH,
  }
end

local function drawObject3D(res)
  if showBBox[0] then
    local b = res.box
    local mn, mx = b.minExtents, b.maxExtents
    local p = {
      vec3(mn.x, mn.y, mn.z), vec3(mx.x, mn.y, mn.z),
      vec3(mn.x, mx.y, mn.z), vec3(mx.x, mx.y, mn.z),
      vec3(mn.x, mn.y, mx.z), vec3(mx.x, mn.y, mx.z),
      vec3(mn.x, mx.y, mx.z), vec3(mx.x, mx.y, mx.z),
    }
    debugDrawer:drawLine(p[1], p[2], bboxColor) debugDrawer:drawLine(p[1], p[3], bboxColor)
    debugDrawer:drawLine(p[2], p[4], bboxColor) debugDrawer:drawLine(p[3], p[4], bboxColor)
    debugDrawer:drawLine(p[5], p[6], bboxColor) debugDrawer:drawLine(p[5], p[7], bboxColor)
    debugDrawer:drawLine(p[6], p[8], bboxColor) debugDrawer:drawLine(p[7], p[8], bboxColor)
    debugDrawer:drawLine(p[1], p[5], bboxColor) debugDrawer:drawLine(p[2], p[6], bboxColor)
    debugDrawer:drawLine(p[3], p[7], bboxColor) debugDrawer:drawLine(p[4], p[8], bboxColor)
  end
  if showCameraLine[0] then
    debugDrawer:drawLine(core_camera.getPosition(), res.center, lineColor)
  end
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Object Screen Size") then
    imgui.TextWrapped("Select objects or forest items in the scene. This shows live camera distance and screen-space pixel size (from world bounding box).")
    imgui.Separator()
    imgui.Checkbox("Draw bounding box", showBBox)
    imgui.SameLine()
    imgui.Checkbox("Draw camera line", showCameraLine)
    imgui.Checkbox("Draw screen rect overlay", showScreenRect)
    imgui.Separator()

    local cam = getCameraContext()
    local objSelection = editor.selection and editor.selection.object or nil
    local forestSelection = editor.selection and editor.selection.forestItem or nil

    local results = {}
    if cam then
      if objSelection then
        for i = 1, #objSelection do
          local obj = scenetree.findObjectById(objSelection[i])
          local res = obj and computeForObject(obj, cam)
          if res then table.insert(results, res) end
        end
      end
      if forestSelection then
        for i = 1, #forestSelection do
          local res = computeForForestItem(forestSelection[i], cam)
          if res then table.insert(results, res) end
        end
      end
    end

    if not cam then
      imgui.TextColored(imgui.ImVec4(1, 0.4, 0.4, 1), "Camera context not available.")
    elseif #results == 0 then
      imgui.TextDisabled("No object or forest item selected.")
    else
      local viewport = imgui.GetMainViewport()
      local vpPos, vpSize = viewport.Pos, viewport.Size
      local drawList = imgui.GetBackgroundDrawList1()

      local screenArea = cam.pixelW * cam.pixelH

      if imgui.BeginTable("objScreenSizeTable", 5, imgui.TableFlags_Borders + imgui.TableFlags_RowBg + imgui.TableFlags_SizingStretchProp) then
        imgui.TableSetupColumn("Object")
        imgui.TableSetupColumn("Distance (m)")
        imgui.TableSetupColumn("Pixels (WxH)")
        imgui.TableSetupColumn("Area (px)")
        imgui.TableSetupColumn("Screen %")
        imgui.TableHeadersRow()

        for _, res in ipairs(results) do
          drawObject3D(res)

          if res.pixelW and showScreenRect[0] then
            local rx0 = vpPos.x + (res.screenMinX / cam.pixelW) * vpSize.x
            local ry0 = vpPos.y + (res.screenMinY / cam.pixelH) * vpSize.y
            local rx1 = vpPos.x + (res.screenMaxX / cam.pixelW) * vpSize.x
            local ry1 = vpPos.y + (res.screenMaxY / cam.pixelH) * vpSize.y
            imgui.ImDrawList_AddRect(drawList, imgui.ImVec2(rx0, ry0), imgui.ImVec2(rx1, ry1), overlayRectColor, 0, nil, 2)
            local label = string.format("%s  %.0fx%.0f px  %.2f%%  %.1f m", res.name, res.pixelW, res.pixelH, screenArea > 0 and (res.pixelArea / screenArea * 100) or 0, res.distance)
            imgui.ImDrawList_AddRectFilled(drawList, imgui.ImVec2(rx0, ry0 - 16), imgui.ImVec2(rx0 + 8 + #label * 7, ry0), overlayTextBgColor, 0, nil)
            imgui.ImDrawList_AddText1(drawList, imgui.ImVec2(rx0 + 4, ry0 - 15), overlayTextColor, label, nil)
          end

          imgui.TableNextRow()
          imgui.TableNextColumn()
          imgui.TextUnformatted(tostring(res.name))
          imgui.TableNextColumn()
          imgui.Text(string.format("%.2f", res.distance))
          imgui.TableNextColumn()
          if res.pixelW then
            imgui.Text(string.format("%.0f x %.0f", res.pixelW, res.pixelH))
          else
            imgui.TextDisabled("off-screen")
          end
          imgui.TableNextColumn()
          if res.pixelArea then
            imgui.Text(string.format("%.0f", res.pixelArea))
          else
            imgui.TextDisabled("-")
          end
          imgui.TableNextColumn()
          if res.pixelArea and screenArea > 0 then
            imgui.Text(string.format("%.2f%%", res.pixelArea / screenArea * 100))
          else
            imgui.TextDisabled("-")
          end
        end
        imgui.EndTable()
      end
    end
  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, imgui.ImVec2(480, 320))
  editor.addWindowMenuItem("Object Screen Size", onWindowMenuItem, {groupMenuName = "Debug"})
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

return M
