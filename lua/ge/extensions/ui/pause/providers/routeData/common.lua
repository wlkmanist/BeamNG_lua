-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

function M.bool(value)
  return value and true or false
end

function M.tryPushStateSequence(states)
  if not states then return false end
  if type(states) == "string" then states = {states} end
  for _, stateName in ipairs(states) do
    local ok, result = pcall(ui_router.navigate, stateName, nil)
    if ok and result and result.result ~= false then return true end
  end
  return false
end

function M.registerPauseButton(button)
  if not button then return nil end
  local callback = button.callback or function() return false end
  local metadata = deepcopy(button)
  metadata.callback = nil
  return ui_pause_actions.registerButton(metadata, callback)
end

M.ExitLevelTexts = {
  default = "ui.pause.home.confirmExitToMainMenu",
  career = "ui.pause.home.confirmExitCareer",
  notSaved = "ui.pause.home.confirmExitCareerNotSaved",
}

M.ExitGameTexts = {
  default = "ui.pause.system.confirmExitGame",
  career = "ui.pause.system.confirmExitGameCareer",
  notSaved = "ui.pause.system.confirmExitGameCareerNotSaved",
}

local function getCurrentCareerSaveDate()
  local _, savePath = career_saveSystem.getCurrentProfile()
  local info = savePath and jsonReadFile(savePath .. "/info.json")
  if info and not info.corrupted then return info.date end
end

-- In career the text warns about unsaved progress; the UI fills {{time}} from confirmSince when the popup opens.
-- Without any save, "Save and exit" is offered only while saving is allowed (the onboarding tutorial blocks it).
function M.withExitConfirm(button, context, texts)
  button.cancelLabel = _tr("ui.pause.common.keepPlaying")
  if context.mode ~= "career" or not career_saveSystem then
    button.confirmText = _tr(texts.default)
    return button
  end

  local saveDate = getCurrentCareerSaveDate()
  if saveDate then
    button.confirmText = { txt = texts.career }
    button.confirmSince = saveDate
    return button
  end

  button.confirmText = _tr(texts.notSaved)
  if career_career.isAutosaveEnabled() then
    button.confirmLabel = _tr("ui.pause.common.saveAndExit")
    button.confirmDestructive = false
    button.altLabel = _tr("ui.pause.common.exitWithoutSaving")
  end
  return button
end

function M.runExit(exitFn, payload)
  if payload and payload.saveFirst then
    ui_pause_actions.saveCareerThen(exitFn)
  else
    exitFn()
  end
end

-- Skip empty action lists so JSON encodes rail actions as arrays, not objects.
function M.asRailGroup(id, actions)
  if not actions or #actions == 0 then return nil end
  return {
    id = id,
    actions = actions,
  }
end

return M
