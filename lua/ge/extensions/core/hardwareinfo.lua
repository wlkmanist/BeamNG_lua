-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local diskUsage = nil
local diskUsageRunning = false

local function getInfo()
  local res = {}

  res.os = Engine.Platform.getOSInfo()
  res.pwr = Engine.Platform.getPowerInfo()
  res.os.warnings = {}
  res.mem = Engine.Platform.getMemoryInfo()
  res.mem.warnings = {}

  -- enhance the memory information
  if res.os.gamearch == 'x64' then
    res.mem.processPhysUsedPercent = res.mem.processPhysUsed / res.mem.osPhysAvailable
    res.mem.osPhysUsedPercent = res.mem.osPhysUsed / res.mem.osPhysAvailable
    res.mem.processVirtUsedPercent = res.mem.processVirtUsed / res.mem.osVirtAvailable
    res.mem.osVirtUsedPercent = res.mem.osVirtUsed / res.mem.osVirtAvailable
  end

  -- enhance linux information
  if res.os.type == 'linux' then
    res.os.windowsystem = Engine.Platform.getVideoDriver()
  end

  if not disableHwWarnings then
    local freememlow = 1 -- in GB
    local minmem = 16 -- in GB
    local minmemThreshold = 0.6 * minmem -- give steamdeck's shared memory system some leeway, since it reports 14gb of ram (below minspecs)
    --res.mem.osPhysAvailable = minmemThreshold*1024*1024*1024 - 1             -- uncomment to force warning
    --res.mem.osPhysUsed = res.mem.osPhysAvailable*1024*1024*1024 - 1 -- uncomment to force warning
    if res.mem.osPhysAvailable < minmemThreshold*1024*1024*1024 then
      table.insert(res.mem.warnings, {type = 'warn', msg = 'minmem', context = { amount = minmem } })
    elseif res.mem.osPhysAvailable - res.mem.osPhysUsed < freememlow*1024*1024*1024 then
      table.insert(res.mem.warnings, {type = 'warn', msg = 'freememlow', context = { amount = freememlow } })
    end
  end

  -- CPU
  res.cpu = Engine.Platform.getCPUInfo()
  res.cpu.warnings = {}

  -- GPU
  res.gpu = Engine.Platform.getGPUInfo()
  res.gpu.warnings = {}

  -- warning test:
  --res.gpu.name = 'Intel HD'
  --res.gpu.name = 'AMD Radeon R9 M295X'
  --res.gpu.memoryMB = 256

  if not disableHwWarnings then
    local lowercaseGpuName = res.gpu.name:lower()
    if lowercaseGpuName:find('intel') and not lowercaseGpuName:find('arc%(tm%)') and not lowercaseGpuName:find('bmg') then
      table.insert(res.gpu.warnings, {type = 'error', msg = 'intelgpu'})
    end
  end

  -- warning tests:
  --res.os.versionMajor = 5
  --res.os.shortname = 'WindowsXP'
  --res.os.type = 'os_type'
  -- res.os.shortname = 'random'
  -- res.os.fullname = 'fullname'

  if core_modmanager.isReady() then
    res.mods = core_modmanager.getStats()
    res.mods.warnings = {}
    if res.mods.unpacked > 20 or res.mods.zip > 150 then
      table.insert(res.mods.warnings, {type = 'error', msg = 'toomanymods'})
    elseif res.mods.unpacked > 10 or res.mods.zip > 100 then
      table.insert(res.mods.warnings, {type = 'warn', msg = 'toomanymods'})
    end
  end

  if sailingTheHighSeas then
    res.hs = {warnings={}}
    table.insert(res.hs.warnings, {type = 'warn', msg = 'highseas'})
  end

  res.disk={}
  res.disk.warnings = {}
  res.disk.freeSpace = Engine.Platform.getDiskFreeSpace()
  res.disk.usage = diskUsage
  local lowfreespace = 1 * 1024 * 1024 * 1024 -- 1 GB
  if res.disk.freeSpace.root < lowfreespace or res.disk.freeSpace.user < lowfreespace then --minimun on each disk 1 GB free
    table.insert(res.disk.warnings, {type = 'warn', msg = 'lowfreespace'})
  end

  if res.os.type == 'linux' then
    res.disk.caseSensiGame = FS:isGamePathCaseSensitive()
    res.disk.caseSensiUser = FS:isUserPathCaseSensitive()
  end

  local originalSize = -1
  if FS:fileExists("integrity.json") then
    local manifest = jsonReadFile("integrity.json")
    if manifest and manifest.format == 1 and manifest.integritydata then
      for _,v in pairs(manifest.integritydata) do
        originalSize = originalSize + v[2]
      end
    end
  end

  if res.disk.usage and diskUsage and originalSize>0 then
    M.runDiskUsage() --send the data we saved
    local rootsize = nil
    for _,v in pairs(diskUsage) do
      if v.name == "rootpath" then
        rootsize = v.size
        break
      end
    end
    log('D', 'hardwareinfo.disk', ' originalSize='..tostring(originalSize).."   rootsize="..tostring(rootsize) )
    if sailingTheHighSeas or (rootsize and (originalSize - 10485760 > rootsize or rootsize > originalSize + 268435456)) then -- allow a size difference of -100mb and +256mb because of `_CommonRedist`
      table.insert(res.disk.warnings, {type = 'warn', msg = 'rootmodified'})
    end
  end
  if string.find( FS:getUserPath(), ".:\\Users\\.-\\OneDrive") then
    table.insert(res.disk.warnings, {type = 'warn', msg = 'onedrive'})
  end

  local stateLevels = { ['ok'] = 1, ['warn'] = 2, ['error'] = 3 }
  res.globalState = 'ok'
  for k, v in pairs(res) do
    if type(v) == 'table' then
      v.state = 'ok'
      if v.warnings and #v.warnings > 0 then
        for k2,v2 in pairs(v.warnings) do
          if settings.getValue('PerformanceWarnings.' .. tostring(v2.msg)) then
            v2.ack = true
          end
          if stateLevels[v2.type] > stateLevels[v.state] then
            v.state = v2.type
          end
          if stateLevels[v2.type] > stateLevels[res.globalState] then
            res.globalState = v2.type
          end
        end
      end
    end
  end

  res.sailingTheHighSeas = sailingTheHighSeas
  if res.mods == nil then res.mods = {state="load"} end

  return res
