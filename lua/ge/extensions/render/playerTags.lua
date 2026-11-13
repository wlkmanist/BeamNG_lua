-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Floating player name tags via the Skia mptag billboard system:
-- camera-facing billboards tinted to each player's colour and following their car.
-- Split-screen creates view-specific tags so co-drivers can see themselves at the bottom of
-- their vehicle's stack while multiseat continues to use one tag per player.
-- Multiseat tags additionally carry a persona icon over their marker.

require("utils")
local M = {}

local TAG_TEMPLATES = {
  default = "art/sktemplates/multiplayer-nametag.sktemplate.json",
  multiseat = "art/sktemplates/multiseat-player-tag.sktemplate.json",
}
local tagRenderer
local tagDesigns = {}
local tagIconPaths = {}
local playerTags = {} -- player -> runtime tag state
local hiddenPlayers = {} -- player -> true while that player's tag is hidden
local colorOverrides = {} -- player -> {r,g,b} override, applied during rebuild
local lastTags
local lastTemplateName

local TAG_SHOW_TIME = 3
local TAG_SCALE = 0.36
local TAG_VISIBLE_SCALE = 0.005
local TAG_MAX_DISTANCE = 40
local TAG_MIN_SCALE_DISTANCE = 3
local TAG_MAX_SCALE_DISTANCE = TAG_MAX_DISTANCE * 2 / 3
local TAG_CLOSE_LAYOUT_DISTANCE = 7
local TAG_POSITION_SMOOTHING = 10
local TAG_STACK = 0.33 -- vertical gap (m) between stacked co-driver tags at minimum scale
local TAG_STACK_ICON = 0.24 -- the icon makes the tag art taller
local TAG_ICON_BOTTOM_ANCHOR = 0.375 -- marker tip is 36 px below centre in the 96 px template

-- Persona icon drawn over the multiseat marker
local TAG_ICON_DIR = "ui/ui-vue/src/assets/fonts/bngIcons/svg/"
local TAG_ICON_AREA = 10
local TAG_ICON_GLYPH = 28 -- svg box inside the icon area
local TAG_ICON_RISE = 0 -- how far the icon centre sits above the marker centre
local TAG_ICON_GLYPH_COLOR = "#ffffff"
local TAG_COLOR_MIX_TOP = 0.3 -- blend player colours toward charcoal
local TAG_COLOR_MIX_BOTTOM = 0.6

local function channel(value)
  value = math.floor((value or 0) * 255 + 0.5)
  return math.max(0, math.min(255, value))
end

local function colorHex(color)
  return string.format("#%02x%02x%02x", channel(color[1]), channel(color[2]), channel(color[3]))
end

local function mutedColorHex(color, mix)
  local keep = 1 - mix
  return colorHex({
    (color[1] or 0) * keep + (54 / 255) * mix,
    (color[2] or 0) * keep + (69 / 255) * mix,
    (color[3] or 0) * keep + (79 / 255) * mix,
  })
end

local function liveRenderer()
  local r = scenetree and scenetree.playerNameTags
  if r then
    tagRenderer = r
    return r
  end
  if tagRenderer or next(playerTags) then
    tagRenderer = nil
    playerTags = {}
  end
  return nil
end

local function ensureTagRenderer()
  local r = liveRenderer()
  if r then return r end
  if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then return nil end
  r = WorldBillboardRenderer()
  if not r then return nil end
  r:registerObject("playerNameTags")
  scenetree.MissionGroup:addObject(r)
  tagRenderer = r
  return r
end

-- Paint every accent from the muted player colour to a slightly more muted variant.
local function tintAccent(node, topHex, bottomHex)
  if type(node) ~= "table" then return end
  if node.role == "accent" then
    node.color = nil
    node.gradient = {
      angle = 90,
      stops = {
        {offset = 0, color = topHex},
        {offset = 1, color = bottomHex},
      },
    }
  end
  if node.children then for _, c in ipairs(node.children) do tintAccent(c, topHex, bottomHex) end end
end

