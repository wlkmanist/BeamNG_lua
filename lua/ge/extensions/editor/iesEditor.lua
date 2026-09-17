-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local ffi = require("ffi")
local im = ui_imgui
local iesCookie = require("editor/api/iesImporter")

local toolWindowName = "iesEditor"
local toolName = "IES Cookie Importer (WIP)"

local DEFAULT_SETTINGS = {
  resolutionExp = 9, -- 512

  autoAngle = true,
  angle = 35.0,

  projection = 0, -- perspective
  rotate = 0.0,

  autoCenter = false,
  centerTheta = 0.0,
  centerPhi = 0.0,

  edgeFeather = 0.0,

  percentile = 100.0,
  gamma = 1.0,
  scale = 1.0,
  invert = false,
}

-- UI state
local iesPathBuf = im.ArrayChar(1024)
local outputPathBuf = im.ArrayChar(1024)

-- pow2 resolution exponent:
-- 5 = 32, 6 = 64, ..., 12 = 4096
local resolutionExpPtr = im.IntPtr(DEFAULT_SETTINGS.resolutionExp)

local autoAnglePtr = im.BoolPtr(DEFAULT_SETTINGS.autoAngle)
local anglePtr = im.FloatPtr(DEFAULT_SETTINGS.angle)

-- 0 = perspective, 1 = linear
local projectionPtr = im.IntPtr(DEFAULT_SETTINGS.projection)
local projectionCombo = "Perspective\0Linear\0"

local rotatePtr = im.FloatPtr(DEFAULT_SETTINGS.rotate)

local autoCenterPtr = im.BoolPtr(DEFAULT_SETTINGS.autoCenter)
local centerThetaPtr = im.FloatPtr(DEFAULT_SETTINGS.centerTheta)
local centerPhiPtr = im.FloatPtr(DEFAULT_SETTINGS.centerPhi)

local edgeFeatherPtr = im.FloatPtr(DEFAULT_SETTINGS.edgeFeather)

local percentilePtr = im.FloatPtr(DEFAULT_SETTINGS.percentile)
local gammaPtr = im.FloatPtr(DEFAULT_SETTINGS.gamma)
local scalePtr = im.FloatPtr(DEFAULT_SETTINGS.scale)
local invertPtr = im.BoolPtr(DEFAULT_SETTINGS.invert)

local cachedInfo = nil
local lastStatus = nil
local lastStatusError = false
local generateJob = nil
local defaultsInitialized = false


-- Helpers
local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function clamp(v, a, b)
  v = tonumber(v) or a
  if v < a then return a end
  if v > b then return b end
  return v
end

local function pow2(exp)
  return 2 ^ exp
end

local function bufString(buf)
  return trim(ffi.string(buf))
end

local function setBuf(buf, value, maxLen)
  value = tostring(value or "")
  maxLen = maxLen or 1024
  ffi.fill(buf, maxLen)
  ffi.copy(buf, value:sub(1, maxLen - 1))
end

local function applySettingsDefaults()
  resolutionExpPtr[0] = DEFAULT_SETTINGS.resolutionExp

  autoAnglePtr[0] = DEFAULT_SETTINGS.autoAngle
  anglePtr[0] = DEFAULT_SETTINGS.angle

  projectionPtr[0] = DEFAULT_SETTINGS.projection
  rotatePtr[0] = DEFAULT_SETTINGS.rotate

  autoCenterPtr[0] = DEFAULT_SETTINGS.autoCenter
  centerThetaPtr[0] = DEFAULT_SETTINGS.centerTheta
  centerPhiPtr[0] = DEFAULT_SETTINGS.centerPhi

  edgeFeatherPtr[0] = DEFAULT_SETTINGS.edgeFeather

  percentilePtr[0] = DEFAULT_SETTINGS.percentile
  gammaPtr[0] = DEFAULT_SETTINGS.gamma
  scalePtr[0] = DEFAULT_SETTINGS.scale
  invertPtr[0] = DEFAULT_SETTINGS.invert
end

