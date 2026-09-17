-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Fixed-slot structured pacenote storage. Slots are stored as string-keyed map
-- entries so JSON keeps a stable object shape instead of a variable array.
-- Slot order is also speak/render order:
--   "1" = caution, "2"/"3" = pre-corner modifiers,
--   "4" = corner, "5"/"6" = post-corner modifiers.
-- Empty slots are represented by {}.
--
-- Each non-empty item is a typed table { type = '...', ...fields }.
-- Storage shape is style-agnostic; the active style provides labels for known item types
-- and field values. Unknown item types render as nothing (compositors degrade gracefully).
--
-- Item taxonomy (canonical):
--   { type = "caution", level = 1|2|3 }
--   { type = "corner", descriptor = nil|"square"|"hairpin"|"openHairpin"|"tightHairpin"|"flat",
--                      shape = nil|"opens"|"tightens"|...,
--                      measurementType = nil|"split2"|"split3",
--                      riskIntensity = nil|-1|1, lengthMode = nil|"shorter"|"longer"|"skip" }
--   { type = "<modifierName>" }   -- atomic modifier; presence is the data
--
-- Legacy corner measurement fields (direction/intensity/arcDegrees/intensityVariation)
-- are used only for best-effort load migration and are not kept as current data.
--
-- Schema v1 used structured.items as an array. Schema v2 used a four-slot map.
-- Schema v3 uses the six-slot map above.

local C = {}
local M = {}
local currentSchemaVersion = 3
local slotCount = 6
local logTag = 'rallyStructured'
local defaultMeasurementType = 'single'
local validMeasurementTypes = {
  single = true,
  split2 = true,
  split3 = true,
}

local function slotKey(index)
  return tostring(index)
end

local function emptySlot()
  return {}
end

local function emptySlotMap()
  local out = {}
  for i = 1, slotCount do
    out[slotKey(i)] = emptySlot()
  end
  return out
end

local function shapeFromIntensityVariation(value)
  value = tonumber(value)
  if value == -1 then return 'opens' end
  if value == 1 then return 'tightens' end
  return nil
end

local function normalizeDescriptor(descriptor)
  return descriptor
end

local function normalizeMeasurementType(measurementType)
  if validMeasurementTypes[measurementType] then return measurementType end
  return nil
end

local function normalizeSignedStep(value)
  local step = tonumber(value)
  if not step or step == 0 then return nil end
  return step > 0 and 1 or -1
end

local function normalizeLengthMode(item)
  if item.lengthMode == 'shorter' or item.lengthMode == 'longer' or item.lengthMode == 'skip' then
    return item.lengthMode
  end

  local legacyFeel = normalizeSignedStep(item.lengthFeel)
  if legacyFeel == -1 then return 'shorter' end
  if legacyFeel == 1 then return 'longer' end
  return nil
end

local function canonicalItem(item)
  if type(item) ~= 'table' or type(item.type) ~= 'string' then return nil end

  if item.type == 'corner' then
    local corner = { type = 'corner' }
    local descriptor = normalizeDescriptor(item.descriptor)
    if descriptor ~= nil then corner.descriptor = descriptor end
    if item.shape ~= nil then corner.shape = item.shape end
    local measurementType = normalizeMeasurementType(item.measurementType)
    if measurementType and measurementType ~= defaultMeasurementType then corner.measurementType = measurementType end
    corner.riskIntensity = normalizeSignedStep(item.riskIntensity)
    corner.lengthMode = normalizeLengthMode(item)
    return corner
  end

  return deepcopy(item)
end

local migrateIntensityVariationField

local function canonicalItems(items, opts)
  opts = opts or {}
  local out = {}
  for _, item in ipairs(items or {}) do
    local source = item
    if opts.migrateDeserialized and migrateIntensityVariationField then
      source = migrateIntensityVariationField(deepcopy(item))
    end
    local canonical = canonicalItem(source)
    if canonical then table.insert(out, canonical) end
  end
  return out
