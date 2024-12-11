-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local C = {}
C.moduleOrder = 1000 -- low first, high later
C.idCounter = 0
C.hooks = {'onRequestMissionScreenData', 'onMissionScreenButtonClicked', "onGetIsMissionStartOrEndScreenActive"}
function C:getFreeId()
  self.idCounter = self.idCounter + 1
  return self.idCounter
end

function C:init()
  self:clear()
end

function C:clear()
  self.isBuilding = false
  self.uiLayout = nil
end

function C:setGameState(...)
  core_gamestate.setGameState(...)
end

function C:keepGameState(keep)
  self.recoverGameStateWhenExecutionStopped = not keep
end

function C:clearButtonFunctions()
  self.buttonFunctions = {}
end

function C:startUIBuilding(uiMode, node)
  if self.isBuilding then
    log("E","","Tried to start building, but is already building!")
    return
  end
  self.uiLayout = { mode = uiMode, header = nil, layout = {}, buttons = {}, _node = {nodeId = node.id, graphId = node.graph.id} }
  self.isBuilding = true
  log("I","","Starting to build.")
  self:clearButtonFunctions()
end

function C:finishUIBuilding()
  if not self.isBuilding then
    log("E","","Tried to finish building, but is currently not building!")
    return
  end
  local mission = self.mgr.activity
  log("I","","Finishing Build...")
  log("I", "", dumpsz(self.uiLayout.layout, 2))


  if self.uiLayout.mode == 'startScreen' then

    table.insert(self.uiLayout.buttons, self:addButton(function()
      self.mgr.graphs[self.uiLayout._node.graphId].nodes[self.uiLayout._node.nodeId]:startFromUi()
       end, {
        label = "ui.scenarios.start.start",
        focus = true,
        main = true,
      }))

    print("Going to mission start!")
    guihooks.trigger('ChangeState', {state = 'mission-control', params = { mode = 'startScreen'}})
  elseif self.uiLayout.mode == 'endScreen' then
    print("Going to mission end!")
    guihooks.trigger('ChangeState', {state = 'mission-control', params = { mode = 'endScreen'}})
  end
  log("I","","Done.")
  self.isBuilding = false
end

function C:onRequestMissionScreenData(mode)
  if self.uiLayout and mode ~= "endScreenTest" then
    --print("sending layout...")
    --jsonWriteFile("gameplay/testing/missionScreen.json", self.uiLayout, true)
    guihooks.trigger("onRequestMissionScreenDataReady", self.uiLayout)
--    dumpz(self.uiLayout,2)
    --dump(self.uiLayout.buttons)
  end
end

function C:onGetIsMissionStartOrEndScreenActive(screensActive)
  if self.uiLayout then table.insert(screensActive, self.uiLayout.mode) end
end


-- Elements --
function C:onMissionScreenButtonClicked(button)
  if self.mgr.id ~= button.mgrId then
    return
  end
  self.buttonFunctions[button.funId]()
  self.uiLayout = nil
end



function C:addUIElement(element)
  if not self.isBuilding then
    log("E","","Tried to add ui element, but is currently not building! ")
    return
  end
  table.insert(self.uiLayout.layout, element)
end

function C:addHeader(header)
  if not self.isBuilding then
    log("E","","Tried to add header, but is currently not building! ")
    return
  end
  self.uiLayout.header = header
end

function C:addButton(fun, meta)
  if not self.isBuilding then
    log("E","","Tried to add button, but is currently not building! ")
    return
  end

  local idx = #self.buttonFunctions+1
  self.buttonFunctions[idx] = fun
  meta = meta or {}
  meta.mgrId = self.mgr.id
  meta.funId = idx
  return meta
end


function C:addObjectives(change)
  if not self.isBuilding then
    log("E","","Tried to add objectives, but is currently not building! ")
    return
  end
  local mission = self.mgr.activity
  if not mission then return end
  local unflattenedSettings = {}
  for k, v in pairs(mission.lastUserSettings) do
    table.insert(unflattenedSettings, {key = k, value = v})
  end

  local activeRewards = gameplay_missions_missionScreen.getActiveStarsForUserSettings(mission.id, unflattenedSettings)
  local stars = gameplay_missions_progress.formatStars(mission).stars or {}
  local anyVisible = false
  for _, star in ipairs(stars) do
    star.order = star.globalStarIndex
    if activeRewards and activeRewards.starInfo then
      star.enabled = activeRewards.starInfo[star.key].enabled
      star.message = activeRewards.starInfo[star.key].message
      star.visible = activeRewards.starInfo[star.key].visible
      anyVisible = star.visible
    end

    if change and change.unlockedStarsAttempt then
      star.unlockAttempt = change.unlockedStarsAttempt[star.key]
    end
    if change and change.unlockedStarsChanged then
      star.unlockChange = change.unlockedStarsChanged[star.key]
    end
  end

  if anyVisible then
    self:addUIElement({
      type = "objectives",
      formattedProgress = {
        stars = stars,
        message = activeRewards.message,
      }
    })
  end
end

local formatMission = function(m)
  return {
    order = i,
    skill = {m.careerSetup.skill},
    id = m.id,
    icon = m.bigMapIcon.icon,
    label = m.name,
    description = m.description,
    formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id),
    startable = m.unlocks.startable,
    preview = m.previewFile,
    locked = not m.unlocks.visible,
    tier = m.unlocks.maxBranchlevel,
    thumbnailFile = m.thumbnailFile,
    difficulty = m.additionalAttributes.difficulty,
  }
