-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Visualizes the shared WindField: samples be:getWindAt() on a grid around the
-- camera and draws arrows (direction = wind, length + color = speed). Gusts are
-- animated because the field is time-varying.
-- Usage: extensions.load("util_windDebug"); util_windDebug.toggle()

local M = {}

M.enabled = false

local gridCount = 21      -- arrows per side (odd = camera centered)
local spacing = 5         -- meters between arrows
local lengthScale = 0.15  -- arrow length in meters per m/s
local minSpeed = 0.05     -- skip near-calm cells
local colorMaxSpeed = 20  -- speed (m/s) mapped to full red

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max

local function speedColor(t)
  t = max(0, min(1, t))
  if t < 0.5 then return ColorF(0, t * 2, 1 - t * 2, 0.9) end
  local u = (t - 0.5) * 2
  return ColorF(u, 1 - u, 0, 0.9)
end

local function drawArrow(base, wind)
  local speed = wind:length()
  if speed < minSpeed then return end
  local dir = wind * (1 / speed)
  local len = min(speed * lengthScale, spacing * 0.9)
  local tip = base + dir * len
  local col = speedColor(speed / colorMaxSpeed)
  debugDrawer:drawLineInstance(base, tip, 3, col)
  local perp = vec3(-dir.y, dir.x, 0)
  local h = min(len * 0.35, 0.8)
  debugDrawer:drawLineInstance(tip, tip - dir * h + perp * (h * 0.6), 3, col)
  debugDrawer:drawLineInstance(tip, tip - dir * h - perp * (h * 0.6), 3, col)
end

function M.onPreRender(dtReal, dtSim)
  if not M.enabled then return end
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  if not cam then return end
  local half = floor(gridCount / 2)
  local ox = floor(cam.x / spacing) * spacing
  local oy = floor(cam.y / spacing) * spacing
  for i = -half, half do
    for j = -half, half do
      local base = vec3(ox + i * spacing, oy + j * spacing, 0)
      base.z = ((core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(base)) or (cam.z - 2)) + 1.0
      local w = be:getWindAt(base)
      drawArrow(base, vec3(w.x, w.y, w.z))
    end
  end

  local centerZ = ((core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(vec3(ox, oy, 0))) or (cam.z - 2))
  local labelPos = vec3(ox, oy, centerZ + 2)
  local wc = be:getWindAt(labelPos)
  local speed = sqrt(wc.x * wc.x + wc.y * wc.y + wc.z * wc.z)
  debugDrawer:drawTextAdvanced(labelPos, String(string.format("wind %.1f m/s (%.0f km/h)", speed, speed * 3.6)), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 192))
end

function M.setEnabled(v) M.enabled = v and true or false end
function M.toggle() M.enabled = not M.enabled end

return M