local function setStatus(msg, isError)
  lastStatus = tostring(msg or "")
  lastStatusError = isError and true or false

  if isError then
    log("E", "", lastStatus)
  else
    log("I", "", lastStatus)
  end
end

local function tooltip(text)
  if im.IsItemHovered() then
    im.BeginTooltip()
    im.TextUnformatted(tostring(text or ""))
    im.EndTooltip()
  end
end

local function normalizePath(p)
  p = trim(p):gsub("\\", "/")
  if p == "" then return "" end

  if string.startswith(p, "/") then
    return p
  end

  if FS and FS:fileExists("/" .. p) then
    return "/" .. p
  end

  if FS and FS:directoryExists("/" .. p) then
    return "/" .. p
  end

  return p
end

local function parseNumberFromString(s)
  if not s then return nil end

  local n = tostring(s):match("[-+]?%d+%.?%d*")
  return n and tonumber(n) or nil
end

local function formatValue(v)
  if v == nil or v == "" then return "-" end
  return tostring(v)
end

local function getHeader(meta, keys, fallback)
  if iesCookie.getHeaderValue then
    return iesCookie.getHeaderValue(meta, keys, fallback)
  end

  if not meta or not meta.map then return fallback or "" end

  for _, key in ipairs(keys or {}) do
    local v = meta.map[tostring(key):upper()]
    if v and v ~= "" then return v end
  end

  return fallback or ""
end

local function photometricTypeName(v)
  v = tonumber(v)
  if v == 1 then return "1 - Type C" end
  if v == 2 then return "2 - Type B" end
  if v == 3 then return "3 - Type A" end
  return tostring(v or "-")
end

local function unitsTypeName(v)
  v = tonumber(v)
  if v == 1 then return "1 - Feet" end
  if v == 2 then return "2 - Meters" end
  return tostring(v or "-")
end

local function syncOutputPath()
  local iesPath = normalizePath(bufString(iesPathBuf))
  local out = ""

  if iesCookie.inferCookiePathFromIES then
    out = iesCookie.inferCookiePathFromIES(iesPath)
  else
    out = iesPath:gsub("%.ies$", ""):gsub("%.IES$", "") .. ".color.png"
  end

  setBuf(outputPathBuf, out)
  return out
end

local function initDefaults()
  if defaultsInitialized then return end
  defaultsInitialized = true

  setBuf(iesPathBuf, "/art/special/ies/")
  syncOutputPath()
end

local function ensureOutputDirectory(outputPath)
  if not FS then return true end

  local dir = tostring(outputPath or ""):gsub("\\", "/"):match("^(.*)/[^/]*$")
  if not dir or dir == "" then return true end
  if not string.endswith(dir, "/") then dir = dir .. "/" end

  if FS:directoryExists(dir) then return true end

  local ok = FS:directoryCreate(dir, true)
  return ok or FS:directoryExists(dir)
end

local function buildOptions()
  resolutionExpPtr[0] = math.floor(clamp(resolutionExpPtr[0], 5, 12))

  anglePtr[0] = clamp(anglePtr[0], 0.001, 179.0)
  rotatePtr[0] = clamp(rotatePtr[0], -360.0, 360.0)
  centerThetaPtr[0] = clamp(centerThetaPtr[0], 0.0, 180.0)
  centerPhiPtr[0] = clamp(centerPhiPtr[0], 0.0, 360.0)
  edgeFeatherPtr[0] = clamp(edgeFeatherPtr[0], 0.0, 1.0)

  percentilePtr[0] = clamp(percentilePtr[0], 0.001, 100.0)
  gammaPtr[0] = clamp(gammaPtr[0], 0.1, 4.0)
  scalePtr[0] = clamp(scalePtr[0], 0.0, 4.0)

  return {
    size = pow2(resolutionExpPtr[0]),

    autoAngle = autoAnglePtr[0],
    -- Manual angle is intentionally ignored when autoAngle is true.
    angle = autoAnglePtr[0] and nil or anglePtr[0],

    projection = projectionPtr[0] == 1 and "linear" or "perspective",
    rotate = rotatePtr[0],

    autoCenter = autoCenterPtr[0],
    -- Manual center is intentionally ignored when autoCenter is true.
    centerTheta = autoCenterPtr[0] and nil or centerThetaPtr[0],
    centerPhi = autoCenterPtr[0] and nil or centerPhiPtr[0],

    edgeFeather = edgeFeatherPtr[0],

    percentile = percentilePtr[0],
    gamma = gammaPtr[0],
    scale = scalePtr[0],
    invert = invertPtr[0],

    writeMetadata = true,
    noInfo = true,
  }