end

function migrateIntensityVariationField(item)
  if type(item) == 'table' and item.type == 'corner' and item.radiusChange ~= nil and item.intensityVariation == nil then
    item.intensityVariation = item.radiusChange
    item.radiusChange = nil
  end
  if type(item) == 'table' and item.type == 'corner' then
    item.descriptor = normalizeDescriptor(item.descriptor)
    item.measurementType = normalizeMeasurementType(item.measurementType)
    if item.shape == nil and item.intensityVariation ~= nil then
      item.shape = shapeFromIntensityVariation(item.intensityVariation)
    end
  end
  return item
end

local function isSlotModifier(item)
  return type(item) == 'table' and item.type ~= 'caution' and item.type ~= 'corner'
end

local function slotMapFromSlots(slots)
  local out = emptySlotMap()
  for i = 1, slotCount do
    local canonical = canonicalItem(slots and slots[i])
    if canonical then
      out[slotKey(i)] = canonical
    end
  end
  return out
end

local function warnDroppedExtra(extraCount, context)
  if extraCount > 0 then
    log('W', logTag, string.format('%s: dropped %d structured item(s) beyond the six-slot schema', context or 'structured items', extraCount))
  end
end

local canonicalSlotFromWire

local function insertFirstEmpty(slots, indexes, item)
  for _, index in ipairs(indexes) do
    if not slots[index] then
      slots[index] = item
      return true
    end
  end
  return false
end

local function slotMapFromOrderedItems(items, context)
  local slots = {}
  local extraCount = 0
  local sawCorner = false

  for _, item in ipairs(items or {}) do
    if type(item) == 'table' and item.type == 'caution' and not slots[1] then
      slots[1] = item
    elseif type(item) == 'table' and item.type == 'corner' and not slots[4] then
      slots[4] = item
      sawCorner = true
    elseif isSlotModifier(item) and insertFirstEmpty(slots, sawCorner and { 5, 6 } or { 2, 3 }, item) then
      -- inserted into the first available modifier slot.
    elseif type(item) == 'table' and item.type == 'corner' then
      extraCount = extraCount + 1
    elseif type(item) == 'table' and item.type == 'caution' then
      extraCount = extraCount + 1
    elseif isSlotModifier(item) then
      extraCount = extraCount + 1
    end
  end

  warnDroppedExtra(extraCount, context)
  return slotMapFromSlots(slots)
end

local function slotMapFromV2Slots(items)
  local slots = {}
  slots[1] = canonicalSlotFromWire(items, 1)
  slots[2] = canonicalSlotFromWire(items, 2)
  slots[4] = canonicalSlotFromWire(items, 3)
  slots[5] = canonicalSlotFromWire(items, 4)
  return slotMapFromSlots(slots)
end

function canonicalSlotFromWire(items, index)
  if type(items) ~= 'table' then return nil end
  local item = items[slotKey(index)]
  if item == nil then item = items[index] end
  if type(item) ~= 'table' or type(item.type) ~= 'string' then return nil end
  return canonicalItem(migrateIntensityVariationField(deepcopy(item)))
end

local function slotMapFromWireSlots(items)
  local out = emptySlotMap()
  for i = 1, slotCount do
    local canonical = canonicalSlotFromWire(items, i)
    if canonical then
      out[slotKey(i)] = canonical
    end
  end
  return out
end

local function orderedItemsFromSlotMap(items)
  local out = {}
  if type(items) ~= 'table' then return out end
  for i = 1, slotCount do
    local item = items[slotKey(i)]
    if item == nil then item = items[i] end
    if type(item) == 'table' and type(item.type) == 'string' then
      table.insert(out, item)
    end
  end
  return out
end

local function looksLikeSlotMap(items)
  if type(items) ~= 'table' then return false end
  for i = 1, slotCount do
    if items[slotKey(i)] ~= nil then return true end
  end
  return false
