-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local aiCompetitorsModel = require("/lua/ge/extensions/gameplay/rally/aiCompetitors")

local configPath = "gameplay/rally/aiCompetitorsConfig.json"

local outcomeDnf = 5
local numOutcomes = 5
local outcomeLabels = {
  "Safe / Clean",
  "Push / Aggressive",
  "Minor Mistake",
  "Major Issue",
  "DNF / Terminal",
}

local defaultGeneral = {
  min_reference_time_sec = 5.0,
  max_time_multiplier_vs_reference = 2.35,
  risk_tail_exponent = 1.58,
  safe_weight_base = 0.70,
  risk_reduces_safe = 0.36,
  push_weight_floor = 0.06,
  skill_increases_push = 0.40,
  risk_increases_push = 0.32,
  minor_tail_weight = 0.60,
  major_tail_weight = 0.38,
  dnf_tail_weight = 0.52,
  skill_reduces_minor = 0.46,
  skill_reduces_major = 0.42,
  skill_reduces_dnf = 0.38,
  relative_mean_safe = 0.036,
  pace_skill_safe = -0.046,
  relative_mean_push = -0.006,
  pace_skill_push = -0.056,
  relative_mean_minor = 0.072,
  relative_mean_major = 0.175,
  std_fraction_safe = 0.022,
  std_fraction_push = 0.034,
  std_fraction_minor = 0.052,
  std_fraction_major = 0.078,
  consistency_std_min_scale = 0.15,
  consistency_std_curve = 1.15,
}

local function defaultGeneralDict()
  local t = {}
  for k, v in pairs(defaultGeneral) do
    t[k] = v
  end
  return t
end

local function mergeGeneral(overrides)
  local base = defaultGeneralDict()
  if overrides then
    for key, value in pairs(overrides) do
      if base[key] ~= nil and value ~= nil then
        base[key] = value
      end
    end
  end
  return base
end

local function defaultUiDict()
  return {
    default_player_time_sec = 100.0,
    default_appearance_mode = "dark",
    default_color_theme = "blue",
    window_min_width = 1100,
    window_min_height = 720,
    slider_min = 0,
    slider_max = 1,
    default_slider_value = 0.5,
    rng_seed = nil,
  }
end

local function defaultCompetitorsPreset()
  local row = function(name)
    return { name = name, skill = 0.5, consistency = 0.5, risk = 0.5 }
  end
  return {
    row("A"),
    row("B"),
    row("C"),
    row("D"),
    row("E"),
  }
end

local function clampToUnitInterval(x)
  if x < 0 then
    return 0
  end
  if x > 1 then
    return 1
  end
  return x
end