end

local function validatePaths(requireOutput)
  local iesPath = normalizePath(bufString(iesPathBuf))
  local outputPath = syncOutputPath()

  if iesPath == "" then
    return nil, nil, "Input IES path is empty."
  end

  if FS and not FS:fileExists(iesPath) then
    return nil, nil, "Input IES file does not exist: " .. tostring(iesPath)
  end

  if requireOutput and outputPath == "" then
    return nil, nil, "Could not infer output path from IES path."
  end

  return iesPath, outputPath, nil
end

local function buildCachedInfo(ies)
  local peakTheta, peakPhi, peak = iesCookie.getPeakDirection(ies)

  cachedInfo = {
    ies = ies,
    meta = ies.metadata or {},
    peakTheta = peakTheta,
    peakPhi = peakPhi,
    peak = peak,
  }

  return cachedInfo
end

-- Actions
local function readIESInfo()
  local iesPath, _, err = validatePaths(false)
  if err then
    cachedInfo = nil
    setStatus(err, true)
    return false
  end

  local ok, res = pcall(function()
    local ies = iesCookie.parseIES(iesPath)
    return buildCachedInfo(ies)
  end)

  if not ok then
    cachedInfo = nil
    setStatus(res, true)
    return false
  end

  setStatus("IES loaded.", false)
  return true
end

local function chooseIESFile()
  if not editor_fileDialog then
    setStatus("File dialog is not available.", true)
    return
  end

  editor_fileDialog.openFile(
    function(data)
      local p = normalizePath(data.filepath or data.path or "")
      setBuf(iesPathBuf, p)
      syncOutputPath()

      cachedInfo = nil
      readIESInfo()
    end,
    {{"IES files", ".ies"}, {"All files", "*"}},
    false,
    "/",
    true
  )
end

local function openOutputInExplorer()
  local outputPath = normalizePath(bufString(outputPathBuf))

  if outputPath == "" then
    setStatus("Output path is empty.", true)
    return
  end

  if FS and not FS:fileExists(outputPath) then
    setStatus("Output image does not exist yet.", true)
    return
  end

  if Engine and Engine.Platform and Engine.Platform.exploreFolder then
    Engine.Platform.exploreFolder(outputPath)
  end
end

local function createJob(fn, data)
  if extensions and extensions.core_jobsystem and extensions.core_jobsystem.create then
    return extensions.core_jobsystem.create(fn, 1, data)
  end
  return nil
end

local function generateCookieJob(job, jobData)
  job.active = true
  job.finished = false
  job.success = false
  job.error = nil
  job.stage = "Starting"

  local function yield()
    if job.yield then job.yield() end
  end

  local ok, err = pcall(function()
    local iesPath = jobData.iesPath
    local outputPath = jobData.outputPath
    local opts = jobData.options or {}

    job.stage = "Parsing IES"
    yield()

    local ies = iesCookie.parseIES(iesPath)
    local peakTheta, peakPhi, peak = iesCookie.getPeakDirection(ies)

    job.info = {
      ies = ies,
      meta = ies.metadata or {},
      peakTheta = peakTheta,
      peakPhi = peakPhi,
      peak = peak,
    }

    local centerTheta = opts.centerTheta or 0
    local centerPhi = opts.centerPhi or 0

    if opts.autoCenter then
      centerTheta = peakTheta or 0
      centerPhi = peakPhi or 0
    end

    local angle = opts.autoAngle and nil or opts.angle

    job.stage = "Generating " .. tostring(opts.size or "") .. "x" .. tostring(opts.size or "")
    yield()

    local img = iesCookie.generateCookie(ies, {
      size = opts.size or 512,
      angle = angle,
      projection = opts.projection or "perspective",
      rotate = opts.rotate or 0,
      centerTheta = centerTheta,
      centerPhi = centerPhi,
      edgeFeather = opts.edgeFeather or 0,
    })

    job.stage = "Saving PNG and metadata"
    yield()

    if not ensureOutputDirectory(outputPath) then
      error("Could not create output directory for: " .. tostring(outputPath))
    end

    local saved, saveInfo = iesCookie.saveImage(img, outputPath, {
      percentile = opts.percentile or 100,
      gamma = opts.gamma or 1,
      scale = opts.scale or 1,
      invert = opts.invert or false,
      writeMetadata = true,
    })

    if not saved then
      error("Failed to save output image: " .. tostring(outputPath))
    end

    job.outputPath = outputPath
    job.saveInfo = saveInfo
    job.stage = "Done"
    job.success = true
  end)

  if not ok then
    job.error = tostring(err)
    job.stage = "Error"
  end

  job.active = false
  job.finished = true
