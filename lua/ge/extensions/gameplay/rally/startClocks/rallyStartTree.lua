-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- LED start clock board of the BeamNG rally start tree prop

local C = {}

local clockShape = '/art/shapes/race/rally/rally_assets/s_rally_start_tree.dae'
local displayShape = '/art/shapes/race/rally/rally_assets/s_rally_start_clock_display.dae'
local textureSize = {900, 540}
local ledGridOrigin = {x = 62.486, y = 62.486}
local ledPitch = 20
local ledSize = 15.026
local showInactiveLeds = true

local colors = {
  transparent = color(0, 0, 0, 0),
  black = color(0, 0, 0, 255),
  green = color(43, 255, 0, 255),
  amber = color(255, 145, 0, 255),
  red = color(255, 30, 15, 255),
  white = color(255, 255, 255, 255),
}

local semaphoreColors = {R = colors.red, A = colors.amber, G = colors.green}

local digitPatterns = {
  ['0'] = {'.##.', '#..#', '#..#', '#..#', '#..#', '#..#', '.##.'},
  ['1'] = {'..#.', '.##.', '..#.', '..#.', '..#.', '..#.', '.###'},
  ['2'] = {'.##.', '#..#', '...#', '..#.', '.#..', '#...', '####'},
  ['3'] = {'###.', '...#', '...#', '.##.', '...#', '...#', '###.'},
  ['4'] = {'#..#', '#..#', '#..#', '####', '...#', '...#', '...#'},
  ['5'] = {'####', '#...', '#...', '###.', '...#', '...#', '###.'},
  ['6'] = {'.##.', '#...', '#...', '###.', '#..#', '#..#', '.##.'},
  ['7'] = {'####', '...#', '..#.', '..#.', '.#..', '.#..', '.#..'},
  ['8'] = {'.##.', '#..#', '#..#', '.##.', '#..#', '#..#', '.##.'},
  ['9'] = {'.##.', '#..#', '#..#', '.###', '...#', '...#', '.##.'},
  ['S'] = {'.###', '#...', '#...', '.##.', '...#', '...#', '###.'},
  ['-'] = {'....', '....', '....', '####', '....', '....', '....'},
}

local semaphorePattern = {
  '..R..',
  'R.R.R',
  '.RAR.',
  'RARAR',
  'AGRGA',
  '.AGA.',
  'GGAGG',
  '..G..',
  '.G.G.',
}

local clockDigitColumns = {9, 13, 20, 24, 31, 35}
local bottomDigitColumns = {0, 4, 8, 20, 24, 31, 35}

local colorTexture
local opacityTexture

C.textures = {
  color = {tag = '@rallyStartClockDisplay', width = textureSize[1], height = textureSize[2], clearColor = colors.transparent},
  opacity = {tag = '@rallyStartClockOpacity', width = textureSize[1], height = textureSize[2], clearColor = colors.black},
}

function C.findClocks()
  local clocks = {}
  for _, name in ipairs(scenetree.findClassObjects('TSStatic') or {}) do
    local object = scenetree.findObject(name)
    if object and object:getField('shapeName', 0) == clockShape then
      table.insert(clocks, {anchor = object, shapeName = displayShape, transform = object:getTransform(), scale = object.scale})
    end
  end
  return clocks
end

local function drawLedOn(target, x, y, ledColor)
  target:triangle(x, y, x + ledSize, y, x + ledSize, y + ledSize, 0, 0, ledColor, ledColor, ledColor, ledColor)
  target:triangle(x, y, x + ledSize, y + ledSize, x, y + ledSize, 0, 0, ledColor, ledColor, ledColor, ledColor)
end

local function drawLed(column, row, ledColor)
  local x = ledGridOrigin.x + column * ledPitch
  local y = ledGridOrigin.y + row * ledPitch
  drawLedOn(colorTexture, x, y, ledColor)
  drawLedOn(opacityTexture, x, y, colors.white)
end

local function drawDigit(value, column, row, ledColor)
  local pattern = digitPatterns[value]
  if not pattern then return end

  for rowOffset, pixels in ipairs(pattern) do
    for columnOffset = 1, #pixels do
      if pixels:sub(columnOffset, columnOffset) == '#' then
        drawLed(column + columnOffset - 1, row + rowOffset - 1, ledColor)
      end
    end
  end
