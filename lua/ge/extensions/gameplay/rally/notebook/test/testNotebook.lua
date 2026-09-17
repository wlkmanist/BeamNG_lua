-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- USAGE
-- run this in the game lua console:
-- extensions.unload("gameplay_notebook_test_testNotebook") extensions.load("gameplay_notebook_test_testNotebook") gameplay_notebook_test_testNotebook.testAll()

-- local SettingsManager = require('/lua/ge/extensions/gameplay/rally/settingsManager')

local logTag = ''
local M = {}
local Pacenote = require('/lua/ge/extensions/gameplay/rally/notebook/pacenote')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')

local assertCounts = {
  total = 0,
  passed = 0,
  failed = 0,
}

local fname_notebook_test_v3_1     = '/gameplay/missions/driver_training/rallyStage/aip-test3/rally/notebooks/test_v3_1.notebook.json'
local fname_notebook_test_v3_1_out = '/gameplay/missions/driver_training/rallyStage/aip-test3/rally/notebooks/test_v3_1_out.notebook.json'

local function assertEqual(message, actual, expected)
  assertCounts.total = assertCounts.total + 1

  if actual ~= expected then
    assertCounts.failed = assertCounts.failed + 1
    message = message or "assertion failed"
    log('E', logTag, string.format("%s: expected '%s' but got '%s'", message, tostring(expected), tostring(actual)))
    error("test failed: "..message)
  else
    assertCounts.passed = assertCounts.passed + 1
    log('I', logTag, "test passed: "..message)
  end
end

local function loadNotebook(notebookFname)
  log('D', logTag, 'reading notebook file: ' .. notebookFname)
  local json = jsonReadFile(notebookFname)
  if not json then
    return nil, 'unable to read notebook file at: ' .. notebookFname
  end

  local notebook = require('/lua/ge/extensions/gameplay/rally/notebook/path')()
  notebook:setFname(notebookFname)
  notebook:onDeserialized(json)

  -- dump(notebook.pacenotes.sorted[1], 2)

  -- SettingsManager.load(notebook)

  return notebook
end

local function firstCornerArcDegrees(notebook)
  local pn = notebook.pacenotes.sorted[1]
  local corner = pn:corner()
  return corner and corner.arcDegrees or nil
end

local function testStructured_deserialize()
  local notebook = loadNotebook(fname_notebook_test_v3_1)
  assertEqual('legacy corner arcDegrees stripped', firstCornerArcDegrees(notebook), nil)
end

local function testStructured_serialize()
  local notebook = loadNotebook(fname_notebook_test_v3_1)
  notebook:setFname(fname_notebook_test_v3_1_out)

  local newVal = 55
  local corner = notebook.pacenotes.sorted[1]:corner()
  corner.arcDegrees = newVal
  notebook:save()

  local notebook = loadNotebook(fname_notebook_test_v3_1)
  assertEqual('legacy source corner arcDegrees stripped', firstCornerArcDegrees(notebook), nil)

  local notebook_out = loadNotebook(fname_notebook_test_v3_1_out)
  assertEqual('serialized corner arcDegrees stripped', firstCornerArcDegrees(notebook_out), nil)
end

local function testStructured_loadMigrationStripsProjectionCache()
  local structured = Structured()
  structured:onDeserialized({
    schemaVersion = 1,
    items = {
      {
        type = 'corner',
        intensity = 5,
        direction = 1,
        arcDegrees = 90,
        arcMeters = 40,
        chordMeters = 30,
        descriptor = 'openHairpin',
        shape = 'tightens',
        measurementType = 'split2',
        riskIntensity = 1,
        lengthFeel = -1,
      },
    },
  })

  local corner = Structured.slotItem(structured, 4)
  assertEqual('corner exists after migration', corner and corner.type, 'corner')
  assertEqual('legacy intensity stripped on load', corner.intensity, nil)
  assertEqual('legacy direction stripped on load', corner.direction, nil)
  assertEqual('legacy arcDegrees stripped on load', corner.arcDegrees, nil)
  assertEqual('legacy arcMeters stripped on load', corner.arcMeters, nil)
  assertEqual('legacy chordMeters stripped on load', corner.chordMeters, nil)
  assertEqual('descriptor preserved on load', corner.descriptor, 'openHairpin')
  assertEqual('shape preserved on load', corner.shape, 'tightens')
  assertEqual('measurementType preserved on load', corner.measurementType, 'split2')
  assertEqual('riskIntensity preserved on load', corner.riskIntensity, 1)
  assertEqual('legacy lengthFeel migrated on load', corner.lengthMode, 'shorter')
  assertEqual('legacy lengthFeel stripped on load', corner.lengthFeel, nil)

  local serialized = structured:onSerialize()
  assertEqual('schema v3 serialized after load migration', serialized.schemaVersion, 3)
  assertEqual('descriptor preserved on serialize', serialized.items["4"].descriptor, 'openHairpin')