end

local function generateCookieSync(iesPath, outputPath, opts)
  local ies = iesCookie.parseIES(iesPath)
  buildCachedInfo(ies)

  local centerTheta = opts.centerTheta
  local centerPhi = opts.centerPhi

  if opts.autoCenter then
    centerTheta = cachedInfo.peakTheta or 0
    centerPhi = cachedInfo.peakPhi or 0
  end

  local angle = opts.autoAngle and nil or opts.angle

  local img = iesCookie.generateCookie(ies, {
    size = opts.size,
    angle = angle,
    projection = opts.projection,
    rotate = opts.rotate,
    centerTheta = centerTheta,
    centerPhi = centerPhi,
    edgeFeather = opts.edgeFeather,
  })

  if not ensureOutputDirectory(outputPath) then
    error("Could not create output directory for: " .. tostring(outputPath))
  end

  return iesCookie.saveImage(img, outputPath, {
    percentile = opts.percentile,
    gamma = opts.gamma,
    scale = opts.scale,
    invert = opts.invert,
    writeMetadata = true,
  })
end

local function generateCookie()
  if generateJob and generateJob.active then
    setStatus("Generation is already running.", true)
    return
  end

  local iesPath, outputPath, err = validatePaths(true)
  if err then
    setStatus(err, true)
    return
  end

  local opts = buildOptions()

  log("I", "", "Generating cookie for: " .. tostring(iesPath))
  log("I", "", "Output path: " .. tostring(outputPath))

  generateJob = createJob(generateCookieJob, {
    iesPath = iesPath,
    outputPath = outputPath,
    options = opts,
  })

  if generateJob then
    setStatus("Generating cookie...", false)
    return
  end

  -- Synchronous fallback if jobsystem is unavailable.
  local ok, saved, saveInfo = pcall(function()
    return generateCookieSync(iesPath, outputPath, opts)
  end)

  if not ok then
    setStatus(saved, true)
  elseif saved then
    local suffix = ""
    if saveInfo and saveInfo.metadataWritten and saveInfo.metadataPath then
      suffix = "  Metadata: " .. tostring(saveInfo.metadataPath)
    end
    setStatus("Saved cookie: " .. tostring(outputPath) .. suffix, false)
  else
    setStatus("Failed to save output image.", true)
  end
end

local function handleFinishedJob()
  if not generateJob then return end
  if not generateJob.finished then return end
  if generateJob._iesEditorHandled then return end

  generateJob._iesEditorHandled = true

  if generateJob.info then
    cachedInfo = generateJob.info
  end

  if generateJob.success then
    local suffix = ""
    if generateJob.saveInfo and generateJob.saveInfo.metadataWritten and generateJob.saveInfo.metadataPath then
      suffix = "  Metadata: " .. tostring(generateJob.saveInfo.metadataPath)
    end
    setStatus("Saved cookie: " .. tostring(generateJob.outputPath) .. suffix, false)
  else
    setStatus(generateJob.error or "Generation failed.", true)
  end
end


