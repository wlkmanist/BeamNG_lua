-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- usage:
--
-- local rallyUtil = require('/lua/ge/extensions/editor/rallyEditor/util')
--

local logTag = ''

local M = {}

local autofill_blocker = '#'
local autodist_internal_level1 = '<none>'
local unknown_transcript_str = '[unknown]'
local missionRallyDir = 'rally'
local notebooksDir = 'notebooks'
local recceDir = 'recce'
local notebooksPath = missionRallyDir..'/'..notebooksDir
local reccePath = missionRallyDir..'/'..recceDir
local recceRecordSubdir = 'primary'
local generatedPacenotesDir = 'gen'
local freeformDir = 'freeform'
local structuredDir = 'structured'
local systemDir = 'system'

local rallySettingsRoot = '/settings/'..missionRallyDir
local cornerAnglesFname = '/lua/ge/extensions/gameplay/rally/corner_angles.json'
local pacenotesMetadataBasename = 'metadata.json'
local pacenotesTranscriptionsBasename = 'transcriptions.json'

local transcriptsExt = 'transcripts.json'
local defaultNotebookFname = 'primary.notebook.json'
local defaultCodriverName = 'Sophia'
local default_codriver_voice = 'british_female'
local default_codriver_language = 'english'
local default_waypoint_intersect_radius = 40

local validPunctuation = {"?", ".", "!"}

local var_db = '{db}'
local var_da = '{da}'

-- html code: #00ffdebf
local rally_flowgraph_color = ui_imgui.ImVec4(0, 1, 0.87, 0.75) -- rgba cyan
local rallyLoop_flowgraph_color = ui_imgui.ImVec4(0, 0.97, 1.0, 0.75) -- rgba blue

local extRally = 'gameplay_rally'
local extRallyLoop = 'gameplay_rallyLoop'

-- Rally Loop Active State Enum
local activeState_inactive = 'inactive'
local activeState_vehicleProximity = 'vehicleProximity'
local activeState_stageActive = 'stageActive'
local activeState_countdown = 'countdown'

local function pacenoteHashSha1(s)
  local str = hashStringSHA1(s)
  return str:sub(1, 16)
end

-- returns seconds since epoch
local function getTime()
  -- os.clockhp appears to be beamng-specific.
  return os.clockhp()
end

-- function printFields(obj)
--   for k, v in pairs(obj) do
--     -- if type(v) == "function" then
--       print(k)
--     -- end
--   end
-- end

local function normalizeName(name)
  if not name then return nil end

  -- Replace everything but letters and numbers with '_'
  name = string.gsub(name, "[^a-zA-Z0-9]", "_")

  -- Replace multiple consecutive '_' with a single '_'
  name = string.gsub(name, "(_+)", "_")

  return name
end

local function hasPunctuation(last_char)
  for _,char in ipairs(validPunctuation) do
    if last_char == char then
      return true
    end
  end

  return false
end

local function detectMissionManagerMissionId()
  if gameplay_missions_missionManager then
    return gameplay_missions_missionManager.getForegroundMissionId()
  else
    return nil
  end
end

local function detectMissionEditorMissionId()
  if editor_missionEditor then
    local selectedMission = editor_missionEditor.getSelectedMissionId()
    if selectedMission then
      return selectedMission.id
    else
      return nil
    end
  else
    return nil
  end
end

local function detectRallyEditorMissionId()
  if editor_rallyEditor then
    local selectedMissionId = editor_rallyEditor.getMissionId()
    if selectedMissionId then
      return selectedMissionId
    else
      return nil
    end
  end
end

local function missionDirHelper(missionId)
  if not missionId then
    return nil
  end

  return '/gameplay/missions/'..missionId
end