-- Read the bngIcons SVG path so its baked-in black fill can be replaced by white.
local function tagIconNode(icon)
  if type(icon) ~= "string" or not icon:match("^%w+$") then return nil end
  local pathData = tagIconPaths[icon]
  if not pathData then
    local path = TAG_ICON_DIR .. icon .. ".svg"
    if not FS:fileExists(path) then return nil end

    local svg = readFile(path)
    if type(svg) ~= "string" then return nil end
    pathData = svg:match('<path[^>]-%sd%s*=%s*"([^"]+)"')
    if not pathData then return nil end

    local minX, minY, width, height = svg:match('viewBox%s*=%s*"([%+%-%.%d]+)%s+([%+%-%.%d]+)%s+([%+%-%.%d]+)%s+([%+%-%.%d]+)"')
    minX, minY, width, height = tonumber(minX) or 0, tonumber(minY) or 0, tonumber(width) or 24, tonumber(height) or 24
    -- The move-only points preserve the SVG viewBox when the path is fitted to its layout box.
    pathData = string.format("M %g %g M %g %g %s", minX, minY, minX + width, minY + height, pathData)
    tagIconPaths[icon] = pathData
  end
  return {type = "path", path = pathData, color = TAG_ICON_GLYPH_COLOR, style = {width = TAG_ICON_GLYPH, height = TAG_ICON_GLYPH}}
end

-- Draw an icon over the marker art. The canvas grows at the top by just enough to
-- fit the icon area, and the marker art is pushed down by the same amount so
-- it keeps its own layout; the caller undoes that extra height by scaling and lifting the
-- billboard, leaving the marker itself where it was.
local function addIcon(design, iconNode)
  local size = design.size or {96, 96}
  local width, height = size[1], size[2]
  local iconRadius = TAG_ICON_AREA * 0.5 + 1
  local extra = math.ceil(math.max(0, TAG_ICON_RISE + iconRadius - height * 0.5))
  local iconTop = height * 0.5 + extra - TAG_ICON_RISE - TAG_ICON_AREA * 0.5

  local marker = design.root
  marker.type = marker.type or "group"
  marker.style = marker.style or {}
  marker.style.position = "absolute"
  marker.style.left = 0
  marker.style.top = extra
  marker.style.width = width
  marker.style.height = height

  design.size = {width, height + extra}
  design.root = {type = "group", children = {
    marker,
    {
      type = "group",
      style = {position = "absolute", left = (width - TAG_ICON_AREA) * 0.5, top = iconTop, width = TAG_ICON_AREA, height = TAG_ICON_AREA,
               justifyContent = "center", alignItems = "center"},
      children = {
        iconNode,
      },
    },
  }}
end

-- Resolve an mptag template and tint it to the player's colour. Also returns the
-- world-height multiplier and vertical anchor within the resulting canvas.
local function buildTagTemplate(name, rgb, templateName, iconNode)
  local templatePath = TAG_TEMPLATES[templateName] or TAG_TEMPLATES.default
  if not tagDesigns[templatePath] then tagDesigns[templatePath] = jsonReadFile(templatePath) end
  if not extensions.core_skiaTemplate then extensions.load("core_skiaTemplate") end
  local st = extensions.core_skiaTemplate
  local tagDesign = tagDesigns[templatePath]
  if type(tagDesign) ~= "table" or not st then return nil end
  local d = deepcopy(tagDesign)
  local baseHeight = (d.size and d.size[2]) or 96
  if iconNode then addIcon(d, iconNode) end
  tintAccent(d.root, mutedColorHex(rgb, TAG_COLOR_MIX_TOP), mutedColorHex(rgb, TAG_COLOR_MIX_BOTTOM))
  local canvasHeight = (d.size and d.size[2]) or baseHeight
  local anchorFraction = (canvasHeight - baseHeight) * 0.5 / canvasHeight
  if templateName == "multiseat" then
    anchorFraction = anchorFraction + TAG_ICON_BOTTOM_ANCHOR * baseHeight / canvasHeight
  end
  return st.resolveTemplate(d, {name = name, distance = ""}),
         canvasHeight / baseHeight,
         anchorFraction
end

local function destroy()
  local r = liveRenderer()
  if r then
    for _, state in pairs(playerTags) do pcall(function() r:destroy(state.id) end) end
  end
  playerTags = {}
end
M.destroy = destroy

-- drop the renderer reference (e.g. before a GE/Lua reload tears down the C++ object)
function M.reset()
  destroy()
  tagRenderer = nil
  table.clear(hiddenPlayers)
  table.clear(colorOverrides)
end
M.onExtensionUnloaded = M.reset

function M.isLive()
  return liveRenderer() ~= nil
end

function M.hasTags()
  return next(playerTags) ~= nil
end

