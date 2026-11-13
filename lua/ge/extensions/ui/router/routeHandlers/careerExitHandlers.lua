-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local NavigationState = require("ge/extensions/ui/router/navigationState")

M.careerProfilesExitHandler = function()
  if extensions.career_career.isActive() then
    ui_router.navigate("pause")
  else
    ui_router.navigate("menu")
  end
end

M.careerBranchPageBackHandler = function()
  local currentEntry = NavigationState.getCurrentEntry()
  local params = currentEntry and currentEntry.request and currentEntry.request.params or {}
  local returnRoute = params.returnRoute
  local pathId = params.pathId
  local branch = career_branches and pathId and career_branches.getBranchById(pathId) or nil
  local parentId = branch and not branch.missing and branch.parentId or nil

  if parentId then
    local targetParams = {
      pathId = parentId,
      focusPathId = pathId,
    }
    if returnRoute then
      targetParams.returnRoute = returnRoute
    end
    return ui_router.navigate("career.branchPage", targetParams)
  end

  if returnRoute == "career.computer" then
    return ui_router.navigate("career.computer")
  end

  return ui_router.navigate("career.domainSelection", {focusPathId = pathId})
end

M.negotiationExitHandler = function()
  extensions.career_modules_marketplace.finalizeNegotiationExit()

  local prevEntry = NavigationState.getPreviousEntry()
  if prevEntry and prevEntry.request and prevEntry.request.name then
    return ui_router.navigate(prevEntry.request.name, prevEntry.request.params or {}, { restoreLastScope = true })
  end

  return { success = false, reason = "no_previous_entry" }
end

return M
