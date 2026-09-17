-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Generic persistent key/value store with lazy field indices

local M = {}

local msgpack = require("libs/lua-MessagePack/MessagePack")

local logTag = "datastore"

-- msgpack packs the store far faster than JSON (benchmarked on the UI cache ~30x write, ~2x read)
local USE_MSGPACK = true
local FILE_EXT = USE_MSGPACK and "bin" or "json"

-- storeName -> store = {
--   filePath, primaryField, loaded,
--   entries = { [primaryValue] = entry },          -- primary index (unique)
--   indices = { [field] = { [value] = { entry, ... } } }, -- lazy secondary indices (multi-valued)
--   chainField, chainResolveField,
-- }
local stores = {}

-- ignore values that aren't supposed to be indexed, so they will never occupy a slot
local function indexable(v)
  return v ~= nil -- and v ~= ""
end

local function normaliseDir(dir)
  dir = tostring(dir or "/temp"):gsub("\\", "/"):gsub("/+$", "")
  return dir
end

local function loadStore(store)
  if store.loaded then return end
  store.loaded = true
  store.entries = {}
  store.indices = {}
  local data
  if USE_MSGPACK then
    local raw = readFile(store.filePath)
    if raw and raw ~= "" then
      -- a truncated file (crash mid-write) just decodes to nothing -> treated as an empty store
      local ok, decoded = pcall(msgpack.unpack, raw)
      if ok then data = decoded else log("W", logTag, "failed to unpack store: " .. tostring(store.filePath)) end
    end
  else
    data = jsonReadFile(store.filePath)
  end
  if type(data) == "table" then
    local pf = store.primaryField
    for _, entry in ipairs(data) do
      if type(entry) == "table" and indexable(entry[pf]) then
        store.entries[entry[pf]] = entry
      end
    end
  end
end

local function isRegistered(storeName)
  return stores[storeName] ~= nil
end

local function getLoaded(storeName)
  local store = stores[storeName]
  if not store then
    log("W", logTag, "store not registered: " .. tostring(storeName))
    return nil
  end
  loadStore(store)
  return store
end

