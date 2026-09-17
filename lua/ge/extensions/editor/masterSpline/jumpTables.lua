-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The is a utility module for the Master Spline tool, which contains various jump tables for fast lookup in compatible spline tools.

local M = {}

-- Module dependencies.
local meshSplineLink = require('editor/meshSpline/splineMgr')
local assemblySplineLink = require('editor/assemblySpline/splineMgr')
local decalSplineLink = require('editor/decalSpline/splineMgr')
local roadSplineLink = require('editor/roadSpline/groupMgr')
local util = require('editor/toolUtilities/util')

-- Module constants.
local meshSplineStr = meshSplineLink.getToolPrefixStr()
local assemblySplineStr = assemblySplineLink.getToolPrefixStr()
local decalSplineStr = decalSplineLink.getToolPrefixStr()
local roadSplineStr = roadSplineLink.getToolPrefixStr()

-- A jump table for setting the link state of a given layer.
local setLinkJumpTable = {
  [meshSplineStr] = meshSplineLink.setLink,
  [assemblySplineStr] = assemblySplineLink.setLink,
  [decalSplineStr] = decalSplineLink.setLink,
  [roadSplineStr] = roadSplineLink.setLink,
}

-- A jump table for setting the name of a given spline.
local setNameJumpTable = {
  [meshSplineStr] = function(id, splineName)
    local idx = meshSplineLink.getSplineMap()[id]
    local fullSplines = meshSplineLink.getMeshSplines()
    if idx and fullSplines[idx] then
      fullSplines[idx].name = splineName
      if fullSplines[idx].sceneTreeFolderId then -- Update scene tree folder name.
        local folder = scenetree.findObjectById(fullSplines[idx].sceneTreeFolderId)
        if folder then
          folder:setName(splineName)
          editor.refreshSceneTreeWindow()
        end
      end
    end
  end,
  [assemblySplineStr] = function(id, splineName)
    local idx = assemblySplineLink.getSplineMap()[id]
    local fullSplines = assemblySplineLink.getAssemblySplines()
    if idx and fullSplines[idx] then
      fullSplines[idx].name = splineName
      if fullSplines[idx].sceneTreeFolderId then -- Update scene tree folder name.
        local folder = scenetree.findObjectById(fullSplines[idx].sceneTreeFolderId)
        if folder then
          folder:setName(splineName)
          editor.refreshSceneTreeWindow()
        end
      end
    end
  end,
  [decalSplineStr] = function(id, splineName)
    local idx = decalSplineLink.getSplineMap()[id]
    local fullSplines = decalSplineLink.getDecalSplines()
    if idx and fullSplines[idx] then
      fullSplines[idx].name = splineName
    end
  end,
  [roadSplineStr] = function(id, splineName)
    local idx = roadSplineLink.getIdToIdxMap()[id]
    local fullSplines = roadSplineLink.getGroups()
    if idx and fullSplines[idx] then
      fullSplines[idx].name = splineName
      if fullSplines[idx].sceneTreeFolderId then -- Update scene tree folder name.
        local folder = scenetree.findObjectById(fullSplines[idx].sceneTreeFolderId)
        if folder then
          folder:setName(splineName)
          editor.refreshSceneTreeWindow()
        end
      end
    end
  end,
}

-- A jump table for creating a new spline.
local createJumpTable = {
  [meshSplineStr] = meshSplineLink.addNewMeshSpline,
  [assemblySplineStr] = assemblySplineLink.addNewAssemblySpline,
  [decalSplineStr] = decalSplineLink.addNewDecalSpline,
  [roadSplineStr] = roadSplineLink.addNewGroup,
}

-- A jump table for getting the last created spline directly (optimized for undo/redo).
local getLastCreatedSplineJumpTable = {
  [meshSplineStr] = function()
    local meshSplines = meshSplineLink.getMeshSplines()
    return #meshSplines > 0 and meshSplines[#meshSplines] or nil
  end,
  [assemblySplineStr] = function()
    local assemblySplines = assemblySplineLink.getAssemblySplines()
    return #assemblySplines > 0 and assemblySplines[#assemblySplines] or nil
  end,
  [decalSplineStr] = function()
    local decalSplines = decalSplineLink.getDecalSplines()
    return #decalSplines > 0 and decalSplines[#decalSplines] or nil
  end,
  [roadSplineStr] = function()
    local roadSplines = roadSplineLink.getGroups()
    return #roadSplines > 0 and roadSplines[#roadSplines] or nil
  end,
}

