-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local function initConsole()
  -- Create dummy global Lua objects and functions
  -- These are needed because some code queues these commands to the game engine which executes them
  function physicsEngineEvent() end
  function vehicleReset() end
  map = {
    setNameForId = function() end,
    objectData = function() end,
  }
  gameplay_statistic = {
    metricAdd = function() end,
  }
  core_sounds = {
    setEngineSoundParameterList = function() end,
    initExhaustSound = function() end,
    setExhaustSoundNodes = function() end,
    initEngineSound = function() end,
  }
end

local function createGroundModel(v)
  -- TODO: this is duplicated from environment.lua -> submitGroundModel ---> needs refactoring
  local particles = require("particles")
  local materials = particles.getMaterialsParticlesTable()
  local gm = ground_model()
  gm.roughnessCoefficient = v.roughnessCoefficient or 0
  gm.defaultDepth = v.defaultDepth or 0
  gm.staticFrictionCoefficient = v.staticFrictionCoefficient or 1
  gm.slidingFrictionCoefficient = v.slidingFrictionCoefficient or 0.7
  gm.hydrodynamicFriction = v.hydrodynamicFriction or v.hydrodnamicFriction or 0.01
  gm.stribeckVelocity = v.stribeckVelocity or 6
  gm.strength = v.strength or 1
  gm.collisiontype = 0
  if type(v.collisiontype) == 'string' then
    gm.collisiontype = particles.getOrAddMaterialIDByName(materials, v.collisiontype)
  end
  gm.fluidDensity = v.fluidDensity or 200
  gm.flowConsistencyIndex = v.flowConsistencyIndex or 10000
  gm.flowBehaviorIndex = v.flowBehaviorIndex or 0.5
  gm.dragAnisotropy = v.dragAnisotropy or 0
  gm.skidMarks = v.skidMarks or false
  gm.shearStrength = v.shearStrength or 0
  return gm
end

local function readGroundModels()
  return jsonReadFile('art/groundmodels.json')
end

M.initConsole = initConsole
M.createGroundModel = createGroundModel
M.readGroundModels = readGroundModels

return M
