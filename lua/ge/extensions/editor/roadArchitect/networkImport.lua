-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared OSM / SUMO → Road Architect import.
-- Creates independent RA roads with coincident endpoints where the source network
-- shares nodes. Full RA junction objects are not built (same limitation as OpenDRIVE).

local M = {}

local roadMgr = require('editor/roadArchitect/roads')
local profileMgr = require('editor/roadArchitect/profiles')
local geom = require('editor/roadArchitect/geometry')
local terra = require('editor/roadArchitect/terraform')
local importFile = require('editor/roadArchitect/importFile')

local im = ui_imgui

-- Must match tech/openStreetMapExporter.lua createNodesData encoding.
local BEAMNG_OSM_SCALE = 1e7
local BEAMNG_OSM_OFFSET = 45.0
local ENDPOINT_SNAP_M = 0.05
-- BeamNG SUMO shapes start/end at road mouths, which can sit several metres off the node.
local SHAPE_INCLUDES_ENDS_M = 25.0

local function parseAttributes(text)
    local attributes = {}
    text:gsub("([%w_:%-]+)%s*=%s*([\"'])(.-)%2", function(key, _, value)
        attributes[key] = value
    end)
    return attributes
end

local function clonePoint(point)
    return vec3(point.x, point.y, point.z)
end

