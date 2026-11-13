-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local ffi = require("ffi")
local im = ui_imgui
local bookmarks = {}
local selectedBookmark = im.IntPtr(-1)
local nextBookmarkId = 1
local newName = im.ArrayChar(128, "Bookmark 1")
local renameName = im.ArrayChar(128, "")
local bookmarkListSize = im.ImVec2(0, 0)

local function setName(buffer, value)
  value = value or ""
  ffi.fill(buffer, 128, 0)
  ffi.copy(buffer, value, math.min(#value, 127))
end

local function trimmedName(buffer)
  return ffi.string(buffer):match("^%s*(.-)%s*$")
end

local function currentBookmark()
  return bookmarks[selectedBookmark[0] + 1]
end

local function selectBookmark(index)
  selectedBookmark[0] = index - 1
  local bookmark = currentBookmark()
  setName(renameName, bookmark and bookmark.name or "")
end

local function moveCameraTo(bookmark)
  core_camera.clearInputs()
  if core_camera.clearMotion then core_camera.clearMotion(0) end
  core_camera.setPosition(0, vec3(bookmark.position))
  core_camera.setRotation(0, quat(bookmark.rotation))
end

function M.draw()
  im.Separator()
  im.HeaderText("Camera Bookmarks")
  im.SetNextItemWidth(160 * im.uiscale[0])
  im.InputText("##newCameraBookmarkName", newName, 128)
  im.SameLine()
  if im.Button("Add Current Position##addCameraBookmark") then
    local name = trimmedName(newName)
    if name == "" then name = string.format("Bookmark %d", nextBookmarkId) end
    bookmarks[#bookmarks + 1] = {
      name = name,
      position = vec3(core_camera.getPosition()),
      rotation = quat(core_camera.getQuat())
    }
    nextBookmarkId = nextBookmarkId + 1
    selectBookmark(#bookmarks)
    setName(newName, string.format("Bookmark %d", nextBookmarkId))
  end

  bookmarkListSize.y = 140 * im.uiscale[0]
  if im.BeginChild1("##cameraBookmarkList", bookmarkListSize, true) then
    if #bookmarks == 0 then im.TextUnformatted("No camera bookmarks") end
    for index, entry in ipairs(bookmarks) do
      local selected = index == selectedBookmark[0] + 1
      if im.Selectable1(entry.name, selected) then selectBookmark(index) end
    end
  end
  im.EndChild()

  local bookmark = currentBookmark()
  if not bookmark then im.BeginDisabled() end
  im.SetNextItemWidth(160 * im.uiscale[0])
  im.InputText("##renameCameraBookmark", renameName, 128)
  im.SameLine()
  if im.Button("Rename##renameCameraBookmarkButton") and bookmark then
    local name = trimmedName(renameName)
    if name ~= "" then bookmark.name = name end
    setName(renameName, bookmark.name)
  end
  if im.Button("Go To##gotoCameraBookmark") and bookmark then
    moveCameraTo(bookmark)
  end
  im.SameLine()
  if im.Button("Update View##updateCameraBookmark") and bookmark then
    bookmark.position = vec3(core_camera.getPosition())
    bookmark.rotation = quat(core_camera.getQuat())
  end
  im.SameLine()
  if im.Button("Delete##deleteCameraBookmark") and bookmark then
    table.remove(bookmarks, selectedBookmark[0] + 1)
    local nextIndex = math.min(selectedBookmark[0] + 1, #bookmarks)
    if nextIndex > 0 then
      selectBookmark(nextIndex)
    else
      selectedBookmark[0] = -1
      setName(renameName, "")
    end
  end
  if not bookmark then im.EndDisabled() end
end

return M
