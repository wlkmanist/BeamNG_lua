-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

M.debugName = "Tutorial"
M.debugOrder = 100

-- Persistent ref for debug draw bounds checkbox (imgui expects persistent state across frames)
local debugDrawBoundsRef = { false }

--==================================================
--MARK: Debug
-- Debug UI
--==================================================

local function drawDebugMenu(dt)
  if not career_modules_tutorial then
    im.Text("Tutorial module not loaded")
    return
  end

  local isActive = career_modules_tutorial.isActive()
  local currentStep = career_modules_tutorial.getCurrentStep()
  local stepOrder = career_modules_tutorial.getStepOrder() or {}

  im.Text("Tutorial Debug")
  im.Separator()

  if not isActive then
    im.Text("Tutorial is not active")
    im.Dummy(im.ImVec2(1, 5))
    if im.Button("Start Tutorial") then
      career_modules_tutorial.start()
    end
    return
  end

  im.Text(string.format("Current Step: %s", tostring(currentStep) or "None"))

  im.Dummy(im.ImVec2(1, 5))
  im.Separator()
  im.Dummy(im.ImVec2(1, 5))

  -- Advance to next step button
  if im.Button("Advance to Next Step") then
    career_modules_tutorial.advanceToNextStep()
  end
  im.SameLine()
  if im.Button("End Tutorial") then
    career_modules_tutorial.endTutorial()
  end

  im.Dummy(im.ImVec2(1, 5))
  im.Separator()
  im.Dummy(im.ImVec2(1, 5))

  -- Step selection
  im.Text("Jump to Step:")
  for i, stepId in ipairs(stepOrder) do
    if im.Button(string.format("%d: %s", i, tostring(stepId))) then
      career_modules_tutorial.activateStep(stepId)
    end
    if i % 5 ~= 0 then
      im.SameLine()
    end
  end

  im.Dummy(im.ImVec2(1, 5))
  im.Separator()
  im.Dummy(im.ImVec2(1, 5))

  -- Screens
  im.Text("Screens:")
  if im.Button("Open contract sign screen") then
    extensions.ui_popup.openContractSignPopup({
      userName = "Test Driver",
      money = "10.000",
      contractText = "By signing this agreement, the undersigned accepts the terms of test-driving employment with APM and confirms acceptance of the starting bonus.",
      text = "Read the agreement and continue to proceed with your onboarding.",
    })
  end
  if im.Button("Trigger damaged vehicle popup") then
    gameplay_tutorial_damageTracker.debugTriggerCrash()
  end
  im.Dummy(im.ImVec2(1, 5))
  im.Separator()
  im.Dummy(im.ImVec2(1, 5))

  -- Bounds
  im.Text("Active bound zones:")
  local names = gameplay_tutorial_bounds.getActiveZoneNames()
  if #names == 0 then
    im.Text("  (none)")
  else
    for _, name in ipairs(names) do
      local enabled = gameplay_tutorial_bounds.getZoneEnabled(name)
      im.Text(string.format("  %s %s", name, enabled and "" or "[disabled]"))
    end
  end
  debugDrawBoundsRef[1] = gameplay_tutorial_bounds.getDebugDrawBounds()
  if im.Checkbox("Debug draw bound zones", im.BoolPtr(debugDrawBoundsRef)) then
    gameplay_tutorial_bounds.setDebugDrawBounds(debugDrawBoundsRef[1])
  end
  if im.Button("Trigger out of bounds") then
    extensions.hook("onCareerTutorialLeftBounds")
  end
  im.Dummy(im.ImVec2(1, 5))
  im.Separator()
  im.Dummy(im.ImVec2(1, 5))

  -- Current step debug menu
  local stepExtName = 'career_modules_tutorial_step' .. currentStep
  local stepExt = extensions[stepExtName]
  if stepExt and stepExt.onDebugMenu then
    im.Text("Step " .. currentStep .. " Debug:")
    im.Separator()
    stepExt.onDebugMenu(im)
  end
end

--==================================================
--MARK: Exports
-- Extension exports
--==================================================

M.drawDebugMenu = drawDebugMenu

return M
