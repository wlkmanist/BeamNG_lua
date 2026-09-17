-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'RallyAICompetitors'
local USER_CONFIG_REL = 'gameplay/rally/aiCompetitorsConfig.json'

-- Medal threshold used to anchor simulated competitor pace. Change this one key
-- to 'silverTime' to switch both standalone-stage and rally-loop simulation.
M.referenceStarKey = 'silverTime'

function M.getReferenceTime(missionTypeData)
  local value = missionTypeData and tonumber(missionTypeData[M.referenceStarKey])
  return value and value > 0 and value or nil
end

local function loadAiCompetitorsConfig()
  local params = jsonReadFile(USER_CONFIG_REL)
  if not params then
    log('E', logTag, string.format('Failed to create or read AI competitors config: %s', USER_CONFIG_REL))
    return nil
  end
  return params
end

local PARAMS = loadAiCompetitorsConfig()
if PARAMS and PARAMS.general then
  for key, value in pairs(PARAMS.general) do
    PARAMS[key] = value
  end
  PARAMS.general = nil
end

local COMPETITORS = (PARAMS and (PARAMS.competitors or PARAMS.drivers)) or {}
local COMPETITORS_COUNT = #COMPETITORS

local OUTCOMES = {
  'safe',
  'push',
  'minor_incident',
  'major_incident',
  'dnf',
}

