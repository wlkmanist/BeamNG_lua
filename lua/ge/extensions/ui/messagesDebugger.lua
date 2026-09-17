-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_imgui" }

local im = ui_imgui
local windowOpen = im.BoolPtr(false)

-- UI state
local txtMsg = im.ArrayChar(1024, "")
local txtCategory = im.ArrayChar(128, "default")
local txtIcon = im.ArrayChar(256, "")
local ttlSeconds = im.FloatPtr(5.0)
local useRegexClear = im.BoolPtr(false)
local bypassTtl = im.BoolPtr(false)

local function _sendMessage(msg, ttl, category, icon)
  guihooks.message(msg, ttl, category, (icon ~= "" and icon) or nil)
end

local function _clearCategory(category, isRegex)
  if not category or category == "" then return end
  if isRegex then
    guihooks.trigger("Message", { category = category, clear = true })
  else
    guihooks.trigger("Message", { category = category, clear = true })
  end
end

local function _clearAll()
  guihooks.trigger("ClearAllMessages")
end

-- Public helpers (console)
local function show() windowOpen[0] = true end
local function hide() windowOpen[0] = false end
local function toggle() windowOpen[0] = not windowOpen[0] end

-- Draw the debug window
local function onUpdate(dtReal, dtSim, dtRaw)
  if not windowOpen[0] then return end

  im.SetNextWindowSize(im.ImVec2(520, 320), im.Cond_FirstUseEver)
  if im.Begin("Messages Debugger", windowOpen) then
    im.TextUnformatted("Compose and control UI 'Message' events")
    im.Separator()

    if im.Checkbox("Bypass TTL (UI)", bypassTtl) then
      guihooks.trigger("MessagesDebug", { bypassTtl = bypassTtl[0] })
    end

    im.TextUnformatted("Message Text")
    im.InputTextMultiline("##msg", txtMsg, im.ArraySize(txtMsg), im.ImVec2(-1, 100))

    im.Columns(2, "cols", false)
    im.TextUnformatted("Category")
    im.InputText("##cat", txtCategory, im.ArraySize(txtCategory))
    im.NextColumn()
    im.TextUnformatted("Icon (font id or /path)")
    im.InputText("##icon", txtIcon, im.ArraySize(txtIcon))
    im.Columns(1)

    im.TextUnformatted("TTL (seconds)")
    im.SliderFloat("##ttl", ttlSeconds, 0.5, 30.0)

    if im.Button("Send Message") then
      local msg = ffi.string(txtMsg)
      local cat = ffi.string(txtCategory)
      local icn = ffi.string(txtIcon)
      _sendMessage(msg, ttlSeconds[0], cat, icn)
    end
    im.SameLine()
    if im.Button("Send Binding Example") then
      local cat = ffi.string(txtCategory)
      local ex = "Press [action=switch_next_vehicle] to switch"
      _sendMessage(ex, ttlSeconds[0], cat, "")
    end

    im.Separator()
    im.Checkbox("Regex clear", useRegexClear)
    im.SameLine()
    if im.Button("Clear Category") then
      _clearCategory(ffi.string(txtCategory), useRegexClear[0])
    end
    im.SameLine()
    if im.Button("Clear All") then
      _clearAll()
    end

    im.Separator()
    if im.Button("Test 3 Messages") then
      local cat = ffi.string(txtCategory)
      _sendMessage("First test line", 3.0, cat .. ".1", "")
      _sendMessage("Second line with [action=switch_previous_vehicle]", 4.0, cat .. ".2", "")
      _sendMessage("Third line with newline\nand more text", 5.0, cat .. ".3", "")
    end
  end
  im.End()
end

-- Exports
M.onUpdate = onUpdate
M.show = show
M.hide = hide
M.toggle = toggle

return M


