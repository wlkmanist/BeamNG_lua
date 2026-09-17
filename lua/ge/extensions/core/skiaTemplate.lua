-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Skia template driver: the whole license-plate variable subsystem lives here.
-- It generates text from design var patterns, builds the var map ({plate},
-- {line1}/{line2}, generated/preset vars) and substitutes every {key} into a
-- copy of the chosen format's flex tree. C++ only renders the resolved template
-- (see veh:renderLicensePlateSkia / templateRenderMapsPng).

local M = {}

local random = math.random

local function nextUtf8CharPos(s, pos)
  repeat
    pos = pos + 1
    local c = s:byte(pos)
  until pos > #s or not (c >= 0x80 and c <= 0xBF)
  return pos
end

-- Byte position `n` UTF-8 codepoints after byte `pos` in `s` (1-based)
local function utf8Advance(s, pos, n)
  for _ = 1, n do
    if pos > #s then break end
    pos = nextUtf8CharPos(s, pos)
  end
  return pos
end

local function randChar(rand, set)
  if type(set) ~= "string" or #set == 0 then return "" end
  local count, pos = 0, 1
  while pos <= #set do
    count = count + 1
    pos = nextUtf8CharPos(set, pos)
  end

  local target = rand(1, count)
  pos = 1
  for _ = 2, target do pos = nextUtf8CharPos(set, pos) end
  return set:sub(pos, nextUtf8CharPos(set, pos) - 1)
end

-- Deterministic per-string hash (djb2) so a plate's preset picks are stable across
-- reloads and multiplayer clients (which all resolve from the same synced text).
local function strHash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end

local function seededRandom(seed)
  local n = 0
  return function(a, b)
    n = n + 1
    return a + (strHash(seed .. ":" .. n) % (b - a + 1))
  end
end

