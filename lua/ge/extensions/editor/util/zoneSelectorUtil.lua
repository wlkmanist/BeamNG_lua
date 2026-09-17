-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local imVec4Yellow = im.ImVec4(1,1,0,1)
local imVec4TransparentWhite = im.ImVec4(1,1,1,0.25)

local C = {}

function C:init(element)
  self.element = element
end

function C:loadZonesFromSitesFile(ctd)
  local e = self.element
  -- Get globalInfoFolder from container
  local globalInfoFolder = ctd[e.globalInfoFolderFieldName] or ""
  if not globalInfoFolder or globalInfoFolder == "" then
    e.loadedZones = {}
    e.zonesLoaded = true
    e.sitesFile = nil
    return
  end

  -- Construct sites file path
  local sitesFile = globalInfoFolder .. "/garages.sites.json"

  -- Check if we already loaded this file
  if e.sitesFile == sitesFile and e.zonesLoaded then
    return
  end

  -- Check if file exists
  if not FS:fileExists(sitesFile) then
    e.loadedZones = {}
    e.zonesLoaded = true
    e.sitesFile = sitesFile
    return
  end

  -- Load sites file - try extensions table first, then direct access
  local sitesManager = nil
  if extensions and extensions.gameplay_sites_sitesManager then
    sitesManager = extensions.gameplay_sites_sitesManager
  elseif gameplay_sites_sitesManager then
    sitesManager = gameplay_sites_sitesManager
  end

  if not sitesManager then
    e.loadedZones = {}
    e.zonesLoaded = true
    e.sitesFile = sitesFile
    return
  end

  local sites = sitesManager.loadSites(sitesFile, false, true)
  if not sites or not sites.zones then
    e.loadedZones = {}
    e.zonesLoaded = true
    e.sitesFile = sitesFile
    return
  end

  -- Extract zone names
  e.loadedZones = {}
  if sites.zones.sorted then
    for _, zone in ipairs(sites.zones.sorted) do
      if zone.name then
        table.insert(e.loadedZones, zone.name)
      end
    end
  end

  -- Sort zones alphabetically
  table.sort(e.loadedZones)

  e.zonesLoaded = true
  e.sitesFile = sitesFile
end

function C:setContainer(ctd)
  local e = self.element
  -- Read tables directly
  e.initialZones = ctd[e.fieldName .. "_initialZones"] or {}
  e.destinationZones = ctd[e.fieldName .. "_destinationZones"] or {}
  -- Reset loaded state so zones will be reloaded if folder changes
  e.zonesLoaded = false
  e.loadedZones = {}
  e.sitesFile = nil
end

