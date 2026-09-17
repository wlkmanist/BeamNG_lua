-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}

C.name = 'Rally End Screen Results'
C.description = 'Shows rally results with the mission-authored title/text and optional medal outro text.'
C.color = RallyUtil.rally_flowgraph_color
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.tags = { 'rally', 'end', 'finish', 'screen', 'outro', 'ui' }
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'out', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'in', type = {'string', 'table'}, name = 'text', description = 'Additional outro text, such as the medal-aware stage result.' },
  { dir = 'in', type = 'table', name = 'change', description = 'Change from the attempt. Use the aggregate attempt node.' },
  { dir = 'in', type = 'bool', name = 'includeObjectives', description = 'If true, automatically adds objectives after the panel.' },
  { dir = 'in', type = 'bool', name = 'includeRatings', description = 'If true, automatically adds ratings after the panel.' },
}

local function isEmptyText(value)
  if value == nil or value == '' then return true end
  return type(value) == 'table' and (value.txt == nil or value.txt == '')
end

local function translationKey(value)
  if type(value) == 'table' then return value.txt end
  if type(value) == 'string' then return value end
  return nil
end

function C:work()
  self.pinOut.flow.value = self.pinIn.flow.value

  local missionTypeData = self.mgr.activity and self.mgr.activity.missionTypeData or {}
  local header = missionTypeData.outroTitleText
  if isEmptyText(header) then header = 'ui.missions.results.title' end

  local authoredText = missionTypeData.endScreenText
  if isEmptyText(authoredText) then authoredText = nil end

  local additionalText = self.pinIn.text.value
  if isEmptyText(additionalText) then additionalText = nil end

  -- Rally loop's save node already emits endScreenText as its outroTranslation.
  -- Suppress it when it is the same authored key so the body appears only once.
  if authoredText and translationKey(additionalText) == translationKey(authoredText) then
    additionalText = nil
  end

  local change = self.pinIn.change.value
  if change and change.formattedAttempt then
    self.mgr.modules.ui:addUIElement({
      type = 'textPanel',
      header = header,
      attempt = change.formattedAttempt,
      pages = { main = true },
    })
    header = nil
  end

  local function addTextPanel(text)
    if not text then return end
    self.mgr.modules.ui:addUIElement({
      type = 'textPanel',
      header = header,
      text = text,
      pages = { main = true },
    })
    header = nil
  end

  addTextPanel(authoredText)
  addTextPanel(additionalText)

  if self.pinIn.includeObjectives.value then
    self.mgr.modules.ui:addObjectives(change)
  end
  if self.pinIn.includeRatings.value then
    self.mgr.modules.ui:addRatings(change)
  end
end

return _flowgraph_createNode(C)
