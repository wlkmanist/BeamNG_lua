-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local virtualTerms = {
  "virtual",
  "voicemeeter",
  "cable input",
  "sonar",
  "streaming speakers",
  "wave link",
}
local headphoneTerms = {"headphone", "headset", "earphone", "earbud", "airpods"}
local displayTerms = {
  "hdmi",
  "displayport",
  "display port",
  "display audio",
  "monitor",
  "nvidia high definition audio",
  "amd high definition audio",
  "intel(r) display audio",
}
local speakerTerms = {"speaker", "soundbar"}

local function containsAny(name, terms)
  for _, term in ipairs(terms) do
    if string.find(name, term, 1, true) then return true end
  end
  return false
end

local function classifyOutput(name)
  if type(name) ~= "string" then return "unknown" end
  name = string.lower(name)
  if containsAny(name, virtualTerms) then return "virtual" end
  if containsAny(name, headphoneTerms) then return "headphones" end
  if string.find(name, "%f[%a]tv%f[%A]")
      or containsAny(name, displayTerms) then
    return "display"
  end
  if containsAny(name, speakerTerms) then return "speakers" end
  return "unknown"
end

local function fromDeviceInfo(info)
  if type(info) ~= "table" or next(info) == nil then return nil end
  return {
    category = classifyOutput(info.name),
    sampleRateHz = info.sampleRateHz,
    speakerMode = info.speakerMode,
    channels = info.channels,
  }
end

M.fromDeviceInfo = fromDeviceInfo

return M
