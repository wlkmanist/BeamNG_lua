-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Save, Save As and Open for the single-document site tools.
-- A massing building, an open space and a car park are each ONE document whose home is a folder on a library shelf, and all
-- three bind to that folder the same way: Save writes back over it without asking, Save As names a new one and follows it
-- there, and Open swaps the whole document out. The site placer stands the copies; the editor cuts the original.
-- One copy of that here, made per tool by new(), so the three tools offer the same three buttons in the same order under the
-- same icons and the same wording.

local M = {}

-- Module dependencies.
local im = ui_imgui
local session = require('editor/toolUtilities/session')
local style = require('editor/toolUtilities/style')
local siteAssets = require('editor/toolUtilities/siteAssets')

-- Module constants.
local cols = style.getImguiCols('crystal')
local iconsBig = im.ImVec2(36, 36)


--- One tool's binding to its shelf. cfg:
---   toolId     the tool's id: its session key, and the tag its model.json was written under
---   kind       which shelf the document lives on ('building' / 'openSpace' / 'carPark')
---   noun       what one of them is called, for the tooltips
---   stateKey   the key the serialised document sits under inside model.json's `state`
---   editMode   the edit mode to select when the placer sends one here to be opened
---   hasContent (doc) -> is there yet anything worth saving
---   bakeRun    (doc) -> ok, and the folder written or the reason it could not be
---   applyState (state) -> load the document out of a model.json state; ok, and a reason when not
---   rename     (doc, name) put the name on the document through the tool's own undo
local function new(cfg)
  -- A folder to open and a name to save under are both acted on at the TOP of a frame rather than where the click happened:
  -- the dialog that produced either is still drawing itself, and opening one replaces the whole document under it.
  local pending, pendingName, onOpened = nil, nil, nil
  local lib = {}

  --- The document into the library under a name, which is also its folder. One path for Save, Save As and Rename.
  local function save(doc, name)
    if not (doc and name and name ~= '') then return false end
    if name ~= doc.name then cfg.rename(doc, name) end
    local ok, res = cfg.bakeRun(doc)
    if ok then
      session.reattach(cfg.toolId, { path = res }) -- bound and clean: Save now overwrites this without asking
      log('I', cfg.toolId, 'Saved ' .. cfg.noun .. ' -> ' .. tostring(res))
    else
      log('E', cfg.toolId, 'Save failed: ' .. tostring(res))
    end
    return ok
  end

  --- Open a baked site back up for editing, from the model the bake left beside its meshes, and bind to it so Save writes
  --- straight back. The placer's edit button comes through here too.
  local function open(dir)
    if not dir then return false, 'no folder' end
    local data = jsonReadFile(dir .. siteAssets.modelFile)
    local state = data and data.state
    -- Which editor cut it is written beside it precisely so the wrong one says so, rather than deserialising a building into
    -- a car park and producing nonsense out of it.
    if data and data.tool and data.tool ~= cfg.toolId then
      return false, 'that folder holds a ' .. tostring(data.tool) .. ' document'
    end
    if not (state and state[cfg.stateKey]) then return false, 'no editable model saved with this ' .. cfg.noun end
    local ok, err = cfg.applyState(state)
    if not ok then return false, err or 'could not load it' end
    if onOpened then onOpened() end
    session.reattach(cfg.toolId, { path = dir })
    editor.selectEditMode(editor.editModes[cfg.editMode])
    return true
  end

  --- Open: the editor's own folder browser, rooted at the shelf. A site IS a folder, so the folder navigated into is the pick
  --- - which is also why this is a folder dialog and not a file one. It resizes and remembers where it was; a list of names
  --- built here would be neither.
  local function askOpen()
    extensions.editor_fileDialog.openFile(
      function(data)
        local dir = data and data.path
        if not dir then return end
        if dir:sub(-1) ~= '/' then dir = dir .. '/' end
        pending = dir
      end,
      nil, true, siteAssets.ensureRoot(cfg.kind))
  end

  --- Save As: the same dialog Open uses, rooted at the shelf, where the name typed is the site's folder. A site lives in the
  --- library and nowhere else, so the folder browsed to is not part of the answer - the name is the whole of it.
  local function askSaveAs()
    extensions.editor_fileDialog.saveFile(
      function(data)
        local name = data and (data.filename or (data.filepath and data.filepath:match('([^/\\]+)[/\\]?$')))
        if name and name ~= '' then pendingName = name end
      end,
      {{ cfg.noun, "" }}, false, siteAssets.ensureRoot(cfg.kind))
  end

  --- Save, Save As and Open. Save appears once the site has a home in the library and overwrites it without asking; the one
  --- that has to ask which is Save As beside it.
  local function buttons(doc)
    local icons = editor.icons
    local id = cfg.toolId
    -- The name the dialog came back with, acted on now the dialog has finished drawing itself.
    if pendingName and doc then
      local name = pendingName
      pendingName = nil
      save(doc, name)
    end
    local named = session.boundPath(id) and doc and doc.name
    if cfg.hasContent(doc) then
      if named then
        if editor.uiIconImageButton(icons.floppyDisk, iconsBig, cols.blueB, nil, nil, id .. 'Save') then save(doc, doc.name) end
        im.tooltip('Save: write this ' .. cfg.noun .. ' back over "' .. doc.name .. '" in the library, meshes and all.')
        im.SameLine()
      end
      if editor.uiIconImageButton(icons.floppyDiskPlus or icons.floppyDisk, iconsBig, cols.blueB, nil, nil, id .. 'SaveAs') then
        askSaveAs()
      end
      im.tooltip('Save As: name this ' .. cfg.noun .. ' in the library and send future Saves there. The one it was under is left on the shelf.')
      im.SameLine()
    end
    if editor.uiIconImageButton(icons.folder, iconsBig, cols.blueB, nil, nil, id .. 'Open') then askOpen() end
    im.tooltip('Open a ' .. cfg.noun .. ' from the library: go into its folder and press Open.')
  end

  --- A site picked in the dialog, opened before anything is drawn: it replaces the whole document.
  local function settle()
    if not pending then return end
    local dir = pending
    pending = nil
    local ok, err = open(dir)
    if not ok then log('E', cfg.toolId, 'could not open ' .. dir .. ': ' .. tostring(err)) end
  end

  --- Off whatever site was open, so the next Save has to ask which rather than taking the last one.
  local function unbind()
    session.unbind(cfg.toolId)
    session.markEdited(cfg.toolId)
  end

  --- On the way out of the editor, so the placer has on its shelf what the editor was holding: a site with a home there is
  --- written back to it if it changed, and one without gets a home of its own, under a name that takes nobody else's folder.
  local function saveOnLeave(doc)
    if not (doc and cfg.hasContent(doc)) then return false end
    local at = session.attachment(cfg.toolId)
    if at.path and doc.name then return at.dirty and save(doc, doc.name) or false end
    local base = doc.name or cfg.noun
    local name, n = base, 1
    while siteAssets.exists(cfg.kind, siteAssets.slugify(cfg.kind, name)) do n = n + 1; name = base .. ' ' .. n end
    return save(doc, name)
  end

  --- The name to show in the window title when the document itself has none.
  local function boundName()
    local dir = session.boundPath(cfg.toolId)
    return dir and dir:match('([^/\\]+)[/\\]?$') or nil
  end

  lib.save = save
  lib.open = open
  lib.buttons = buttons
  lib.settle = settle
  lib.unbind = unbind
  lib.saveOnLeave = saveOnLeave
  lib.boundName = boundName
  --- The shelf folder the document is bound to, or nil before its first save.
  lib.boundPath = function() return session.boundPath(cfg.toolId) end
  lib.attachment = function() return session.attachment(cfg.toolId) end
  lib.reattach = function(at) session.reattach(cfg.toolId, at) end
  --- What to run once a loaded document is in place - the tool's own reload of anything derived from it.
  lib.setOnOpened = function(fn) onOpened = fn end
  return lib
end


-- Public interface.
M.new = new

return M