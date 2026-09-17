-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-------------------------------------------------------------------------------
-- Variables used by client scripts & code.  The ones marked with (c)
-- are accessed from code.  Variables preceeded by Pref:: are client
-- preferences and stored automatically in the ~/client/prefs.cs file
-- in between sessions.
--
--    (c) Client::MissionFile             Mission file name
--    ( ) Client::Password                Password for server join
--    (c) pref::Master[n]                 List of master servers
--    (c) pref::Net::RegionMask
--    (c) pref::Client::ServerFavoriteCount
--    (c) pref::Client::ServerFavorite[FavoriteCount]
--    .. Many more prefs... need to finish this off

-- Moves, not finished with this either...
--    $mv*Action...

-------------------------------------------------------------------------------
-- These are variables used to control the shell scripts and
-- can be overriden by mods:
-------------------------------------------------------------------------------
local M = {}
--initBaseClient was taken from core/scripts/client/client.cs
local function initBaseClient()
  -- log('I','client', "initBaseClient start...")
  -- dumps(debug.tracesimple())

  -- Base client functionality
  local postFxModule = require("client/postFx")
  rawset(_G, "postFxModule", postFxModule)


  local renderManagerModule = require("client/renderManager")

  local lightingModule = require("client/lighting")

  -- print("initRenderManager");
  renderManagerModule.initRenderManager()

  -- print("initLightingSystems");
  lightingModule.initLightingSystems()

  local adapterCount = GFXInit.getAdapterCount()
  if adapterCount == 1 and GFXInit.getAdapterName(0) == "GFX Null Device" then
    log('E','client',"Null graphics device detected, skipping PostFX initialization.")
    return
  end

  -- -- Initialize all core post effects.
  -- log('I','client', "Initialize the post effect manager")
  postFxModule.initPostEffects()

  -- Get the default preset settings
  postFxModule.applyDefaultPreset()

  -- log('I','client', "... initBaseClient done")
end

--reloadBaseClient was taken from core/scripts/client/client.cs
local function reloadBaseClient()
  -- Base client functionality
  local postFxModule = require("client/postFx");
  rawset(_G, "postFxModule", postFxModule)

  local renderManagerModule = require("client/renderManager");

  local lightingModule = require("client/lighting");

  -- print("initLightingSystems");
  lightingModule.reloadLightingSystems();

  local adapterCount = GFXInit.getAdapterCount()
  if adapterCount == 1 and GFXInit.getAdapterName(0) == "GFX Null Device" then
    log('E','client',"Null graphics device detected, skipping PostFX initialization.")
    return
  end

  -- -- Initialize all core post effects.
  -- log('I','client', "Initialize the post effect manager")
  postFxModule.reloadPostEffects()

  -- log('I','client', "... initBaseClient done")
end

M.loadMainMenu = function()
  -- Startup the client with the Main menu...
  local onlyGui = scenetree.findObject("OnlyGui")
  local canvas = scenetree.findObject("Canvas")
  if onlyGui and canvas then
    canvas:setContent(onlyGui)
  end
end

local function createGameViewportCtrl()
  local cmdArgs = Engine.getStartingArgs()
  if tableFindKey(cmdArgs, '-noui') then
    -- -headless is working differenly than expected and should not be used
    -- it only prevents opening a main window
    log('I', 'startup', "UI is disabled, skipping GameViewportCtrl creation")
    return
  end

  local onlyGui = createObject("GameViewportCtrl")
  onlyGui.forceFOV = 0
  onlyGui.reflectPriority = 1
  onlyGui:setField("margin", 0, "0 0 0 0")
  onlyGui:setField("padding", 0, "0 0 0 0")
  onlyGui:setField("anchorTop", 0, "1")
  onlyGui:setField("anchorBottom", 0, "0")
  onlyGui:setField("anchorLeft", 0, "1")
  onlyGui:setField("anchorRight", 0, "0")
  onlyGui:setField("position", 0, "0 0")
  onlyGui:setField("extent", 0, "1024 768")
  onlyGui:setField("minExtent", 0, "8 8")
  onlyGui:setField("horizSizing", 0, "right")
  onlyGui:setField("vertSizing", 0, "bottom")
  onlyGui:setField("profile", 0, "GuiDefaultProfile")
  onlyGui:setField("tooltipProfile", 0, "GuiToolTipProfile")
  onlyGui:setField("hovertime", 0, "1000")
  onlyGui:setField("helpTag", 0, "0")
  onlyGui.visible = 1
  onlyGui.active = 1
  onlyGui.isContainer = 1
  onlyGui.canSave = 1
  onlyGui.canSaveDynamicFields = 1
  onlyGui.enabled = 1
  onlyGui:registerObject("OnlyGui")

  -- DO NOT RENAME maincef, its name is hardcoded in c++
  local maincef = createObject("CefGui")
  if maincef ~= nil then
    maincef:setField("docking", 0, "Client")
    maincef:setField("margin", 0, "0 0 0 0")
    maincef:setField("padding", 0, "0 0 0 0")
    maincef:setField("anchorTop", 0, "1")
    maincef:setField("anchorBottom", 0, "0")
    maincef:setField("anchorLeft", 0, "1")
    maincef:setField("anchorRight", 0, "0")
    maincef:setField("position", 0, "0 0")
    maincef:setField("extent", 0, "1024 768")
    maincef:setField("minExtent", 0, "8 2")
    maincef:setField("horizSizing", 0, "right")
    maincef:setField("vertSizing", 0, "bottom")
    maincef:setField("profile", 0, "GuiCEFProfile")
    maincef:setField("tooltipProfile", 0, "GuiToolTipProfile")
    maincef:setField("hovertime", 0, "1000")
    maincef:setField("StartURL", 0, "local://local/ui/entrypoints/main/index.html")
    maincef.visible = 1
    maincef.active = 1
    maincef.isContainer = 1
    maincef.canSave = 1
    maincef.canSaveDynamicFields = 0
    maincef:registerObject("maincef")
    onlyGui:add(maincef)
  end
end

local cmdArgs = Engine.getStartingArgs()

M.initClient = function()
  -- log('I','client', "initClient start...")

  -- The common module provides basic client functionality
  initBaseClient()

  createGameViewportCtrl()

  -- default cubemap for levels without LevelInfo.globalEnviromentMap
  VariableRegistry.set("$defaultLevelEnviromentMap", "BNG_Sky_02_cubemap")

  if not tableFindKey(cmdArgs, '-convertCSMaterials') then
    loadDirRec("core/art/datablocks/")
    loadDirRec("art/")
    loadDirRec("assets/")

    --TODO: check funcs
    if FS:fileExists(FS:expandFilename("./audioData.cs")) then
      TorqueScriptLua.exec( "./audioData.cs" )
    end
  end

  --loadStartup();
  -- BEAMNG: load the menu directly
  M.loadMainMenu()

  -- print("... initClient done")
end

M.reloadClient = function()
  -- log('I','client', "reloadClient start...")

  -- The common module provides basic client functionality
  reloadBaseClient()
end
return M
