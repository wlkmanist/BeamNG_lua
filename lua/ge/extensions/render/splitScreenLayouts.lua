-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local maxPerPlayerSettingsCount = 8
local higherPlayerCountSettingsBucket = maxPerPlayerSettingsCount + 1

-- Custom layouts are loaded recursively from /settings/**/*.splitscreenLayout.json.
-- Format: {"layouts":[{"id":"name","label":"Display name","playerCount":2,"layout":[[x,y,width,height], ...]}]}
-- Coordinates are normalized to 0..1, there must be one rectangle per player, and rectangles may overlap.

local targetViewAspect = (16 / 9) * 1.2
local viewGapPixels = 2
local edgeEpsilon = 0.000001

local function screenSize(width, height)
  if type(width) == "number" and width >= 2 and type(height) == "number" and height >= 2 then
    return width, height
  end
  local aspect = type(width) == "number" and width > 0 and width or (16 / 9)
  return aspect * 1080, 1080
end

local function addViewGaps(layout, screenWidth, screenHeight)
  local halfGapX = viewGapPixels / (screenWidth * 2)
  local halfGapY = viewGapPixels / (screenHeight * 2)
  for _, rect in ipairs(layout) do
    local x, y, width, height = rect[1], rect[2], rect[3], rect[4]
    local leftInset = x > edgeEpsilon and math.min(halfGapX, width / 4) or 0
    local topInset = y > edgeEpsilon and math.min(halfGapY, height / 4) or 0
    local rightInset = x + width < 1 - edgeEpsilon and math.min(halfGapX, width / 4) or 0
    local bottomInset = y + height < 1 - edgeEpsilon and math.min(halfGapY, height / 4) or 0

    rect[1] = x + leftInset
    rect[2] = y + topInset
    rect[3] = width - leftInset - rightInset
    rect[4] = height - topInset - bottomInset
  end
  return layout
end

local layoutDefinitions = {
  [2] = {
    order = {"automatic", "shared", "horizontal", "vertical"},
    layouts = {
      horizontal = {
        {0, 0, 1, 0.5},
        {0, 0.5, 1, 0.5},
      },
      vertical = {
        {0, 0, 0.5, 1},
        {0.5, 0, 0.5, 1},
      },
    },
  },
  [3] = {
    order = {"automatic", "shared", "horizontal", "vertical", "top", "left", "right", "bottom"},
    layouts = {
      horizontal = {
        {0, 0, 1, 1 / 3},
        {0, 1 / 3, 1, 1 / 3},
        {0, 2 / 3, 1, 1 / 3},
      },
      vertical = {
        {0, 0, 1 / 3, 1},
        {1 / 3, 0, 1 / 3, 1},
        {2 / 3, 0, 1 / 3, 1},
      },
      top = {
        {0, 0, 1, 0.5},
        {0, 0.5, 0.5, 0.5},
        {0.5, 0.5, 0.5, 0.5},
      },
      left = {
        {0, 0, 0.5, 1},
        {0.5, 0, 0.5, 0.5},
        {0.5, 0.5, 0.5, 0.5},
      },
      right = {
        {0.5, 0, 0.5, 1},
        {0, 0, 0.5, 0.5},
        {0, 0.5, 0.5, 0.5},
      },
      bottom = {
        {0, 0.5, 1, 0.5},
        {0, 0, 0.5, 0.5},
        {0.5, 0, 0.5, 0.5},
      },
    },
  },
  [4] = {
    order = {"automatic", "shared", "horizontal", "vertical", "corners"},
    layouts = {
      horizontal = {
        {0, 0, 1, 0.25},
        {0, 0.25, 1, 0.25},
        {0, 0.5, 1, 0.25},
        {0, 0.75, 1, 0.25},
      },
      vertical = {
        {0, 0, 0.25, 1},
        {0.25, 0, 0.25, 1},
        {0.5, 0, 0.25, 1},
        {0.75, 0, 0.25, 1},
      },
      corners = {
        {0, 0, 0.5, 0.5},
        {0.5, 0, 0.5, 0.5},
        {0, 0.5, 0.5, 0.5},
        {0.5, 0.5, 0.5, 0.5},
      },
    },
  },
}