end

local function testStructured_lengthModeSerializes()
  local structured = Structured()
  structured:onDeserialized({
    schemaVersion = 1,
    items = {
      {
        type = 'corner',
        lengthMode = 'skip',
      },
    },
  })

  local serialized = structured:onSerialize()
  local corner = serialized.items["4"]
  assertEqual('lengthMode skip serialized', corner.lengthMode, 'skip')
  assertEqual('lengthFeel not serialized with lengthMode', corner.lengthFeel, nil)
end

local function testStructured_v1ArrayMigratesToFixedSlots()
  local structured = Structured()
  structured:onDeserialized({
    schemaVersion = 1,
    items = {
      { type = 'caution', level = 1 },
      { type = 'overJump' },
      { type = 'crest' },
      { type = 'corner', shape = 'tightens' },
      { type = 'deceptive' },
      { type = 'bump' },
    },
  })

  assertEqual('v1 caution migrated to slot 1', structured.items["1"].type, 'caution')
  assertEqual('v1 first pre modifier migrated to slot 2', structured.items["2"].type, 'overJump')
  assertEqual('v1 second pre modifier migrated to slot 3', structured.items["3"].type, 'crest')
  assertEqual('v1 corner migrated to slot 4', structured.items["4"].type, 'corner')
  assertEqual('v1 first post modifier migrated to slot 5', structured.items["5"].type, 'deceptive')
  assertEqual('v1 second post modifier migrated to slot 6', structured.items["6"].type, 'bump')
  assertEqual('v1 ordered items preserve speak order', Structured.orderedItems(structured)[4].shape, 'tightens')
end

local function testStructured_v3RoundTripsSixSlots()
  local structured = Structured()
  structured:onDeserialized({
    schemaVersion = 3,
    items = {
      ["1"] = { type = 'caution', level = 2 },
      ["2"] = { type = 'overJump' },
      ["3"] = { type = 'crest' },
      ["4"] = { type = 'corner', shape = 'tightens' },
      ["5"] = { type = 'deceptive' },
      ["6"] = { type = 'bump' },
    },
  })

  local serialized = structured:onSerialize()
  assertEqual('v3 serialize keeps schema version', serialized.schemaVersion, 3)
  assertEqual('v3 slot 1 caution serialized', serialized.items["1"].type, 'caution')
  assertEqual('v3 slot 2 first pre modifier serialized', serialized.items["2"].type, 'overJump')
  assertEqual('v3 slot 3 second pre modifier serialized', serialized.items["3"].type, 'crest')
  assertEqual('v3 slot 4 corner serialized', serialized.items["4"].type, 'corner')
  assertEqual('v3 slot 5 first post modifier serialized', serialized.items["5"].type, 'deceptive')
  assertEqual('v3 slot 6 second post modifier serialized', serialized.items["6"].type, 'bump')

  local ordered = Structured.orderedItems(structured)
  assertEqual('v3 ordered slot 1', ordered[1].type, 'caution')
  assertEqual('v3 ordered slot 2', ordered[2].type, 'overJump')
  assertEqual('v3 ordered slot 3', ordered[3].type, 'crest')
  assertEqual('v3 ordered slot 4', ordered[4].type, 'corner')
  assertEqual('v3 ordered slot 5', ordered[5].type, 'deceptive')
  assertEqual('v3 ordered slot 6', ordered[6].type, 'bump')
end

