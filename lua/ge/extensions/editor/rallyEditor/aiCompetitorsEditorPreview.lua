-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local model = require("/lua/ge/extensions/editor/rallyEditor/aiCompetitorsEditorModel")

local M = {}

local CHART_SAMPLE_COUNT = 500

--- Graph parameters
local BROAD_TIME_MIN_FACTOR = 0.65
local BROAD_TIME_SPAN_CAP_FACTOR = 2.8
local MIXTURE_PEAK_EPSILON = 1e-30
local ZOOM_PEAK_FRACTION = 0.02
local ZOOM_MARGIN_RELATIVE = 0.1
local ZOOM_MARGIN_MIN_FRAC_OF_BROAD = 0.01
local ZOOM_MIN_SPAN_FRAC_OF_BROAD = 0.055
local ZOOM_MAX_RETAINED_FRAC_OF_BROAD = 0.9

local function narrowTimeRangeFromMixture(densityResult, broadTimeLo, broadTimeHi)
  local mixture = densityResult.mixture
  local times = densityResult.times
  local sampleCount = densityResult.sampleCount
  local peak = 0
  for i = 1, sampleCount do
    if mixture[i] > peak then
      peak = mixture[i]
    end
  end
  if peak <= MIXTURE_PEAK_EPSILON then
    return broadTimeLo, broadTimeHi
  end
  local threshold = peak * ZOOM_PEAK_FRACTION
  local indexFirst, indexLast = sampleCount, 1
  for i = 1, sampleCount do
    if mixture[i] >= threshold then
      if i < indexFirst then
        indexFirst = i
      end
      if i > indexLast then
        indexLast = i
      end
    end
  end
  local t0 = times[indexFirst]
  local t1 = times[indexLast]
  local broadSpan = broadTimeHi - broadTimeLo
  if broadSpan <= 0 then
    return broadTimeLo, broadTimeHi
  end
  local margin = math.max((t1 - t0) * ZOOM_MARGIN_RELATIVE, broadSpan * ZOOM_MARGIN_MIN_FRAC_OF_BROAD)
  local zoomLo = math.max(broadTimeLo, t0 - margin)
  local zoomHi = math.min(broadTimeHi, t1 + margin)
  local minimumSpan = broadSpan * ZOOM_MIN_SPAN_FRAC_OF_BROAD
  if zoomHi - zoomLo < minimumSpan then
    local center = 0.5 * (zoomLo + zoomHi)
    zoomLo = math.max(broadTimeLo, center - 0.5 * minimumSpan)
    zoomHi = math.min(broadTimeHi, center + 0.5 * minimumSpan)
  end
  if zoomHi - zoomLo < broadSpan * ZOOM_MAX_RETAINED_FRAC_OF_BROAD then
    return zoomLo, zoomHi
  end
  return broadTimeLo, broadTimeHi
end

local function computeVisualization(input)
  local general = input.general
  local referenceSec = input.referenceSec
  local skillUnit = input.skillUnit
  local consistencyUnit = input.consistencyUnit
  local riskUnit = input.riskUnit

  local maxMultiplier = general.max_time_multiplier_vs_reference or 2.35
  local broadLo = referenceSec * BROAD_TIME_MIN_FACTOR
  local broadHi = math.min(referenceSec * maxMultiplier, referenceSec * BROAD_TIME_SPAN_CAP_FACTOR)
  if broadHi <= broadLo then
    broadHi = broadLo + 1e-6
  end

  local densityBroad = model.mixtureDensityTimes(
    general,
    referenceSec,
    skillUnit,
    consistencyUnit,
    riskUnit,
    broadLo,
    broadHi,
    CHART_SAMPLE_COUNT
  )
  local weights = densityBroad.weights

  local timeLo, timeHi = narrowTimeRangeFromMixture(densityBroad, broadLo, broadHi)
  if timeHi <= timeLo then
    timeHi = timeLo + 1e-6
  end

  local density = model.mixtureDensityTimes(
    general,
    referenceSec,
    skillUnit,
    consistencyUnit,
    riskUnit,
    timeLo,
    timeHi,
    CHART_SAMPLE_COUNT,
    weights
  )

  local sampleCount = density.sampleCount
  local weightedComponents = { {}, {}, {}, {} }
  local densityMaxY = 0
  for outcomeIndex = 1, 4 do
    for sampleIndex = 1, sampleCount do
      local y = weights[outcomeIndex] * density.components[outcomeIndex][sampleIndex]
      weightedComponents[outcomeIndex][sampleIndex] = y
      if y > densityMaxY then
        densityMaxY = y
      end
    end
  end
  for sampleIndex = 1, sampleCount do
    local y = density.mixture[sampleIndex]
    if y > densityMaxY then
      densityMaxY = y
    end
  end

  return {
    weights = weights,
    density = density,
    weightedComponents = weightedComponents,
    yMax = densityMaxY,
    timeLo = timeLo,
    timeHi = timeHi,
  }
end

M.computeVisualization = computeVisualization
M.narrowTimeRangeFromMixture = narrowTimeRangeFromMixture
M.chartSampleCount = CHART_SAMPLE_COUNT

return M