local function registerCustomLayout(data, sourcePath)
  local layoutId = data.id
  local playerCount = data.playerCount
  local layout = data.layout
  if type(layoutId) ~= "string" or not layoutId:match("^[%w_.-]+$") or layoutId == "automatic" or layoutId == "shared" then
    log("W", "splitScreenLayouts", "Ignoring layout with invalid or reserved id in " .. sourcePath)
    return
  end
  if type(playerCount) ~= "number" or playerCount < 1 or playerCount ~= math.floor(playerCount) then
    log("W", "splitScreenLayouts", "Ignoring layout '" .. layoutId .. "' with invalid playerCount in " .. sourcePath)
    return
  end
  if type(layout) ~= "table" or #layout ~= playerCount then
    log("W", "splitScreenLayouts", "Ignoring layout '" .. layoutId .. "': expected one rectangle per player in " .. sourcePath)
    return
  end

  for _, rect in ipairs(layout) do
    if type(rect) ~= "table" or #rect ~= 4 then
      log("W", "splitScreenLayouts", "Ignoring layout '" .. layoutId .. "' with an invalid rectangle in " .. sourcePath)
      return
    end
    for i = 1, 4 do
      if type(rect[i]) ~= "number" or rect[i] ~= rect[i] or math.abs(rect[i]) == math.huge then
        log("W", "splitScreenLayouts", "Ignoring layout '" .. layoutId .. "' with non-finite coordinates in " .. sourcePath)
        return
      end
    end
    if rect[1] < 0 or rect[2] < 0 or rect[3] <= 0 or rect[4] <= 0 or rect[1] + rect[3] > 1 or rect[2] + rect[4] > 1 then
      log("W", "splitScreenLayouts", "Ignoring layout '" .. layoutId .. "' with coordinates outside the screen in " .. sourcePath)
      return
    end
  end

  local definition = layoutDefinitions[playerCount]
  if not definition then
    definition = {order = {"automatic", "shared"}, layouts = {}}
    layoutDefinitions[playerCount] = definition
  end
  if definition.layouts[layoutId] then
    log("W", "splitScreenLayouts", "Ignoring duplicate layout '" .. layoutId .. "' for " .. playerCount .. " players in " .. sourcePath)
    return
  end

  definition.layouts[layoutId] = layout
  definition.labels = definition.labels or {}
  definition.labels[layoutId] = type(data.label) == "string" and data.label or ("ui.multiseat.layout." .. layoutId)
  definition.order[#definition.order + 1] = layoutId
end

local function loadCustomLayouts()
  local files = FS:findFiles("/settings/", "*.splitscreenLayout.json", -1, true, false) or {}
  table.sort(files)
  for _, path in ipairs(files) do
    local data = jsonReadFile(path)
    if type(data) ~= "table" or type(data.layouts) ~= "table" then
      log("W", "splitScreenLayouts", "Ignoring invalid layout file " .. path)
    else
      for _, layout in ipairs(data.layouts) do
        if type(layout) == "table" then
          registerCustomLayout(layout, path)
        else
          log("W", "splitScreenLayouts", "Ignoring invalid layout entry in " .. path)
        end
      end
    end
  end
end

loadCustomLayouts()

local function computeAutomaticLayout(playerCount, screenAspect)
  if playerCount <= 1 then return {{0, 0, 1, 1}} end
  screenAspect = screenAspect or (16 / 9)

  local bestRows, bestScore = 1, math.huge
  for rows = 1, playerCount do
    local base, remainder = math.floor(playerCount / rows), playerCount % rows
    local score = 0
    for row = 0, rows - 1 do
      local columns = base + (row < remainder and 1 or 0)
      local aspect = screenAspect * rows / columns
      score = math.max(score, math.abs(math.log(aspect / targetViewAspect)))
    end
    if score < bestScore then
      bestScore, bestRows = score, rows
    end
  end

  local base, remainder = math.floor(playerCount / bestRows), playerCount % bestRows
  local rowHeight, layout = 1 / bestRows, {}
  for row = 0, bestRows - 1 do
    local columns = base + (row < remainder and 1 or 0)
    local columnWidth = 1 / columns
    for column = 0, columns - 1 do
      layout[#layout + 1] = {
        column * columnWidth,
        row * rowHeight,
        columnWidth,
        rowHeight,
      }
    end
  end
  return layout
end

function M.getLayout(playerCount, layoutId, screenWidth, screenHeight)
  if layoutId == "shared" then return {{0, 0, 1, 1}} end
  screenWidth, screenHeight = screenSize(screenWidth, screenHeight)
  local screenAspect = screenWidth / screenHeight
  local definition = layoutDefinitions[playerCount]
  if layoutId == "automatic" or not definition or not definition.layouts[layoutId] then
    return addViewGaps(computeAutomaticLayout(playerCount, screenAspect), screenWidth, screenHeight)
  end
  return addViewGaps(deepcopy(definition.layouts[layoutId]), screenWidth, screenHeight)
end

function M.getSettingsPlayerCount(playerCount)
  playerCount = math.max(0, math.floor(tonumber(playerCount) or 0))
  return playerCount > maxPerPlayerSettingsCount and higherPlayerCountSettingsBucket or playerCount
end

function M.getOptions(playerCount, screenWidth, screenHeight)
  local definition = layoutDefinitions[playerCount]
  local options = {}
  local order = definition and definition.order or {"automatic", "shared"}
  for _, layoutId in ipairs(order) do
    if layoutId ~= "shared" then
      options[#options + 1] = {
        value = layoutId,
        label = definition and definition.labels and definition.labels[layoutId] or ("ui.multiseat.layout." .. layoutId),
        layout = M.getLayout(playerCount, layoutId, screenWidth, screenHeight),
      }
    end
  end
  return options
end

function M.isValid(playerCount, layoutId)
  if layoutId == "automatic" or layoutId == "shared" then return true end
  local definition = layoutDefinitions[playerCount]
  return definition ~= nil and definition.layouts[layoutId] ~= nil
end

function M.isShared(layoutId)
  return layoutId == "shared"
end

return M
