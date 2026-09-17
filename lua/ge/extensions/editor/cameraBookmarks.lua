-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'editor_cameraBookmarks'
local ffi = require("ffi")
local imgui = ui_imgui
local toolWindowName = "cameraBookmarks"
local newBookmarkName = imgui.ArrayChar(1000)

local function createBookmarkRedo(actionData)
  local bookmarksGroup = editor.getCameraBookmarks()
  if not bookmarksGroup then return end
  local bookmark = worldEditorCppApi.createObject("CameraBookmark")
  bookmark:setField("datablock", 0, "CameraBookmarkMarker")
  bookmark:setField("scale", 0, "5 5 5")
  bookmark:registerObject("")
  bookmark:setInternalName(actionData.name)
  bookmark:setTransform(editor.tableToMatrix(actionData.transform))
  bookmarksGroup:addObject(bookmark)
  if actionData.objectId then
    editor.history:updateRedoStackObjectId(actionData.objectId, bookmark:getID())
  end
  actionData.objectId = bookmark:getID()
  editor.setDirty()
end

local function deleteBookmarkRedo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then obj:deleteObject() end
  editor.setDirty()
end

local function setCameraTransformRedo(actionData)
  core_camera.setPosRot(0,
    actionData.newTransform.pos.x, actionData.newTransform.pos.y, actionData.newTransform.pos.z,
    actionData.newTransform.rot.x, actionData.newTransform.rot.y, actionData.newTransform.rot.z, actionData.newTransform.rot.w)
end

local function setCameraTransformUndo(actionData)
  core_camera.setPosRot(0,
    actionData.oldTransform.pos.x, actionData.oldTransform.pos.y, actionData.oldTransform.pos.z,
    actionData.oldTransform.rot.x, actionData.oldTransform.rot.y, actionData.oldTransform.rot.z, actionData.oldTransform.rot.w)
end

local function captureCameraTransform()
  local pos = core_camera.getPosition()
  local rot = core_camera.getQuat()
  return { pos = vec3(pos), rot = quat(rot) }
end

local function addBookmarkWithUndo(name)
  local id = editor.addCameraBookmark(name)
  local obj = scenetree.findObjectById(id)
  if not obj then return end
  editor.history:commitAction("AddCameraBookmark",
    { objectId = id, name = name, transform = editor.matrixToTable(obj:getTransform()) },
    deleteBookmarkRedo, createBookmarkRedo, true)
end

local function deleteBookmarkWithUndo(objectId)
  local obj = scenetree.findObjectById(objectId)
  if not obj then return end
  editor.history:commitAction("DeleteCameraBookmark",
    { objectId = objectId, name = obj:getInternalName(), transform = editor.matrixToTable(obj:getTransform()) },
    createBookmarkRedo, deleteBookmarkRedo)
end

local function pasteLocationWithUndo()
  local oldTransform = captureCameraTransform()
  editor.pasteCameraBookmarkFromClipboard()
  local newTransform = captureCameraTransform()
  editor.history:commitAction("PasteCameraLocation",
    { oldTransform = oldTransform, newTransform = newTransform },
    setCameraTransformUndo, setCameraTransformRedo, true)
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Camera Bookmarks") then
    imgui.Text("New bookmark name:")
    local addMark = imgui.InputText("##newBookmarkName", newBookmarkName, imgui.ArraySize(newBookmarkName), imgui.InputTextFlags_EnterReturnsTrue)
    imgui.SameLine()

    if imgui.Button("Add") then addMark = true end

    if addMark then
      local val = ffi.string(newBookmarkName)
      ffi.copy(newBookmarkName, "")
      addBookmarkWithUndo(val)
    end

    imgui.TextUnformatted("Clipboard: ")
    imgui.SameLine()

    if imgui.Button("Copy Location") then editor.copyCameraBookmarkToClipboard(editor.getCamera()) end

    imgui.SameLine()

    if imgui.Button("Paste Location") then pasteLocationWithUndo() end

    imgui.BeginChild1("cameraBookmarksChild", imgui.ImVec2(0, 0), true)
    local bookmarks = editor.getCameraBookmarks()

    if bookmarks then
      local deleteId = 0
      for i = 1, bookmarks:size() do
        local bookmark = bookmarks:at(i - 1)
        imgui.PushID4(i)
        if imgui.Button("Go To") then editor.jumpToCameraBookmark(bookmark:getID()) end
        imgui.SameLine()
        if imgui.Button("Copy") then editor.copyCameraBookmarkToClipboard(bookmark) end
        imgui.SameLine()
        if imgui.Button("Delete") then deleteId = bookmark:getID() end
        imgui.SameLine()
        imgui.TextUnformatted(bookmark:getInternalName())
        imgui.PopID()
      end
      if deleteId ~= 0 then deleteBookmarkWithUndo(deleteId) end
    end
    imgui.EndChild()
  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onExtensionLoaded()
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, imgui.ImVec2(500,500))
  editor.addWindowMenuItem("Camera Bookmarks", onWindowMenuItem)
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui
M.onExtensionLoaded = onExtensionLoaded

return M
