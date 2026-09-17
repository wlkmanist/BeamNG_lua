-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'licensePlateDesign'

local FORMAT_US = '30-15'
local DEFAULT_PLATE_WIDTH = 512
local DEFAULT_PLATE_HEIGHT = 256
local DEFAULT_LINE_HEIGHT = 80
local DEFAULT_ANCHOR_BIAS = 0.5
local DEFAULT_EMBOSS = 3.0
local MAX_PLATE_LENGTH = 32
local LIGHT_TINT_LUMINANCE = 224
local LEGACY_BASELINE_FACTOR = 1.5

local DEFAULT_FINISH = { roughness = 1.0, metallic = 0.0, fgRoughness = 0.7, fgMetallic = 0.0 }
local CHARSET_DEFAULTS = { d = '0123456789', c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', D = '123456789' }
local ROOT_STYLE = { justifyContent = 'center', alignItems = 'center' }
local ROOT_STYLE_PADDED = { justifyContent = 'center', alignItems = 'center', paddingLeft = 24, paddingRight = 24 }
local FONT_FALLBACKS = {
    { 'italy', 'plateIT' }, { '_it', 'plateIT' },
    { 'fe', 'plateFE' }, { 'europe', 'plateFE' },
}

local generatorBiasCache = {}

local function vfsAssetExists(path)
    if not path or path == '' then return false end
    if path:match('^#') or path:match('^rgb') then return true end
    return FS:fileExists(path)
end

local function resolveDesignPaths(path)
    local skPath = path
    if path:match('%.json$') and not path:match('%.sktemplate%.json$') then
        skPath = path:gsub('%.json$', '.sktemplate.json')
    end
    local legacyPath = skPath:match('%.sktemplate%.json$') and skPath:gsub('%.sktemplate%.json$', '.json') or path
    return skPath, legacyPath
end

local function convertPattern(pattern)
    if type(pattern) == 'table' then
        local out = {}
        for i = 1, #pattern do out[i] = convertPattern(pattern[i]) end
        return out
    end
    -- legacy printf tokens (%d, %c, %l) become sktemplate {token} placeholders
    return tostring(pattern):gsub('%%([%w_]+)', function(token)
        return token == 'l' and '{c}' or ('{' .. token .. '}')
    end)
end

local function buildCharsets(patternData, pattern)
    local charsets = {}
    for key, value in pairs(patternData or {}) do charsets[key] = value end
    local patStr = type(pattern) == 'table' and table.concat(pattern) or pattern
    for token in patStr:gmatch('{([%w_]+)}') do
        if CHARSET_DEFAULTS[token] and not charsets[token] then
            charsets[token] = CHARSET_DEFAULTS[token]
        end
    end
    return charsets
end

local function parseColor(compact)
    local lower = string.lower(compact)
    if lower == 'white' then return 255, 255, 255 end
    if lower == 'black' then return 0, 0, 0 end
    local r, g, b = lower:match('^#(%x%x)(%x%x)(%x%x)$')
    if r then return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) end
    r, g, b = lower:match('^#(%x)(%x)(%x)$')
    if r then return tonumber(r, 16) * 17, tonumber(g, 16) * 17, tonumber(b, 16) * 17 end
    r, g, b = lower:match('^rgb%((%d+),(%d+),(%d+)%)$')
    if r then return tonumber(r), tonumber(g), tonumber(b) end
end

local function generatorTextAnchorBias(generatorPath)
    if not generatorPath or generatorPath == '' then return DEFAULT_ANCHOR_BIAS end
    local cached = generatorBiasCache[generatorPath]
    if cached then return cached end
    local bias = DEFAULT_ANCHOR_BIAS
    if FS:fileExists(generatorPath) then
        -- legacy HTML generators anchor text at textWidth * factor (0.45 for CEP, 0.5 centered)
        local factor = (readFile(generatorPath) or ''):match('textWidth%s*%*%s*([%d%.]+)')
        bias = tonumber(factor) or DEFAULT_ANCHOR_BIAS
    end
    generatorBiasCache[generatorPath] = bias
    return bias
end