end

function C:addRatings(change)
  if not self.isBuilding then
    log("E","","Tried to add rating, but is currently not building! ")
    return
  end
  local mission = self.mgr.activity
  if not mission then return end
  local prog = {}

  local key = mission.currentProgressKey or "default"
  prog.leaderboardKey = mission.defaultLeaderboardKey or 'recent'
  prog.progressKey = key
  prog.leaderboardChangeKeys = gameplay_missions_progress.getLeaderboardChangeKeys(mission.id)
  local dnq = prog.leaderboardKey == 'highscore' and not (change and change.aggregateChange.newBestKeysByKey[prog.leaderboardChangeKeys['highscore']])
  if not change then dnq = nil end
  local formatted = gameplay_missions_progress.formatSaveDataForUi(mission.id, key, dnq)
  prog.formattedProgress = formatted.formattedProgressByKey[key]
  prog.progressKeyTranslations = formatted.progressKeyTranslations
  if dnq and change then
    -- fixed amount shown hack for dnq
    change.aggregateChange.newBestKeysByKey[prog.leaderboardChangeKeys['highscore']] = 6
  end

  -- pre-format aggregates for the UI. This formatting might be the default later and then be moved to gameplay_missions_progress
  local ownAggregate = {}
  for i, label in ipairs(prog.formattedProgress.ownAggregate.labels) do
    local agg = {
      label = label,
      value = prog.formattedProgress.ownAggregate.rows[1][i],
    }
    if change then
      local key = prog.formattedProgress.ownAggregate.newBestKeys[i]
      agg.newBest = change.aggregateChange.newBestKeysByKey[key]
    end
    table.insert(ownAggregate,agg)
  end
  prog.formattedProgress.ownAggregate = ownAggregate
  prog.formattedProgress.attempts.leaderboardIndex = change and change.aggregateChange.newBestKeysByKey[prog.leaderboardChangeKeys['highscore']] or -1

  if change then
    for _, league in ipairs(change.unlockedLeagues or {}) do
      for i, mId in ipairs(league.missions) do
        local m = gameplay_missions_missions.getMissionById(mId)
        league.missions[i] = formatMission(m)
      end
    end
    for _, elem in ipairs(change.unlockedMissions or {}) do
      local m = gameplay_missions_missions.getMissionById(elem.id)
      elem.formatted = formatMission(m)
      if m.startCondition.type == "league" then
        elem.hidden = true
      end
    end
  end

  self:addUIElement({
    type = "ratings",
    change = change,
    progress = prog,
    --ownAggregate = ownAggregate
  })

end

function C:addLaptimesForVehicle(state, attempt)
  -- Find the best lap time
  local bestLapTime = math.huge
  local bestLapIndex = -1
  for i, lap in ipairs(state.historicTimes) do
    if lap.lapTime < bestLapTime then
      bestLapTime = lap.lapTime
      bestLapIndex = i
    end
  end

  -- Generate rows with "Best" for the best lap and time difference for others
  local rows = {}
  for i, lap in ipairs(state.historicTimes) do
    local isBest = lap.lapTime == bestLapTime
    local differenceText = isBest and "Best" or string.format("+%d:%02d:%03d",
      math.floor((lap.lapTime - bestLapTime) / 60),
      (lap.lapTime - bestLapTime) % 60,
      1000 * ((lap.lapTime - bestLapTime) % 1)
    )
    table.insert(rows, {
      { text = i },
      { format = "detailledTime", detailledTime = lap.lapTime, text = string.format("%d:%02d:%03d",
        math.floor(lap.lapTime / 60),
        lap.lapTime % 60,
        1000 * (lap.lapTime % 1)
      )},
      { text = differenceText }
    })
  end

  -- Create the grid and UI element
  local grid = {
    labels = { 'Lap', 'Time', '' },
    rows = rows,
    leaderboardIndex = bestLapIndex
  }
  self:addUIElement({
    type = "textPanel",
    header = "Lap Times",
    attempt = {
      grids = { grid }
    }
  })
end


-- will probably only be used by startPage
function C:nextPage()
  self.pageCounter = self.pageCounter + 1
  table.insert(self.uiLayout.layout,self.pageCounter,{})
end

function C:executionStarted()
  self.serializedRecoveryPromptState = core_recoveryPrompt.serializeState()
  self.gameStateBeginning = deepcopy(core_gamestate.state)
  self.recoverGameStateWhenExecutionStopped = true
  self.genericMissionDataChanged = false
  core_recoveryPrompt.setActive(false)

  if self.mgr.activity then
    guihooks.trigger('ClearTasklist')
  end
end

function C:executionStopped()
  if self.genericMissionDataChanged then
    guihooks.trigger('SetGenericMissionDataResetAll')
  end

  if self.serializedRecoveryPromptState then
    core_recoveryPrompt.deserializeState(self.serializedRecoveryPromptState)
  end
  self.serializedRecoveryPromptState = nil

  if self.recoverGameStateWhenExecutionStopped and self.gameStateBeginning then
    core_gamestate.setGameState(self.gameStateBeginning.state, self.gameStateBeginning.appLayout, self.gameStateBeginning.menuItems, self.gameStateBeginning.options)
  end
  self.recoverGameStateWhenExecutionStopped = nil
  self.gameStateBeginning = nil

  if self.mgr.activity then
    guihooks.trigger('ClearTasklist')
  end
end




return _flowgraph_createModule(C)