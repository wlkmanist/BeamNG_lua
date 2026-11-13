-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Mesh Spline' -- The global prefix for the mesh spline tool.
local editModeKey = 'meshSplineEditMode' -- The edit mode key for this tool.

local minSplineDivisions = 100 -- The minimum number of divisions to use for a mesh spline.

local minImportSize = 10.0 -- The minimum size of a mesh spline to import.

-- Default mesh and properties.
local defaultMeshPath = 'art/shapes/objects/jerseybarrier_3m.dae'
local defaultMeshName = 'jerseybarrier_3m'
local defaultRot = 1

-- Default slider parameters for UI.
local defaultParams = {
  spacing = 0.0,
  verticalOffset = 0.0,
  startCapOffset = 0.0,
  endCapOffset = 0.0,
  normalMode = 2, -- 0=local, 1=global, 2=terrain (default).
  jitterForward = 0.0,
  jitterRight = 0.0,
  jitterUp = 0.0,
  mainRandomWeight = 1.0,
  alias1RandomWeight = 0.0,
  alias2RandomWeight = 0.0,
  alias3RandomWeight = 0.0,
  splineRandomSeed = 0,
}

-- The concrete barrier preset.
local concreteBarrierPreset = {
  name = 'Concrete Barrier',
  meshPath = 'art/shapes/objects/jerseybarrier_3m.dae',
  meshName = 'jerseybarrier_3m',
  rot = 1,
  spacing = -0.18,
  normalMode = 0,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 1,
  alias1MeshPath = 'art/shapes/objects/jerseybarrier_3m.dae',
  alias1MeshName = 'jerseybarrier_3m',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 1,
  alias2MeshPath = 'art/shapes/objects/jerseybarrier_3m.dae',
  alias2MeshName = 'jerseybarrier_3m',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 1,
  alias3MeshPath = 'art/shapes/objects/jerseybarrier_3m.dae',
  alias3MeshName = 'jerseybarrier_3m',
  isStartCap = true,
  startCapRot = 1,
  startCapMeshPath = 'art/shapes/objects/jerseybarrier_end.dae',
  startCapMeshName = 'jerseybarrier_end',
  isEndCap = true,
  endCapRot = 3,
  endCapMeshPath = 'art/shapes/objects/jerseybarrier_end.dae',
  endCapMeshName = 'jerseybarrier_end',
}

-- The plastic barrier preset.
local plasticBarrierPreset = {
  name = 'Plastic Barrier',
  meshPath = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier.dae',
  meshName = 'hr_plasticbarrier_red',
  rot = 0,
  spacing = -0.075,
  normalMode = 0,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = true,
  alias1RandomWeight = 0.0,
  alias1Rot = 0,
  alias1MeshPath = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.dae',
  alias1MeshName = 'hr_plasticbarrier_red',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 0,
  alias2MeshPath = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier.dae',
  alias2MeshName = 'hr_plasticbarrier_red',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 0,
  alias3MeshPath = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.dae',
  alias3MeshName = 'hr_plasticbarrier_red',
  isStartCap = false,
  startCapRot = 0,
  startCapMeshPath = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.dae',
  startCapMeshName = 'hr_plasticbarrier_red',
  isEndCap = false,
  endCapRot = 0,
  endCapMeshPath = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.dae',
  endCapMeshName = 'hr_plasticbarrier_red',
}

-- The metal fence preset.
local metalFencePreset = {
  name = 'Metal Fence',
  meshPath = 'art/shapes/objects/s_metal_fence.dae',
  meshName = 's_metal_fence',
  rot = 1,
  spacing = 0.2,
  normalMode = 0,
  verticalOffset = 0.0,
  jitterForward = 0.00,
  jitterRight = 0.00,
  jitterUp = 0.00,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 1,
  alias1MeshPath = 'art/shapes/objects/s_metal_fence.dae',
  alias1MeshName = 's_metal_fence',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 1,
  alias2MeshPath = 'art/shapes/objects/s_metal_fence.dae',
  alias2MeshName = 's_metal_fence',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 1,
  alias3MeshPath = 'art/shapes/objects/s_metal_fence.dae',
  alias3MeshName = 's_metal_fence',
  isStartCap = false,
  startCapRot = 1,
  startCapMeshPath = 'art/shapes/objects/s_metal_fence.dae',
  startCapMeshName = 's_metal_fence',
  isEndCap = false,
  endCapRot = 1,
  endCapMeshPath = 'art/shapes/objects/s_metal_fence.dae',
  endCapMeshName = 's_metal_fence',
}

-- The mast arm lamp post preset.
local mastArmLampPostPreset = {
  name = 'Mast Arm Lamp Post',
  meshPath = 'art/shapes/garage_and_dealership/Clutter/eca_lamppost.dae',
  meshName = 'eca_lamppost',
  rot = 1,
  spacing = 30.0,
  normalMode = 1,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 1,
  alias1MeshPath = 'art/shapes/garage_and_dealership/Clutter/eca_lamppost.dae',
  alias1MeshName = 'eca_lamppost',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 1,
  alias2MeshPath = 'art/shapes/garage_and_dealership/Clutter/eca_lamppost.dae',
  alias2MeshName = 'eca_lamppost',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 1,
  alias3MeshPath = 'art/shapes/garage_and_dealership/Clutter/eca_lamppost.dae',
  alias3MeshName = 'eca_lamppost',
  isStartCap = false,
  startCapRot = 1,
  startCapMeshPath = 'art/shapes/garage_and_dealership/Clutter/eca_lamppost.dae',
  startCapMeshName = 'eca_lamppost',
  isEndCap = false,
  endCapRot = 1,
  endCapMeshPath = 'art/shapes/garage_and_dealership/Clutter/eca_lamppost.dae',
  endCapMeshName = 'eca_lamppost',
}

-- The victorian lamp post preset.
local victorianLampPostPreset = {
  name = 'Victorian Lamp Post',
  meshPath = 'art/shapes/objects/lamp1.dae',
  meshName = 'lamp1',
  rot = 1,
  spacing = 25.0,
  normalMode = 1,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 1,
  alias1MeshPath = 'art/shapes/objects/lamp1.dae',
  alias1MeshName = 'lamp1',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 1,
  alias2MeshPath = 'art/shapes/objects/lamp1.dae',
  alias2MeshName = 'lamp1',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 1,
  alias3MeshPath = 'art/shapes/objects/lamp1.dae',
  alias3MeshName = 'lamp1',
  isStartCap = false,
  startCapRot = 1,
  startCapMeshPath = 'art/shapes/objects/lamp1.dae',
  startCapMeshName = 'lamp1',
  isEndCap = false,
  endCapRot = 1,
  endCapMeshPath = 'art/shapes/objects/lamp1.dae',
  endCapMeshName = 'lamp1',
}