local function writeStore(store)
  local arr = {}
  for _, entry in pairs(store.entries) do
    arr[#arr + 1] = entry
  end
  if USE_MSGPACK then
    writeFile(store.filePath, msgpack.pack(arr))
  else
    jsonWriteFile(store.filePath, arr, false, nil, true)
  end
end

-- (re)build a secondary index for a field from the current entries
-- primaryField never lands here - it is served straight from store.entries
local function ensureIndex(store, field)
  local idx = store.indices[field]
  if idx then return idx end
  idx = {}
  for _, entry in pairs(store.entries) do
    local v = entry[field]
    if indexable(v) then
      local list = idx[v]
      if not list then list = {}; idx[v] = list end
      list[#list + 1] = entry
    end
  end
  store.indices[field] = idx
  return idx
end

-- add/remove an entry across every live secondary index (only fields that already have an index)
local function addToIndices(store, entry)
  for field, idx in pairs(store.indices) do
    local v = entry[field]
    if indexable(v) then
      local list = idx[v]
      if not list then list = {}; idx[v] = list end
      list[#list + 1] = entry
    end
  end
end

local function detachFromIndices(store, entry)
  for field, idx in pairs(store.indices) do
    local v = entry[field]
    if indexable(v) then
      local list = idx[v]
      if list then
        for i = #list, 1, -1 do
          if list[i] == entry then table.remove(list, i) end
        end
        if #list == 0 then idx[v] = nil end
      end
    end
  end
end

-- storeName, primaryField (unique storage key, default "name"), opts = { path, prefix }
-- file = <path>/<prefix?><storeName>.<bin|json> (prefix adds a trailing "-" when set)
local function register(storeName, primaryField, opts)
  if type(storeName) ~= "string" or storeName == "" then
    log("E", logTag, "register: invalid storeName")
    return false
  end
  opts = type(opts) == "table" and opts or {}
  local dir = normaliseDir(opts.path or "/temp")
  local prefix = opts.prefix
  local fileName = (type(prefix) == "string" and prefix ~= "")
    and (prefix .. "-" .. storeName .. "." .. FILE_EXT)
    or (storeName .. "." .. FILE_EXT)
  local existing = stores[storeName]
  stores[storeName] = {
    filePath = dir .. "/" .. fileName,
    primaryField = (type(primaryField) == "string" and primaryField ~= "") and primaryField or "name",
    loaded = false,
    entries = {},
    indices = {},
    -- keep any chain config across a re-register (e.g. a UI reload re-runs register)
    chainField = existing and existing.chainField or nil,
    chainResolveField = existing and existing.chainResolveField or nil,
  }
  return true
end

local function getEntry(storeName, field, value)
  local store = getLoaded(storeName)
  if not store then return nil end
  if field == store.primaryField then return store.entries[value] end
  local list = ensureIndex(store, field)[value]
  return list and list[1] or nil
end

-- flattened + deduped by primary
-- values must be a table
local function getEntries(storeName, field, values)
  local out = {}
  local store = getLoaded(storeName)
  if not store or type(values) ~= "table" then return out end
  local pf = store.primaryField
  local isPrimary = field == pf
  local idx = (not isPrimary) and ensureIndex(store, field) or nil
  local seen = {}
  local function take(entry)
    local pk = entry[pf]
    if not seen[pk] then seen[pk] = true; out[#out + 1] = entry end
  end
  for _, value in ipairs(values) do
    if isPrimary then
      local e = store.entries[value]
      if e then take(e) end
    else
      local list = idx[value]
      if list then for _, e in ipairs(list) do take(e) end end
    end
  end
  return out
end

-- primaryKey=false (default): table of unique values present for that field
-- primaryKey=true: same table but mapped to each entry's primary value (and non-unique)
local function getIndex(storeName, field, primaryKey)
  local out = {}
  local store = getLoaded(storeName)
  if not store then return out end
  if primaryKey then
    for pk, entry in pairs(store.entries) do
      local v = entry[field]
      if indexable(v) then out[pk] = v end
    end
    return out
  end
  if field == store.primaryField then
    for pk in pairs(store.entries) do out[#out + 1] = pk end
    return out
  end
  for v in pairs(ensureIndex(store, field)) do
    out[#out + 1] = v
  end
  return out
end

local function getAll(storeName)
  local out = {}
  local store = getLoaded(storeName)
  if not store then return out end
  for _, entry in pairs(store.entries) do
    out[#out + 1] = entry
  end
  return out
end

local function hasEntry(storeName, field, value)
  local store = getLoaded(storeName)
  if not store then return false end
  if field == store.primaryField then return store.entries[value] ~= nil end
  local list = ensureIndex(store, field)[value]
  return list ~= nil and #list > 0
end

-- lookup, then follow the seed's chainField (array of keys)
local function getChain(storeName, field, value)
  local out = {}
  local store = getLoaded(storeName)
  if not store then return out end
  local seed = getEntry(storeName, field, value)
  if not seed then return out end
  local pf = store.primaryField
  local seen = { [seed[pf]] = true }
  out[#out + 1] = seed
  local chainField, resolveField = store.chainField, store.chainResolveField
  if not chainField or not resolveField then return out end
  local stack = { seed }
  while #stack > 0 do
    local entry = table.remove(stack)
    local keys = entry[chainField]
    if type(keys) == "table" then
      for _, key in ipairs(keys) do
        local rel = getEntry(storeName, resolveField, key)
        if rel and not seen[rel[pf]] then
          seen[rel[pf]] = true
          out[#out + 1] = rel
          stack[#stack + 1] = rel
        end
      end
    end
  end
  return out
end

-- upsert by primaryField: detach the old entry, then re-index
local function putEntries(storeName, entries)
  local store = getLoaded(storeName)
  if not store or type(entries) ~= "table" then return false end
  local pf = store.primaryField
  local changed = false
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and indexable(entry[pf]) then
      local pk = entry[pf]
      local existing = store.entries[pk]
      if existing then detachFromIndices(store, existing) end
      store.entries[pk] = entry
      addToIndices(store, entry)
      changed = true
    elseif type(entry) == "table" then
      log("W", logTag, "putEntries: entry missing primary field '" .. tostring(pf) .. "' in " .. tostring(storeName))
    end
  end
  if changed then writeStore(store) end
  return changed
end

local function removeEntries(storeName, field, values)
  local store = getLoaded(storeName)
  if not store or type(values) ~= "table" then return false end
  local pf = store.primaryField
  local isPrimary = field == pf
  local idx = (not isPrimary) and ensureIndex(store, field) or nil
  -- collect first, so we don't mutate an index list while walking it
  local targets, seen = {}, {}
  local function mark(entry)
    local pk = entry[pf]
    if not seen[pk] then seen[pk] = true; targets[#targets + 1] = entry end
  end
  for _, value in ipairs(values) do
    if isPrimary then
      local e = store.entries[value]
      if e then mark(e) end
    else
      local list = idx[value]
      if list then for _, e in ipairs(list) do mark(e) end end
    end
  end
  if #targets == 0 then return false end
  for _, entry in ipairs(targets) do
    detachFromIndices(store, entry)
    store.entries[entry[pf]] = nil
  end
  writeStore(store)
  return true
end

local function clear(storeName)
  local store = stores[storeName]
  if not store then return false end
  store.loaded = true
  store.entries = {}
  store.indices = {}
  writeStore(store)
  return true
end

-- chainField: entry field holding an array of related keys
local function setChain(storeName, chainField, field)
  local store = stores[storeName]
  if not store then
    log("W", logTag, "setChain: store not registered: " .. tostring(storeName))
    return false
  end
  store.chainField = chainField
  store.chainResolveField = field
  loadStore(store)
  if field ~= store.primaryField then ensureIndex(store, field) end
  return true
end

local function onInit()
  setExtensionUnloadMode(M, "manual")
end

-- carry only the lightweight registrations across a hot reload, NOT the entries
local function onSerialize()
  local registrations = {}
  for name, store in pairs(stores) do
    registrations[name] = {
      filePath = store.filePath,
      primaryField = store.primaryField,
      chainField = store.chainField,
      chainResolveField = store.chainResolveField,
    }
  end
  return { registrations = registrations }
end

local function onDeserialized(data)
  stores = {}
  if type(data) ~= "table" or type(data.registrations) ~= "table" then return end
  for name, reg in pairs(data.registrations) do
    stores[name] = {
      filePath = reg.filePath,
      primaryField = reg.primaryField or "name",
      loaded = false,
      entries = {},
      indices = {},
      chainField = reg.chainField,
      chainResolveField = reg.chainResolveField,
    }
  end
end

M.register = register
M.isRegistered = isRegistered
M.getEntry = getEntry
M.getEntries = getEntries
M.getIndex = getIndex
M.getChain = getChain
M.getAll = getAll
M.hasEntry = hasEntry
M.putEntries = putEntries
M.removeEntries = removeEntries
M.clear = clear
M.setChain = setChain

M.onInit = onInit
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
