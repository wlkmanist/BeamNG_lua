-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')

local M = {}

local windowBgColor = im.ImVec4(0.02, 0.12, 0.35, 0.94)
local titleBgColor = im.ImVec4(0.0, 0.18, 0.55, 1.0)
local titleBgActiveColor = im.ImVec4(0.0, 0.25, 0.75, 1.0)
local textColor = im.ImVec4(1.0, 1.0, 1.0, 1.0)
local borderColor = im.ImVec4(0.35, 0.62, 1.0, 0.9)

local function textOrNone(text)
  if text and text ~= "" then return text end
  return "<none>"
end

local function firstCorner(pn, projected)
  local structured = projected and pn.structuredForProjection and pn:structuredForProjection() or pn.structured
  local item = Structured.slotItem(structured, 4)
  if item and item.type == 'corner' then return item end
  return nil
end

local function adjustmentText(pn)
  local corner = firstCorner(pn, false)
  if not corner then return nil end

  local parts = {}
  local riskIntensity = tonumber(corner.riskIntensity) or 0
  if riskIntensity > 0 then
    table.insert(parts, "more intensity risk")
  elseif riskIntensity < 0 then
    table.insert(parts, "less intensity risk")
  end

  local lengthMode = corner.lengthMode
  if lengthMode == 'longer' then
    table.insert(parts, "feels longer")
  elseif lengthMode == 'shorter' then
    table.insert(parts, "feels shorter")
  elseif lengthMode == 'skip' then
    table.insert(parts, "skip length")
  end

  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

local function cornerIntensityLabel(pn, intensityId)
  if not intensityId or intensityId == "" then return nil end

  local compositor = pn.notebook and pn.notebook:getTextCompositor()
  local config = compositor and compositor:getConfig()
  local cornerCfg = config and config.componentTypes and config.componentTypes.corner
  for _, entry in ipairs(compositorUtil.cornerIntensityList(cornerCfg) or {}) do
    if compositorUtil.intensityEntryId(entry) == intensityId then
      return compositorUtil.intensityEntryLabel(entry)
    end
  end
  return intensityId
end

local function calibrationMetadataText(pn)
  local calibration = pn.metadata and pn.metadata.calibration
  if not calibration then return nil end

  local parts = {}
  if calibration.cornerDescriptor and calibration.cornerDescriptor ~= "" then
    table.insert(parts, calibration.cornerDescriptor)
  elseif calibration.cornerIntensity and calibration.cornerIntensity ~= "" then
    table.insert(parts, cornerIntensityLabel(pn, calibration.cornerIntensity))
  end
  if calibration.direction and calibration.direction ~= "" then
    table.insert(parts, calibration.direction)
  end
  if calibration.cornerLength and calibration.cornerLength ~= "" then
    table.insert(parts, calibration.cornerLength)
  end
  if calibration.shape and calibration.shape ~= "" then
    table.insert(parts, calibration.shape)
  end

  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

local function actualMetadataText(pn)
  local corner = firstCorner(pn, true)
  if not corner then return nil end

  local compositor = pn.notebook and pn.notebook:getTextCompositor()
  local config = compositor and compositor:getConfig()
  local cornerCfg = config and config.componentTypes and config.componentTypes.corner
  if not cornerCfg then return nil end

  local parts = {}
  local cornerCall = compositorUtil.getCornerCall(cornerCfg, corner)
  if cornerCall and cornerCall ~= "" then
    table.insert(parts, cornerCall)
  end

  local lengthStr = compositorUtil.getCornerLengthForItem(cornerCfg, corner)
  if lengthStr and lengthStr ~= "" then
    table.insert(parts, lengthStr)
  end

  local shapeStr = compositorUtil.getCornerShape(cornerCfg, corner.shape)
  if shapeStr and shapeStr ~= "" then
    table.insert(parts, shapeStr)
  end

  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

function M.draw(pacenotesWindow)
  if not pacenotesWindow then return end

  local pn = pacenotesWindow:selectedPacenote()
  if not pn or pn.missing or pacenotesWindow:cameraPathIsPlaying() then return end

  im.SetNextWindowSize(im.ImVec2(320, 0), im.Cond_FirstUseEver)
  local windowFlags = bit.bor(im.WindowFlags_AlwaysAutoResize, im.WindowFlags_NoDocking)
  im.PushStyleColor2(im.Col_WindowBg, windowBgColor)
  im.PushStyleColor2(im.Col_TitleBg, titleBgColor)
  im.PushStyleColor2(im.Col_TitleBgActive, titleBgActiveColor)
  im.PushStyleColor2(im.Col_Text, textColor)
  im.PushStyleColor2(im.Col_Border, borderColor)
  if im.Begin("Selected Pacenote Utility###selectedPacenoteUtility", nil, windowFlags) then
    im.Text(string.format("%s  (id: %s)", pn.name or "<unnamed>", tostring(pn.id)))
    im.Separator()

    im.Text("Actual")
    im.TextWrapped(textOrNone(actualMetadataText(pn)))
    im.Spacing()

    im.Text("Adjustment")
    im.TextWrapped(textOrNone(adjustmentText(pn)))
    im.Spacing()

    im.Text("Metadata")
    im.TextWrapped(textOrNone(calibrationMetadataText(pn)))
  end
  im.End()
  im.PopStyleColor(5)
end

return M