-- The modern single street lamp preset (global 's_*' asset). rot carries the roadsideProps/bridge calibration: relative to the
-- mast (rot = 1) the street pole faces the other way, so rot = 0. Verify facing in-game and only adjust rot if it points wrong.
local streetLampPostPreset = {
  name = 'Street Lamp Post',
  meshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_street_single_01.dae',
  meshName = 's_lamp_post_street_single_01',
  rot = 0,
  spacing = 30.0,
  normalMode = 1,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 0,
  alias1MeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_street_single_01.dae',
  alias1MeshName = 's_lamp_post_street_single_01',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 0,
  alias2MeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_street_single_01.dae',
  alias2MeshName = 's_lamp_post_street_single_01',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 0,
  alias3MeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_street_single_01.dae',
  alias3MeshName = 's_lamp_post_street_single_01',
  isStartCap = false,
  startCapRot = 0,
  startCapMeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_street_single_01.dae',
  startCapMeshName = 's_lamp_post_street_single_01',
  isEndCap = false,
  endCapRot = 0,
  endCapMeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_street_single_01.dae',
  endCapMeshName = 's_lamp_post_street_single_01',
}

-- The tall highway lamp preset (global 's_*' asset). rot = 2 (mast + 180) per the shared calibration.
local highwayLampPostPreset = {
  name = 'Highway Lamp Post',
  meshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_single_highway_01.dae',
  meshName = 's_lamp_post_single_highway_01',
  rot = 2,
  spacing = 40.0,
  normalMode = 1,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 2,
  alias1MeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_single_highway_01.dae',
  alias1MeshName = 's_lamp_post_single_highway_01',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 2,
  alias2MeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_single_highway_01.dae',
  alias2MeshName = 's_lamp_post_single_highway_01',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 2,
  alias3MeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_single_highway_01.dae',
  alias3MeshName = 's_lamp_post_single_highway_01',
  isStartCap = false,
  startCapRot = 2,
  startCapMeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_single_highway_01.dae',
  startCapMeshName = 's_lamp_post_single_highway_01',
  isEndCap = false,
  endCapRot = 2,
  endCapMeshPath = 'assets/meshes/props/urban/lighting/s_lamp_post_single_highway_01.dae',
  endCapMeshName = 's_lamp_post_single_highway_01',
}

-- The pedestrian sidewalk lamp preset (global 's_*' asset). rot = 2 (mast + 180) per the shared calibration.
local sidewalkLampPostPreset = {
  name = 'Sidewalk Lamp Post',
  meshPath = 'assets/meshes/props/urban/lighting/s_streetlamp_sidewalk_01.dae',
  meshName = 's_streetlamp_sidewalk_01',
  rot = 2,
  spacing = 25.0,
  normalMode = 1,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 2,
  alias1MeshPath = 'assets/meshes/props/urban/lighting/s_streetlamp_sidewalk_01.dae',
  alias1MeshName = 's_streetlamp_sidewalk_01',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 2,
  alias2MeshPath = 'assets/meshes/props/urban/lighting/s_streetlamp_sidewalk_01.dae',
  alias2MeshName = 's_streetlamp_sidewalk_01',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 2,
  alias3MeshPath = 'assets/meshes/props/urban/lighting/s_streetlamp_sidewalk_01.dae',
  alias3MeshName = 's_streetlamp_sidewalk_01',
  isStartCap = false,
  startCapRot = 2,
  startCapMeshPath = 'assets/meshes/props/urban/lighting/s_streetlamp_sidewalk_01.dae',
  startCapMeshName = 's_streetlamp_sidewalk_01',
  isEndCap = false,
  endCapRot = 2,
  endCapMeshPath = 'assets/meshes/props/urban/lighting/s_streetlamp_sidewalk_01.dae',
  endCapMeshName = 's_streetlamp_sidewalk_01',
}

-- The bollard preset.
local bollardPreset = {
  name = 'Bollard',
  meshPath = 'art/shapes/objects/bollard_yellow.dae',
  meshName = 'bollard_yellow',
  rot = 1,
  spacing = 10.0,
  normalMode = 2,
  verticalOffset = 0.0,
  jitterForward = 0.01,
  jitterRight = 0.01,
  jitterUp = 0.01,
  mainRandomWeight = 1.0,
  splineRandomSeed = 0,
  isAliasRoundRobin = true,
  isAlias1 = false,
  alias1RandomWeight = 0.0,
  alias1Rot = 1,
  alias1MeshPath = 'art/shapes/objects/bollard_yellow.dae',
  alias1MeshName = 'bollard_yellow',
  isAlias2 = false,
  alias2RandomWeight = 0.0,
  alias2Rot = 1,
  alias2MeshPath = 'art/shapes/objects/bollard_yellow.dae',
  alias2MeshName = 'bollard_yellow',
  isAlias3 = false,
  alias3RandomWeight = 0.0,
  alias3Rot = 1,
  alias3MeshPath = 'art/shapes/objects/bollard_yellow.dae',
  alias3MeshName = 'bollard_yellow',
  isStartCap = false,
  startCapRot = 1,
  startCapMeshPath = 'art/shapes/objects/bollard_yellow.dae',
  startCapMeshName = 'bollard_yellow',
  isEndCap = false,
  endCapRot = 1,
  endCapMeshPath = 'art/shapes/objects/bollard_yellow.dae',
  endCapMeshName = 'bollard_yellow',
}

