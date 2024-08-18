-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

local defaultFilledColor = ColorF(0, 1, 0, 1)
local defaultFilling1Color = ColorF(1, 0, 0, 1)
local defaultFilling2Color = ColorF(0, 0, 1, 1)
local defaultBackgorundColor = ColorF(1, 1, 1, 1)
local defaultAmount = 32
local defaultDecalPath = "art/shapes/interface/parkDecal.png"
local defaultDecalScale = {1,1,3}
local defaultInverted = false

C.name = 'Decal Single'
C.color = ui_flowgraph_editor.nodeColors.scene
C.icon = ui_flowgraph_editor.nodeIcons.scene
C.description = "Will draw a single decal - be aware of low performance when drawing many individual decals."
C.category = 'repeat_instant'

C.pinSchema = {
    { dir = 'in', type = 'vec3', name = 'pos', description = 'Position' },
    { dir = 'in', type = 'quat', name = 'rot', description = 'rotation' },
    { dir = 'in', type = 'vec3', name = 'scl', description = "Decal's scale", default = defaultDecalScale, hardcoded = true },
    { dir = 'in', type = 'string', name = 'decalPath', description = "The path to the decal to be used", default = defaultDecalPath, hardcoded = true },
    { dir = 'in', type = 'color', name = 'clrA', hidden = true, hardcoded = true, default = {51/255,135/255,255/255,200/255}, description = 'Color of thje decal' },
    { dir = 'in', type = 'color', name = 'clrB', hidden = true, hardcoded = true, default = {165/255,203/255,255/255,200/255}, description = 'Color of thje decal' },
    { dir = 'in', type = 'number', name = 'clrFrequency', hidden = true, hardcoded = true, default = 2, description = '' },
}

C.tags = {'util', 'draw'}

function C:init()
end
local pingpong = function(t, max)
  local v = (t % (2 * max))
  if v > max then
    return max - (v - max)
  else
    return v
  end
end
function C:work()
  local clr = {}
  for i = 1, 4 do
    clr[i] = lerp(self.pinIn.clrA.value[i], self.pinIn.clrB.value[i], pingpong(os.clockhp() * self.pinIn.clrFrequency.value, 1))
  end
  local decal = {{
    texture = self.pinIn.decalPath.value,
    position = vec3(self.pinIn.pos.value),
    forwardVec = quat(self.pinIn.rot.value) * vec3(0,1,0),
    color = ColorF(clr[1], clr[2], clr[3], clr[4]),
    scale = vec3(self.pinIn.scl.value),
    fadeStart = 100,
    fadeEnd = 150
  }}
  Engine.Render.DynamicDecalMgr.addDecals(decal, 1)
end

return _flowgraph_createNode(C)
