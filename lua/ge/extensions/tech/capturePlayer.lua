-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local logTag = 'CapturePlayer'

local lastVid = nil
local portToVid = {}
local BLOCKING_CALLS = {
  ['LoadScenario'] = 'MapLoaded',
  ['RestartScenario'] = 'ScenarioRestarted',
  ['StopScenario'] = 'ScenarioStopped',
  ['StartVehicleConnection'] = 'StartVehicleConnection',
  ['GetCurrentVehicles'] = 'GetCurrentVehicles',
  ['SpawnVehicle'] = 'VehicleSpawned',
  ['Step'] = 'Stepped'
}

local responsesFile = nil

local M = {}
M.dependencies = {'tech_techCore', 'tech_techCapture', 'core_jobsystem'}

local function parseIntermediate(file, output)
  -- state machine
  local HEADER, TIMESTAMP, CONTEXT, PAYLOAD = -1, 0, 1, 2
  local NUM_STATES = 3
  local state = HEADER
  local ctx, timestamp

  local line = file:read()
  while line do
    if #line == 0 then
      return
    end
    if state == CONTEXT then
      ctx = line
    elseif state == TIMESTAMP then
      timestamp = tonumber(line)
    elseif state == PAYLOAD then
      table.insert(output, {ctx = ctx, timestamp = timestamp, payload = line})
    end

    state = (state + 1) % NUM_STATES
    line = file:read()
  end
end

local function mergeCaptures(captureName, captureType, removeIntermediates)
  local files = tech_techCapture.getAllRelatedFiles(captureName, false, true)
  files = tech_techCapture.filterFilesByHeader(files, captureType, 'INTERMEDIATE')

  if #files == 0 then
    log('E', logTag, 'No files found for input filename ' .. captureName .. '.')
    return
  end

  local messages = {}
  for _, currFilename in ipairs(files) do
    log('D', logTag, 'Merging ' .. currFilename .. '.')
    local currFile, err = io.open(currFilename, 'r')
    if currFile == nil then
      log('E', logTag, 'Couldn\'t open ' .. currFile .. ' for reading. Original error: ' .. err)
    end
    parseIntermediate(currFile, messages)
  end

  local function compare(a, b)
    if a.timestamp ~= b.timestamp then
      return a.timestamp < b.timestamp
    end
    return a.ctx < b.ctx
  end
  table.sort(messages, compare) -- can be optimized using k-way merge, we're sorting sorted arrays

  local dirname, baseFilename, _ = path.splitWithoutExt(captureName)
  if dirname == nil then dirname = '' end
  baseFilename = baseFilename:gmatch("([^%.]+)")()
  local outputFilename = dirname .. '/' .. baseFilename .. '.log'
  local outputFile, err = io.open(outputFilename, 'w')
  if outputFile == nil then
    log('E', logTag, 'Couldn\'t open ' .. outputFilename .. ' for writing. Original error: ' .. err)
    return
  else
    if captureType == 'REQUEST' then
      outputFile:write('TECH CAPTURE v1 COMPLETE\n')
    elseif captureType == 'RESPONSE' then
      outputFile:write('TECH RESPONSE v1 COMPLETE\n')
    end
  end

  for _, message in ipairs(messages) do
    local line = message.timestamp .. '\n' .. message.ctx .. '\n' .. message.payload .. '\n'
    outputFile:write(line)
  end
  outputFile:flush()
  outputFile:close()

  if removeIntermediates then
    for _, file in ipairs(files) do
      FS:removeFile(file)
    end
  end

  log('I', logTag, 'Successfully merged into ' .. outputFilename .. '.')
  return outputFilename
end

local function waitForResponse(job, request, type)
  while true do
    local response = request.response
    if response == nil then
      job.yield()
    elseif type ~= nil and response.type ~= type then
      job.yield()
    else
      return response
    end
  end
end

-- Some dynamic BeamNG responses are needed for us to properly play the capture (the vehicle IDs, for example).
-- This function stores them.
local function synchronizeState(response)
  if response.type == 'StartVehicleConnection' then
    local veh = scenetree.findObject(response.vid)
    lastVid = veh:getID()
  end
end

local function processRequest(job, ctx, payload)
  log('D', logTag, 'Processing ' .. ctx .. ' [' .. payload.type .. ']')
  if ctx == 'GE' then
    local request = tech_techCapture.injectMessage(payload)
    local waitFor = BLOCKING_CALLS[request.type]
    if not waitFor then
      return
    end
    local response = waitForResponse(job, request, waitFor)
    synchronizeState(response)
  else
    local port = tonumber(ctx)
    if not portToVid[port] then
      portToVid[port] = lastVid
    end
    local vid = portToVid[port]
    local serializedData = string.format("tech_techCapture.injectMessage(lpack.decode(%q))", lpack.encode(payload))
    be:queueObjectLua(vid, serializedData)
  end
