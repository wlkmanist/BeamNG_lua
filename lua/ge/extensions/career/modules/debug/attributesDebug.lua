-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local im = ui_imgui
M.debugOrder = 0
M.debugName = "Attributes"

M.drawDebugFunctions = function()
  if im.BeginMenu("Branches > Branch Order") then
    for _, branch in ipairs(career_branches.getSortedBranches()) do
      if im.Button("Edit##"..branch.id) then
        Engine.Platform.exploreFolder(branch.file)
      end
      im.SameLine()
      local label = (string.format("%s %04d - %s ",(branch.isSkill and "Skill" or "Branch"), branch.order, branch.id))
      if im.Selectable1(label) then
        dump(branch)
      end
    end
    im.EndMenu()
  end
end

M.drawDebugMenu = function()
  im.Text("Money: " .. career_modules_playerAttributes.getAttributeValue("money"))
  im.SameLine()
  if im.Button("+100000##money") then career_modules_playerAttributes.addAttributes({money=100000}, {tags={"cheat"},label="Debug Cheating"}) end
  im.SameLine()
  if im.Button("+10000##money") then career_modules_playerAttributes.addAttributes({money=10000}, {tags={"cheat"},label="Debug Cheating"}) end
  im.SameLine()
  if im.Button("+1000##money") then career_modules_playerAttributes.addAttributes({money=1000}, {tags={"cheat"},label="Debug Cheating"}) end
  im.SameLine()
  if im.Button("-1000##money") then career_modules_playerAttributes.addAttributes({money=-1000}, {tags={"cheat"},label="Debug Cheating"}) end
  im.SameLine()
  if im.Button("-10000##money") then career_modules_playerAttributes.addAttributes({money=-10000}, {tags={"cheat"},label="Debug Cheating"}) end

  im.Text("BeamXP: " .. career_modules_playerAttributes.getAttributeValue("beamXP"))
  im.SameLine()
  if im.Button("+1000##beamXP") then career_modules_playerAttributes.addAttributes({beamXP=1000}, {tags={"cheat", "gameplay"},label="Debug Cheating"}) end
  im.SameLine()
  if im.Button("-1000##beamXP") then career_modules_playerAttributes.addAttributes({beamXP=-1000}, {tags={"cheat", "gameplay"},label="Debug Cheating"}) end

  im.Text("Vouchers: " .. career_modules_playerAttributes.getAttributeValue("vouchers"))
  im.SameLine()
  if im.Button("+1000##vouchers") then career_modules_playerAttributes.addAttributes({vouchers=1000}, {tags={"cheat", "gameplay"},label="Debug Cheating"}) end
  im.SameLine()
  if im.Button("-1000##vouchers") then career_modules_playerAttributes.addAttributes({vouchers=-1000}, {tags={"cheat", "gameplay"},label="Debug Cheating"}) end

  for _, branch in ipairs(career_branches.getSortedBranches()) do
    local name = _tr(branch.name)
    im.Text(name ..": " .. career_modules_playerAttributes.getAttributeValue(branch.attributeKey).. " ( Level "..career_branches.getBranchLevel(branch.id).." )")
    im.SameLine()
    if im.Button("+5##"..branch.name) then career_modules_playerAttributes.addAttributes({[branch.attributeKey]=5}, {tags={"cheat", "gameplay"},label="Debug Cheating"}) end
    im.SameLine()
    if im.Button("+100##"..branch.name) then career_modules_playerAttributes.addAttributes({[branch.attributeKey]=100}, {tags={"cheat", "gameplay"},label="Debug Cheating"}) end
    im.SameLine()
    if im.Button("+500##"..branch.name) then career_modules_playerAttributes.addAttributes({[branch.attributeKey]=500}, {tags={"cheat", "gameplay"},label="Debug Cheating"}) end
  end
end

return M