-- UI helpers
local function drawStatus()
  if generateJob and generateJob.active then
    im.TextColored(im.ImVec4(0.7, 0.9, 1, 1), "Working: " .. tostring(generateJob.stage or ""))
  end

  if not lastStatus then return end

  if lastStatusError then
    im.TextColored(im.ImVec4(1, 0.25, 0.2, 1), lastStatus)
  else
    im.TextColored(im.ImVec4(0.35, 1, 0.35, 1), lastStatus)
  end
end

local function infoRow(label, value)
  im.TextUnformatted(tostring(label or ""))
  im.NextColumn()
  im.TextWrapped(formatValue(value))
  im.NextColumn()
end

local function drawHeaderSummary(meta)
  im.TextUnformatted("Header")
  im.Separator()

  if not meta or not meta.entries or #meta.entries == 0 then
    im.TextColored(im.ImVec4(0.75, 0.75, 0.75, 1), "No header metadata loaded.")
    return
  end

  im.Columns(2, "iesHeaderColumns", false)

  infoRow("IES version", meta.version)
  infoRow("Manufacturer", getHeader(meta, {"MANUFAC"}))
  infoRow("Catalog", getHeader(meta, {"LUMCAT"}))
  infoRow("Luminaire", getHeader(meta, {"LUMINAIRE"}))
  infoRow("Distribution", getHeader(meta, {"DISTRIBUTION"}))
  infoRow("Lamp", getHeader(meta, {"LAMP"}))
  infoRow("Lamp catalog", getHeader(meta, {"LAMPCAT"}))
  infoRow("Test", getHeader(meta, {"TEST"}))
  infoRow("Test lab", getHeader(meta, {"TESTLAB"}))
  infoRow("Issue date", getHeader(meta, {"ISSUEDATE"}))

  local fileType = getHeader(meta, {"_FILETYPE"})
  local sourceType = getHeader(meta, {"_SEARCH_SOURCETYPE", "SEARCH"})
  local cct = getHeader(meta, {"_CCT", "_SEARCH_COLORTEMP"})
  local cri = getHeader(meta, {"_CRI", "_SEARCH_CRI"})
  local driveCurrent = getHeader(meta, {"_DRIVE_CURRENT"})
  local mounting = getHeader(meta, {"_SEARCH_MOUNTING"})
  local certification = getHeader(meta, {"_SEARCH_CERTIFICATION"})
  local classification = getHeader(meta, {"_SEARCH_CLASSIFICATION"})
  local application = getHeader(meta, {"_SEARCH_APPLICATION"})

  if fileType ~= "" then infoRow("File type", fileType) end
  if sourceType ~= "" then infoRow("Source", sourceType) end
  if cct ~= "" then infoRow("CCT", cct) end
  if cri ~= "" then infoRow("CRI", cri) end
  if driveCurrent ~= "" then infoRow("Drive current", driveCurrent) end
  if mounting ~= "" then infoRow("Mounting", mounting) end
  if certification ~= "" then infoRow("Certification", certification) end
  if classification ~= "" then infoRow("Classification", classification) end
  if application ~= "" then infoRow("Application", application) end

  im.Columns(1)
end