local function testStructured_v2MapRoundTripsEmptySlots()
  local structured = Structured()
  structured:onDeserialized({
    schemaVersion = 2,
    items = {
      ["1"] = {},
      ["2"] = { type = 'overJump' },
      ["3"] = { type = 'corner', shape = 'tightens' },
      ["4"] = {},
    },
  })

  local ordered = Structured.orderedItems(structured)
  assertEqual('v2 empty slots skipped from ordered view', #ordered, 2)
  assertEqual('v2 ordered pre modifier preserved', ordered[1].type, 'overJump')
  assertEqual('v2 ordered corner preserved', ordered[2].type, 'corner')

  local serialized = structured:onSerialize()
  assertEqual('v2 serialize upgrades schema version', serialized.schemaVersion, 3)
  assertEqual('v2 serialize keeps empty slot 1 table', type(serialized.items["1"]), 'table')
  assertEqual('v2 serialize keeps empty slot 1 empty', serialized.items["1"].type, nil)
  assertEqual('v2 serialize keeps slot 2 item', serialized.items["2"].type, 'overJump')
  assertEqual('v2 serialize leaves new slot 3 empty', serialized.items["3"].type, nil)
  assertEqual('v2 serialize moves corner to slot 4', serialized.items["4"].type, 'corner')
  assertEqual('v2 serialize keeps empty slot 5 table', type(serialized.items["5"]), 'table')
  assertEqual('v2 serialize keeps empty slot 5 empty', serialized.items["5"].type, nil)
  assertEqual('v2 serialize keeps empty slot 6 table', type(serialized.items["6"]), 'table')
  assertEqual('v2 serialize keeps empty slot 6 empty', serialized.items["6"].type, nil)
end

local function testStructured_slotItemPreservesEmptyPositions()
  local structured = Structured()
  structured:onDeserialized({
    schemaVersion = 2,
    items = {
      ["1"] = {},
      ["2"] = {},
      ["3"] = {},
      ["4"] = { type = 'overJump' },
    },
  })

  assertEqual('v2 slot 2 remains empty when only old slot 4 has a modifier', Structured.slotItem(structured, 2), nil)
  assertEqual('v2 old slot 4 migrates to post slot 5', Structured.slotItem(structured, 5).type, 'overJump')
  assertEqual('ordered view still speaks migrated post modifier', Structured.orderedItems(structured)[1].type, 'overJump')
end

local function testStructuredForProjectionUsesLiveMeasurement()
  local nextId = 0
  local fakeNotebook = {
    getNextUniqueIdentifier = function()
      nextId = nextId + 1
      return nextId
    end,
    getLanguages = function()
      return { { language = 'english' } }
    end,
  }
  local pn = Pacenote(fakeNotebook, 'projection test')
  pn.structured:setSlotItems({
    ["4"] = {
      type = 'corner',
      shape = 'tightens',
      riskIntensity = 1,
    },
  })
  pn.measurements.variants = {
    single = {
      diameter = 249,
      direction = 'left',
      arcDegrees = 25,
      arcMeters = 55,
      chordMeters = 54,
    },
  }
  pn.measurements.corner1 = pn.measurements.variants.single

  local projected = pn:structuredForProjection()
  local corner = Structured.slotItem(projected, 4)
  assertEqual('projected intensity uses measured diameter', corner.intensity, 249)
  assertEqual('projected direction uses measured direction', corner.direction, -1)
  assertEqual('projected arcDegrees uses measurement', corner.arcDegrees, 25)
  assertEqual('projected arcMeters uses measurement', corner.arcMeters, 55)
  assertEqual('projected chordMeters uses measurement', corner.chordMeters, 54)
  assertEqual('authored shape preserved during projection', corner.shape, 'tightens')
  assertEqual('authored riskIntensity preserved during projection', corner.riskIntensity, 1)
  assertEqual('source structured intensity not mutated by projection', pn.structured.items["4"].intensity, nil)
end

local function testDistanceBeforeModifierOrder()
  local config = {
    distance = {
      links = {
        { threshold = 20, text = 'into' },
      },
    },
    componentTypes = {
      corner = {
        direction = {
          [1] = 'right',
        },
        intensity = {
          { diameter = { min = 0 }, text = 'five' },
        },
      },
      modifiers = {
        bump = { text = 'bump' },
        crest = { text = 'crest' },
        tightens = { text = 'tightens' },
      },
    },
  }
  local structured = {
    items = {
      { type = 'corner', direction = 1, intensity = 5 },
      { type = 'tightens' },
    },
  }

  local defaultEntries = compositorUtil.compositePhraseEntries(config, structured, '', '100')
  assertEqual('default distance follows modifier', defaultEntries[1].text, 'five right')
  assertEqual('default modifier before distance', defaultEntries[2].text, 'tightens')
  assertEqual('default distance last', defaultEntries[3].text, '100')
  assertEqual('default numeric distance category', defaultEntries[3].category, 'distance')

  local linkwordEntries = compositorUtil.compositePhraseEntries(config, structured, '', 'into')
  assertEqual('link word distance text', linkwordEntries[3].text, 'into')
  assertEqual('link word distance category', linkwordEntries[3].category, 'linkword')

  local swappedEntries = compositorUtil.compositePhraseEntries(config, structured, '', '100', {
    distanceAfterBeforePostModifier = true,
  })
  assertEqual('swapped corner remains first', swappedEntries[1].text, 'five right')
  assertEqual('swapped distance before modifier', swappedEntries[2].text, '100')
  assertEqual('swapped modifier last', swappedEntries[3].text, 'tightens')

  local noCornerStructured = {
    items = {
      { type = 'bump' },
      { type = 'crest' },
    },
  }
  local noCornerEntries = compositorUtil.compositePhraseEntries(config, noCornerStructured, '', '100', {
    distanceAfterBeforePostModifier = true,
  })
  assertEqual('no-corner pre modifier remains first', noCornerEntries[1].text, 'bump')
  assertEqual('no-corner distance before post modifier', noCornerEntries[2].text, '100')
  assertEqual('no-corner post modifier last', noCornerEntries[3].text, 'crest')

  local v2SlotOnlyStructured = Structured()
  v2SlotOnlyStructured:onDeserialized({
    schemaVersion = 2,
    items = {
      ["1"] = {},
      ["2"] = {},
      ["3"] = {},
      ["4"] = { type = 'crest' },
    },
  })
  local v2SlotOnlyEntries = compositorUtil.compositePhraseEntries(config, v2SlotOnlyStructured, '', '100', {
    distanceAfterBeforePostModifier = true,
  })
  assertEqual('v2 old slot 4 distance before migrated post modifier', v2SlotOnlyEntries[1].text, '100')
  assertEqual('v2 old slot 4 migrated post modifier last', v2SlotOnlyEntries[2].text, 'crest')

  local v3TwoPostStructured = Structured()
  v3TwoPostStructured:onDeserialized({
    schemaVersion = 3,
    items = {
      ["1"] = {},
      ["2"] = {},
      ["3"] = {},
      ["4"] = { type = 'corner', direction = 1, intensity = 5 },
      ["5"] = { type = 'crest' },
      ["6"] = { type = 'bump' },
    },
  })
  local v3TwoPostEntries = compositorUtil.compositePhraseEntries(config, v3TwoPostStructured, '', '100', {
    distanceAfterBeforePostModifier = true,
  })
  assertEqual('v3 corner remains first before post modifiers', v3TwoPostEntries[1].text, 'five right')
  assertEqual('v3 distance before first post modifier', v3TwoPostEntries[2].text, '100')
  assertEqual('v3 first post modifier after distance', v3TwoPostEntries[3].text, 'crest')
  assertEqual('v3 second post modifier after first post modifier', v3TwoPostEntries[4].text, 'bump')
end

local function testAll()
  testStructured_deserialize()
  testStructured_serialize()
  testStructured_loadMigrationStripsProjectionCache()
  testStructured_lengthModeSerializes()
  testStructured_v1ArrayMigratesToFixedSlots()
  testStructured_v3RoundTripsSixSlots()
  testStructured_v2MapRoundTripsEmptySlots()
  testStructured_slotItemPreservesEmptyPositions()
  testStructuredForProjectionUsesLiveMeasurement()
  testDistanceBeforeModifierOrder()
  dump(assertCounts)
end

M.testAll = testAll

return M
