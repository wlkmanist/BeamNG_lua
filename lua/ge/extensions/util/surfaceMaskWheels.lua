-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Usage: extensions.load("util_surfaceMaskWheels"); util_surfaceMaskWheels.setEnabled(true)

local M = {}

M.dependencies = { "ui_imgui" }
M.enabled = false

local im = ui_imgui

local wheelMaskEnabled = true -- master toggle: wheels flatten/mark grass into the surface mask (off = testing)
local maskInterval = 0.05
local maskWidth = 1.8
local mowerWidth = 3.2
local flattenStrength = 1
local markStrength = 0.75
local mowerMarkStrength = 1
local minMoveSq = 0.04
local maxMoveSq = 100
local pageWorldSize = 16
local debugMode = 0 -- 0 = off, 1 = basic (throttled console stats), 2 = full (imgui window + 3D pages)
local debugTileSize = 36
local debugPageRadius = 3
local debugMapBox = 400         -- map viewport size in px (C++ magnifies into it on wheel)
local debugFocusVehicle = false -- focus view: center on the vehicle + rotate the grid to heading
local statsPrintTimer = 0
local statsPrintInterval = 1.0
local mowingEnabled = false
local grassParticleType = 21
local grassParticleCount = 3

local timer = 0
-- per-vehicle state, keyed by vehicle id (never module-wide, so multiple vehicles
-- can be tracked): { offsets = {vec3...}, nodePairs = {{n1,n2}...}, prevPositions = {vec3...} }
local vehicles = {}
-- reusable scratch so the per-tick path allocates nothing (in-place vec3/quat ops)
local scratchVehPos = vec3()
local scratchDir = vec3()
local scratchUp = vec3()
local scratchRot = quat()
local scratchWheelPos = vec3()
-- debug page-outline scratch (mode 2 only, reused so the 3D overlay allocates nothing)
local dbgQuery = vec3()
local dbgCorner = { vec3(), vec3(), vec3(), vec3() }
local dbgLabelPos = vec3()
local dbgColors -- lazily built ColorF/ColorI (color libs may not exist at module load)
local perfSmoothing = 0.15
local performanceStats = {
  maskTicks = 0,
  lastLuaFrameMs = 0,
  avgLuaFrameMs = 0,
  lastLuaMaskMs = 0,
  avgLuaMaskMs = 0,
  lastWheelCount = 0,
  lastMovedWheels = 0,
  lastSkippedWheels = 0,
  lastMaskCalls = 0,
  lastParticleCalls = 0,
}

local function nowMs()
  return ((os.clockhp and os.clockhp()) or os.clock()) * 1000
end

local function smoothMs(current, value)
  if current <= 0 then return value end
  return current + (value - current) * perfSmoothing
end

local function getVehicleRotation(veh)
  return quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
end

