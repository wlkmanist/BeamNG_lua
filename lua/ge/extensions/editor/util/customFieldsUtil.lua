-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local im = ui_imgui
local ffi = require('ffi')

function C:init(name, fields, options)
  self.name = name or "Custom Fields" -- name should be unique, especially if using multiple instances
  self.tagsText = "Tags"
  self.fieldsText = "Custom Fields"
  self.enableTags = true
  self.enableFields = true
  self.presetTags = {} -- dropdown of recommended tags
  self.allowedTypes = {"string", "number"} -- string, number, boolean, vec3, quat

  options = options or {}
  for k, v in pairs(options) do
    if self[k] then self[k] = v end
  end

  self:setFields(fields)
  self:refresh()
end

function C:refresh()
  self.newNameInput = im.ArrayChar(256, "")
  self.newValueInput = im.ArrayChar(256, "")
  self.newTagInput = im.ArrayChar(256, "")
  self.currType = "string"
end

function C:setFields(fields)
  self.fields = fields or require('/lua/ge/extensions/gameplay/util/customFields')()
end

function C:drawCustomFields()
  im.Text(self.fieldsText)
  local remove
  local availWidth = im.GetContentRegionAvailWidth() * 0.24

  if im.BeginTable("statesSummary", 4, bit.bor(im.TableFlags_None)) then
    im.TableSetupScrollFreeze(0, 1)
    im.TableSetupColumn("Name", im.TableColumnFlags_WidthStretch, 25)
    im.TableSetupColumn("Value", im.TableColumnFlags_WidthStretch, 25)
    im.TableSetupColumn("Type", im.TableColumnFlags_WidthStretch, 25)
    im.TableSetupColumn("", im.TableColumnFlags_WidthStretch, 25)
    im.TableHeadersRow()
    im.TableNextColumn()

    for i, name in ipairs(self.fields.names) do
      im.Text(name)
      im.TableNextColumn()
      im.Text(tostring(self.fields.values[name]))
      im.TableNextColumn()
      im.Text(self.fields.types[name])
      im.TableNextColumn()
      if im.SmallButton("Remove##"..self.name.."_"..i) then
        remove = name
      end
      im.TableNextColumn()
    end

    im.PushItemWidth(availWidth)
    editor.uiInputText("##newName"..self.name, self.newNameInput)
    im.PopItemWidth()
    im.TableNextColumn()

    im.PushItemWidth(availWidth)
    editor.uiInputText("##newValue"..self.name, self.newValueInput) -- TODO: change this element based on data type
    im.PopItemWidth()
    im.TableNextColumn()

    im.PushItemWidth(availWidth)
    if im.BeginCombo("##newType"..self.name, self.currType) then
      for _, v in ipairs(self.allowedTypes) do
        if im.Selectable1(v.."##newType"..self.name, self.currType == v) then
          self.currType = v
        end
        if v == "boolean" then
          im.tooltip('Enter "true" or "false"')
        elseif v == "vec3" or v == "quat" then
          im.tooltip('Use commas to separate values')
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()
    im.TableNextColumn()

    if im.Button("Add") then
      self.fields:add(ffi.string(self.newNameInput), self.currType, ffi.string(self.newValueInput))
      self.newNameInput = im.ArrayChar(256, "")
      self.newValueInput = im.ArrayChar(256, "")
    end
    im.TableNextColumn()
    im.EndTable()
  end
  if remove then
    self.fields:remove(remove)
  end
end

function C:drawTags()
  im.Text(self.tagsText)
  local totalWidth = im.GetContentRegionAvailWidth()
  local removeTag

  im.BeginChild1("##tagsChild", im.ImVec2(0, 22), false)
  im.SetCursorPosY(im.GetCursorPosY() + 2)
  if tableSize(self.fields.sortedTags) == 0 then
    im.Text("(None)")
  else
    for _, t in ipairs(self.fields.sortedTags) do
      if im.GetCursorPosX() + im.CalcTextSize(t).x + 10 > totalWidth then
        im.EndChild()
        im.BeginChild1(t, im.ImVec2(0, 22), false)
        im.SetCursorPosY(im.GetCursorPosY() + 2)
      end
      if im.SmallButton(t) then
        self.popupTag = t
        im.OpenPopup("TagPopup")
      end
      im.SameLine()
    end
    if self.popupTag and im.BeginPopup("TagPopup") then
      im.Text("Tag: " .. self.popupTag)
      im.Separator()
      if im.Selectable1("Remove Tag") then
        removeTag = self.popupTag
      end
      im.EndPopup()
    end
  end

  im.EndChild()
  if removeTag then
    self.fields:removeTag(removeTag)
  end
  im.PushItemWidth(totalWidth * 0.5)
  if editor.uiInputText("##tagInput", self.newTagInput, nil, im.InputTextFlags_EnterReturnsTrue) then
    self:addTag()
  end
  im.PopItemWidth()
  im.SameLine()

  if self.presetTags[1] then
    im.PushItemWidth(totalWidth * 0.25)
    if im.BeginCombo("##tagSelect", "...") then
      for _, tag in ipairs(self.presetTags) do
        if im.Selectable1(tag) then
          self.newTagInput = im.ArrayChar(256, tag)
          self:addTag()
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()
  end
  im.SameLine()

  if im.Button("Add Tag") then
    self:addTag()
  end
end

function C:addTag()
  local tag = ffi.string(self.newTagInput)
  if tag == '' then
    return
  end

  self.fields:addTag(tag)
  self.newTagInput = im.ArrayChar(256, "")
end

function C:widget()
  if self.enableTags then
    self:drawTags()
  end
  if self.enableFields then
    self:drawCustomFields()
  end
end

-- helper callbacks for the edit mode
function C:onActivate()
end

function C:onDeactivate()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end