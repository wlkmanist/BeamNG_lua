-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function wildcardToLuaPattern(wildcard)
  return "^" .. wildcard:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*") .. "$"
end

local function matchesAnyWildcard(value, patterns)
  if not patterns or #patterns == 0 then return true end
  for _, p in ipairs(patterns) do
    if value:match(wildcardToLuaPattern(p)) then return true end
  end
  return false
end

local function normalizeWildcardList(pattern)
  if not pattern then return {"*"} end
  return type(pattern) == "string" and {pattern} or pattern
end

local function extensionRootsForVm()
  local typeCopy = vmType
  -- for whatever reason, we decided do not name that folder game...
  if typeCopy == "game" then
    typeCopy = "ge"
  end
  return {"/lua/common/extensions/", "/lua/" .. typeCopy .. "/extensions/"}
end

local function extNameFromFile(filePath)
  local extRootStart = filePath:find("/extensions/", 1, true)
  if not extRootStart then return nil end
  local rel = filePath:sub(extRootStart + #"/extensions/"):gsub("%.lua$", "")
  return extensions.luaPathToExtName(rel), rel
end

local function discoverExtensions(wildcardList)
  local discovered, byName = {}, {}
  for _, root in ipairs(extensionRootsForVm()) do
    for _, filePath in ipairs(FS:findFiles(root, "*.lua", -1, true, false) or {}) do
      local extName, relPath = extNameFromFile(filePath)
      if extName and matchesAnyWildcard(extName, wildcardList) and not byName[extName] then
        local entry = { extName = extName, relPath = relPath, filePath = filePath }
        byName[extName] = entry
        table.insert(discovered, entry)
      end
    end
  end
  table.sort(discovered, function(a, b) return a.extName < b.extName end)
  return discovered
end

local function ensureDirectoryForFile(filePath)
  local dir = filePath:match("(.*/)")
  if dir then FS:directoryCreate(dir, true) end
end

local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local mockRegistry = nil

local function ensureMockRegistryLoaded()
  if mockRegistry then return mockRegistry end
  mockRegistry = { exact = {}, default = false }

  local ok, mod = pcall(require, "testFramework/MockGenerators")
  if ok and type(mod) == "table" then
    for key, value in pairs(mod) do
      if type(value) == "function" then
        local hookName = key:match("^generateMockData_(.+)$")
        if hookName then
          if hookName == "default" then mockRegistry.default = value
          else mockRegistry.exact[hookName] = value end
        end
      end
    end
  end
  return mockRegistry
end

local function getHookGenerator(hookName)
  local registry = ensureMockRegistryLoaded()
  return registry.exact[hookName] or registry.default, registry.exact[hookName] ~= nil
end

local function runCallsViaHookApi(hookName, calls)
  if type(calls) ~= "table" then return end
  for _, call in ipairs(calls) do
    extensions.hook(hookName, unpack(call.args or {}))
  end
end

local function runSerializationChecks(extName, moduleTable, iterations)
  local result = { serializeSec = 0, deserializeSec = 0, stable = true }
  if type(moduleTable) ~= "table" then return result end

  local hasSerialize = type(moduleTable.onSerialize) == "function" or type(moduleTable.state) == "table"
  local hasDeserialize = type(moduleTable.onDeserialize) == "function"
  if not hasSerialize and not hasDeserialize then return result end

  local baselineData
  for i = 1, iterations do
    local tS0 = os.clockhp()
    local allData = extensions.getSerializationData("extensionTest")
    local serializeData = allData and allData[extName]
    result.serializeSec = result.serializeSec + (os.clockhp() - tS0)

    if serializeData ~= nil then
      if i == 1 then baselineData = deepcopy(serializeData)
      elseif not deepEqual(baselineData, serializeData) then result.stable = false end
    end

    if hasDeserialize then
      local tD0 = os.clockhp()
      extensions.deserialize(deepcopy(allData), extName)
      result.deserializeSec = result.deserializeSec + (os.clockhp() - tD0)
    end
  end
  return result
end

local function mapSetKeys(setTable)
  local res = {}
  for k in pairs(setTable or {}) do table.insert(res, k) end
  table.sort(res)
  return res
end

local function runHookCallsViaExtensionsApi(entry, moduleTable)
  local hookTimings, hookErrors, missingHooks = {}, {}, {}
  if type(moduleTable) ~= "table" then return hookTimings, hookErrors, missingHooks end

  local hookNames = {}
  for k, v in pairs(moduleTable) do
    if type(v) == "function" and k:match("^on") then table.insert(hookNames, k) end
  end
  table.sort(hookNames)

  for _, hookName in ipairs(hookNames) do
    local generator, covered = getHookGenerator(hookName)
    if not covered then table.insert(missingHooks, hookName) end
    if generator then
      local t0 = os.clockhp()
      local ok, err = xpcall(function()
        runCallsViaHookApi(hookName, generator(hookName, entry, moduleTable))
      end, debug.traceback)
      hookTimings[hookName] = (hookTimings[hookName] or 0) + (os.clockhp() - t0)
      if not ok then hookErrors[hookName] = tostring(err) end
    end
  end
  return hookTimings, hookErrors, missingHooks
end

local function uniqueSorted(list)
  local dict, res = {}, {}
  for _, v in ipairs(list or {}) do
    if not dict[v] then dict[v] = true; table.insert(res, v) end
  end
  table.sort(res)
  return res
end

local function runExtensionOwnedTests(testManager, extName, moduleTable)
  local tests = moduleTable and moduleTable._unittests
  return type(tests) == "table" and testManager:run(tests, nil, { resultNamePrefix = extName .. "/case", suppressLogs = true }) or nil
end

local function logDetailedSummary(summary)
  local extensions = summary.extensions or {}
  log("I", "extensionTestRunner", string.format("Summary: extensions=%d pass=%d fail=%d", #extensions, summary.testPassCount or 0, summary.testFailCount or 0))

  local failedCount = 0
  for _, ext in ipairs(extensions) do
    local passChecks, failChecks = 0, 0
    for _, check in ipairs(ext.tests or {}) do
      if check.passed then passChecks = passChecks + 1 else failChecks = failChecks + 1 end
    end
    if ext.status == "failed" then failedCount = failedCount + 1 end
    log("I", "extensionTestRunner", string.format("[module] %s status=%s tests=%d/%d", ext.extName, ext.status, passChecks, passChecks + failChecks))
  end

  for _, tr in ipairs((summary.results and summary.results.testResults) or {}) do
    log(tr.passed and (tr.warningMessage and "W" or "I") or "E", "extensionTestRunner",
      string.format("[test] %s status=%s%s%s", tr.name, tr.passed and "passed" or "failed",
        tr.errorMessage and (" error=" .. tostring(tr.errorMessage)) or "",
        tr.warningMessage and (" warning=" .. tostring(tr.warningMessage)) or ""))
  end

  if failedCount == 0 then log("I", "extensionTestRunner", "All tested extensions passed") end
end

local function runOneExtension(testManager, entry, options)
  local metrics = {
    parseColdSec = 0, loadSec = 0, sandboxLoadSec = 0,
    apiUsage = { globalsRead = {}, globalsReadTypes = {}, gTableReads = {}, gTableWrites = {} },
    requiredModules = {}, requireTimingsSec = {}, mockHookSec = {},
    serializeSec = 0, deserializeSec = 0, unloadSec = 0,
  }
  local ownedTestResults

  local ok, resultsOrError = xpcall(function()
    local state = { loaded = false, moduleTable = nil, hookErrors = {}, missingHooks = {} }
    local tests = {}

    tests.test_1_parse_loadfile = function(ctx)
      ctx:setDescription("Parses the extension file directly from disk using loadfile.")
      local chunk, parseErr = loadfile(entry.filePath)
      if not chunk then ctx:fail(tostring(parseErr)) end
    end

    tests.test_2_sandbox_globals = function(ctx)
      ctx:setDescription("Executes in sandbox and verifies no unintended global writes/leaks.")
      local sandbox = testManager:runSandboxedFunction(function()
        local chunk, err = loadfile(entry.filePath)
        if not chunk then error("sandbox_load_error: " .. tostring(err)) end
        setfenv(chunk, getfenv())
        return chunk()
      end)
      metrics.sandboxLoadSec = sandbox.loadSec

      if sandbox.apiUsage then
        metrics.apiUsage.globalsRead = mapSetKeys(sandbox.apiUsage.globalsRead)
        metrics.apiUsage.globalsReadTypes = sandbox.apiUsage.globalsReadTypes or {}
        metrics.apiUsage.gTableReads = mapSetKeys(sandbox.apiUsage.gTableReads)
        metrics.apiUsage.gTableWrites = mapSetKeys(sandbox.apiUsage.gTableWrites)
        local written = mapSetKeys(sandbox.apiUsage.globalsWritten)
        if #written > 0 then metrics.apiUsage.globalsWritten = written end
      end

      metrics.requiredModules = mapSetKeys(sandbox.requiredModules)
      metrics.requireTimingsSec = sandbox.requireTimings or {}

      if not sandbox.ok then
        ctx:fail(type(sandbox.error) == "table" and jsonEncode(sandbox.error) or tostring(sandbox.error))
      end

      local created, modified = mapSetKeys(sandbox.globalsCreated), mapSetKeys(sandbox.globalsModified)
      if #created > 0 or #modified > 0 then
        ctx:fail("created={" .. table.concat(created, ",") .. "} modified={" .. table.concat(modified, ",") .. "}")
      end
    end

    tests.test_3_load = function(ctx)
      ctx:setDescription("Loads the extension through extensions.load and checks global exposure.")
      local ok, err = xpcall(function() extensions.load(entry.extName) end, debug.traceback)
      if not ok then ctx:fail(tostring(err)) end
      state.moduleTable = _G[entry.extName]
      if not state.moduleTable then ctx:fail("module_not_available_in_global_scope") end
      state.loaded = true
    end

    tests.test_4_extension_tests = function(ctx)
      ctx:setDescription("Runs extension-owned test cases declared by the module.")
      if not state.loaded then ctx:fail("extension_not_loaded") end
      ownedTestResults = runExtensionOwnedTests(testManager, entry.extName, state.moduleTable)
      if ownedTestResults and (ownedTestResults.testFailCount or 0) > 0 then
        ctx:fail("failed_tests=" .. tostring(ownedTestResults.testFailCount))
      end
    end

    tests.test_5_hook_calls = function(ctx)
      ctx:setDescription("Invokes discovered lifecycle hooks and checks for hook runtime errors.")
      if not state.loaded then ctx:fail("extension_not_loaded") end
      local timings, errors, missing = runHookCallsViaExtensionsApi(entry, state.moduleTable)
      metrics.mockHookSec = timings
      state.hookErrors = errors
      state.missingHooks = uniqueSorted(missing)
      if next(state.hookErrors) then ctx:fail(jsonEncode(state.hookErrors)) end
    end

    tests.test_6_mock_generators_coverage = function(ctx)
      ctx:setDescription("Verifies all discovered on* hooks have mock generator coverage.")
      if #state.missingHooks > 0 then ctx:fail("missing={" .. table.concat(state.missingHooks, ",") .. "}") end
    end

    tests.test_7_serialize_stability = function(ctx)
      ctx:setDescription("Checks serialized data is stable across repeated iterations.")
      if not state.loaded then ctx:fail("extension_not_loaded") end
      local ser = runSerializationChecks(entry.extName, state.moduleTable, options.serializationIterations)
      metrics.serializeSec, metrics.deserializeSec = ser.serializeSec, ser.deserializeSec
      if not ser.stable then ctx:fail("serialized_data_changed_between_iterations") end
    end

    tests.test_8_unload = function(ctx)
      ctx:setDescription("Unloads the extension and validates unload path completes successfully.")
      local ok, err = xpcall(function() extensions.unload(entry.extName) end, debug.traceback)
      if not ok then ctx:fail(tostring(err)) end
    end

    local results = testManager:run(tests, nil, { resultNamePrefix = entry.extName, suppressLogs = true, captureLogs = true })

    for _, tr in ipairs(results.testResults or {}) do
      local checkName = tr.name:match("test_%d+_(.+)$") or tr.name
      tr.name = entry.extName .. "/" .. checkName
      if checkName == "parse_loadfile" then metrics.parseColdSec = tr.duration or 0
      elseif checkName == "load" then metrics.loadSec = tr.duration or 0
      elseif checkName == "unload" then metrics.unloadSec = tr.duration or 0
      end
    end
    return results
  end, debug.traceback)

  if not ok then
    return true, {
      testPassCount = 0, testFailCount = 1, totalDuration = 0,
      testResults = {{ name = entry.extName .. "/runner_internal", passed = false, duration = 0, errorMessage = tostring(resultsOrError), description = "Internal test-runner guard; fails if runner itself throws.", logs = {} }}
    }, metrics, ownedTestResults
  end

  return (resultsOrError.testFailCount or 0) > 0, resultsOrError, metrics, ownedTestResults
end

function M.run(testManager, options)
  options = options or {}
  local vmNamespace = (getLuaNamespacesForVmType()[2] or ""):gsub("^/lua/", ""):gsub("/$", "")
  local wildcardList = normalizeWildcardList(options.pattern)
  local outputPrefix = options.outputPrefix or "/junit-results/lua-extension-tests"
  local iterations = options.serializationIterations or 3

  local summary = {
    vm = vmType, namespace = vmNamespace, serializationIterations = iterations,
    extensions = {}, testPassCount = 0, testFailCount = 0, failedExtensionCount = 0
  }
  local aggregated = { testPassCount = 0, testFailCount = 0, totalDuration = 0, testResults = {} }

  for _, entry in ipairs(discoverExtensions(wildcardList)) do
    local failed, extensionResults, metrics, ownedTestResults = runOneExtension(testManager, entry, { serializationIterations = iterations })

    local extensionTests, extensionOwnedLogs = {}, {}
    for _, tr in ipairs(extensionResults.testResults or {}) do
      table.insert(extensionTests, tr); table.insert(aggregated.testResults, tr)
      if tr.name == (entry.extName .. "/extension_tests") then extensionOwnedLogs = tr.logs or {} end
      if tr.passed then aggregated.testPassCount = aggregated.testPassCount + 1 else aggregated.testFailCount = aggregated.testFailCount + 1 end
    end
    aggregated.totalDuration = aggregated.totalDuration + (extensionResults.totalDuration or 0)

    if ownedTestResults and ownedTestResults.testResults then
      for _, tr in ipairs(ownedTestResults.testResults) do
        tr.description = tr.description or "Extension-owned test case provided by the module."
        tr.logs = tr.logs or extensionOwnedLogs
        if tr.expectedToFail == false then tr.expectedToFail = nil end
        table.insert(extensionTests, tr); table.insert(aggregated.testResults, tr)
      end
      aggregated.testPassCount = aggregated.testPassCount + (ownedTestResults.testPassCount or 0)
      aggregated.testFailCount = aggregated.testFailCount + (ownedTestResults.testFailCount or 0)
      aggregated.totalDuration = aggregated.totalDuration + (ownedTestResults.totalDuration or 0)
    end

    table.insert(summary.extensions, {
      extName = entry.extName, relPath = entry.relPath, status = failed and "failed" or "passed",
      tests = extensionTests, metrics = metrics, hasExtensionTests = ownedTestResults ~= nil,
    })
    if failed then summary.failedExtensionCount = summary.failedExtensionCount + 1 end
  end

  summary.testPassCount, summary.testFailCount = aggregated.testPassCount, aggregated.testFailCount

  local resultsJsonFile = outputPrefix .. ".json"
  ensureDirectoryForFile(resultsJsonFile)
  summary.results = aggregated
  summary.outputFiles = { resultsJson = resultsJsonFile }

  local detailedSummary = {}
  for _, ext in ipairs(summary.extensions) do
    detailedSummary[ext.extName] = {
      vm = summary.vm, namespace = summary.namespace, serializationIterations = summary.serializationIterations,
      relPath = ext.relPath, status = ext.status, hasExtensionTests = ext.hasExtensionTests,
      tests = ext.tests, metrics = ext.metrics
    }
  end
  jsonWriteFile(resultsJsonFile, detailedSummary, true)

  if options.writeAutoLog then
    local ok, autoLog = pcall(require, "extensions/test/util/autoTest")
    if ok and type(autoLog) == "table" and autoLog.writeTestResultsToLog then autoLog.writeTestResultsToLog(summary) end
  end

  local runFailed = (aggregated.testFailCount > 0) or (summary.failedExtensionCount > 0)
  log(runFailed and "E" or "I", "extensionTestRunner", string.format("Lua extension tests %s: tests=%d extensions=%d", runFailed and "failed" or "passed", runFailed and aggregated.testFailCount or aggregated.testPassCount, summary.failedExtensionCount))
  log("I", "extensionTestRunner", "Results JSON: " .. tostring(resultsJsonFile))
  logDetailedSummary(summary)

  return summary
end

function M.testExtensions(pattern, options)
  options = options or {}
  local testManager = require("testFramework/TestManager")
  local extensionNamePatterns = {pattern}
  if #discoverExtensions(extensionNamePatterns) == 0 then
    log("E", "extensionTestRunner", "No extensions match pattern: " .. tostring(pattern))
    return
  end

  options.pattern = extensionNamePatterns
  return M.run(testManager, options)
end

return M