function M.rebuild(tags, templateName)
  if type(tags) ~= "table" then return false end
  lastTags = deepcopy(tags)
  lastTemplateName = templateName
  local previousStates = playerTags
  destroy()
  local r = ensureTagRenderer()
  if not r then return false end
  local iconTemplate = templateName == "multiseat" -- only the multiseat marker carries an icon badge
  local stack = iconTemplate and TAG_STACK_ICON or TAG_STACK
  for _, t in ipairs(tags) do
    local iconNode = iconTemplate and tagIconNode(t.icon) or nil
    local rgb = colorOverrides[t.player] or t.color
    local resolved, canvasScale, anchorFraction = buildTagTemplate(t.label, rgb, templateName, iconNode)
    if resolved then
      local id = r:create(jsonEncode(resolved), false) -- static texture, rendered once
      if id and id ~= 0 then
        r:render(id, "{}")
        if t.hideInViews then r:setViewFilter(id, t.hideInViews, false) end -- blacklist these views
        local veh = getPlayerVehicle(t.player)
        local vehicleId = veh and veh:getID()
        local key = t.key or t.player
        local state = previousStates[key]
        if state then
          state.id = id
          state.player = t.player
          state.perspectivePlayer = t.perspectivePlayer
          state.canvasScale = canvasScale
          state.anchorFraction = anchorFraction
          state.stack = stack
          state.markerTime = state.markerTime or 0
          state.positionSmoother = state.positionSmoother or newTemporalSmoothingNonLinear(TAG_POSITION_SMOOTHING, TAG_POSITION_SMOOTHING)
          if state.vehicleId ~= vehicleId then
            state.vehicleId = vehicleId
            state.occupantCount = nil
          end
        else
          state = {
            id = id,
            player = t.player,
            perspectivePlayer = t.perspectivePlayer,
            canvasScale = canvasScale,
            anchorFraction = anchorFraction,
            stack = stack,
            vehicleId = vehicleId,
            markerTime = 0,
            occupantCount = nil,
            scaleSmoother = newTemporalSmoothingNonLinear(20, 20),
            positionSmoother = newTemporalSmoothingNonLinear(TAG_POSITION_SMOOTHING, TAG_POSITION_SMOOTHING),
          }
          state.scaleSmoother:set(0)
          state.positionSmoother:set(0)
        end
        playerTags[key] = state
      end
    end
  end
  return true
end

-- Reload source templates and SVG paths, then recreate the most recently requested tags.
function M.reload()
  tagDesigns = {}
  tagIconPaths = {}
  if not lastTags then return false end
  return M.rebuild(lastTags, lastTemplateName)
end

function M.setPlayerHidden(player, hidden)
  player = tonumber(player)
  if player == nil then return end
  hiddenPlayers[player] = hidden and true or nil
end

function M.clearHiddenPlayers()
  if not next(hiddenPlayers) then return end
  table.clear(hiddenPlayers)
end

function M.setPlayerColorOverride(player, color)
  player = tonumber(player)
  if player == nil then return end
  colorOverrides[player] = color
  if lastTags then M.rebuild(lastTags, lastTemplateName) end
end

function M.clearPlayerColorOverrides()
  if not next(colorOverrides) then return end
  table.clear(colorOverrides)
  if lastTags then M.rebuild(lastTags, lastTemplateName) end
end

function M.onVehicleSwitched(oldId, newId, player)
  for _, state in pairs(playerTags) do
    if state.player == player then
      state.vehicleId = newId
      state.occupantCount = nil
      if state.perspectivePlayer == player and newId then
        state.markerTime = TAG_SHOW_TIME
      else
        state.markerTime = 0
      end
    end
  end
end

local TAG_OFFSET = 0.1
local AXIS_EPSILON = 1e-6
local hiddenPosition = vec3()
local cameraPositionScratch = vec3()
local centerScratch = vec3()
local axis0Scratch = vec3()
local axis1Scratch = vec3()
local axis2Scratch = vec3()
local driverPositionScratch = vec3()
local referenceOffsetScratch = vec3()
local seatMarkerPositionScratch = vec3()
local updatePositionScratch = vec3()
local vehicleGroupsById = {}
local vehicleGroupPool = {}
local activeVehicleGroupCount = 0

local function isGamePaused()
  return simTimeAuthority and type(simTimeAuthority.getPause) == "function" and simTimeAuthority.getPause() == true
end

local function limitExitDistance(distance, localPosition, verticalAmount, halfExtent)
  if math.abs(verticalAmount) <= AXIS_EPSILON then return distance end
  local boundary = verticalAmount > 0 and halfExtent or -halfExtent
  local candidate = (boundary - localPosition) / verticalAmount
  if candidate >= 0 and candidate < distance then return candidate end
  return distance
end

