-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local delayedData = {}
local cycleArgs = {}
local delayCounter = 1

M.delayFrames = 3

-- screenData = content {image, title, text} that is displayed during the pause phase
local function fadeToBlack(fade, screenData, args)
  fade = fade or 1
  args = args or {}
  local params = {
    -- fade to and stop on black
    fadeIn = fade,
    -- pause = cycleArgs.pause or 1e6,
    pause = cycleArgs.pause or -1,
    -- fadeOut = cycleArgs.fadeOut and 1e6 or 0,
    fadeOut = cycleArgs.fadeOut or 0,
    data = screenData
  }
  -- guihooks.trigger('ChangeState', {state = 'fadeScreen', params = params})
  guihooks.trigger("LoadingScreen", { active = true, custom = params })

  if headless_mode then -- in headless mode, skip this as there's no UI
    extensions.hook("onScreenFadeState", 1)
  end

  if args.useGlobalAudioFade == nil or args.useGlobalAudioFade then
    SFXSystem.setGlobalParameter("g_FadeTimeMS", fade * 1000) -- fade is in seconds, convert to milliseconds
    SFXSystem.setGlobalParameter("g_GameLoading", 1)
  end
end

local function fadeFromBlack(fade, args)
  fade = fade or 1
  args = args or {}
  -- local params = {fadeIn = 0, pause = 0, fadeOut = fade} -- fade from black
  -- guihooks.trigger('ChangeState', {state = 'fadeScreen', params = params})
  guihooks.trigger("LoadingScreen", { active = false, custom = { fadeOut = fade } })

  if headless_mode then -- in headless mode, skip this as there's no UI
    extensions.hook("onScreenFadeState", 3)
  end

  if args.useGlobalAudioFade == nil or args.useGlobalAudioFade then
    SFXSystem.setGlobalParameter("g_FadeTimeMS", fade * 1000) -- fade is in seconds, convert to milliseconds
    SFXSystem.setGlobalParameter("g_GameLoading", 0)
  end
end

local function fadeSequence(fadeIn, pause, fadeOut, screenData, args) -- fade to black, pause, then fade from black
  cycleArgs.fadeIn = fadeIn or 1
  cycleArgs.pause = math.max(0.05, pause or 0) -- TODO: zero value breaks things a little bit
  cycleArgs.fadeOut = fadeOut or fadeIn
  cycleArgs.args = args or {}
  fadeToBlack(cycleArgs.fadeIn, screenData, args)
end

-- this delay is needed so we can be sure that the screen is completely black before moving on.
local function onScreenFadeStateDelayed(state)
  table.insert(delayedData, state)
  delayCounter = M.delayFrames
end

local function onGuiUpdate()
  if delayedData[1] then
    if delayCounter <= 0 then
      for _, state in ipairs(delayedData) do
        extensions.hook("onScreenFadeState", state)

        if state == 2 and next(cycleArgs) then -- only during full fade cycle
          fadeFromBlack(cycleArgs.fadeOut, cycleArgs.args)
          table.clear(cycleArgs)
        end
      end
      table.clear(delayedData)
    end
    delayCounter = delayCounter - 1
  end
end

-- public interface
M.fadeToBlack = fadeToBlack
M.fadeFromBlack = fadeFromBlack
M.fadeSequence = fadeSequence
M.start = fadeToBlack
M.stop = fadeFromBlack
M.cycle = fadeSequence
M.onScreenFadeStateDelayed = onScreenFadeStateDelayed
M.onGuiUpdate = onGuiUpdate

return M