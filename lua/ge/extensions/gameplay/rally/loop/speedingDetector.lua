-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local C = {}
local logTag = 'speedingDetector'

function C:init(manager)
  self.manager = manager
  self.currentLimitKph = nil
  self.bufferSize = 5
  -- Pre-allocate ring buffer to avoid memory allocations
  self.data = {}
  for i = 1, self.bufferSize do
    self.data[i] = nil
  end
  self.writeIndex = 1  -- Current write position (1-based, wraps around)
  self.count = 0  -- Number of valid samples in buffer
  self.sampleRate = 1.0  -- Seconds between samples
  self.timeSinceLastSample = 0
  self.penaltyRateLimit = 60.0  -- Minimum seconds between penalties
  self.timeSinceLastPenalty = self.penaltyRateLimit  -- Start ready to penalize
  self.penalties = {}  -- Store all triggered penalties

  self.maxSpeedOver = 60
  self.maxProbability = 0.05

  self.strictMaxSpeedOver = 5
  self.strictMaxProbability = 0.2

  -- self.strictModeBuffer = 3  -- kph buffer for strict mode
end

function C:getCurrentSpeedKph()
  local veh = getPlayerVehicle(0)
  if not veh then return nil end
  local velocityMs = veh:getVelocity():length()
  return velocityMs * 3.6
end

function C:addSample(sample)
  -- Ring buffer implementation - no memory allocations
  self.data[self.writeIndex] = sample
  self.writeIndex = (self.writeIndex % self.bufferSize) + 1  -- Wrap around
  self.count = math.min(self.count + 1, self.bufferSize)  -- Track valid samples
end

function C:getAverageSpeed()
  if self.count == 0 then return nil end

  local sum = 0
  for i = 1, self.count do
    sum = sum + (self.data[i] or 0)
  end

  return sum / self.count
end

function C:stochasticPenalty(maxSpeedOver, maxProbability)
  -- Check if penalty should be applied based on average speed over limit
  -- Returns: penaltyTriggered (boolean), probability (0-1)

  if not self.currentLimitKph then
    return false, 0
  end

  local avgSpeed = self:getAverageSpeed()
  if not avgSpeed or avgSpeed <= self.currentLimitKph then
    return false, 0
  end

  -- Calculate how much over the limit for the configured probability ramp
  local speedOver = avgSpeed - self.currentLimitKph
  -- 0 kph over = 0%, maxSpeedOver kph over = maxProbability
  -- Linear scaling: 0 kph over = 0%, maxSpeedOver kph over = maxProbability
  local probability = math.min(speedOver / maxSpeedOver * maxProbability, maxProbability)

  -- Roll the dice
  local roll = math.random()
  local penaltyTriggered = roll < probability

  return penaltyTriggered, probability
end

function C:update(dtSim, limitKph, strictMode)
  self.currentLimitKph = limitKph
  self.strictMode = strictMode or false

  -- Accumulate time
  self.timeSinceLastSample = self.timeSinceLastSample + dtSim
  self.timeSinceLastPenalty = self.timeSinceLastPenalty + dtSim

  -- Take a sample if enough time has passed
  if self.timeSinceLastSample >= self.sampleRate then
    local speedKph = self:getCurrentSpeedKph()
    if speedKph then
      self:addSample(speedKph)

      -- Check for penalty after adding sample (with rate limiting)
      if self.timeSinceLastPenalty >= self.penaltyRateLimit then
        local penaltyTriggered = false
        local probability = 0
        local avgSpeed = self:getAverageSpeed()
        local speedUsed = avgSpeed

        local maxSpeedOver = self.maxSpeedOver
        local maxProbability = self.maxProbability

        if self.strictMode then
          maxSpeedOver = self.strictMaxSpeedOver
          maxProbability = self.strictMaxProbability
        end

        -- Strict mode: use instantaneous speed and guaranteed penalty if over limit + buffer
        -- if self.strictMode and speedKph > (self.currentLimitKph + self.strictModeBuffer) then
          -- penaltyTriggered = true
          -- probability = 1.0
          -- speedUsed = speedKph  -- Use instantaneous speed for strict mode
        -- else
          -- Normal mode: stochastic penalty based on average speed
          -- penaltyTriggered, probability = self:stochasticPenalty(self.maxSpeedOver, self.maxProbability)
        -- end

        penaltyTriggered, probability = self:stochasticPenalty(maxSpeedOver, maxProbability)

        if penaltyTriggered then
          -- Store penalty data
          local penaltyData = {
            averageSpeed = avgSpeed,
            instantSpeed = speedKph,
            speedLimit = self.currentLimitKph,
            speedOver = speedUsed - self.currentLimitKph,
            probability = probability,
            strictMode = self.strictMode,
          }

          table.insert(self.penalties, penaltyData)

          -- Record penalty with manager
          if self.manager then
            self.manager:recordSpeedingPenalty(penaltyData)
          end

          self.timeSinceLastPenalty = 0  -- Reset rate limit timer
        end
      end
    end
    self.timeSinceLastSample = self.timeSinceLastSample - self.sampleRate
  end

  -- self:drawDebug()