end

local function requestInfo()
  local res = getInfo()

  --dump(res)
  guihooks.trigger('HardwareInfo', res)
end

local function logInfo(filename)
  local hw = {
    mem = Engine.Platform.getMemoryInfo(),
    cpu = Engine.Platform.getCPUInfo(),
    gpu = Engine.Platform.getGPUInfo(),
    os = Engine.Platform.getOSInfo(),
    pwr = Engine.Platform.getPowerInfo(),
  }
  jsonWriteFile(filename, hw, true)
end

local function runPhysicsBenchmark()
  --local fn = '/temp/bananabench.json'
  log('D', 'hardwareinfo.runPhysicsBenchmark', 'runPhysicsBenchmark()')
  local fn = 'bananabench.json'
  FS:removeFile(fn)
  Engine.Platform.runBananaBench(fn)
end

local function onBananaBenchReady(outFilename)
  -- this is called once the banchmark is done
  log('D', 'hardwareinfo.onBananaBenchReady', 'onBananaBenchReady: ' .. tostring(outFilename))
  if not FS:fileExists(outFilename) then
    guihooks.trigger('BananaBenchReady', nil)
    return nil
  end
  local data = jsonReadFile(outFilename)
  guihooks.trigger('BananaBenchReady', data)
end

local function readBananabenchFile()
  return jsonReadFile('bananabench.json')
end

local function latestBenchmarkExists()
  return FS:fileExists('bananabench.json')
end

local function acknowledgeWarning(warning)
  settings.setValue('PerformanceWarnings.' .. warning, true)
  requestInfo()
end

local function onModManagerReady()
  requestInfo()
end

local function diskInfoCallback(data)
  -- log('D', 'hardwareinfo.diskInfoCallback', 'data: ' .. dumps(data))
  guihooks.trigger('diskInfoCallback', data)
  if not data.running then
    diskUsage = diskUsage or {}
    table.insert(diskUsage,data)
    diskUsageRunning = false
    requestInfo()
    --log('D', 'hardwareinfo.diskInfoCallback', 'diskUsage: ' .. dumps(diskUsage))
  else
    diskUsageRunning = true
  end
end

local function runDiskUsage()
  if diskUsage or diskUsageRunning then
    --log('E', 'hardwareinfo.diskInfoCallback', 'DATA: ')
    if diskUsage then
      for _,v in pairs(diskUsage) do
        guihooks.trigger('diskInfoCallback', v)
      end
    end
  else
    --log('E', 'hardwareinfo.diskInfoCallback', 'RUN: ')
    Engine.Platform.runDiskUsage()
    diskUsageRunning = true
  end
end

M.getInfo = getInfo
M.requestInfo = requestInfo
M.logInfo = logInfo
M.runPhysicsBenchmark = runPhysicsBenchmark
M.onBananaBenchReady = onBananaBenchReady
M.latestBananbench = readBananabenchFile
M.latestBenchmarkExists = latestBenchmarkExists
M.acknowledgeWarning = acknowledgeWarning
M.onModManagerReady = onModManagerReady
M.diskInfoCallback = diskInfoCallback
M.runDiskUsage = runDiskUsage

return M