function C:draw(ctd, container, labelFn)
  local e = self.element
  labelFn(e)

  -- Initialize arrays if needed
  if not e.initialZones then e.initialZones = {} end
  if not e.destinationZones then e.destinationZones = {} end

  -- Load zones from sites file
  self:loadZonesFromSitesFile(ctd)

  local ret = false

  -- Cache sets and only rebuild when arrays change (performance optimization)
  local initialZonesCount = #e.initialZones
  local destinationZonesCount = #e.destinationZones
  if not e._cachedInitialZonesSet or e._cachedInitialZonesCount ~= initialZonesCount then
    e._cachedInitialZonesSet = {}
    for _, zoneName in ipairs(e.initialZones) do
      e._cachedInitialZonesSet[zoneName] = true
    end
    e._cachedInitialZonesCount = initialZonesCount
  end
  local initialZonesSet = e._cachedInitialZonesSet

  if not e._cachedDestinationZonesSet or e._cachedDestinationZonesCount ~= destinationZonesCount then
    e._cachedDestinationZonesSet = {}
    for _, zoneName in ipairs(e.destinationZones) do
      e._cachedDestinationZonesSet[zoneName] = true
    end
    e._cachedDestinationZonesCount = destinationZonesCount
  end
  local destinationZonesSet = e._cachedDestinationZonesSet

  -- Display zones
  if #e.loadedZones == 0 then
    im.TextColored(imVec4Yellow, "No zones found. Please check the Global Info Folder path and ensure garages.sites.json exists.")
  else
    -- Initial Zones section
    im.Separator()
    im.Text("Initial Zones (where player can spawn):")

    -- Dropdown to add zones
    if not e.selectedInitialZone then e.selectedInitialZone = "" end
    im.PushItemWidth(300)
    if im.BeginCombo("Add Zone##initialAdd"..e._id, e.selectedInitialZone or "Select zone...") then
      for _, zoneName in ipairs(e.loadedZones) do
        -- Only show zones that aren't already selected
        if not initialZonesSet[zoneName] then
          if im.Selectable1(zoneName, zoneName == e.selectedInitialZone) then
            e.selectedInitialZone = zoneName
            -- Add to initial zones
            table.insert(e.initialZones, zoneName)
            initialZonesSet[zoneName] = true
            e._cachedInitialZonesCount = #e.initialZones
            ctd[e.fieldName .. "_initialZones"] = e.initialZones
            e.selectedInitialZone = "" -- Reset selection
            ret = true
            im.EndCombo()
            im.PopItemWidth()
            break
          end
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()
    im.SameLine()
    -- Select All button
    if im.Button("Select All##initialSelectAll"..e._id) then
      for _, zoneName in ipairs(e.loadedZones) do
        if not initialZonesSet[zoneName] then
          table.insert(e.initialZones, zoneName)
          initialZonesSet[zoneName] = true
        end
      end
      e._cachedInitialZonesCount = #e.initialZones
      ctd[e.fieldName .. "_initialZones"] = e.initialZones
      ret = true
    end
    im.SameLine()
    -- Remove All button
    if im.Button("Remove All##initialRemoveAll"..e._id) then
      e.initialZones = {}
      e._cachedInitialZonesSet = {}
      e._cachedInitialZonesCount = 0
      initialZonesSet = e._cachedInitialZonesSet
      ctd[e.fieldName .. "_initialZones"] = {}
      ret = true
    end

    -- List of selected initial zones
    if #e.initialZones > 0 then
      -- Use available content region, but ensure minimum height for usability
      local availHeight = im.GetContentRegionAvail().y
      local initialZonesHeight = math.max(150, math.min(availHeight * 0.5, #e.initialZones * 25 + 30))
      im.BeginChild1("InitialZonesList"..e._id, im.ImVec2(0, initialZonesHeight), true)
      for i, zoneName in ipairs(e.initialZones) do
        im.Text(zoneName)
        im.SameLine()
        if im.SmallButton("Remove##initialRemove"..i..e._id) then
          table.remove(e.initialZones, i)
          initialZonesSet[zoneName] = nil
          e._cachedInitialZonesCount = #e.initialZones
          ctd[e.fieldName .. "_initialZones"] = e.initialZones
          ret = true
          break
        end
      end
      im.EndChild()
    else
      im.TextColored(imVec4TransparentWhite, "No initial zones selected")
    end

    -- Destination Zones section
    im.Separator()
    im.Text("Destination Zones (where player can get destinations):")

    -- Dropdown to add zones
    if not e.selectedDestinationZone then e.selectedDestinationZone = "" end
    im.PushItemWidth(300)
    if im.BeginCombo("Add Zone##destinationAdd"..e._id, e.selectedDestinationZone or "Select zone...") then
      for _, zoneName in ipairs(e.loadedZones) do
        -- Only show zones that aren't already selected
        if not destinationZonesSet[zoneName] then
          if im.Selectable1(zoneName, zoneName == e.selectedDestinationZone) then
            e.selectedDestinationZone = zoneName
            -- Add to destination zones
            table.insert(e.destinationZones, zoneName)
            destinationZonesSet[zoneName] = true
            e._cachedDestinationZonesCount = #e.destinationZones
            ctd[e.fieldName .. "_destinationZones"] = e.destinationZones
            e.selectedDestinationZone = "" -- Reset selection
            ret = true
            im.EndCombo()
            im.PopItemWidth()
            break
          end
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()
    im.SameLine()
    -- Select All button
    if im.Button("Select All##destinationSelectAll"..e._id) then
      for _, zoneName in ipairs(e.loadedZones) do
        if not destinationZonesSet[zoneName] then
          table.insert(e.destinationZones, zoneName)
          destinationZonesSet[zoneName] = true
        end
      end
      e._cachedDestinationZonesCount = #e.destinationZones
      ctd[e.fieldName .. "_destinationZones"] = e.destinationZones
      ret = true
    end
    im.SameLine()
    -- Remove All button
    if im.Button("Remove All##destinationRemoveAll"..e._id) then
      e.destinationZones = {}
      e._cachedDestinationZonesSet = {}
      e._cachedDestinationZonesCount = 0
      destinationZonesSet = e._cachedDestinationZonesSet
      ctd[e.fieldName .. "_destinationZones"] = {}
      ret = true
    end

    -- List of selected destination zones
    if #e.destinationZones > 0 then
      -- Use available content region, but ensure minimum height for usability
      local availHeight = im.GetContentRegionAvail().y
      local destinationZonesHeight = math.max(150, math.min(availHeight * 0.5, #e.destinationZones * 25 + 30))
      im.BeginChild1("DestinationZonesList"..e._id, im.ImVec2(0, destinationZonesHeight), true)
      for i, zoneName in ipairs(e.destinationZones) do
        im.Text(zoneName)
        im.SameLine()
        if im.SmallButton("Remove##destinationRemove"..i..e._id) then
          table.remove(e.destinationZones, i)
          destinationZonesSet[zoneName] = nil
          e._cachedDestinationZonesCount = #e.destinationZones
          ctd[e.fieldName .. "_destinationZones"] = e.destinationZones
          ret = true
          break
        end
      end
      im.EndChild()
    else
      im.TextColored(imVec4TransparentWhite, "No destination zones selected")
    end

    -- Summary
    im.Separator()
    im.Text("Selected: " .. #e.initialZones .. " initial zone(s), " .. #e.destinationZones .. " destination zone(s)")

    -- Save zone lists as tables directly
    ctd[e.fieldName .. "_initialZones"] = e.initialZones
    ctd[e.fieldName .. "_destinationZones"] = e.destinationZones
  end

  im.Columns(1)
  return ret
end

return function(element)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(element)
  return o
end