-- The oil drum preset.
local oilDrumPreset = {
  name = 'Oil Drum',
  meshPath = 'art/shapes/garage_and_dealership/Clutter/metal_drum_a.dae',
  meshName = 'metal_drum_a',
  rot = 1,
  spacing = 1.0,
  normalMode = 0,
  verticalOffset = 0.0,
  jitterForward = 0.02,
  jitterRight = 0.02,
  jitterUp = 0.1,
  mainRandomWeight = 0.5,
  splineRandomSeed = 0,
  isAliasRoundRobin = false,
  isAlias1 = true,
  alias1RandomWeight = 0.25,
  alias1Rot = 1,
  alias1MeshPath = 'art/shapes/garage_and_dealership/Clutter/metal_drum_old_a.dae',
  alias1MeshName = 'metal_drum_old_a',
  isAlias2 = true,
  alias2RandomWeight = 0.5,
  alias2Rot = 1,
  alias2MeshPath = 'art/shapes/garage_and_dealership/Clutter/metal_drum_old_b.dae',
  alias2MeshName = 'metal_drum_old_b',
  isAlias3 = false,
  alias3RandomWeight = 0.25,
  alias3Rot = 1,
  alias3MeshPath = 'art/shapes/garage_and_dealership/Clutter/metal_drum_a.dae',
  alias3MeshName = 'metal_drum_a',
  isStartCap = false,
  startCapRot = 1,
  startCapMeshPath = 'art/shapes/garage_and_dealership/Clutter/metal_drum_a.dae',
  startCapMeshName = 'metal_drum_a',
  isEndCap = false,
  endCapRot = 1,
  endCapMeshPath = 'art/shapes/garage_and_dealership/Clutter/metal_drum_a.dae',
  endCapMeshName = 'metal_drum_a',
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'meshSpline'

-- External modules.
local buffer = require('string.buffer')
local pop = require('editor/meshSpline/populate')
local populationEngine = require('editor/meshSpline/populationEngine')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')
local session = require('editor/toolUtilities/session') -- Shared Save/Load Session helper (itemToTable + vec3 rehydrate).

-- Module constants.
local abs, min = math.abs, math.min
local presetsByStr = {
  ['concrete_barrier'] = concreteBarrierPreset,
  ['plastic_barrier'] = plasticBarrierPreset,
  ['metal_fence'] = metalFencePreset,
  ['mast_arm_lamp_post'] = mastArmLampPostPreset,
  ['victorian_lamp_post'] = victorianLampPostPreset,
  ['street_lamp_post'] = streetLampPostPreset,
  ['highway_lamp_post'] = highwayLampPostPreset,
  ['sidewalk_lamp_post'] = sidewalkLampPostPreset,
  ['bollard'] = bollardPreset,
  ['oil_drum'] = oilDrumPreset,
}

-- Module state.
local meshSplines = {}
local splineMap = {}
local tmpPoint2I = Point2I(0, 0)


-- Fetches the tool prefix string.
local function getToolPrefixStr() return toolPrefixStr end

-- Fetches the edit mode key.
local function getEditModeKey() return editModeKey end

-- Fetches the mesh splines.
local function getMeshSplines() return meshSplines end

-- Fetches the mesh spline map.
local function getSplineMap() return splineMap end

-- Sets the mesh spline with the given index.
local function setMeshSpline(spline, idx)
  meshSplines[idx] = spline

  -- Ensure we have a unique mesh spline name.
  local baseName = spline.name
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create a new scene tree folder for the mesh spline.
  if not spline.sceneTreeFolderId or not scenetree.findObjectById(spline.sceneTreeFolderId) then
    local newFolder = createObject("SimGroup")
    local folderNameId = Engine.generateUUID()
    newFolder:registerObject(string.format("%s - %s", uniqueName, folderNameId))
    newFolder.cansave = false -- Transient while editing; the Bake button flips the folder to canSave=true.
    scenetree.MissionGroup:addObject(newFolder)
    spline.sceneTreeFolderId = newFolder:getId()
  end
  spline.isDirty = true
end

-- Sets the mesh splines (full table).
local function setMeshSplines(splines)
  for i = 1, #splines do
    setMeshSpline(splines[i], i)
  end
end

-- Sets the given spline to the given preset.
local function setPreset(spline, presetStr)
  if not spline or not presetStr then
    return -- No spline or preset string provided.
  end

  -- Remove any existing meshes from the scene.
  pop.tryRemove(spline)

  -- Set the preset data in the spline.
  local preset = presetsByStr[presetStr]
  if preset then
    -- Get the extents data of the preset mesh.
    local mbox = util.getMeshBox(preset.meshPath)
    local extents = mbox.extents
    local center = mbox.center
    local minExtents = mbox.minExtents
    local maxExtents = mbox.maxExtents
    local mesh_boxXLeft_Center, mesh_boxXRight_Center = center.x - minExtents.x, maxExtents.x - center.x
    local mesh_boxYLeft_Center, mesh_boxYRight_Center = center.y - minExtents.y, maxExtents.y - center.y
    local mesh_extentsL_Center, mesh_extentsW_Center = extents.x, extents.y

    -- Determine if the mesh is centered left.
    local isLongX = extents.x >= extents.y
    local boxCenter = (mbox.minExtents + mbox.maxExtents) * 0.5
    local originToCenterDistance = isLongX and abs(center.x - boxCenter.x) or abs(center.y - boxCenter.y)
    local isCenteredLeft = originToCenterDistance > 0.01

    -- Core properties.
    spline.centerMeshPath = preset.meshPath
    spline.centerMeshName = preset.meshName
    spline.rot = preset.rot
    spline.spacing = preset.spacing
    spline.normalMode = preset.normalMode
    spline.verticalOffset = preset.verticalOffset
    spline.jitterForward = preset.jitterForward
    spline.jitterRight = preset.jitterRight
    spline.jitterUp = preset.jitterUp
    spline.isAliasRoundRobin = preset.isAliasRoundRobin

    -- Main mesh component properties.
    spline.mainComponentPath = string.format('main_%s', preset.meshPath)
    spline.extentsW_Center = mesh_extentsW_Center
    spline.extentsL_Center = mesh_extentsL_Center
    spline.boxXLeft_Center = mesh_boxXLeft_Center
    spline.boxXRight_Center = mesh_boxXRight_Center
    spline.boxYLeft_Center = mesh_boxYLeft_Center
    spline.boxYRight_Center = mesh_boxYRight_Center
    spline.isCenteredLeft = isCenteredLeft

    -- Random seed and weights.
    spline.splineRandomSeed = preset.splineRandomSeed
    spline.mainRandomWeight = preset.mainRandomWeight

    -- Alias mesh component properties.
    spline.isAlias1 = preset.isAlias1
    spline.alias1RandomWeight = preset.alias1RandomWeight
    spline.alias1Rot = preset.alias1Rot
    spline.alias1MeshPath = preset.alias1MeshPath
    spline.alias1MeshName = preset.alias1MeshName
    spline.alias1ComponentPath = string.format('alias1_%s', preset.alias1MeshPath)

    spline.isAlias2 = preset.isAlias2
    spline.alias2RandomWeight = preset.alias2RandomWeight
    spline.alias2Rot = preset.alias2Rot
    spline.alias2MeshPath = preset.alias2MeshPath
    spline.alias2MeshName = preset.alias2MeshName
    spline.alias2ComponentPath = string.format('alias2_%s', preset.alias2MeshPath)

    spline.isAlias3 = preset.isAlias3
    spline.alias3RandomWeight = preset.alias3RandomWeight
    spline.alias3Rot = preset.alias3Rot
    spline.alias3MeshPath = preset.alias3MeshPath
    spline.alias3MeshName = preset.alias3MeshName
    spline.alias3ComponentPath = string.format('alias3_%s', preset.alias3MeshPath)

    -- Cap mesh component properties.
    spline.isStartCap = preset.isStartCap
    spline.startCapRot = preset.startCapRot
    spline.startCapMeshPath = preset.startCapMeshPath
    spline.startCapMeshName = preset.startCapMeshName
    spline.startCapComponentPath = string.format('startCap_%s', preset.startCapMeshPath)
    spline.startCapOffset = preset.startCapOffset or 0.0

    spline.isEndCap = preset.isEndCap
    spline.endCapRot = preset.endCapRot
    spline.endCapMeshPath = preset.endCapMeshPath
    spline.endCapMeshName = preset.endCapMeshName
    spline.endCapComponentPath = string.format('endCap_%s', preset.endCapMeshPath)
    spline.endCapOffset = preset.endCapOffset or 0.0
  end

  spline.isDirty = true
end

-- Returns the default slider parameters.
local function getDefaultSliderParams() return defaultParams end

-- Adds a new mesh spline.
local function addNewMeshSpline()
  -- Ensure we have a unique mesh spline name.
  local baseName = string.format(toolPrefixStr .. " %d", #meshSplines + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)
  local id = Engine.generateUUID()

  -- Create a new folder for the mesh spline.
  local newFolder = createObject("SimGroup")
  newFolder:registerObject(string.format("%s - %s", uniqueName, id))
  newFolder.cansave = false -- Transient while editing; the Bake button flips the folder to canSave=true.
  scenetree.MissionGroup:addObject(newFolder)

  -- Create a new mesh spline with basic structure.
  table.insert(meshSplines, {
    name = uniqueName,
    id = id,
    sceneTreeFolderId = newFolder:getId(),
    isDirty = false,
    isLoop = false,
    isLink = false,
    linkId = nil,
    nodes = {},
    widths = {},
    nmls = {},
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    isEnabled = true,
    isConformToTerrain = false, -- One-shot model: build free in 3D by default; use the 'drop to surface' button to snap nodes down.
    normalMode = 2,
    isAliasRoundRobin = true,
    isFixedEnds = false, -- 'Lock ends': discrete props only -- pin an item at both ends, even-fit the interior (see populate).
    roadLength = 0.0,
  })

  -- Apply the concrete barrier preset to set all the mesh-specific parameters.
  setPreset(meshSplines[#meshSplines], 'concrete_barrier')

  -- Update the spline map.
  util.computeIdToIdxMap(meshSplines, splineMap)
end

-- Removes the mesh spline with the given index.
local function removeMeshSpline(idx)
  local spline = meshSplines[idx]
  pop.tryRemove(spline) -- Remove the static meshes related to this mesh spline from the scene.
  if spline.sceneTreeFolderId then
    local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
    if folder and simObjectExists(folder) then
      folder:delete() -- Remove the scene tree folder for the mesh spline.
    end
  end
  table.remove(meshSplines, idx) -- Finally, remove the mesh spline from the list.

  -- Update the spline map.
  util.computeIdToIdxMap(meshSplines, splineMap)
end

-- Finds a live mesh spline by id (nil if not present).
local function findMeshSpline(id)
  local idx = splineMap[id]
  return idx and meshSplines[idx] or nil
end

-- Removes a linked mesh spline by ID (called from master spline layer removal).
local function removeLinkedMeshSpline(splineId)
  local idx = splineMap[splineId]
  if idx then
    removeMeshSpline(idx)
  end
end

-- Removes all mesh splines.
-- [If isIncludeDisabled is true, then all mesh splines will be removed, including disabled ones.]
-- [If isIncludeDisabled is false, then only enabled mesh splines will be removed.]
local function removeAllMeshSplines(isIncludeDisabled)
  if isIncludeDisabled then
    for i = #meshSplines, 1, -1 do
      local spline = meshSplines[i]
      if spline then
        removeMeshSpline(i)
      end
    end
  else
    for i = #meshSplines, 1, -1 do
      local spline = meshSplines[i]
      if spline and spline.isEnabled and not spline.isLink then -- Only remove enabled and unlinked mesh splines.
        removeMeshSpline(i)
      end
    end
  end
end

-- Deep copies the given mesh spline.
local function deepCopyMeshSpline(spline)
  local copy = buffer.decode(buffer.encode(spline))
  table.clear(copy.divPoints)
  table.clear(copy.divWidths)
  table.clear(copy.tangents)
  table.clear(copy.binormals)
  table.clear(copy.normals)
  table.clear(copy.discMap)
  return copy
end

-- Deep copies the full mesh spline state.
local function deepCopyMeshSplineState()
  local copy = {}
  for i = 1, #meshSplines do
    copy[i] = deepCopyMeshSpline(meshSplines[i])
  end
  return copy
end

-- Splits the selected mesh spline into two, at the selected node.
local function splitMeshSpline(selectedSplineIdx, selectedNodeIdx)
  local spline = meshSplines[selectedSplineIdx]
  if not spline then return end

  if spline.isLoop then
    -- Unwrap loop in place starting from the split point, convert to open spline.
    spline.nodes, spline.widths, spline.nmls = geom.splitLoopSplineGeometry(spline.nodes, spline.widths, spline.nmls, selectedNodeIdx)
    spline.isLoop = false
    spline.isDirty = true
  else
    local copy = deepCopyMeshSpline(spline)
    removeMeshSpline(selectedSplineIdx)

    -- Add first half (A).
    addNewMeshSpline()
    meshSplines[#meshSplines].name = copy.name .. '_split_A'
    meshSplines[#meshSplines].isDirty = true
    meshSplines[#meshSplines].isLoop = false
    meshSplines[#meshSplines].isLink = false
    meshSplines[#meshSplines].linkId = nil
    meshSplines[#meshSplines].isEnabled = true
    meshSplines[#meshSplines].normalMode = copy.normalMode
    meshSplines[#meshSplines].isCenteredLeft = copy.isCenteredLeft
    meshSplines[#meshSplines].verticalOffset = copy.verticalOffset
    meshSplines[#meshSplines].isConformToTerrain = copy.isConformToTerrain
    meshSplines[#meshSplines].isAliasRoundRobin = copy.isAliasRoundRobin
    meshSplines[#meshSplines].isFixedEnds = copy.isFixedEnds
    meshSplines[#meshSplines].roadLength = 0.0
    meshSplines[#meshSplines].spacing = copy.spacing
    meshSplines[#meshSplines].jitterForward = copy.jitterForward
    meshSplines[#meshSplines].jitterRight = copy.jitterRight
    meshSplines[#meshSplines].jitterUp = copy.jitterUp
    meshSplines[#meshSplines].splineRandomSeed = copy.splineRandomSeed
    meshSplines[#meshSplines].rot = copy.rot
    meshSplines[#meshSplines].mainRandomWeight = copy.mainRandomWeight
    meshSplines[#meshSplines].centerMeshPath = copy.centerMeshPath
    meshSplines[#meshSplines].centerMeshName = copy.centerMeshName
    meshSplines[#meshSplines].mainComponentPath = copy.mainComponentPath
    meshSplines[#meshSplines].extentsW_Center = copy.extentsW_Center
    meshSplines[#meshSplines].extentsL_Center = copy.extentsL_Center
    meshSplines[#meshSplines].boxXLeft_Center = copy.boxXLeft_Center
    meshSplines[#meshSplines].boxXRight_Center = copy.boxXRight_Center
    meshSplines[#meshSplines].boxYLeft_Center = copy.boxYLeft_Center
    meshSplines[#meshSplines].boxYRight_Center = copy.boxYRight_Center
    meshSplines[#meshSplines].isAlias1 = copy.isAlias1
    meshSplines[#meshSplines].alias1RandomWeight = copy.alias1RandomWeight
    meshSplines[#meshSplines].alias1Rot = copy.alias1Rot
    meshSplines[#meshSplines].alias1MeshPath = copy.alias1MeshPath
    meshSplines[#meshSplines].alias1MeshName = copy.alias1MeshName
    meshSplines[#meshSplines].alias1ComponentPath = copy.alias1ComponentPath
    meshSplines[#meshSplines].isAlias2 = copy.isAlias2
    meshSplines[#meshSplines].alias2RandomWeight = copy.alias2RandomWeight
    meshSplines[#meshSplines].alias2Rot = copy.alias2Rot
    meshSplines[#meshSplines].alias2MeshPath = copy.alias2MeshPath
    meshSplines[#meshSplines].alias2MeshName = copy.alias2MeshName
    meshSplines[#meshSplines].alias2ComponentPath = copy.alias2ComponentPath
    meshSplines[#meshSplines].isAlias3 = copy.isAlias3
    meshSplines[#meshSplines].alias3RandomWeight = copy.alias3RandomWeight
    meshSplines[#meshSplines].alias3Rot = copy.alias3Rot
    meshSplines[#meshSplines].alias3MeshPath = copy.alias3MeshPath
    meshSplines[#meshSplines].alias3MeshName = copy.alias3MeshName
    meshSplines[#meshSplines].alias3ComponentPath = copy.alias3ComponentPath
    meshSplines[#meshSplines].isStartCap = copy.isStartCap
    meshSplines[#meshSplines].startCapRot = copy.startCapRot
    meshSplines[#meshSplines].startCapMeshPath = copy.startCapMeshPath
    meshSplines[#meshSplines].startCapMeshName = copy.startCapMeshName
    meshSplines[#meshSplines].startCapComponentPath = copy.startCapComponentPath
    meshSplines[#meshSplines].startCapOffset = copy.startCapOffset or 0.0
    meshSplines[#meshSplines].isEndCap = false
    meshSplines[#meshSplines].endCapRot = defaultRot
    meshSplines[#meshSplines].endCapMeshPath = defaultMeshPath
    meshSplines[#meshSplines].endCapMeshName = defaultMeshName
    meshSplines[#meshSplines].endCapComponentPath = copy.endCapComponentPath
    meshSplines[#meshSplines].endCapOffset = 0.0

    -- Get split geometry for first half
    local nodes1, widths1, nmls1, nodes2, widths2, nmls2 = geom.splitSplineGeometry(copy.nodes, copy.widths, copy.nmls, selectedNodeIdx)
    for i = 1, #nodes1 do
      table.insert(meshSplines[#meshSplines].nodes, nodes1[i])
      table.insert(meshSplines[#meshSplines].widths, widths1[i])
      table.insert(meshSplines[#meshSplines].nmls, nmls1[i])
    end

    -- Add second half (B).
    addNewMeshSpline()
    meshSplines[#meshSplines].name = copy.name .. '_split_B'
    meshSplines[#meshSplines].isDirty = true
    meshSplines[#meshSplines].isLoop = false
    meshSplines[#meshSplines].isLink = false
    meshSplines[#meshSplines].linkId = nil
    meshSplines[#meshSplines].isEnabled = true
    meshSplines[#meshSplines].normalMode = copy.normalMode
    meshSplines[#meshSplines].isCenteredLeft = copy.isCenteredLeft
    meshSplines[#meshSplines].verticalOffset = copy.verticalOffset
    meshSplines[#meshSplines].isConformToTerrain = copy.isConformToTerrain
    meshSplines[#meshSplines].isAliasRoundRobin = copy.isAliasRoundRobin
    meshSplines[#meshSplines].isFixedEnds = copy.isFixedEnds
    meshSplines[#meshSplines].roadLength = 0.0
    meshSplines[#meshSplines].spacing = copy.spacing
    meshSplines[#meshSplines].jitterForward = copy.jitterForward
    meshSplines[#meshSplines].jitterRight = copy.jitterRight
    meshSplines[#meshSplines].jitterUp = copy.jitterUp
    meshSplines[#meshSplines].splineRandomSeed = copy.splineRandomSeed
    meshSplines[#meshSplines].rot = copy.rot
    meshSplines[#meshSplines].mainRandomWeight = copy.mainRandomWeight
    meshSplines[#meshSplines].centerMeshPath = copy.centerMeshPath
    meshSplines[#meshSplines].centerMeshName = copy.centerMeshName
    meshSplines[#meshSplines].mainComponentPath = copy.mainComponentPath
    meshSplines[#meshSplines].extentsW_Center = copy.extentsW_Center
    meshSplines[#meshSplines].extentsL_Center = copy.extentsL_Center
    meshSplines[#meshSplines].boxXLeft_Center = copy.boxXLeft_Center
    meshSplines[#meshSplines].boxXRight_Center = copy.boxXRight_Center
    meshSplines[#meshSplines].boxYLeft_Center = copy.boxYLeft_Center
    meshSplines[#meshSplines].boxYRight_Center = copy.boxYRight_Center
    meshSplines[#meshSplines].isAlias1 = copy.isAlias1
    meshSplines[#meshSplines].alias1RandomWeight = copy.alias1RandomWeight
    meshSplines[#meshSplines].alias1Rot = copy.alias1Rot
    meshSplines[#meshSplines].alias1MeshPath = copy.alias1MeshPath
    meshSplines[#meshSplines].alias1MeshName = copy.alias1MeshName
    meshSplines[#meshSplines].alias1ComponentPath = copy.alias1ComponentPath
    meshSplines[#meshSplines].isAlias2 = copy.isAlias2
    meshSplines[#meshSplines].alias2RandomWeight = copy.alias2RandomWeight
    meshSplines[#meshSplines].alias2Rot = copy.alias2Rot
    meshSplines[#meshSplines].alias2MeshPath = copy.alias2MeshPath
    meshSplines[#meshSplines].alias2MeshName = copy.alias2MeshName
    meshSplines[#meshSplines].alias2ComponentPath = copy.alias2ComponentPath
    meshSplines[#meshSplines].isAlias3 = copy.isAlias3
    meshSplines[#meshSplines].alias3RandomWeight = copy.alias3RandomWeight
    meshSplines[#meshSplines].alias3Rot = copy.alias3Rot
    meshSplines[#meshSplines].alias3MeshPath = copy.alias3MeshPath
    meshSplines[#meshSplines].alias3MeshName = copy.alias3MeshName
    meshSplines[#meshSplines].alias3ComponentPath = copy.alias3ComponentPath
    meshSplines[#meshSplines].isStartCap = false
    meshSplines[#meshSplines].startCapRot = defaultRot
    meshSplines[#meshSplines].startCapMeshPath = defaultMeshPath
    meshSplines[#meshSplines].startCapMeshName = defaultMeshName
    meshSplines[#meshSplines].startCapComponentPath = copy.startCapComponentPath
    meshSplines[#meshSplines].startCapOffset = 0.0
    meshSplines[#meshSplines].isEndCap = copy.isEndCap
    meshSplines[#meshSplines].endCapRot = copy.endCapRot
    meshSplines[#meshSplines].endCapMeshPath = copy.endCapMeshPath
    meshSplines[#meshSplines].endCapMeshName = copy.endCapMeshName
    meshSplines[#meshSplines].endCapComponentPath = copy.endCapComponentPath
    meshSplines[#meshSplines].endCapOffset = copy.endCapOffset or 0.0

    -- Get split geometry for second half
    for i = 1, #nodes2 do
      table.insert(meshSplines[#meshSplines].nodes, nodes2[i])
      table.insert(meshSplines[#meshSplines].widths, widths2[i])
      table.insert(meshSplines[#meshSplines].nmls, nmls2[i])
    end

    util.computeIdToIdxMap(meshSplines, splineMap)
  end
end

-- Joins two unlooped Mesh Splines into one, modifying spline1 and deleting spline2.
local function joinMeshSplines(splineIdx1, nodeIdx1, splineIdx2, nodeIdx2)
  local spline1, spline2 = meshSplines[splineIdx1], meshSplines[splineIdx2]
  if not spline1 or not spline2 then
    return -- Early return if invalid spline indices.
  end

  -- Determine join case and concatenate in correct order.
  local n1, w1, nm1 = spline1.nodes, spline1.widths, spline1.nmls
  local n2, w2, nm2 = spline2.nodes, spline2.widths, spline2.nmls
  local nodesNew, widthsNew, nmlsNew = geom.joinSplineGeometry(n1, w1, nm1, nodeIdx1, n2, w2, nm2, nodeIdx2)
  if not nodesNew then
    return -- Early return if invalid node indices.
  end

  -- Apply joined geometry to spline1.
  spline1.nodes = nodesNew
  spline1.widths = widthsNew
  spline1.nmls = nmlsNew
  spline1.isLoop = false
  spline1.isDirty = true

  -- Safely remove spline2 without index adjustment
  removeMeshSpline(splineIdx2)

  -- Recompute the map
  util.computeIdToIdxMap(meshSplines, splineMap)
end

-- Undo/redo core function.
local function singleSplineEditUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx then
    -- Remove the spline if it has less than 2 nodes.
    local spline = meshSplines[idx]
    if #data.nodes < 2 then
      pop.tryRemove(spline)
    end

    -- Update the spline with the new data.
    spline.name = data.name
    spline.isDirty = true -- Set the dirty flag to true.
    spline.isLoop = data.isLoop
    spline.isLink = data.isLink
    spline.linkId = data.linkId
    spline.nodes = data.nodes
    spline.widths = data.widths
    spline.nmls = data.nmls
    spline.isEnabled = data.isEnabled
    spline.normalMode = data.normalMode
    spline.isCenteredLeft = data.isCenteredLeft
    spline.isConformToTerrain = data.isConformToTerrain
    spline.isAliasRoundRobin = data.isAliasRoundRobin
    spline.isFixedEnds = data.isFixedEnds
    spline.roadLength = data.roadLength
    spline.spacing = data.spacing
    spline.verticalOffset = data.verticalOffset or 0.0
    spline.jitterForward = data.jitterForward
    spline.jitterRight = data.jitterRight
    spline.jitterUp = data.jitterUp
    spline.splineRandomSeed = data.splineRandomSeed
    spline.rot = data.rot
    spline.mainRandomWeight = data.mainRandomWeight
    spline.centerMeshPath = data.centerMeshPath
    spline.centerMeshName = data.centerMeshName
    spline.mainComponentPath = data.mainComponentPath
    spline.extentsW_Center = data.extentsW_Center
    spline.extentsL_Center = data.extentsL_Center
    spline.boxXLeft_Center = data.boxXLeft_Center
    spline.boxXRight_Center = data.boxXRight_Center
    spline.boxYLeft_Center = data.boxYLeft_Center
    spline.boxYRight_Center = data.boxYRight_Center
    spline.isAlias1 = data.isAlias1
    spline.alias1RandomWeight = data.alias1RandomWeight
    spline.alias1Rot = data.alias1Rot
    spline.alias1MeshPath = data.alias1MeshPath
    spline.alias1MeshName = data.alias1MeshName
    spline.alias1ComponentPath = data.alias1ComponentPath
    spline.isAlias2 = data.isAlias2
    spline.alias2RandomWeight = data.alias2RandomWeight
    spline.alias2Rot = data.alias2Rot
    spline.alias2MeshPath = data.alias2MeshPath
    spline.alias2MeshName = data.alias2MeshName
    spline.alias2ComponentPath = data.alias2ComponentPath
    spline.isAlias3 = data.isAlias3
    spline.alias3RandomWeight = data.alias3RandomWeight
    spline.alias3Rot = data.alias3Rot
    spline.alias3MeshPath = data.alias3MeshPath
    spline.alias3MeshName = data.alias3MeshName
    spline.alias3ComponentPath = data.alias3ComponentPath
    spline.isStartCap = data.isStartCap
    spline.startCapRot = data.startCapRot
    spline.startCapMeshPath = data.startCapMeshPath
    spline.startCapMeshName = data.startCapMeshName
    spline.startCapComponentPath = data.startCapComponentPath
    spline.startCapOffset = data.startCapOffset or 0.0
    spline.isEndCap = data.isEndCap
    spline.endCapRot = data.endCapRot
    spline.endCapMeshPath = data.endCapMeshPath
    spline.endCapMeshName = data.endCapMeshName
    spline.endCapComponentPath = data.endCapComponentPath
    spline.endCapOffset = data.endCapOffset or 0.0

    -- Special case for when the mesh spline has been renamed.
    if data.isUpdateSceneTree then
      local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
      if folder then
        folder:setName(spline.name)
      end
      editor.refreshSceneTreeWindow()
    end
  end
end

-- Handles the undo for a single mesh spline.
local function singleSplineEditUndo(meshSplineData)
  local data = meshSplineData.old
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the redo for a single mesh spline.
local function singleSplineEditRedo(meshSplineData)
  local data = meshSplineData.new
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the undo for preset selection (removes meshes before applying).
local function presetSelectionUndo(meshSplineData)
  local data = meshSplineData.old
  if data then
    local idx = splineMap[data.id]
    if idx then
      local spline = meshSplines[idx]
      -- Remove all existing meshes before applying the old state.
      pop.tryRemove(spline)
      singleSplineEditUndoRedoCore(data)
    end
  end
end

-- Handles the redo for preset selection (removes meshes before applying).
local function presetSelectionRedo(meshSplineData)
  local data = meshSplineData.new
  if data then
    local idx = splineMap[data.id]
    if idx then
      local spline = meshSplines[idx]
      -- Remove all existing meshes before applying the new state.
      pop.tryRemove(spline)
      singleSplineEditUndoRedoCore(data)
    end
  end
end

-- Handles the undo for trans-meshspline edits.
local function transSplineEditUndo(data)
  removeAllMeshSplines(true)
  setMeshSplines(data.old)
  for i = 1, #meshSplines do
    meshSplines[i].isDirty = true
  end
  util.computeIdToIdxMap(meshSplines, splineMap)
end

-- Handles the redo for trans-meshspline edits.
local function transSplineEditRedo(data)
  removeAllMeshSplines(true)
  setMeshSplines(data.new)
  for i = 1, #meshSplines do
    meshSplines[i].isDirty = true
  end
  util.computeIdToIdxMap(meshSplines, splineMap)
end

-- Recompute the spline id -> index map (called by the shared session helper after a load appends the loaded splines).
local function recomputeIdMap() util.computeIdToIdxMap(meshSplines, splineMap) end

-- Core function for the object select undo/redo.
local function objectSelectUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx and meshSplines[idx] then
    pop.tryRemove(meshSplines[idx])
    meshSplines[idx] = data
    meshSplines[idx].isDirty = true
    util.computeIdToIdxMap(meshSplines, splineMap)
  end
end

-- Undo callback for object select operations.
local function objectSelectUndo(data) objectSelectUndoRedoCore(data.old) end

-- Redo callback for object select operations.
local function objectSelectRedo(data) objectSelectUndoRedoCore(data.new) end

-- Copies the profile of the given mesh spline.
local function copyMeshSplineProfile(spline)
  local copy = deepCopyMeshSpline(spline)
  copy.nodes = nil
  copy.widths = nil
  copy.nmls = nil
  copy.divPoints = nil
  copy.divWidths = nil
  copy.tangents = nil
  copy.binormals = nil
  copy.normals = nil
  copy.discMap = nil
  return copy
end

-- Pastes the profile to the given mesh spline.
local function pasteMeshSplineProfile(spline, profile)
  -- Clean up old mesh objects before applying new profile.
  pop.tryRemove(spline)

  spline.isDirty = true
  spline.normalMode = profile.normalMode
  spline.isCenteredLeft = profile.isCenteredLeft
  spline.isConformToTerrain = profile.isConformToTerrain
  spline.isAliasRoundRobin = profile.isAliasRoundRobin
  spline.isFixedEnds = profile.isFixedEnds
  spline.spacing = profile.spacing
  spline.verticalOffset = profile.verticalOffset
  spline.jitterForward = profile.jitterForward
  spline.jitterRight = profile.jitterRight
  spline.jitterUp = profile.jitterUp
  spline.splineRandomSeed = profile.splineRandomSeed
  spline.rot = profile.rot
  spline.mainRandomWeight = profile.mainRandomWeight
  spline.centerMeshPath = profile.centerMeshPath
  spline.centerMeshName = profile.centerMeshName
  spline.mainComponentPath = profile.mainComponentPath
  spline.extentsW_Center = profile.extentsW_Center
  spline.extentsL_Center = profile.extentsL_Center
  spline.boxXLeft_Center = profile.boxXLeft_Center
  spline.boxXRight_Center = profile.boxXRight_Center
  spline.boxYLeft_Center = profile.boxYLeft_Center
  spline.boxYRight_Center = profile.boxYRight_Center
  spline.isAlias1 = profile.isAlias1
  spline.alias1RandomWeight = profile.alias1RandomWeight
  spline.alias1Rot = profile.alias1Rot
  spline.alias1MeshPath = profile.alias1MeshPath
  spline.alias1MeshName = profile.alias1MeshName
  spline.alias1ComponentPath = profile.alias1ComponentPath
  spline.isAlias2 = profile.isAlias2
  spline.alias2RandomWeight = profile.alias2RandomWeight
  spline.alias2Rot = profile.alias2Rot
  spline.alias2MeshPath = profile.alias2MeshPath
  spline.alias2MeshName = profile.alias2MeshName
  spline.alias2ComponentPath = profile.alias2ComponentPath
  spline.isAlias3 = profile.isAlias3
  spline.alias3RandomWeight = profile.alias3RandomWeight
  spline.alias3Rot = profile.alias3Rot
  spline.alias3MeshPath = profile.alias3MeshPath
  spline.alias3MeshName = profile.alias3MeshName
  spline.alias3ComponentPath = profile.alias3ComponentPath
  spline.isStartCap = profile.isStartCap
  spline.startCapRot = profile.startCapRot
  spline.startCapMeshPath = profile.startCapMeshPath
  spline.startCapMeshName = profile.startCapMeshName
  spline.startCapComponentPath = profile.startCapComponentPath
  spline.startCapOffset = profile.startCapOffset or 0.0
  spline.isEndCap = false -- Do not include end cap for spline A..
  spline.endCapRot = defaultRot -- Use default rotation for end cap, since it is not first used.
  spline.endCapMeshPath = defaultMeshPath -- Use default mesh for end cap, since it is not first used.
  spline.endCapMeshName = defaultMeshName -- Use default mesh name for end cap, since it is not first used.
  spline.endCapComponentPath = profile.endCapComponentPath
  spline.endCapOffset = 0.0
end

-- Serializes a mesh spline to a table.
local function serializeMeshSpline(spline)
  table.clear(spline.divPoints)
  table.clear(spline.divWidths)
  table.clear(spline.tangents)
  table.clear(spline.binormals)
  table.clear(spline.normals)
  table.clear(spline.discMap)
  return buffer.encode(spline)
end

-- Serialises a mesh spline to a portable plain table for a session file (see toolUtilities/session). Deep-copied through the
-- codec so the live spline is never mutated; derived geometry is emptied (rebuilt by the dirty pass) and the runtime scene
-- handle dropped.
local function serializeMeshSplineToTable(spline)
  return session.itemToTable(spline,
    { 'divPoints', 'divWidths', 'tangents', 'binormals', 'normals', 'discMap', 'ribPoints' },
    { 'sceneTreeFolderId' })
end

-- Deserializes a mesh spline. `data` is either the editor's buffer-encoded blob (string) or a plain table straight from a JSON
-- session file. On the JSON path the derived scratch tables are empty and node positions arrive as plain {x,y,z}, so guarantee
-- the tables exist and rehydrate them to vec3 before the first build.
local function deserializeMeshSpline(data, isCreateObject)
  local spline = type(data) == 'table' and data or buffer.decode(data)
  spline.isDirty = true

  spline.nodes = spline.nodes or {}
  spline.widths = spline.widths or {}
  spline.nmls = spline.nmls or {}
  spline.divPoints = spline.divPoints or {}
  spline.divWidths = spline.divWidths or {}
  spline.tangents = spline.tangents or {}
  spline.binormals = spline.binormals or {}
  spline.normals = spline.normals or {}
  spline.discMap = spline.discMap or {}
  spline.isFixedEnds = spline.isFixedEnds or false
  spline.startCapOffset = spline.startCapOffset or 0.0 -- backward-compat: older sessions/presets predate cap offsets.
  spline.endCapOffset = spline.endCapOffset or 0.0
  session.rehydrateVec3Array(spline.nodes)
  session.rehydrateVec3Array(spline.nmls)

  -- Create a new scene tree folder for the mesh spline, if requested. A locked spline kept across a Lua reload keeps its own.
  if spline.keptObjects and spline.sceneTreeFolderId and scenetree.findObjectById(spline.sceneTreeFolderId) then
    -- Kept folder: nothing to create.
  elseif isCreateObject then
    -- Ensure we have a unique mesh spline name.
    local baseName = string.format(toolPrefixStr .. " %d", #meshSplines + 1)
    local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

    -- Create a new scene tree folder for the mesh spline.
    local newFolder = createObject("SimGroup")
    newFolder:registerObject(string.format("%s - %s", uniqueName, spline.id))
    newFolder.cansave = not spline.isEnabled -- Transient while editing; a locked spline's folder saves with the level.
    scenetree.MissionGroup:addObject(newFolder)
    spline.sceneTreeFolderId = newFolder:getId()
  end
  return spline
end

-- Updates the geometry and meshes of any dirty mesh splines.
local function updateDirtyMeshSplines()
  local rebuiltAny = false -- did any spline actually rebuild this pass? (-> the document has an unsaved edit).
  for i = 1, #meshSplines do
    local spline = meshSplines[i]
    if spline.isDirty then
      rebuiltAny = true
      -- Check if spline has enough nodes to be valid (minimum 2)
      local nodes = spline.nodes
      if #nodes < 2 then
        -- Remove all meshes and clear secondary geometry when insufficient nodes.
        pop.tryRemove(spline)
        populationEngine.clearDerivedGeometry(spline)
        spline.roadLength = 0.0
      else
        populationEngine.updateGeometry(spline, minSplineDivisions)
        pop.populateMeshSpline(spline, i)

        spline.roadLength = util.getPolyLength(nodes) -- Update the spline length.
      end

      spline.isDirty = false
    end
  end
  if rebuiltAny then session.markEdited('meshSpline') end -- fold this pass's edits into the Save/Save As dirty state (load guard swallows a fresh load's rebuild).
end

-- One-shot: drops the spline's control nodes onto the surface below (raycast). The build stays free in 3D, so this simply moves
-- the nodes down to the terrain/objects; run it again after terraforming to re-snap.
local function conformNodesToTerrain(spline)
  if not spline or not spline.nodes then return end
  local nodes = spline.nodes
  for i = 1, #nodes do
    util.vertRaycast(nodes[i])
  end
  spline.isDirty = true
end

-- Converts the given paths (traced from a bitmap) to mesh splines.
local function convertPathsToMeshSplines(paths)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  for i = 1, #paths do
    local path = paths[i]

    -- Create a new mesh spline.
    addNewMeshSpline()
    local spline = meshSplines[#meshSplines]

    -- Convert the grid points to world space.
    local points = path.points
    local numPoints = #points
    local pointsWS = {}
    for j = 1, numPoints do
      local pointGrid = points[j]
      tmpPoint2I.x, tmpPoint2I.y = pointGrid.x, pointGrid.y
      pointsWS[j] = te:gridToWorldByPoint2I(tmpPoint2I, tb)
    end

    -- If the path is sufficiently large, then import it.
    local aabb = geom.getAABB(pointsWS)
    if min(abs(aabb.xMax - aabb.xMin), abs(aabb.yMax - aabb.yMin)) > minImportSize then
      spline.nodes, spline.widths = pointsWS, path.widths -- Set the nodes and widths directly.
      for j = 1, numPoints do
        spline.nmls[j] = geom.getTerrainNormal(pointsWS[j]) -- Compute the normals for each node.
      end
    end
  end
  log('I', logTag, string.format("Converted %d traced paths to mesh splines. %d paths were too small to import.", #paths, #paths - #meshSplines))
end

-- Returns the current list of mesh splines.
local function getCurrentMeshSplineList()
  local numSplines = #meshSplines
  local list, ctr = {}, 1
  for i = 1, numSplines do
    local spline = meshSplines[i]
    if spline.isEnabled then
      list[ctr] = { name = spline.name, id = spline.id, type = toolPrefixStr }
      ctr = ctr + 1
    end
  end
  return list
end

-- Returns true if the given mesh spline is linked, false otherwise.
local function isLinked(id)
  local spline = meshSplines[splineMap[id]]
  return spline and spline.isLink or false
end

-- Sets the given linked mesh spline to be linked or not.
local function setLink(id, groupId, isLink)
  local spline = meshSplines[splineMap[id]]
  if spline then
    spline.isLink = isLink
    if isLink then
      spline.linkId = groupId
    else
      spline.linkId = nil
    end
    pop.tryRemove(spline)
    spline.isDirty = true
  end
end

-- Updates the given linked mesh spline with the given geometry.
local function updateLinkedMeshSpline(id, points, widths, nmls, isLoop, isConformToTerrain)
  local spline = meshSplines[splineMap[id]]
  if spline then
    spline.nodes, spline.widths, spline.nmls = points, widths, nmls
    spline.isLoop = isLoop -- Propagate the loop state of the master spline to the linked spline.
    spline.isConformToTerrain = isConformToTerrain -- Propagate the conform to surface below state of the master spline to the linked spline.

    -- If there are insufficient nodes, clear secondary geometry and remove existing meshes.
    if #points < 2 then
      table.clear(spline.divPoints)
      table.clear(spline.divWidths)
      table.clear(spline.tangents)
      table.clear(spline.binormals)
      table.clear(spline.normals)
      table.clear(spline.discMap)
      pop.tryRemove(spline)
    end

    spline.isDirty = true
  end
end

-- Unlinks all mesh splines.
local function unlinkAll()
  for i = 1, #meshSplines do
    local spline = meshSplines[i]
    if spline.isLink then
      spline.isLink = false
      spline.linkId = nil
    end
    spline.isDirty = true
  end
end


-- Public interface.
M.getToolPrefixStr =                                    getToolPrefixStr
M.getEditModeKey =                                      getEditModeKey
M.getMeshSplines =                                      getMeshSplines
M.getSplineMap =                                        getSplineMap
M.setMeshSplines =                                      setMeshSplines
M.setMeshSpline =                                       setMeshSpline
M.setPreset =                                           setPreset
M.getDefaultSliderParams =                              getDefaultSliderParams

M.addNewMeshSpline =                                    addNewMeshSpline

M.splitMeshSpline =                                     splitMeshSpline
M.joinMeshSplines =                                     joinMeshSplines

M.removeMeshSpline =                                    removeMeshSpline
M.findMeshSpline =                                      findMeshSpline
M.removeLinkedMeshSpline =                              removeLinkedMeshSpline
M.removeAllMeshSplines =                                removeAllMeshSplines

M.deepCopyMeshSpline =                                  deepCopyMeshSpline
M.deepCopyMeshSplineState =                             deepCopyMeshSplineState
M.copyMeshSplineProfile =                               copyMeshSplineProfile
M.pasteMeshSplineProfile =                              pasteMeshSplineProfile

M.singleSplineEditUndo =                                singleSplineEditUndo
M.singleSplineEditRedo =                                singleSplineEditRedo
M.presetSelectionUndo =                                 presetSelectionUndo
M.presetSelectionRedo =                                 presetSelectionRedo
M.transSplineEditUndo =                                 transSplineEditUndo
M.transSplineEditRedo =                                 transSplineEditRedo
M.objectSelectUndo =                                    objectSelectUndo
M.objectSelectRedo =                                    objectSelectRedo

M.updateDirtyMeshSplines =                              updateDirtyMeshSplines
M.conformNodesToTerrain =                               conformNodesToTerrain

M.convertPathsToMeshSplines =                           convertPathsToMeshSplines

M.serializeMeshSpline =                                 serializeMeshSpline
M.deserializeMeshSpline =                               deserializeMeshSpline
M.serializeMeshSplineToTable =                          serializeMeshSplineToTable
M.recomputeIdMap =                                      recomputeIdMap
M.deepCopyMeshSplineState =                             deepCopyMeshSplineState

M.getCurrentMeshSplineList =                            getCurrentMeshSplineList
M.isLinked =                                            isLinked
M.setLink =                                             setLink
M.updateLinkedMeshSpline =                              updateLinkedMeshSpline
M.unlinkAll =                                           unlinkAll

return M