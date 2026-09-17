-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.onInit = function() setExtensionUnloadMode(M, "manual") end

local debug = false

-- Points data storage
local pointsData = {
  currentPoints = 0,
  pointsLabel = "0",
  thresholds = {100, 200, 300}
}

local guiData = {
  fillPercent = 0,
  pointsLabel = "0",
  thresholdsReached = {},
  thresholdPercentages = {},
  thresholdCount = 0
}

-- Function to update points
local function setPoints(points, pointsLabel)
  pointsData.currentPoints = points
  pointsData.pointsLabel = pointsLabel
  local maxValue = pointsData.thresholds[#pointsData.thresholds] * 1.1  -- Add 10% buffer
  guiData.fillPercent = points / maxValue
  guiData.pointsLabel = pointsLabel or tostring(points)
  guiData.thresholdsReached = {}
  for i, threshold in ipairs(pointsData.thresholds) do
    guiData.thresholdsReached[i] = points >= threshold
  end
  guiData.thresholdCount = #pointsData.thresholds
  guihooks.queueStream('pointsBar', guiData)
end

-- Function to update points bar configuration
local function setThresholds(thresholds)
  if thresholds then
    pointsData.thresholds = thresholds
  end
  local maxValue = pointsData.thresholds[#pointsData.thresholds] * 1.1  -- Add 10% buffer
  guiData.thresholdCount = #pointsData.thresholds
  guiData.thresholdPercentages = {}
  for i, threshold in ipairs(pointsData.thresholds) do
    guiData.thresholdPercentages[i] = threshold / maxValue * 100
  end
  guihooks.queueStream('pointsBar', guiData)
end

-- Function to clear all points data
local function clearData()
  M.setThresholds({100, 200, 300})
  M.setPoints(0)
end

local function requestAllData()
  M.setThresholds(pointsData.thresholds)
  M.setPoints(pointsData.currentPoints, pointsData.pointsLabel)
end

-- Debug UI
local im
if debug then
  im = ui_imgui

  local function onUpdate()
    if not im then return end

    im.Begin("Points Bar Debug")

    -- Show current data
    im.Text("Current Points: " .. pointsData.currentPoints)
    im.Text("Thresholds:")
    for i, threshold in ipairs(pointsData.thresholds) do
      im.BulletText(string.format("Threshold %d: %d", i, threshold))
    end

    im.SameLine()
    if im.Button("Clear All") then
      clearData()
    end

    im.End()
  end

  M.onUpdate = onUpdate
end

-- Public interface
M.setPoints = setPoints
M.setThresholds = setThresholds
M.clearData = clearData
M.requestAllData = requestAllData

return M