local function formatTextAnchorBias(fmt)
    local text = fmt.text or {}
    return tonumber(fmt.bias) or tonumber(text.bias) or tonumber(text.anchorBias)
        or generatorTextAnchorBias(fmt.generator)
end

local function modFontAssets(characterLayout, spriteImg)
    if not characterLayout then return nil end
    local lower = string.lower(characterLayout)
    if lower:match('%.[ot]tf$') then
        return FS:fileExists(characterLayout) and { font = characterLayout }
    end
    if not (lower:match('%.json$') and FS:fileExists(characterLayout)) then return nil end
    local atlas = spriteImg
    if not vfsAssetExists(atlas) then
        local layout = jsonReadFile(characterLayout)
        local file = layout and layout.pages and layout.pages[1] and layout.pages[1].file
        if file then atlas = characterLayout:gsub('[^/]+$', '') .. file end
    end
    if not vfsAssetExists(atlas) then return nil end
    return { font = characterLayout, fontAtlas = atlas }
end

local function builtinFontForLayout(characterLayout)
    if not characterLayout then return 'plate' end
    local lower = string.lower(characterLayout)
    for _, entry in ipairs(FONT_FALLBACKS) do
        if lower:find(entry[1], 1, true) then return entry[2] end
    end
    return 'plate'
end

local function numberOrTable(value, default, index)
    if type(value) == 'table' then
        local field = index == 2 and (value.y or value.height) or (value.x or value.width)
        return tonumber(value[index or 1]) or tonumber(field) or tonumber(value.value) or default
    end
    return tonumber(value) or default
end

local function readFontMetrics(characterLayout)
    local common = characterLayout and (jsonReadFile(characterLayout) or {}).common or {}
    return numberOrTable(common.lineHeight, DEFAULT_LINE_HEIGHT), numberOrTable(common.base, DEFAULT_LINE_HEIGHT)
end

local function resolveTextColor(text, characterLayout, usesModFont)
    local color = text.color or 'black'
    local r, g, b = parseColor(color:gsub('%s+', ''))
    if not r then return color end
    -- built-in fonts are tinted, near-white legacy colors would render invisible
    if not usesModFont and characterLayout and (0.299 * r + 0.587 * g + 0.114 * b) >= LIGHT_TINT_LUMINANCE then
        return 'black'
    end
    return string.format('#%02x%02x%02x', r, g, b)
end

local function buildPlateRoot(text, size, characterLayout, spriteImg, anchorBias)
    local modFont = modFontAssets(characterLayout, spriteImg)
    local font = modFont and modFont.font or builtinFontForLayout(characterLayout)
    local fontAtlas = modFont and modFont.fontAtlas
    local color = resolveTextColor(text, characterLayout, modFont ~= nil)
    local lineHeight, base = readFontMetrics(characterLayout)
    local fontSize = round(lineHeight * numberOrTable(text.scale, 1.0))
    local plateHeight = size[2]

    local function textNode(name, varText, style)
        return {
            name = name, type = 'text', text = varText, font = font, fontAtlas = fontAtlas,
            color = color, fontSize = fontSize, fit = 'shrink', letterSpacing = 0, style = style,
        }
    end

    local function anchoredLine(name, varText, xNorm, yNorm, extra)
        local lineFontSize = (extra and extra.fontSize) or fontSize
        local node = textNode(name, varText, {
            position = 'absolute', left = 0, right = 0,
            top = round(yNorm * plateHeight - LEGACY_BASELINE_FACTOR * lineHeight + base),
            height = lineFontSize,
        })
        node.anchorX = xNorm
        node.anchorBias = anchorBias
        if extra then for k, v in pairs(extra) do node[k] = v end end
        return node
    end

    local x = numberOrTable(text.x, 0.5)
    local style, children = ROOT_STYLE, nil
    if text.lines and #text.lines > 0 then
        children = {}
        for i, line in ipairs(text.lines) do
            local pos = line.pos or {}
            children[i] = anchoredLine('seg' .. i, '{seg' .. i .. '}', numberOrTable(pos, 0.5, 1), numberOrTable(pos, 0.5, 2), {
                fontSize = round(lineHeight * numberOrTable(pos, 1.0, 3)),
                letterSpacing = numberOrTable(line.xAdv, 0) + 2,
                atlasYOffset = numberOrTable(line.yMain, 0),
            })
        end
    elseif numberOrTable(text.limit2, 0) > 0 then
        children = {
            anchoredLine('line1', '{line1}', x, numberOrTable(text.y, 0.5)),
            anchoredLine('line2', '{line2}', numberOrTable(text.x2, x), numberOrTable(text.y2, numberOrTable(text.y, 0.5))),
        }
    elseif text.y then
        children = { anchoredLine('plate', '{plate}', x, numberOrTable(text.y, 0.5)) }
    else
        style = ROOT_STYLE_PADDED
        children = { textNode('plate', '{plate}', { width = '94%' }) }
    end
    return { name = 'root', style = style, children = children }