local function detectMissionIdHelper()
  local missionId = nil
  local missionDir = nil

  -- first try the mission manager.
  -- This is a running mission outside of the world editor.
  local theMissionId = detectMissionManagerMissionId()
  if theMissionId then
    log('D', logTag, 'missionId "'.. theMissionId ..'" detected from missionManager')
  else
    log('D', logTag, 'no mission detected from missionManager')
  end

  -- then try the rally editor.
  -- this is the mission loaded into the rally editor.
  if not theMissionId then
    theMissionId = detectRallyEditorMissionId()
    if theMissionId then
      log('D', logTag, 'missionId "'.. theMissionId ..'" detected from rallyEditor')
    else
      log('D', logTag, 'no mission detected from rallyEditor')
    end
  end

  -- then try the mission editor
  -- this is the selected mission in the world editor.
  if not theMissionId then
    theMissionId = detectMissionEditorMissionId()
    if theMissionId then
      log('D', logTag, 'missionId "'.. theMissionId ..'" detected from missionEditor')
    else
      log('D', logTag, 'no mission detected from editor')
    end
  end

  if not theMissionId then
    log('E', logTag, 'couldnt detect missionId')
    return nil, nil, 'missionId could not be detected'
  end

  missionId = theMissionId
  missionDir = missionDirHelper(theMissionId)

  return missionId, missionDir, nil
end

local function getNotebookFullPath(missionDir, basename)
  local notebookFname = missionDir..'/'..notebooksPath..'/'..basename
  return notebookFname
end

local function listNotebooks(missionDir)
  if not missionDir then return {} end
  local dir = missionDir..'/'..notebooksPath
  local files = FS:findFiles(dir, '*.notebook.json', -1, true, false)
  local basenames = {}
  for _, fname in ipairs(files or {}) do
    local _, basename, _ = path.split(fname)
    table.insert(basenames, basename)
  end
  table.sort(basenames)
  return basenames
end

local function createNotebook(fname)
  local newPath = require('/lua/ge/extensions/gameplay/rally/notebook/path')()
  newPath:setFname(fname)
  if not newPath:save() then
    log('E', logTag, 'error saving new notebook')
    return nil
  end

  return newPath
end

local function isBlankFile(fname)
  local contents = readFile(fname)
  return type(contents) == 'string' and string.match(contents, "^%s*$") ~= nil
end

local function loadNotebook(notebookFname)
  log('I', logTag, 'loading notebook: ' .. notebookFname)

  if not notebookFname then
    log('E', logTag, 'unable to load notebook: notebookFname is nil')
    return nil
  end

  if not FS:fileExists(notebookFname) then
    log('E', logTag, 'unable to load notebook: notebook file not found: '..notebookFname)
    return nil
  end

  local blankFile = isBlankFile(notebookFname)
  local notebook = require('/lua/ge/extensions/gameplay/rally/notebook/path')()
  notebook:setFname(notebookFname)

  if blankFile then
    log('I', logTag, 'initializing empty notebook: '..notebookFname)
    if not notebook:save() then
      log('E', logTag, 'unable to initialize empty notebook: '..notebookFname)
      return nil
    end
    notebook:setAllAdjacentNotes()
    return notebook
  end

  local json = jsonReadFile(notebookFname)
  if not json then
    log('E', logTag, 'unable to load notebook json: '..notebookFname)
    return nil
  end

  notebook:onDeserialized(json)
  notebook:setAllAdjacentNotes()

  return notebook
end

local function loadNotebookForMissionDir(missionDir, basename)
  local notebookFname = getNotebookFullPath(missionDir, basename)
  return loadNotebook(notebookFname)
end

local function loadRacePath(missionDir)
  local raceFname = missionDir..'/race.race.json'
  log('I', logTag, 'loading race: ' .. raceFname)

  if not FS:fileExists(raceFname) then
    return nil, "race file not found: "..raceFname
  end

  local racePath = require('/lua/ge/extensions/gameplay/race/path')()
  racePath:onDeserialized(jsonReadFile(raceFname))

  return racePath, nil
end


local function missionRecceDir(missionDir)
  return missionDir..'/'..reccePath
end

local function missionRecceRecordDir(missionDir)
  local rv = missionRecceDir(missionDir)..'/'..recceRecordSubdir
  return rv
end

local function missionReccePath(missionDir, basename)
  local subdir = missionRecceRecordDir(missionDir)
  local rv = subdir..'/'..basename
  return rv
end

local function drivelineFile(missionDir)
  return missionReccePath(missionDir, 'driveline.json')
end

local function finalDrivelineFile(missionDir)
  return missionDir..'/'..missionRallyDir..'/finalDriveline.json'
end

local function drivelineSplineFile(missionDir)
  return missionDir..'/'..missionRallyDir..'/drivelineSpline.json'
end

local function cutsFile(missionDir)
  return missionReccePath(missionDir, 'cuts.json')