local function projectMarkerAboveVehicle(veh, referencePosition, useLateralPosition, result)
  local vehicleId = veh:getID()
  if not be:getObjectOOBBIsInitialized(vehicleId) then return false end

  centerScratch:set(be:getObjectOOBBCenterXYZ(vehicleId))
  axis0Scratch:set(be:getObjectOOBBAxisNormalizedXYZ(vehicleId, 0))
  axis1Scratch:set(be:getObjectOOBBAxisNormalizedXYZ(vehicleId, 1))
  axis2Scratch:set(be:getObjectOOBBAxisNormalizedXYZ(vehicleId, 2))
  referenceOffsetScratch:set(referencePosition)
  referenceOffsetScratch:setSub(centerScratch)

  local lateralOffset = useLateralPosition and referenceOffsetScratch:dot(axis0Scratch) or 0
  local lengthOffset = referenceOffsetScratch:dot(axis1Scratch)
  local halfExtentX, halfExtentY, halfExtentZ = be:getObjectOOBBHalfExtentsXYZ(vehicleId)
  if math.abs(lateralOffset) > halfExtentX + AXIS_EPSILON or math.abs(lengthOffset) > halfExtentY + AXIS_EPSILON then
    return false
  end

  local exitDistance = math.huge
  exitDistance = limitExitDistance(exitDistance, lateralOffset, axis0Scratch.z, halfExtentX)
  exitDistance = limitExitDistance(exitDistance, lengthOffset, axis1Scratch.z, halfExtentY)
  exitDistance = limitExitDistance(exitDistance, 0, axis2Scratch.z, halfExtentZ)
  if exitDistance == math.huge then return false end

  result:setAddScaled(centerScratch, axis0Scratch, lateralOffset)
  result:setAddScaled(result, axis1Scratch, lengthOffset)
  result:setAddXYZ(0, 0, exitDistance + TAG_OFFSET)
  return true
end

local function markerPositionAboveVehicle(veh, result)
  if be:getObjectOOBBIsInitialized(veh:getID()) then
    centerScratch:set(be:getObjectOOBBCenterXYZ(veh:getID()))
    driverPositionScratch:set(centerScratch)
    local driverNode = core_camera and core_camera.getDriverData and core_camera.getDriverData(veh)
    if driverNode ~= nil then
      driverPositionScratch:set(veh:getPositionXYZ())
      driverPositionScratch:setAddXYZ(veh:getNodePositionXYZ(driverNode))
    end
    if projectMarkerAboveVehicle(veh, driverPositionScratch, false, result) then return end
  end
  result:set(veh:getPositionXYZ())
  result:setAddXYZ(0, 0, 1.25)
end

local function markerPositionAbovePlayerSeat(veh, seatPosition, result)
  return seatPosition ~= nil and projectMarkerAboveVehicle(veh, seatPosition, true, result)
end

local function getVehicleGroup(veh)
  local vehicleId = veh:getID()
  local group = vehicleGroupsById[vehicleId]
  if group then return group end

  activeVehicleGroupCount = activeVehicleGroupCount + 1
  group = vehicleGroupPool[activeVehicleGroupCount]
  if not group then
    group = {occupants = {}, states = {}, basePosition = vec3(), occupantLookup = {}, seatPositions = {}}
    vehicleGroupPool[activeVehicleGroupCount] = group
  end
  group.veh = veh
  group.count = 0
  group.stateCount = 0
  table.clear(group.occupantLookup)
  vehicleGroupsById[vehicleId] = group
  return group
end

local function updateSeatPositions(group)
  table.clear(group.seatPositions)
  local seatOccupants = extensions.gameplay_seatOccupants
  if not (seatOccupants and seatOccupants.getSeatExitData) then return end
  local vehicleId = group.veh:getID()
  for index = 1, group.count do
    local player = group.occupants[index]
    local _, seatPosition = seatOccupants.getSeatExitData(player, vehicleId)
    group.seatPositions[player] = seatPosition
  end
end

local function getPlayerIndex(players, player)
  for index, candidate in ipairs(players) do
    if candidate == player then return index end
  end
end

local function getTagStackOffset(group, state)
  local stack = state.stack
  local perspectivePlayer = state.perspectivePlayer
  local offset
  if not perspectivePlayer then
    local playerIndex = getPlayerIndex(group.occupants, state.player)
    offset = playerIndex and (group.count - playerIndex) * stack
  elseif not group.occupantLookup[perspectivePlayer] then
    local playerIndex = getPlayerIndex(group.occupants, state.player)
    offset = playerIndex and (group.count - playerIndex) * stack
  elseif group.count <= 1 then
    offset = nil
  elseif state.player == perspectivePlayer then
    offset = 0
  else
    local offsetIndex = 1
    for _, player in ipairs(group.occupants) do
      if player ~= perspectivePlayer then
        if player == state.player then
          offset = offsetIndex * stack
          break
        end
        offsetIndex = offsetIndex + 1
      end
    end
  end
  return offset