end

local function translateLegacyFormat(fmt)
    local diffuse = fmt.diffuse or {}
    local bump = fmt.bump or {}
    local text = fmt.text or {}
    local size = { numberOrTable(fmt.size, DEFAULT_PLATE_WIDTH, 1), numberOrTable(fmt.size, DEFAULT_PLATE_HEIGHT, 2) }
    local out = {
        size = size,
        background = diffuse.backgroundImg or diffuse.fillStyle or '#ffffff',
        emboss = DEFAULT_EMBOSS,
        finish = DEFAULT_FINISH,
        root = buildPlateRoot(text, size, fmt.characterLayout, diffuse.spriteImg, formatTextAnchorBias(fmt)),
    }
    if bump.backgroundImg and vfsAssetExists(bump.backgroundImg) then out.normal = bump.backgroundImg end
    if text.lines and #text.lines > 0 then
        out.segments = {}
        for i, line in ipairs(text.lines) do
            local limit = line.limit or {}
            out.segments[i] = { limit[1] or 0, limit[2] or 0 }
        end
    else
        if text.limit then out.limit = text.limit end
        if text.limit2 then out.limit2 = text.limit2 end
    end
    return out
end

local function translateV2ToV3(design)
    local src = design.data or design
    local out = {
        name = design.name or 'legacy',
        version = 3,
        type = 'licenseplate',
        format = {},
    }
    if src.gen then
        local pattern = convertPattern(src.gen.pattern)
        out.vars = {
            plate = {
                type = 'string',
                default = pattern,
                charsets = buildCharsets(src.gen.patternData, pattern),
                minLength = 0,
                maxLength = MAX_PLATE_LENGTH,
            },
        }
    end
    for key, fmt in pairs(src.format or {}) do
        out.format[key] = translateLegacyFormat(fmt)
    end
    return out
end

local function translateLegacyDesign(legacy)
    if not legacy then return nil end
    local ver = legacy.version or 0
    if ver >= 3 then return legacy end
    if ver == 2 or (legacy.data and legacy.data.format) then
        return translateV2ToV3(legacy)
    end
    return translateV2ToV3({ name = legacy.name, data = { format = { [FORMAT_US] = legacy.data or legacy } } })
end

local function mergeLegacyFormats(design, legacyPath)
    local legacy = jsonReadFile(legacyPath)
    if not legacy then return design end
    local translated = translateLegacyDesign(legacy)
    if not translated then return design end
    for key, fmt in pairs(translated.format) do
        if not design.format[key] then design.format[key] = fmt end
    end
    return design
end

local function loadDesign(path)
    if not path or path == '' then return nil end

    local skPath, legacyPath = resolveDesignPaths(path)
    local design = jsonReadFile(skPath)
    if design and design.format then
        return mergeLegacyFormats(design, legacyPath)
    end

    if not FS:fileExists(legacyPath) then
        legacyPath = FS:fileExists(path) and path or nil
        if not legacyPath then
            log('W', logTag, 'could not find ' .. path)
            return nil
        end
    end

    design = jsonReadFile(legacyPath)
    if not design then
        log('W', logTag, 'could not read ' .. legacyPath)
        return nil
    end
    return translateLegacyDesign(design)
end

M.loadDesign = loadDesign

return M
