-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The shelves a placed SITE comes off: a building, an open space, a car park. Three editors bake to them and one placer
-- reads them all, so where they live and what the files in them are called belongs to neither end. Written out once here
-- instead, because a root spelled one way in the editor that writes it and another in the tool that lists it is a library
-- that is always empty and never errors.
--
-- A site is one folder named after its slug, holding three things and nothing else:
--   <manifest>  what the placer needs to stand it up: bounds, kit transforms, the ground plan, lamps, plants.
--   model.json  the editable document, so the placer's Edit button can open it straight back up in the editor that cut it.
--   shell.dae   the unique geometry, LODs and collision in the one file.
-- The manifest is named per kind rather than manifest.json, so a folder tells you what it is without being parsed.

local M = {}

-- Module constants.
-- Every kind of thing the placer can stand on the ground. `editor` is the extension its Edit button hands a folder to,
-- which is allowed to be absent -- a kind whose editor is not loaded still lists and still places, it just cannot be
-- opened up.
local KINDS = {
  { id = 'building', noun = 'building', label = 'Buildings', icon = 'location_city',
    root = '/assets/massingBuildings/', manifest = 'building.json', editor = 'editor_massingEditor' },
  { id = 'openSpace', noun = 'open space', label = 'Open Spaces', icon = 'nature',
    root = '/assets/openSpaces/', manifest = 'openSpace.json', editor = 'editor_openSpaceEditor' },
  { id = 'carPark', noun = 'car park', label = 'Car Parks', icon = 'local_parking',
    root = '/assets/carParks/', manifest = 'carPark.json', editor = 'editor_parkingLotEditor' },
}
local MODEL = 'model.json'
local SHELL = 'shell.dae'

local BY_ID = {}
for i = 1, #KINDS do BY_ID[KINDS[i].id] = KINDS[i] end

-- Module state.
local watchers = {} -- see onWritten


local function kindOf(kind)
  return BY_ID[kind or ''] or KINDS[1]
end

--- A folder name from the thing's own name. Anything a filesystem would argue about becomes an underscore, so a rebake of a
--- renamed-but-same site overwrites its own folder instead of quietly growing a second one beside it.
local function slugify(kind, name)
  local k = kindOf(kind)
  local s = tostring(name or k.noun):lower()
  s = s:gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if s == '' then s = k.noun:gsub('[^%w]+', '_') end
  return s
end

local function rootOf(kind) return kindOf(kind).root end

local function folderFor(kind, slug) return rootOf(kind) .. slug .. '/' end

local function manifestPath(kind, dir) return dir .. kindOf(kind).manifest end
local function modelPath(dir) return dir .. MODEL end
local function shellPath(dir) return dir .. SHELL end

--- Make sure the shelf's folder is really there. The file dialog only LISTS the path it is given - it will not create one -
--- so without this the first bake on a fresh install opens the dialog on a folder that does not exist, showing nothing.
local function ensureRoot(kind)
  local root = rootOf(kind)
  if FS and not FS:directoryExists(root) then FS:directoryCreate(root, true) end
  return root
end

--- Clear a folder before rewriting it, so a rebake producing less than the last one leaves nothing stale behind. The engine
--- writes a .cdae cache beside a .dae, which has to go too or it is loaded in preference to the new file.
local function wipe(dir)
  if not FS or not FS:directoryExists(dir) then return end
  local files = FS:findFiles(dir, '*', -1, true, false)
  if files then for i = 1, #files do FS:removeFile(files[i]) end end
end

--- Clear the folder out and hand it back ready to be written into. Every bake starts here, so a rebake never leaves half of
--- the last one lying about.
local function prepare(kind, slug)
  ensureRoot(kind)
  local dir = folderFor(kind, slug)
  if FS and not FS:directoryExists(dir) then FS:directoryCreate(dir, true) end
  wipe(dir)
  return dir
end

--- The editable document, beside its meshes. `tool` is the editor that wrote it, so a folder opened by the wrong one says so
--- instead of quietly producing nonsense.
local function writeModel(dir, tool, state)
  return jsonWriteFile(modelPath(dir), { version = 1, tool = tool, state = state }, true) ~= false
end

--- Be told whenever a site is written to a shelf.
local function onWritten(fn)
  if type(fn) == 'function' then watchers[#watchers + 1] = fn end
end

--- Written compact, unlike the model beside it. Nobody opens a manifest by hand -- it is thousands of instance transforms
--- and a thousand mark runs -- and indenting it doubles a file the library has to read in full just to list the shelf.
local function writeManifest(kind, dir, manifest)
  if jsonWriteFile(manifestPath(kind, dir), manifest) == false then return false end
  for i = 1, #watchers do watchers[i](kind, manifest.slug) end
  return true
end

--- Is this name already taken? What Save As asks before it writes over somebody else's work.
local function exists(kind, slug)
  return (FS and FS:directoryExists(folderFor(kind, slug))) and true or false
end

--- Off the shelf, folder and all. A rename is a save under the new name followed by this on the old one, which keeps the name
--- stored in the manifest honest - moving the folder alone would leave the old name inside it.
local function remove(kind, slug)
  local dir = folderFor(kind, slug)
  if not (FS and FS:directoryExists(dir)) then return false, 'not in the library' end
  wipe(dir)
  if FS.directoryRemove then FS:directoryRemove(dir) end
  return true, dir
end

local function byName(a, b) return (a.name or '') < (b.name or '') end

--- Everything already on one shelf. Reads only the manifests, so listing a folder of fifty costs fifty small json reads and
--- not one mesh. Each comes back knowing its own folder and its own kind, which is all the placer needs to stand it up.
local function list(kind)
  local k = kindOf(kind)
  local out = {}
  if not FS or not FS:directoryExists(k.root) then return out end
  local dirs = FS:directoryList(k.root, false, true) or {}
  for i = 1, #dirs do
    local dir = dirs[i]
    if dir:sub(-1) ~= '/' then dir = dir .. '/' end
    local m = jsonReadFile(dir .. k.manifest)
    if m and m.slug then
      m.dir = dir
      m.kind = k.id
      out[#out + 1] = m
    end
  end
  table.sort(out, byName)
  return out
end


-- Public interface.
M.kinds = KINDS
M.modelFile = MODEL
M.shellFile = SHELL

M.kindOf = kindOf
M.slugify = slugify
M.rootOf = rootOf
M.folderFor = folderFor
M.manifestPath = manifestPath
M.modelPath = modelPath
M.shellPath = shellPath
M.ensureRoot = ensureRoot
M.wipe = wipe
M.prepare = prepare
M.writeModel = writeModel
M.writeManifest = writeManifest
M.onWritten = onWritten
M.exists = exists
M.remove = remove
M.list = list

return M