end

local function transcriptsFile(missionDir)
  return missionReccePath(missionDir, 'transcripts.json')
end

-- args are both vec3's representing a position.
local function calculateForwardNormal(snap_pos, next_pos)
  local flip = false
  local dx = next_pos.x - snap_pos.x
  local dy = next_pos.y - snap_pos.y
  local dz = next_pos.z - snap_pos.z

  local magnitude = math.sqrt(dx*dx + dy*dy + dz*dz)
  if magnitude == 0 then
    error("The two positions must not be identical.")
  end

  local normal = vec3(dx / magnitude, dy / magnitude, dz / magnitude)

  if flip then
    normal = -normal
  end

  return normal
end

local function loadCornerAnglesFile()
  local filename = cornerAnglesFname
  local json = jsonReadFile(filename)
  if json then
    return json, nil
  else
    local err = 'unable to find corner_angles file: ' .. tostring(filename)
    log('E', 'rally', err)
    return nil, err
  end
end

local function determineCornerCall(angles, steering)
  local absSteeringVal = math.abs(steering)
  for i,angle in ipairs(angles) do
    if absSteeringVal >= angle.fromAngleDegrees and absSteeringVal < angle.toAngleDegrees then
      local direction = steering >= 0 and "L" or "R"
      local cornerCallWithDirection = angle.cornerCall..direction
      if angle.cornerCall == '_deadzone' then
        cornerCallWithDirection = 'c'
      end

    local range = angle.toAngleDegrees - angle.fromAngleDegrees
    local pct = (absSteeringVal - angle.fromAngleDegrees) / range
      return angle, string.upper(cornerCallWithDirection), pct
    end
  end
end

local function trimString(txt)
  if not txt then return txt end
  local trimmed = string.gsub(txt, "^%s*(.-)%s*$", "%1")
  return trimmed
end

local function stripBasename(thepath)
  if not thepath then return nil end

  if thepath:sub(-1) == "/" then
    thepath = thepath:sub(1, -2)
  end
  local dirname, fn, e = path.split(thepath)

  if dirname:sub(-1) == "/" then
    dirname = dirname:sub(1, -2)
  end
  return dirname
end

local function matchSearchPattern(searchPattern, stringToMatch)
  -- Escape special characters in Lua patterns except '*'
  searchPattern = searchPattern:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
  -- Replace '*' with Lua's '.*' to act as a wildcard
  searchPattern = searchPattern:gsub("%*", ".*")

  return stringToMatch:match(searchPattern) ~= nil
end

local function useNote(text)
  return text and
    text ~= '' and
    text ~= autofill_blocker and
    text ~= autodist_internal_level1
end

local function customRound(dist, round_to)
  return math.floor(dist / round_to + 0.5) * round_to
end

local function makePacenoteAudioFilename(pacenoteHash)
  return 'pacenote_'..pacenoteHash..'.ogg'
end

local function makePacenoteVariantAudioFilename(pacenoteHash, variant)
  local variantIndex = math.floor(tonumber(variant) or 1)
  if variantIndex < 1 then variantIndex = 1 end
  return 'pacenote_'..pacenoteHash..'_'..tostring(variantIndex)..'.ogg'
end

local function pacenoteAudioBasenameVariantIndex(basename)
  if type(basename) ~= 'string' then return nil end
  local variantIndex = tonumber(basename:match('_(%d+)%.ogg$') or 1) or 1
  return variantIndex > 0 and math.floor(variantIndex) or 1
end

local function customPacenoteAudioBasenameParts(basename)
  if type(basename) ~= 'string' then return nil end
  local num, letter, variant = string.match(basename, "^pacenote_(%d+)([a-z]?)_?(%d*)%.ogg$")
  if not num then return nil end
  return {
    number = tonumber(num),
    letter = letter or '',
    variant = tonumber(variant) or 0,
    basename = basename,
  }
end

local function compareCustomPacenoteAudioBasenames(a, b)
  local aParts = customPacenoteAudioBasenameParts(a)
  local bParts = customPacenoteAudioBasenameParts(b)
  if aParts and bParts then
    if aParts.number ~= bParts.number then return aParts.number < bParts.number end
    if aParts.letter ~= bParts.letter then return aParts.letter < bParts.letter end
    if aParts.variant ~= bParts.variant then return aParts.variant < bParts.variant end
  elseif aParts or bParts then
    return aParts ~= nil
  end
  return tostring(a) < tostring(b)
