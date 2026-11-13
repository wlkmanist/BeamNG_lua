-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


-- Reads a caller-supplied path that may be a virtual FS path or a native absolute path
-- under the game/user mounts. Sandboxed io.open/readFile only see the VFS; absolute paths
-- outside those mounts must be staged into /temp/ by the tech bridge (fileContent).

local M = {}

local function normalizeSeparators(filePath)
    return filePath:gsub('\\', '/')
end

local function readTextFile(filePath)
    if type(filePath) ~= 'string' or filePath == '' then
        return nil
    end

    local tried = normalizeSeparators(filePath)

    local data = readFile(tried)
    if data then
        return data
    end

    if tried ~= filePath then
        data = readFile(filePath)
        if data then
            return data
        end
    end

    if FS and FS.native2Virtual then
        local virtualPath = FS:native2Virtual(filePath)
        if (not virtualPath or virtualPath == '') and tried ~= filePath then
            virtualPath = FS:native2Virtual(tried)
        end
        if type(virtualPath) == 'string' and virtualPath ~= '' then
            data = readFile(virtualPath)
            if data then
                return data
            end
        end
    end

    local f, err = io.open(tried, 'rb')
    if not f then
        f, err = io.open(filePath, 'rb')
    end
    if not f then
        return nil
    end
    data = f:read('*a')
    f:close()
    return data
end

local function stageText(filePath, fileContent)
    if fileContent ~= nil and type(fileContent) ~= 'string' then
        fileContent = tostring(fileContent)
    end
    if type(fileContent) ~= 'string' or fileContent == '' then
        return filePath, false
    end
    local name = tostring(filePath):match('[^/\\]+$') or 'import.bin'
    local dir = '/temp/roadArchitectImport'
    if FS and FS.directoryCreate then
        FS:directoryCreate(dir, true)
    end
    local staged = dir .. '/' .. name
    if not writeFile(staged, fileContent) then
        error('Unable to stage import file to ' .. staged)
    end
    return staged, true
end

-- Sync World Editor APIs needed for import/finalize without opening the UI.
-- setEditorActive is deferred across splash frames, so it cannot satisfy a
-- same-request BeamNGpy import. initializeModules creates history; preferences
-- attach during full activate via loadPreferences — ensurePreferencesApi covers
-- the headless case (roadRiver.getPreference during DecalRoad finalize).
local function ensureEditorHistory()
    if not editor then
        extensions.load('editor_main')
    end
    if not editor then
        error('Road Architect import requires World Editor (editor_main could not be loaded)')
    end
    if not editor.history then
        if editor.initializeModules then
            editor.initializeModules()
        end
        if not editor.history then
            error('Road Architect import could not initialize World Editor history')
        end
    end
    if not editor.getPreference then
        if editor.ensurePreferencesApi then
            editor.ensurePreferencesApi()
        elseif editor.loadPreferences then
            editor.loadPreferences()
        end
        if not editor.getPreference then
            error('Road Architect import could not initialize editor preferences')
        end
    end
end

-- Lays DecalRoads / meshes, reloads collision, and rebuilds the navgraph.
-- Same work as Road Architect's Render/finalise toggle, without opening the UI.
-- options.finalize must be true (tech/BeamNGpy default); editor UI imports omit it.
local function maybeFinalise(options)
    if not options or options.finalize ~= true then
        return false, nil
    end
    if not scenetree or not scenetree.MissionGroup then
        return false, 'finalize requires a loaded level (MissionGroup missing)'
    end
    local roadMgr = require('editor/roadArchitect/roads')
    -- A prior finalise leaves a named SimGroup; rebuild cleanly instead of duplicating.
    if scenetree.findObject('Road Architect') or scenetree.findObject('Road Architect - Road 1') then
        roadMgr.unfinalise()
    end
    roadMgr.finalise()
    return true, nil
end

M.readTextFile = readTextFile
M.stageText = stageText
M.ensureEditorHistory = ensureEditorHistory
M.maybeFinalise = maybeFinalise

return M