local function normalizeCompetitorTraits(d)
  local out = {}
  for k, v in pairs(d) do
    out[k] = v
  end
  local default = 0.5
  local vals = {}
  for _, key in ipairs({ "skill", "consistency", "risk" }) do
    local v = out[key]
    local f = default
    if type(v) == "number" then
      f = v
    elseif type(v) == "string" then
      f = tonumber(v) or default
    end
    vals[#vals + 1] = f
  end
  local scaleHundred = math.max(vals[1], vals[2], vals[3]) > 1.0
  for i, key in ipairs({ "skill", "consistency", "risk" }) do
    local x = vals[i]
    if scaleHundred then
      x = x / 100.0
    end
    out[key] = clampToUnitInterval(x)
  end
  return out
end

local function configWithDefaults(raw)
  raw = raw or {}
  local general = mergeGeneral(raw.general)
  local competitors = raw.competitors
  if type(competitors) ~= "table" or #competitors == 0 then
    local alt = raw.drivers
    if type(alt) == "table" and #alt > 0 then
      competitors = alt
    else
      competitors = defaultCompetitorsPreset()
    end
  end
  local norm = {}
  for i = 1, #competitors do
    norm[i] = normalizeCompetitorTraits(competitors[i])
  end
  local ui = defaultUiDict()
  if type(raw.ui) == "table" then
    for k, v in pairs(raw.ui) do
      ui[k] = v
    end
  end
  return general, norm, ui
end

local function loadRawConfig()
  local data = jsonReadFile(configPath)
  if type(data) ~= "table" then
    return {}
  end
  return data
end

local roundSaveFloats
roundSaveFloats = function(obj, ndigits)
  ndigits = ndigits or 3
  local t = type(obj)
  if t == "boolean" then
    return obj
  end
  if t == "number" then
    local roundedInt = math.floor(obj + 0.5)
    if math.abs(obj - roundedInt) < 1e-9 then
      return roundedInt
    end
    local m = 10 ^ ndigits
    return math.floor(obj * m + 0.5) / m
  end
  if t == "table" then
    local maxIndex = 0
    local onlyNumericKeys = true
    for k in pairs(obj) do
      if type(k) ~= "number" then
        onlyNumericKeys = false
        break
      end
      if k > maxIndex then
        maxIndex = k
      end
    end
    if onlyNumericKeys and maxIndex > 0 then
      local out = {}
      for i = 1, maxIndex do
        out[i] = roundSaveFloats(obj[i], ndigits)
      end
      return out
    end
    local out = {}
    for k, v in pairs(obj) do
      out[k] = roundSaveFloats(v, ndigits)
    end
    return out
  end
  return obj
end

local function saveConfig(generalTable, competitorsList, uiTable)
  local payload = {
    general = roundSaveFloats(generalTable, 3),
    competitors = roundSaveFloats(competitorsList, 3),
    ui = roundSaveFloats(uiTable, 3),
  }
  return jsonWriteFile(configPath, payload, true)
end

local function sliderRangeForGeneralParam(fieldName)
  if fieldName == "min_reference_time_sec" then
    return 0.5, 600.0
  end
  if fieldName == "max_time_multiplier_vs_reference" then
    return 1.0, 5.0
  end
  if fieldName == "risk_tail_exponent" then
    return 0.2, 4.0
  end
  if fieldName == "safe_weight_base"
    or fieldName == "push_weight_floor"
    or fieldName == "minor_tail_weight"
    or fieldName == "major_tail_weight"
    or fieldName == "dnf_tail_weight"
  then
    return 0.0, 2.0
  end
  if fieldName == "risk_reduces_safe"
    or fieldName == "skill_increases_push"
    or fieldName == "risk_increases_push"
    or fieldName == "skill_reduces_minor"
    or fieldName == "skill_reduces_major"
    or fieldName == "skill_reduces_dnf"
  then
    return 0.0, 1.0
  end
  if string.sub(fieldName, 1, 14) == "relative_mean_" then
    return -0.35, 0.6
  end
  if string.sub(fieldName, 1, 11) == "pace_skill_" then
    return -0.35, 0.6
  end
  if string.sub(fieldName, 1, 13) == "std_fraction_" then
    return 0.001, 0.5
  end
  if fieldName == "consistency_std_min_scale" then
    return 0.01, 0.65
  end
  if fieldName == "consistency_std_curve" then
    return 0.5, 3.5
  end
  error("no slider range for " .. tostring(fieldName))
end

local function buildGeneralSliderBounds()
  local bounds = {}
  for k in pairs(defaultGeneral) do
    local lo, hi = sliderRangeForGeneralParam(k)
    bounds[k] = { lo = lo, hi = hi }
  end
  return bounds
end

local generalSliderBounds = buildGeneralSliderBounds()

local generalFieldNames = {}
do
  for k in pairs(generalSliderBounds) do
    generalFieldNames[#generalFieldNames + 1] = k
  end
  table.sort(generalFieldNames)
end

local function clampParamToSliderRange(fieldName, value)
  local b = generalSliderBounds[fieldName]
  if not b then
    return value
  end
  local v = tonumber(value) or 0
  if v < b.lo then
    return b.lo
  end
  if v > b.hi then
    return b.hi
  end
  return v
end

local function formatParamValue(value)
  local v = tonumber(value) or 0
  local av = math.abs(v)
  if av >= 100 then
    return string.format("%.2f", v)
  end
  if av >= 10 then
    return string.format("%.3f", v)
  end
  if av >= 1 then
    return string.format("%.4f", v)
  end
  return string.format("%.5g", v)
end

local function fieldLabel(snakeName)
  local parts = {}
  for part in string.gmatch(snakeName, "[^_]+") do
    parts[#parts + 1] = part:sub(1, 1):upper() .. part:sub(2):lower()
  end
  return table.concat(parts, " ")
end

local function sliderToUnit(value, sliderMin, sliderMax)
  local span = sliderMax - sliderMin
  if span <= 0 then
    return clampToUnitInterval(value)
  end
  return clampToUnitInterval((value - sliderMin) / span)
end

local generalParamGroups = {
  {
    title = "Stage limits",
    blurb = "Clamp reference input and cap finished stage times (DNF is handled separately).",
    fields = { "min_reference_time_sec", "max_time_multiplier_vs_reference" },
  },
  {
    title = "Safe & Push (mixture weights)",
    blurb = "Risk reduces Safe and boosts Push; Skill adds Push. Consistency does not change these weights.",
    fields = {
      "safe_weight_base",
      "risk_reduces_safe",
      "push_weight_floor",
      "skill_increases_push",
      "risk_increases_push",
    },
  },
  {
    title = "Incidents & DNF (risk tail + skill)",
    blurb = "Tail mass scales with Risk^exponent; Skill suppresses each tail outcome separately.",
    fields = {
      "risk_tail_exponent",
      "minor_tail_weight",
      "skill_reduces_minor",
      "major_tail_weight",
      "skill_reduces_major",
      "dnf_tail_weight",
      "skill_reduces_dnf",
    },
  },
  {
    title = "Pace vs reference (relative means)",
    blurb = "Mean stage time = reference x (1 + relative offset). Skill adjusts Safe and Push pace; Minor/Major use offset only.",
    fields = {
      "relative_mean_safe",
      "pace_skill_safe",
      "relative_mean_push",
      "pace_skill_push",
      "relative_mean_minor",
      "relative_mean_major",
    },
  },
  {
    title = "Base std dev per outcome",
    blurb = "Std dev = reference x std_fraction x consistency_std_scale (Gaussian in seconds, scales with reference).",
    fields = {
      "std_fraction_safe",
      "std_fraction_push",
      "std_fraction_minor",
      "std_fraction_major",
    },
  },
  {
    title = "Consistency on std dev",
    blurb = "Only Consistency scales finished-stage spread (all outcomes). Risk does not widen std in this model.",
    fields = { "consistency_std_min_scale", "consistency_std_curve" },
  },
}

M.configPath = configPath
M.outcomeDnf = outcomeDnf
M.numOutcomes = numOutcomes
M.outcomeLabels = outcomeLabels
M.mergeGeneral = mergeGeneral
M.defaultUiDict = defaultUiDict
M.configWithDefaults = configWithDefaults
M.loadRawConfig = loadRawConfig
M.saveConfig = saveConfig
M.generalSliderBounds = generalSliderBounds
M.generalFieldNames = generalFieldNames
M.clampParamToSliderRange = clampParamToSliderRange
M.formatParamValue = formatParamValue
M.fieldLabel = fieldLabel
M.sliderToUnit = sliderToUnit
M.generalParamGroups = generalParamGroups
M.computeMixtureWeights = aiCompetitorsModel.computeMixtureWeights
M.mixtureDensityTimes = aiCompetitorsModel.mixtureDensityTimes

return M
