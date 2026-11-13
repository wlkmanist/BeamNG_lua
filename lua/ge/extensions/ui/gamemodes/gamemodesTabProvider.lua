local M = {}

local function isNetworkedSession()
  return multiplayer_sessionManager
    and multiplayer_sessionManager.getCurrentSession() ~= nil
end

local function requestGamemodeData()
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.requestMultiplayerTabData()
    end
  else
    if gameplay_multiseat_gamemodeManager then
      gameplay_multiseat_gamemodeManager.requestGamemodeData()
    end
  end
end

local function startGamemode(name, settings)
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.startGamemode(name, settings)
    end
  else
    if gameplay_multiseat_gamemodeManager then
      gameplay_multiseat_gamemodeManager.start(name, settings)
    end
  end
end

local function stopGamemode()
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.stopGamemode()
    end
  else
    if gameplay_multiseat_gamemodeManager then
      gameplay_multiseat_gamemodeManager.stop()
    end
  end
end

local function restartGamemode(name, settings)
  if isNetworkedSession() then
    return
  end
  if gameplay_multiseat_gamemodeManager then
    gameplay_multiseat_gamemodeManager.restart(name, settings)
  end
end

local function selectGamemode(name)
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.selectGamemodeForOwner(name)
    end
  end
end

local function deselectGamemode()
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.deselectGamemodeForOwner()
    end
  end
end

local function startReadyUp(gamemodeInfo)
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.startReadyUp(gamemodeInfo)
    end
  end
end

local function stopReadyUp()
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.stopReadyUp()
    end
  end
end

local function setOwnerPreReadyRole(role)
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.setOwnerPreReadyRole(role)
    end
  end
end

local function requestSetOwnGamemodeRole(role)
  if isNetworkedSession() then
    if multiplayer_uiBackend_multiplayerUIManager then
      multiplayer_uiBackend_multiplayerUIManager.requestSetOwnGamemodeRole(role)
    end
  end
end

M.requestGamemodeData = requestGamemodeData
M.startGamemode = startGamemode
M.stopGamemode = stopGamemode
M.restartGamemode = restartGamemode
M.selectGamemode = selectGamemode
M.deselectGamemode = deselectGamemode
M.startReadyUp = startReadyUp
M.stopReadyUp = stopReadyUp
M.setOwnerPreReadyRole = setOwnerPreReadyRole
M.requestSetOwnGamemodeRole = requestSetOwnGamemodeRole

return M