end

local function drawColon(column, row, ledColor)
  drawLed(column, row + 2, ledColor)
  drawLed(column, row + 4, ledColor)
end

local function drawInactiveDisplay()
  for row, pixels in ipairs(semaphorePattern) do
    for column = 1, #pixels do
      if pixels:sub(column, column) ~= '.' then drawLed(column - 1, row - 1, colors.black) end
    end
  end

  for _, column in ipairs(clockDigitColumns) do
    for row = 0, 6 do
      for columnOffset = 0, 3 do drawLed(column + columnOffset, row, colors.black) end
    end
  end
  drawColon(18, 0, colors.black)
  drawColon(29, 0, colors.black)

  for _, column in ipairs(bottomDigitColumns) do
    for row = 14, 20 do
      for columnOffset = 0, 3 do drawLed(column + columnOffset, row, colors.black) end
    end
  end
  drawColon(29, 14, colors.black)
end

function C.draw(textures, display)
  colorTexture, opacityTexture = textures.color, textures.opacity
  local clockDisplay, stageDisplay, countdownDisplay, semaphoreCode = display.clock, display.label, display.countdown, display.semaphore
  if showInactiveLeds then drawInactiveDisplay() end

  for row, pixels in ipairs(semaphorePattern) do
    for column = 1, #pixels do
      if pixels:sub(column, column) == semaphoreCode then
        drawLed(column - 1, row - 1, semaphoreColors[semaphoreCode])
      end
    end
  end

  local digitIndex = 1
  for index = 1, #clockDisplay do
    local character = clockDisplay:sub(index, index)
    if character == ':' then
      drawColon(digitIndex == 3 and 18 or 29, 0, colors.green)
    else
      drawDigit(character, clockDigitColumns[digitIndex], 0, colors.green)
      digitIndex = digitIndex + 1
    end
  end

  for index = 1, #stageDisplay do
    drawDigit(stageDisplay:sub(index, index), (index - 1) * 4, 14, colors.amber)
  end

  if countdownDisplay:sub(1, 1) == '-' then
    drawDigit('-', 31, 14, colors.red)
    drawDigit(countdownDisplay:sub(2), 35, 14, colors.red)
    return
  end

  local minutes, seconds = countdownDisplay:match('^(%d+):(%d%d)$')
  if minutes then
    if #minutes == 2 then drawDigit(minutes:sub(1, 1), 20, 14, colors.red) end
    drawDigit(minutes:sub(-1), 24, 14, colors.red)
    drawColon(29, 14, colors.red)
    drawDigit(seconds:sub(1, 1), 31, 14, colors.red)
    drawDigit(seconds:sub(2, 2), 35, 14, colors.red)
    return
  end

  if #countdownDisplay == 2 then drawDigit(countdownDisplay:sub(1, 1), 31, 14, colors.red) end
  drawDigit(countdownDisplay:sub(-1), 35, 14, colors.red)
end

function C.getView(clock, startLine, targetPos)
  if not startLine.rot then return end
  local roadForward = quat(startLine.rot) * vec3(0, -1, 0)
  roadForward.z = 0
  if roadForward:squaredLength() <= 0.01 then return end

  roadForward = roadForward:normalized()
  local roadRight = roadForward:cross(vec3(0, 0, 1))
  local clockIsRight = (targetPos - vec3(startLine.pos)):dot(roadRight) >= 0
  local clockTransform = clock.anchor:getTransform()
  local surfaceTangent = vec3(clockTransform:getColumn(0))
  local surfaceNormal = vec3(clockTransform:getColumn(1))
  surfaceTangent.z = 0
  surfaceNormal.z = 0
  if surfaceTangent:squaredLength() <= 0.01 or surfaceNormal:squaredLength() <= 0.01 then return end

  surfaceTangent = surfaceTangent:normalized()
  surfaceNormal = surfaceNormal:normalized()
  if surfaceTangent:dot(roadForward) < 0 then surfaceTangent = surfaceTangent * -1 end
  local inward = roadRight * (clockIsRight and -1 or 1)
  if surfaceNormal:dot(inward) < 0 then surfaceNormal = surfaceNormal * -1 end
  return surfaceTangent + surfaceNormal
end

return C
