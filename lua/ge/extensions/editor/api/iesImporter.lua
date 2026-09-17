-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}


-- Math aliases
local sqrt  = math.sqrt
local sin   = math.sin
local cos   = math.cos
local tan   = math.tan
local acos  = math.acos
local floor = math.floor
local ceil  = math.ceil
local abs   = math.abs
local min   = math.min
local max   = math.max
local rad   = math.rad
local deg   = math.deg
local atan2 = math.atan2


-- General helpers
local function mod360(v)
  v = v % 360
  if v < 0 then v = v + 360 end
  return v
end

local function toInt(v)
  if v >= 0 then return floor(v) end
  return ceil(v)
end

local function normalizePath(path)
  path = trim(tostring(path or "")):gsub("\\", "/")
  if path == "" then return "" end

  if string.startswith(path, "/") then
    return path
  end

  if FS and FS:fileExists("/" .. path) then
    return "/" .. path
  end

  if FS and FS:directoryExists("/" .. path) then
    return "/" .. path
  end

  return path
end

local function dirname(path)
  path = tostring(path or ""):gsub("\\", "/")
  local d = path:match("^(.*)/[^/]*$")

  if not d or d == "" then
    return ""
  end

  if string.endswith(d, "/") then
    return d
  end

  return d .. "/"
end

local function basename(path)
  path = tostring(path or ""):gsub("\\", "/")
  return path:match("([^/]+)$") or path
end

local function basenameNoExt(path)
  local b = basename(path)
  return b:gsub("%.[^%.]+$", "")
end

local function readAll(path)
  path = normalizePath(path)

  if readFile then
    local ok, txt = pcall(readFile, path)
    if ok and txt then
      return txt
    end
  end

  local f = io.open(path, "rb")
  if not f then
    error("Could not read file: " .. tostring(path))
  end

  local txt = f:read("*a")
  f:close()

  return txt
end

