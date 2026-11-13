-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function normalizeLimit(limit)
  limit = tonumber(limit)
  if not limit or limit < 1 then return nil end
  return math.floor(limit)
end

function M.isSimpleMenu()
  return Engine.UI.isSimpleMenu()
end

function M.getCurrentLevelLimit()
  local levelName = getCurrentLevelIdentifier()
  local level = levelName and core_levels.getLevelByName(levelName)
  return normalizeLimit(level and level.multiseat and level.multiseat.maxPlayers)
end

-- the running multiseat gamemode's maximum, a hard limit on every platform
function M.getCurrentModeLimit()
  local manager = gameplay_multiseat_gamemodeManager
  return normalizeLimit(manager and manager.getMaxPlayers and manager.getMaxPlayers())
end

-- softLimit is the hardware/level recommendation, only enforced in the simple menu or when softIsHard is set
-- modeLimit is what the content supports and is always enforced
function M.getState(softLimit, playerCount, modeLimit, softIsHard)
  softLimit = normalizeLimit(softLimit)
  modeLimit = normalizeLimit(modeLimit)
  playerCount = math.max(0, tonumber(playerCount) or 0)
  softIsHard = softIsHard == true or M.isSimpleMenu()
  local hardLimit = modeLimit
  if softIsHard and softLimit then hardLimit = math.min(hardLimit or softLimit, softLimit) end
  local limit = hardLimit or softLimit
  return {
    limit = limit,
    hard = hardLimit ~= nil,
    atLimit = limit ~= nil and playerCount >= limit,
    exceeded = limit ~= nil and playerCount > limit,
    warning = not softIsHard and softLimit ~= nil and playerCount > softLimit and {
      txt = "ui.multiseat.playerLimitWarning",
      context = {count = softLimit},
    } or nil,
  }
end

function M.getCurrentLevelState(playerCount, softIsHard)
  return M.getState(M.getCurrentLevelLimit(), playerCount, M.getCurrentModeLimit(), softIsHard)
end

return M