end

local function getTagDistance(state, position)
  if not core_camera then return 0 end
  local ctxId = state.perspectivePlayer and core_camera.getContextIdForPlayer(state.perspectivePlayer) or nil
  cameraPositionScratch:set(core_camera.getPositionXYZ(ctxId))
  return math.sqrt(cameraPositionScratch:squaredDistance(position))
end

local function getTagScale(distance)
  local scaleDistance = math.max(TAG_MIN_SCALE_DISTANCE, math.min(TAG_MAX_SCALE_DISTANCE, distance))
  return TAG_SCALE * scaleDistance / TAG_MIN_SCALE_DISTANCE
end

function M.updatePositions(dt)
  local r = liveRenderer()
  if not r then return end
  dt = math.max(0, dt or 0)
  if photoModeOpen then
    for _, state in pairs(playerTags) do
      state.scaleSmoother:set(0)
      r:update(state.id, hiddenPosition, 0, false)
    end
    return
  end
  local forceVisible = isGamePaused()
  table.clear(vehicleGroupsById)
  activeVehicleGroupCount = 0

  for _, state in pairs(playerTags) do
    local player = state.player
    local veh = not hiddenPlayers[player] and getPlayerVehicle(player)
    if veh then
      local vehicleId = veh:getID()
      if state.vehicleId ~= vehicleId then
        state.vehicleId = vehicleId
        if state.perspectivePlayer == player then state.markerTime = TAG_SHOW_TIME end
      end
      local group = getVehicleGroup(veh)
      group.stateCount = group.stateCount + 1
      group.states[group.stateCount] = state
      if not group.occupantLookup[player] then
        group.count = group.count + 1
        group.occupants[group.count] = player
        group.occupantLookup[player] = true
      end
    else
      state.vehicleId = nil
      state.markerTime = 0
      state.occupantCount = nil
      state.scaleSmoother:set(0)
      r:update(state.id, hiddenPosition, 0, false)
    end
  end

  for groupIndex = 1, activeVehicleGroupCount do
    local group = vehicleGroupPool[groupIndex]
    for index = #group.occupants, group.count + 1, -1 do group.occupants[index] = nil end
    for index = #group.states, group.stateCount + 1, -1 do group.states[index] = nil end
    table.sort(group.occupants)

    markerPositionAboveVehicle(group.veh, group.basePosition)
    updateSeatPositions(group)

    for stateIndex = 1, group.stateCount do
      local state = group.states[stateIndex]
      -- tags on the viewer's own vehicle only show for a moment whenever the occupancy changes
      local ownVehicle = state.perspectivePlayer ~= nil and group.occupantLookup[state.perspectivePlayer]
      if ownVehicle then
        if state.occupantCount ~= group.count then state.markerTime = TAG_SHOW_TIME end
        state.occupantCount = group.count
      else
        state.occupantCount = nil
      end
      local stackOffset = getTagStackOffset(group, state)
      local distance = getTagDistance(state, group.basePosition)
      local visibleScale = getTagScale(distance)
      local targetScale
      if distance > TAG_MAX_DISTANCE then
        targetScale = 0
      elseif forceVisible then
        targetScale = visibleScale
      elseif ownVehicle then
        targetScale = state.markerTime > 0 and visibleScale or 0
      else
        targetScale = visibleScale
      end
      local scale = state.scaleSmoother:get(targetScale * state.canvasScale, dt)
      updatePositionScratch:set(group.basePosition)
      if stackOffset then updatePositionScratch:setAddXYZ(0, 0, stackOffset * scale / (state.canvasScale * TAG_SCALE)) end
      local hasSeatPosition = markerPositionAbovePlayerSeat(group.veh, group.seatPositions[state.player], seatMarkerPositionScratch)
      local closeLayout = hasSeatPosition and distance < TAG_CLOSE_LAYOUT_DISTANCE
      local positionBlend = state.positionSmoother:get(closeLayout and 1 or 0, dt)
      if hasSeatPosition and positionBlend > 0 then
        updatePositionScratch:setLerp(updatePositionScratch, seatMarkerPositionScratch, positionBlend)
      end
      if state.anchorFraction > 0 then updatePositionScratch:setAddXYZ(0, 0, scale * state.anchorFraction) end
      r:update(state.id, updatePositionScratch, scale, scale > TAG_VISIBLE_SCALE)
      if state.markerTime > 0 then state.markerTime = math.max(0, state.markerTime - dt) end
    end
  end
end


return M
