-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

-- linear Rec.709/sRGB via Planckian locus -> xy -> XYZ -> RGB
local function kelvinToRGBLinear(k)
  k = clamp(k or 6500, 1667, 25000)

  local x, y
  if k <= 4000 then
    -- Planckian locus approximation for 1667K–4000K
    local t = k
    x = -0.2661239e9/(t^3) - 0.2343580e6/(t^2) + 0.8776956e3/t + 0.179910
    y = -1.1063814*(x^3) - 1.34811020*(x^2) + 2.18555832*x - 0.20219683
  else
    -- 4000K–25000K
    local t = k
    x = -3.0258469e9/(t^3) + 2.1070379e6/(t^2) + 0.2226347e3/t + 0.240390
    y =  3.0817580*(x^3) - 5.87338670*(x^2) + 3.75112997*x - 0.37001483
  end

  -- xyY -> XYZ (Y=1.0 arbitrary; we’ll normalize later)
  local X = x / y
  local Y = 1.0
  local Z = (1.0 - x - y) / y

  -- XYZ -> linear sRGB/Rec.709 (D65)
  local r =  3.2404542*X + (-1.5371385)*Y + (-0.4985314)*Z
  local g = (-0.9692660)*X +  1.8760108*Y +  0.0415560*Z
  local b =  0.0556434*X + (-0.2040259)*Y +  1.0572252*Z

  -- Clamp negative numerical noise and normalize so max = 1
  if r < 0 then r = 0 end
  if g < 0 then g = 0 end
  if b < 0 then b = 0 end
  local m = math.max(r, g, b)
  if m > 0 then r = r/m; g = g/m; b = b/m end

  return r, g, b
end

-- small UI state per unique id
local _kelvinState = {}
local _presetState = {}
local _filamentState = {}
local _degradationState = {}
local _initFromRGBDone = {}

-- opts:
--   id                unique string id (required)
--   label             default "Color temperature"
--   minK,maxK         default 1000..20000
--   getKelvin()       -> Kelvin value
--   setKelvin(k,isFinal)
--   getRGBA()         -> r,g,b,a
--   setRGBA(r,g,b,a,isFinal)
--   getFilamentId()   -> string, default "blackbody"
--   setFilamentId(id,isFinal)
--   getDegradation()  -> 0..1
--   setDegradation(value,isFinal)