end

local function makeSystemPacenoteAudioFilename(systemKey, variantIndex)
  variantIndex = tonumber(variantIndex) or 1
  return 'pacenote_system_'..tostring(systemKey)..'_'..tostring(math.floor(variantIndex))..'.ogg'
end

local function getMissionName(missionId)
  -- log('D', 'rallyUtil', 'getMissionName: missionId = ' .. tostring(missionId))
  local mission = gameplay_missions_missions.getMissionById(missionId)
  if not mission then
    -- log('D', 'rallyUtil', 'getMissionName: mission not found, returning missionId')
    return missionId
  end
  -- log('D', 'rallyUtil', 'getMissionName: found mission, name = ' .. tostring(mission.name))
  return mission.name
end

local function translatedMissionName(missionName)
  -- log('D', 'rallyUtil', 'translatedMissionName: missionName = ' .. tostring(missionName))
  if not missionName then
    -- log('D', 'rallyUtil', 'translatedMissionName: missionName is nil, returning nil')
    return missionName
  end
  local translated = _tr(missionName)
  -- log('D', 'rallyUtil', 'translatedMissionName: translated = ' .. tostring(translated))
  return translated
end

local function translatedMissionNameFromId(missionId)
  -- log('D', 'rallyUtil', 'translatedMissionNameFromId: missionId = ' .. tostring(missionId))
  local missionName = getMissionName(missionId)
  if not missionName then
    -- log('D', 'rallyUtil', 'translatedMissionNameFromId: missionName not found, returning missionId')
    return missionId
  end
  local translated = translatedMissionName(missionName)
  -- log('D', 'rallyUtil', 'translatedMissionNameFromId: translated = ' .. tostring(translated))
  return translated
end

local function randomId()
  local randomStr = tostring(math.random(1, 1000000))
  local hash = hashStringSHA1(randomStr)
  return string.sub(hash, 1, 8)
end

local function getAppropriateTextColor(clr)
  return (clr[1] < 0.1 and clr[2] < 0.5 and clr[3] > 0.7) and ColorF(1, 1, 1, 1) or ColorF(0, 0, 0, 1)
end

local function arePointsEqualWithinThreshold(point1, point2, threshold)
  -- Using squared distance for performance (like BeamNG does)
  local thresholdSq = threshold * threshold
  return point1:squaredDistance(point2) <= thresholdSq
end

local function getVehFrontCenter(vehId)
  local veh = scenetree.findObjectById(vehId)
  if not veh then return nil end

  local oobb = veh:getSpawnWorldOOBB()

  -- Get front 4 corners of the bounding box
  local p0 = vec3(oobb:getPoint(0))  -- front-left
  local p1 = vec3(oobb:getPoint(1))  -- front-left-up
  local p2 = vec3(oobb:getPoint(2))  -- front-right-up
  local p3 = vec3(oobb:getPoint(3))  -- front-right

  -- Calculate and return center of front plane
  return (p0 + p1 + p2 + p3) * 0.25
end

local function getVehFrontBottom(vehId)
  local veh = scenetree.findObjectById(vehId)
  if not veh then return nil end

  local oobb = veh:getSpawnWorldOOBB()

  local fl = vec3(oobb:getPoint(0))
  local fr = vec3(oobb:getPoint(3))

  -- Calculate and return center of front plane
  return (fl + fr) * 0.5
end

local function drawVehLeadingPoint(vehId, inside)
  local color = inside and ColorF(0.2, 1.0, 0.2, 0.5) or ColorF(1.0, 0.2, 0.2, 0.5)
  local frontCenter = getVehFrontCenter(vehId)
  if not frontCenter then return end

  debugDrawer:drawSphere(frontCenter, 0.1, color, false, false)
end

