-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local axisColors = {
  x = ColorF(1, 0.2, 0.2, 0.95),
  y = ColorF(0.2, 1, 0.3, 0.95),
  z = ColorF(0.25, 0.55, 1, 0.95)
}
local ringColor = ColorF(1, 0.75, 0.15, 0.95)
local ringIdleColor = ColorF(1, 1, 1, 0.35)

local function normalized(vector, fallback)
  local result = vec3(vector)
  local length = result:length()
  return length > 0.0001 and result / length or vec3(fallback)
end

local function guideLength(pivot)
  return clamp((vec3(pivot) - core_camera.getPosition()):length() * 0.16, 1.5, 30)
end

local function tipRadius(pivot)
  return clamp((vec3(pivot) - core_camera.getPosition()):length() * 0.006, 0.08, 0.8)
end

local function selectedNames(constraint, includeExcluded)
  if not constraint then return {"x", "y", "z"} end
  local names = {}
  for _, name in ipairs({"x", "y", "z"}) do
    local selected = constraint.exclude and name ~= constraint.axis
      or not constraint.exclude and name == constraint.axis
    if selected and (includeExcluded or not constraint.exclude) then
      names[#names + 1] = name
    end
  end
  return names
end

function M.axisColors()
  return axisColors
end

function M.drawTranslate(pivot, axes, constraint)
  local length = guideLength(pivot)
  for _, name in ipairs(selectedNames(constraint, true)) do
    local axis = normalized(axes[name], vec3(1, 0, 0))
    local colorValue = axisColors[name]
    local shaftEnd = vec3(pivot) + axis * length * 0.82
    local tipEnd = vec3(pivot) + axis * length
    debugDrawer:drawLineInstance(pivot, shaftEnd, 3, colorValue, false)
    local radius = tipRadius(pivot) * 1.2
    debugDrawer:drawSquarePrism(
      shaftEnd,
      tipEnd,
      Point2F(radius, radius),
      Point2F(0, 0),
      colorValue)
  end
end

function M.drawScale(pivot, axes, constraint)
  local length = guideLength(pivot)
  for _, name in ipairs(selectedNames(constraint, true)) do
    local axis = normalized(axes[name], vec3(1, 0, 0))
    local tip = vec3(pivot) + axis * length
    debugDrawer:drawLineInstance(pivot, tip, 3, axisColors[name], false)
    debugDrawer:drawSphere(tip, tipRadius(pivot), axisColors[name], false)
  end
end

local function ringBasis(axis)
  local reference = math.abs(axis.z) < 0.9 and vec3(0, 0, 1) or vec3(0, 1, 0)
  local first = normalized(axis:cross(reference), vec3(1, 0, 0))
  return first, normalized(axis:cross(first), vec3(0, 1, 0))
end

local function drawRing(pivot, axis, radius, colorValue, width)
  local first, second = ringBasis(axis)
  local previous = vec3(pivot) + first * radius
  for index = 1, 64 do
    local angle = math.pi * 2 * index / 64
    local point = vec3(pivot)
      + (first * math.cos(angle) + second * math.sin(angle)) * radius
    debugDrawer:drawLineInstance(previous, point, width, colorValue, false)
    previous = point
  end
end

function M.drawRotation(pivot, axis, startVector, angle)
  local rotationAxis = normalized(axis, vec3(0, 0, 1))
  local radius = guideLength(pivot) * 0.65
  drawRing(pivot, rotationAxis, radius, ringIdleColor, 2)
  if not startVector or math.abs(angle or 0) <= 0.0001 then return end
  local radial = vec3(startVector)
  radial = radial - rotationAxis * radial:dot(rotationAxis)
  radial = normalized(radial, ringBasis(rotationAxis))
  local segmentCount = math.max(2, math.ceil(math.abs(angle) / (math.pi / 32)))
  local previous = vec3(pivot) + radial * radius
  for index = 1, segmentCount do
    local rotation = quatFromAxisAngle(rotationAxis, angle * index / segmentCount)
    local point = vec3(pivot) + rotation * radial * radius
    debugDrawer:drawLineInstance(previous, point, 5, ringColor, false)
    previous = point
  end
end

return M