local function squaredDistance2D(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

local function near2D(a, b, tol)
    tol = tol or ENDPOINT_SNAP_M
    return squaredDistance2D(a, b) <= tol * tol
end

local function formatNodes(points, halfWidth)
    local nodes = {}
    for i, point in ipairs(points) do
        -- Always own a unique vec3: shared refs across roads make applyPlacement
        -- multiply the XY shift at every coincidence and tear junctions apart.
        local p = clonePoint(point)
        nodes[i] = {
            p = p,
            isLocked = false,
            rot = im.FloatPtr(0.0),
            height = im.FloatPtr(p.z),
            widths = {
                [-1] = im.FloatPtr(halfWidth),
                [1] = im.FloatPtr(halfWidth)
            },
            heightsL = {
                [-1] = im.FloatPtr(0.1),
                [1] = im.FloatPtr(0.1)
            },
            heightsR = {
                [-1] = im.FloatPtr(0.1),
                [1] = im.FloatPtr(0.1)
            },
            incircleRad = im.FloatPtr(1.0),
            isAutoBanked = false,
            offset = 0.0
        }
    end
    return nodes
end

local function createRoad(spec)
    local laneSection = {
        [-1] = {type = 'driving'},
        [1] = {type = 'driving'}
    }
    local profile = profileMgr.createCustomImportProfile(laneSection)
    local road = roadMgr.createRoadFromProfile(profile)
    road.nodes = formatNodes(spec.points, math.max(spec.width or 7.0, 0.2) * 0.5)
    road.displayName = im.ArrayChar(32, tostring(spec.name or 'Imported Road'))
    road.isDisplayRoadOutline = im.BoolPtr(false)
    road.isDisplayRoadSurface = im.BoolPtr(false)
    road.isDisplayNodeSpheres = im.BoolPtr(false)
    geom.computeRoadRenderData(road, roadMgr.roads, roadMgr.map)
    roadMgr.roads[#roadMgr.roads + 1] = road
    roadMgr.map[road.name] = #roadMgr.roads
    roadMgr.setDirty(road)
    road.isDirty = false                                                                            -- renderData already computed; avoid a full recompute in Render Mode.
end

-- placeMode: 0 = as in file, 1 = custom (placeX, placeY), 2 = camera XY, 3 = player vehicle XY.
-- placeZ shifts the whole network vertically so the first imported road start node sits at that height.
local function applyPlacement(firstRoadIndex, options)
    local placeMode = options.placeMode or 0
    local placeZ = options.placeZ
    if (placeMode == 0 and placeZ == nil) or firstRoadIndex > #roadMgr.roads then
        return
    end

    local firstNode = roadMgr.roads[firstRoadIndex].nodes[1]
    if not firstNode then
        return
    end

    local dx, dy = 0.0, 0.0
    if placeMode ~= 0 then
        local targetX, targetY = options.placeX or 0.0, options.placeY or 0.0
        if placeMode == 2 then
            local cameraPosition = core_camera.getPosition()
            targetX, targetY = cameraPosition.x, cameraPosition.y
        elseif placeMode == 3 then
            -- Headless/API counterpart of the camera anchor: the caller cannot see the
            -- free camera, so the current player vehicle is the meaningful anchor.
            local vehicle = be:getPlayerVehicle(0)
            if not vehicle then
                error('placeMode 3 requires a current player vehicle; none found')
            end
            local position = vec3(vehicle:getPosition())
            targetX, targetY = position.x, position.y
        end
        dx = targetX - firstNode.p.x
        dy = targetY - firstNode.p.y
    end

    local dz = placeZ ~= nil and (placeZ - firstNode.p.z) or 0.0
    if math.abs(dx) < 1e-9 and math.abs(dy) < 1e-9 and math.abs(dz) < 1e-9 then
        return
    end

    for i = firstRoadIndex, #roadMgr.roads do
        local road = roadMgr.roads[i]
        for _, node in ipairs(road.nodes) do
            node.p.x = node.p.x + dx
            node.p.y = node.p.y + dy
            node.p.z = node.p.z + dz
            node.height[0] = node.p.z
        end
        roadMgr.setDirty(road)
    end
end

-- After placement / height offsets, force endpoints that share a source node id onto
-- one canonical world position so T-joins and crossings stay coincident.
local function snapSharedEndpoints(firstRoadIndex, endpointKeys)
    if not endpointKeys or #endpointKeys == 0 then
        return
    end

    local canonical = {}
    for roadOffset, ends in ipairs(endpointKeys) do
        local road = roadMgr.roads[firstRoadIndex + roadOffset - 1]
        if road and road.nodes and #road.nodes > 0 then
            for _, endInfo in ipairs(ends) do
                local node = road.nodes[endInfo.index]
                local key = endInfo.key
                if node and key then
                    if not canonical[key] then
                        canonical[key] = {x = node.p.x, y = node.p.y, z = node.p.z}
                    end
                end
            end
        end
    end

    for roadOffset, ends in ipairs(endpointKeys) do
        local road = roadMgr.roads[firstRoadIndex + roadOffset - 1]
        if road and road.nodes then
            local dirty = false
            for _, endInfo in ipairs(ends) do
                local node = road.nodes[endInfo.index]
                local pos = endInfo.key and canonical[endInfo.key]
                if node and pos then
                    if node.p.x ~= pos.x or node.p.y ~= pos.y or node.p.z ~= pos.z then
                        node.p.x, node.p.y, node.p.z = pos.x, pos.y, pos.z
                        node.height[0] = pos.z
                        dirty = true
                    end
                end
            end
            if dirty then
                roadMgr.setDirty(road)
            end
        end
    end
end

local function importUndo(data)
    for _, road in ipairs(data.roads) do
        roadMgr.removeRoad(road.name)
    end
    roadMgr.computeAllRoadRenderData()
    if data.finalized then
        be:reloadCollision()
        map.reset()
    end
end

local function importRedo(data)
    for _, serializedRoad in ipairs(data.roads) do
        local road = roadMgr.deserialiseRoad(serializedRoad)
        roadMgr.roads[#roadMgr.roads + 1] = road
        roadMgr.setDirty(road)
    end
    roadMgr.recomputeMap()
    roadMgr.computeAllRoadRenderData()
    if data.finalized then
        importFile.maybeFinalise({finalize = true})
    end
end

local function importRoads(label, specs, skippedRoadCount, warnings, junctionCount, options, endpointKeys)
    options = options or {}
    importFile.ensureEditorHistory()

    local roadsBefore = #roadMgr.roads
    local ok, importError = pcall(function()
        for _, spec in ipairs(specs) do
            createRoad(spec)
        end

        local firstRoadIndex = roadsBefore + 1
        applyPlacement(firstRoadIndex, options)

        if options.offsetToTerrain == true then
            for i = firstRoadIndex, #roadMgr.roads do
                local road = roadMgr.roads[i]
                road.isConformRoadToTerrain = im.BoolPtr(true)
                roadMgr.setDirty(road)
            end
        elseif options.verticalOffset ~= nil then
            for i = firstRoadIndex, #roadMgr.roads do
                local road = roadMgr.roads[i]
                for _, node in ipairs(road.nodes) do
                    node.p.z = node.p.z + options.verticalOffset
                    node.height[0] = node.p.z
                end
                roadMgr.setDirty(road)
            end
        end

        snapSharedEndpoints(firstRoadIndex, endpointKeys)

        if options.terraform == true then
            roadMgr.computeAllRoadRenderData()
            terra.terraformMultiRoads(options.domainOfInfluence or 30, options.margin or 1.0, nil)
        end
    end)

    if not ok then
        for i = #roadMgr.roads, roadsBefore + 1, -1 do
            roadMgr.removeRoad(roadMgr.roads[i].name)
        end
        error(importError)
    end

    local importedRoadCount = #roadMgr.roads - roadsBefore
    local importedRoads = {}
    for i = roadsBefore + 1, #roadMgr.roads do
        importedRoads[#importedRoads + 1] = roadMgr.serialiseRoad(roadMgr.roads[i])
    end
    local finalized = false
    if importedRoadCount > 0 then
        local callOk, finResult, finErr = pcall(function()
            return importFile.maybeFinalise(options)
        end)
        if callOk and finResult then
            finalized = true
        elseif callOk and finErr then
            warnings[#warnings + 1] = tostring(finErr)
            log('W', 'roadArchitect.networkImport', finErr)
        elseif not callOk then
            local msg = 'finalize failed: ' .. tostring(finResult)
            warnings[#warnings + 1] = msg
            log('W', 'roadArchitect.networkImport', msg)
        end
        editor.history:commitAction(
            'Import ' .. label,
            {roads = importedRoads, finalized = finalized},
            importUndo,
            importRedo,
            true)
    end

    return {
        success = true,
        importedRoadCount = importedRoadCount,
        skippedRoadCount = skippedRoadCount,
        warningCount = #warnings,
        warnings = warnings,
        junctionCount = junctionCount,
        unsupported = {junctions = junctionCount > 0},
        finalized = finalized
    }
end

local function parseWidth(value)
    return value and tonumber(value:match('[-+]?%d*%.?%d+')) or nil
end

local ignoredHighways = {
    footway = true,
    path = true,
    cycleway = true,
    pedestrian = true,
    steps = true,
    bridleway = true
}

local function isNonRoadWay(tags)
    return tags.building ~= nil
        or tags.waterway ~= nil
        or tags.railway ~= nil
        or tags.natural ~= nil
        or tags.landuse ~= nil
        or tags.leisure ~= nil
        or tags.boundary ~= nil
        or tags.barrier ~= nil
        or tags.area == 'yes'
end

-- Geographic lat/lon → local metres (east = X, north = Y), origin at (minLon, minLat).
local function geoToLocal(latitude, longitude, minLat, minLon)
    local x = (longitude - minLon) * 40075000.0 * math.cos(math.rad(latitude)) / 360.0
    local y = (latitude - minLat) * 111320.0
    return x, y
end

-- Inverse of tech/openStreetMapExporter.lua metre packing into fake lat/lon.
local function beamNgOsmToWorld(latitude, longitude)
    local x = (latitude - BEAMNG_OSM_OFFSET) * BEAMNG_OSM_SCALE
    local y = (longitude - BEAMNG_OSM_OFFSET) * BEAMNG_OSM_SCALE
    return x, y
end

local function importOsmFromFile(filePath, options)
    local fileData = importFile.readTextFile(filePath)
    if not fileData then
        error('Unable to read OpenStreetMap file: ' .. tostring(filePath))
    end

    local isBeamNgExport = fileData:find('generator="BeamNG"', 1, true) ~= nil

    local boundsText = fileData:match('<bounds%s+([^>]-)/?>')
    local bounds = boundsText and parseAttributes(boundsText) or {}
    local minLat = tonumber(bounds.minlat)
    local minLon = tonumber(bounds.minlon)
    local nodeMinLat, nodeMinLon
    local rawNodes = {}
    for attributesText in fileData:gmatch('<node%s+([^>]-)>') do
        local attributes = parseAttributes(attributesText)
        local latitude = tonumber(attributes.lat)
        local longitude = tonumber(attributes.lon)
        if attributes.id and latitude and longitude then
            rawNodes[attributes.id] = {
                latitude = latitude,
                longitude = longitude,
                elevation = tonumber(attributes.ele) or 0.1
            }
            nodeMinLat = nodeMinLat and math.min(nodeMinLat, latitude) or latitude
            nodeMinLon = nodeMinLon and math.min(nodeMinLon, longitude) or longitude
        end
    end
    minLat = minLat or nodeMinLat
    minLon = minLon or nodeMinLon

    if not minLat or not minLon then
        error('OpenStreetMap file contains no usable nodes')
    end

    local nodes = {}
    for id, node in pairs(rawNodes) do
        local x, y
        if isBeamNgExport then
            x, y = beamNgOsmToWorld(node.latitude, node.longitude)
        else
            x, y = geoToLocal(node.latitude, node.longitude, minLat, minLon)
        end
        nodes[id] = vec3(x, y, node.elevation)
    end

    local specs = {}
    local endpointKeys = {}
    local skipped = 0
    local missingReferences = 0
    local referenceCounts = {}
    for wayAttributesText, body in fileData:gmatch('<way%s+([^>]-)>(.-)</way>') do
        local wayAttributes = parseAttributes(wayAttributesText)
        local references = {}
        for attributesText in body:gmatch('<nd%s+([^>]-)>') do
            local attributes = parseAttributes(attributesText)
            if attributes.ref then
                references[#references + 1] = attributes.ref
            end
        end

        local tags = {}
        for attributesText in body:gmatch('<tag%s+([^>]-)>') do
            local attributes = parseAttributes(attributesText)
            if attributes.k then
                tags[attributes.k] = attributes.v
            end
        end

        local skipWay = #references < 2
            or (tags.highway and ignoredHighways[tags.highway])
            or (not tags.highway and (isNonRoadWay(tags) or not isBeamNgExport))
        if skipWay then
            skipped = skipped + 1
        else
            local points = {}
            local usedRefs = {}
            for _, reference in ipairs(references) do
                if nodes[reference] then
                    points[#points + 1] = clonePoint(nodes[reference])
                    usedRefs[#usedRefs + 1] = reference
                else
                    missingReferences = missingReferences + 1
                end
            end
            if #points > 1 then
                for _, reference in ipairs(usedRefs) do
                    referenceCounts[reference] = (referenceCounts[reference] or 0) + 1
                end
                local laneCount = tonumber(tags.lanes)
                local width = parseWidth(tags.width) or (laneCount and laneCount * 3.5) or 7.0
                specs[#specs + 1] = {
                    name = 'OSM ' .. tostring(wayAttributes.id or #specs + 1),
                    points = points,
                    width = width
                }
                endpointKeys[#endpointKeys + 1] = {
                    {key = usedRefs[1], index = 1},
                    {key = usedRefs[#usedRefs], index = #points}
                }
            else
                skipped = skipped + 1
            end
        end
    end

    local warnings = {}
    if isBeamNgExport then
        warnings[#warnings + 1] = 'Decoded BeamNG OpenStreetMap export metre packing (lat/lon = world/1e7 + 45)'
    end
    if missingReferences > 0 then
        warnings[#warnings + 1] = tostring(missingReferences) .. ' missing OSM node reference(s) were ignored'
    end
    -- Count nodes referenced by 2+ ways (connection points), not every shared mid-vertex alone.
    local junctionCount = 0
    for _, count in pairs(referenceCounts) do
        if count > 1 then
            junctionCount = junctionCount + 1
        end
    end
    if junctionCount > 0 then
        warnings[#warnings + 1] = tostring(junctionCount)
            .. ' shared OSM road node(s) were snapped geometrically but not converted to Road Architect junctions'
    end
    return importRoads('OpenStreetMap', specs, skipped, warnings, junctionCount, options, endpointKeys)
end

local function sumoPrefix(filePath)
    if filePath:sub(-8) == '.nod.xml' or filePath:sub(-8) == '.edg.xml' then
        return filePath:sub(1, -9)
    end
    if filePath:sub(-4) == '.xml' then
        return filePath:sub(1, -5)
    end
    return filePath
end

local function parseShape(shape)
    local points = {}
    if not shape then
        return points
    end
    for coordinate in shape:gmatch('%S+') do
        local x, y, z = coordinate:match('([^,]+),([^,]+),?([^,]*)')
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if x and y then
            points[#points + 1] = vec3(x, y, z or 0.1)
        end
    end
    return points
end

-- SUMO shape is normally intermediate points only; BeamNG's exporter includes mouth
-- positions that may sit off the junction nodes. Always terminate on from/to so
-- edges that share a node meet exactly.
local function buildSumoEdgePoints(fromPos, toPos, shapePoints)
    local points = {clonePoint(fromPos)}

    if #shapePoints >= 2 and near2D(shapePoints[1], fromPos, SHAPE_INCLUDES_ENDS_M)
        and near2D(shapePoints[#shapePoints], toPos, SHAPE_INCLUDES_ENDS_M) then
        -- Shape already spans the edge (BeamNG export / some netconvert output).
        for i = 2, #shapePoints - 1 do
            local p = shapePoints[i]
            if not near2D(p, points[#points], ENDPOINT_SNAP_M) then
                points[#points + 1] = clonePoint(p)
            end
        end
    else
        for _, p in ipairs(shapePoints) do
            if not near2D(p, fromPos, ENDPOINT_SNAP_M) and not near2D(p, toPos, ENDPOINT_SNAP_M)
                and not near2D(p, points[#points], ENDPOINT_SNAP_M) then
                points[#points + 1] = clonePoint(p)
            end
        end
    end

    if not near2D(points[#points], toPos, ENDPOINT_SNAP_M) then
        points[#points + 1] = clonePoint(toPos)
    else
        points[#points] = clonePoint(toPos)
    end
    points[1] = clonePoint(fromPos)
    return points
end

local function undirectedPairKey(from, to)
    local first, second = tostring(from), tostring(to)
    if first < second then
        return first .. '\0' .. second
    end
    return second .. '\0' .. first
end

local function importSumoFromFile(filePath, options)
    local prefix = sumoPrefix(filePath)
    local nodePath = prefix .. '.nod.xml'
    local edgePath = prefix .. '.edg.xml'
    local nodeData = importFile.readTextFile(nodePath)
    local edgeData = importFile.readTextFile(edgePath)
    if not nodeData then
        error('Unable to read SUMO node file: ' .. nodePath)
    end
    if not edgeData then
        error('Unable to read SUMO edge file: ' .. edgePath)
    end

    local nodes = {}
    local nodeCount = 0
    for attributesText in nodeData:gmatch('<node%s+([^>]-)>') do
        local attributes = parseAttributes(attributesText)
        local x, y, z = tonumber(attributes.x), tonumber(attributes.y), tonumber(attributes.z)
        if attributes.id and x and y then
            nodes[attributes.id] = vec3(x, y, z or 0.1)
            nodeCount = nodeCount + 1
        end
    end

    -- Collect edges first so reverse duplicates can keep the richer shape.
    local edgeRecords = {}
    local skipped = 0
    for attributesText in edgeData:gmatch('<edge%s+([^>]-)>') do
        local attributes = parseAttributes(attributesText)
        local from, to = attributes.from, attributes.to
        if not from or not to or not nodes[from] or not nodes[to] then
            skipped = skipped + 1
        else
            local shapePoints = parseShape(attributes.shape)
            local points = buildSumoEdgePoints(nodes[from], nodes[to], shapePoints)
            if #points > 1 then
                local laneCount = tonumber(attributes.numLanes) or 2
                local laneWidth = tonumber(attributes.laneWidth) or 3.5
                edgeRecords[#edgeRecords + 1] = {
                    id = attributes.id,
                    from = from,
                    to = to,
                    points = points,
                    width = laneCount * laneWidth,
                    shapeScore = #shapePoints
                }
            else
                skipped = skipped + 1
            end
        end
    end

    local specs = {}
    local endpointKeys = {}
    local duplicateCount = 0
    local bestByPair = {}
    local degree = {}
    for _, edge in ipairs(edgeRecords) do
        local pairKey = undirectedPairKey(edge.from, edge.to)
        local existing = bestByPair[pairKey]
        if existing then
            duplicateCount = duplicateCount + 1
            if edge.shapeScore > existing.shapeScore then
                bestByPair[pairKey] = edge
            end
        else
            bestByPair[pairKey] = edge
        end
    end

    -- Stable-ish order: follow first-seen order among winners.
    local emitted = {}
    for _, edge in ipairs(edgeRecords) do
        local pairKey = undirectedPairKey(edge.from, edge.to)
        local winner = bestByPair[pairKey]
        if winner and not emitted[pairKey] then
            emitted[pairKey] = true
            degree[edge.from] = (degree[edge.from] or 0) + 1
            degree[edge.to] = (degree[edge.to] or 0) + 1
            specs[#specs + 1] = {
                name = 'SUMO ' .. tostring(winner.id or #specs + 1),
                points = winner.points,
                width = winner.width
            }
            endpointKeys[#endpointKeys + 1] = {
                {key = winner.from, index = 1},
                {key = winner.to, index = #winner.points}
            }
        end
    end
    skipped = skipped + duplicateCount

    local junctionCount = 0
    for _, count in pairs(degree) do
        if count > 1 then
            junctionCount = junctionCount + 1
        end
    end

    local warnings = {}
    if duplicateCount > 0 then
        warnings[#warnings + 1] = tostring(duplicateCount)
            .. ' reverse or duplicate SUMO edge(s) were skipped (kept the richer shape per undirected pair)'
    end
    if nodeCount > 0 and junctionCount > 0 then
        warnings[#warnings + 1] = tostring(junctionCount)
            .. ' SUMO connection node(s) were snapped geometrically but not converted to Road Architect junctions'
    elseif nodeCount > 0 then
        warnings[#warnings + 1] =
            'SUMO junction records were not converted to Road Architect junctions (roads meet at shared endpoints only)'
    end
    return importRoads('SUMO', specs, skipped, warnings, junctionCount, options, endpointKeys)
end

M.importOsmFromFile = importOsmFromFile
M.importSumoFromFile = importSumoFromFile

return M
