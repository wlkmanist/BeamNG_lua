local M = {}

local function loadDriftData(fileName)
  if not fileName then
    return
  end
  local json = jsonReadFile(fileName)
  if not json then
    log('E', logTag, 'unable to find driftData file: ' .. tostring(fileName))
    return
  end

  -- "cast" scl, pos and rot to vec/quat
  for _, elem in ipairs(json.stuntZones or {}) do
    if elem.pos and type(elem.pos) == "table" and elem.pos.x and elem.pos.y and elem.pos.z then elem.pos = vec3(elem.pos) end
    if elem.rot and type(elem.rot) == "table" and elem.rot.x and elem.rot.y and elem.rot.z and elem.rot.w then elem.rot = quat(elem.rot) end
    if elem.scl and type(elem.scl) == "table" and elem.scl.x and elem.scl.y and elem.scl.z then elem.scl = vec3(elem.scl) end
    if elem.scl and type(elem.scl) == "number" then end
  end

  gameplay_drift_stuntZones.setStuntZones(json.stuntZones)
end

M.loadDriftData = loadDriftData

return M