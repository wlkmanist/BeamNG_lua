local C = {}
C.moduleOrder = 0 -- low first, high later
C.hooks = {"onAnyMissionChanged"}
local dir

local function invertList(x)
  local n, m = #x, #x/2
  for i=1, m do
    x[i], x[n-i+1] = x[n-i+1], x[i]
  end
  return x
end

function C:executionStopped() 
  self.stopIfRec()
end

function C:executionStarted()
  dir = core_replay.getAutoReplayPath()
end

function C:getAutoReplayFiles()
  local orderedReplays = {}
  local result = {}
  for i, file in ipairs(FS:findFiles(dir, '*.rpl', 0, false, false)) do
    table.insert(orderedReplays, {date = FS:stat(file).createtime, file = file})
  end
  table.sort(orderedReplays, function(a,b) return a.date < b.date end)
  for i, file in ipairs(orderedReplays) do
    table.insert(result, file.file)
  end
  return result
end

function C:deleteReplayFile(file)
  FS:removeFile(file)
end

function C:deleteByCount()
  local files = self:getAutoReplayFiles()
  local diff = #files - settings.getValue('countReplayCapMode')
  if diff > 0 then
    for i = 1, diff + 1, 1 do
      self:deleteReplayFile(files[i])
    end
  end
end

function C:deleteByMaxSize()
  local files = self:getAutoReplayFiles()
  local totalSize = 0
  for i, file in ipairs(files) do
    totalSize = totalSize + getFileSize(file) / 1000000
  end
  for i, file in ipairs(files) do
    if totalSize < settings.getValue('maxSizeReplayCapMode') then return end

    totalSize = totalSize - getFileSize(file) / 1000000
    self:deleteReplayFile(file)
  end
end

function C:deleteOlderReplays()
  if settings.getValue('enableMissionReplayCapModes') == "maxSize" then
    self:deleteByMaxSize()
  elseif settings.getValue('enableMissionReplayCapModes') == "count" then
    self:deleteByCount()
  end
end

function C:stopIfRec()
  if core_replay.getState() == "recording" then
    core_replay.toggleAutomaticRecording()
  end
end

function C:startNewRec() 
  self:stopIfRec()
  self:deleteOlderReplays()
  if core_replay.getState() == "idle" and settings.getValue('enableMissionReplay') then
    core_replay.toggleAutomaticRecording()  
  end
end


function C:onAnyMissionChanged(state, mission)
end

return _flowgraph_createModule(C)