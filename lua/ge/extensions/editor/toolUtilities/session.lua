-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared Save/Load Session helper for the custom spline/zone editor tools. It owns the parts that are IDENTICAL across every
-- tool: the portable JSON envelope, the file read/write, the replace-or-merge load loop, and the top-of-window Save/Load
-- buttons plus the Replace/Merge modal. Everything tool-SPECIFIC (which fields are primary vs derived, how an item rehydrates,
-- the undo hooks) stays in the tool and is passed in through a small `spec` table -- so each tool wires this in ~15 lines
-- instead of copy-pasting ~120. See heroRoadEditor / roadSpline for the reference wiring.
--
-- A session file is a portable, human-diffable JSON of every item in the tool. It is a thin wrapper over the SAME serialize/
-- deserialize the editor already uses: keep the primary data (nodes/widths/normals + config + layers) and drop everything the
-- dirty pass rebuilds on load (derived geometry, runtime scene handles). Terrain edits are intentionally NOT saved.
--
-- spec fields:
--   toolId          (string)  unique id; used for the envelope `tool` tag, the button ids and the modal popup id.
--   displayName     (string)  human label for the modal/undo text, e.g. 'Hero Road', 'Road Spline'. Defaults to toolId.
--   itemNoun        (string)  plural noun for messages/modal text, e.g. 'roads', 'splines', 'zones'. Defaults to 'items'.
--   getItems        ()        -> the live array of items (returned BY REFERENCE; load appends into it).
--   serializeItem   (item)    -> a clean, JSON-safe plain table (see itemToTable). Must NOT mutate the live item.
--   deserializeItem (table)   -> a live item ready to append (dual-path deserialize + vec3 rehydrate + create scene object).
--   clearAll        ()        wipe all current items (used by Replace).
--   deepCopyAll     ()        -> a snapshot of all items for the undo history.
--   transUndo/Redo  (data)    the tool's trans-edit undo/redo fns (given { old = snapshot, new = snapshot }).
--   refreshIdMap    ()        (optional) recompute the tool's id->index map after a load.
--   onLoaded        ()        (optional) e.g. reset the selected index to 1.
--   logTag          (string)  (optional) log tag; defaults to toolId.
--   version         (number)  (optional) envelope version; defaults to 1.
--   noMerge         (bool)    (optional) single-document tool: a Load always replaces (skip the Replace/Merge modal - merging is meaningless).
--   altItemsKey     (string)  (optional) legacy envelope array key to also accept on load (e.g. 'groups').
--   iconColor       (imvec4)  (optional) button colour.
--   iconSize        (imvec2)  (optional) button size; defaults to 36x36.
--   saveIcon/loadIcon         (optional) icon overrides; default to editor.icons.floppyDisk / editor.icons.folder.
--   getGlobals      ()        (optional) -> a small JSON-safe table of TOOL-GLOBAL knobs (e.g. terraform params) not tied to any
--                             one item, written under the envelope's `globals` key.
--   applyGlobals    (table)   (optional) apply a loaded `globals` table back onto the live tool. Only called on a REPLACE load
--                             (a Merge leaves your current knobs untouched). A file with no `globals` block leaves defaults as-is.
--   getRecords      ()        (optional) -> tool-global records too big to compare every frame (a terraform's record of the
--                             ground it moved, tunnel holes), written under `records`. They never mark the document edited.
--   applyRecords    (table)   (optional) apply a loaded `records` table, on a REPLACE load only.
--
-- Whole-state tools (e.g. a tool with an internal id counter that must round-trip): instead of serializeItem/deserializeItem,
-- provide these two and the helper stores/loads one opaque `state` blob rather than a per-item array:
--   getState        ()               -> a plain, JSON-safe full-state snapshot (written under the envelope's `state` key).
--   loadWhole       (state, replace) -> apply the loaded state; return the number of items loaded. `replace` swaps the whole
--                                       state; a false (merge) appends the loaded items alongside the current ones.
-- getItems is still required (used for the empty-state check and the modal's "already has items" branch).
--   loadJson        (j, replace)     (optional) take the whole decoded file instead, for a tool made of other tools' parts;
--                                       returns ok, countOrError, keepUnbound (a part file: the next Save must ask where).
--   loadOptions     ()               (optional) draws what to take from the file inside the load modal, which then opens on
--                                       every load, not only when there is something to merge with.

local M = {}

-- Module dependencies.
local im = ui_imgui
local buffer = require('string.buffer')

-- Per-tool state, all keyed by toolId so tools never collide (like the deferred-load path).
local pendingByTool = {}    -- a load waiting on the Replace/Merge modal.
local boundPathByTool = {}  -- the file this tool is currently attached to (Save writes here silently). Runtime-only.
local dirtyByTool = {}      -- unsaved changes since the last save/load. Drives whether the Save button shows.
local savedGlobalsByTool = {} -- snapshot of getGlobals() at the last save/load, for the cheap per-frame globals-changed compare.
local loadGuardByTool = {}  -- one-shot: swallow the ONE markEdited that the rebuild of a fresh load triggers (so loading stays clean).

-- Recursive value equality for the tiny tool-global tables (a handful of numbers/strings). Only used to tell whether a tool-global
-- knob changed since the last save/load, so it need not be fast.
local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Deep copy of a small JSON-safe value. getGlobals() often returns the LIVE knob table (e.g. `return terraParams`), so the clean
-- baseline must be a detached copy -- otherwise it would alias the live table and every compare would trivially match (no dirty).
local function deepCopy(v)
  if type(v) ~= 'table' then return v end
  local t = {}
  for k, val in pairs(v) do t[k] = deepCopy(val) end
  return t
end

-- Detached snapshot of the tool-global knobs, or nil if the tool has none.
local function snapshotGlobals(spec)
  return spec.getGlobals and deepCopy(spec.getGlobals()) or nil
end

-- Marks a tool's document as having unsaved changes. Tools call this from their dirty/rebuild pass (once per pass, when something
-- actually rebuilt). The load guard swallows exactly one call so the forced rebuild a fresh Load triggers doesn't flip the doc dirty.
local function markEdited(toolId)
  if loadGuardByTool[toolId] then loadGuardByTool[toolId] = nil; return end
  dirtyByTool[toolId] = true
end

-- Clears the dirty flag and re-snapshots the tool-global knobs as the new clean baseline. Called after every successful save/load.
local function markClean(spec)
  dirtyByTool[spec.toolId] = nil
  savedGlobalsByTool[spec.toolId] = snapshotGlobals(spec)
end

-- Detaches a tool from its file, so the next Save has to ask where instead of writing silently over whatever was last loaded.
local function unbind(toolId)
  boundPathByTool[toolId] = nil
end

-- Which file the document is attached to and whether it has unsaved changes.
local function attachment(toolId)
  return { path = boundPathByTool[toolId], dirty = dirtyByTool[toolId] or nil }
end

-- The bound path on its own, for callers that run every frame and should not allocate a table to read it.
local function boundPath(toolId)
  return boundPathByTool[toolId]
end

-- Window title naming the bound file (or `newName` before it has one). `id` follows `###` so ImGui keeps the window's
-- dock/size while the name changes. Cached per tool, so the per-frame call does not rebuild the string.
local titleByTool = {}
local function windowTitle(toolId, label, id, newName)
  local path = boundPathByTool[toolId] or false
  local t = titleByTool[toolId]
  if t and t.path == path then return t.text end
  local name = path and (path:match('([^/\\]+)%.json$') or path:match('[^/\\]+$')) or newName or 'New Session'
  t = { path = path, text = label .. ' - [' .. name .. ']###' .. id }
  titleByTool[toolId] = t
  return t.text
end

local function reattach(toolId, at)
  if type(at) ~= 'table' then return end
  boundPathByTool[toolId] = at.path
  dirtyByTool[toolId] = at.dirty or nil
end

-- Deep-copies an item through the buffer codec.
local function itemToTable(item, emptyKeys, nilKeys)
  local t = buffer.decode(buffer.encode(item))
  if emptyKeys then for i = 1, #emptyKeys do t[emptyKeys[i]] = {} end end
  if nilKeys then for i = 1, #nilKeys do t[nilKeys[i]] = nil end end
  return t
end

-- Rehydrates an array of node positions loaded from JSON (plain {x,y,z}) back into vec3, in place. Idempotent: entries that are
-- already vec3 (the buffer/undo path) have a :distance method and are left as-is. Safe on nil / non-table.
local function rehydrateVec3Array(arr)
  if type(arr) ~= 'table' then return end
  for i = 1, #arr do
    local n = arr[i]
    if type(n) == 'table' and not n.distance then arr[i] = vec3(n.x, n.y, n.z) end
  end
end

-- Writes every item to `path` as a portable session JSON. Returns ok, count.
local function saveToFile(path, spec)
  local items = spec.getItems()
  local out = { version = spec.version or 1, tool = spec.toolId }
  if core_levels and getMissionFilename then out.mapName = core_levels.getLevelName(getMissionFilename()) end
  if spec.getState then -- whole-state tool: one opaque snapshot blob.
    out.state = spec.getState()
  else
    out.items = {}
    for i = 1, #items do out.items[i] = spec.serializeItem(items[i]) end
  end
  if spec.getGlobals then out.globals = spec.getGlobals() end -- tool-global knobs (terraform params etc.), one block per file.
  if spec.getRecords then out.records = spec.getRecords() end
  jsonWriteFile(path, out, false)
  return true, #items
end

-- Writes an edited document back over the file it is bound to, for a tool whose work should never wait on a Save press.
local function saveIfEdited(spec)
  local path = boundPathByTool[spec.toolId]
  if not (path and dirtyByTool[spec.toolId]) then return false end
  local ok = saveToFile(path, spec)
  if ok then markClean(spec) end
  return ok
end

-- Applies a decoded session JSON. `replace` wipes current items first; otherwise the loaded items are MERGED (an incoming id that
-- clashes with a live item gets a fresh one so nothing is clobbered). Returns ok, countOrError.
local function loadJson(j, spec, replace)
  if spec.loadWhole then -- whole-state tool: hand the opaque snapshot straight to the tool.
    if not j or type(j.state) ~= 'table' then return false, 'not a valid ' .. spec.toolId .. ' session file' end
    if replace and spec.applyGlobals and type(j.globals) == 'table' then spec.applyGlobals(j.globals) end -- merge keeps live knobs.
    if replace and spec.applyRecords and type(j.records) == 'table' then spec.applyRecords(j.records) end
    return true, spec.loadWhole(j.state, replace) or 0
  end
  local list = j and (type(j.items) == 'table' and j.items or (spec.altItemsKey and j[spec.altItemsKey]))
  if type(list) ~= 'table' then return false, 'not a valid ' .. spec.toolId .. ' session file' end
  if replace then spec.clearAll() end
  if replace and spec.applyGlobals and type(j.globals) == 'table' then spec.applyGlobals(j.globals) end -- merge keeps live knobs.
  if replace and spec.applyRecords and type(j.records) == 'table' then spec.applyRecords(j.records) end
  local items = spec.getItems()
  local existing = {}
  for i = 1, #items do if items[i].id then existing[items[i].id] = true end end
  local n = 0
  for i = 1, #list do
    local it = list[i]
    if not replace and it.id and existing[it.id] then it.id = Engine.generateUUID() end -- merge: don't overwrite a live item.
    items[#items + 1] = spec.deserializeItem(it)
    n = n + 1
  end
  if spec.refreshIdMap then spec.refreshIdMap() end
  return true, n
end

local function loadFromFile(path, spec, replace)
  local j = jsonReadFile(path)
  if spec.loadJson then return spec.loadJson(j, replace) end
  return loadJson(j, spec, replace)
end

-- Commits a load through the undo history, then clears the pending path.
local function commitLoad(spec, path, replace)
  local pre = spec.deepCopyAll()
  local ok, info, keepUnbound = loadFromFile(path, spec, replace)
  local tag = spec.logTag or spec.toolId
  if ok then
    editor.history:commitAction("Load " .. (spec.displayName or spec.toolId) .. " Session",
      { old = pre, new = spec.deepCopyAll() }, spec.transUndo, spec.transRedo, true)
    if spec.onLoaded then spec.onLoaded() end
    -- Bind + clean on a Replace (the tool now mirrors the file, so future Saves overwrite it).
    if replace and not keepUnbound then
      boundPathByTool[spec.toolId] = path
      markClean(spec)
    else
      savedGlobalsByTool[spec.toolId] = snapshotGlobals(spec) -- baseline the (untouched, on a merge) globals.
      dirtyByTool[spec.toolId] = true
    end
    -- Swallow the ONE markEdited that this load's forced rebuild fires (rebuild-tapped tools). Tools that mark dirty from user-action
    -- commits instead (spec.noLoadGuard) fire no markEdited on load, so arming it would eat their first post-load edit -- skip them.
    if not spec.noLoadGuard then loadGuardByTool[spec.toolId] = true end
    log('I', tag, string.format('Loaded %s %s from %s', tostring(info), spec.itemNoun or 'item(s)', path))
  else
    log('E', tag, 'Load session failed: ' .. tostring(info))
  end
  pendingByTool[spec.toolId] = nil
end

-- Opens the file dialog and, on confirm, writes the session, BINDS this tool to the chosen file and marks it clean. Shared by the
-- 'Save As' button and by a first-time 'Save' (no bound file yet).
local function saveAsDialog(spec)
  local tag = spec.logTag or spec.toolId
  -- Seed the dialog with the directory of the currently-bound file.
  local bound = boundPathByTool[spec.toolId]
  local defaultDir = bound and bound:match('^(.*[/\\])') or "/"
  extensions.editor_fileDialog.saveFile(
    function(data)
      if data and data.filepath then
        local ok, cnt = saveToFile(data.filepath, spec)
        if ok then
          boundPathByTool[spec.toolId] = data.filepath
          markClean(spec)
          log('I', tag, string.format('Saved %d %s -> %s', cnt, spec.itemNoun or 'item(s)', data.filepath))
        end
      end
    end,
    {{"JSON", ".json"}}, false, defaultDir, "File already exists.\nDo you want to overwrite the file?")
end

-- Draws the 'Save' icon button. Shown whenever a file is known, and it overwrites that file with no dialog: a button that has
-- to ask where to put it is Save As, which sits right beside it.
local function drawSaveButton(spec, size)
  local tag = spec.logTag or spec.toolId
  local path = boundPathByTool[spec.toolId]
  if not path then return end
  if editor.uiIconImageButton(spec.saveIcon or editor.icons.floppyDisk, size, spec.iconColor, nil, nil, spec.toolId .. '_saveSessionBtn') then
    local ok, cnt = saveToFile(path, spec)
    if ok then markClean(spec); log('I', tag, string.format('Saved %d %s -> %s', cnt, spec.itemNoun or 'item(s)', path)) end
  end
  im.tooltip('Save: overwrite ' .. path:match('[^/\\]+$') .. ' (this tool is bound to it). Terrain edits are not saved.')
end

-- Draws the 'Save As' icon button (caller only shows it when the tool is non-empty). Always opens the dialog and rebinds.
local function drawSaveAsButton(spec, size)
  if editor.uiIconImageButton(spec.saveAsIcon or editor.icons.floppyDiskPlus or editor.icons.floppyDisk, size, spec.iconColor, nil, nil, spec.toolId .. '_saveAsSessionBtn') then
    saveAsDialog(spec)
  end
  im.tooltip('Save As: write everything in this tool to a NEW .json file, and bind future Saves to it. Terrain edits are not saved.')
end

-- Draws the 'Load Session' icon button. With content already present the Replace/Merge modal decides; otherwise it loads straight in.
local function drawLoadButton(spec, size)
  if editor.uiIconImageButton(spec.loadIcon or editor.icons.folder, size, spec.iconColor, nil, nil, spec.toolId .. '_loadSessionBtn') then
    extensions.editor_fileDialog.openFile(
      function(data)
        if data and data.filepath then
          if (#spec.getItems() > 0 and not spec.noMerge) or spec.loadOptions then
            pendingByTool[spec.toolId] = data.filepath -- defer to the Replace/Merge modal.
          else
            commitLoad(spec, data.filepath, true) -- nothing to clash with (or a single-document tool): just load, replacing.
          end
        end
      end,
      {{"JSON", ".json"}}, false, "/")
  end
  im.tooltip(spec.noMerge and 'Load Session: load a building from a .json file (replaces the current one).'
    or 'Load Session: load from a .json file. If this tool already has content, you can Replace it or Merge the loaded items in.')
end

-- Replace/Merge modal (only while a load is pending for this tool). Popups are top-level windows, so this is safe to call from
-- inside a column layout.
local function drawModal(spec)
  local pending = pendingByTool[spec.toolId]
  if not pending then return end
  local title = "Load " .. (spec.displayName or spec.toolId) .. " Session"
  if not im.IsPopupOpen(title) then im.OpenPopup(title) end
  if im.BeginPopupModal(title, nil, im.WindowFlags_AlwaysAutoResize) then
    local has = #spec.getItems() > 0 and not spec.noMerge
    if has then
      im.TextWrapped("This tool already has " .. (spec.itemNoun or "items") ..
        ". Replace them with the loaded session, or merge the loaded ones in alongside the current ones?")
    else
      im.TextWrapped("Load " .. (pending:match('[^/\\]+$') or pending) .. "?")
    end
    -- What to take from the file, for a tool made of parts.
    if spec.loadOptions then
      im.Separator()
      spec.loadOptions()
    end
    im.Separator()
    if has then
      if im.Button("Replace", im.ImVec2(100, 0)) then commitLoad(spec, pending, true); im.CloseCurrentPopup() end
      im.SameLine()
      if im.Button("Merge", im.ImVec2(100, 0)) then commitLoad(spec, pending, false); im.CloseCurrentPopup() end
    else
      if im.Button("Load", im.ImVec2(100, 0)) then commitLoad(spec, pending, true); im.CloseCurrentPopup() end
    end
    im.SameLine()
    if im.Button("Cancel", im.ImVec2(100, 0)) then pendingByTool[spec.toolId] = nil; im.CloseCurrentPopup() end
    im.EndPopup()
  end
end

-- Folds a tool-global knob change.
local function updateGlobalsDirty(spec)
  if dirtyByTool[spec.toolId] or not spec.getGlobals then return end
  local saved = savedGlobalsByTool[spec.toolId]
  if saved ~= nil and not deepEqual(spec.getGlobals(), saved) then dirtyByTool[spec.toolId] = true end
end

-- Inline variant: draws Save (once a file is known) + Save As (when non-empty) + Load side-by-side + the modal.
local function renderButtons(spec)
  local size = spec.iconSize or im.ImVec2(36, 36)
  if #spec.getItems() > 0 then
    updateGlobalsDirty(spec)
    if boundPathByTool[spec.toolId] then drawSaveButton(spec, size); im.SameLine() end
    drawSaveAsButton(spec, size); im.SameLine()
  end
  drawLoadButton(spec, size)
  drawModal(spec)
end

-- Column variant: draws Save + Save As + Load as three grid cells.
local function renderButtonsColumns(spec)
  local size = spec.iconSize or im.ImVec2(36, 36)
  local nonEmpty = #spec.getItems() > 0
  if nonEmpty then updateGlobalsDirty(spec) end
  if nonEmpty and boundPathByTool[spec.toolId] then drawSaveButton(spec, size) else im.Dummy(size) end
  im.NextColumn()
  if nonEmpty then drawSaveAsButton(spec, size) else im.Dummy(size) end
  im.NextColumn()
  drawLoadButton(spec, size)
  im.NextColumn()
  drawModal(spec)
end


-- Public interface.
M.itemToTable = itemToTable
M.rehydrateVec3Array = rehydrateVec3Array
M.saveToFile = saveToFile
M.saveIfEdited = saveIfEdited
M.loadFromFile = loadFromFile
M.loadJson = loadJson
M.markEdited = markEdited
M.unbind = unbind
M.attachment = attachment
M.boundPath = boundPath
M.windowTitle = windowTitle
M.reattach = reattach
M.renderButtons = renderButtons
M.renderButtonsColumns = renderButtonsColumns

return M