-- Hot-reloads *.materials.json files on disk change: re-parses the file (patching
-- the in-memory Material objects) and reloads each affected material instance.

local M = {}

local function isMaterialFile(filename)
  local f = string.lower(filename)
  return string.sub(f, -15) == ".materials.json" or string.sub(f, -14) == ".material.json"
end

local function reloadMaterialFile(filename)
  loadJsonMaterialsFile(filename)

  local data = jsonReadFile(filename)
  if type(data) ~= "table" then return end

  local count = 0
  for _, entry in pairs(data) do
    if type(entry) == "table" and entry.class == "Material" and entry.name then
      local mat = scenetree.findObject(entry.name)
      if mat then
        mat:reload()
        count = count + 1
      end
    end
  end
  log("I", "materialHotReload", string.format("reloaded %d material(s) from %s", count, filename))
end

local function onFileChanged(filename, type)
  if type == "modified" and isMaterialFile(filename) then
    reloadMaterialFile(filename)
  end
end

local function onInit()
  setExtensionUnloadMode(M, "manual") -- stay loaded across level/mode changes
end

M.onInit = onInit
M.onFileChanged = onFileChanged

return M