local function splitLines(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")

  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  return lines
end

local function numericTokens(lines)
  local tokens = {}

  for _, line in ipairs(lines or {}) do
    for tok in line:gmatch("[+-]?[%d%.]+[eE]?[+-]?%d*") do
      local n = tonumber(tok)
      if n then
        tokens[#tokens + 1] = n
      end
    end
  end

  return tokens
end

local function upperBound(arr, value)
  local lo = 1
  local hi = #arr + 1

  while lo < hi do
    local mid = floor((lo + hi) * 0.5)

    if arr[mid] <= value then
      lo = mid + 1
    else
      hi = mid
    end
  end

  return lo
end

local function normalize3(x, y, z)
  local len = sqrt(x * x + y * y + z * z)
  if len < 1e-30 then
    return 0, 0, 0
  end

  return x / len, y / len, z / len
end

local function cross(ax, ay, az, bx, by, bz)
  return
    ay * bz - az * by,
    az * bx - ax * bz,
    ax * by - ay * bx
end

local function interp1(x, xs, ys, defaultValue)
  local n = #xs

  if n == 0 then return defaultValue or 1 end
  if n == 1 then return ys[1] or defaultValue or 1 end

  if x <= xs[1] then return ys[1] end
  if x >= xs[n] then return ys[n] end

  local i0 = upperBound(xs, x) - 1
  i0 = clamp(i0, 1, n - 1)

  local i1 = i0 + 1
  local denom = xs[i1] - xs[i0]

  if denom == 0 then
    return ys[i0]
  end

  local t = (x - xs[i0]) / denom
  return lerp(ys[i0] or 1, ys[i1] or 1, t)
end

local function getMetaValue(meta, keys, fallback)
  if not meta or not meta.map then return fallback or "" end

  for _, key in ipairs(keys or {}) do
    local v = meta.map[tostring(key):upper()]
    if v and v ~= "" then
      return v
    end
  end

  return fallback or ""
end

local function parseNumberFromString(s)
  if not s then return nil end

  local n = tostring(s):match("[-+]?%d+%.?%d*")
  return n and tonumber(n) or nil
end


-- Header metadata
local function cleanMetaValue(v)
  v = tostring(v or "")
  v = v:gsub("%s+", " ")
  return trim(v)
end

function M.parseHeaderMetadata(path)
  local text = readAll(path)
  local lines = splitLines(text)

  local meta = {
    version = "",
    entries = {},
    map = {},
    more = {},
  }

  local lastKey = nil

  for _, line in ipairs(lines) do
    local stripped = trim(line)
    local upper = stripped:upper()

    if upper:sub(1, 5) == "TILT=" then
      break
    end

    if stripped ~= "" then
      local key, value = stripped:match("^%[([^%]]+)%]%s*(.-)%s*$")

      if key then
        key = trim(key):upper()
        value = cleanMetaValue(value)

        meta.entries[#meta.entries + 1] = {
          key = key,
          value = value,
        }

        if key == "MORE" then
          if value ~= "" then
            meta.more[#meta.more + 1] = value

            -- Common IES convention: [MORE] continues previous field.
            if lastKey and meta.map[lastKey] and meta.map[lastKey] ~= "" then
              meta.map[lastKey] = cleanMetaValue(meta.map[lastKey] .. " " .. value)
            end
          end
        else
          if meta.map[key] and meta.map[key] ~= "" and value ~= "" then
            meta.map[key] = meta.map[key] .. "\n" .. value
          else
            meta.map[key] = value
          end

          lastKey = key
        end
      elseif meta.version == "" then
        meta.version = stripped
      end
    end
  end

  return meta
end

function M.getHeaderValue(meta, keys, fallback)
  return getMetaValue(meta, keys, fallback)
end


-- IES parsing
local function parseTiltSection(tokens, idx, tiltMode)
  local tilt = {
    mode = tiltMode,
    lampToLuminaireGeometry = nil,
    angles = nil,
    multipliers = nil,
  }

  if tiltMode == "NONE" then
    return idx, tilt
  end

  if tiltMode == "INCLUDE" then
    if #tokens < idx + 1 then
      error("Invalid TILT=INCLUDE section.")
    end

    tilt.lampToLuminaireGeometry = toInt(tokens[idx])
    idx = idx + 1

    local numTiltAngles = toInt(tokens[idx])
    idx = idx + 1

    tilt.angles = {}
    for i = 1, numTiltAngles do
      tilt.angles[i] = tokens[idx]
      idx = idx + 1
    end

    tilt.multipliers = {}
    for i = 1, numTiltAngles do
      tilt.multipliers[i] = tokens[idx]
      idx = idx + 1
    end

    return idx, tilt
  end

  error("External tilt files are not supported: TILT=" .. tostring(tiltMode))
end

local function applyTiltMultipliers(ies)
  local tilt = ies.tilt
  if not tilt or not tilt.angles or not tilt.multipliers then return end

  local v = ies.verticalAngles
  local c = ies.candela

  for iv = 1, #v do
    local mult = interp1(v[iv], tilt.angles, tilt.multipliers, 1)

    for ih = 1, #c do
      c[ih][iv] = c[ih][iv] * mult
    end
  end
end

function M.parseIES(path)
  path = normalizePath(path)

  log("I", "", "Parsing IES: " .. tostring(path))

  local text = readAll(path)
  local lines = splitLines(text)
  local metadata = M.parseHeaderMetadata(path)

  local tiltIndex = nil
  local tiltMode = nil

  for i, line in ipairs(lines) do
    local stripped = trim(line)
    local upper = stripped:upper()

    if upper:sub(1, 5) == "TILT=" then
      tiltIndex = i
      tiltMode = trim(stripped:sub(6)):upper()
      break
    end
  end

  if not tiltIndex then
    error("Could not find TILT= line. This does not look like an IES file.")
  end

  local dataLines = {}
  for i = tiltIndex + 1, #lines do
    dataLines[#dataLines + 1] = lines[i]
  end

  local tokens = numericTokens(dataLines)
  local idx = 1
  local tilt

  idx, tilt = parseTiltSection(tokens, idx, tiltMode)

  local function takeFloat()
    if idx > #tokens then
      error("Unexpected end of IES numeric data.")
    end

    local v = tokens[idx]
    idx = idx + 1
    return v
  end

  local numLamps = toInt(takeFloat())
  local lumensPerLamp = takeFloat()
  local candelaMultiplier = takeFloat()

  local numVerticalAngles = toInt(takeFloat())
  local numHorizontalAngles = toInt(takeFloat())

  local photometricType = toInt(takeFloat())
  local unitsType = toInt(takeFloat())

  local width = takeFloat()
  local length = takeFloat()
  local height = takeFloat()

  local ballastFactor = takeFloat()
  local futureUse = takeFloat()
  local inputWatts = takeFloat()

  local verticalAngles = {}
  for i = 1, numVerticalAngles do
    verticalAngles[i] = takeFloat()
  end

  local horizontalAngles = {}
  for i = 1, numHorizontalAngles do
    horizontalAngles[i] = takeFloat()
  end

  -- IES order:
  -- for each horizontal angle, all vertical candela values.
  local candela = {}
  for ih = 1, numHorizontalAngles do
    candela[ih] = {}

    for iv = 1, numVerticalAngles do
      candela[ih][iv] = takeFloat() * candelaMultiplier
    end
  end

  local ies = {
    path = path,
    metadata = metadata,
    tilt = tilt,

    verticalAngles = verticalAngles,
    horizontalAngles = horizontalAngles,
    candela = candela,

    numLamps = numLamps,
    lumensPerLamp = lumensPerLamp,
    candelaMultiplier = candelaMultiplier,

    photometricType = photometricType,
    unitsType = unitsType,

    width = width,
    length = length,
    height = height,

    ballastFactor = ballastFactor,
    futureUse = futureUse,
    inputWatts = inputWatts,
  }

  applyTiltMultipliers(ies)

  log("I", "",
    string.format(
      "Parsed IES: %d vertical angles, %d horizontal angles, tilt=%s",
      #verticalAngles,
      #horizontalAngles,
      tostring(tiltMode)
    )
  )

  return ies
end

function M.getPeakDirection(ies)
  local v = ies.verticalAngles
  local h = ies.horizontalAngles
  local c = ies.candela

  local peak = -math.huge
  local peakTheta = 0
  local peakPhi = 0
  local peakHIndex = 1
  local peakVIndex = 1

  for ih = 1, #h do
    for iv = 1, #v do
      if c[ih][iv] > peak then
        peak = c[ih][iv]
        peakTheta = v[iv]
        peakPhi = h[ih]
        peakHIndex = ih
        peakVIndex = iv
      end
    end
  end

  return peakTheta, peakPhi, peak, peakHIndex, peakVIndex
end

function M.printIESInfo(ies)
  local peakTheta, peakPhi, peak = M.getPeakDirection(ies)
  local v = ies.verticalAngles
  local h = ies.horizontalAngles

  log("I", "", "IES info")
  log("I", "", string.format("Vertical angles:   %d   range %s to %s degrees", #v, tostring(v[1]), tostring(v[#v])))
  log("I", "", string.format("Horizontal angles: %d   range %s to %s degrees", #h, tostring(h[1]), tostring(h[#h])))
  log("I", "", string.format("Photometric type:  %s", tostring(ies.photometricType)))
  log("I", "", string.format("Input watts:       %s", tostring(ies.inputWatts)))
  log("I", "", string.format("Peak candela:      %s", tostring(peak)))
  log("I", "", string.format("Peak theta:        %s degrees", tostring(peakTheta)))
  log("I", "", string.format("Peak phi:          %s degrees", tostring(peakPhi)))
end


-- Sampling
function M.prepareHorizontalData(horizontalAngles, candela)
  local pairs = {}

  for i = 1, #horizontalAngles do
    pairs[i] = {
      h = horizontalAngles[i],
      c = candela[i],
    }
  end

  table.sort(pairs, function(a, b) return a.h < b.h end)

  local h = {}
  local c = {}

  for i = 1, #pairs do
    h[i] = pairs[i].h
    c[i] = shallowcopy(pairs[i].c)
  end

  -- If full horizontal data is given and does not include 360,
  -- append first row at 360 for wrapping.
  if #h > 1 and h[#h] > 180 and h[#h] < 359.999 then
    h[#h + 1] = 360
    c[#c + 1] = shallowcopy(c[1])
  end

  return {
    h = h,
    c = c,
  }
end

local function remapPhiForSymmetry(phi, h)
  phi = mod360(phi)

  if #h <= 1 then
    return 0
  end

  local maxH = h[#h]

  if maxH <= 90 + 1e-4 then
    -- 0..90 mirrored into each quadrant.
    local p = phi % 180
    if p > 90 then p = 180 - p end
    return p
  end

  if maxH <= 180 + 1e-4 then
    -- 0..180 mirrored front/back.
    if phi > 180 then
      return 360 - phi
    end

    return phi
  end

  -- Full 0..360 data.
  return phi
end

function M.sampleIES(theta, phi, ies, prepared)
  local v = ies.verticalAngles
  prepared = prepared or M.prepareHorizontalData(ies.horizontalAngles, ies.candela)

  local h = prepared.h
  local c = prepared.c

  local numV = #v
  local numH = #h

  if numV == 0 or numH == 0 then
    return 0
  end

  if theta < v[1] or theta > v[#v] then
    return 0
  end

  local iv0, iv1, tv

  if numV == 1 then
    iv0 = 1
    iv1 = 1
    tv = 0
  else
    local thetaClamped = clamp(theta, v[1], v[#v])

    iv0 = upperBound(v, thetaClamped) - 1
    iv0 = clamp(iv0, 1, numV - 1)
    iv1 = iv0 + 1

    local denomV = v[iv1] - v[iv0]
    if denomV == 0 then denomV = 1 end

    tv = (thetaClamped - v[iv0]) / denomV
  end

  local ih0, ih1, th

  if numH == 1 then
    ih0 = 1
    ih1 = 1
    th = 0
  else
    local phiMapped = remapPhiForSymmetry(phi, h)
    local phiClamped = clamp(phiMapped, h[1], h[#h])

    ih0 = upperBound(h, phiClamped) - 1
    ih0 = clamp(ih0, 1, numH - 1)
    ih1 = ih0 + 1

    local denomH = h[ih1] - h[ih0]
    if denomH == 0 then denomH = 1 end

    th = (phiClamped - h[ih0]) / denomH
  end

  local c00 = c[ih0][iv0]
  local c01 = c[ih0][iv1]
  local c10 = c[ih1][iv0]
  local c11 = c[ih1][iv1]

  local a = c00 * (1 - tv) + c01 * tv
  local b = c10 * (1 - tv) + c11 * tv

  return a * (1 - th) + b * th
end


-- Cookie generation
local function makeBasisFromCenter(centerThetaDeg, centerPhiDeg)
  local theta = rad(centerThetaDeg)
  local phi = rad(centerPhiDeg)

  local wx = sin(theta) * cos(phi)
  local wy = sin(theta) * sin(phi)
  local wz = cos(theta)

  wx, wy, wz = normalize3(wx, wy, wz)

  local rx, ry, rz = 0, 0, 1
  local dot = rx * wx + ry * wy + rz * wz

  if abs(dot) > 0.99 then
    rx, ry, rz = 0, 1, 0
  end

  local ux, uy, uz = cross(rx, ry, rz, wx, wy, wz)
  ux, uy, uz = normalize3(ux, uy, uz)

  local vx, vy, vz = cross(wx, wy, wz, ux, uy, uz)
  vx, vy, vz = normalize3(vx, vy, vz)

  return {
    ux = ux, uy = uy, uz = uz,
    vx = vx, vy = vy, vz = vz,
    wx = wx, wy = wy, wz = wz,
  }
end

function M.generateCookie(ies, opts)
  opts = opts or {}

  local size = tonumber(opts.size) or 1024
  local projection = opts.projection or "perspective"
  local rotate = tonumber(opts.rotate) or 0
  local centerTheta = tonumber(opts.centerTheta) or 0
  local centerPhi = tonumber(opts.centerPhi) or 0
  local edgeFeather = max(0, tonumber(opts.edgeFeather) or 0)

  local verticalMax = ies.verticalAngles[1] or 90
  for i = 2, #ies.verticalAngles do
    if ies.verticalAngles[i] > verticalMax then
      verticalMax = ies.verticalAngles[i]
    end
  end

  local maxAngle = opts.angle
  if maxAngle == nil then
    maxAngle = min(verticalMax, 90)
  end

  maxAngle = tonumber(maxAngle) or 90

  log("I", "",
    string.format(
      "Generating cookie: %dx%d, angle=%s, projection=%s, centerTheta=%s, centerPhi=%s",
      size,
      size,
      tostring(maxAngle),
      tostring(projection),
      tostring(centerTheta),
      tostring(centerPhi)
    )
  )

  local maxAngleRad = rad(maxAngle)

  local rot = rad(rotate)
  local cosRot = cos(rot)
  local sinRot = sin(rot)

  local basis = makeBasisFromCenter(centerTheta, centerPhi)
  local prepared = M.prepareHorizontalData(ies.horizontalAngles, ies.candela)

  local data = {}

  for y = 0, size - 1 do
    local cy = ((y + 0.5) / size) * 2 - 1
    local yy = -cy

    for x = 0, size - 1 do
      local cx = ((x + 0.5) / size) * 2 - 1
      local xx = cx

      local xr = xx * cosRot - yy * sinRot
      local yr = xx * sinRot + yy * cosRot

      local r = sqrt(xr * xr + yr * yr)

      local edgeMask
      if edgeFeather > 0 then
        local featherStart = max(0, 1 - edgeFeather)
        local featherDenom = 1 - featherStart
        if abs(featherDenom) < 1e-8 then
          edgeMask = r < 1 and 1 or 0
        else
          edgeMask = 1 - smoothstep((r - featherStart) / featherDenom)
        end

        if r > 1 then
          edgeMask = 0
        end
      else
        edgeMask = r <= 1 and 1 or 0
      end

      local lx, ly, lz

      if projection == "perspective" then
        local px = xr * tan(maxAngleRad)
        local py = yr * tan(maxAngleRad)
        local pz = 1
        local len = sqrt(px * px + py * py + pz * pz)

        lx = px / len
        ly = py / len
        lz = pz / len
      elseif projection == "linear" then
        local localTheta = r * maxAngleRad
        local localPhi = atan2(yr, xr)

        lx = sin(localTheta) * cos(localPhi)
        ly = sin(localTheta) * sin(localPhi)
        lz = cos(localTheta)
      else
        error("Unknown projection mode: " .. tostring(projection))
      end

      local dx =
        lx * basis.ux +
        ly * basis.vx +
        lz * basis.wx

      local dy =
        lx * basis.uy +
        ly * basis.vy +
        lz * basis.wy

      local dz =
        lx * basis.uz +
        ly * basis.vz +
        lz * basis.wz

      dz = clamp(dz, -1, 1)

      local theta = deg(acos(dz))
      local phi = mod360(deg(atan2(dy, dx)))

      local value = M.sampleIES(theta, phi, ies, prepared)
      data[y * size + x + 1] = value * edgeMask
    end
  end

  return {
    width = size,
    height = size,
    data = data,

    -- Reference is intentionally non-serializable metadata for saveImage().
    _ies = ies,

    generation = {
      size = size,
      angle = maxAngle,
      projection = projection,
      rotate = rotate,
      centerTheta = centerTheta,
      centerPhi = centerPhi,
      edgeFeather = edgeFeather,
    },
  }
end


-- Saving
local function percentileFromSorted(sorted, p)
  local n = #sorted
  if n == 0 then return 0 end

  if p <= 0 then return sorted[1] end
  if p >= 100 then return sorted[n] end

  local pos = (p / 100) * (n - 1) + 1
  local lo = floor(pos)
  local hi = ceil(pos)

  if lo < 1 then lo = 1 end
  if hi > n then hi = n end

  if lo == hi then return sorted[lo] end

  local t = pos - lo
  return sorted[lo] * (1 - t) + sorted[hi] * t
end

local function calculateNormalizationInfo(data, percentile)
  local nonzero = {}
  local maxValue = 0
  local nonzeroCount = 0

  for i = 1, #data do
    local v = data[i]

    if v > 0 then
      nonzeroCount = nonzeroCount + 1
      nonzero[nonzeroCount] = v

      if v > maxValue then
        maxValue = v
      end
    end
  end

  local norm = 1

  if nonzeroCount == 0 then
    norm = 1
  elseif percentile >= 100 then
    norm = maxValue
  else
    table.sort(nonzero)
    norm = percentileFromSorted(nonzero, percentile)

    if norm <= 0 then norm = maxValue end
    if norm <= 0 then norm = 1 end
  end

  return {
    maxValue = maxValue,
    nonzeroPixels = nonzeroCount,
    normalizationValue = norm,
    percentile = percentile,
  }
end

function M.saveImage(img, outPath, opts)
  opts = opts or {}

  outPath = normalizePath(outPath)

  local percentile = tonumber(opts.percentile) or 100
  local gamma = tonumber(opts.gamma) or 1
  local scale = tonumber(opts.scale) or 1
  local invert = opts.invert and true or false

  percentile = clamp(percentile, 0.001, 100)
  gamma = max(gamma, 0.001)
  scale = max(scale, 0)

  local w = img.width
  local h = img.height
  local data = img.data

  local normInfo = calculateNormalizationInfo(data, percentile)
  local norm = normInfo.normalizationValue

  local bmp = GBitmap()
  bmp:init(w, h)

  local c = ColorI(0, 0, 0, 255)

  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local idx = y * w + x + 1

      local v = data[idx] / norm
      v = clamp(v * scale, 0, 1)

      if gamma ~= 1 then
        v = v ^ (1 / gamma)
      end

      if invert then
        v = 1 - v
      end

      local iv = floor(v * 255 + 0.5)
      iv = clamp(iv, 0, 255)

      c.r = iv
      c.g = iv
      c.b = iv
      c.a = 255

      bmp:setColor(x, y, c)
    end
  end

  log("I", "", "Saving PNG: " .. tostring(outPath))
  local ok = bmp:saveFile(outPath)

  local saveInfo = {
    path = outPath,
    width = w,
    height = h,
    format = "RGB8 PNG",
    channels = 3,
    bitDepth = 8,

    percentile = percentile,
    gamma = gamma,
    scale = scale,
    invert = invert,

    maxValue = normInfo.maxValue,
    nonzeroPixels = normInfo.nonzeroPixels,
    normalizationValue = normInfo.normalizationValue,

    metadataWritten = false,
    metadataPath = nil,
  }

  if not ok then
    log("E", "", "Failed to save PNG: " .. tostring(outPath))
    return false, saveInfo
  end

  if img._ies and opts.writeMetadata ~= false then
    local metaOpts = {}

    if img.generation then
      for k, v in pairs(img.generation) do
        metaOpts[k] = v
      end
    end

    metaOpts.percentile = percentile
    metaOpts.gamma = gamma
    metaOpts.scale = scale
    metaOpts.invert = invert

    local metadataOk, metadataPathOrErr = M.writeCookieMetadata(img._ies, outPath, metaOpts, saveInfo)

    saveInfo.metadataWritten = metadataOk and true or false

    if metadataOk then
      saveInfo.metadataPath = metadataPathOrErr
      log("I", "", "Saved cookie metadata: " .. tostring(metadataPathOrErr))
    else
      log("W", "", "Failed to write cookie metadata: " .. tostring(metadataPathOrErr))
    end
  end

  log("I", "", "Saved PNG: " .. tostring(outPath))
  return true, saveInfo
end


-- Sidecar metadata
function M.getCookieMetadataPath(outPath)
  local p = tostring(outPath or "")
  local lp = p:lower()

  if string.endswith(lp, ".color.png") then
    return p:sub(1, #p - #".color.png") .. ".cookie.json"
  end

  if string.endswith(lp, ".png") then
    return p:sub(1, #p - #".png") .. ".cookie.json"
  end

  return p .. ".cookie.json"
end

local function firstNonEmpty(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v ~= nil and tostring(v) ~= "" then
      return tostring(v)
    end
  end

  return ""
end

local function makeSafeObjectName(s)
  s = tostring(s or "")
  s = s:gsub("%.[^%.]+$", "")
  s = s:gsub("[^%w_]", "_")
  s = s:gsub("_+", "_")
  s = s:gsub("^_+", ""):gsub("_+$", "")

  if s == "" then
    s = "IESLight"
  end

  if not s:match("^[A-Za-z_]") then
    s = "IES_" .. s
  end

  return s
end

local function getColorTemperatureKelvin(meta)
  local cct = getMetaValue(meta, {
    "_CCT",
    "_SEARCH_COLORTEMP",
    "CCT",
    "COLORTEMP",
    "COLOR_TEMPERATURE",
  })

  local kelvin = parseNumberFromString(cct)

  if kelvin and kelvin > 0 then
    return kelvin
  end

  return nil
end

local function getIESLumens(ies, meta)
  local absoluteLumens = parseNumberFromString(getMetaValue(meta, {
    "_ABSOLUTELUMENS",
    "_ABSLUMENS",
  }))

  if absoluteLumens and absoluteLumens > 0 then
    return absoluteLumens, "absolute"
  end

  local numLamps = tonumber(ies.numLamps)
  local lumensPerLamp = tonumber(ies.lumensPerLamp)

  if numLamps and lumensPerLamp and numLamps > 0 and lumensPerLamp > 0 then
    return numLamps * lumensPerLamp, "numLampsTimesLumensPerLamp"
  end

  return nil, nil
end

local function getIESWatts(ies, meta)
  local systemWatts = parseNumberFromString(getMetaValue(meta, {
    "_SYSTEMWATTS",
    "SYSTEMWATTS",
  }))

  if systemWatts and systemWatts > 0 then
    return systemWatts
  end

  local inputWatts = tonumber(ies.inputWatts)

  if inputWatts and inputWatts > 0 then
    return inputWatts
  end

  return nil
end

local function getFullSpotLightAngle(ies, opts)

  local halfAngle = tonumber(opts.angle)

  if not halfAngle then
    local verticalMax = 90

    if ies.verticalAngles and #ies.verticalAngles > 0 then
      verticalMax = ies.verticalAngles[1]

      for i = 2, #ies.verticalAngles do
        if ies.verticalAngles[i] > verticalMax then
          verticalMax = ies.verticalAngles[i]
        end
      end
    end

    halfAngle = min(verticalMax, 90)
  end

  return clamp(halfAngle * 2.0, 0.01, 180.0)
end

function M.buildCookieMetadata(ies, outPath, opts, saveInfo)
  opts = opts or {}

  local meta = ies.metadata or {}

  local peakTheta, peakPhi, peakCandela = M.getPeakDirection(ies)

  local manufacturer = getMetaValue(meta, {"MANUFAC"})
  local luminaire = getMetaValue(meta, {"LUMINAIRE"})
  local luminaireCatalog = getMetaValue(meta, {"LUMCAT"})
  local lamp = getMetaValue(meta, {"LAMP"})
  local lampCatalog = getMetaValue(meta, {"LAMPCAT"})
  local copyright = getMetaValue(meta, {"COPYRIGHT", "_COPYRIGHT"})

  local iesVersion = meta.version

  local name = firstNonEmpty(
    luminaireCatalog,
    luminaire,
    lampCatalog,
    lamp,
    basenameNoExt(ies.path)
  )

  local colorTemperatureKelvin = getColorTemperatureKelvin(meta)

  local lumens, lumensSource = getIESLumens(ies, meta)
  local watts = getIESWatts(ies, meta)

  local efficacy = nil
  if lumens and watts and watts > 0 then
    efficacy = lumens / watts
  end

  local outerAngle = getFullSpotLightAngle(ies, opts)

  local innerAngle = clamp(outerAngle * 0.90, 0.01, outerAngle)

  return {
    type = "IESLightImport",
    version = 1,

    source = {
      iesPath = ies.path,
      iesVersion = iesVersion ~= "" and iesVersion or nil,
      copyright = copyright ~= "" and copyright or nil,
    },

    names = {
      name = name,
      suggestedObjectName = makeSafeObjectName(name),

      manufacturer = manufacturer ~= "" and manufacturer or nil,

      luminaire = luminaire ~= "" and luminaire or nil,
      luminaireCatalog = luminaireCatalog ~= "" and luminaireCatalog or nil,

      lamp = lamp ~= "" and lamp or nil,
      lampCatalog = lampCatalog ~= "" and lampCatalog or nil,
    },

    assets = {
      cookieTexture = outPath,
      metadataPath = M.getCookieMetadataPath(outPath),
      imageWidth = saveInfo and saveInfo.width or opts.size,
      imageHeight = saveInfo and saveInfo.height or opts.size,
    },

    light = {
      class = "SpotLight",

      fields = {
        outerAngle = outerAngle,
        innerAngle = innerAngle,
      },

      candela = peakCandela,
      lumens = lumens,
      watts = watts,

      colorTemperatureKelvin = colorTemperatureKelvin,

      cookieTexture = outPath,
    },

    photometry = {
      candela = peakCandela,
      peakTheta = peakTheta,
      peakPhi = peakPhi,

      lumens = lumens,
      lumensSource = lumensSource,

      watts = watts,
      efficacyLmPerW = efficacy,

      photometricType = ies.photometricType,
      unitsType = ies.unitsType,
    },

    conversion = {
      -- Full game spotlight angle, not half-angle.
      outerAngle = outerAngle,

      projection = opts.projection or "perspective",
      rotate = opts.rotate or 0,

      autoCenter = opts.autoCenter and true or false,
      centerTheta = opts.centerTheta or 0,
      centerPhi = opts.centerPhi or 0,

      edgeFeather = opts.edgeFeather or 0,

      percentile = opts.percentile or 100,
      gamma = opts.gamma or 1,
      scale = opts.scale or 1,
      invert = opts.invert and true or false,

      tiltApplied = ies.tilt and ies.tilt.mode == "INCLUDE" or false,
    },
  }
end

function M.writeCookieMetadata(ies, outPath, opts, saveInfo)
  local metadataPath = M.getCookieMetadataPath(outPath)
  local data = M.buildCookieMetadata(ies, outPath, opts, saveInfo)

  local ok, err = pcall(function()
    jsonWriteFile(metadataPath, data, true)
  end)

  if not ok then
    return false, err
  end

  return true, metadataPath, data
end


-- High-level generation
function M.generateToFile(iesPath, outPath, opts)
  opts = opts or {}

  iesPath = normalizePath(iesPath)
  outPath = normalizePath(outPath)

  log("I", "", "Generating cookie from IES: " .. tostring(iesPath))

  local ies = M.parseIES(iesPath)

  if not opts.noInfo then
    M.printIESInfo(ies)
  end

  local centerTheta = opts.centerTheta or 0
  local centerPhi = opts.centerPhi or 0

  if opts.autoCenter then
    local peakTheta, peakPhi = M.getPeakDirection(ies)
    centerTheta = peakTheta
    centerPhi = peakPhi

    log("I", "", "Auto-center enabled.")
    log("I", "", "Using center theta: " .. tostring(centerTheta))
    log("I", "", "Using center phi:   " .. tostring(centerPhi))
  end

  local generationOptions = {
    size = opts.size or 1024,
    angle = opts.angle,
    projection = opts.projection or "perspective",
    rotate = opts.rotate or 0,
    centerTheta = centerTheta,
    centerPhi = centerPhi,
    edgeFeather = opts.edgeFeather or 0,
  }

  local cookie = M.generateCookie(ies, generationOptions)

  local saveOpts = {
    percentile = opts.percentile or 100,
    gamma = opts.gamma or 1,
    scale = opts.scale or 1,
    invert = opts.invert or false,
    writeMetadata = opts.writeMetadata,
  }

  local ok, saveInfo = M.saveImage(cookie, outPath, saveOpts)

  if not ok then
    log("E", "", "Failed to save cookie texture: " .. tostring(outPath))
    return false, {
      imagePath = outPath,
      saveInfo = saveInfo,
    }
  end

  log("I", "", "Saved cookie texture: " .. tostring(outPath))

  return true, {
    imagePath = outPath,
    metadataPath = saveInfo and saveInfo.metadataPath or nil,
    metadataWritten = saveInfo and saveInfo.metadataWritten or false,
    saveInfo = saveInfo,
  }
end

function M.inferCookiePathFromIES(iesPath)
  iesPath = normalizePath(iesPath)

  if iesPath == "" or string.endswith(iesPath, "/") then
    return ""
  end

  return dirname(iesPath) .. basenameNoExt(iesPath) .. ".color.png"
end

return M