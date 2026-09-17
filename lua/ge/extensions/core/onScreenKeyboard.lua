-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- there's two types of on-screen keyboards:
-- 1. one that is kind of "fire and forget" after calling _openOnScreenKeyboard and that sends keyboard inputs straight to the game (for example the steam deck keyboard)
-- 2. one that also gets openend with _openOnScreenKeyboard but doesnt send keyboard inputs to the game and instead send the complete text once via onScreenKeyboardClosed when the user confirms (for example PS5)

local function _openOnScreenKeyboard(title, placeholder, initialText, maxLength, inputType, textBoxLeft, textBoxTop, textBoxWidth, textBoxHeight)
  if openOnScreenKeyboard then
    if type(maxLength) ~= "number" or maxLength <= 0 then
      maxLength = 1000
    end
    openOnScreenKeyboard(title, placeholder or "", initialText or "", maxLength, inputType or "string", textBoxLeft, textBoxTop, textBoxWidth, textBoxHeight)
  end
end

local function onScreenKeyboardClosed(applied, text)
  guihooks.trigger('onScreenKeyboardClosed', applied, text)
end

local function _isOnScreenKeyboardAvailable()
  return isOnScreenKeyboardAvailable()
end

M.openOnScreenKeyboard = _openOnScreenKeyboard
M.onScreenKeyboardClosed = onScreenKeyboardClosed
M.isOnScreenKeyboardAvailable = _isOnScreenKeyboardAvailable

return M