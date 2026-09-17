-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared between GE (sensor pipeline) and vehicle (VECore): C++ apply_config JSON only.

local M = {}

local outWrap = { sensors = {} }
local entryPool = {}

function M.buildConfigJson(config)
  local sensors = config and config.sensors
  local outSensors = outWrap.sensors
  for j = #outSensors, 1, -1 do
    outSensors[j] = nil
  end
  if not sensors then
    return jsonEncode(outWrap)
  end
  for i = 1, #sensors do
    local sensor = sensors[i]
    local entry = entryPool[i]
    if not entry then
      entry = {}
      entryPool[i] = entry
    end
    entry.id = sensor.id
    entry.frameId = sensor.frameId
    entry.layoutId = sensor.layoutId
    entry.sensorCategory = sensor.sensorCategory
    local sc = sensor.config
    if sc and sc.blobLayout then
      entry.blobLayout = sc.blobLayout
    else
      entry.blobLayout = nil
    end
    if sensor.fields then
      entry.fields = sensor.fields
    else
      entry.fields = nil
    end
    outSensors[i] = entry
  end
  return jsonEncode(outWrap)
end

return M