end

function C:init()
  self.schemaVersion = currentSchemaVersion
  self.items = emptySlotMap()
end

function C:onDeserialized(data)
  self.schemaVersion = currentSchemaVersion
  self.items = emptySlotMap()

  if not data then
    return
  end

  if type(data.items) == 'table' then
    local schemaVersion = tonumber(data.schemaVersion) or 1
    if schemaVersion >= 3 then
      self.items = slotMapFromWireSlots(data.items)
    elseif schemaVersion == 2 or looksLikeSlotMap(data.items) then
      self.items = slotMapFromV2Slots(data.items)
    else
      self.items = slotMapFromOrderedItems(canonicalItems(data.items, { migrateDeserialized = true }), 'schema v1 structured.items')
    end
    return
  end
end

function C:onSerialize()
  return {
    schemaVersion = currentSchemaVersion,
    items = self:slotItems(),
  }
end

function C:orderedItems()
  return orderedItemsFromSlotMap(self.items)
end

function C:slotItems()
  return slotMapFromWireSlots(self.items)
end

function C:slotItem(index)
  local item = self.items and self.items[slotKey(index)]
  if type(item) == 'table' and type(item.type) == 'string' then
    return item
  end
  return nil
end

function C:setOrderedItems(items)
  self.schemaVersion = currentSchemaVersion
  self.items = slotMapFromOrderedItems(canonicalItems(items), 'setOrderedItems')
end

function C:setSlotItems(items)
  self.schemaVersion = currentSchemaVersion
  self.items = slotMapFromWireSlots(items)
end

function C:itemCount()
  return #self:orderedItems()
end

function C:hasItems()
  return self:itemCount() > 0
end

M.orderedItems = function(structured)
  if type(structured) ~= 'table' then return {} end
  if structured.orderedItems then
    return structured:orderedItems()
  end
  local schemaVersion = tonumber(structured.schemaVersion) or 1
  if structured.items and schemaVersion < 3 and looksLikeSlotMap(structured.items) then
    return orderedItemsFromSlotMap(slotMapFromV2Slots(structured.items))
  end
  return orderedItemsFromSlotMap(structured.items or structured)
end

M.slotItems = function(structured)
  if type(structured) ~= 'table' then return emptySlotMap() end
  if structured.slotItems then
    return structured:slotItems()
  end
  local schemaVersion = tonumber(structured.schemaVersion) or 1
  if structured.items and schemaVersion < 2 and not looksLikeSlotMap(structured.items) then
    return slotMapFromOrderedItems(canonicalItems(structured.items, { migrateDeserialized = true }), 'schema v1 structured.items')
  end
  if structured.items and schemaVersion < 3 and looksLikeSlotMap(structured.items) then
    return slotMapFromV2Slots(structured.items)
  end
  return slotMapFromWireSlots(structured.items or structured)
end

M.slotItem = function(structured, index)
  if type(structured) ~= 'table' then return nil end
  if structured.slotItem then
    return structured:slotItem(index)
  end
  local items = structured.items or structured
  local schemaVersion = tonumber(structured.schemaVersion) or 1
  if structured.items and schemaVersion < 3 and looksLikeSlotMap(structured.items) then
    items = slotMapFromV2Slots(structured.items)
  end
  local item = type(items) == 'table' and (items[slotKey(index)] or items[index]) or nil
  if type(item) == 'table' and type(item.type) == 'string' then
    return item
  end
  return nil
end

M.setOrderedItems = function(structured, items)
  if type(structured) ~= 'table' then return end
  if structured.setOrderedItems then
    structured:setOrderedItems(items)
  else
    structured.items = slotMapFromOrderedItems(canonicalItems(items), 'setOrderedItems')
    structured.schemaVersion = currentSchemaVersion
  end
end

return setmetatable(M, {
  __call = function(_, ...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
  end,
})
