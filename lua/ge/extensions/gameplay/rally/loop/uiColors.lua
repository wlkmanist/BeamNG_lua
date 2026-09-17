-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local colors = {
  loop = "#009a1a",
  loopNgrc = "#00B890",
  stage = "#1f8fff",
  stageNgrc = "#1998b8"
}

local themeOverride = nil

local function normalizeHex(hex)
  if hex == nil then return nil end
  if type(hex) ~= "string" then return nil end
  hex = hex:match("^%s*(.-)%s*$") or ""
  if hex == "" then return nil end
  if not hex:find("^#") then hex = "#" .. hex end
  if not hex:match("^#%x%x%x%x%x%x$") then return nil end
  return hex
end

function M.setThemeOverride(hexOrNil)
  themeOverride = normalizeHex(hexOrNil)
end

function M.getThemeOverride()
  return themeOverride
end

local function update(target, isNgrcMode, color, ngrcColor)
  if not target then return end

  target.theme = isNgrcMode and ngrcColor or color
  if themeOverride then
    target.theme = themeOverride
  end
end

function M.updateForLoop(target, isNgrcMode)
  update(target, isNgrcMode, colors.loop, colors.loopNgrc)
end

function M.updateForStage(target, isNgrcMode)
  update(target, isNgrcMode, colors.stage, colors.stageNgrc)
end

return M
