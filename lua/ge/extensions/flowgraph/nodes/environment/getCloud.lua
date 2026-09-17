-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Get Clouds'
C.icon = "simobject_scatter_sky"
C.description = "Gets a specific cloud object parameters."
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'objectId', description = "(Optional) Specific cloud object id; if not provided, attempts to use default clouds." },
  { dir = 'out', type = 'number', name = 'coverage', description = "How much of the sky is covered by this cloud." },
  { dir = 'out', type = 'number', name = 'exposure', description = "Brightness scale of the cloud." },
  { dir = 'out', type = 'number', name = 'windSpeed', description = "How fast the cloud texture will scroll." },
  { dir = 'out', type = 'number', name = 'height', description = "Height of cloud in the sky." },
}

C.tags = {'environment', 'weather', 'cloud'}

function C:work()
  local cloudId = self.pinIn.objectId.value
  if cloudId then
    self.pinOut.coverage.value = core_environment.getCloudCoverByID(cloudId)
    self.pinOut.exposure.value = core_environment.getCloudExposureByID(cloudId)
    self.pinOut.windSpeed.value = core_environment.getCloudWindByID(cloudId)
    self.pinOut.height.value = core_environment.getCloudHeightByID(cloudId)
  else
    -- only some of these are available for the default cloud object
    self.pinOut.coverage.value = core_environment.getCloudCover()
    self.pinOut.exposure.value = 0
    self.pinOut.windSpeed.value = core_environment.getWindSpeed()
    self.pinOut.height.value = 0
  end
end

return _flowgraph_createNode(C)