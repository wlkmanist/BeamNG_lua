-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- World editor for the Recast navmesh, modelled on the River editor: one edit
-- mode, a compact toolbar, viewport interaction, properties in the Inspector, and
-- a left "Overview" window (2D tile grid + shapes in the current tile). A target
-- toggle picks what you edit:
--   Tiles   - click to select, lock to protect from rebuilds
--   Outline - coverage polygon (river-style nodes, gizmo move, Alt+click add)
--   Areas   - convex volumes tagged with an area kind (exclude/ground/road/...)
--   Links   - off-mesh connections (jump/drop/climb/teleport), two clicks to place
-- Everything is undoable. Drives the engine navmeshEditor* API.

local M = {}

local editModeName = "Navigation Mesh"
local overviewWindowName = "navMeshOverview"
local tileViewWindowName = "navMeshTileView"
local im = ui_imgui

local NODE_PICK = 2.0
local LINK_PICK = 2.0
local DRAW_RANGE = 250
local Z_OFFSET = 0.3
local OVERVIEW_R = 4

local CONFIG_FIELDS = {
  {"cs", "Cell size", false}, {"ch", "Cell height", false},
  {"walkableSlopeAngle", "Walkable slope", false},
  {"walkableHeight", "Agent height (vox)", true},
  {"walkableClimb", "Agent climb (vox)", true},
  {"walkableRadius", "Agent radius (vox)", true},
  {"tileSize", "Tile size (vox)", true},
  {"maxEdgeLen", "Max edge len", true},
  {"maxSimplificationError", "Max simpl. err", false},
  {"minRegionArea", "Min region area", true},
  {"mergeRegionArea", "Merge region area", true},
  {"detailSampleDist", "Detail sample dist", false},
  {"detailSampleMaxError", "Detail max err", false},
  {"maxPolysPerTile", "Max polys/tile", true},
}

local LINK_FLAGS = { walk = 1, swim = 2, jump = 4, ledge = 8, drop = 16, climb = 32, teleport = 64 }
local LINK_TYPES = { "jump", "drop", "climb", "teleport" }
local AREA_KINDS = { [0] = "Exclude", [1] = "Ground", [2] = "Road", [3] = "Sidewalk", [4] = "Water" }
local AREA_ORDER = { 0, 1, 2, 3, 4 }
local PARTITION_NAMES = { "Watershed (best quality)", "Monotone (fast)", "Layers" }

-- Plain-language help shown for the active tool, aimed at first-time users.
local TARGET_HELP = {
  tiles = "TILES - the navmesh is built as a grid of square tiles. Click a tile to select it, then tick 'Locked' to protect it so a rebuild never changes it.",
  outline = "OUTLINE - draw the area AI is allowed in. Alt+click to drop points, drag a point to move it, right-click to remove one. On Build, navmesh outside the outline is removed. No outline = whole map.",
  areas = "AREAS - mark special ground. Pick a Kind above (Road costs more to walk, Water = swim, Exclude = no navmesh), then Alt+click to draw the region.",
  links = "LINKS - connect spots AI cannot walk between (a jump or a drop). Click the start point, then the end point. Select a link to change its type or delete it.",
  test = "TEST - check AI can get from A to B. Click a start point, then an end point; the route and its length are drawn. Right-click clears.",
  crowd = "CROWD - test live AI agents. Click to drop an agent, right-click to set where they all walk to. They avoid each other and obstacles as they move.",
}

local target = 'tiles'       -- 'tiles' | 'outline' | 'areas' | 'links'
local polygons = {}          -- outline: { { {x,y,z}, ... }, ... }
local areaVolumes = {}       -- areas:   { { kind=int, poly={ {x,y,z}, ... } }, ... }
local activePoly = nil       -- outline polygon new points append to
local activeArea = nil       -- area volume new points append to
local loadedThisSession = false
local state = { tiles = {}, info = {}, links = {} }
local selKind = nil          -- 'tile' | 'node' | 'link' | nil
local selectedXY = nil       -- selected tile
local selNode = nil          -- { set='outline'|'area', p, v }
local selectedLink = nil     -- link idx
local hoveredTileId = nil
local hoveredNode = nil
local hoveredLink = nil
local linkFrom = nil         -- pending link start point while placing
local linkType = 'jump'
local linkBidir = true
local areaKind = 1
local testFrom = nil         -- pathfind test start/end + result
local testTo = nil
local testPath = nil
local testLen = 0
local crowdInited = false    -- live crowd (agent test) active
local showAdvanced = false   -- collapse advanced build properties by default
local nodeTransform = MatrixF(true)
local gizmoBefore = nil
local posEditBefore = nil
local shapesCache = {}
local shapesCacheKey = nil
local tilePolysCache = {}
local tilePolysKey = nil
local viewCols = nil
local _v1 = im.ImVec2(0, 0)
local _v2 = im.ImVec2(0, 0)
local waterItems, linkItems, areaItems = nil, nil, nil

local function getWaterItems()
  if not waterItems then waterItems = im.ArrayCharPtrByTbl({ "Ignore", "Solid", "Impassable" }) end
  return waterItems
end
local function getLinkItems()
  if not linkItems then linkItems = im.ArrayCharPtrByTbl(LINK_TYPES) end
  return linkItems