local function sampleOutcomeFromWeights(weights)
  local u = math.random()
  local cumulative = 0
  for i, weight in ipairs(weights) do
    cumulative = cumulative + weight
    if u <= cumulative then
      return OUTCOMES[i]
    end
  end
  return OUTCOMES[#OUTCOMES]
end

local function sampleNormal(mu, sigma)
  local u1 = math.max(math.random(), 1e-300)
  local u2 = math.random()
  local radius = math.sqrt(-2 * math.log(u1))
  local angle = 2 * math.pi * u2
  return mu + sigma * (radius * math.cos(angle))
end

local function stdScaleFromConsistency(consistency, P)
  P = P or PARAMS
  return P.consistency_std_min_scale
    + (1.0 - P.consistency_std_min_scale) * (1.0 - consistency) ^ P.consistency_std_curve
end

local function buildOutcomeWeights(skill, consistency, risk, P)
  P = P or PARAMS
  local weights = {}
  weights[1] = P.safe_weight_base * (1.0 - P.risk_reduces_safe * risk)
  weights[2] = (P.push_weight_floor + P.skill_increases_push * skill) * (1.0 + P.risk_increases_push * risk)
  local riskTail = risk ^ P.risk_tail_exponent
  weights[3] = P.minor_tail_weight * riskTail * (1.0 - P.skill_reduces_minor * skill)
  weights[4] = P.major_tail_weight * riskTail * (1.0 - P.skill_reduces_major * skill)
  weights[5] = P.dnf_tail_weight * riskTail * (1.0 - P.skill_reduces_dnf * skill)

  local total = 0
  for i = 1, #weights do
    weights[i] = math.max(weights[i], 1e-15)
    total = total + weights[i]
  end
  for i = 1, #weights do
    weights[i] = weights[i] / total
  end
  return weights
end

local function outcomeMeanStd(outcome, referenceTime, skill, consistency, risk, P)
  P = P or PARAMS
  if outcome == 'dnf' then
    return nil
  end

  local stdScale = stdScaleFromConsistency(consistency, P)
  local mean, std

  if outcome == 'safe' then
    mean = referenceTime * (1.0 + P.relative_mean_safe + P.pace_skill_safe * skill)
    std = referenceTime * P.std_fraction_safe * stdScale
  elseif outcome == 'push' then
    mean = referenceTime * (1.0 + P.relative_mean_push + P.pace_skill_push * skill)
    std = referenceTime * P.std_fraction_push * stdScale
  elseif outcome == 'minor_incident' then
    mean = referenceTime * (1.0 + P.relative_mean_minor)
    std = referenceTime * P.std_fraction_minor * stdScale
  elseif outcome == 'major_incident' then
    mean = referenceTime * (1.0 + P.relative_mean_major)
    std = referenceTime * P.std_fraction_major * stdScale
  end

  return mean, std
end

local INCIDENT_SECONDS = 5

local function sampleIncidentCount(outcome)
  if outcome == 'minor_incident' then
    return math.random(1, 2)
  elseif outcome == 'major_incident' then
    return math.random(2, 5)
  end
  return 0
end

local function sampleSingleCompetitorTime(referenceTime, skill, consistency, risk)
  local weights = buildOutcomeWeights(skill, consistency, risk)
  local outcome = sampleOutcomeFromWeights(weights)

  if outcome == 'dnf' then
    return nil
  end

  local mean, std = outcomeMeanStd(outcome, referenceTime, skill, consistency, risk, nil)
  local time = sampleNormal(mean, std)
  local nIncidents = sampleIncidentCount(outcome)
  if nIncidents > 0 then
    time = time + nIncidents * INCIDENT_SECONDS
  end
  return time
end

local function sampleAllCompetitorTimes(referenceTime, quiet)
  local times = {}
  if not quiet then
    log('I', logTag, "\nSampling stage times for " .. COMPETITORS_COUNT .. " competitors with reference time " .. referenceTime .. ".")
  end
  for i = 1, COMPETITORS_COUNT do
    local competitor = COMPETITORS[i]
    times[i] = sampleSingleCompetitorTime(referenceTime, competitor.skill, competitor.consistency, competitor.risk)
    if not quiet then
      if times[i] then
        log('I', logTag, "Competitor " .. competitor.name .. " stage time: " .. times[i] .. " seconds.")
      else
        log('I', logTag, "Competitor " .. competitor.name .. " DNF.")
      end
    end
  end
  return times
end

local sqrtTwoPi = math.sqrt(2.0 * math.pi)
local pdfStdFloor = 1e-12

local function normalPdfAtTime(timeSec, mean, std)
  local stdSafe = math.max(std, pdfStdFloor)
  local z = (timeSec - mean) / stdSafe
  return math.exp(-0.5 * z * z) / (stdSafe * sqrtTwoPi)
end

--- Gaussian mixture over finish-time outcomes (editor preview). Uses the same weights and mean/std rules as sampling.
local function mixtureDensityTimes(paramTable, referenceSec, skill, consistency, risk, timeLo, timeHi, sampleCount, precomputedWeights)
  local P = paramTable or PARAMS
  local weights = precomputedWeights or buildOutcomeWeights(skill, consistency, risk, P)
  local mixture = {}
  local comps = { {}, {}, {}, {}, {} }
  local times = {}
  local n = math.max(2, math.floor(sampleCount or 500))
  local span = timeHi - timeLo
  for i = 1, n do
    times[i] = timeLo + span * (i - 1) / (n - 1)
    mixture[i] = 0
    for o = 1, 5 do
      comps[o][i] = 0
    end
  end
  for outcomeIdx = 1, 4 do
    local outcome = OUTCOMES[outcomeIdx]
    local meanTime, stdTime = outcomeMeanStd(outcome, referenceSec, skill, consistency, risk, P)
    if meanTime and stdTime then
      for i = 1, n do
        local pdf = normalPdfAtTime(times[i], meanTime, stdTime)
        comps[outcomeIdx][i] = pdf
        mixture[i] = mixture[i] + weights[outcomeIdx] * pdf
      end
    end
  end
  return {
    times = times,
    mixture = mixture,
    weights = weights,
    components = comps,
    sampleCount = n,
  }
end

function M.computeMixtureWeights(paramTable, skill, risk)
  return buildOutcomeWeights(skill, 0.5, risk, paramTable)
end

M.mixtureDensityTimes = mixtureDensityTimes

--- Stage time / gap string with tenths of a second (same rules as rally loop formatStageTime / formatSSTime).
local function formatStageTime(seconds)
  if not seconds then
    return nil
  end
  local roundedSeconds = math.floor(seconds * 10 + 0.5) / 10
  local hours = math.floor(roundedSeconds / 3600)
  local minutes = math.floor((roundedSeconds % 3600) / 60)
  local secs = math.floor(roundedSeconds % 60)
  local tenths = math.floor((roundedSeconds % 1) * 10) % 10

  if hours > 0 then
    return string.format("%d:%02d:%02d.%d", hours, minutes, secs, tenths)
  elseif minutes > 0 then
    return string.format("%d:%02d.%d", minutes, secs, tenths)
  else
    return string.format("%d.%d", secs, tenths)
  end
end

--- Per-stage values for one driver: nil = DNF on that stage (and forced DNF on later stages).
local function propagateStagesSequential(getTimeForStage, stageCount)
  local stages = {}
  local failed = false
  for s = 1, stageCount do
    if failed then
      stages[s] = nil
    else
      local t = getTimeForStage(s)
      stages[s] = t
      if t == nil then
        failed = true
      end
    end
  end
  return stages
end

--- Sort key: fewer DNF columns is better; then lower sum of valid stage times (full total if no DNF, else sum before first DNF).
local function sortKeysFromStages(stageVals, stageCount)
  local firstDnf = nil
  for s = 1, stageCount do
    if stageVals[s] == nil then
      firstDnf = s
      break
    end
  end
  if not firstDnf then
    local sum = 0
    for s = 1, stageCount do
      sum = sum + stageVals[s]
    end
    return 0, sum
  end
  local dnfCols = stageCount - firstDnf + 1
  local sum = 0
  for s = 1, firstDnf - 1 do
    sum = sum + stageVals[s]
  end
  return dnfCols, sum
end

local function computeLeaderboardSingle(playerTime, silverTime, playerName, playerFinalSortSecs)
  local useDefaultPlayerName = playerName == nil
  playerName = playerName or "Player"
  local result = { rows = {} }

  if type(playerTime) ~= 'number' or type(silverTime) ~= 'number' or silverTime <= 0 then
    return result
  end

  local officialPlayerTime =
    type(playerFinalSortSecs) == 'number' and playerFinalSortSecs > 0 and playerFinalSortSecs or nil

  local competitorTimes = sampleAllCompetitorTimes(silverTime, true)
  local sortedEntries = {
    { name = playerName, time = officialPlayerTime or playerTime, isPlayer = true },
  }
  for i = 1, COMPETITORS_COUNT do
    sortedEntries[#sortedEntries + 1] = {
      name = COMPETITORS[i].name,
      time = competitorTimes[i],
      isPlayer = false,
    }
  end

  local fastestTime = nil
  for _, entry in ipairs(sortedEntries) do
    if entry.time and (not fastestTime or entry.time < fastestTime) then
      fastestTime = entry.time
    end
  end

  table.sort(sortedEntries, function(a, b)
    local ta, tb = a.time, b.time
    if ta == nil and tb == nil then
      return tostring(a.name or "") < tostring(b.name or "")
    end
    if ta == nil then
      return false
    end
    if tb == nil then
      return true
    end
    if type(ta) == "number" and type(tb) == "number" then
      return ta < tb
    end
    return tostring(a.name or "") < tostring(b.name or "")
  end)

  local function formatGapBehind(seconds)
    if seconds == nil then
      return "-"
    end
    if math.abs(seconds) < 1e-9 then
      return "-"
    end
    return "+" .. formatStageTime(seconds)
  end

  local playerRowIndex = nil
  for rank, entry in ipairs(sortedEntries) do
    if entry.isPlayer then
      playerRowIndex = rank
    end
    if entry.time == nil then
      result.rows[#result.rows + 1] = {
        position = rank,
        name = entry.name,
        nameTranslationKey = entry.isPlayer and useDefaultPlayerName and "missions.aiCompetitorsLeaderboard.player" or nil,
        time = "DNF",
        delta = "",
        deltaVsLeader = "-",
        deltaVsAhead = "-",
        dnf = true,
      }
    else
      local timeText = formatStageTime(entry.time)
      local deltaText = ""
      if fastestTime and (entry.time - fastestTime) > 1e-6 then
        deltaText = "+" .. formatStageTime(entry.time - fastestTime)
      end

      local vsLeader = "-"
      local vsAhead = "-"
      if fastestTime then
        vsLeader = formatGapBehind(entry.time - fastestTime)
      end
      if rank > 1 then
        local ahead = sortedEntries[rank - 1]
        if ahead and ahead.time then
          vsAhead = formatGapBehind(entry.time - ahead.time)
        end
      end

      result.rows[#result.rows + 1] = {
        position = rank,
        name = entry.name,
        nameTranslationKey = entry.isPlayer and useDefaultPlayerName and "missions.aiCompetitorsLeaderboard.player" or nil,
        time = timeText,
        delta = deltaText,
        deltaVsLeader = vsLeader,
        deltaVsAhead = vsAhead,
        dnf = false,
      }
    end
  end

  result.playerRowIndex = playerRowIndex
  return result
end

local function computeLeaderboardMulti(playerTimes, silverTimes, playerName, playerFinalSortSecs)
  local useDefaultPlayerName = playerName == nil
  playerName = playerName or "Player"
  local result = {
    rows = {},
    multiStage = true,
    stageCount = 0,
  }

  if type(playerTimes) ~= 'table' or type(silverTimes) ~= 'table' then
    return result
  end

  local S = #playerTimes
  if S < 1 or S ~= #silverTimes then
    return result
  end

  for s = 1, S do
    local ref = silverTimes[s]
    if type(ref) ~= 'number' or ref <= 0 then
      return result
    end
  end

  result.stageCount = S

  local officialSort =
    type(playerFinalSortSecs) == 'number' and playerFinalSortSecs > 0 and playerFinalSortSecs or nil

  local function playerStageTime(s)
    local v = playerTimes[s]
    if type(v) == 'number' and v >= 0 then
      return v
    end
    return nil
  end

  local entries = {
    {
      name = playerName,
      isPlayer = true,
      stages = propagateStagesSequential(playerStageTime, S),
    },
  }

  for i = 1, COMPETITORS_COUNT do
    local comp = COMPETITORS[i]
    entries[#entries + 1] = {
      name = comp.name,
      isPlayer = false,
      stages = propagateStagesSequential(function(stageIdx)
        return sampleSingleCompetitorTime(silverTimes[stageIdx], comp.skill, comp.consistency, comp.risk)
      end, S),
    }
  end

  for _, e in ipairs(entries) do
    local dnfCols, tsum = sortKeysFromStages(e.stages, S)
    e.dnfColumnCount = dnfCols
    e.timeSum = tsum
    if e.isPlayer and officialSort then
      e.finalSortSecs = officialSort
    elseif dnfCols == 0 then
      local total = 0
      for s = 1, S do
        total = total + e.stages[s]
      end
      e.finalSortSecs = total
    else
      e.finalSortSecs = 1e18 + tsum
    end
  end

  table.sort(entries, function(a, b)
    if a.dnfColumnCount ~= b.dnfColumnCount then
      return a.dnfColumnCount < b.dnfColumnCount
    end
    if math.abs(a.finalSortSecs - b.finalSortSecs) > 1e-6 then
      return a.finalSortSecs < b.finalSortSecs
    end
    return tostring(a.name or "") < tostring(b.name or "")
  end)

  local playerRowIndex = nil
  for rank, entry in ipairs(entries) do
    if entry.isPlayer then
      playerRowIndex = rank
    end

    local stageCells = {}
    for s = 1, S do
      local t = entry.stages[s]
      if t == nil then
        stageCells[s] = { dnf = true }
      else
        stageCells[s] = { dnf = false, timeText = formatStageTime(t) }
      end
    end

    local finalDnf = entry.dnfColumnCount > 0
    local finalTimeText = nil
    if not finalDnf then
      local total = nil
      if entry.isPlayer and officialSort then
        total = officialSort
      else
        total = 0
        for s = 1, S do
          total = total + entry.stages[s]
        end
      end
      finalTimeText = formatStageTime(total)
    end

    result.rows[#result.rows + 1] = {
      position = rank,
      name = entry.name,
      nameTranslationKey = entry.isPlayer and useDefaultPlayerName and "missions.aiCompetitorsLeaderboard.player" or nil,
      stageCells = stageCells,
      finalDnf = finalDnf,
      finalTime = finalTimeText,
    }
  end

  result.playerRowIndex = playerRowIndex
  return result
end

--- Overwrite the player row total with the official rally event-log total (all SS times + all penalties).
--- Multi-stage: `finalTime` / `finalDnf`. Single-stage: `time` / `dnf` (deltas are not recomputed).
function M.applyOfficialPlayerTotalSeconds(leaderboard, totalSecs)
  if type(leaderboard) ~= 'table' or type(leaderboard.rows) ~= 'table' then
    return
  end
  if type(totalSecs) ~= 'number' or totalSecs <= 0 then
    return
  end
  local idx = leaderboard.playerRowIndex
  if type(idx) ~= 'number' or idx < 1 or idx > #leaderboard.rows then
    return
  end
  local row = leaderboard.rows[idx]
  if not row then
    return
  end
  local txt = formatStageTime(totalSecs)
  if leaderboard.multiStage == true and type(leaderboard.stageCount) == 'number' and leaderboard.stageCount >= 1 then
    row.finalTime = txt
    row.finalDnf = false
  else
    row.time = txt
    row.dnf = false
  end
end

--- Single stage: (playerTime, silverTime) as numbers. Loop stage layout: (playerTimes, silverTimes) as equal-length arrays (length >= 1).
--- Optional `playerFinalSortSecs`: official total seconds (stages + penalties) for ranking the player row; AI rows rank by sum of simulated stage times (or DNF tier).
function M.computeLeaderboard(playerTimeOrTimes, silverTimeOrTimes, playerName, playerFinalSortSecs)
  if type(playerTimeOrTimes) == 'table' and type(silverTimeOrTimes) == 'table' then
    local n = #playerTimeOrTimes
    if n >= 1 then
      return computeLeaderboardMulti(playerTimeOrTimes, silverTimeOrTimes, playerName, playerFinalSortSecs)
    end
    return { rows = {} }
  end
  return computeLeaderboardSingle(playerTimeOrTimes, silverTimeOrTimes, playerName, playerFinalSortSecs)
end

return M
