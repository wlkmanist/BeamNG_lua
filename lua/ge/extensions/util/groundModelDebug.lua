-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"ui_imguiUtils"}
local logTag = 'groundmodel_debug'

local im = ui_imgui

local windowOpen = im.BoolPtr(false)
local minWindowSize = im.ImVec2(0, 0)
local maxWindowSize = im.ImVec2(math.huge, math.huge)
local spawnFrames = 0 -- min size is only enforced for the first frames, long enough to outlast imgui's initial auto-fit

local groundModels = {}
local altTheme = im.BoolPtr(false)
local listAll = im.BoolPtr(false)
local allVisible = im.IntPtr(0) -- CheckboxFlags value: 0 none, 1 mixed, 3 all
local seen = {} -- groundmodels that had tris since the window was closed or static was unticked
local grayText = im.ImVec4(0.5, 0.5, 0.5, 1)
local iconAtlasInfo, iconAtlasTex -- editor icon atlas, loaded on demand so it works without the world editor
local iconP1, iconP2, iconUv1, iconUv2 = im.ImVec2(0, 0), im.ImVec2(0, 0), im.ImVec2(0, 0), im.ImVec2(0, 0)
local sectionFlags = bit.bor(im.TreeNodeFlags_DefaultOpen, im.TreeNodeFlags_NoTreePushOnOpen)
local groundDebug = im.BoolPtr(false)
local staticDebug = im.BoolPtr(false)
local staticColPosShrink = im.FloatPtr(0)
local debugtype = -1

-- Collision density related variables
local colDensityEnabled = im.BoolPtr(false)
local colDensityShowText = im.BoolPtr(true)
local colDensityThreshold = im.FloatPtr(25)
local colDensityTileCount = im.IntPtr(100)
local colDensityTileSize = im.FloatPtr(5)

local depthDebug = im.BoolPtr(false)
local mouseFocus = im.BoolPtr(true)
local distance = im.FloatPtr(20)
local tileSize = im.FloatPtr(1)
local depthScale = im.FloatPtr(1)
local active = {}

local groundModelPath = "/art/groundmodels.json"
local settingsPath = "settings/editor/groundModelDebug_settings.json"

local gms
local envGroundModels

local collisiontype = im.IntPtr(0)

local function serializeSettings()
  local tbl = {}
  tbl.colors = {}
  tbl.options = {}

  for name, gm in pairs(groundModels) do
    tbl.colors[name] = {}
    table.insert( tbl.colors[name], gm.color[0])
    table.insert( tbl.colors[name], gm.color[1])
    table.insert( tbl.colors[name], gm.color[2])
  end
  tbl.options.mouseFocus = mouseFocus[0]
  tbl.options.distance = distance[0]
  tbl.options.tileSize = tileSize[0]
  tbl.options.depthScale = depthScale[0]
  tbl.options.colDensityThreshold = colDensityThreshold[0]
  tbl.options.colDensityTileCount = colDensityTileCount[0]
  tbl.options.colDensityTileSize = colDensityTileSize[0]
  tbl.options.colDensityShowText = colDensityShowText[0]
  tbl.options.altTheme = altTheme[0]
  tbl.options.listAll = listAll[0]
  tbl.options.staticColPosShrink = staticColPosShrink[0]
  jsonWriteFile(settingsPath, tbl, true)
end

local function deserializeSettings()
  local tbl = jsonReadFile(settingsPath)
  if tbl then
    for name, color in pairs(tbl.colors or {}) do
      if groundModels[name] then
        groundModels[name].color = im.ArrayFloatByTbl(color)
      end
    end
    if tbl.options then
      mouseFocus[0] = tbl.options.mouseFocus
      distance[0] = tbl.options.distance
      tileSize[0] = tbl.options.tileSize
      depthScale[0] = tbl.options.depthScale
      colDensityThreshold[0] = tbl.options.colDensityThreshold or 0
      colDensityTileCount[0] = tbl.options.colDensityTileCount or 50
      colDensityTileSize[0] = tbl.options.colDensityTileSize or 5
      colDensityShowText[0] = tbl.options.colDensityShowText ~= false
      altTheme[0] = tbl.options.altTheme == true
      listAll[0] = tbl.options.listAll == true
      staticColPosShrink[0] = tbl.options.staticColPosShrink or 0
      Engine.setStaticColDebugPosShrink(staticColPosShrink[0])
    end
  end