local function drawPhotometryInfo()
  im.TextUnformatted("Photometry")
  im.Separator()

  if not cachedInfo or not cachedInfo.ies then
    im.TextColored(im.ImVec4(0.75, 0.75, 0.75, 1), "No IES loaded.")

    if im.Button("Read IES Info##info") then
      readIESInfo()
    end

    return
  end

  local ies = cachedInfo.ies
  local meta = cachedInfo.meta or {}
  local v = ies.verticalAngles or {}
  local h = ies.horizontalAngles or {}

  local absLumensStr = getHeader(meta, {"_ABSOLUTELUMENS", "_ABSLUMENS"})
  local systemWattsStr = getHeader(meta, {"_SYSTEMWATTS"})
  local cct = getHeader(meta, {"_CCT", "_SEARCH_COLORTEMP"})
  local cri = getHeader(meta, {"_CRI", "_SEARCH_CRI"})

  local absoluteLumens = parseNumberFromString(absLumensStr)
  local systemWatts = parseNumberFromString(systemWattsStr) or tonumber(ies.inputWatts)

  local calculatedLumens = nil
  if tonumber(ies.numLamps) and tonumber(ies.lumensPerLamp) then
    calculatedLumens = tonumber(ies.numLamps) * tonumber(ies.lumensPerLamp)
  end

  local lumensForEfficacy = absoluteLumens or calculatedLumens
  local efficacy = nil

  if lumensForEfficacy and systemWatts and systemWatts > 0 then
    efficacy = lumensForEfficacy / systemWatts
  end

  im.Columns(2, "iesPhotometryColumns", false)

  infoRow("Vertical angles", string.format("%d  [%s..%s deg]", #v, tostring(v[1]), tostring(v[#v])))
  infoRow("Horizontal angles", string.format("%d  [%s..%s deg]", #h, tostring(h[1]), tostring(h[#h])))
  infoRow("Photometric type", photometricTypeName(ies.photometricType))
  infoRow("Units", unitsTypeName(ies.unitsType))

  infoRow("Lamps", ies.numLamps)
  infoRow("Lumens/lamp", ies.lumensPerLamp)

  if absLumensStr ~= "" then
    infoRow("Absolute lumens", absLumensStr)
  elseif calculatedLumens then
    infoRow("Calculated lumens", string.format("%.0f", calculatedLumens))
  end

  infoRow("Input watts", ies.inputWatts)

  if systemWattsStr ~= "" then
    infoRow("System watts", systemWattsStr)
  end

  if efficacy then
    infoRow("Efficacy", string.format("%.1f lm/W", efficacy))
  end

  if cct ~= "" then infoRow("CCT", cct) end
  if cri ~= "" then infoRow("CRI", cri) end

  infoRow("Width", ies.width)
  infoRow("Length", ies.length)
  infoRow("Height", ies.height)
  infoRow("Ballast factor", ies.ballastFactor)
  infoRow("Tilt", ies.tilt and ies.tilt.mode or "-")

  infoRow("Peak candela", cachedInfo.peak)
  infoRow("Peak theta", tostring(cachedInfo.peakTheta) .. " deg")
  infoRow("Peak phi", tostring(cachedInfo.peakPhi) .. " deg")

  im.Columns(1)

  if im.Button("Use Peak As Center") then
    centerThetaPtr[0] = cachedInfo.peakTheta or 0
    centerPhiPtr[0] = cachedInfo.peakPhi or 0
    autoCenterPtr[0] = false
  end

  im.SameLine()

  if im.Button("Auto-Center") then
    autoCenterPtr[0] = true
  end
end

local function drawRawHeaderFields()
  if not cachedInfo or not cachedInfo.meta then return end

  local meta = cachedInfo.meta
  if not meta.entries or #meta.entries == 0 then return end

  im.Spacing()

  if im.TreeNode1("Raw header fields") then
    im.Columns(2, "iesRawHeaderColumns", false)

    for _, entry in ipairs(meta.entries) do
      if entry.key ~= "MORE" or entry.value ~= "" then
        infoRow("[" .. tostring(entry.key) .. "]", entry.value)
      end
    end

    im.Columns(1)
    im.TreePop()
  end
end

local function drawInfoPanel()
  drawHeaderSummary(cachedInfo and cachedInfo.meta or nil)

  im.Spacing()
  drawPhotometryInfo()

  drawRawHeaderFields()
end

local function drawFilesAndInfo()
  im.TextUnformatted("Files")
  im.Separator()

  local btnW = 88 * im.uiscale[0]
  local spacing = im.GetStyle().ItemSpacing.x
  local availW = im.GetContentRegionAvailWidth()
  local pathW = math.min(360 * im.uiscale[0], math.max(220 * im.uiscale[0], availW - btnW - spacing))

  im.PushItemWidth(pathW)
  if im.InputText("Input .ies##iesPath", iesPathBuf, 1024) then
    cachedInfo = nil
    syncOutputPath()
  end
  im.PopItemWidth()

  im.SameLine()

  if im.Button("Browse##ies", im.ImVec2(btnW, 0)) then
    chooseIESFile()
  end

  syncOutputPath()

  im.TextUnformatted("Output")
  im.PushTextWrapPos()
  im.TextWrapped(bufString(outputPathBuf) ~= "" and bufString(outputPathBuf) or "-")
  im.PopTextWrapPos()

  if im.Button("Open Output Location##output") then
    openOutputInExplorer()
  end

  im.Spacing()

  if im.Button("Read IES Info", im.ImVec2(130 * im.uiscale[0], 0)) then
    readIESInfo()
  end

  im.SameLine()

  local generateActive = generateJob and generateJob.active
  if generateActive and im.BeginDisabled then im.BeginDisabled() end

  if im.Button("Generate Cookie", im.ImVec2(150 * im.uiscale[0], 0)) then
    generateCookie()
  end

  if generateActive and im.EndDisabled then im.EndDisabled() end

  drawStatus()

  im.Spacing()
  drawInfoPanel()
end

local function drawPreview()
  im.TextUnformatted("Preview")
  im.Separator()

  local outputPath = normalizePath(bufString(outputPathBuf))

  if outputPath == "" then
    im.TextUnformatted("No output image selected.")
    return
  end

  if FS and not FS:fileExists(outputPath) then
    im.TextColored(im.ImVec4(0.75, 0.75, 0.75, 1), "Output image does not exist yet.")
    im.TextWrapped(outputPath)
    return
  end

  local tex = editor.getTempTextureObj(outputPath)

  if not tex or not tex.size or tex.size.x <= 0 or tex.size.y <= 0 then
    im.TextColored(im.ImVec4(1, 0.4, 0.3, 1), "Failed to load preview texture.")
    im.TextWrapped(outputPath)
    return
  end

  local avail = im.GetContentRegionAvail()
  local maxW = math.max(64, avail.x)
  local maxH = math.max(64, avail.y - 30 * im.uiscale[0])

  local ratio = tex.size.y / tex.size.x
  local drawW = maxW
  local drawH = drawW * ratio

  if drawH > maxH then
    drawH = maxH
    drawW = drawH / ratio
  end

  im.Image(
    tex.tex:getID(),
    im.ImVec2(drawW, drawH),
    nil,
    nil,
    nil,
    editor.color.white.Value
  )

  im.TextWrapped(outputPath)

  local metaPath = iesCookie.getCookieMetadataPath and iesCookie.getCookieMetadataPath(outputPath) or nil
  if metaPath and FS and FS:fileExists(metaPath) then
    im.TextWrapped(metaPath)
  end
end

local function drawCookieSettings()
  im.TextUnformatted("Cookie")
  im.Separator()

  resolutionExpPtr[0] = math.floor(clamp(resolutionExpPtr[0], 5, 12))
  local size = pow2(resolutionExpPtr[0])

  im.PushItemWidth(220 * im.uiscale[0])
  im.SliderInt("Texture size", resolutionExpPtr, 5, 12, tostring(size) .. " x " .. tostring(size))
  im.PopItemWidth()
  tooltip("Power-of-two resolution only.")

  im.PushItemWidth(220 * im.uiscale[0])
  im.Combo2("Projection", projectionPtr, projectionCombo)
  im.PopItemWidth()
  tooltip("Perspective usually matches projected spotlight cookies. Linear maps texture radius directly to angle.")

  im.Checkbox("Auto angle from IES", autoAnglePtr)
  tooltip("Uses min(max IES vertical angle, 90). Manual half-angle is ignored while enabled.")

  if autoAnglePtr[0] then
    im.TextColored(im.ImVec4(0.75, 0.75, 0.75, 1), "Manual half-angle ignored while auto angle is enabled.")
  else
    im.PushItemWidth(220 * im.uiscale[0])
    im.SliderFloat("Half-angle", anglePtr, 1.0, 120.0, "%.1f deg")
    im.PopItemWidth()
  end

  im.PushItemWidth(220 * im.uiscale[0])
  im.SliderFloat("Cookie rotation", rotatePtr, -180.0, 180.0, "%.1f deg")
  im.SliderFloat("Edge feather", edgeFeatherPtr, 0.0, 1.0, "%.3f")
  im.PopItemWidth()
end

local function drawCenterSettings()
  im.TextUnformatted("Center")
  im.Separator()

  im.Checkbox("Auto-center on brightest direction", autoCenterPtr)

  if autoCenterPtr[0] then
    im.TextColored(im.ImVec4(0.75, 0.75, 0.75, 1), "Manual center theta/phi ignored while auto-center is enabled.")
  else
    im.PushItemWidth(220 * im.uiscale[0])
    im.SliderFloat("Center theta", centerThetaPtr, 0.0, 180.0, "%.1f deg")
    im.SliderFloat("Center phi", centerPhiPtr, 0.0, 360.0, "%.1f deg")
    im.PopItemWidth()
  end

  if cachedInfo then
    if im.Button("Use Peak Direction") then
      centerThetaPtr[0] = cachedInfo.peakTheta or 0
      centerPhiPtr[0] = cachedInfo.peakPhi or 0
      autoCenterPtr[0] = false
    end

    im.SameLine()

    im.TextUnformatted(
      string.format(
        "Peak: theta %.2f, phi %.2f",
        tonumber(cachedInfo.peakTheta) or 0,
        tonumber(cachedInfo.peakPhi) or 0
      )
    )
  end
end

local function drawOutputSettings()
  im.TextUnformatted("Output")
  im.Separator()

  im.PushItemWidth(220 * im.uiscale[0])
  im.SliderFloat("Percentile", percentilePtr, 50.0, 100.0, "%.2f")
  im.SliderFloat("Gamma", gammaPtr, 0.1, 4.0, "%.2f")
  im.SliderFloat("Scale", scalePtr, 0.0, 4.0, "%.2f")
  im.PopItemWidth()

  tooltip("Gamma 1.0 is linear. Gamma 2.2 is useful for previews.")

  im.Checkbox("Invert", invertPtr)
end

local function drawSettings()
  im.Separator()
  im.TextUnformatted("Settings")
  im.SameLine()

  if im.Button("Reset Settings To Defaults") then
    applySettingsDefaults()
    setStatus("Settings reset to import defaults.", false)
  end

  im.Spacing()

  if im.BeginTable("iesSettingsTable", 3, im.TableFlags_SizingStretchProp) then
    im.TableNextColumn()
    drawCookieSettings()

    im.TableNextColumn()
    drawCenterSettings()

    im.TableNextColumn()
    drawOutputSettings()

    im.EndTable()
  end
end


-- Editor hooks
local function onEditorGui()
  initDefaults()
  handleFinishedJob()

  if editor.beginWindow(toolWindowName, toolName, im.WindowFlags_NoDocking) then
    local avail = im.GetContentRegionAvail()
    local topH = math.max(330 * im.uiscale[0], avail.y * 0.62)

    if im.BeginTable("iesTopTable", 2, im.TableFlags_SizingStretchProp + im.TableFlags_Resizable, im.ImVec2(0, topH)) then
      im.TableSetupColumn("Files", im.TableColumnFlags_WidthStretch, 0.58)
      im.TableSetupColumn("Preview", im.TableColumnFlags_WidthStretch, 0.42)

      im.TableNextRow()

      im.TableSetColumnIndex(0)
      if im.BeginChild1("iesFilesInfoChild", im.ImVec2(0, topH), true) then
        drawFilesAndInfo()
      end
      im.EndChild()

      im.TableSetColumnIndex(1)
      if im.BeginChild1("iesPreviewChild", im.ImVec2(0, topH), true) then
        drawPreview()
      end
      im.EndChild()

      im.EndTable()
    end

    drawSettings()
  end

  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.addWindowMenuItem(toolName, onWindowMenuItem, {groupMenuName = 'Experimental'})
  editor.registerWindow(toolWindowName, im.ImVec2(980, 700))
  initDefaults()
  log("I", "", "Initialized")
end

M.onEditorGui = onEditorGui
M.onWindowMenuItem = onWindowMenuItem
M.onEditorInitialized = onEditorInitialized

return M