local function draw(opts)
  local id = opts.id or "kelvin"
  local label = opts.label
  local minK = opts.minK or 1000
  local maxK = opts.maxK or 20000

  local filamentTypes = {
    {id = "blackbody",  label = "Blackbody / pure CCT"},
    {id = "tungsten",   label = "Tungsten filament", tint = {1.03, 0.98, 0.84}, degradationTint = {1.10, 0.84, 0.52}},
    {id = "halogen",    label = "Quartz halogen", tint = {1.00, 0.99, 0.94}, degradationTint = {1.05, 0.92, 0.72}},
    {id = "warmLed",    label = "Warm phosphor LED", tint = {0.96, 1.00, 0.90}, degradationTint = {1.04, 0.96, 0.72}},
    {id = "coolLed",    label = "Cool phosphor LED", tint = {0.94, 0.98, 1.06}, degradationTint = {0.82, 0.92, 1.18}},
    {id = "fluorescent", label = "Fluorescent tube", tint = {0.86, 1.00, 0.82}, degradationTint = {0.72, 1.00, 0.62}},
    {id = "sodium",     label = "Sodium vapor", tint = {1.18, 0.76, 0.08}, degradationTint = {1.22, 0.62, 0.04}},
    {id = "mercury",    label = "Mercury vapor", tint = {0.70, 1.00, 0.92}, degradationTint = {0.62, 1.00, 0.78}},
    {id = "metalHalide", label = "Metal halide", tint = {0.88, 1.00, 0.94}, degradationTint = {1.08, 0.82, 1.00}},
    {id = "xenonHid",   label = "Xenon HID", tint = {0.90, 0.96, 1.10}, degradationTint = {0.76, 0.88, 1.24}},
    {id = "phosphorLed", label = "Phosphor LED", tint = {0.96, 1.00, 1.02}, degradationTint = {0.50, 0.34, 1.30}},
  }

  local presets = {
    {k = 1700,  label = "Candle flame", filamentId = "blackbody"},
    {k = 2200,  label = "HPS streetlight", filamentId = "sodium"},
    {k = 2700,  label = "Household incandescent", filamentId = "tungsten"},
    {k = 3000,  label = "Incandescent", filamentId = "tungsten"},
    {k = 3200,  label = "Studio tungsten", filamentId = "tungsten"},
    {k = 4000,  label = "Fluorescent tube", filamentId = "fluorescent"},
    {k = 4300,  label = "Halogen", filamentId = "halogen"},
    {k = 5000,  label = "Neutral LED/Modern Halogen", filamentId = "coolLed"},
    {k = 5000,  label = "Phosphor LED streetlight", filamentId = "phosphorLed"},
    {k = 5000,  label = "Metal halide floodlight", filamentId = "metalHalide"},
    {k = 6000,  label = "Mercury vapor streetlight", filamentId = "mercury"},
    {k = 6500,  label = "Modern LED/Xenon", filamentId = "xenonHid"},
    {k = 8000,  label = "Aftermarket LED/Xenon", filamentId = "xenonHid"},
    {k = 10000, label = "Blue sky", filamentId = "blackbody"},
    {k = 12000, label = "Blue light", filamentId = "blackbody"},
  }

  local kPtr = _kelvinState[id]
  if not kPtr then
    _kelvinState[id] = im.FloatPtr(6500.0)
    kPtr = _kelvinState[id]
  end
  local hasStoredKelvin = false
  if opts.getKelvin then
    local storedKelvin = tonumber(opts.getKelvin())
    if storedKelvin then
      kPtr[0] = clamp(storedKelvin, minK, maxK)
      hasStoredKelvin = true
    end
  end

  local degradationPtr = _degradationState[id]
  if not degradationPtr then
    _degradationState[id] = im.FloatPtr(0.0)
    degradationPtr = _degradationState[id]
  end
  if opts.getDegradation then degradationPtr[0] = clamp(tonumber(opts.getDegradation()) or 0, 0, 1) end

  local function getFilamentIndex(filamentId)
    for i, f in ipairs(filamentTypes) do
      if f.id == filamentId then return i end
    end
    return 1
  end

  local function getFilament(filamentId)
    return filamentTypes[getFilamentIndex(filamentId)]
  end

  local function normalizeFilamentId(filamentId)
    if not filamentId or filamentId == "" then return "blackbody" end
    return filamentTypes[getFilamentIndex(filamentId)].id
  end

  if opts.getFilamentId then
    _filamentState[id] = normalizeFilamentId(opts.getFilamentId())
  elseif not _filamentState[id] then
    _filamentState[id] = "blackbody"
  end

  local function setFilamentId(filamentId, isFinal)
    filamentId = normalizeFilamentId(filamentId)
    _filamentState[id] = filamentId
    if opts.setFilamentId then opts.setFilamentId(filamentId, isFinal == true) end
  end

  local function setDegradation(value, isFinal)
    value = clamp(tonumber(value) or 0, 0, 1)
    degradationPtr[0] = value
    if opts.setDegradation then opts.setDegradation(value, isFinal == true) end
  end

  local function setKelvin(value, isFinal)
    value = clamp(tonumber(value) or 6500, minK, maxK)
    kPtr[0] = value
    if opts.setKelvin then opts.setKelvin(value, isFinal == true) end
  end

  local function applyTint(r, g, b, tint)
    if tint then
      r = r * (tint[1] or 1)
      g = g * (tint[2] or 1)
      b = b * (tint[3] or 1)

      local m = math.max(r, g, b)
      if m > 0 then r = r/m; g = g/m; b = b/m end
    end
    return r, g, b
  end

  local function applyFilamentToRGBLinear(k, filament, degradation)
    local r, g, b = kelvinToRGBLinear(k)
    r, g, b = applyTint(r, g, b, filament and filament.tint)

    local degradationTint = filament and filament.degradationTint
    if degradationTint and degradation and degradation > 0 then
      local tint = {
        1 + ((degradationTint[1] or 1) - 1) * degradation,
        1 + ((degradationTint[2] or 1) - 1) * degradation,
        1 + ((degradationTint[3] or 1) - 1) * degradation,
      }
      r, g, b = applyTint(r, g, b, tint)
    end

    return r, g, b
  end

  local function presetToRGBLinear(p)
    return applyFilamentToRGBLinear(p.k, getFilament(p.filamentId), 0)
  end

  local function _matchPresetFromRGB(r, g, b, list, tol)
    tol = tol or 0.03
    local maxc = math.max(r or 0, g or 0, b or 0)
    if maxc <= 0 then return nil, maxc end
    local rn, gn, bn = r / maxc, g / maxc, b / maxc
    local bestIdx, bestErr = nil, 1e9
    for i, p in ipairs(list) do
      local kr, kg, kb = presetToRGBLinear(p)
      local err = (rn-kr)*(rn-kr) + (gn-kg)*(gn-kg) + (bn-kb)*(bn-kb)
      if err < bestErr then bestErr, bestIdx = err, i end
    end
    if bestIdx and bestErr <= tol*tol*3 then
      return bestIdx, maxc
    end
    return nil, maxc
  end

  if not _initFromRGBDone[id] and not hasStoredKelvin and opts.getRGBA then
    local rr, gg, bb = opts.getRGBA()
    if rr and gg and bb then
      local idx, maxc = _matchPresetFromRGB(rr, gg, bb, presets, 0.03)
      if idx then
        setKelvin(presets[idx].k, false)
        _presetState[id] = idx
        if not opts.getFilamentId then _filamentState[id] = presets[idx].filamentId or "blackbody" end
        setDegradation(0, false)
      end
    end
    _initFromRGBDone[id] = true
  end

  local function apply(isFinal)
    local r, g, b = applyFilamentToRGBLinear(
      kPtr[0],
      getFilament(_filamentState[id] or "blackbody"),
      degradationPtr[0]
    )
    local a = 1
    if opts.setRGBA then opts.setRGBA(r, g, b, a, isFinal == true) end
  end


  local ended = im.BoolPtr(false)
  local function slider(lbl, ptr, a, b, fmt)
    if editor and editor.uiSliderFloat then
      return editor.uiSliderFloat(lbl, ptr, a, b, fmt, nil, ended)
    end
  end

  if label then
    im.TextUnformatted(label)
  end
  if slider("##kelvin_"..id, kPtr, minK, maxK, "%.0f K") then
    _presetState[id] = nil
    setKelvin(kPtr[0], false)
    apply(false)
  end
  if ended[0] then setKelvin(kPtr[0], true); apply(true); ended[0] = false end

  local function findPresetIndex(val, list, eps)
    eps = eps or 0.5 -- tolerance in Kelvin
    local filamentId = _filamentState[id] or "blackbody"
    local selectedIdx = _presetState[id]
    local selectedPreset = selectedIdx and list[selectedIdx]
    if selectedPreset and math.abs(val - selectedPreset.k) <= eps and (selectedPreset.filamentId or "blackbody") == filamentId then return selectedIdx end

    for i, p in ipairs(list) do
      if math.abs(val - p.k) <= eps and (p.filamentId or "blackbody") == filamentId then return i end
    end
    return nil
  end

  local curK = kPtr[0]
  local matchIdx = findPresetIndex(curK, presets)
  local dispLabel
  if matchIdx then
    local p = presets[matchIdx]
    dispLabel = string.format("%dK - %s", p.k, p.label or "")
  else
    dispLabel = string.format("Custom (%.0fK)", curK)
  end
  im.TextUnformatted("Presets")
  if im.BeginCombo("##kelvinPreset_"..id, dispLabel) then
    -- Custom entry (selected if there is no exact match)
    local isCustom = (matchIdx == nil)
    if im.Selectable1(string.format("Custom (%.0fK)", curK), isCustom) then
      -- no-op, user keeps current custom value
    end
    im.Separator()
    -- List all presets
    for i, p in ipairs(presets) do
      local itemLabel = string.format("%dK - %s", p.k, p.label or "")
      local selected = (matchIdx == i)
      if im.Selectable1(itemLabel, selected) then
        setKelvin(p.k, true)
        _presetState[id] = i
        setFilamentId(p.filamentId or "blackbody", true)
        setDegradation(0, true)
        apply(true) -- commit selection
      end
    end
    im.EndCombo()
  end

  local filamentIdx = getFilamentIndex(_filamentState[id] or "blackbody")
  local filamentLabel = filamentTypes[filamentIdx].label
  im.TextUnformatted("Filament type")
  if im.BeginCombo("##filamentType_"..id, filamentLabel) then
    for i, f in ipairs(filamentTypes) do
      local selected = filamentIdx == i
      if im.Selectable1(f.label, selected) then
        setFilamentId(f.id, true)
        _presetState[id] = nil
        if not f.degradationTint then setDegradation(0, true) end
        apply(true)
      end
    end
    im.EndCombo()
  end

  local filament = filamentTypes[filamentIdx]
  if filament.degradationTint then
    im.TextUnformatted("Degradation")
    if slider("##degradation_"..id, degradationPtr, 0, 1, "%.2f") then
      _presetState[id] = nil
      setDegradation(degradationPtr[0], false)
      apply(false)
    end
    if ended[0] then setDegradation(degradationPtr[0], true); apply(true); ended[0] = false end
  end
end

function M.kelvinToRGBLinear(k)
  return kelvinToRGBLinear(k)
end

function M.kelvinToColorStringLinear(k, alpha)
  local r, g, b = kelvinToRGBLinear(k)
  alpha = alpha or 1

  return string.format("%.6f %.6f %.6f %.6f", r, g, b, alpha)
end

M.draw = draw

return M
