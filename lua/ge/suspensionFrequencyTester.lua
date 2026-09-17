-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- instructions:
--  * move car to an ice surface
--  * remove damping from suspension (ideally)
--  * open ingame console, copypaste this code and hit enter:     extensions.suspensionFrequencyTester.run()

local reference = {
    { "Too Soft", 0.9 },
    { "Luxury", 1.1 },
    { "Average", 1.2 },
    { "Sporty", 1.4},
    { "Rally", 1.8},
    { "Racetrack", 2.2},
    { "Aero-Critical", 5.0},
}

local M = {}
local nodeFrontAxle = 279
local nodeRearAxle = 425

local minFreq = 0.5
local maxFreq = reference[#reference][2]
local numFreqs = 1000
local freqStep = (maxFreq - minFreq) / (numFreqs - 1)

local function createFreqFilters()
    local filters_list = {}
    for i = 1, numFreqs do
        local freq = minFreq + (i - 1) * freqStep
        filters_list[i] = {
            freq = freq,
            filter = newFreqExists()
        }
    end
    return filters_list
end

local nodes = {
    {name="Front", id=nodeFrontAxle},
    {name="Rear", id=nodeRearAxle}
}
local function initNodes()
  for _,node in ipairs(nodes) do
    node.freqFilters = createFreqFilters()
    node.amplitudes = {}
  end
end
initNodes()

local imgui = ui_imgui
local windowOpen = imgui.BoolPtr(true)
local nodeFrontPtr = imgui.IntPtr(nodeFrontAxle)
local nodeRearPtr = imgui.IntPtr(nodeRearAxle)
local freqExistsWindowPtr = imgui.IntPtr(1)
local numFreqsPtr = imgui.IntPtr(numFreqs)

local function drawWindow()
    imgui.SetNextWindowSize(imgui.ImVec2(500, 600), imgui.Cond_FirstUseEver)
    if imgui.Begin("Suspension Frequency Tester", windowOpen) then
      local availWidth = imgui.GetContentRegionAvailWidth()
      local contentWidth = math.floor(availWidth)
      imgui.PushItemWidth(100)

       imgui.Text("Settings:")
       if imgui.InputInt("Front axle node ID", nodeFrontPtr, 0, 0) then nodes[1].id = nodeFrontPtr[0] end
       if imgui.InputInt("Rear axle node ID", nodeRearPtr, 0, 0) then nodes[2].id = nodeRearPtr[0] end
       if imgui.SliderInt("Detected frequencies", numFreqsPtr, 100, 3000) then
        numFreqs = numFreqsPtr[0]
        initNodes()
       end
      imgui.SliderInt("Detector accuracy (more = laggier)", freqExistsWindowPtr, 1, 5)

      for _, node in ipairs(nodes) do
        imgui.Spacing()
        imgui.Spacing()
        imgui.Spacing()
        imgui.Spacing()
        imgui.Spacing()
        imgui.Spacing()

        if #node.amplitudes > 0 then
          if imgui.BeginTable("CategoryTable_"..node.name, 3, imgui.TableFlags_Borders + imgui.TableFlags_SizingFixedFit) then
            imgui.TableSetupColumn(string.format("%s Suspension", node.name), imgui.TableColumnFlags_WidthFixed, 160)
            imgui.TableSetupColumn("Freq", imgui.TableColumnFlags_WidthFixed, 60)
            imgui.TableSetupColumn("Match (integral of amplitudes, divided by the range of Hz)")
            imgui.TableHeadersRow()

            local categorySums = {}
            local maxCategorySum = 0
            local minCategorySum = math.huge
            for catIdx, entry in ipairs(reference) do
              local freqLimit = entry[2]
              local prevLimit = (catIdx > 1) and reference[catIdx - 1][2] or 0
              local freqRangeHz = freqLimit - prevLimit
              local sum = 0
              for i = 1, numFreqs do
                local freq = minFreq + (i - 1) * freqStep
                if freq > prevLimit and freq <= freqLimit then
                  sum = sum + (node.amplitudes[i] or 0)
                end
              end
              local sumPerHz = freqRangeHz > 0 and (sum / freqRangeHz) or 0
              categorySums[catIdx] = sumPerHz
              maxCategorySum = math.max(maxCategorySum, sumPerHz)
              minCategorySum = math.min(minCategorySum, sumPerHz)
            end

            local categoryRange = maxCategorySum - minCategorySum
            for catIdx, entry in ipairs(reference) do
              imgui.TableNextRow()
              imgui.TableNextColumn()
              imgui.Text(entry[1])
              imgui.TableNextColumn()
              imgui.Text(string.format("%.1f Hz", entry[2]))
              imgui.TableNextColumn()

              local sumPerHz = categorySums[catIdx]
              local intensity = categoryRange > 0 and ((sumPerHz - minCategorySum) / categoryRange) or 0
              local r = 0.4 + intensity * 0.2
              local g = 0.4 + intensity * 0.6
              local b = 0.4
              imgui.TextColored(imgui.ImVec4(r, g, b, 1), string.format("%i m/Hz", sumPerHz))
            end
            imgui.EndTable()
          end

          local numPixels = contentWidth
          local ampArray = imgui.ArrayFloat(numPixels)
          local maxAmpl = 0

          for pixel = 0, numPixels - 1 do
            local pixelAmpl = 0
            local freqStart = math.floor(pixel * numFreqs / numPixels) + 1
            local freqEnd = math.floor((pixel + 1) * numFreqs / numPixels)

            if freqStart <= freqEnd then
              for freqIdx = freqStart, freqEnd do
                local ampl = node.amplitudes[freqIdx] or 0
                if ampl > pixelAmpl then pixelAmpl = ampl end
              end
            else
              local closestFreqIdx = math.floor(pixel * numFreqs / numPixels + 0.5) + 1
              closestFreqIdx = math.max(1, math.min(closestFreqIdx, numFreqs))
              pixelAmpl = node.amplitudes[closestFreqIdx] or 0
            end

            ampArray[pixel] = pixelAmpl
            if pixelAmpl > maxAmpl then maxAmpl = pixelAmpl end
          end

          imgui.PushStyleColor2(imgui.Col_PlotLines, imgui.ImVec4(1, 1, 1, 1))
          imgui.PlotLines1("##"..node.name, ampArray, numPixels, 0, nil, 0, maxAmpl, imgui.ImVec2(contentWidth, 60))
          imgui.PopStyleColor()

           local numLabels = math.max(2, math.floor(contentWidth / 50))
           local labelFreqStep = (maxFreq - minFreq) / (numLabels - 1)
           local startCursorPosX = imgui.GetCursorPosX()
           local startCursorPosY = imgui.GetCursorPosY()
           for i = 0, numLabels - 1 do
             local freq = minFreq + i * labelFreqStep
             local xPos = startCursorPosX + (i * contentWidth / (numLabels - 1)) - 10
             imgui.SetCursorPos(imgui.ImVec2(xPos, startCursorPosY))
             local color = (i % 2 == 0) and imgui.ImVec4(1, 1, 1, 1) or imgui.ImVec4(0.6, 0.6, 0.6, 1)
             imgui.TextColored(color, string.format("%.2fHz", freq))
           end
        end
      end
        imgui.PopItemWidth()
    end
    imgui.End()
end

M.onUpdate = function (dtReal, dtSim, dtRaw)
    if windowOpen[0] then drawWindow() end
    local veh = getPlayerVehicle(0)
    if not veh then return end
    for _, node in ipairs(nodes) do
        if not node.id then goto continue end
        local _,_,posZ = veh:getNodePositionXYZ(node.id)
        for i, freqFilter in ipairs(node.freqFilters) do
          node.amplitudes[i] = freqFilter.filter:get(posZ, dtSim, freqFilter.freq, freqExistsWindowPtr[0])
        end
        ::continue::
    end
end

M.run = function()
    windowOpen[0] = true
    for _, node in ipairs(nodes) do
        node.amplitudes = {}
        for _, freqFilter in ipairs(node.freqFilters) do
            freqFilter.filter:reset()
        end
    end
end

return M
