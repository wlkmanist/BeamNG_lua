-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Walks structured items in fixed slot order and emits one visual per renderable item,
-- pulling visuals out of the active style's componentTypes registry.
-- Items with no visual / unknown type degrade silently.

local util = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')

local C = {}

local logTag = ''

local typicalSize = 2
local typicalOpacity = 1
local maxNotes = 4

function C:init(textCompositor)
  self.textCompositor = textCompositor
end

function C:_getMaxLinkDistance()
  return self.textCompositor:getMaxLinkDistance()
end

-- Supported consumer-side visual payload values:
--
-- isLeft: false, done
--
-- type: 'turn1', done
-- type: 'turn2', done
-- type: 'turn3', done
-- type: 'turn4', done
-- type: 'turn5', done
-- type: 'turn6', done
-- type: 'turnHp', done
-- type: 'turnSq', done
--
-- type: 'rocks',
--
-- modifiers:
-- type: 'scissorsSlashed',
-- type: 'circleSlashed',
-- type: 'mathLessThan',
-- type: 'mathGreaterThan',
--
-- type: 'caution', done
-- type: 'doubleCaution', done
--
-- type: 'bridge',
-- type: 'bump',
-- type: 'bumps',
-- type: 'crest',
-- type: 'finish',
-- type: 'jumpOverBump',
-- type: 'narrows',
-- type: 'pothole',
-- type: 'water',
--
-- needed:
-- tripleCaution
--
-- {
--   type: "empty",  -- Note icon from the iconfont, string, by ID from icons.js / import { BngIcon, icons } from "@/common/components/base"
--   typeExt: nil, -- Note icon for custom SVGs, should be url()
--   turnModifier: nil, -- "Informational" modifiers: opens, narrows, over crest, water splash. Color is not changeable, placed on vertical center. Accepts icon ID from the iconfont
--   background: {
--     color: 'var(--bng-cool-gray-600)', -- color override for the background, should be RGB or CSS var with color, no alpha!
--     strokeColor: 'var(--bng-cool-gray-500)', -- color override for stroke, same as above, should be RGB, no alpha!
--     opacity: 1 -- keep visual pacenotes opaque; use softer colors instead of alpha
--   },
--   isInto: false, -- "into" background style. Boolean, apply to the note that is chained to previous one
--   isLeft: false, -- Boolean, scales the icon on X axis to -1
--   size: 5, -- note container size in REMs, with some additional magic to break the Angular's defaults.
--   turnTypeValue: nil, -- String, usually 1-6, but you can drop SQ, FL, or whatever else there.
--   distance: nil, -- string, in meters, drawn below the note
--   additionalNote: { -- That's for the important notes, top right corner, colorable. Intended for "Cut" / "Don't cut", "attention", "danger"
--     color: '#fff', -- icon/text color override, could be css var or color as rgb
--     colorBg: '#000', -- optional badge background override; falls back to note background
--     icon: nil, -- icon from the iconfont, by ID
--     text: nil -- that's an alternative, if you need to show text for some reason (NC / C)
--   }
-- }

local function buildCornerVisual(cornerCfg, item)
  -- Structured corner direction is emitted for consumers as:
  --   -1 = left, 1 = right, 0/nil = no directional corner visual.
  local direction = item.direction
  if direction == nil or direction == 0 then return nil end
  local isLeft = direction == -1

  -- descriptor visual wins (matches text compositor)
  local turnType = nil
  local descEntry = util.lookupDescriptorEntry(cornerCfg, item.descriptor)
  if descEntry and descEntry.visual then
    turnType = descEntry.visual
  end

  if not turnType then
    local intEntry = util.lookupRiskAdjustedIntensityEntry(cornerCfg, item)
    if intEntry and intEntry.visual then
      turnType = intEntry.visual
    end
  end

  if not turnType then return nil end

  local turnModifier = nil
  local shapeEntry = util.lookupShapeEntry(cornerCfg, item.shape)
  if shapeEntry then
    if shapeEntry.visual and shapeEntry.visual.icon then
      turnModifier = shapeEntry.visual.icon
    end
  end

  return {
    type           = turnType.icon,
    typeExt        = nil,
    turnModifier   = turnModifier,
    colorNoteIcon  = turnType.colorNoteIcon,
    colorNoteText  = turnType.colorNoteText,
    background     = {
      color       = turnType.colorBg,
      strokeColor = turnType.colorStroke,
      opacity     = typicalOpacity,
    },
    isLeft         = isLeft,
    size           = typicalSize,
    turnTypeValue  = turnType.text,
  }
end