end

local function themeColor(count, i)
  if altTheme[0] then
    local r, g, b = HSVtoRGB(indexedBlueNoise(i), 1, 1)
    return {r, g, b, 1}
  end
  return rainbowColor(count, i, 1)
end

local function applyTheme()
  for i, k in ipairs(gms) do
    groundModels[k].color = im.ArrayFloatByTbl(themeColor(#gms, i))
  end
end

local function setup()
  envGroundModels = core_environment.groundModels -- core_environment replaces this table whenever it reloads groundmodels (e.g. on level load)
  table.clear(groundModels)
  table.clear(seen)
  local i = 1
  local groundModelSize = tableSize(core_environment.groundModels)

  gms = tableKeys(core_environment.groundModels)
  table.sort(gms)

  for _, k in ipairs(gms) do
    local v = core_environment.groundModels[k]
    groundModels[k] = {data = v.cdata, isAlias = v.isAlias, parent = v.parent, aliases = {}, active = im.BoolPtr(true), color = im.ArrayFloatByTbl(themeColor(groundModelSize, i))}
    groundModels[k].cdata = {}
    groundModels[k].cdata.collisiontype = im.IntPtr(v.cdata.collisiontype)
    groundModels[k].cdata.defaultDepth = im.FloatPtr(v.cdata.defaultDepth)
    groundModels[k].cdata.dragAnisotropy = im.FloatPtr(v.cdata.dragAnisotropy)
    groundModels[k].cdata.flowBehaviorIndex = im.FloatPtr(v.cdata.flowBehaviorIndex)
    groundModels[k].cdata.flowConsistencyIndex = im.FloatPtr(v.cdata.flowConsistencyIndex)
    groundModels[k].cdata.fluidDensity = im.FloatPtr(v.cdata.fluidDensity)
    groundModels[k].cdata.hydrodynamicFriction = im.FloatPtr(v.cdata.hydrodynamicFriction)
    --groundModels[k].cdata.name = "Test"
    groundModels[k].cdata.roughnessCoefficient = im.FloatPtr(v.cdata.roughnessCoefficient)
    groundModels[k].cdata.shearStrength = im.FloatPtr(v.cdata.shearStrength)
    groundModels[k].cdata.skidMarks = im.BoolPtr(v.cdata.skidMarks)
    groundModels[k].cdata.slidingFrictionCoefficient = im.FloatPtr(v.cdata.slidingFrictionCoefficient)
    groundModels[k].cdata.staticFrictionCoefficient = im.FloatPtr(v.cdata.staticFrictionCoefficient)
    groundModels[k].cdata.strength = im.FloatPtr(v.cdata.strength)
    groundModels[k].cdata.stribeckVelocity = im.FloatPtr(v.cdata.stribeckVelocity)

    i = i + 1
    -- dump(groundModels[k].data:as_table())
  end

  -- if it's an alias add it to the parents aliases table
  for _, k in ipairs(gms) do
    if groundModels[k].isAlias == true then
      table.insert(groundModels[groundModels[k].parent].aliases, k)
    end
  end

  deserializeSettings()
end

local function setValue(name, gm, type, val)
  gm.data[type] = val
  be:setGroundModel(name, gm.data)
  if #groundModels[name].aliases > 0 then
    for _,alias in pairs(groundModels[name].aliases) do
      be:setGroundModel(alias, gm.data)
    end
  end
end

local function saveGroundmodels()
  local materials = require("particles").getMaterialsParticlesTable()
  local data = {}
  for k,v in pairs(groundModels) do
    if not v.isAlias then
      data[k] = {}
      for propertyName, propertyVal in pairs(v.cdata) do
        data[k][propertyName] = propertyVal[0]
      end
      local material = materials[data[k].collisiontype]
      data[k].collisiontype = material and material.name or nil
      if #v.aliases > 0 then data[k].aliases = v.aliases end
    end
  end
  dump(data)
  jsonWriteFile(groundModelPath, data, true)
end

local function drawGroundModel(visibleGroundModels, debugtype, focusPos, gmName, gm, countOnly)
  local col = ColorF(gm.color[0], gm.color[1], gm.color[2], 1)
  local drawn = 0
  if debugtype >= 0 then
    drawn = drawn + debugDrawer:renderGroundModelDebug(debugtype, gmName, col, distance[0], tileSize[0], focusPos, depthScale[0], countOnly)
  end
  if staticDebug[0] then
    drawn = drawn + debugDrawer:renderStaticColDebug(debugtype, gmName, col, distance[0], tileSize[0], focusPos, depthScale[0], countOnly)
  end
  if drawn > 0 then
    if groundModels[gmName].isAlias == true then gmName = groundModels[gmName].parent end
    seen[gmName] = true
    if not countOnly then
      if not visibleGroundModels[gmName] then visibleGroundModels[gmName] = 0 end
      visibleGroundModels[gmName] = visibleGroundModels[gmName] + drawn
    end
  end
end

local function openWindow()
  windowOpen[0] = true
end

-- the imgui fonts have no emoji glyphs, so draw an editor atlas icon into the padded start of the button
local function iconButton(iconName, label)
  if not iconAtlasInfo then
    iconAtlasInfo = jsonReadFile("/core/art/gui/images/iconAtlas.json")
    iconAtlasTex = ui_imguiUtils.texObj("/core/art/gui/images/iconAtlas.png").tex
  end
  local size = im.GetTextLineHeight()
  local padding = string.rep(" ", math.ceil(size / im.CalcTextSize(" ").x) + 1)
  local pressed = im.SmallButton(padding .. label)
  local icon = iconAtlasInfo.icons[iconName]
  local pos = im.GetItemRectMin()
  iconP1.x, iconP1.y = pos.x + im.GetStyle().FramePadding.x, pos.y
  iconP2.x, iconP2.y = iconP1.x + size, iconP1.y + size
  iconUv1.x, iconUv1.y = icon.x / iconAtlasInfo.atlasWidth, icon.y / iconAtlasInfo.atlasHeight
  iconUv2.x, iconUv2.y = (icon.x + 48) / iconAtlasInfo.atlasWidth, (icon.y + 48) / iconAtlasInfo.atlasHeight
  im.ImDrawList_AddImage(im.GetWindowDrawList(), iconAtlasTex:getID(), iconP1, iconP2, iconUv1, iconUv2, im.GetColorU321(im.Col_Text))
  return pressed
end

local timeToNextDrawCount = 0
local axisToDraw = false -- x axis, vs y axis
local function onUpdate(dt)
  if windowOpen[0] ~= true then return end
  if core_environment.groundModels ~= envGroundModels then setup() end

  -- mouse
  local focusPos = vec3(Lua.lastDebugFocusPos)
  if mouseFocus[0] then
    local res = cameraMouseRayCast()
    if res and res.pos then
      -- debugDrawer:drawSphere(res.pos, 0.1, ColorF(0,1,0,1))
      --debugDrawer:drawLine(res.pos, res.pos + res.normal, ColorF(0,1,0,1))
      --print(" hit object: " .. tostring(res.object:getId() .. ' in ' .. res.distance .. ' m distance'))
      -- removes the object - fun minigame ;)
      --if res.object then res.object:delete() end
      focusPos = vec3(res.pos)
      debugDrawer:drawSphere(focusPos, math.min(math.max(res.distance * 0.02, 0.02), 1.0), ColorF(0,1,0,1))
    end
  end

  local visibleGroundModels = {}

  if spawnFrames < 3 then
    minWindowSize.x, minWindowSize.y = 310 * im.uiscale[0], 590 * im.uiscale[0]
    im.SetNextWindowSizeConstraints(minWindowSize, maxWindowSize)
    spawnFrames = spawnFrames + 1
  end
  im.Begin("GroundModel Debug Window", windowOpen)
    if groundDebug[0] and depthDebug[0] then debugtype = 2
    elseif groundDebug[0] and not depthDebug[0] then debugtype = 0
    elseif not groundDebug[0] and depthDebug[0] then debugtype = 1
    else debugtype = -1 end

    im.PushItemWidth(120 * im.uiscale[0])
    local areaDisabled = not (groundDebug[0] or depthDebug[0] or staticDebug[0])
    if areaDisabled then im.BeginDisabled(true) end
    if im.Checkbox("Follow mouse", mouseFocus) then serializeSettings() end
    im.SameLine()
    if im.SliderFloat("Area", distance, 0, 60, "%.1f", nil) then
      serializeSettings()
    end
    if im.IsItemDeactivatedAfterEdit() then
      distance[0] = clamp(distance[0], 0, 60)
    end
    if areaDisabled then im.EndDisabled() end

    local heightmapOpen = im.TreeNodeEx1("Ground heightmap:", sectionFlags)
    if heightmapOpen then
      im.Checkbox("Show heightmap", groundDebug)
      im.Checkbox("Show heightmap depth", depthDebug)
      if depthDebug[0] then
        if im.SliderFloat("Depth scale", depthScale, 0.1, 10, "%.2f", nil) then
          serializeSettings()
        end
        if im.IsItemDeactivatedAfterEdit() then
          depthScale[0] = clamp(depthScale[0], 0.1, 10)
        end
      end
      if groundDebug[0] or depthDebug[0] then
        if im.SliderFloat("Tile Size##heightmap", tileSize, 0.5, 1, "%.2f", nil) then
          serializeSettings()
        end
        if im.IsItemDeactivatedAfterEdit() then
          tileSize[0] = clamp(tileSize[0], 0.5, 1)
        end
      end
    end

    local staticOpen = im.TreeNodeEx1("Static triangles:", sectionFlags)
    if staticOpen then
      if im.Checkbox("Show triangles", staticDebug) then
        Engine.setStaticColDebugEnabled(staticDebug[0] or colDensityEnabled[0])
        if not staticDebug[0] then table.clear(seen) end
      end
      if staticDebug[0] then
        if im.SliderFloat("Padding", staticColPosShrink, 0, 0.12, "%.2f m") then
          staticColPosShrink[0] = math.floor(staticColPosShrink[0] * 100 + 0.5) * 0.01
          Engine.setStaticColDebugPosShrink(staticColPosShrink[0])
          serializeSettings()
        end
      end
      if im.Checkbox("Show triangles density (freezes on click)", colDensityEnabled) then
        Engine.setStaticColDebugEnabled(staticDebug[0] or colDensityEnabled[0])
      end
      if colDensityEnabled[0] then
        if im.SliderInt("Area##density", colDensityTileCount, 3, 100, string.format("%d x %d (%d tiles)", colDensityTileCount[0], colDensityTileCount[0], colDensityTileCount[0]*colDensityTileCount[0])) then
          serializeSettings()
        end
        if im.SliderFloat("Tile Size (freezes on click)", colDensityTileSize, 5, 30, "%.1f") then
          serializeSettings()
        end
        if im.Checkbox("Highlight Labels", colDensityShowText) then
          serializeSettings()
        end
        if im.SliderFloat("Highlight threshold", colDensityThreshold, 1, 100, "%.0f coltris/m²") then
          serializeSettings()
        end
      end
    end
    im.PopItemWidth()

    -- debug draw
    for _,k in pairs(gms) do
      local gm = groundModels[k]
      local drawGm = gm.isAlias == true and groundModels[gm.parent] or gm
      if gm.active[0] then
        drawGroundModel(visibleGroundModels, debugtype, focusPos, k, drawGm)
      elseif not listAll[0] then
        drawGroundModel(visibleGroundModels, debugtype, focusPos, k, drawGm, true)
      end
    end
    if colDensityEnabled[0] then
      debugDrawer:renderStaticColCounter(focusPos, colDensityTileSize[0], colDensityTileCount[0], colDensityThreshold[0], colDensityShowText[0])
    end

    local groundModelsOpen = im.TreeNodeEx1("Groundmodels:", sectionFlags)
    if groundModelsOpen then
      if im.Checkbox("List All", listAll) then serializeSettings() end
      im.SameLine()
      if im.Checkbox("Alt Theme", altTheme) then
        applyTheme()
        serializeSettings()
      end
      im.BeginChild1("GroundModelScroll")
      im.Columns(4, "GroundModelColumnsBegin") -- im.ColumnsFlags_NoResize)

      local iconColumnWidth = im.GetFrameHeight() + 2 * im.GetStyle().ItemSpacing.x
      im.SetColumnWidth(0, iconColumnWidth)
      im.SetColumnWidth(1, iconColumnWidth)
      im.SetColumnWidth(2, 50 * im.uiscale[0])
      im.SetColumnWidth(3, 1000 * im.uiscale[0])

      -- table header
      local shownCount = 0
      for _,k in pairs(gms) do
        if groundModels[k].active[0] then shownCount = shownCount + 1 end
      end
      allVisible[0] = shownCount == #gms and 3 or (shownCount > 0 and 1 or 0)
      im.Separator()
      if im.CheckboxFlags1("##allVisible", allVisible, 3) then
        for _,k in pairs(gms) do
          groundModels[k].active[0] = allVisible[0] == 3
        end
      end
      im.NextColumn()
      im.NextColumn()
      im.Text("Tris")
      im.NextColumn()
      im.Text("Name")
      im.SameLine()
      if iconButton("save", "Save") then saveGroundmodels() end
      im.SameLine()
      if iconButton("settings_backup_restore", "Default") then core_environment.reloadGroundModels() setup() end
      im.NextColumn()
      im.Separator()

      -- TODO: use ImGuiListClipper
      for _,k in pairs(gms) do
        local v = groundModels[k]
        local tris = visibleGroundModels[k] or 0
        if v.isAlias == false and (listAll[0] or seen[k]) then
          im.PushID1(k..'_active')
          if im.Checkbox('', groundModels[k].active) then
            if #v.aliases > 0 then
              for _, name in pairs(v.aliases) do
                groundModels[name].active[0] = groundModels[k].active[0]
              end
            end
          end
          im.NextColumn()
          im.PopID()
          im.PushID1(k..'_color')
          if im.ColorEdit3("", groundModels[k].color, im.ColorEditFlags_NoInputs) then
            serializeSettings()
          end
          im.PopID()
          im.NextColumn()
          if v.active[0] then im.Text(tostring(tris)) end
          im.NextColumn()

          -- im.SetCursorPosX(55)
          local grayed = tris == 0
          if grayed then im.PushStyleColor2(im.Col_Text, grayText) end
          local nodeOpen = im.TreeNode1(k)
          if grayed then im.PopStyleColor() end
          if nodeOpen then
            im.PushItemWidth(100 * im.uiscale[0])
            local materials = require("particles").getMaterialsParticlesTable()
            local material = materials[v.cdata.collisiontype[0]]
            local materialName = material and material.name:gsub("%%", "%%%%") or "none" -- used as imgui format string
            if im.SliderInt("collisiontype", v.cdata.collisiontype, 0, table.maxn(materials), materialName) then
              setValue(k, v, 'collisiontype', v.cdata.collisiontype[0])
            end
            if im.SliderFloat("defaultDepth", v.cdata.defaultDepth, 0.0, 5) then
              setValue(k, v, 'defaultDepth', v.cdata.defaultDepth[0])
            end
            im.ShowHelpMarker('This parameter sets the depth of the surface fluid in meters.', true)
            if im.SliderFloat("dragAnisotropy", v.cdata.dragAnisotropy, 0, 1, "%.2f") then
              setValue(k, v, 'dragAnisotropy', v.cdata.dragAnisotropy[0])
            end
            im.ShowHelpMarker('Upwards/Downwards drag anisotropy. This creates a lifting or sinking effect on the node when it slides through the surface fluid.', true)
            if im.SliderFloat("flowBehaviorIndex", v.cdata.flowBehaviorIndex, 0, 5.0, "%.2f") then
              setValue(k, v, 'flowBehaviorIndex', v.cdata.flowBehaviorIndex[0])
            end
            if im.SliderFloat("flowConsistencyIndex", v.cdata.flowConsistencyIndex, 0, 15000, "%.0f") then
              setValue(k, v, 'flowConsistencyIndex', v.cdata.flowConsistencyIndex[0])
            end
            im.ShowHelpMarker('Determines the speed sensitive drag effect. If <1 then fluid is Pseudoplastic (ketchup, whipped cream, paint) and has less drag coefficient at high speeds. If =1 then fluid is Newtonian, having equal drag coefficient at any speed. If >1 then fluid is Dilatant, having higher drag coefficient at high speeds.', true)
            if im.SliderFloat("fluidDensity", v.cdata.fluidDensity, 0, 50000, "%.0f") then
              setValue(k, v, 'fluidDensity', v.cdata.fluidDensity[0])
            end
            im.ShowHelpMarker('Density of the surface fluid (kg/m^3).', true)
            if im.SliderFloat("hydrodynamicFriction", v.cdata.hydrodynamicFriction, 0, 0.01, "%.4f") then
              setValue(k, v, 'hydrodynamicFriction', v.cdata.hydrodynamicFriction[0])
            end
            im.ShowHelpMarker("This friction coefficient is used to add some extra friction as sliding velocity increases. This is useful for replicating fluid viscosity or speed sensitive friction effects of somewhat fluid-like ground types (soft dirt, sand, mud). If you decide that you'll simulate the fluid like behavior with the more complex fluid physics below, then just set this to 0.", true)
            -- if im.InputText("name", v.cdata.name) then
            --   setValue(k, v, 'name', v.cdata.name[0])
            -- end
            if im.SliderFloat("roughnessCoefficient", v.cdata.roughnessCoefficient, 0, 1, "%.2f") then
              setValue(k, v, 'roughnessCoefficient', v.cdata.roughnessCoefficient[0])
            end
            if im.SliderFloat("shearStrength", v.cdata.shearStrength, 0, 25000, "%.0f") then
              setValue(k, v, 'shearStrength', v.cdata.shearStrength[0])
            end
            if im.Checkbox("skidMarks", v.cdata.skidMarks) then
              setValue(k, v, 'skidMarks', v.cdata.skidMarks[0])
            end
            im.ShowHelpMarker('False = No skidmarks, True = Skidmarks.', true)
            if im.SliderFloat("slidingFrictionCoefficient", v.cdata.slidingFrictionCoefficient, 0.1, 1.5, "%.2f") then
              setValue(k, v, 'slidingFrictionCoefficient', v.cdata.slidingFrictionCoefficient[0])
            end
            if im.SliderFloat("staticFrictionCoefficient", v.cdata.staticFrictionCoefficient, 0.1, 2.0, "%.2f") then
              setValue(k, v, 'staticFrictionCoefficient', v.cdata.staticFrictionCoefficient[0])
            end
            im.ShowHelpMarker('Static friction keeps you in the same place when you are stopped on a hill. This friction coefficient is usually higher than sliding friction.', true)
            if im.SliderFloat("strength", v.cdata.strength, 0, 2, "%.2f") then
              setValue(k, v, 'strength', v.cdata.strength[0])
            end
            im.ShowHelpMarker('This parameter raises or diminishes surface friction in a generic way. It is here so as to be able to do quick calibrations of friction. Start with having this to 1.0 and after tuning the rest of the surface variables, come back and play with this.', true)
            if im.SliderFloat("stribeckVelocity", v.cdata.stribeckVelocity, 0, 7.5, "%.2f") then
              setValue(k, v, 'stribeckVelocity', v.cdata.stribeckVelocity[0])
            end
            im.ShowHelpMarker('The stribeck velocity defines the shape of the static-sliding friction curve. A small stribeck velocity will cause an abrupt change from static to sliding friction, a large stribek velocity will make a slower transition that will feel more "sticky". The inverse (1 / stribeck velocity) is often described as "stribeck coefficient". Reference values can be found in either form, so make sure not to confuse them when looking up reference data.', true)
            im.TreePop()
          end
          im.NextColumn()
        end
      end
      im.Columns(1)
      im.EndChild()
    end

    -- ## commented out following stuff for the time being cause it caused a huuuge framedrop and made the tool unuseable ##

    -- if staticDebug[0] and staticCounterOnly[0] then
    --   local c = Engine.getCollisionDebugData()
    --   if c then
    --     -- postprocessing: sort, do some global stats, etc
    --     c.worlds[1].tris = 0
    --     for kb, body in ipairs(c.worlds[1].bodies) do
    --       body.tris = 0
    --       for kc, col in ipairs(body.cols) do
    --         body.tris = body.tris + col.triCount
    --       end
    --       c.worlds[1].tris = c.worlds[1].tris + body.tris
    --     end
    --     table.sort(c.worlds[1].bodies, function(a, b) return a.tris > b.tris end)
    --   end

      -- display
      -- if im.TreeNode1("Static Collision data: " .. tostring(c.worlds[1].tris) .. " tris") then

        -- im.BeginChild1("StaticColDetailScroll")
        -- im.Columns(2, "StaticColDetailColumnsBegin") -- im.ColumnsFlags_NoResize)
        -- local firstColumnSize = 150
        -- im.SetColumnWidth(0, firstColumnSize)
        -- im.SetColumnWidth(1, 1000)

        -- -- table header
        -- im.Separator()
        -- im.Text("Triangles")
        -- im.NextColumn()
        -- im.Text("Object")
        -- im.NextColumn()
        -- im.Separator()

        -- for kb, body in ipairs(c.worlds[1].bodies) do
        --   local weight = ((body.tris * 50) / c.worlds[1].tris) * firstColumnSize
        --   -- draw bar in the firs column
        --   local p1 = im.GetCursorScreenPos()
        --   local p2 = im.ImVec2(p1.x + weight, p1.y + textLineHeight)
        --   local col = im.GetColorU322( im.ImVec4(0.65, 0.2, 0.2, 1))
        --   im.ImDrawList_AddRectFilled(im.GetWindowDrawList(), p1, p2, col)
        --   -- then the text on top and the other columns
        --   im.Text(string.format("%d (%0.2f%%%%)", body.tris, (body.tris / c.worlds[1].tris) * 100))
        --   im.NextColumn()
        --   im.Text(body.objName .. ' [' .. body.objId .. ']')
        --   im.SameLine()
        --   if ui_imgui.SmallButton("select") then
        --     TorqueScript.eval('EWorldEditor.clearSelection();EWorldEditor.selectObject(' .. tostring(body.objId) .. ');EWorldEditor.dropCameraToSelection();')
        --   end
        --   im.NextColumn()
        -- end
        -- im.Columns(1)
        -- im.EndChild()

        -- im.TreePop()
      -- end
    -- end
  im.End()
  if not windowOpen[0] then
    table.clear(seen)
    spawnFrames = 0
    staticDebug[0] = false
    colDensityEnabled[0] = false
    Engine.setStaticColDebugEnabled(false)
  end
end

local function onExtensionLoaded()
  setup()
end

local function onSerialize()
  return {
    windowOpen = windowOpen[0],
    staticDebug = staticDebug[0],
    colDensityEnabled = colDensityEnabled[0],
  }
end

local function onDeserialized(data)
  windowOpen[0] = data.windowOpen
  staticDebug[0] = data.staticDebug
  colDensityEnabled[0] = data.colDensityEnabled

  Engine.setStaticColDebugEnabled(staticDebug[0] or colDensityEnabled[0])
end

M.openWindow = openWindow
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M