-- A jump table for restoring a spline.
local restoreJumpTable = {
  [meshSplineStr] = function(data)
    local spline = meshSplineLink.deepCopyMeshSpline(data)
    local meshSplines = meshSplineLink.getMeshSplines()
    meshSplines[#meshSplines + 1] = spline
    util.computeIdToIdxMap(meshSplines, meshSplineLink.getSplineMap())
    return spline
  end,
  [assemblySplineStr] = function(data)
    local spline = assemblySplineLink.deepCopyAssemblySpline(data)
    local assemblySplines = assemblySplineLink.getAssemblySplines()
    assemblySplines[#assemblySplines + 1] = spline
    util.computeIdToIdxMap(assemblySplines, assemblySplineLink.getSplineMap())
    return spline
  end,
  [decalSplineStr] = function(data)
    local spline = decalSplineLink.deepCopyDecalSpline(data)
    local decalSplines = decalSplineLink.getDecalSplines()
    decalSplines[#decalSplines + 1] = spline
    util.computeIdToIdxMap(decalSplines, decalSplineLink.getSplineMap())
    return spline
  end,
  [roadSplineStr] = function(data)
    local spline = roadSplineLink.deepCopyGroup(data)
    roadSplineLink.addGroupToGroupArray(spline)
    util.computeIdToIdxMap(roadSplineLink.getGroups(), roadSplineLink.getIdToIdxMap())
    return spline
  end,
}

-- A jump table for unlinking splines.
local unlinkJumpTable = {
  [meshSplineStr] = function(linkedSplineId)
    local idx = meshSplineLink.getSplineMap()[linkedSplineId]
    if idx then
      local meshSplines = meshSplineLink.getMeshSplines()
      if meshSplines[idx] then
        meshSplines[idx].isLink = false
        meshSplines[idx].linkId = nil
        meshSplines[idx].isDirty = true
      end
    end
  end,
  [assemblySplineStr] = function(linkedSplineId)
    local idx = assemblySplineLink.getSplineMap()[linkedSplineId]
    if idx then
      local assemblySplines = assemblySplineLink.getAssemblySplines()
      if assemblySplines[idx] then
        assemblySplines[idx].isLink = false
        assemblySplines[idx].linkId = nil
        assemblySplines[idx].isDirty = true
      end
    end
  end,
  [decalSplineStr] = function(linkedSplineId)
    local idx = decalSplineLink.getSplineMap()[linkedSplineId]
    if idx then
      local decalSplines = decalSplineLink.getDecalSplines()
      if decalSplines[idx] then
        decalSplines[idx].isLink = false
        decalSplines[idx].linkId = nil
        decalSplines[idx].isDirty = true
      end
    end
  end,
  [roadSplineStr] = function(linkedSplineId)
    local idx = roadSplineLink.getIdToIdxMap()[linkedSplineId]
    if idx then
      local groups = roadSplineLink.getGroups()
      if groups[idx] then
        groups[idx].isLink = false
        groups[idx].linkId = nil
        groups[idx].isDirty = true
      end
    end
  end,
}

-- A jump table for removing a spline.
local removeJumpTable = {
  [meshSplineStr] = meshSplineLink.removeLinkedMeshSpline,
  [assemblySplineStr] = assemblySplineLink.removeLinkedAssemblySpline,
  [decalSplineStr] = decalSplineLink.removeLinkedDecalSpline,
  [roadSplineStr] = roadSplineLink.removeLinkedRoadSpline,
}

-- A jump table for setting isDirty flag on linked splines.
local setLinkedSplineDirtyJumpTable = {
  [meshSplineStr] = function(id)
    local idx = meshSplineLink.getSplineMap()[id]
    local fullSplines = meshSplineLink.getMeshSplines()
    if idx and fullSplines[idx] then
      fullSplines[idx].isDirty = true
    end
  end,
  [assemblySplineStr] = function(id)
    local idx = assemblySplineLink.getSplineMap()[id]
    local fullSplines = assemblySplineLink.getAssemblySplines()
    if idx and fullSplines[idx] then
      fullSplines[idx].isDirty = true
    end
  end,
  [decalSplineStr] = function(id)
    local idx = decalSplineLink.getSplineMap()[id]
    local fullSplines = decalSplineLink.getDecalSplines()
    if idx and fullSplines[idx] then
      fullSplines[idx].isDirty = true
    end
  end,
  [roadSplineStr] = function(id)
    local idx = roadSplineLink.getIdToIdxMap()[id]
    local fullSplines = roadSplineLink.getGroups()
    if idx and fullSplines[idx] then
      fullSplines[idx].isDirty = true
    end
  end,
}

-- A jump table for serializing linked splines.
local serializeJumpTable = {
  [meshSplineStr] = function(linkedSplineId)
    local idx = meshSplineLink.getSplineMap()[linkedSplineId]
    if idx then
      local meshSplines = meshSplineLink.getMeshSplines()
      if meshSplines[idx] then
        return meshSplineLink.deepCopyMeshSpline(meshSplines[idx])
      end
    end
    return nil
  end,
  [assemblySplineStr] = function(linkedSplineId)
    local idx = assemblySplineLink.getSplineMap()[linkedSplineId]
    if idx then
      local assemblySplines = assemblySplineLink.getAssemblySplines()
      if assemblySplines[idx] then
        return assemblySplineLink.deepCopyAssemblySpline(assemblySplines[idx])
      end
    end
    return nil
  end,
  [decalSplineStr] = function(linkedSplineId)
    local idx = decalSplineLink.getSplineMap()[linkedSplineId]
    if idx then
      local decalSplines = decalSplineLink.getDecalSplines()
      if decalSplines[idx] then
        return decalSplineLink.deepCopyDecalSpline(decalSplines[idx])
      end
    end
    return nil
  end,
  [roadSplineStr] = function(linkedSplineId)
    local idx = roadSplineLink.getIdToIdxMap()[linkedSplineId]
    if idx then
      local groups = roadSplineLink.getGroups()
      if groups[idx] then
        return roadSplineLink.deepCopyGroup(groups[idx])
      end
    end
    return nil
  end,
}

-- Jump table for getting relevant tool info from compatible tools.
local toolNavigation = {
  [meshSplineStr] = {
    uiModule = 'editor_meshSpline',
    getModeKey = meshSplineLink.getEditModeKey,
    getSplines = meshSplineLink.getMeshSplines,
    getIdToIdxMap = meshSplineLink.getSplineMap,
  },
  [assemblySplineStr] = {
    uiModule = 'editor_assemblySpline',
    getModeKey = assemblySplineLink.getEditModeKey,
    getSplines = assemblySplineLink.getAssemblySplines,
    getIdToIdxMap = assemblySplineLink.getSplineMap,
  },
  [decalSplineStr] = {
    uiModule = 'editor_decalSpline',
    getModeKey = decalSplineLink.getEditModeKey,
    getSplines = decalSplineLink.getDecalSplines,
    getIdToIdxMap = decalSplineLink.getSplineMap,
  },
  [roadSplineStr] = {
    uiModule = 'editor_roadSpline',
    getModeKey = roadSplineLink.getEditModeKey,
    getSplines = roadSplineLink.getGroups,
    getIdToIdxMap = roadSplineLink.getIdToIdxMap,
  },
}


-- Public interface.
M.setLinkJumpTable =                                    setLinkJumpTable
M.setNameJumpTable =                                    setNameJumpTable
M.createJumpTable =                                     createJumpTable
M.getLastCreatedSplineJumpTable =                       getLastCreatedSplineJumpTable
M.restoreJumpTable =                                    restoreJumpTable
M.unlinkJumpTable =                                     unlinkJumpTable
M.removeJumpTable =                                     removeJumpTable
M.setLinkedSplineDirtyJumpTable =                       setLinkedSplineDirtyJumpTable
M.serializeJumpTable =                                  serializeJumpTable
M.toolNavigation =                                      toolNavigation

return M