end
local function getAreaItems()
  if not areaItems then
    local t = {}
    for _, k in ipairs(AREA_ORDER) do t[#t + 1] = AREA_KINDS[k] end
    areaItems = im.ArrayCharPtrByTbl(t)
  end
  return areaItems
end
local partitionItems = nil
local function getPartitionItems()
  if not partitionItems then partitionItems = im.ArrayCharPtrByTbl(PARTITION_NAMES) end
  return partitionItems
end

local function levelDir()
  return (editor.getLevelPath and editor.getLevelPath()) or editor.levelPath or ""
end
local function binPath() return levelDir() .. "art/navmesh/navmesh.bin" end
local function jsonPath() return levelDir() .. "art/navmesh/navmesh.json" end

-- The engine navmesh bindings only exist in a rebuilt binary; C++ does not
-- hot-reload. Guard every entry point so a stale build shows a message instead
-- of throwing each frame.
local function apiReady() return type(navmeshEditorGetState) == 'function' end
local API_MSG = "NavMesh engine API not found. Rebuild the game (C++) and restart it, then reopen this tool."

local function terrainZ(x, y)
  if core_terrain and core_terrain.getTerrain and core_terrain.getTerrain() then
    return core_terrain.getTerrainHeight(vec3(x, y, 0))
  end
  return nil
end

local function refreshTiles()
  state.tiles = navmeshEditorGetTiles() or {}
  for _, t in ipairs(state.tiles) do
    local fb = t.min.z
    t.corners = {
      vec3(t.min.x, t.min.y, (terrainZ(t.min.x, t.min.y) or fb) + Z_OFFSET),
      vec3(t.max.x, t.min.y, (terrainZ(t.max.x, t.min.y) or fb) + Z_OFFSET),
      vec3(t.max.x, t.max.y, (terrainZ(t.max.x, t.max.y) or fb) + Z_OFFSET),
      vec3(t.min.x, t.max.y, (terrainZ(t.min.x, t.max.y) or fb) + Z_OFFSET),
    }
    t.cx = (t.min.x + t.max.x) * 0.5
    t.cy = (t.min.y + t.max.y) * 0.5
  end
  shapesCacheKey = nil
  tilePolysKey = nil
end

local function tileAt(x, y)
  for id, t in ipairs(state.tiles) do
    if x >= t.min.x and x <= t.max.x and y >= t.min.y and y <= t.max.y then return t, id end
  end
  return nil, nil
end

local function selectedTileRecord()
  if not selectedXY then return nil end
  for _, t in ipairs(state.tiles) do
    if t.x == selectedXY.x and t.y == selectedXY.y then return t end
  end
  return nil
end

-- polygon a selected node lives in (outline or an area volume)
local function nodePoly(sel)
  if not sel then return nil end
  if sel.set == 'area' then local av = areaVolumes[sel.p]; return av and av.poly end
  return polygons[sel.p]
end

local function nearestNodeIn(polysOrAreas, isArea, x, y)
  local best, bestD = nil, NODE_PICK * NODE_PICK
  for pi, item in ipairs(polysOrAreas) do
    local poly = isArea and item.poly or item
    for vi, p in ipairs(poly) do
      local dx, dy = p.x - x, p.y - y
      local d = dx * dx + dy * dy
      if d < bestD then bestD = d; best = { set = isArea and 'area' or 'outline', p = pi, v = vi } end
    end
  end
  return best
end

local function nearestLink(x, y)
  local best, bestD = nil, LINK_PICK * LINK_PICK
  for _, l in ipairs(state.links) do
    for _, e in ipairs({ l.from, l.to }) do
      local dx, dy = e.x - x, e.y - y
      local d = dx * dx + dy * dy
      if d < bestD then bestD = d; best = l.idx end
    end
  end
  return best
end

local function pointInOutline(x, y)
  local inside = false
  for _, poly in ipairs(polygons) do
    local n = #poly
    if n >= 3 then
      local j = n
      for i = 1, n do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then inside = not inside end
        j = i
      end
    end
  end
  return inside
end

local function pushBoundaries() navmeshEditorSetBoundaries(polygons) end
local function pushAreas()
  local out = {}
  for _, av in ipairs(areaVolumes) do
    if #av.poly >= 3 then
      local minz, maxz = math.huge, -math.huge
      for _, p in ipairs(av.poly) do minz = math.min(minz, p.z); maxz = math.max(maxz, p.z) end
      out[#out + 1] = { kind = av.kind, minY = minz - 1, maxY = maxz + 3, poly = av.poly }
    end
  end
  navmeshEditorSetAreaVolumes(out)
end

-- Undo/redo (outline + areas + locks + config as one idempotent snapshot; links
-- are snapshotted separately since they live in the engine) --------------------
local function captureState()
  return {
    boundaries = deepcopy(polygons),
    areas = deepcopy(areaVolumes),
    locked = navmeshEditorGetLockedTiles() or {},
    config = navmeshEditorGetConfig(),
  }
end

local function clearSel() selKind = nil; selNode = nil; selectedXY = nil; selectedLink = nil end

local function applyState(s)
  polygons = deepcopy(s.boundaries or {})
  areaVolumes = deepcopy(s.areas or {})
  activePoly = nil; activeArea = nil
  pushBoundaries(); pushAreas()
  if s.config then for k, v in pairs(s.config) do navmeshEditorSetConfig(k, v) end end
  navmeshEditorLockAll(false)
  for _, t in ipairs(s.locked or {}) do navmeshEditorSetTileLocked(t.x, t.y, true) end
  clearSel()
  refreshTiles()
end

local function commit(name, before)
  local after = captureState()
  editor.history:commitAction(name, { before = before, after = after },
    function(a) applyState(a.before) end, function(a) applyState(a.after) end, true)
end

local function captureLinks() return navmeshEditorGetLinks() or {} end
local function applyLinks(list)
  navmeshEditorClearLinks()
  for _, l in ipairs(list) do
    navmeshEditorAddLink(l.from.x, l.from.y, l.from.z, l.to.x, l.to.y, l.to.z, l.flags, l.bidir)
  end
  state.links = captureLinks()
end
local function commitLinks(name, before)
  local after = captureLinks()
  editor.history:commitAction(name, { before = before, after = after },
    function(a) applyLinks(a.before) end, function(a) applyLinks(a.after) end, true)
end

-- Selection ------------------------------------------------------------------
local function ensureNavSelection()
  editor.clearObjectSelection()
  if not editor.selection then editor.selection = {} end
  editor.selection.navMesh = { 1 }
end

local function updateGizmoPos()
  local poly = nodePoly(selNode)
  if selKind == 'node' and poly and poly[selNode.v] then
    local p = poly[selNode.v]
    nodeTransform:setPosition(vec3(p.x, p.y, p.z))
    editor.setAxisGizmoTransform(nodeTransform)
  end
end

local function selectNode(n)
  selKind = 'node'; selNode = n; selectedXY = nil; selectedLink = nil
  ensureNavSelection()
  editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate)
  updateGizmoPos()
end

local function selectTile(t)
  selKind = 'tile'; selectedXY = { x = t.x, y = t.y }; selNode = nil; selectedLink = nil
  ensureNavSelection()
end

local function selectLink(idx)
  selKind = 'link'; selectedLink = idx; selNode = nil; selectedXY = nil
  ensureNavSelection()
end

local function deleteNode(n)
  local poly = nodePoly(n)
  if not poly then return end
  local before = captureState()
  table.remove(poly, n.v)
  if #poly == 0 then
    if n.set == 'area' then table.remove(areaVolumes, n.p); activeArea = nil
    else table.remove(polygons, n.p); activePoly = nil end
  end
  clearSel()
  pushBoundaries(); pushAreas()
  commit("Delete node", before)
end

-- Gizmo ----------------------------------------------------------------------
local function gizmoBeginDrag() gizmoBefore = captureState() end
local function gizmoDragging()
  local poly = nodePoly(selNode)
  if selKind == 'node' and poly and poly[selNode.v] then
    local gp = editor.getAxisGizmoTransform():getColumn(3)
    poly[selNode.v] = { x = gp.x, y = gp.y, z = gp.z }
  end
end
local function gizmoEndDrag()
  pushBoundaries(); pushAreas()
  if gizmoBefore then commit("Move node", gizmoBefore); gizmoBefore = nil end
  updateGizmoPos()
end

-- Build / IO -----------------------------------------------------------------
local function doBuild()
  navmeshEditorEnsure(binPath())
  pushBoundaries(); pushAreas()
  navmeshEditorBuild()
  refreshTiles()
  state.links = captureLinks()
end

local function saveToLevel()
  if not apiReady() then return end
  local info = navmeshEditorGetState()
  if not info.hasMesh then return end
  pushBoundaries(); pushAreas()
  navmeshEditorSave()
  jsonWriteFile(jsonPath(), {
    boundaries = polygons, areaVolumes = areaVolumes,
    lockedTiles = navmeshEditorGetLockedTiles() or {},
    links = captureLinks(), config = navmeshEditorGetConfig(),
  }, true)
end

local function loadFromLevel()
  navmeshEditorEnsure(binPath())
  local data = jsonReadFile(jsonPath())
  polygons = (data and data.boundaries) or {}
  areaVolumes = (data and data.areaVolumes) or {}
  activePoly = nil; activeArea = nil
  if data and data.config then for k, v in pairs(data.config) do navmeshEditorSetConfig(k, v) end end
  pushBoundaries(); pushAreas()
  navmeshEditorLoad(binPath())
  if data and data.lockedTiles then
    for _, t in ipairs(data.lockedTiles) do navmeshEditorSetTileLocked(t.x, t.y, true) end
  end
  if data and data.links then applyLinks(data.links) end
  refreshTiles()
  state.links = captureLinks()
end

local function lockInsideOutline()
  local before = captureState()
  for _, t in ipairs(state.tiles) do
    if pointInOutline(t.cx, t.cy) then navmeshEditorSetTileLocked(t.x, t.y, true) end
  end
  refreshTiles()
  commit("Lock tiles inside outline", before)
end

local function lockAll(v)
  local before = captureState()
  navmeshEditorLockAll(v)
  refreshTiles()
  commit(v and "Lock all tiles" or "Unlock all tiles", before)
end

-- Drawing --------------------------------------------------------------------
local COL = {
  grid = ColorF(0.5, 0.5, 0.55, 0.35), lock = ColorF(1, 0.45, 0.1, 0.8),
  hover = ColorF(0.3, 0.8, 1, 1), sel = ColorF(0.2, 1, 0.35, 1),
  outline = ColorF(0.2, 1, 0.35, 1), node = ColorF(1, 1, 0.2, 1),
  link = ColorF(0.9, 0.4, 1, 1),
}
local AREA_COL = {
  [0] = ColorF(1, 0.25, 0.25, 1), [1] = ColorF(0.3, 0.6, 1, 1), [2] = ColorF(1, 0.6, 0.1, 1),
  [3] = ColorF(1, 0.9, 0.2, 1), [4] = ColorF(0.2, 0.9, 1, 1),
}

local function drawTileQuad(t, col)
  local c = t.corners
  if not c then return end
  debugDrawer:drawLine(c[1], c[2], col); debugDrawer:drawLine(c[2], c[3], col)
  debugDrawer:drawLine(c[3], c[4], col); debugDrawer:drawLine(c[4], c[1], col)
end

local function drawPoly(poly, set, pidx, lineCol)
  local n = #poly
  for i = 1, n do
    local p = poly[i]
    local isSel = selKind == 'node' and selNode and selNode.set == set and selNode.p == pidx and selNode.v == i
    local isHov = hoveredNode and hoveredNode.set == set and hoveredNode.p == pidx and hoveredNode.v == i
    local col = isSel and COL.sel or (isHov and COL.hover or COL.node)
    debugDrawer:drawSphere(vec3(p.x, p.y, p.z), 0.6, col, false)
    if n >= 2 then
      local q = poly[(i % n) + 1]
      debugDrawer:drawLine(vec3(p.x, p.y, p.z), vec3(q.x, q.y, q.z), lineCol)
    end
  end
end

local function drawOverlays()
  local camPos = core_camera and core_camera.getPosition and core_camera.getPosition()
  for id, t in ipairs(state.tiles) do
    if not camPos or (math.abs(t.cx - camPos.x) < DRAW_RANGE and math.abs(t.cy - camPos.y) < DRAW_RANGE) then
      local isSel = selKind == 'tile' and selectedXY and t.x == selectedXY.x and t.y == selectedXY.y
      if isSel then drawTileQuad(t, COL.sel)
      elseif target == 'tiles' and id == hoveredTileId then drawTileQuad(t, COL.hover)
      elseif t.locked then drawTileQuad(t, COL.lock)
      else drawTileQuad(t, COL.grid) end
    end
  end
  for pi, poly in ipairs(polygons) do drawPoly(poly, 'outline', pi, COL.outline) end
  for ai, av in ipairs(areaVolumes) do drawPoly(av.poly, 'area', ai, AREA_COL[av.kind] or COL.outline) end
  for _, l in ipairs(state.links) do
    local a, b = vec3(l.from.x, l.from.y, l.from.z), vec3(l.to.x, l.to.y, l.to.z)
    local col = (selectedLink == l.idx) and COL.sel or (hoveredLink == l.idx and COL.hover or COL.link)
    debugDrawer:drawLine(a, b, col)
    debugDrawer:drawSphere(a, 0.5, col, false)
    debugDrawer:drawSphere(b, 0.5, col, false)
  end
  if linkFrom then debugDrawer:drawSphere(vec3(linkFrom.x, linkFrom.y, linkFrom.z), 0.6, COL.sel, false) end
  if target == 'test' then
    if testFrom then debugDrawer:drawSphere(vec3(testFrom.x, testFrom.y, testFrom.z), 0.7, ColorF(0.2, 1, 0.35, 1), false) end
    if testTo then debugDrawer:drawSphere(vec3(testTo.x, testTo.y, testTo.z), 0.7, ColorF(1, 0.3, 0.3, 1), false) end
    if testPath and #testPath >= 2 then
      for i = 1, #testPath - 1 do
        local a, b = testPath[i], testPath[i + 1]
        debugDrawer:drawLine(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z), ColorF(0.2, 1, 0.5, 1))
      end
    end
  end
  if target == 'crowd' then
    for _, a in ipairs(navmeshEditorCrowdGetAgents() or {}) do
      debugDrawer:drawSphere(vec3(a.x, a.y, a.z + 0.9), 0.35, ColorF(1, 0.8, 0.2, 1), false)
    end
  end
