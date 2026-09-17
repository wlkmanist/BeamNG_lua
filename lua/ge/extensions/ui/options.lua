local M = {}

local layoutDir = "/ui/ui-vue/src/modules/options/runtime/"
local layoutBaseName = "layout"
local layoutExt = "json"

-- key must be nil/empty or a safe slug (mirrors the old editor-server validation /^[a-z\d\-_]+$/i)
local function isValidKey(key)
  return string.match(key, "^[%w%-_]+$") ~= nil
end

local function normalisePath(p)
  return (tostring(p or ""):gsub("\\", "/"))
end

local function getUserFolderLayouts()
  local res = {}
  local userPath = normalisePath(FS:getUserPath())
  if userPath == "" then return res end
  local names = { layoutBaseName .. "." .. layoutExt, layoutBaseName .. ".dev." .. layoutExt }
  for _, name in ipairs(names) do
    local real = normalisePath(FS:getFileRealPath(layoutDir .. name))
    if real ~= "" and string.startswith(real, userPath) then
      res[#res + 1] = name
    end
  end
  return res
end

local function saveLayout(key, data)
  if type(data) ~= "string" then
    log("E", "options.saveLayout", "layout data must be a JSON string")
    return false
  end

  local suffix = ""
  if key ~= nil and key ~= "" then
    if not isValidKey(key) then
      log("E", "options.saveLayout", "invalid layout key: " .. tostring(key))
      return false
    end
    suffix = "." .. key
  end

  local vpath = layoutDir .. layoutBaseName .. suffix .. "." .. layoutExt
  if not writeFile(vpath, data) then
    log("E", "options.saveLayout", "failed to write layout file: " .. vpath)
    return false
  end

  log("I", "options.saveLayout", "layout saved to user folder: " .. tostring(FS:getFileRealPath(vpath)))
  return true
end

M.saveLayout = saveLayout
M.getUserFolderLayouts = getUserFolderLayouts

return M
