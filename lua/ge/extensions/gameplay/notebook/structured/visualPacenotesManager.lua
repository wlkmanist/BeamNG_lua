-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local re_util = require('ge/extensions/editor/rallyEditor/util')

local C = {}

local logTag = 'VisualPacenotesManager'

function C:init()
  self:reset()
  self.style = re_util.getStructuredPacenoteStyle()
end

function C:reset()
  self.images = {
    right = {},
    left = {},
  }
end

local function extractDirectionAndNumber(fname)
  local direction, number = fname:match('([^/]+)-([^/]+).svg$')
  return direction, number
end

function C:load()
  self:reset()

  local visualPacenotes = re_util.loadVisualPacenotesFile()
  local indexedVisualPacenotes = {}
  for _,visualNote in ipairs(visualPacenotes.styles[self.style]) do
    local fnamePart = visualNote.filename
    indexedVisualPacenotes[fnamePart] = visualNote.cornerSeverity
  end

  local files = FS:findFiles(
    '/ui/ui-vue/src/assets/images/rally/pacenotes/'..self.style,
    '*.svg',
    -1,
    true,
    false
  ) or {}

  for _,file in ipairs(files) do
    local direction, severity = extractDirectionAndNumber(file)
    if direction and severity then
      local number = indexedVisualPacenotes[severity]
      if number then
        local data = { number = number, severity = severity, file = file }
        table.insert(self.images[direction], data)
      end
    else
      log('E', logTag, 'invalid pacenote file name: ' .. file)
    end
  end

  -- dump(self.images)
end

function C:findClosestImage(direction, number)
  if direction == nil or number == nil then return nil end
  -- Convert direction to left/right string
  local dirStr = direction > 0 and "right" or "left"

  local targetNum = tonumber(number)
  if not targetNum or targetNum < 0 then return nil end

  local closest = nil
  local minDiff = math.huge

  for _, img in ipairs(self.images[dirStr]) do
    local imgNum = tonumber(img.number)
    local diff = math.abs(imgNum - targetNum)

    if diff < minDiff then
      minDiff = diff
      closest = img
    end
  end

  local basename = closest.file:match('([^/]+-[^/]+.svg)$')
  return basename
end

-- returns a svg basename string like: 'left-sq.svg'
function C:determineVisualPacenotes(noteAttrs)
  local resultIcons = {}
  local resultModifiers = {}

  if noteAttrs.modSquare then
    if noteAttrs.cornerDirection == -1 then
      table.insert(resultIcons, { fname = 'left-sq.svg', kind = 'corner' })
    elseif noteAttrs.cornerDirection == 1 then
      table.insert(resultIcons, { fname = 'right-sq.svg', kind = 'corner' })
    end
  else
    local closestImage = self:findClosestImage(
      noteAttrs.cornerDirection,
      noteAttrs.cornerSeverity
    )
    if closestImage then
      table.insert(resultIcons, { fname = closestImage, kind = 'corner' })
    end
  end

  local checkAddModifier = function(noteAttrs, resultModifiers, fieldName, svgFilename)
    if noteAttrs[fieldName] then
      table.insert(resultModifiers, { fname = svgFilename, kind = 'modifier' })
    end
  end

  checkAddModifier(noteAttrs, resultModifiers, "modDontCut",  "dontcut.svg")
  checkAddModifier(noteAttrs, resultModifiers, "modNarrows",  "narrows.svg")
  checkAddModifier(noteAttrs, resultModifiers, "modBumps",    "bump_jump.svg") -- TODO add dedicated image?
  checkAddModifier(noteAttrs, resultModifiers, "modJump",     "bump_jump.svg") -- TODO add dedicated image?
  checkAddModifier(noteAttrs, resultModifiers, "modCrest",    "bump_jump.svg") -- TODO add dedicated image?
  checkAddModifier(noteAttrs, resultModifiers, "modWater",    "water.svg")
  checkAddModifier(noteAttrs, resultModifiers, "modCaution1", "caution1.svg")
  checkAddModifier(noteAttrs, resultModifiers, "modCaution2", "caution2.svg")
  checkAddModifier(noteAttrs, resultModifiers, "modCaution3", "caution3.svg")

  return { icons = resultIcons, modifiers = resultModifiers }
end


return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
