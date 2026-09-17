--[[
  Unit Test Manager for the BeamNG
  Copyright 2024 BeamNG GmbH, Thomas Fischer <tfischer@beamng.gmbh>

  This module provides a simple test manager for running unit tests
  It collects test functions, executes them, logs the results, and outputs the results
  in JUnit XML format for integration with other tools.

  Usage:
    - Define your test functions in a separate table.
    - Each test function should be named starting with "test".
    - If a test is expected to fail, append "_shouldFail" to its name.
    - Use the TestManager to run your tests.

  Example:
    -- See the example usage at the end of this file.


    -- extensions.testFramework_TestManager.runTestFiles()
]]

-- Import required modules
local function getLuaNamespacesForVmType()
  local typeCopy = vmType
  -- for whatever reason, we decided do not name that folder game...
  if typeCopy == "game" then
    typeCopy = "ge"
  end
  return {"/lua/common/", "/lua/" .. typeCopy .. "/"}
end

-- TestManager class
local TestManager = {
  -- Log levels
  LogAlways = 1,
  LogErrors = 2,
  LogFails = 3,

  currentCtx = nil,

  __internal = {
    LogDefault = 1, -- Default to LogAlways
    testPassCount = 0,
    testFailCount = 0,
    testResults = {}, -- Store individual test results
  },

  drainFrameLogs = function(self)
    local ok, rows = pcall(Engine.getFrameLog)
    if not ok or type(rows) ~= "table" then
      return {}
    end
    local captured = {}
    for _, row in ipairs(rows) do
      if type(row) == "table" then
        table.insert(captured, {
          timestamp = row[1],
          level = tostring(row[2] or ""),
          origin = tostring(row[3] or ""),
          message = tostring(row[4] or ""),
        })
      end
    end
    return captured
  end,

  logsContainErrors = function(self, logs)
    for _, row in ipairs(logs or {}) do
      if tostring(row.level or ""):sub(1, 1):upper() == "E" then
        return true
      end
    end
    return false
  end,

  --[[
    Sets the default log level.

    @param self The TestManager instance.
    @param logLevel The desired log level.
  ]]
  setLogDefault = function(self, logLevel)
    self.__internal.LogDefault = logLevel
  end,

  --[[
    Runs all .test.lua files found in the game directory.
    @param self The TestManager instance.
    @param pattern Optional pattern to filter files or tests.
    @param options Optional table of options. Set writeResults=true to write a
      <file>.results.json next to each test file (off by default).
  ]]
  runTestFiles = function(self, pattern, options)
    options = options or {}
    local searchPaths = getLuaNamespacesForVmType()

    local testFiles = {}
    local seen = {}
    for _, searchPath in ipairs(searchPaths) do
      for _, file in ipairs(FS:findFiles(searchPath, '*.test.lua', -1, true, false) or {}) do
        if not seen[file] then
          seen[file] = true
          table.insert(testFiles, file)
        end
      end
    end
    local allResults = {
      testPassCount = 0,
      testFailCount = 0,
      totalDuration = 0,
      files = {}
    }

    --dump{'testFiles', testFiles}

    for _, file in ipairs(testFiles) do
      local fileMatches = not pattern or string.find(file, pattern)

      -- Load the file
      local chunk, err = loadfile(file)
      if chunk then
        -- Execute the chunk to get the module table
        local ok, module = pcall(chunk)
        if ok and type(module) == 'table' then
           -- Check if we should run at all
           local shouldRun = fileMatches
           if not shouldRun then
             -- Check if any test matches pattern
             for name, func in pairs(module) do
               if type(func) == "function" and name:match("^test") and string.find(name, pattern) then
                 shouldRun = true
                 break
               end
             end
           end

           if shouldRun then
             local runOptions = {
               suppressLogs = false,
               resultNamePrefix = file:gsub("^/", ""),
               resultNameSeparator = "@",
               context = file
             }
             if not fileMatches then
               runOptions.testPattern = pattern
             end

            local fileResults = self:run(module, nil, runOptions)
            if options.writeResults then
              jsonWriteFile(file .. ".results.json", {
                results = fileResults.testResults,
                stats = {
                  pass = fileResults.testPassCount,
                  fail = fileResults.testFailCount,
                  duration = fileResults.totalDuration,
                  garbageBytes = fileResults.totalGarbageBytes or 0,
                  timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }
              }, true)
            end

             if fileResults.testPassCount > 0 or fileResults.testFailCount > 0 then
               -- Aggregate results
               allResults.testPassCount = allResults.testPassCount + fileResults.testPassCount
               allResults.testFailCount = allResults.testFailCount + fileResults.testFailCount
               allResults.totalDuration = allResults.totalDuration + fileResults.totalDuration

               table.insert(allResults.files, {
                 file = file,
                 results = fileResults
               })
             end
           end
        else
           log('E', 'TestManager', 'Failed to execute test file: ' .. file .. ' - ' .. tostring(module))
        end
      else
        log('E', 'TestManager', 'Failed to load test file: ' .. file .. ' - ' .. tostring(err))
      end
    end

    return allResults
  end,

  --[[
    Runs the provided tests.

    @param self The TestManager instance.
    @param tests A table containing test functions.
    @param outputFile Optional. The file path to output the test results in JUnit XML format.
  ]]
  run = function(self, tests, outputFile, options)
    options = options or {}
    local resultNamePrefix = options.resultNamePrefix
    local writeXml = options.writeXml == true
    local suppressLogs = options.suppressLogs == true
    local captureLogs = options.captureLogs == true
    local failOnErrorLogs = options.failOnErrorLogs == true
    local testPattern = options.testPattern
    local context = options.context or resultNamePrefix or outputFile or "unknown"
    local enableJit = options.enableJit == true
    local tlog = function(level, origin, message)
      if not suppressLogs then
        log(level, origin, message)
      end
    end
    local formatDurationMs = function(ms)
      return string.format("%6.3fms", ms or 0)
    end
    local formatGarbageBytes = function(bytes)
      return string.format("%6.0fB", bytes or 0)
    end

    if not enableJit then
      jit.off() -- always disable JIT - not available on all platforms and not deterministic
    end

    self.__internal.testPassCount = 0
    self.__internal.testFailCount = 0
    self.__internal.testResults = {}

    -- Collect and sort test names
    local testNames = {}
    for name, func in pairs(tests) do
      if type(func) == "function" and name:match("^test") then
        if not testPattern or string.find(name, testPattern) then
          table.insert(testNames, name)
        end
      else
        if not name:match("^test") then
          tlog('E', 'testing', 'Unknown test function: ' .. tostring(name))
          tlog('E', 'testing', 'Function name must begin with \'test\', rename the function to \'test' .. tostring(name) .. '\'.')
        end
      end
    end
    table.sort(testNames)
    tlog('I', 'testing', 'Running ' .. #testNames .. ' tests from ' .. tostring(context) .. ' ...')
    if captureLogs then
      self:drainFrameLogs()
    end

    -- Run all test methods in the tests table
    local totalTimer = (HighPerfTimer or hptimer)()
    local totalGarbageBytes = 0
    for _, name in ipairs(testNames) do
      local func = tests[name]
      local displayName = string.format("%-40s", name:gsub('_shouldFail$', ''))

      local textFuncContext = {
        buildFailureMessage = function(ctx, kind, message)
          local src, line = "unknown", -1
          for level = 3, 20 do
            local info = debug.getinfo(level, "Sl")
            if not info then break end
            local shortSrc = tostring(info.short_src or info.source or "unknown")
            if not string.find(shortSrc, "testFramework/TestManager.lua", 1, true) then
              src = shortSrc
              line = info.currentline or -1
              break
            end
          end
          local how = kind or "fail"
          local msg = tostring(message or (how == "assert" and "Assertion failed" or "Test failed"))
          if line > 0 then
            return string.format("%s at %s:%d - %s", how, src, line, msg)
          end
          return string.format("%s at %s - %s", how, src, msg)
        end,
        fail = function(ctx, message, withTraceback)
          local formatted = ctx:buildFailureMessage("fail", message)
          if withTraceback then
            error(formatted)
          else
            error({message = formatted, __noTraceback = true})
          end
        end,
        success = function(ctx, message)
          ctx.successMessage = message
        end,
        setDescription = function(ctx, description)
          ctx.description = description
        end,
        resetGarbageCheckpoint = function(ctx)
          local now = collectgarbage("count") * 1024
          ctx.garbageCheckpointBytes = now
          return now
        end,
        checkGarbage = function(ctx, maxBytes, message)
          if type(maxBytes) == "string" and message == nil then
            message = maxBytes
            maxBytes = 0
          end
          local allowed = maxBytes or 0
          local n = tonumber(allowed)
          if not n or n < 0 then
            error({message = ctx:buildFailureMessage("checkGarbage", "checkGarbage expects a non-negative maxBytes"), __noTraceback = true})
          end
          local now = collectgarbage("count") * 1024
          local delta = math.max(0, now - (ctx.garbageCheckpointBytes or now))
          ctx.garbageCheckpointBytes = now
          if delta > n then
            local detail = string.format("%.0f bytes > %.0f bytes", delta, n)
            local msg = message and (message .. " (" .. detail .. ")")
              or ("garbage allocation exceeded checkpoint allowance: " .. detail)
            error({message = ctx:buildFailureMessage("checkGarbage", msg), __noTraceback = true})
          end
          return delta
        end,
        allowGarbage = function(ctx, bytes)
          local n = tonumber(bytes)
          if not n or n < 0 then
            error({message = ctx:buildFailureMessage("allowGarbage", "allowGarbage expects a non-negative number of bytes"), __noTraceback = true})
          end
          ctx.allowedGarbageBytes = n
          return n
        end,
        assert = function(ctx, condition, message)
          if not condition then
            error({message = ctx:buildFailureMessage("assert", message), __noTraceback = true})
          end
        end,
        assertEqual = function(ctx, actual, expected, message)
          if actual ~= expected then
            local msg = message or string.format("Expected %s, got %s", tostring(expected), tostring(actual))
            error({message = ctx:buildFailureMessage("assertEqual", msg), __noTraceback = true})
          end
        end,
        assertNear = function(ctx, actual, expected, tolerance, message)
          local tol = tolerance or 0.001
          if type(actual) ~= "number" or type(expected) ~= "number" then
            local msg = message or string.format("assertNear expects numbers, got %s and %s", type(actual), type(expected))
            error({message = ctx:buildFailureMessage("assertNear", msg), __noTraceback = true})
          end
          if math.abs(actual - expected) > tol then
            local msg = message or string.format("Expected %.10g +/- %.10g, got %.10g", expected, tol, actual)
            error({message = ctx:buildFailureMessage("assertNear", msg), __noTraceback = true})
          end
        end,
        successMessage = nil,
        description = nil,
        garbageBytes = 0,
        garbageCheckpointBytes = nil,
        allowedGarbageBytes = nil,
        -- You can add more fields to the context if needed
      }

      self.currentCtx = textFuncContext
      local testTimer = (HighPerfTimer or hptimer)()
      if captureLogs then
        self:drainFrameLogs()
      end
      local originalEnv = getfenv(func)
      setfenv(func, _G)

      -- Keep GC sampling window as tight as possible around the test body.
      collectgarbage("collect")
      collectgarbage("stop")
      local gcBeforeBytes = collectgarbage("count") * 1024
      textFuncContext.garbageCheckpointBytes = gcBeforeBytes
      local tLoad0 = os.clockhp()
      local status, resOrErr = pcall(func, textFuncContext)
      local tLoad1 = os.clockhp()
      local gcAfterBytes = collectgarbage("count") * 1024
      collectgarbage("restart")
      setfenv(func, originalEnv)
      local garbageBytes = math.max(0, gcAfterBytes - gcBeforeBytes)
      textFuncContext.garbageBytes = garbageBytes
      totalGarbageBytes = totalGarbageBytes + garbageBytes
      local err = nil
      if not status then
        if type(resOrErr) == "table" and resOrErr.__noTraceback then
          err = resOrErr.message
        else
          err = debug.traceback(resOrErr)
        end
      end
      local durationMs = testTimer:stop()
      local duration = durationMs / 1000
      local capturedLogs = captureLogs and self:drainFrameLogs() or nil

      local expectedToFail = name:match("_shouldFail$") ~= nil
      local testPassed = (status ~= expectedToFail)

      -- Store test result
      local testName = name
      if resultNamePrefix and resultNamePrefix ~= "" then
        local separator = options.resultNameSeparator or "/"
        testName = resultNamePrefix .. separator .. name
      end

      local testResult = {
        name = testName,
        passed = testPassed,
        description = textFuncContext.description,
        duration = duration,
        garbageBytes = garbageBytes,
        allowedGarbageBytes = textFuncContext.allowedGarbageBytes,
      }
      if expectedToFail then
        testResult.expectedToFail = true
      end
      if captureLogs then
        testResult.logs = capturedLogs or {}
      end
      local loadSec = tLoad1 - tLoad0
      if loadSec > 0.01 then
        testResult.sandbox = { loadSec = loadSec }
      end

      if not testPassed then
        testResult.errorMessage = err
      else
        testResult.successMessage = textFuncContext.successMessage
      end

      if failOnErrorLogs and captureLogs and self:logsContainErrors(capturedLogs) then
        testResult.passed = false
        testResult.errorMessage = testResult.errorMessage or "error-level log captured during test"
        testPassed = false
      end

      if textFuncContext.allowedGarbageBytes ~= nil and garbageBytes > textFuncContext.allowedGarbageBytes then
        testResult.passed = false
        testResult.errorMessage = testResult.errorMessage or string.format(
          "garbage allocation exceeded allowance: %.0f bytes > %.0f bytes",
          garbageBytes,
          textFuncContext.allowedGarbageBytes
        )
        testPassed = false
      end

      table.insert(self.__internal.testResults, testResult)

      if testPassed then
        self.__internal.testPassCount = self.__internal.testPassCount + 1
        if expectedToFail then
          tlog('I', 'testing', ' - ' .. displayName .. " >>> PASSED (expected failure) [" .. formatDurationMs(durationMs) .. ", " .. formatGarbageBytes(garbageBytes) .. "]")
        else
          if textFuncContext.successMessage then
            tlog('I', 'testing', ' - ' .. displayName .. " >>> PASSED [" .. formatDurationMs(durationMs) .. ", " .. formatGarbageBytes(garbageBytes) .. "]: " .. textFuncContext.successMessage)
          else
            tlog('I', 'testing', ' - ' .. displayName .. " >>> PASSED [" .. formatDurationMs(durationMs) .. ", " .. formatGarbageBytes(garbageBytes) .. "]")
          end
        end
      else
        self.__internal.testFailCount = self.__internal.testFailCount + 1
        if expectedToFail then
          tlog('E', 'testing', ' - ' .. displayName .. " >>> FAILED (expected failure but test passed) [" .. formatDurationMs(durationMs) .. ", " .. formatGarbageBytes(garbageBytes) .. "]")
        else
          tlog('E', 'testing', ' - ' .. displayName .. " >>> FAILED [" .. formatDurationMs(durationMs) .. ", " .. formatGarbageBytes(garbageBytes) .. "]: " .. tostring(testResult.errorMessage or err))
        end
      end
    end
    local totalDuration = totalTimer:stop() / 1000

    local totalTests = self.__internal.testPassCount + self.__internal.testFailCount
    local summaryLevel = self.__internal.testFailCount > 0 and 'E' or 'I'
    tlog(summaryLevel, 'testing', string.format(" -> Summary: %d tests, %d passed, %d failed, total %.3fms, garbage %.0fB", totalTests, self.__internal.testPassCount, self.__internal.testFailCount, totalDuration * 1000, totalGarbageBytes))

    -- Output results to JUnit XML if outputFile is provided
    local results = {
      testPassCount = self.__internal.testPassCount,
      testFailCount = self.__internal.testFailCount,
      testResults = self.__internal.testResults,
      totalDuration = totalDuration,
      totalGarbageBytes = totalGarbageBytes,
    }

    if outputFile and writeXml then
      local JUnitXMLWriter = require('testFramework/JUnitXMLWriter')
      -- Write the results to JUnit XML
      JUnitXMLWriter.write(results, outputFile)
    end

    -- Reset counts after running tests
    self.__internal.testPassCount = 0
    self.__internal.testFailCount = 0
    self.__internal.testResults = {}

    return results
  end,
}

return TestManager

--[[ Example Usage:

-- Import the TestManager
local testManager = require('testFramework/TestManager')

-- Define your tests in a table
local tests = {}

-- Test functions should start with "test"
function tests.testExampleSuccess(ctx)
  -- Basic helpers
  ctx:assertEqual(42, 42, "strict equality")
  ctx:assertNear(0.3000001, 0.3, 0.001, "float near-equality")

  -- Optional test description shown in results
  ctx:setDescription("Example showing common ctx helpers")

  -- Garbage checkpoints: check allocations for specific code regions
  ctx:allowGarbage(4096) -- optional whole-test allowance
  ctx:resetGarbageCheckpoint()
  local sum = 0
  for i = 1, 1000 do
    sum = sum + i
  end
  ctx:checkGarbage(0, "sum loop should not allocate")

  ctx:assert(sum > 0, "sum should be positive")
  ctx:success("Result matches expected value")
end

function tests.testExampleFailure_shouldFail(ctx)
  -- This test is expected to fail
  ctx:fail("Intentional failure")
end

-- Run the tests and output results to 'test-results.xml'
testManager:run(tests, 'test-results.xml')


-- run all .test.lua file:
require('testFramework/TestManager'):runTestFiles()
]]
