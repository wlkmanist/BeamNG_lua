-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.args = {}

-- Support functions used to manage the directory list
local function pushFront(list, token, delim)
  if list ~= "" then
    return token .. delim .. list
  end
  return token
end

local function pushBack(list, token, delim)
  if list ~= "" then
    return list .. delim .. token
  end
  return token
end

local function popFront(list, delim)
  --TODO:
  return nextToken(list, unused, delim)
end

-- The default global argument parsing
local function defaultParseArgs()
  M.args = {}
  local argumentCount = tonumber(VariableRegistry.get("$Game::argc", 0))
  -- log('I','parse','$Game::argv = '..VariableRegistry.get("$Game::argv", 0)..'     argumentCount: '..tostring(argumentCount))
  if argumentCount then
    for i = 0, argumentCount - 1 do
      local arg = VariableRegistry.get("$Game::argv".. tostring(i), "")
      local nextArg = VariableRegistry.get("$Game::argv".. tostring(i + 1), "")
      local hasNextArg = (argumentCount - i) > 1
      -- log('I','parse',"    $Game::argv".. tostring(i).."= "..tostring(arg))

      if arg == "-log" then
        if hasNextArg == true then
          -- Turn on console logging
          if nextArg ~= 0 then
            -- Dump existing console to logfile first.
            nextArg = nextArg + 4
          end
          setLogMode(nextArg)
          VariableRegistry.set("$logModeSpecified", true)
          i = i + 1
        else
          log("E", "", "Error: Missing Command Line argument. Usage: -log <Mode: 0,1,2>")
        end
      elseif arg == "-cefdev" then
        enableCEFDevConsole(true)
      elseif arg == "-fullscreen" then
        setFullScreen(true)
      elseif arg == "-windowed" then
        setFullScreen(false)
      elseif arg == "-vehicleConfig" then
        if hasNextArg then
          M.args.vehicleConfig = nextArg
          i = i + 1
        else
          log("E", "", "Error: Missing Command Line argument. Usage: -vehicleConfig \"pickup/myConfig.pc\"")
        end
      elseif arg == "-vehicle" then
        if hasNextArg then
          VariableRegistry.set("$beamngVehicleArgs", nextArg)
          i = i + 1
        else
          log("E", "", "Error: Missing Command Line argument. Usage: -vehicle <vehicle arg>")
        end
      elseif arg == "-useDefaultPc" then
        M.args.useDefaultPc = true
      elseif arg == "-translationScrambleDebug" then
        M.args.translationScrambleDebug = true
        if core_locales then
          core_locales.setScrambleTranslationDebugEnabled(true)
        end
      elseif arg == "-luafile" then
        if hasNextArg then
          require(nextArg)
          i = i + 1
        else
          log("E", "", "Error: Missing Command Line argument. Usage: -luafile <lua file arg>")
        end
      elseif arg == "-lua" then
        if hasNextArg then
          LuaExecuteQueueString(nextArg)
          i = i + 1
        else
          log("E", "", "Error: Missing Command Line argument. Usage: -lua <lua arg>")
        end
      elseif arg == "-onLevelLoad_ext" then
        if hasNextArg then
          queueCmdlineLevelLoadExtension(nextArg)
          i = i + 1
        else
          log("E", "", "Error: Missing Command Line argument. Usage: -onLevelLoad_ext <argument>")
        end
      elseif arg == "-level" then
        if hasNextArg then
          VariableRegistry.set("$levelToLoad", nextArg)
          i = i + 1
        else
          log("E", "", "Error: Missing Command Line argument. Usage: -level <level file name (no path), with or without extension>")
        end
      elseif arg == "-worldeditor" then
        log("E", "", "Error: The -worldeditor argument was deprecated. Please use -worldEditor (camel case) instead.")
      elseif arg == "-tcom" or arg == "-tcom-capture" then
        local success, err = pcall(function()
          extensions.load('tech/techCore')
        end)
        if not success then
          log("E", "", string.format("Error: Cannot load techCore extension. Original error: %s", err))
        elseif arg == "-tcom" then
          tech_techCore.openServer()
        end
      elseif arg == "-levelOffset" then
        if i + 3 <= argumentCount then
          local x = tonumber(VariableRegistry.get("$Game::argv".. tostring(i + 1), 0))
          local y = tonumber(VariableRegistry.get("$Game::argv".. tostring(i + 2), 0))
          local z = tonumber(VariableRegistry.get("$Game::argv".. tostring(i + 3), 0))
          if x and y and z then
            server.setLevelOffset(x, y, z)
            i = i + 3 -- Skip the consumed arguments
          else
            log('E', 'Invalid argument for -levelOffset: expected three numeric values.')
          end
        else
          log('E', 'Not enough arguments for -levelOffset: expected three numeric values.')
        end
      elseif arg == "-enableAiRecordingForMissions" then
        M.args.enableAiRecordingForMissions = true
      end
    end
  end
end

M.defaultParseArgs = defaultParseArgs

return M