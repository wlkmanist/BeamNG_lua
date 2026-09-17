-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Allows to test the objectTeleported() function, by recording or running various situations and checking how it reacts.
--
-- HOW TO record a new test (or update an existing one), in the GE lua console:
--  - extensions.test_objectTeleported_main.testName = "myTest"
--  - hide the UI (this is used to trigger recording), do something you want to capture/test, then unhide the UI (this stops and saves the recording)
--
-- HOW TO run all tests, in the GE lua console:
--  - extensions.test_objectTeleported_main.test()

local M = {}

local testDir = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('[^/\\]+$', '')
local ongoing

local function toVec(t) return vec3(t[1], t[2], t[3]) end -- frames store vecs as {x,y,z} so they're json-friendly

-- writes valid json, but keeps each recorded frame on a single line for readability
local function writeTest(name, test)
  local frames = {}
  for _, f in ipairs(test.frames) do frames[#frames + 1] = '    ' .. jsonEncode(f) end
  writeFile(testDir .. name .. '.test.json', string.format('{\n  "expected": %s,\n  "frames": [\n%s\n  ]\n}', tostring(test.expected), table.concat(frames, ',\n')))
end

-- persistent buffers, reused each frame so the per-frame path allocates nothing
local curPos, curVel, prevPos, prevVel = vec3(), vec3(), vec3(), vec3()
local wasRecording = false

-- record(true): start capturing frames. record("myName"): stop, save the scenario to disk and check it.
local function record(v)
  if v == true then
    ongoing = {expected = false, frames = {}} -- expected = whether a teleport was detected in any frame
    log('I', 'objectTeleported', 'recording started')
  elseif type(v) == 'string' then
    writeTest(v, ongoing)
    log('I', 'objectTeleported', string.format("recording saved as '%s' (%d frames, teleport=%s)", v, #ongoing.frames, tostring(ongoing.expected)))
    ongoing = nil
    M.test()
  else
    ongoing = nil
    log('I', 'objectTeleported', 'recording aborted')
  end
end

-- tests all recorded scenarios
function M.test(verbose)
  verbose = verbose ~= false
  local timer = hptimer()
  for _, file in ipairs(FS:findFiles(testDir, '*.test.json', -1, true, false)) do
    local name, test = file:match('([^/\\]+)%.test%.json$'), jsonReadFile(file)
    if verbose then log('I', 'objectTeleported', string.format("Testing %3d frames, teleport expected '%5s': %s", #test.frames, tostring(test.expected), file)) end
    local teleported = false
    for _, frame in ipairs(test.frames) do
      teleported = teleported or objectTeleported(toVec(frame.curPos), toVec(frame.prevPos), toVec(frame.prevVel), frame.dt)
    end
    if teleported ~= test.expected then -- log instead of assert, so a failing test doesn't disable the lua vm
      log('E', 'objectTeleported', string.format("Test failed: expected teleport '%5s', got '%5s': %s", tostring(test.expected), tostring(teleported), file))
    end
  end
  local durationMs = timer:stop()
  if verbose or durationMs > 200 then log((not verbose and durationMs > 200) and 'W' or 'I', 'objectTeleported', string.format("Ran all tests in %.1f ms%s", durationMs, (durationMs > 200) and ' (tests took a bit long and should be optimized)' or '')) end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  local veh = getPlayerVehicle(0)
  if not veh or dtSim <= 0 then return end -- no vehicle or paused

  local recording = not ui_visibility.get() -- record while the UI is hidden
  if recording ~= wasRecording then
    record(recording or M.testName)
    wasRecording = recording
  end

  curPos:set(veh:getPositionXYZ())
  curVel:setSub2(curPos, prevPos) curVel:setScaled(1 / dtSim)
  local teleported = objectTeleported(curPos, prevPos, prevVel, dtSim)
  if teleported then log('I', 'objectTeleported', '======== Object teleport detected! ========') end
  if ongoing then
    ongoing.expected = ongoing.expected or teleported
    table.insert(ongoing.frames, {curPos = curPos:toTable(), prevPos = prevPos:toTable(), prevVel = prevVel:toTable(), dt = dtSim})
  end
  prevPos:set(curPos)
  prevVel:set(curVel)
end

M.onUpdate = onUpdate

return M
