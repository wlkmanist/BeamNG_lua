-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local im = ui_imgui
M.debugOrder = 3
M.debugName = "Organizations"

M.drawDebugFunctions = function()
  if im.Selectable1("> Give random reputation to 30% of organizations") then
    local change = {}
    for _, org in pairs(freeroam_organizations.getOrganizations()) do
      if math.random(1, 100) <= 30 then
        change[org.attributeKey] = math.random(-50, 150)
        career_career.interactWithOrganization(org.id)
      end
    end
    dump(change)
    career_modules_playerAttributes.addAttributes(change, {tags={"gameplay", "delivery","reputation", "Cheat"}, label="Reputation change for organizations Cheat"})
  end

  if im.Selectable1("Interact with random facilities") then
    local facilities = career_modules_delivery_generator.getFacilities()
    for _, fac in ipairs(facilities) do
      if math.random(1, 100) <= 30 then
        fac.progress.interacted = true
      end
    end
  end
end

return M
