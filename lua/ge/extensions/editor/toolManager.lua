-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The is a centralised module which handles the cross-tool removal of TSStatic meshes.

local M = {}

-- Module dependencies.
local meshSplineMgr = require('editor/meshSpline/splineMgr')
local meshSplinePop = require('editor/meshSpline/populate')
local assemblySplineMgr = require('editor/assemblySpline/splineMgr')
local assemblySplinePop = require('editor/assemblySpline/populate')


-- Centralised function to remove all spline tool TSStatic meshes.
-- [Returns true if any meshes were removed, false otherwise.]
local function removeAllSplineToolMeshes()
  local meshesRemoved = false

  -- Mesh spline tools.
  local meshSplines = meshSplineMgr.getMeshSplines()
  if meshSplines then
    for i = 1, #meshSplines do
      local spline = meshSplines[i]
      if spline and spline.isEnabled then
        meshSplinePop.tryRemove(spline)
        spline.isDirty = true
        meshesRemoved = true
      end
    end
  end

  -- Assembly spline tools.
  local assemblySplines = assemblySplineMgr.getAssemblySplines()
  if assemblySplines then
    for i = 1, #assemblySplines do
      local spline = assemblySplines[i]
      if spline and spline.isEnabled then
        assemblySplinePop.tryRemove(spline)
        spline.isDirty = true
        meshesRemoved = true
      end
    end
  end

  return meshesRemoved
end

-- Removes all spline tool meshes and reloads collision if needed.
-- [Called every time the editor is entered.]
local function onEditorActivated()
  if removeAllSplineToolMeshes() then
    be:reloadCollision() -- Only reload collision if we actually removed meshes.
  end
end


-- Public interface.
M.removeAllSplineToolMeshes =                           removeAllSplineToolMeshes
M.onEditorActivated =                                   onEditorActivated

return M