end

function C:drawDebug()
  im.Begin("Speeding Detector Debug")

  -- Current limit
  im.Text("Speed Limit: " .. tostring(self.currentLimitKph or "N/A") .. " kph")

  -- Strict mode indicator
  if self.strictMode then
    im.TextColored(im.ImVec4(1, 0.3, 0.3, 1), string.format("STRICT MODE (max %d kph over, %.1f%% prob)", self.strictMaxSpeedOver, self.strictMaxProbability * 100))
  end

  -- Current vehicle speed
  local currentSpeed = self:getCurrentSpeedKph()
  if currentSpeed then
    im.Text(string.format("Current Speed: %.1f kph", currentSpeed))
  else
    im.Text("Current Speed: N/A")
  end

  -- Average speed (bigger font, red if speeding)
  local avgSpeed = self:getAverageSpeed()
  im.SetWindowFontScale(1.5)
  if avgSpeed then
    local isSpeeding = self.currentLimitKph and avgSpeed > self.currentLimitKph
    local color = isSpeeding and im.ImVec4(1, 0.2, 0.2, 1) or im.ImVec4(1, 1, 1, 1)
    im.TextColored(color, string.format("Average Speed: %.1f kph", avgSpeed))
  else
    im.TextColored(im.ImVec4(1, 1, 1, 1), "Average Speed: N/A")
  end
  im.SetWindowFontScale(1.0)

  -- Show penalty probability
  if self.currentLimitKph then
    local currentSpeed = self:getCurrentSpeedKph()
    local probability

    -- Strict mode: use instantaneous speed, 100% if speed over limit + buffer
    if self.strictMode and currentSpeed then
      if currentSpeed > (self.currentLimitKph + self.strictMaxSpeedOver) then
        probability = self.strictMaxProbability
      else
        probability = 0
      end
    elseif avgSpeed then
      -- Normal mode: use average speed
      local speedOver = math.max(0, avgSpeed - self.currentLimitKph)
      probability = math.min(speedOver / self.maxSpeedOver * self.maxProbability, self.maxProbability)
    end

    if probability and probability > 0 then
      local isPenaltyReady = self.timeSinceLastPenalty >= self.penaltyRateLimit
      local probColor = isPenaltyReady and im.ImVec4(1, 0.6, 0.2, 1) or im.ImVec4(0.5, 0.5, 0.5, 1)
      local statusText = isPenaltyReady and "" or " (RATE LIMITED)"
      im.TextColored(probColor, string.format("Penalty Probability: %.1f%%%s", probability * 100, statusText))
    end
  end

  im.Separator()

  -- Penalties info
  im.Text(string.format("Total Penalties: %d", #self.penalties))
  if self.timeSinceLastPenalty < self.penaltyRateLimit then
    im.Text(string.format("Time Until Penalty Ready: %.1f sec", self.penaltyRateLimit - self.timeSinceLastPenalty))
  else
    im.TextColored(im.ImVec4(0.3, 1, 0.3, 1), "Penalty Ready")
  end

  -- Show most recent penalty
  if #self.penalties > 0 then
    local lastPenalty = self.penalties[#self.penalties]
    im.Text(string.format("Last Penalty: %.1f kph avg (%.1f%% prob)",
      lastPenalty.averageSpeed, lastPenalty.probability * 100))
  end

  im.Separator()

  -- Sampling info
  im.Text(string.format("Sample Rate: %.1f sec", self.sampleRate))
  im.Text(string.format("Time Until Next Sample: %.2f sec", self.sampleRate - self.timeSinceLastSample))

  im.Separator()

  -- Display samples in buffer
  if self.count > 0 then
    im.Separator()
    im.Text("Speed Samples (newest to oldest):")
    for i = 0, self.count - 1 do
      local idx = ((self.writeIndex - 1 - i - 1) % self.bufferSize) + 1
      local sample = self.data[idx]
      if sample then
        local color = (self.currentLimitKph and sample > self.currentLimitKph) and {1, 0.3, 0.3, 1} or {1, 1, 1, 1}
        im.TextColored(im.ImVec4(color[1], color[2], color[3], color[4]), string.format("  [%d] %.1f kph", i + 1, sample))
      end
    end
  end

  im.End()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