local function rebuildWheelOffsets(veh, data)
  local offsets, nodePairs, prevPositions = {}, {}, {}
  data.offsets, data.nodePairs, data.prevPositions = offsets, nodePairs, prevPositions

  local wheelCount = veh:getWheelCount() - 1
  if wheelCount < 0 then return end

  local rot = getVehicleRotation(veh)
  local x, y, z = rot * vec3(1, 0, 0), rot * vec3(0, 1, 0), rot * vec3(0, 0, 1)

  for i = 0, wheelCount do
    local axisNodes = veh:getWheelAxisNodes(i)
    if axisNodes and axisNodes[1] then
      local nodePos = vec3(veh:getNodePosition(axisNodes[1]))
      offsets[#offsets + 1] = vec3(nodePos:dot(x), nodePos:dot(y), nodePos:dot(z))
      nodePairs[#nodePairs + 1] = { axisNodes[1], axisNodes[2] or axisNodes[1] }
    end
  end
end

local function getVehicleData(veh)
  local id = veh:getID()
  local data = vehicles[id]
  if not data then
    data = { offsets = {}, nodePairs = {}, prevPositions = {} }
    vehicles[id] = data
    rebuildWheelOffsets(veh, data)
  end
  return data
end

local function getPageCoord(pos)
  return math.floor(pos.x / pageWorldSize), math.floor(pos.y / pageWorldSize)
end

local function getTileDirectory()
  local level = (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) or "unknown"
  return "/temp/levels/" .. level .. "/dynamicTiles"
end

-- Point C++ tile storage at the current level. C++ flushes/closes any in-flight
-- IO for the previous level before repointing.
local function initStorage()
  if SurfaceMaskClipmap and getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    SurfaceMaskClipmap:init(getTileDirectory())
  end
end

local function terrainZ(x, y, fallbackZ)
  if core_terrain and core_terrain.getTerrainHeight then
    dbgQuery:set(x, y, fallbackZ or 0)
    return core_terrain.getTerrainHeight(dbgQuery) or fallbackZ or 0
  end
  return fallbackZ or 0
end

local function formatBytes(bytes)
  bytes = bytes or 0
  if bytes >= 1024 * 1024 then
    return string.format("%.2f MiB", bytes / (1024 * 1024))
  end
  if bytes >= 1024 then
    return string.format("%.1f KiB", bytes / 1024)
  end
  return string.format("%d B", bytes)
end

local function drawPageOutline(pageX, pageY, vehicleZ, color)
  local x0 = pageX * pageWorldSize
  local y0 = pageY * pageWorldSize
  local x1 = x0 + pageWorldSize
  local y1 = y0 + pageWorldSize
  local z = terrainZ((x0 + x1) * 0.5, (y0 + y1) * 0.5, vehicleZ) + 0.08

  local p0, p1, p2, p3 = dbgCorner[1], dbgCorner[2], dbgCorner[3], dbgCorner[4]
  p0:set(x0, y0, z)
  p1:set(x1, y0, z)
  p2:set(x1, y1, z)
  p3:set(x0, y1, z)

  debugDrawer:drawLineInstance(p0, p1, 3, color)
  debugDrawer:drawLineInstance(p1, p2, 3, color)
  debugDrawer:drawLineInstance(p2, p3, 3, color)
  debugDrawer:drawLineInstance(p3, p0, 3, color)
end

-- Throttled console line - the cheap "basic" readout. Runs at statsPrintInterval so
-- most frames do zero debug work, letting a profile show the near-production baseline.
local function printBasicStats(vehiclePos, dt)
  statsPrintTimer = statsPrintTimer + (dt or 0)
  if statsPrintTimer < statsPrintInterval then return end
  statsPrintTimer = 0

  local pageX, pageY = getPageCoord(vehiclePos)
  local s = SurfaceMaskClipmap and SurfaceMaskClipmap:getDebugState(pageX, pageY)
  local ps = performanceStats
  -- saved/loaded are the last batch sizes (persist until the next save/load), so they
  -- reveal whether eviction-saves fire; IO r/w and pending are live (near-0 at 1Hz).
  log('I', 'surfaceMask', string.format(
    "page %d,%d | lua %.3fms (mask %.3f) | wheels %d moved %d calls %d | GPU %.3fms/%dtex | saved %d loaded %d | disk avg r%.2f w%.2f ms | live r%d w%d pend %d",
    pageX, pageY, ps.avgLuaFrameMs, ps.avgLuaMaskMs, ps.lastWheelCount, ps.lastMovedWheels, ps.lastMaskCalls,
    s and s.dispatchSubmitMs or 0, s and s.dispatchedTexels or 0,
    s and s.savedPagesLast or 0, s and s.loadedPagesLast or 0,
    s and s.diskReadAvgMs or 0, s and s.diskWriteAvgMs or 0,
    s and s.ioReadsInFlight or 0, s and s.ioWritesInFlight or 0, s and s.pendingSaves or 0))
end

local function drawDebugPages(vehiclePos)
  if not dbgColors then
    dbgColors = {
      center = ColorF(1, 0.85, 0.1, 0.9),
      normal = ColorF(0.1, 0.7, 1, 0.55),
      text = ColorF(1, 1, 1, 1),
      textBg = ColorI(0, 0, 0, 192),
    }
  end

  local pageX, pageY = getPageCoord(vehiclePos)
  for y = pageY - debugPageRadius, pageY + debugPageRadius do
    for x = pageX - debugPageRadius, pageX + debugPageRadius do
      local isCenter = x == pageX and y == pageY
      drawPageOutline(x, y, vehiclePos.z, isCenter and dbgColors.center or dbgColors.normal)
    end
  end

  dbgLabelPos:set(vehiclePos.x, vehiclePos.y, vehiclePos.z + 2)
  debugDrawer:drawTextAdvanced(dbgLabelPos, String(string.format("surface mask page %d,%d", pageX, pageY)), dbgColors.text, true, false, dbgColors.textBg)
end

-- Preallocated ImGui vecs (constant ones + one reused scratch for the grid size), built
-- once so the window allocates nothing per frame. Lazy in case ui_imgui isn't ready yet.
local imVecs
local function getImVecs()
  if not imVecs then
    imVecs = {
      winSize = im.ImVec2(620, 560),
      winMin = im.ImVec2(420, 360),
      winMax = im.ImVec2(100000, 100000),
      legU = im.ImVec4(0.5, 0.5, 0.5, 1),
      legR = im.ImVec4(0.1, 0.7, 1, 1),
      legD = im.ImVec4(1, 0.5, 0.1, 1),
      legL = im.ImVec4(0.2, 1, 0.4, 1),
      legC = im.ImVec4(1, 1, 1, 1),
    }
  end
  return imVecs
end

local function drawDebugWindow(veh, vehiclePos, dt)
  if not im then return end
  local v = getImVecs()

  -- Constrain the size every frame so un-collapsing never restores to 0 height.
  im.SetNextWindowSizeConstraints(v.winMin, v.winMax)
  im.SetNextWindowSize(v.winSize, im.Cond_FirstUseEver)
  -- Always reserve the vertical scrollbar: the in-flight list grows/shrinks live, and
  -- without this the scrollbar toggling on/off changes the content width and reflows
  -- (flashes) the whole grid every frame.
  local open = im.Begin("SurfaceMask Pages", nil, im.WindowFlags_AlwaysVerticalScrollbar)
  if not open then
    -- Collapsed: skip the whole state query + grid, just print the cheap stats line.
    im.End()
    printBasicStats(vehiclePos, dt)
    return
  end

  local pageX, pageY = getPageCoord(vehiclePos)
  local state = SurfaceMaskClipmap and SurfaceMaskClipmap:getDebugState(pageX, pageY)
  if not state then
    im.End()
    return
  end

  -- Fixed field widths + monospace font so values keep a constant width and text after
  -- them does not jump around every frame as magnitudes change.
  local fontPushed = im.PushFont3("robotomono_regular")
  -- Short lines (values are last/avg where two are shown) so nothing overflows the window.
  im.Text(string.format("page %5d,%5d   origin %5d,%5d   %dx%d", pageX, pageY, state.originPageX, state.originPageY, state.residentPages, state.residentPages))
  im.Text(string.format("pending  masks %3d  loads %3d", state.pendingMasks or 0, state.pendingLoads or 0))
  im.Text(string.format("lua ms   frame %6.3f/%6.3f  mask %6.3f/%6.3f", performanceStats.lastLuaFrameMs, performanceStats.avgLuaFrameMs, performanceStats.lastLuaMaskMs, performanceStats.avgLuaMaskMs))
  im.Text(string.format("wheels %2d  moved %2d skip %2d  calls %2d part %2d", performanceStats.lastWheelCount, performanceStats.lastMovedWheels, performanceStats.lastSkippedWheels, performanceStats.lastMaskCalls, performanceStats.lastParticleCalls))
  im.Text(string.format("gpu ms   tex %6.3f  instr %6.3f (%s)", state.textureUploadMs or 0, state.instructionUploadMs or 0, formatBytes(state.uploadedInstructionBytes)))
  im.Text(string.format("gpu ms   dispatch %6.3f  texels %6d", state.dispatchSubmitMs or 0, state.dispatchedTexels or 0))
  im.Text(string.format("load ms  disk %6.3f/%6.3f  gpu %6.3f/%6.3f  %2dp", state.diskReadLastMs or 0, state.diskReadAvgMs or 0, state.gpuUploadLastMs or 0, state.gpuUploadAvgMs or 0, state.loadedPagesLast or 0))
  im.Text(string.format("save ms  gpu %6.3f/%6.3f  disk %6.3f/%6.3f  %2dp", state.gpuExtractLastMs or 0, state.gpuExtractAvgMs or 0, state.diskWriteLastMs or 0, state.diskWriteAvgMs or 0, state.savedPagesLast or 0))
  im.Text(string.format("io flight  r %2d  w %2d  readback %2d", state.ioReadsInFlight or 0, state.ioWritesInFlight or 0, state.pendingSaves or 0))
  if fontPushed then im.PopFont() end
  im.Separator()

  -- Visual-only tile-count presets (does not touch the clipmap, only the overlay).
  im.Text("View:")
  im.SameLine()
  if im.SmallButton("1x1") then debugPageRadius = 0 end
  im.SameLine()
  if im.SmallButton("3x3") then debugPageRadius = 1 end
  im.SameLine()
  if im.SmallButton("5x5") then debugPageRadius = 2 end
  im.SameLine()
  if im.SmallButton("7x7") then debugPageRadius = 3 end
  im.SameLine()
  if im.SmallButton("11x11") then debugPageRadius = 5 end
  im.SameLine()
  -- Focus view: recenter on the vehicle and rotate the grid so heading points up.
  if im.SmallButton(debugFocusVehicle and "Focus:ON" or "Focus:OFF") then debugFocusVehicle = not debugFocusVehicle end
  im.Separator()

  -- Focus view needs the exact fractional page position + heading; a zero direction tells
  -- C++ this is the plain north-up view.
  local fx, fy, dx, dy = 0.5, 0.5, 0, 0
  if debugFocusVehicle then
    fx = vehiclePos.x / pageWorldSize - pageX
    fy = vehiclePos.y / pageWorldSize - pageY
    local dxr, dyr = veh:getDirectionVectorXYZ()
    local len = math.sqrt(dxr * dxr + dyr * dyr)
    if len > 1e-4 then dx, dy = dxr / len, dyr / len else dx, dy = 0, 1 end
  end
  -- Self-contained C++ map control: fits + draws the grid and magnifies on mouse wheel (all
  -- the ImGui child/scroll/wheel plumbing lives in C++). Tile count stays as set by the presets.
  SurfaceMaskClipmap:imGuiDrawPageMap(pageX, pageY, debugPageRadius, debugMapBox, fx, fy, dx, dy)

  -- Legend for the single-letter state codes, color-matched to the tile borders.
  im.TextColored(v.legU, "u=unloaded")
  im.SameLine()
  im.TextColored(v.legR, "r=resident")
  im.SameLine()
  im.TextColored(v.legD, "d=dirty")
  im.SameLine()
  im.TextColored(v.legL, "l=loading")
  im.SameLine()
  im.TextColored(v.legC, "c=clearing")
  im.Separator()
  -- Drawn in C++ (iterates the pending-save list straight into ImGui) so the live,
  -- variable-length list produces no per-frame Lua garbage.
  SurfaceMaskClipmap:imGuiDrawInflightSaves()

  im.End()
  return true -- window open and fully drawn; caller also draws the 3D page outlines
end

local function emitGrassClippings(veh, wheelIndex, nodePairs)
  if not mowingEnabled then return false end
  local nodes = nodePairs[wheelIndex]
  if not nodes then return false end
  veh:queueLuaCommand(string.format("obj:addParticleByNodesRelative(%d, %d, 0, %d, 0.3, %d)", nodes[1], nodes[2], grassParticleType, grassParticleCount))
  return true
end

local function maskWheels(veh, data)
  local surfaceMaskClipmap = SurfaceMaskClipmap
  if not surfaceMaskClipmap then return end
  local offsets = data.offsets
  if #offsets == 0 then
    rebuildWheelOffsets(veh, data)
    offsets = data.offsets
  end
  local wheelCount = #offsets
  if wheelCount == 0 then return end
  local prevPositions = data.prevPositions
  local nodePairs = data.nodePairs

  local maskStart = nowMs()
  scratchVehPos:set(veh:getPositionXYZ())
  scratchDir:set(veh:getDirectionVectorXYZ())
  scratchUp:set(veh:getDirectionVectorUpXYZ())
  scratchRot:setFromDir(scratchDir, scratchUp)
  -- C++ owns tile lifetime: recentering saves evicted painted tiles and streams entering ones.
  surfaceMaskClipmap:setCenter(scratchVehPos.x, scratchVehPos.y)
  local activeMaskWidth = mowingEnabled and mowerWidth or maskWidth
  local activeMarkStrength = mowingEnabled and mowerMarkStrength or markStrength
  local maskCalls, particleCalls, movedWheels, skippedWheels = 0, 0, 0, 0

  for i = 1, wheelCount do
    scratchWheelPos:setRotate(scratchRot, offsets[i]) -- rot * offset via pooled temps, no GC
    scratchWheelPos:setAdd(scratchVehPos)
    local px, py, pz = scratchWheelPos.x, scratchWheelPos.y, scratchWheelPos.z
    local prev = prevPositions[i]

    if not prev then
      if wheelMaskEnabled then surfaceMaskClipmap:maskCircleWorld(px, py, activeMaskWidth * 0.5, flattenStrength, activeMarkStrength) end
      maskCalls = maskCalls + 1
      if emitGrassClippings(veh, i, nodePairs) then particleCalls = particleCalls + 1 end
      prevPositions[i] = vec3(px, py, pz) -- one-time alloc per wheel on first contact
      movedWheels = movedWheels + 1
    else
      local dx = px - prev.x
      local dy = py - prev.y
      local dz = pz - prev.z
      local moveSq = dx * dx + dy * dy + dz * dz
      if moveSq > maxMoveSq then
        prev:set(px, py, pz)
        skippedWheels = skippedWheels + 1
      elseif moveSq > minMoveSq then
        if wheelMaskEnabled then surfaceMaskClipmap:maskLineWorld(prev.x, prev.y, px, py, activeMaskWidth, flattenStrength, activeMarkStrength) end
        maskCalls = maskCalls + 1
        if emitGrassClippings(veh, i, nodePairs) then particleCalls = particleCalls + 1 end
        movedWheels = movedWheels + 1
        prev:set(px, py, pz)
      else
        skippedWheels = skippedWheels + 1
      end
    end
  end

  local luaMaskMs = nowMs() - maskStart
  performanceStats.maskTicks = performanceStats.maskTicks + 1
  performanceStats.lastLuaMaskMs = luaMaskMs
  performanceStats.avgLuaMaskMs = smoothMs(performanceStats.avgLuaMaskMs, luaMaskMs)
  performanceStats.lastWheelCount = wheelCount
  performanceStats.lastMovedWheels = movedWheels
  performanceStats.lastSkippedWheels = skippedWheels
  performanceStats.lastMaskCalls = maskCalls
  performanceStats.lastParticleCalls = particleCalls
end

function M.onPreRender(dtReal, dtSim)
  if not M.enabled then return end

  local frameStart = nowMs()
  local veh = be and be:getPlayerVehicle(0)
  if not veh then return end -- per-vehicle data persists (cleaned on destroy), nothing to wipe

  local dt = dtSim or dtReal or 0
  timer = timer + dt
  if timer >= maskInterval then
    timer = timer % maskInterval
    -- Currently only the player vehicle; the per-vehicle store is ready for a loop
    -- over all vehicles once the clipmap can center on more than one.
    maskWheels(veh, getVehicleData(veh))
  end

  if debugMode >= 1 then
    scratchVehPos:set(veh:getPositionXYZ())  -- current pos for debug, no alloc (maskWheels may not have run)
    if debugMode == 1 then
      printBasicStats(scratchVehPos, dt)     -- basic: cheap throttled console line, no imgui/3D work
    elseif drawDebugWindow(veh, scratchVehPos, dt) then
      drawDebugPages(scratchVehPos)          -- full & window open: also draw 3D page outlines
    end                                      -- collapsed window skips pages + prints the basic line
  end

  local luaFrameMs = nowMs() - frameStart
  performanceStats.lastLuaFrameMs = luaFrameMs
  performanceStats.avgLuaFrameMs = smoothMs(performanceStats.avgLuaFrameMs, luaFrameMs)
end

function M.onExtensionLoaded()
  M.setEnabled(true)
  M.setDebugMode(0)
  initStorage()
end

function M.onClientStartMission()
  initStorage()
end

function M.onVehicleDestroyed(vehId)
  vehicles[vehId] = nil -- drop per-vehicle state so it never leaks or goes stale
end

function M.onVehicleResetted(vehId)
  vehicles[vehId] = nil -- rebuild offsets and reset wheel history after a reset/part change
end

function M.setEnabled(enabled)
  M.enabled = enabled and true or false
  timer = 0
end

function M.toggle()
  M.setEnabled(not M.enabled)
end

function M.clear()
  if SurfaceMaskClipmap then SurfaceMaskClipmap:clear() end
end

-- Surface-mask service used by other extensions (e.g. util_lawnMower): the clipmap lifetime
-- (storage, centering, clear) is owned here, so consumers stamp/center through these instead of
-- poking the SurfaceMaskClipmap global directly. isReady lets a consumer cheaply skip its work.
function M.isReady()
  return SurfaceMaskClipmap ~= nil
end

function M.setCenter(x, y)
  if SurfaceMaskClipmap then SurfaceMaskClipmap:setCenter(x, y) end
end

function M.maskCircleWorld(x, y, radius, flatten, mark)
  if SurfaceMaskClipmap then SurfaceMaskClipmap:maskCircleWorld(x, y, radius, flatten, mark) end
end

function M.maskLineWorld(x1, y1, x2, y2, width, flatten, mark)
  if SurfaceMaskClipmap then SurfaceMaskClipmap:maskLineWorld(x1, y1, x2, y2, width, flatten, mark) end
end

function M.onSerialize()
  return {
    enabled = M.enabled,
    maskInterval = maskInterval,
    maskWidth = maskWidth,
    mowerWidth = mowerWidth,
    flattenStrength = flattenStrength,
    markStrength = markStrength,
    mowerMarkStrength = mowerMarkStrength,
    minMoveSq = minMoveSq,
    maxMoveSq = maxMoveSq,
    pageWorldSize = pageWorldSize,
    debugMode = debugMode,
    debugTileSize = debugTileSize,
    debugPageRadius = debugPageRadius,
    mowingEnabled = mowingEnabled,
    grassParticleType = grassParticleType,
    grassParticleCount = grassParticleCount,
  }
end

function M.onDeserialized(data)
  if not data then return end
  M.enabled = data.enabled and true or false
  maskInterval = data.maskInterval or maskInterval
  maskWidth = data.maskWidth or maskWidth
  mowerWidth = data.mowerWidth or mowerWidth
  flattenStrength = data.flattenStrength or flattenStrength
  markStrength = data.markStrength or markStrength
  mowerMarkStrength = data.mowerMarkStrength or mowerMarkStrength
  minMoveSq = data.minMoveSq or minMoveSq
  maxMoveSq = data.maxMoveSq or maxMoveSq
  pageWorldSize = data.pageWorldSize or pageWorldSize
  debugMode = data.debugMode or 0
  debugTileSize = math.min(data.debugTileSize or debugTileSize, 36)
  debugPageRadius = data.debugPageRadius or debugPageRadius
  mowingEnabled = data.mowingEnabled and true or false
  grassParticleType = data.grassParticleType or grassParticleType
  grassParticleCount = data.grassParticleCount or grassParticleCount
end

function M.getPerformanceStats()
  return {
    maskTicks = performanceStats.maskTicks,
    lastLuaFrameMs = performanceStats.lastLuaFrameMs,
    avgLuaFrameMs = performanceStats.avgLuaFrameMs,
    lastLuaMaskMs = performanceStats.lastLuaMaskMs,
    avgLuaMaskMs = performanceStats.avgLuaMaskMs,
    lastWheelCount = performanceStats.lastWheelCount,
    lastMovedWheels = performanceStats.lastMovedWheels,
    lastSkippedWheels = performanceStats.lastSkippedWheels,
    lastMaskCalls = performanceStats.lastMaskCalls,
    lastParticleCalls = performanceStats.lastParticleCalls,
  }
end

function M.setDebugMode(mode)
  debugMode = math.max(0, math.min(2, math.floor(mode or 0)))
  statsPrintTimer = statsPrintInterval -- print the first basic line immediately
  -- Tell C++ to only collect perf stats while a debug mode is active.
  if SurfaceMaskClipmap then SurfaceMaskClipmap:setDebugEnabled(debugMode > 0) end
end

function M.setDebug(enabled) -- back-compat: on = full
  M.setDebugMode(enabled and 2 or 0)
end

function M.cycleDebug()
  M.setDebugMode((debugMode + 1) % 3)
end

function M.setMowingEnabled(enabled)
  mowingEnabled = enabled and true or false
end

function M.toggleMowing()
  M.setMowingEnabled(not mowingEnabled)
end

function M.setMowerWidth(width)
  mowerWidth = width or mowerWidth
end

function M.setDebugPageRadius(radius)
  debugPageRadius = math.max(0, math.floor(radius or debugPageRadius)) -- 0 = current tile only
end

return M
