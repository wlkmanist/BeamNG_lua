-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local logTag = "EndScreenAiCompetitorsLeaderboard"

C.name = "EndScreen AI Competitors Leaderboard"
C.color = ui_flowgraph_editor.nodeColors.ui
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.description =
  "Adds a AI Competitors Leaderboard tab to the mission end screen. Single-stage: time + delta columns. Multi-stage: one column per stage + final (from Rally AI Competitors Leaderboard with playerTimes/silverTimes tables)."
C.category = "once_instant"

C.pinSchema = {
  { dir = "in", type = "flow", name = "flow", description = "", chainFlow = true },
  { dir = "out", type = "flow", name = "flow", description = "", chainFlow = true },
  { dir = "in", type = "table", tableType = "generic", name = "leaderboard", description = "Output from Rally AI Competitors Leaderboard node." },
}

C.tags = { "end", "finish", "screen", "outro", "ui", "rally" }

local function hasValidMultiStageLayout(leaderboard)
  if leaderboard.multiStage ~= true then
    return true
  end
  if type(leaderboard.stageCount) ~= "number" or leaderboard.stageCount < 1 then
    return false
  end
  if type(leaderboard.stageLabels) ~= "table" or #leaderboard.stageLabels ~= leaderboard.stageCount then
    return false
  end
  for _, row in ipairs(leaderboard.rows) do
    if type(row.stageCells) ~= "table" or #row.stageCells ~= leaderboard.stageCount then
      return false
    end
  end
  return true
end

function C:workOnce()
  local leaderboard = self.pinIn.leaderboard.value
  if not leaderboard or type(leaderboard.rows) ~= "table" or #leaderboard.rows == 0 then
    return
  end

  if not hasValidMultiStageLayout(leaderboard) then
    log("E", logTag, "Invalid AI competitors multi-stage payload; skipping end-screen panel.")
    return
  end

  local playerRowIndex = leaderboard.playerRowIndex
  if type(playerRowIndex) ~= "number" or playerRowIndex < 1 or playerRowIndex > #leaderboard.rows then
    playerRowIndex = 0
  end

  local playerName = "Player"
  local useDefaultPlayerName = true
  if OnlineServiceProvider and OnlineServiceProvider.playerName ~= nil and OnlineServiceProvider.playerName ~= "" then
    playerName = OnlineServiceProvider.playerName
    useDefaultPlayerName = false
  end

  local lbPayload = {
    rows = leaderboard.rows,
    playerRowIndex = playerRowIndex,
    playerName = playerName,
    useDefaultPlayerName = useDefaultPlayerName,
  }
  if leaderboard.multiStage == true and type(leaderboard.stageCount) == "number" then
    lbPayload.multiStage = true
    lbPayload.stageCount = leaderboard.stageCount
    if type(leaderboard.stageLabels) == "table" and #leaderboard.stageLabels == leaderboard.stageCount then
      lbPayload.stageLabels = leaderboard.stageLabels
    end
  end

  self.mgr.modules.ui:addUIElement({
    type = "textPanel",
    header = "missions.aiCompetitorsLeaderboard.title",
    fullHeight = true,
    attempt = {
      aiCompetitorsLeaderboard = lbPayload,
    },
    pages = {
      aiCompetitors = true,
    },
  })
end

return _flowgraph_createNode(C)