local function drawVehBB(vehId)
  local veh = scenetree.findObjectById(vehId)
  if not veh then return end

  local oobb = veh:getSpawnWorldOOBB()

  -- Get all 8 corners of the bounding box
  -- Bottom 4 corners (indices 0-3)
  local p0 = vec3(oobb:getPoint(0))  -- front-left
  local p1 = vec3(oobb:getPoint(1))  -- front-left-up
  local p2 = vec3(oobb:getPoint(2))  -- front-right-up
  local p3 = vec3(oobb:getPoint(3))  -- front-right
  local p4 = vec3(oobb:getPoint(4))  -- back-left
  local p5 = vec3(oobb:getPoint(5))  -- back-left-up
  local p6 = vec3(oobb:getPoint(6))  -- back-right-up
  local p7 = vec3(oobb:getPoint(7))  -- back-right

  local color = ColorF(0.2, 0.2, 1.0, 0.8)  -- Green color
  local thickness = 3

  -- Draw bottom rectangle (4 edges)
  debugDrawer:drawLineInstance(p0, p3, thickness, color, false)
  debugDrawer:drawLineInstance(p3, p7, thickness, color, false)
  debugDrawer:drawLineInstance(p7, p4, thickness, color, false)
  debugDrawer:drawLineInstance(p4, p0, thickness, color, false)

  -- Draw top rectangle (4 edges)
  debugDrawer:drawLineInstance(p1, p2, thickness, color, false)
  debugDrawer:drawLineInstance(p2, p6, thickness, color, false)
  debugDrawer:drawLineInstance(p6, p5, thickness, color, false)
  debugDrawer:drawLineInstance(p5, p1, thickness, color, false)

  -- Draw vertical edges (4 edges)
  debugDrawer:drawLineInstance(p0, p1, thickness, color, false)
  debugDrawer:drawLineInstance(p3, p2, thickness, color, false)
  debugDrawer:drawLineInstance(p7, p6, thickness, color, false)
  debugDrawer:drawLineInstance(p4, p5, thickness, color, false)
end

local function formatTime24Hour(timeSecs, includeSeconds, includeTenths)
  -- Format time in 24-hour format as a table {time = "HH:MM"}
  -- timeSecs: seconds of day where 0 = midnight (00:00)
  if not timeSecs then return {time = "N/A"} end

  local hours24 = math.floor(timeSecs / 3600) % 24
  local minutes = math.floor((timeSecs % 3600) / 60)
  local seconds = math.floor(timeSecs % 60)
  local tenths = math.floor((timeSecs % 1) * 10)

  local timeStr
  if includeSeconds then
    if includeTenths then
      timeStr = string.format("%02d:%02d:%02d.%d", hours24, minutes, seconds, tenths)
    else
      timeStr = string.format("%02d:%02d:%02d", hours24, minutes, seconds)
    end
  else
    timeStr = string.format("%02d:%02d", hours24, minutes)
  end

  return {time = timeStr}
end

local function formatTime12Hour(timeSecs, includeSeconds, includeTenths)
  -- Format time in 12-hour format with AM/PM as a table {time = "HH:MM", ampm = "AM"}
  -- timeSecs: seconds of day where 0 = midnight (00:00)
  if not timeSecs then return {time = "N/A", ampm = ""} end

  local hours24 = math.floor(timeSecs / 3600) % 24
  local minutes = math.floor((timeSecs % 3600) / 60)
  local seconds = math.floor(timeSecs % 60)
  local tenths = math.floor((timeSecs % 1) * 10)

  local hours12 = hours24 % 12
  if hours12 == 0 then hours12 = 12 end
  local ampm = hours24 < 12 and "AM" or "PM"

  local timeStr
  if includeSeconds then
    if includeTenths then
      timeStr = string.format("%02d:%02d:%02d.%d", hours12, minutes, seconds, tenths)
    else
      timeStr = string.format("%02d:%02d:%02d", hours12, minutes, seconds)
    end
  else
    timeStr = string.format("%02d:%02d", hours12, minutes)
  end

  return {time = timeStr, ampm = ampm}
end

local function formatTimeFromSeconds(timeSecs, includeSeconds, includeTenths)
  -- Format time in both 24-hour and 12-hour formats (e.g. "14:30:45 / 02:30:45 PM")
  -- timeSecs: seconds of day where 0 = midnight (00:00)
  -- includeSeconds: if true, format as HH:MM:SS, otherwise HH:MM
  -- includeTenths: if true, format as HH:MM:SS.T
  if not timeSecs then return "N/A" end

  local time24 = formatTime24Hour(timeSecs, includeSeconds, includeTenths)
  local time12 = formatTime12Hour(timeSecs, includeSeconds, includeTenths)

  return time24 .. " / " .. time12