end

-- Viewport interaction -------------------------------------------------------
local function editNodes(wx, wy, wz, set)
  local isArea = (set == 'area')
  hoveredNode = nearestNodeIn(isArea and areaVolumes or polygons, isArea, wx, wy)
  if im.IsMouseClicked(0) and not editor.isAxisGizmoHovered() then
    if editor.keyModifiers.alt then
      local before = captureState()
      if isArea then
        if not activeArea then areaVolumes[#areaVolumes + 1] = { kind = areaKind, poly = {} }; activeArea = #areaVolumes end
        local poly = areaVolumes[activeArea].poly
        poly[#poly + 1] = { x = wx, y = wy, z = wz }
        pushAreas()
        selectNode({ set = 'area', p = activeArea, v = #poly })
      else
        if not activePoly then polygons[#polygons + 1] = {}; activePoly = #polygons end
        local poly = polygons[activePoly]
        poly[#poly + 1] = { x = wx, y = wy, z = wz }
        pushBoundaries()
        selectNode({ set = 'outline', p = activePoly, v = #poly })
      end
      commit("Add node", before)
    elseif hoveredNode then
      selectNode(hoveredNode)
    else
      clearSel()
    end
  end
  if im.IsMouseClicked(1) then deleteNode(nearestNodeIn(isArea and areaVolumes or polygons, isArea, wx, wy)) end
end

local function onUpdate()
  if not apiReady() then return end
  state.info = navmeshEditorGetState()
  state.links = captureLinks()
  drawOverlays()

  if selKind == 'node' then
    editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoDragging)
    editor.drawAxisGizmo()
  end

  hoveredTileId = nil; hoveredNode = nil; hoveredLink = nil
  if im.GetIO().WantCaptureMouse then return end
  if editor.isViewportHovered and not editor.isViewportHovered() then return end

  local hit = cameraMouseRayCast(false, nil, 4000)
  if not hit or not hit.pos then return end
  local wx, wy, wz = hit.pos.x, hit.pos.y, hit.pos.z

  if target == 'outline' then
    editNodes(wx, wy, wz, 'outline')
  elseif target == 'areas' then
    editNodes(wx, wy, wz, 'area')
  elseif target == 'links' then
    hoveredLink = nearestLink(wx, wy)
    if im.IsMouseClicked(0) then
      if linkFrom then
        local before = captureLinks()
        navmeshEditorAddLink(linkFrom.x, linkFrom.y, linkFrom.z, wx, wy, wz, LINK_FLAGS[linkType], linkBidir)
        linkFrom = nil
        state.links = captureLinks()
        commitLinks("Add link", before)
      elseif hoveredLink then
        selectLink(hoveredLink)
      else
        linkFrom = { x = wx, y = wy, z = wz }
      end
    end
    if im.IsMouseClicked(1) then
      if linkFrom then linkFrom = nil
      elseif selectedLink then
        local before = captureLinks()
        navmeshEditorDeleteLink(selectedLink)
        selectedLink = nil
        state.links = captureLinks()
        commitLinks("Delete link", before)
      end
    end
  elseif target == 'test' then
    if im.IsMouseClicked(0) then
      if not testFrom or testTo then
        testFrom = { x = wx, y = wy, z = wz }; testTo = nil; testPath = nil; testLen = 0
      else
        testTo = { x = wx, y = wy, z = wz }
        local res = navmeshEditorFindPath(testFrom.x, testFrom.y, testFrom.z, testTo.x, testTo.y, testTo.z)
        if res and res.ok then testPath = res.points; testLen = res.length or 0 else testPath = nil; testLen = 0 end
      end
    end
    if im.IsMouseClicked(1) then testFrom = nil; testTo = nil; testPath = nil; testLen = 0 end
  elseif target == 'crowd' then
    if not crowdInited then crowdInited = navmeshEditorCrowdInit() end
    if im.IsMouseClicked(0) then navmeshEditorCrowdAdd(wx, wy, wz) end
    if im.IsMouseClicked(1) then navmeshEditorCrowdTarget(wx, wy, wz) end
  else
    local t, id = tileAt(wx, wy)
    hoveredTileId = id
    if t and im.IsMouseClicked(0) then selectTile(t) end
  end
end

-- Toolbar --------------------------------------------------------------------
local function targetBtn(name, label)
  if im.Button(target == name and ("[ " .. label .. " ]") or label) then target = name; clearSel(); linkFrom = nil end
  im.SameLine()
end

local function onToolbar()
  if not apiReady() then im.TextUnformatted(API_MSG) return end
  targetBtn('tiles', "Tiles"); targetBtn('outline', "Outline"); targetBtn('areas', "Areas"); targetBtn('links', "Links"); targetBtn('test', "Test"); targetBtn('crowd', "Crowd")
  im.TextUnformatted("|") im.SameLine()
  if im.Button("Build") then doBuild() end im.SameLine()
  if im.Button("Save") then saveToLevel() end im.SameLine()
  if im.Button("Reload") then loadFromLevel() end im.SameLine()
  if im.Button("Clear all") then navmeshEditorClear(); clearSel(); refreshTiles() end im.SameLine()
  im.TextUnformatted("|") im.SameLine()

  if target == 'tiles' then
    if im.Button("Lock all") then lockAll(true) end im.SameLine()
    if im.Button("Unlock all") then lockAll(false) end im.SameLine()
    if im.Button("Lock inside outline") then lockInsideOutline() end im.SameLine()
  elseif target == 'links' then
    im.TextUnformatted("Type") im.SameLine()
    im.PushItemWidth(90)
    local tIdx = im.IntPtr(0)
    for i, n in ipairs(LINK_TYPES) do if n == linkType then tIdx[0] = i - 1 end end
    if im.Combo1("##ltype", tIdx, getLinkItems()) then linkType = LINK_TYPES[tIdx[0] + 1] end
    im.PopItemWidth() im.SameLine()
    local bd = im.BoolPtr(linkBidir)
    if im.Checkbox("Bidir", bd) then linkBidir = bd[0] end im.SameLine()
  elseif target == 'areas' then
    im.TextUnformatted("Kind") im.SameLine()
    im.PushItemWidth(110)
    local kIdx = im.IntPtr(0)
    for i, k in ipairs(AREA_ORDER) do if k == areaKind then kIdx[0] = i - 1 end end
    if im.Combo1("##akind", kIdx, getAreaItems()) then areaKind = AREA_ORDER[kIdx[0] + 1] end
    im.PopItemWidth() im.SameLine()
    im.TextUnformatted("(Alt+click adds points)") im.SameLine()
  elseif target == 'test' then
    if testPath then im.TextUnformatted(string.format("Path length: %.1f m", testLen))
    else im.TextUnformatted("Click a start point, then an end point") end
    im.SameLine()
    if im.Button("Clear") then testFrom = nil; testTo = nil; testPath = nil; testLen = 0 end im.SameLine()
  elseif target == 'crowd' then
    if im.Button("Re-init") then crowdInited = navmeshEditorCrowdInit() end im.SameLine()
    if im.Button("Clear agents") then navmeshEditorCrowdClear() end im.SameLine()
    im.TextUnformatted("Click = add agent, right-click = set target") im.SameLine()
  else
    im.TextUnformatted("(Alt+click adds points)") im.SameLine()
  end

  im.TextUnformatted("|") im.SameLine()
  local info = state.info or {}
  im.TextUnformatted(string.format("Tiles %d  Locked %d  Outline %d  Areas %d  Links %d",
    info.tileCount or 0, info.lockedCount or 0, #polygons, #areaVolumes, #state.links))
  if info.building then im.SameLine() im.TextColored(im.ImVec4(1, 0.7, 0.2, 1), "Building...") end
end

-- Inspector ------------------------------------------------------------------
-- The handful of settings a non-expert usually touches; the rest are "advanced".
local BASIC = { cs = true, walkableRadius = true, walkableHeight = true, walkableSlopeAngle = true }

local function fieldGui(cfg, key, label, isInt)
  local ee = im.BoolPtr(false)
  if isInt then
    local p = im.IntPtr(math.floor((cfg[key] or 0) + 0.5))
    editor.uiInputInt(label, p, 1, 10, nil, ee)
    if ee[0] then local before = captureState(); navmeshEditorSetConfig(key, p[0]); commit("Set " .. label, before) end
  else
    local p = im.FloatPtr(cfg[key] or 0)
    editor.uiInputFloat(label, p, 0.05, 0.5, "%.3f", nil, ee)
    if ee[0] then local before = captureState(); navmeshEditorSetConfig(key, p[0]); commit("Set " .. label, before) end
  end
end

local function configGui()
  im.Text("Build settings")
  local cfg = navmeshEditorGetConfig()
  local waterPtr = im.IntPtr(cfg.water or 0)
  if im.Combo1("Water", waterPtr, getWaterItems()) then
    local before = captureState(); navmeshEditorSetConfig("water", waterPtr[0]); commit("Set water", before)
  end
  for _, f in ipairs(CONFIG_FIELDS) do if BASIC[f[1]] then fieldGui(cfg, f[1], f[2], f[3]) end end
  local advPtr = im.BoolPtr(showAdvanced)
  if im.Checkbox("Show advanced settings", advPtr) then showAdvanced = advPtr[0] end
  if showAdvanced then
    local partPtr = im.IntPtr(cfg.partition or 0)
    if im.Combo1("Partitioning", partPtr, getPartitionItems()) then
      local before = captureState(); navmeshEditorSetConfig("partition", partPtr[0]); commit("Set partitioning", before)
    end
    for _, f in ipairs(CONFIG_FIELDS) do if not BASIC[f[1]] then fieldGui(cfg, f[1], f[2], f[3]) end end
  end
end

local function nodeInspector()
  local poly = nodePoly(selNode)
  if not (poly and poly[selNode.v]) then return end
  im.Text(selNode.set == 'area' and "Area node" or "Outline node")
  local p = poly[selNode.v]
  local arr = im.ArrayFloat(3); arr[0] = p.x; arr[1] = p.y; arr[2] = p.z
  local ee = im.BoolPtr(false)
  if editor.uiDragFloat3("Position", arr, 0.2, -1000000000, 1000000000, "%.2f", 1, ee) then
    if not posEditBefore then posEditBefore = captureState() end
    poly[selNode.v] = { x = arr[0], y = arr[1], z = arr[2] }
    pushBoundaries(); pushAreas(); updateGizmoPos()
  end
  if ee[0] and posEditBefore then commit("Move node", posEditBefore); posEditBefore = nil end
  if selNode.set == 'area' then
    local av = areaVolumes[selNode.p]
    if av then
      local kIdx = im.IntPtr(0)
      for i, k in ipairs(AREA_ORDER) do if k == av.kind then kIdx[0] = i - 1 end end
      if im.Combo1("Area kind", kIdx, getAreaItems()) then
        local before = captureState(); av.kind = AREA_ORDER[kIdx[0] + 1]; pushAreas(); commit("Set area kind", before)
      end
    end
  end
  if im.Button("Delete node") then deleteNode(selNode) end
  im.Separator()
end

local function linkInspector()
  local link
  for _, l in ipairs(state.links) do if l.idx == selectedLink then link = l end end
  if not link then return end
  im.Text("Off-mesh link #" .. selectedLink)
  local tIdx = im.IntPtr(0)
  local cur = link.jump and "jump" or link.drop and "drop" or link.climb and "climb" or link.teleport and "teleport" or "jump"
  for i, n in ipairs(LINK_TYPES) do if n == cur then tIdx[0] = i - 1 end end
  local changed = false
  if im.Combo1("Type", tIdx, getLinkItems()) then cur = LINK_TYPES[tIdx[0] + 1]; changed = true end
  local bd = im.BoolPtr(link.bidir)
  if im.Checkbox("Bidirectional", bd) then changed = true end
  if changed then
    local before = captureLinks()
    navmeshEditorSetLink(selectedLink, LINK_FLAGS[cur], bd[0])
    state.links = captureLinks()
    commitLinks("Edit link", before)
  end
  if im.Button("Delete link") then
    local before = captureLinks()
    navmeshEditorDeleteLink(selectedLink); selectedLink = nil
    state.links = captureLinks()
    commitLinks("Delete link", before)
  end
  im.Separator()
end

local function navMeshInspectorGui(inspectorInfo)
  if not apiReady() then im.TextWrapped(API_MSG) return end
  im.TextWrapped(TARGET_HELP[target] or "")
  im.Separator()
  local info = navmeshEditorGetState()
  if not info.hasMesh then
    im.TextWrapped("No navmesh yet. Click Build in the toolbar to generate one over the whole map, then refine it.")
    return
  end
  if selKind == 'node' then nodeInspector()
  elseif selKind == 'link' then linkInspector()
  elseif selKind == 'tile' then
    local t = selectedTileRecord()
    if t then
      im.Text(string.format("Tile (%d, %d)", t.x, t.y))
      local lp = im.BoolPtr(t.locked and true or false)
      if im.Checkbox("Locked (skipped on build)", lp) then
        local before = captureState(); navmeshEditorSetTileLocked(t.x, t.y, lp[0]); refreshTiles(); commit(lp[0] and "Lock tile" or "Unlock tile", before)
      end
      if im.Button("Rebuild this tile") then navmeshEditorBuildTile(t.x, t.y, false); refreshTiles() end
      im.SameLine()
      if im.Button("Rebuild 3x3") then navmeshEditorBuildTile(t.x, t.y, true); refreshTiles() end
      im.Separator()
    end
  end
  configGui()
  im.Separator()
  im.TextWrapped("Build settings apply on the next Build.")
end

-- Overview window ------------------------------------------------------------
local function currentTile()
  if selKind == 'tile' and selectedXY then return selectedTileRecord() end
  local info = state.info or {}
  if info.cameraTile and info.cameraTile >= 0 then return state.tiles[info.cameraTile + 1] end
  return nil
end
local function tileLookup()
  local m = {}
  for _, t in ipairs(state.tiles) do m[t.x .. "_" .. t.y] = t end
  return m
end
local function shapesFor(t)
  local key = t.x .. "_" .. t.y
  if key ~= shapesCacheKey then shapesCache = navmeshEditorGetTileShapes(t.x, t.y) or {}; shapesCacheKey = key end
  return shapesCache
end

local function drawOverviewWindow()
  if not editor.beginWindow(overviewWindowName, "NavMesh Overview") then editor.endWindow() return end
  im.TextWrapped("Build a navmesh, then refine it: Outline limits where AI can walk, Areas mark special ground, Links add jumps/drops, Test checks a route. Click a tile below to inspect it.")
  im.Separator()
  local cur = currentTile()
  if not cur then
    im.TextWrapped("No current tile. Select a tile, or aim the camera at the navmesh.")
    editor.endWindow() return
  end
  im.Text(string.format("Current tile: (%d, %d)", cur.x, cur.y))
  im.TextColored(im.ImVec4(0.6, 0.6, 0.65, 1), "green current / orange locked / blue built / grey empty")
  local look = tileLookup()
  local sz = im.ImVec2(22, 22)
  for dy = -OVERVIEW_R, OVERVIEW_R do
    for dx = -OVERVIEW_R, OVERVIEW_R do
      if dx > -OVERVIEW_R then im.SameLine() end
      local tx, ty = cur.x + dx, cur.y + dy
      local t = look[tx .. "_" .. ty]
      local col
      if t and t.x == cur.x and t.y == cur.y then col = im.ImVec4(0.2, 1, 0.35, 1)
      elseif not t then col = im.ImVec4(0.12, 0.12, 0.12, 1)
      elseif t.locked then col = im.ImVec4(1, 0.5, 0.15, 1)
      elseif t.built then col = im.ImVec4(0.25, 0.55, 0.9, 1)
      else col = im.ImVec4(0.35, 0.35, 0.4, 1) end
      im.PushID1(tx .. "_" .. ty)
      im.PushStyleColor2(im.Col_Button, col)
      if im.Button("##c", sz) and t then selectTile(t) end
      im.PopStyleColor()
      im.PopID()
    end
  end
  im.Separator()
  local shapes = shapesFor(cur)
  im.Text(string.format("Shapes in tile: %d", #shapes))
  im.BeginChild1("navShapes", im.ImVec2(0, 220), true)
  for _, s in ipairs(shapes) do
    local label = (s.name ~= "" and s.name or ("#" .. s.id)) .. "  [" .. s.class .. "]"
    if im.Selectable1(label, false) then
      if editor.selection then editor.selection.navMesh = nil end
      clearSel(); editor.selectObjectById(s.id)
    end
  end
  im.EndChild()
  editor.endWindow()
end

-- Big orthographic top-down view of the current tile: navmesh polygons (by area),
-- shape footprints (AABB), plus outline / area / link overlays.
local function initViewCols()
  if viewCols then return end
  local function c(r, g, b, a) return im.GetColorU322(im.ImVec4(r, g, b, a)) end
  viewCols = {
    bg = c(0.08, 0.08, 0.09, 1), shape = c(0.82, 0.82, 0.88, 0.9),
    outline = c(0.2, 1, 0.35, 1), link = c(0.9, 0.4, 1, 1), tile = c(1, 1, 1, 0.55),
    areaFill = { [0] = c(0.3, 0.6, 1, 0.5), [1] = c(0.2, 0.9, 1, 0.5), [3] = c(1, 0.6, 0.1, 0.5), [4] = c(1, 0.9, 0.2, 0.5) },
    areaEdge = { [0] = c(1, 0.25, 0.25, 1), [1] = c(0.3, 0.6, 1, 1), [2] = c(1, 0.6, 0.1, 1), [3] = c(1, 0.9, 0.2, 1), [4] = c(0.2, 0.9, 1, 1) },
  }
end

local function polysFor(t)
  local key = t.x .. "_" .. t.y
  if key ~= tilePolysKey then tilePolysCache = navmeshEditorGetTilePolys(t.x, t.y) or {}; tilePolysKey = key end
  return tilePolysCache
end

local function drawScreenRect(dl, x1, y1, x2, y2, col, thick)
  _v1.x = x1; _v1.y = y1; _v2.x = x2; _v2.y = y1; im.ImDrawList_AddLine(dl, _v1, _v2, col, thick)
  _v1.x = x2; _v1.y = y1; _v2.x = x2; _v2.y = y2; im.ImDrawList_AddLine(dl, _v1, _v2, col, thick)
  _v1.x = x2; _v1.y = y2; _v2.x = x1; _v2.y = y2; im.ImDrawList_AddLine(dl, _v1, _v2, col, thick)
  _v1.x = x1; _v1.y = y2; _v2.x = x1; _v2.y = y1; im.ImDrawList_AddLine(dl, _v1, _v2, col, thick)
end

local function drawWorldPolyEdges(dl, poly, w2sx, w2sy, col)
  local n = #poly
  for i = 1, n do
    if n >= 2 then
      local a = poly[i]; local b = poly[(i % n) + 1]
      _v1.x = w2sx(a.x); _v1.y = w2sy(a.y); _v2.x = w2sx(b.x); _v2.y = w2sy(b.y)
      im.ImDrawList_AddLine(dl, _v1, _v2, col, 2)
    end
  end
end

local function drawTileView()
  if not editor.beginWindow(tileViewWindowName, "NavMesh Tile View") then editor.endWindow() return end
  initViewCols()
  local cur = currentTile()
  if not cur then
    im.TextWrapped("No current tile. Select a tile, or aim the camera at the navmesh.")
    editor.endWindow() return
  end
  im.Text(string.format("Tile (%d, %d) - top-down (north up)", cur.x, cur.y))
  im.TextColored(im.ImVec4(0.6, 0.6, 0.65, 1), "filled = walkable (blue ground / orange road / yellow sidewalk / cyan water) | white boxes = shapes | green = outline")

  local avail = im.GetContentRegionAvail()
  local w = math.max(64, avail.x)
  local h = math.max(64, avail.y - 2)
  local origin = im.GetCursorScreenPos()
  local ox, oy = origin.x, origin.y
  im.InvisibleButton("##tileview", im.ImVec2(w, h))
  local dl = im.GetWindowDrawList()
  _v1.x = ox; _v1.y = oy; _v2.x = ox + w; _v2.y = oy + h
  im.ImDrawList_AddRectFilled(dl, _v1, _v2, viewCols.bg)
  im.ImDrawList_PushClipRect(dl, im.ImVec2(ox, oy), im.ImVec2(ox + w, oy + h), true)

  local minX, minY, maxX, maxY = cur.min.x, cur.min.y, cur.max.x, cur.max.y
  local spanX = math.max(0.001, maxX - minX)
  local spanY = math.max(0.001, maxY - minY)
  local scale = math.min(w / spanX, h / spanY) * 0.92
  local padX = (w - spanX * scale) * 0.5
  local padY = (h - spanY * scale) * 0.5
  local function w2sx(wx) return ox + padX + (wx - minX) * scale end
  local function w2sy(wy) return oy + h - padY - (wy - minY) * scale end

  for _, poly in ipairs(polysFor(cur)) do
    if #poly.verts >= 3 then
      im.ImDrawList_PathClear(dl)
      for _, v in ipairs(poly.verts) do
        _v1.x = w2sx(v.x); _v1.y = w2sy(v.y)
        im.ImDrawList_PathLineTo(dl, _v1)
      end
      im.ImDrawList_PathFillConvex(dl, viewCols.areaFill[poly.area] or viewCols.areaFill[0])
    end
  end
  for _, s in ipairs(shapesFor(cur)) do
    if s.boxMin and s.boxMax then
      drawScreenRect(dl, w2sx(s.boxMin.x), w2sy(s.boxMin.y), w2sx(s.boxMax.x), w2sy(s.boxMax.y), viewCols.shape, 1)
    end
  end
  for _, poly in ipairs(polygons) do drawWorldPolyEdges(dl, poly, w2sx, w2sy, viewCols.outline) end
  for _, av in ipairs(areaVolumes) do drawWorldPolyEdges(dl, av.poly, w2sx, w2sy, viewCols.areaEdge[av.kind] or viewCols.outline) end
  for _, l in ipairs(state.links) do
    _v1.x = w2sx(l.from.x); _v1.y = w2sy(l.from.y); _v2.x = w2sx(l.to.x); _v2.y = w2sy(l.to.y)
    im.ImDrawList_AddLine(dl, _v1, _v2, viewCols.link, 2)
  end
  drawScreenRect(dl, w2sx(minX), w2sy(minY), w2sx(maxX), w2sy(maxY), viewCols.tile, 1)
  im.ImDrawList_PopClipRect(dl)
  editor.endWindow()
end

local function onEditorGui()
  if editor.editMode ~= editor.editModes.navMeshEditMode then return end
  if not apiReady() then
    if editor.beginWindow(overviewWindowName, "NavMesh Overview") then im.TextWrapped(API_MSG) end
    editor.endWindow()
    return
  end
  drawOverviewWindow()
  drawTileView()
end

-- Lifecycle ------------------------------------------------------------------
local function onDeleteSelection()
  if selKind == 'node' then deleteNode(selNode)
  elseif selKind == 'link' and selectedLink then
    local before = captureLinks(); navmeshEditorDeleteLink(selectedLink); selectedLink = nil
    state.links = captureLinks(); commitLinks("Delete link", before)
  end
end

local function show() editor.selectEditMode(editor.editModes.navMeshEditMode) end

local function onActivate()
  editor.showWindow(overviewWindowName)
  editor.showWindow(tileViewWindowName)
  if not apiReady() then return end
  navmeshEditorSetVisible(true)
  ensureNavSelection()
  if not loadedThisSession then loadFromLevel(); loadedThisSession = true end
  refreshTiles()
  state.links = captureLinks()
end

local function onDeactivate()
  editor.hideWindow(overviewWindowName)
  editor.hideWindow(tileViewWindowName)
  if editor.selection then editor.selection.navMesh = nil end
  clearSel(); linkFrom = nil
  if apiReady() then navmeshEditorSetVisible(false); navmeshEditorCrowdShutdown() end
  crowdInited = false
end

local function onEditorInitialized()
  editor.registerWindow(overviewWindowName, im.ImVec2(320, 520), im.ImVec2(20, 140))
  editor.registerWindow(tileViewWindowName, im.ImVec2(600, 600))
  editor.registerInspectorTypeHandler("navMesh", navMeshInspectorGui)
  editor.editModes.navMeshEditMode =
  {
    displayName = editModeName,
    onUpdate = onUpdate,
    onToolbar = onToolbar,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    onDeleteSelection = onDeleteSelection,
    auxShortcuts = {},
    hideObjectIcons = true,
  }
  editor.editModes.navMeshEditMode.auxShortcuts[editor.AuxControl_LMB] = "Select / place"
  editor.editModes.navMeshEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Alt)] = "Add node"
  editor.editModes.navMeshEditMode.auxShortcuts[editor.AuxControl_RMB] = "Delete node / link"
  editor.addWindowMenuItem("Navigation Mesh", show, {groupMenuName="Gameplay"})
end

local function onEditorAfterSaveLevel() saveToLevel() end
local function onEditorAfterOpenLevel()
  loadedThisSession = false
  polygons = {}; areaVolumes = {}; activePoly = nil; activeArea = nil
  clearSel(); linkFrom = nil
  state.tiles = {}; state.links = {}; shapesCacheKey = nil
end

M.allowGizmo = function() return editor.editMode and editor.editMode.displayName == editModeName or false end
M.show = show
M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onEditorAfterSaveLevel = onEditorAfterSaveLevel
M.onEditorAfterOpenLevel = onEditorAfterOpenLevel

return M