end

local function techCaptureJob(job, args)
  local err
  local inputFile = io.open(args.inputFilename, 'r')
  if inputFile == nil then
    log('E', logTag, 'Couldn\'t open ' .. completeInputFilename .. ' for reading. Original error: ' .. err)
    return
  end

  local dtBetweenRequests = args.dtBetweenRequests -- -1 = use timestamps diff from the file; nil = don't wait (except blocking requests); >0 = wait for n seconds

  -- state machine
  local HEADER, TIMESTAMP, CONTEXT, PAYLOAD = -1, 0, 1, 2
  local NUM_STATES = 3
  local state = HEADER
  local ctx, captureTimestamp
  local lastRealTimestamp = os.clockhp()
  local lastCaptureTimestamp = nil

  local line = inputFile:read()
  while line do
    if #line == 0 then
      return
    end
    if state == HEADER and line ~= 'TECH CAPTURE v1 COMPLETE' then
      log('E', logTag, 'Header mismatch, got ' .. line .. '.')
      return
    end
    if state == CONTEXT then
      ctx = line
    elseif state == TIMESTAMP then
      captureTimestamp = tonumber(line)
      local realTimestamp = os.clockhp()

      if dtBetweenRequests == -1 and lastCaptureTimestamp ~= nil then
        local actualWait = realTimestamp - lastRealTimestamp
        local expectedWait = captureTimestamp - lastCaptureTimestamp
        local remainingWait = expectedWait - actualWait
        if remainingWait > 0 then
          log('D', logTag, 'Sleeping for ' .. tostring(remainingWait) .. 's.')
          job.sleep(remainingWait)
        end
      end
      lastRealTimestamp = realTimestamp
      lastCaptureTimestamp = captureTimestamp
    elseif state == PAYLOAD then
      local payload = jsonDecode(line)
      processRequest(job, ctx, payload)
      if dtBetweenRequests and dtBetweenRequests > 0 then
        job.sleep(dtBetweenRequests)
      end
    end

    state = (state + 1) % NUM_STATES
    line = inputFile:read()
  end

  job.sleep(5.0) -- TODO: think of a better way how to wait until the response for the last request is written
  log('I', logTag, 'Finished playing ' .. args.inputFilename .. '.')
  tech_techCapture.disableResponseCapture()
  if args.mergeResponses then
    mergeCaptures(responsesFile .. '.log', 'RESPONSE', true)
  end
end

local function checkCaptureRequestFile(inputFilename)
  local captureType, captureMerged = tech_techCapture.getCaptureTypeFromFile(inputFilename)
  if captureType ~= 'REQUEST' then
    log('E', logTag, inputFilename .. ' is not a request file but was supplied to function that loads requests.')
    return nil
  end

  if captureMerged == 'COMPLETE' then
    return inputFilename
  end
  if captureMerged == 'INTERMEDIATE' then -- needs to be merged
    return mergeCaptures(inputFilename, 'REQUEST', true)
  end

  return nil
end

local function playCapture(inputFilename, outputPrefix, dtBetweenRequests, mergeResponses)
  if dtBetweenRequests == nil then
    dtBetweenRequests = -1 -- by default, emulate timestamps from the request file
  end
  if mergeResponses == nil then
    mergeResponses = false
  end

  local completeInputFilename = checkCaptureRequestFile(inputFilename)
  if completeInputFilename == nil then
    log('E', logTag, 'Cannot parse ' .. inputFilename .. '. Check if it exists and is a valid tech capture file.')
    return
  end

  log('I', logTag, 'Playing capture ' .. completeInputFilename .. '.')
  portToVid = {}

  if outputPrefix then
    outputPrefix = outputPrefix:gsub("%.log$", "") -- if user included the extension, remove it
    responsesFile = outputPrefix
    tech_techCapture.enableResponseCapture(outputPrefix)
  end
  local args = {
    inputFilename = completeInputFilename,
    dtBetweenRequests = dtBetweenRequests,
    mergeResponses = mergeResponses
  }
  core_jobsystem.create(techCaptureJob, 0.001, args)
end

local function onInit()
  setExtensionUnloadMode(M, 'manual')
end

M.onInit = onInit
M.mergeCaptures = mergeCaptures
M.playCapture = playCapture

return M