end

-- vars
M.rallySettingsRoot = rallySettingsRoot
M.missionRallyDir = missionRallyDir
M.autodist_internal_level1 = autodist_internal_level1
M.autofill_blocker = autofill_blocker
M.default_codriver_language = default_codriver_language
M.default_waypoint_intersect_radius = default_waypoint_intersect_radius
M.defaultCodriverName = defaultCodriverName
M.defaultNotebookFname = defaultNotebookFname
M.default_codriver_voice = default_codriver_voice
M.notebooksDir = notebooksDir
M.recceDir = recceDir
M.recceRecordSubdir = recceRecordSubdir
M.notebooksPath = notebooksPath
M.pacenotesMetadataBasename = pacenotesMetadataBasename
M.pacenotesTranscriptionsBasename = pacenotesTranscriptionsBasename
M.transcriptsExt = transcriptsExt
M.unknown_transcript_str = unknown_transcript_str
M.validPunctuation = validPunctuation
M.var_db = var_db
M.var_da = var_da

-- funcs
M.calculateForwardNormal = calculateForwardNormal
M.detectMissionEditorMissionId = detectMissionEditorMissionId
M.detectMissionIdHelper = detectMissionIdHelper
M.detectMissionManagerMissionId = detectMissionManagerMissionId
M.missionDirHelper = missionDirHelper
M.determineCornerCall = determineCornerCall
M.loadNotebook = loadNotebook
M.loadNotebookForMissionDir = loadNotebookForMissionDir
M.createNotebook = createNotebook
M.loadRacePath = loadRacePath
M.getTime = getTime
M.hasPunctuation = hasPunctuation
M.loadCornerAnglesFile = loadCornerAnglesFile
M.matchSearchPattern = matchSearchPattern
M.missionRecceRecordDir = missionRecceRecordDir
M.missionReccePath = missionReccePath
M.generatedPacenotesDir = generatedPacenotesDir
M.freeformDir = freeformDir
M.structuredDir = structuredDir
M.systemDir = systemDir

M.getAppropriateTextColor = getAppropriateTextColor

M.drivelineFile = drivelineFile
M.finalDrivelineFile = finalDrivelineFile
M.drivelineSplineFile = drivelineSplineFile
M.cutsFile = cutsFile
M.transcriptsFile = transcriptsFile

M.pacenoteHashSha1 = pacenoteHashSha1
M.normalizeName = normalizeName
M.trimString = trimString
M.stripBasename = stripBasename
M.useNote = useNote
M.customRound = customRound

M.makePacenoteAudioFilename = makePacenoteAudioFilename
M.makePacenoteVariantAudioFilename = makePacenoteVariantAudioFilename
M.pacenoteAudioBasenameVariantIndex = pacenoteAudioBasenameVariantIndex
M.customPacenoteAudioBasenameParts = customPacenoteAudioBasenameParts
M.compareCustomPacenoteAudioBasenames = compareCustomPacenoteAudioBasenames
M.makeSystemPacenoteAudioFilename = makeSystemPacenoteAudioFilename
M.getNotebookFullPath = getNotebookFullPath
M.listNotebooks = listNotebooks

M.getMissionName = getMissionName
M.translatedMissionName = translatedMissionName
M.translatedMissionNameFromId = translatedMissionNameFromId
M.rally_flowgraph_color = rally_flowgraph_color
M.rallyLoop_flowgraph_color = rallyLoop_flowgraph_color
M.randomId = randomId
M.arePointsEqualWithinThreshold = arePointsEqualWithinThreshold

M.extRally = extRally
M.extRallyLoop = extRallyLoop

M.activeState_inactive = activeState_inactive
M.activeState_vehicleProximity = activeState_vehicleProximity
M.activeState_stageActive = activeState_stageActive
M.activeState_countdown = activeState_countdown

M.getVehFrontCenter = getVehFrontCenter
M.getVehFrontBottom = getVehFrontBottom
M.drawVehLeadingPoint = drawVehLeadingPoint
M.drawVehBB = drawVehBB
M.formatTime24Hour = formatTime24Hour
M.formatTime12Hour = formatTime12Hour
M.formatTimeFromSeconds = formatTimeFromSeconds

return M