local function generateVarText(vdef, veh, rand)
  if not (vdef and vdef.default) then return nil end

  local pattern = vdef.default
  if vdef.formats then
    local formattxt = veh and veh:getDynDataFieldbyName("licenseFormats", 0)
    local formats = (formattxt and #formattxt > 0 and jsonDecode(formattxt)) or { "30-15" }
    for _, f in ipairs(formats) do
      local override = vdef.formats[f]
      if override and override.default then pattern = override.default end
    end
  end
  if type(pattern) == "table" then pattern = pattern[rand(1, #pattern)] end

  local sets = vdef.charsets or {}
  return (tostring(pattern):gsub("{([%w_]+)}", function(tok)
    local set = sets[tok]
    if type(set) == "string" then return randChar(rand, set) end
    if type(set) == "table" then return tostring(set[rand(1, #set)]) end
    if tok == "vid" then return veh and tostring(veh:getId()) or "0" end
    if tok == "vname" then return veh and tostring(veh:getJBeamFilename()) or "" end
    return "{" .. tok .. "}"
  end))
end

-- Generate plate text from `design.vars.plate`: literal text plus {token} placeholders.
-- With no usable var it falls back to an "AAA-0000" style.
local function generateText(design, veh)
  local text = generateVarText(design and design.vars and design.vars.plate, veh, random)
  if text then return text end

  local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  return randChar(random, A) .. randChar(random, A) .. randChar(random, A) .. '-'
      .. random(0, 9) .. random(0, 9) .. random(0, 9) .. random(0, 9)
end

local function blankIfEmpty(s)
  return s == "" and " " or s
end

local function substituteVar(vars, tok)
  local value = vars[tok]
  return value == nil and ("{" .. tok .. "}") or blankIfEmpty(value)
end

local function substitute(node, vars)
  if type(node) ~= "table" then return end
  if type(node.text) == "string" then
    node.text = blankIfEmpty(node.text:gsub("{([%w_]+)}", function(tok) return substituteVar(vars, tok) end))
  end
  if type(node.children) == "table" then
    for _, c in ipairs(node.children) do substitute(c, vars) end
  end
end

local function mergePatch(dst, patch)
  if type(dst) ~= "table" or type(patch) ~= "table" then return end
  for k, v in pairs(patch) do
    if type(v) == "table" and type(dst[k]) == "table" then
      for k2, v2 in pairs(v) do dst[k][k2] = v2 end
    else
      dst[k] = v
    end
  end
end

local function patchNodesByName(node, patches)
  if type(node) ~= "table" then return end
  local patch = node.name and patches[node.name]
  if patch then mergePatch(node, patch) end
  if type(node.children) == "table" then
    for _, c in ipairs(node.children) do patchNodesByName(c, patches) end
  end
end

local function callDesignLogic(design, format, text)
  if type(design) ~= "table" or type(design.logic) ~= "string" or design.logic == "" then return nil end
  local ok, mod = pcall(require, design.logic)
  if not ok or type(mod) ~= "table" or type(mod.resolve) ~= "function" then return nil end
  local ok2, result = pcall(mod.resolve, text, format, design)
  if ok2 and type(result) == "table" then return result end
  return nil
end

-- Default render layers per design type: license plates are physical objects (full PBR
-- set), everything else (name tags, overlays, ...) is a flat emissive diffuse. An explicit
-- `maps` list on the design/format overrides this.
local function defaultMaps(designType)
  if designType == "licenseplate" then return { "diffuse", "normal", "specular", "metallic" } end
  return { "diffuse" }
end

-- Resolve one format of a design into a flat template the C++ renderer understands:
-- { size, background, normal, emboss, finish, maps, root } with every {key} already
-- substituted. `maps` names which PBR maps to render (diffuse always); it defaults from
-- the design `type` (see defaultMaps) and an explicit `format.maps` overrides it.
-- `finish` holds the plate-wide PBR defaults (0..1): { roughness,
-- metallic } for the base and { fgRoughness, fgMetallic } for drawn text/logos; any
-- node can override with its own `metallic`/`roughness` (e.g. raised foil chars).
-- Returns nil if the format/root is missing.
local function resolveFormat(design, format, text, veh)
  local fmt = design and design.format and design.format[format]
  if type(fmt) ~= "table" or type(fmt.root) ~= "table" then return nil end
  text = blankIfEmpty(text or "")

  local vars = { plate = text, line1 = text, line2 = "" }
  -- multi-segment split (segments) for designs that lay out the text in parts,
  -- [start, end) ranges (0-based, end-exclusive) -> seg1..segN
  if type(fmt.segments) == "table" then
    for i, range in ipairs(fmt.segments) do
      vars["seg" .. i] = text:sub((tonumber(range[1]) or 0) + 1, tonumber(range[2]) or 0)
    end
  end
  -- two-line split (limit/limit2) for square plates that stack the text.
  -- limit/limit2 count UTF-8 codepoints, not bytes, to support multi-byte characters.
  local limit, limit2 = tonumber(fmt.limit) or 0, tonumber(fmt.limit2) or 0
  if limit2 > 0 then
    local p1 = utf8Advance(text, 1, limit)
    vars.line1 = text:sub(1, p1 - 1)
    if p1 <= #text then vars.line2 = text:sub(p1, utf8Advance(text, p1, limit2) - 1) end
  elseif limit > 0 then
    local p1 = utf8Advance(text, 1, limit)
    if p1 <= #text then
      vars.line1 = text:sub(1, p1 - 1)
      vars.line2 = text:sub(p1)
    end
  end

  -- preset/generated vars are stable per plate text so clients resolve the same values.
  if type(design.vars) == "table" then
    for k, vdef in pairs(design.vars) do
      if type(vdef) == "table" then
        local preset = vdef.preset
        if type(preset) == "table" and #preset > 0 then
          vars[k] = preset[(strHash(text .. ":" .. k) % #preset) + 1]
        elseif k ~= "plate" and vdef.default ~= nil then
          vars[k] = generateVarText(vdef, veh, seededRandom(text .. ":" .. k))
        end
      end
    end
  end

  local background, normal = fmt.background, fmt.normal
  local extra = callDesignLogic(design, format, text)
  if extra and type(extra.vars) == "table" then
    for k, v in pairs(extra.vars) do vars[k] = v end
  end

  local root = deepcopy(fmt.root)
  substitute(root, vars)
  if extra and type(extra.nodes) == "table" then patchNodesByName(root, extra.nodes) end
  if extra then
    if extra.background ~= nil then background = extra.background end
    if extra.normal ~= nil then normal = extra.normal end
  end

  return { size = fmt.size, background = background, normal = normal, emboss = fmt.emboss, finish = fmt.finish,
           maps = fmt.maps or defaultMaps(design.type or "licenseplate"), root = root }
end

-- Resolve a generic (non-plate) template - flat { size, background?, root } with {key}
-- vars - into the same shape the C++ map renderer / layout consume: deep-copy and
-- substitute every {key} in text from `vars`. `maps` defaults from the design `type`
-- (non-plate types -> diffuse only) unless set explicitly. Returns nil if it has no root.
local function resolveTemplate(design, vars)
  if type(design) ~= "table" or type(design.root) ~= "table" then return nil end
  local root = deepcopy(design.root)
  substitute(root, vars or {})
  return { size = design.size, background = design.background, normal = design.normal, emboss = design.emboss, finish = design.finish,
           maps = design.maps or defaultMaps(design.type), root = root }
end

-- Resolve + submit to the engine's Skia render thread, which binds the result to the
-- vehicle's @licenseplate-* material tags when done. Returns false if not renderable.
local function renderToVehicle(veh, design, format, text)
  if not (veh and veh.renderLicensePlateSkia) then return false end
  local resolved = resolveFormat(design, format, text, veh)
  if not resolved then return false end
  return veh:renderLicensePlateSkia(jsonEncode(resolved), format) == true
end

-- Dev tool: benchmark CPU vs GPU plate-map rendering. `design` is a design table or a
-- VFS path to a *.sktemplate.json (default: the stock plate); `format` defaults to the
-- design's first. Returns the engine's CPU-vs-GPU timing summary (also logged). Renders
-- synchronously on the calling thread, so run it when no plate is spawning.
local function benchmark(design, format, text, iterations)
  if type(skiaBenchmark) ~= "function" then return "skiaBenchmark unavailable (needs a dev build with Skia)" end
  if design == "" then design = nil end
  if type(design) ~= "table" then
    design = jsonReadFile(design or "vehicles/common/licenseplates/default/licensePlate-default.sktemplate.json")
  end
  if type(design) ~= "table" then return "benchmark: design not found" end
  if type(design.format) ~= "table" and type(design.data) == "table" then design = design.data end
  -- a flat template ({ size, root, ... }, e.g. the test scenes) is benchmarked as-is;
  -- a plate design resolves one of its formats first.
  if type(design.root) == "table" and design.size ~= nil and type(design.format) ~= "table" then
    return skiaBenchmark(jsonEncode(design), iterations or 20)
  end
  if not format or format == "" then format = (type(design.format) == "table" and next(design.format)) or "" end
  local resolved = resolveFormat(design, format, text or "ABC-1234")
  if not resolved then return "benchmark: format '" .. tostring(format) .. "' not renderable" end
  return skiaBenchmark(jsonEncode(resolved), iterations or 20)
end

M.generateText = generateText
M.resolveFormat = resolveFormat
M.resolveTemplate = resolveTemplate
M.renderToVehicle = renderToVehicle
M.benchmark = benchmark

return M
