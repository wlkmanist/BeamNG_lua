-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local Detector = {}
Detector.__index = Detector

local baselineAlpha = 0.05 -- about 2.5 seconds at the 0.13-second sample cadence

local function clearEpisode(self)
  self.episodeStartMs = nil
  self.episodeBaselineMs = nil
  self.worstFrameMs = nil
  self.worstAtMs = nil
  self.lastDipAtMs = nil
  self.absoluteSeen = false
  self.relativeSeen = false
end

local function updateBaseline(self, frameMs)
  local baseline = self.baselineFrameMs
  self.baselineFrameMs = baseline and baseline + (frameMs - baseline) * baselineAlpha or frameMs
end

local function triggerName(self)
  if self.absoluteSeen and self.relativeSeen then return "both" end
  return self.absoluteSeen and "absolute" or "relative"
end

local function finishEpisode(self, nowMs)
  if not self.episodeStartMs
      or self.lastDipAtMs - self.episodeStartMs < self.dipMinDurationMs then
    clearEpisode(self)
    return nil
  end

  local event = {
    durationMs = self.lastDipAtMs - self.episodeStartMs,
    worstAgoMs = nowMs - self.worstAtMs,
    baselineFrameMs = self.episodeBaselineMs,
    trigger = triggerName(self),
    dipFpsThreshold = self.dipFpsThreshold,
    dipFrameTimeRatio = self.dipFrameTimeRatio,
    dipMinDurationMs = self.dipMinDurationMs,
  }
  self.eventCount = self.eventCount + 1
  self.cooldownUntilMs = nowMs + self.dipCooldownSeconds * 1000
  clearEpisode(self)
  return event
end

function Detector:reset()
  self.baselineFrameMs = nil
  clearEpisode(self)
end

function Detector:canReport(nowMs)
  return nowMs >= self.cooldownUntilMs and self.eventCount < self.maxDipEventsPerSession
end

function Detector:finish(nowMs)
  return finishEpisode(self, nowMs)
end

function Detector:update(nowMs, fps, frameMs, absoluteAllowed)
  if not self.baselineFrameMs then self.baselineFrameMs = frameMs end

  local absolute = absoluteAllowed ~= false and fps < self.dipFpsThreshold
  local relative = frameMs >= self.baselineFrameMs * self.dipFrameTimeRatio
  if absolute or relative then
    if not self:canReport(nowMs) then
      return false
    end

    if not self.episodeStartMs then
      self.episodeStartMs = nowMs
      self.episodeBaselineMs = self.baselineFrameMs
      self.worstFrameMs = frameMs
      self.worstAtMs = nowMs
      self.lastDipAtMs = nowMs
      self.absoluteSeen = absolute
      self.relativeSeen = relative
      return true
    end

    self.absoluteSeen = self.absoluteSeen or absolute
    self.relativeSeen = self.relativeSeen or relative
    self.lastDipAtMs = nowMs
    local captureWorst = false
    if frameMs > self.worstFrameMs then
      self.worstFrameMs = frameMs
      self.worstAtMs = nowMs
      captureWorst = true
    end
    if nowMs - self.episodeStartMs >= self.maxEpisodeMs then
      return captureWorst, finishEpisode(self, nowMs)
    end
    return captureWorst
  end

  local event = finishEpisode(self, nowMs)
  updateBaseline(self, frameMs)
  return false, event
end

function M.new(config)
  local self = setmetatable({
    dipFpsThreshold = config.dipFpsThreshold,
    dipFrameTimeRatio = config.dipFrameTimeRatio,
    dipMinDurationMs = config.dipMinDurationMs,
    dipCooldownSeconds = config.dipCooldownSeconds,
    maxDipEventsPerSession = config.maxDipEventsPerSession,
    maxEpisodeMs = config.maxEpisodeMs or 1800000,
    cooldownUntilMs = 0,
    eventCount = 0,
  }, Detector)
  clearEpisode(self)
  return self
end

return M
