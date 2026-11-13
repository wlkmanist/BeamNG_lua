-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
Source-agnostic scoreboard data layer.
Manages player score state and pushes to the UI via the "scoreboard" stream.
Can be used by local gameplay (splitscreen) or wrapped by a network layer (multiplayer).
]]

local M = {}

local defaultScoreboardStyle = {
  entries = {
    { key = "score", name = "Score", order = 1, type = "points" },
  },
  orderBy = { key = "score", direction = "desc" },
}

local scoreboard = {
  players = {},
  style = nil,
  localMPClientId = nil,
}
local active = false

local function getScore(player, key)
  local scores = player.scores
  return scores and scores[key] or 0
end

local function orderPlayersForUI()
  local list = {}
  for _, player in pairs(scoreboard.players) do
    list[#list + 1] = player
  end

  local orderBy = scoreboard.style and scoreboard.style.orderBy
  local orderKey = orderBy and (orderBy.key or "score")
  local isAsc = orderBy and orderBy.direction == "asc"

  table.sort(list, function(a, b)
    if orderBy then
      local aDq = a.status == "disqualified" and 1 or 0
      local bDq = b.status == "disqualified" and 1 or 0
      if aDq ~= bDq then return aDq < bDq end
      local aVal = getScore(a, orderKey)
      local bVal = getScore(b, orderKey)
      if aVal ~= bVal then
        if isAsc then return aVal < bVal else return aVal > bVal end
      end
    end
    return (a.playerIndex or 0) < (b.playerIndex or 0)
  end)

  if not orderBy then
    for i, player in ipairs(list) do
      player.rank = i
    end
    return list
  end

  local rank = 0
  local prevVal, prevDq
  for i, player in ipairs(list) do
    local dq = player.status == "disqualified" and 1 or 0
    local val = getScore(player, orderKey)
    if i == 1 or val ~= prevVal or dq ~= prevDq then
      rank = rank + 1
      prevVal = val
      prevDq = dq
    end
    player.rank = rank
  end
  return list
end

local function pushToUI()
  guihooks.queueStream("scoreboard", {
    players = orderPlayersForUI(),
    style = scoreboard.style,
    localMPClientId = scoreboard.localMPClientId,
  })
end

local function clear()
  scoreboard = {
    players = {},
    style = defaultScoreboardStyle,
    localMPClientId = nil,
  }
  active = false
  pushToUI()
end

local function isActive()
  return active
end

local function ensurePlayer(playerId, name, color, playerIndex)
  if not scoreboard.players[playerId] then
    scoreboard.players[playerId] = {mpClientId = playerId, name = name or playerId, scores = {}, status = nil, color = color, playerIndex = playerIndex}
  else
    if color ~= nil then scoreboard.players[playerId].color = color end
    if playerIndex ~= nil then scoreboard.players[playerId].playerIndex = playerIndex end
    if name ~= nil then scoreboard.players[playerId].name = name end
  end
end

local function setPlayerName(playerId, name)
  ensurePlayer(playerId, name)
  scoreboard.players[playerId].name = name
end

local function setPlayerColor(playerId, color)
  ensurePlayer(playerId)
  scoreboard.players[playerId].color = color
  pushToUI()
end

local function updatePlayerScores(playerId, scores)
  if not active then return end
  ensurePlayer(playerId)
  for key, value in pairs(scores) do
    scoreboard.players[playerId].scores[key] = value
  end
  pushToUI()
end

local function updatePlayerStatus(playerId, status)
  if not active then return end
  ensurePlayer(playerId)
  scoreboard.players[playerId].status = status
  pushToUI()
end

local function pulsePlayerColor(playerId, color)
  if not active then return end
  guihooks.trigger('scoreboardPlayerPulseColor', {mpClientId = playerId, color = color})
end

local function setLocalMPClientId(id)
  scoreboard.localMPClientId = id
  pushToUI()
end

local function getPlayers()
  return scoreboard.players
end

-- @param _scoreboardStyle table  the style definition for the scoreboard UI
local function startNewScoreboard(_scoreboardStyle)
  clear()
  active = true
  scoreboard.style = _scoreboardStyle or defaultScoreboardStyle
  pushToUI()
end

M.startNewScoreboard = startNewScoreboard
M.clear = clear
M.ensurePlayer = ensurePlayer
M.setPlayerName = setPlayerName
M.updatePlayerScores = updatePlayerScores
M.updatePlayerStatus = updatePlayerStatus
M.pulsePlayerColor = pulsePlayerColor
M.setPlayerColor = setPlayerColor
M.setLocalMPClientId = setLocalMPClientId
M.getPlayers = getPlayers
M.isActive = isActive

return M