local function buildCautionVisual(cautionCfg, item)
  if not cautionCfg or not item or not item.level then return nil end
  local levelVisual = type(cautionCfg.levelVisuals) == 'table' and cautionCfg.levelVisuals[item.level] or nil
  local visual = levelVisual or cautionCfg.visual
  if not visual then return nil end

  local icon = (item.level >= 3) and 'doubleCaution' or 'caution'
  return {
    type          = icon,
    colorNoteIcon = visual.colorNoteIcon,
    colorNoteText = visual.colorNoteText,
    background    = {
      color       = visual.colorBg,
      strokeColor = visual.colorStroke,
      opacity     = typicalOpacity,
    },
    size          = typicalSize,
  }
end

local function buildAtomicVisual(typeConf)
  if not typeConf or not typeConf.visual or not typeConf.visual.icon then return nil end
  local v = typeConf.visual
  return {
    type          = v.icon,
    colorNoteIcon = v.colorIcon,
    colorNoteText = v.colorNoteText,
    background    = {
      color       = v.colorBg,
      strokeColor = v.colorStroke,
      opacity     = typicalOpacity,
    },
    size          = typicalSize,
  }
end

local function isTurnVisual(vp)
  return vp and type(vp.type) == 'string' and string.sub(vp.type, 1, 4) == 'turn'
end

local function applyTurnModifier(visualPacenotes, visual)
  local turnModifier = visual and visual.turnModifier or nil
  if not turnModifier then return false end

  for i = #visualPacenotes, 1, -1 do
    local vp = visualPacenotes[i]
    if isTurnVisual(vp) then
      vp.turnModifier = turnModifier
      return true
    end
  end

  return false
end

local function applyAdditionalNote(visualPacenotes, additionalNote)
  if not additionalNote then return false end

  for i = #visualPacenotes, 1, -1 do
    local vp = visualPacenotes[i]
    if isTurnVisual(vp) then
      vp.additionalNote = additionalNote
      return true
    end
  end

  return false
end

function C:compositeVisual(pacenote, structured, distBeforeMeters, distAfterMeters)
  local visualPacenotes = {}

  local config = self.textCompositor:getConfig()
  local componentTypes = (config and config.componentTypes) or {}
  local distanceCallsEnabled = util.distanceCallsEnabled(config)

  local isInto = distanceCallsEnabled and distBeforeMeters and distBeforeMeters > 0 and distBeforeMeters < self:_getMaxLinkDistance()
  local dist = nil
  local distColor = nil
  if distanceCallsEnabled and distAfterMeters and distAfterMeters > 0 then
    dist = self.textCompositor:distanceToString(distAfterMeters)
    distColor = config.visualGeneral.distanceColor
  end

  local items = Structured.orderedItems(structured)
  local pendingTurnModifierVisual = nil
  local pendingAdditionalNote = nil
  for _, item in ipairs(items) do
    local typeConf = util.lookupComponentType(componentTypes, item.type)
    local vp = nil
    if typeConf then
      if item.type == 'corner' then
        vp = buildCornerVisual(typeConf, item)
        if vp and pendingTurnModifierVisual then
          vp.turnModifier = pendingTurnModifierVisual.turnModifier
          pendingTurnModifierVisual = nil
        end
        if vp and pendingAdditionalNote then
          vp.additionalNote = pendingAdditionalNote
          pendingAdditionalNote = nil
        end
      elseif item.type == 'caution' then
        vp = buildCautionVisual(typeConf, item)
      else
        local visual = typeConf.visual
        local turnModifier = visual and visual.turnModifier or nil
        local additionalNote = visual and visual.additionalNote or nil
        if additionalNote then
          if not applyAdditionalNote(visualPacenotes, additionalNote) then
            pendingAdditionalNote = additionalNote
          end
        elseif turnModifier then
          if not applyTurnModifier(visualPacenotes, visual) then
            pendingTurnModifierVisual = visual
          end
        else
          vp = buildAtomicVisual(typeConf)
        end
      end
    end
    if vp and #visualPacenotes < maxNotes then
      table.insert(visualPacenotes, vp)
    end
  end

  for i, vp in ipairs(visualPacenotes) do
    vp.id = string.format("%s_%d", string.gsub(pacenote.name, ' ', '_'), i)
    vp.pnId = pacenote.id
    if i == 1 then
      vp.isInto = isInto
      vp.intoColor = isInto and vp.background and vp.background.strokeColor or nil
    end
    if i == #visualPacenotes then
      vp.distance = dist
      vp.colorDistance = distColor
    end
  end

  return visualPacenotes
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
