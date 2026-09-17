-- Real astronomical sky, driven entirely by the level's TimeOfDay.
-- The level owns the single clock (time / play / dayLength / scales) and the observer
-- location + date (TimeOfDay.latitude/longitude/year/month/day). This extension reads that
-- one source of truth and positions the sun, the moon (size + lit phase) and the star-field
-- orientation to match, all from the same instant - so they can never disagree.
-- Stars are always rendered; in daytime the bright sky simply overpowers them (additive
-- blend + HDR exposure), exactly like real life.
local M = {}

local floor, abs, sqrt = math.floor, math.abs, math.sqrt
local sin, cos, tan, asin, acos = math.sin, math.cos, math.tan, math.asin, math.acos
local atan2 = math.atan2 or math.atan -- LuaJIT has atan2; 5.3+ folds it into atan(y,x)
local pi = math.pi
local DEG = pi / 180.0
local toDeg = 180.0 / pi

-- state ---------------------------------------------------------------------
local enabled = true        -- the real astronomical sky is on by default
local northOffsetDeg = 0.0  -- world +Y -> true north
local azimuthSign = 1       -- flip to -1 if the sky/sun ends up mirrored east-west
local moonScale = 0.05      -- realistic-ish moon size (level default ~0.2 is huge)
local skyId, todId = nil, nil
local saved = nil           -- level night chrome, restored verbatim when disabled
local applied = nil         -- enabled-state last pushed to the current sky (nil/true/false)
local meteorTest = false    -- debug: force a strong shower regardless of the date
local meteorTestRate = 30   -- meteors/min used while meteorTest is on
local METEOR_RATE_PRESETS = { default = false, low = 10, moderate = 30, high = 120 }
local hoverEnabled = false   -- mouse-over fact-sheet picking; enable from the Celestial Debug panel
local starMeta = nil         -- lazy-loaded star_meta.json (index-aligned with the star catalog)
local hoverAccum = 0.0       -- throttle accumulator for the hover pick
local lastHoverKey = nil     -- last hovered constellation/star, to fire the UI event only on change
local lastHover = nil        -- last hover result (constellation + star fact sheet), for polling
local activeProfile = nil    -- per-level celestial profile (atmosphere/bodies) loaded from JSON on mission start
local atmosphereApplied = false -- the profile's atmosphere is pushed to the sky once it is found
local customDriver = nil     -- optional mod per-frame sky driver (core_celestial.setDriver); nil = built-in Earth
local _ctx = {}              -- reused per-frame context handed to the driver (allocation-free hot path)

-- Fallback observer + date for a TimeOfDay that predates the location/date fields
-- (older levels, or before the engine carries them). The level overrides all of these.
local DEF_LAT, DEF_LON = 47.0, 8.0
local DEF_Y, DEF_MO, DEF_D = 2026, 6, 20
-- The earth profile's moon texture lives here as data (not baked into the renderer); a profile can override it.
local DEFAULT_MOON_ALBEDO = "/art/skies/night2/moon_albedo.png"

-- math helpers --------------------------------------------------------------
local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end
local function rev(x) x = x % 360.0; if x < 0 then x = x + 360.0 end; return x end
local function skyAzimuthDeg(az, northOff, sign) return rev(((sign or azimuthSign) * az + northOff) * toDeg) end
local function parseColor(s)
  if type(s) ~= "string" then return { 0, 0, 0, 1 } end
  local r, g, b, a = s:match("([%-%d.eE]+)%s+([%-%d.eE]+)%s+([%-%d.eE]+)%s*([%-%d.eE]*)")
  return { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1 }
end

-- Julian Date from a UTC calendar date (hour is fractional UTC hours; may be <0 or >24,
-- which simply shifts the continuous JD - used to fold the observer's clock into UT).
local function julianDate(y, mo, d, hour)
  if mo <= 2 then y = y - 1; mo = mo + 12 end
  local A = floor(y / 100)
  local B = 2 - A + floor(A / 4)
  return floor(365.25 * (y + 4716)) + floor(30.6001 * (mo + 1)) + d + B - 1524.5 + hour / 24.0
end

-- Sun (Schlyter): returns RA, Dec (radians) plus terms reused for moon perturbations.
local function computeSun(d)
  local ws = 282.9404 + 4.70935e-5 * d
  local es = 0.016709 - 1.151e-9 * d
  local Ms = rev(356.0470 + 0.9856002585 * d)
  local oblecl = 23.4393 - 3.563e-7 * d
  local E = Ms + toDeg * es * sin(Ms * DEG) * (1 + es * cos(Ms * DEG))
  local xv = cos(E * DEG) - es
  local yv = sin(E * DEG) * sqrt(1 - es * es)
  local v = toDeg * atan2(yv, xv)
  local r = sqrt(xv * xv + yv * yv)
  local lon = rev(v + ws)
  local xs, ys = r * cos(lon * DEG), r * sin(lon * DEG)
  local xe = xs
  local ye = ys * cos(oblecl * DEG)
  local ze = ys * sin(oblecl * DEG)
  return atan2(ye, xe), atan2(ze, sqrt(xe * xe + ye * ye)), Ms, ws, oblecl
end

-- Moon (Schlyter, main perturbation terms): returns RA, Dec (radians).
local function computeMoon(d, Ms, ws, oblecl)
  local N = rev(125.1228 - 0.0529538083 * d)
  local i = 5.1454
  local w = rev(318.0634 + 0.1643573223 * d)
  local a = 60.2666
  local e = 0.054900
  local Mm = rev(115.3654 + 13.0649929509 * d)
  local E = Mm + toDeg * e * sin(Mm * DEG) * (1 + e * cos(Mm * DEG))
  for _ = 1, 2 do
    E = E - (E - toDeg * e * sin(E * DEG) - Mm) / (1 - e * cos(E * DEG))
  end
  local xv = a * (cos(E * DEG) - e)
  local yv = a * sqrt(1 - e * e) * sin(E * DEG)
  local v = toDeg * atan2(yv, xv)
  local r = sqrt(xv * xv + yv * yv)
  local vw, Nr, ir = (v + w) * DEG, N * DEG, i * DEG
  local xh = r * (cos(Nr) * cos(vw) - sin(Nr) * sin(vw) * cos(ir))
  local yh = r * (sin(Nr) * cos(vw) + cos(Nr) * sin(vw) * cos(ir))
  local zh = r * sin(vw) * sin(ir)
  local lon = toDeg * atan2(yh, xh)
  local lat = toDeg * atan2(zh, sqrt(xh * xh + yh * yh))
  -- perturbations
  local Ls = rev(Ms + ws)
  local Lm = rev(Mm + w + N)
  local D = rev(Lm - Ls)
  local F = rev(Lm - N)
  lon = lon
    - 1.274 * sin((Mm - 2 * D) * DEG) + 0.658 * sin((2 * D) * DEG)
    - 0.186 * sin(Ms * DEG) - 0.059 * sin((2 * Mm - 2 * D) * DEG)
    - 0.057 * sin((Mm - 2 * D + Ms) * DEG) + 0.053 * sin((Mm + 2 * D) * DEG)
    + 0.046 * sin((2 * D - Ms) * DEG) + 0.041 * sin((Mm - Ms) * DEG)
    - 0.035 * sin(D * DEG) - 0.031 * sin((Mm + Ms) * DEG)
    - 0.015 * sin((2 * F - 2 * D) * DEG) + 0.011 * sin((Mm - 4 * D) * DEG)
  lat = lat
    - 0.173 * sin((F - 2 * D) * DEG) - 0.055 * sin((Mm - F - 2 * D) * DEG)
    - 0.046 * sin((Mm + F - 2 * D) * DEG) + 0.033 * sin((F + 2 * D) * DEG)
    + 0.017 * sin((2 * Mm + F) * DEG)
  r = r - 0.58 * cos((Mm - 2 * D) * DEG) - 0.46 * cos(2 * D * DEG) -- distance perturbation (Earth radii)
  local lonr, latr, obl = lon * DEG, lat * DEG, oblecl * DEG
  local xg = cos(lonr) * cos(latr)
  local yg = sin(lonr) * cos(latr)
  local zg = sin(latr)
  local xe = xg
  local ye = yg * cos(obl) - zg * sin(obl)
  local ze = yg * sin(obl) + zg * cos(obl)
  return atan2(ye, xe), atan2(ze, sqrt(xe * xe + ye * ye)), N, r -- N (deg): node for the orbit overlay; r: distance (Earth radii) for parallax
end

-- Equatorial -> horizontal. H = LST - RA. Azimuth from North, eastward (matches the C++ star matrix).
local function altAz(H, dec, lat)
  local sinAlt = clamp(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(H), -1, 1)
  local alt = asin(sinAlt)
  local cosAlt = cos(alt)
  local az = 0.0
  if abs(cosAlt) > 1e-6 and abs(cos(lat)) > 1e-6 then
    az = acos(clamp((sin(dec) - sin(lat) * sinAlt) / (cos(lat) * cosAlt), -1, 1))
    if sin(H) > 0 then az = 2 * pi - az end
    az = az % (2 * pi)
  end
  return alt, az
end

-- Local mean sidereal time (radians) for a Julian Date at an east-positive longitude.
local function localSiderealTime(jd, lonDeg)
  local gmst = rev(280.46061837 + 360.98564736629 * (jd - 2451545.0))
  return rev(gmst + lonDeg) * DEG
end

-- True altitude (deg) -> atmospheric refraction to add (deg), Saemundsson. Faded out below the
-- horizon so the apparent altitude stays continuous into twilight (no lighting discontinuity).
local function refractionDeg(hDeg)
  local hc = hDeg < -0.9 and -0.9 or hDeg
  local R = 1.02 / tan((hc + 10.3 / (hc + 5.11)) * DEG) / 60.0
  if hDeg < -0.9 then
    local t = (hDeg + 2.0) / 1.1
    R = R * (t > 0 and t or 0)
  end
  return R
end

-- Geocentric horizontal (alt, az in rad) + distance (Earth radii) -> topocentric, by offsetting the
-- observer one Earth radius along the local vertical from the geocentre. This is the lunar parallax
-- (up to ~1 deg near the horizon); it is ~9 arcsec for the sun, so we only apply it to the moon.
local function topocentric(alt, az, distER)
  local ca = cos(alt)
  local x = distER * sin(az) * ca
  local y = distER * cos(az) * ca
  local z = distER * sin(alt) - 1.0
  local len = sqrt(x * x + y * y + z * z)
  local a = atan2(x, y); if a < 0 then a = a + 2 * pi end
  return asin(z / len), a
end

-- Meteor showers ------------------------------------------------------------
-- The major annual showers: day-of-year peak, radiant (RA/Dec in degrees), a game-tuned peak
-- rate (meteors/min, not real ZHR) and a gaussian width in days. core_celestial picks the most
-- active shower for the date and feeds rate + radiant + "shower fraction" to the sky; off-peak
-- the sky shows a low sporadic baseline from random directions.
local CUMDAYS = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 } -- days before each month (non-leap)
local SPORADIC_RATE = 0.15 -- baseline meteors/min when no shower is active
local SHOWERS = {
  { name = "Quadrantids",   doy = 3,   ra = 230, dec = 49, peak = 12, sigma = 1.0 },
  { name = "Lyrids",        doy = 112, ra = 271, dec = 34, peak = 6,  sigma = 2.5 },
  { name = "Eta Aquariids", doy = 126, ra = 338, dec = -1, peak = 6,  sigma = 4.0 },
  { name = "Perseids",      doy = 224, ra = 48,  dec = 58, peak = 14, sigma = 6.0 },
  { name = "Orionids",      doy = 294, ra = 95,  dec = 16, peak = 6,  sigma = 4.0 },
  { name = "Leonids",       doy = 321, ra = 152, dec = 22, peak = 6,  sigma = 2.5 },
  { name = "Geminids",      doy = 348, ra = 112, dec = 33, peak = 14, sigma = 5.0 },
}

local function dayOfYear(y, mo, d) return CUMDAYS[mo] + d end
local function doyDist(a, b) local x = abs(a - b) % 365.25; return x < 365.25 - x and x or 365.25 - x end

-- The meteor state for a calendar date (no scene access, so it is unit-testable). The result
-- only changes when the date does, so it is cached and the same table is mutated in place: the
-- per-frame hot path recomputes nothing and allocates nothing. The returned table is shared and
-- reused, so a caller must read it before the next call with a different date.
local _meteor = { rate = SPORADIC_RATE, showerFraction = 0.0, ra = 46.2, dec = 57.4, activity = 0.0 }
local _meteorY, _meteorMo, _meteorD
local function meteorState(y, mo, d)
  if y == _meteorY and mo == _meteorMo and d == _meteorD then return _meteor end
  _meteorY, _meteorMo, _meteorD = y, mo, d
  local doy = dayOfYear(y, mo, d)
  local best, bestAct = nil, 0.0
  for _, s in ipairs(SHOWERS) do
    local x = doyDist(doy, s.doy) / s.sigma
    local act = math.exp(-0.5 * x * x)
    if act > bestAct then bestAct, best = act, s end
  end
  local out = _meteor
  out.activity = bestAct
  if best and bestAct > 0.02 then
    out.rate = SPORADIC_RATE + best.peak * bestAct
    out.showerFraction = clamp(bestAct, 0.0, 1.0)
    out.ra, out.dec = best.ra, best.dec
    out.name = bestAct > 0.05 and best.name or nil
  else
    out.rate, out.showerFraction, out.ra, out.dec, out.name = SPORADIC_RATE, 0.0, 46.2, 57.4, nil
  end
  return out
end

-- scene wiring --------------------------------------------------------------
local function getSky()
  if skyId then
    local obj = scenetree.findObjectById(skyId)
    if obj then return obj end
    skyId = nil
  end
  local names = scenetree.findClassObjects("ScatterSky")
  if names and names[1] then
    local obj = scenetree.findObject(names[1])
    if obj then skyId = obj:getID(); return obj end
  end
end

local function getTod()
  if todId then
    local obj = scenetree.findObjectById(todId)
    if obj then return obj end
    todId = nil
  end
  local names = scenetree.findClassObjects("TimeOfDay")
  if names and names[1] then
    local obj = scenetree.findObject(names[1])
    if obj then todId = obj:getID(); return obj end
  end
end

-- Civil timezone -> UTC offset (hours), with daylight saving. The standard offset defaults to the
-- nearest 15-deg meridian (round(lon/15)); real DST needs the zone identity (lat/lon only approximates
-- it), so "auto" applies the US rule in the temperate Americas, the EU rule elsewhere in the northern
-- temperate belt, the AU rule in the southern, and none in the tropics. Non-DST temperate zones (e.g.
-- Japan) and exact control come from tod.utcOffset (exact, DST included), tod.dstRule or setTimezone.
local tzStdOffset = nil  -- hours east of UTC; nil = derive from longitude
local tzRule = "auto"    -- "auto" | "eu" | "us" | "au" | "none"

local function dow(y, m, d) -- day of week, 0 = Sunday (Sakamoto)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y = y - 1 end
  return (y + floor(y / 4) - floor(y / 100) + floor(y / 400) + t[m] + d) % 7
end
local function lastSunday(y, m) local last = (m == 4 or m == 9 or m == 11) and 30 or 31; return last - dow(y, m, last) end
local function firstSunday(y, m) return 1 + (7 - dow(y, m, 1)) % 7 end

-- Daylight saving in effect? EU: last-Sun-Mar..last-Sun-Oct. US: 2nd-Sun-Mar..1st-Sun-Nov.
-- AU (southern, inverted): 1st-Sun-Oct..1st-Sun-Apr.
local function dstActive(rule, y, mo, d)
  if rule == "eu" then
    if mo < 3 or mo > 10 then return false elseif mo > 3 and mo < 10 then return true end
    return (mo == 3 and d >= lastSunday(y, 3)) or (mo == 10 and d < lastSunday(y, 10))
  elseif rule == "us" then
    if mo < 3 or mo > 11 then return false elseif mo > 3 and mo < 11 then return true end
    return (mo == 3 and d >= firstSunday(y, 3) + 7) or (mo == 11 and d < firstSunday(y, 11))
  elseif rule == "au" then
    if mo > 4 and mo < 10 then return false elseif mo < 4 or mo > 10 then return true end
    return (mo == 4 and d < firstSunday(y, 4)) or (mo == 10 and d >= firstSunday(y, 10))
  end
  return false
end

local function civilOffset(w)
  if w.utcOffset ~= nil then return w.utcOffset end -- level pinned the exact offset (DST included)
  local std = tzStdOffset or floor(w.lon / 15.0 + 0.5)
  local rule = w.dstRule or tzRule
  if rule == "auto" then -- temperate belts only: US in the Americas, EU elsewhere north, AU south
    if w.lat <= -30 then rule = "au"
    elseif w.lat >= 30 then rule = (w.lon > -170 and w.lon < -30) and "us" or "eu"
    else rule = "none" end
  end
  return std + (dstActive(rule, w.y, w.mo, w.d) and 1 or 0)
end

-- The level's "when + where". Engine `time` is a 0..1 day fraction with noon at 0.
-- Reuses one table (filled in place) so the per-frame hot path allocates nothing.
local _when = {}
local function readWhen(tod)
  local w = _when
  w.time = tod.time or 0.0
  w.lat = tod.latitude or DEF_LAT
  w.lon = tod.longitude or DEF_LON
  w.y, w.mo, w.d = tod.year or DEF_Y, tod.month or DEF_MO, tod.day or DEF_D
  w.utcOffset = tod.utcOffset -- optional level override: exact UTC offset in hours (DST included)
  w.dstRule = tod.dstRule     -- optional level override: "eu"/"us"/"au"/"none"
  return w
end

-- Real instant (Julian Date) for the level's day fraction at the observer. `time` is the civil local
-- clock ((time + 0.5) of a day, noon at time 0); UT = civil local - the zone's UTC offset (with DST).
local function whenToJD(w)
  local localHours = ((w.time + 0.5) % 1.0) * 24.0
  return julianDate(w.y, w.mo, w.d, localHours - civilOffset(w))
end

-- Black out the level's night chrome (so the additive stars stay crisp) and shrink the
-- moon to a realistic size; the originals are saved and restored verbatim when disabled.
local DEFAULT_NIGHT = "0.0196078 0.0117647 0.109804 1" -- ScatterSky's built-in night color
local function enableChrome(sky)
  local nc = sky:getField("nightColor", 0)
  local nf = sky:getField("nightFogColor", 0)
  -- a Lua hot-reload can re-capture our own blacked-out sky; treat all-black as "ours"
  -- and fall back to the engine default so disabling never sticks the sky black.
  local pc = parseColor(nc); if pc[1] + pc[2] + pc[3] < 1e-3 then nc = DEFAULT_NIGHT end
  local pf = parseColor(nf); if pf[1] + pf[2] + pf[3] < 1e-3 then nf = DEFAULT_NIGHT end
  saved = { nightColor = nc, nightFogColor = nf, moonScale = sky.moonScale, useNightCubemap = sky.useNightCubemap }
  sky:setField("nightColor", 0, "0 0 0 1")
  sky:setField("nightFogColor", 0, "0 0 0 1")
  sky.useNightCubemap = false
  sky.moonScale = moonScale
  sky.meteorsEnabled = true
  sky.moonEnabled = false -- the moon now renders as a data-driven body (setCelestialBodies), not the legacy path
end

-- Fall back to the level's authored night: restore its chrome/cubemap (if we changed it) and stop
-- every procedural element. Meteors and the shaded moon aren't gated on starVisibility, so they
-- must be turned off explicitly or they keep drawing over the cubemap.
local function disableSky(sky)
  if saved then
    sky:setField("nightColor", 0, saved.nightColor)
    sky:setField("nightFogColor", 0, saved.nightFogColor)
    sky.useNightCubemap = saved.useNightCubemap
    sky.moonScale = saved.moonScale
    saved = nil
  end
  sky.starVisibility = 0
  sky.meteorsEnabled = false
  sky.moonEnabled = false
  if setCelestialBodies then setCelestialBodies(sky:getID(), {}) end -- drop data-driven bodies too
end

-- Constellation name labels: the 88 IAU figures (3-letter ids match constellation_labels.bin).
-- Push localized {id:name} to ScatterSky, which bakes them into an in-memory atlas with Skia
-- (no disk) on first use and re-bakes on a language change.
local CONST_IDS = {
  "And","Ant","Aps","Aqr","Aql","Ara","Ari","Aur","Boo","Cae","Cam","Cnc","CVn","CMa","CMi",
  "Cap","Car","Cas","Cen","Cep","Cet","Cha","Cir","Col","Com","CrA","CrB","Crv","Crt","Cru",
  "Cyg","Del","Dor","Dra","Equ","Eri","For","Gem","Gru","Her","Hor","Hya","Hyi","Ind","Lac",
  "Leo","LMi","Lep","Lib","Lup","Lyn","Lyr","Men","Mic","Mon","Mus","Nor","Oct","Oph","Ori",
  "Pav","Peg","Per","Phe","Pic","Psc","PsA","Pup","Pyx","Ret","Sge","Sgr","Sco","Scl","Sct",
  "Ser","Sex","Tau","Tel","Tri","TrA","Tuc","UMa","UMi","Vel","Vir","Vol","Vul",
}
local namesDirty = true -- (re)push localized names on first apply and after a language change

local function pushConstellationNames(sky)
  local t = {}
  for _, id in ipairs(CONST_IDS) do
    t[id] = (_tr and _tr("ui.celestial.constellation." .. id .. ".name")) or id
  end
  sky:setField("constellationNames", 0, jsonEncode(t))
end

-- Celestial profiles (per-level JSON) ---------------------------------------
-- One file consolidates the level's atmosphere (and later, bodies). Resolved on mission start from
-- tod.celestialProfile (a bare name -> /art/skies/profiles/<name>.json, or a direct "/..." path)
-- and from the level folder's celestial.json; the atmosphere block is pushed to ScatterSky once found.
local function v3str(t) return string.format("%.9g %.9g %.9g", t[1] or 0, t[2] or 0, t[3] or 0) end

local function applyAtmosphere(sky, a)
  if not (sky and a) then return end
  if a.rayleighScattering then sky:setField("atmoRayleighScattering", 0, v3str(a.rayleighScattering)) end
  if a.mieScattering then sky:setField("atmoMieScattering", 0, v3str(a.mieScattering)) end
  if a.mieExtinction then sky:setField("atmoMieExtinction", 0, v3str(a.mieExtinction)) end
  if a.ozoneAbsorption then sky:setField("atmoAbsorption", 0, v3str(a.ozoneAbsorption)) end
  if a.groundAlbedo then sky:setField("atmoGroundAlbedo", 0, v3str(a.groundAlbedo)) end
  if a.solarIrradiance then sky:setField("atmoSunIrradiance", 0, v3str(a.solarIrradiance)) end
  if a.rayleighScaleHeightKm then sky.atmoRayleighScaleHeight = a.rayleighScaleHeightKm end
  if a.mieScaleHeightKm then sky.atmoMieScaleHeight = a.mieScaleHeightKm end
  if a.miePhaseG then sky.atmoMiePhaseG = a.miePhaseG end
  if a.planetRadiusKm then sky.atmoPlanetRadius = a.planetRadiusKm end
  if a.atmosphereHeightKm then sky.atmoThickness = a.atmosphereHeightKm end
  if a.skyBrightness then sky.skyBrightness = a.skyBrightness end
  if a.exposure then sky.exposure = a.exposure end
  if a.sunAngularSizeDeg then sky.atmoSunAngularSize = a.sunAngularSizeDeg end
  if a.ozoneLayerWidth then sky.atmoOzoneLayerWidth = a.ozoneLayerWidth end
  if a.ozoneConst0 then sky.atmoOzoneConst0 = a.ozoneConst0 end
  if a.ozoneLinear0 then sky.atmoOzoneLinear0 = a.ozoneLinear0 end
  if a.ozoneConst1 then sky.atmoOzoneConst1 = a.ozoneConst1 end
  if a.ozoneLinear1 then sky.atmoOzoneLinear1 = a.ozoneLinear1 end
end

local function resolveProfilePath()
  local tod = getTod()
  local explicit = tod and tod.celestialProfile
  if type(explicit) == "string" and explicit ~= "" then
    local p = explicit:find("/") and explicit or ("/art/skies/profiles/" .. explicit .. ".json")
    if FS:fileExists(p) then return p end
  end
  local mf = (getMissionFilename and getMissionFilename()) or ""
  if mf ~= "" then
    local dir = path.split(mf)
    if dir and FS:fileExists(dir .. "celestial.json") then return dir .. "celestial.json" end
  end
  return nil
end

local function loadLevelProfile()
  activeProfile, atmosphereApplied = nil, false
  local p = resolveProfilePath()
  if not p then return end
  local data = jsonReadFile(p)
  if type(data) == "table" then
    activeProfile = data
    log("I", "celestial", "loaded celestial profile: " .. p)
  end
end

-- Append the profile's extra bodies (planets / moons / extra suns) with lightweight apparent motion:
-- a fixed {azimuth,elevation}, or a circular path (ra0/dec advancing at 360deg per periodH hours).
-- Reuses the same altAz + sidereal-time math as the sun/moon so every body shares one sky frame.
local function appendProfileBodies(out, pbs, lst, lat, northOff, jd)
  for _, pb in ipairs(pbs) do
    local az, el
    if pb.azimuth ~= nil or pb.elevation ~= nil then
      az, el = pb.azimuth or 0, pb.elevation or 0
    else
      local rate = pb.periodH and (2 * pi * (jd * 24.0 / pb.periodH)) or 0
      local alt, a = altAz(lst - ((pb.ra0 or 0) * DEG + rate), (pb.dec or 0) * DEG, lat)
      az, el = skyAzimuthDeg(a, northOff), alt * toDeg
    end
    out[#out + 1] = {
      azimuth = az, elevation = el,
      angularSize = pb.angularSize or 0.5,
      illumination = pb.illumination or 1.0,
      brightnessEV = pb.brightnessEV or 0.0,
      emissive = pb.emissive and true or false,
      albedo = pb.albedo,
      tint = pb.tint and vec3(pb.tint[1] or 1, pb.tint[2] or 1, pb.tint[3] or 1) or nil,
    }
  end
end

-- Place equatorial coords (RA/Dec in degrees) into the current sky frame -> (azimuth deg, elevation
-- deg). Handed to a custom driver as ctx.altAz so it can position the sun/bodies without re-deriving.
local function ctxAltAz(raDeg, decDeg)
  local alt, az = altAz(_ctx.lst - raDeg * DEG, decDeg * DEG, _ctx.lat)
  return skyAzimuthDeg(az, _ctx.starNorthOffset), alt * toDeg
end

-- Position sun, moon and the star field for the level's current time + place.
local function apply(sky, tod)
  local w = readWhen(tod)
  local jd = whenToJD(w)
  local d = jd - 2451543.5
  local sunRA, sunDec, Ms, ws, oblecl = computeSun(d)
  local moonRA, moonDec, moonNode, moonDist = computeMoon(d, Ms, ws, oblecl)
  local lst = localSiderealTime(jd, w.lon)
  local lat = w.lat * DEG
  local northOff = northOffsetDeg * DEG

  local sunAlt, sunAz = altAz(lst - sunRA, sunDec, lat)
  local moonAlt, moonAz = altAz(lst - moonRA, moonDec, lat)

  -- geocentric -> what an observer on the ground actually sees: lunar parallax, then refraction
  moonAlt, moonAz = topocentric(moonAlt, moonAz, moonDist)
  sunAlt = sunAlt + refractionDeg(sunAlt * toDeg) * DEG
  moonAlt = moonAlt + refractionDeg(moonAlt * toDeg) * DEG

  local moonAzDeg = skyAzimuthDeg(moonAz, northOff)
  local moonElDeg = moonAlt * toDeg
  local cosElong = sin(sunDec) * sin(moonDec) + cos(sunDec) * cos(moonDec) * cos(sunRA - moonRA)
  local moonIllum = clamp((1 - cosElong) * 0.5, 0, 1)
  local m = meteorState(w.y, w.mo, w.d)

  -- Hand the real-sky defaults to a custom driver (if any) to retarget the sun, bodies, star
  -- orientation or meteors (e.g. a Mars sol, an arbitrary sun path, per-body phase). The built-in
  -- Earth sky leaves ctx untouched. ctx.altAz(raDeg, decDeg) places equatorial coords in this frame.
  local ctx = _ctx
  ctx.sky, ctx.time, ctx.jd, ctx.lst, ctx.lat, ctx.lon = sky, w.time, jd, lst, lat, w.lon
  ctx.year, ctx.month, ctx.day = w.y, w.mo, w.d
  ctx.sunAz, ctx.sunEl = skyAzimuthDeg(sunAz, northOff), sunAlt * toDeg
  ctx.starLst, ctx.starLat, ctx.starNorthOffset, ctx.starAzimuthSign, ctx.starVisibility = lst, lat, northOff, azimuthSign, 1.0
  ctx.moonOrbitNodeRad = moonNode * DEG
  ctx.meteorRate = meteorTest and meteorTestRate or m.rate
  ctx.meteorShowerFraction = meteorTest and 1.0 or m.showerFraction
  ctx.meteorRadiantRA = meteorTest and 48 or m.ra
  ctx.meteorRadiantDec = meteorTest and 58 or m.dec
  ctx.altAz = ctxAltAz

  local bodies = {
    { azimuth = moonAzDeg, elevation = moonElDeg, angularSize = sky.moonAngularSize or 1.5,
      illumination = moonIllum, albedo = (activeProfile and activeProfile.moonAlbedo) or DEFAULT_MOON_ALBEDO },
  }
  if activeProfile and activeProfile.bodies then
    appendProfileBodies(bodies, activeProfile.bodies, lst, lat, northOff, jd)
  end
  ctx.bodies = bodies

  if customDriver then customDriver(ctx) end

  -- Push the (possibly overridden) state. Sun az/el drives the atmosphere shader + scene light; the
  -- moon and any extra bodies render as billboards (the legacy single-moon path stays off).
  sky.azimuth = ctx.sunAz
  sky.elevation = ctx.sunEl
  sky.moonAzimuth = moonAzDeg
  sky.moonElevation = moonElDeg
  sky.moonIllumination = moonIllum
  sky.moonOrbitNodeRad = ctx.moonOrbitNodeRad
  sky.starLocalSiderealTime = ctx.starLst
  sky.starLatitude = ctx.starLat
  sky.starNorthOffset = ctx.starNorthOffset
  sky.starAzimuthSign = ctx.starAzimuthSign
  sky.starVisibility = ctx.starVisibility
  if setCelestialBodies then setCelestialBodies(sky:getID(), ctx.bodies) end
  if namesDirty then pushConstellationNames(sky); namesDirty = false end
  sky.meteorRate = ctx.meteorRate
  sky.meteorShowerFraction = ctx.meteorShowerFraction
  sky.meteorRadiantRA = ctx.meteorRadiantRA
  sky.meteorRadiantDec = ctx.meteorRadiantDec
end

-- Solar eclipses ------------------------------------------------------------
-- Find the next solar eclipse visible from the observer (the level's TimeOfDay lat/lon), starting at
-- the level's current instant, and return its calendar date + civil clock at maximum eclipse. This
-- reuses the very sun/moon model the sky renders, so the returned instant is the one where the
-- rendered moon sits most centred on the rendered sun for this location.
--
-- Two stages: step day-by-day to bracket each new moon (the geocentric sun-moon separation dips to a
-- monthly minimum), refine the conjunction, and - only when the geocentric miss distance is small
-- enough for the moon's shadow/penumbra to reach Earth at all - scan the few hours around it for the
-- observer's topocentric minimum separation. An eclipse is "visible here" when at that minimum the
-- discs overlap (separation < sun radius + moon radius) and the sun is above the horizon.
local SUN_RADIUS_RAD = 0.2666 * DEG  -- mean apparent solar radius
local MOON_PHYS_RADIUS_ER = 0.2725   -- moon radius in Earth radii (apparent size from its distance)
local ECLIPSE_MIN_MAGNITUDE = 0.001  -- filter eclipses below this overlap (normalized diameter percent, from 0 to 1)
local ECLIPSE_GEO_LIMIT_DEG = 1.6    -- geocentric miss distance below which an eclipse can occur somewhere on Earth
local ECLIPSE_MAX_YEARS = 30         -- give up after this many years if nothing is visible here
local SYNODIC_DAYS = 29.530588861    -- mean interval between new moons; eclipses can only happen at one
local NEWMOON_EPOCH_JD = 2451550.09766 -- a reference new moon (2000-01-06), to land each search window on a lunation

-- Geocentric sun + moon equatorial coords (radians) and moon distance (Earth radii) for a Julian Date.
local function sunMoonAtJD(jd)
  local d = jd - 2451543.5
  local sunRA, sunDec, Ms, ws, oblecl = computeSun(d)
  local moonRA, moonDec, _, moonDist = computeMoon(d, Ms, ws, oblecl)
  return sunRA, sunDec, moonRA, moonDec, moonDist
end

-- Angular separation (radians) between two sky points, each given as (latitude, longitude) on the
-- sphere - i.e. (dec, RA) for equatorial coords or (alt, az) for horizontal ones.
local function angSep(lat1, lon1, lat2, lon2)
  return acos(clamp(sin(lat1) * sin(lat2) + cos(lat1) * cos(lat2) * cos(lon1 - lon2), -1, 1))
end

-- Geocentric angular separation (radians) of the sun and moon centres.
local function geoSunMoonSep(jd)
  local sunRA, sunDec, moonRA, moonDec = sunMoonAtJD(jd)
  return angSep(sunDec, sunRA, moonDec, moonRA)
end

-- Observer-local circumstances at a Julian Date: topocentric sun-moon separation (radians), the sun's
-- altitude (radians) and the summed disc radius (radians, sun + moon apparent radii).
local function topoCircumstances(jd, latRad, lonDeg)
  local sunRA, sunDec, moonRA, moonDec, moonDist = sunMoonAtJD(jd)
  local lst = localSiderealTime(jd, lonDeg)
  local sunAlt, sunAz = altAz(lst - sunRA, sunDec, latRad)
  local moonAlt, moonAz = altAz(lst - moonRA, moonDec, latRad)
  moonAlt, moonAz = topocentric(moonAlt, moonAz, moonDist)
  local moonR = asin(clamp(MOON_PHYS_RADIUS_ER / moonDist, -1, 1))
  return angSep(sunAlt, sunAz, moonAlt, moonAz), sunAlt, SUN_RADIUS_RAD + moonR
end

-- Golden-section minimum of a single-dip f over [a, b]; returns the argmin.
local function goldenMin(f, a, b, iters)
  local gr = 0.6180339887498949
  local c = b - (b - a) * gr
  local d = a + (b - a) * gr
  local fc, fd = f(c), f(d)
  for _ = 1, iters or 50 do
    if fc < fd then
      b, d, fd = d, c, fc
      c = b - (b - a) * gr
      fc = f(c)
    else
      a, c, fc = c, d, fd
      d = a + (b - a) * gr
      fd = f(d)
    end
  end
  if fc < fd then return c else return d end
end

-- Julian Date -> Gregorian calendar (proleptic): year, month, day, day-fraction (0..1). (Meeus)
local function jdToGregorian(jd)
  local z = floor(jd + 0.5)
  local f = (jd + 0.5) - z
  local A
  if z < 2299161 then
    A = z
  else
    local alpha = floor((z - 1867216.25) / 36524.25)
    A = z + 1 + alpha - floor(alpha / 4)
  end
  local B = A + 1524
  local C = floor((B - 122.1) / 365.25)
  local Dd = floor(365.25 * C)
  local E = floor((B - Dd) / 30.6001)
  local dayWithFrac = B - Dd - floor(30.6001 * E) + f
  local month = (E < 14) and (E - 1) or (E - 13)
  local year = (month > 2) and (C - 4716) or (C - 4715)
  local day = floor(dayWithFrac)
  return year, month, day, dayWithFrac - day
end

-- Inverse of whenToJD: a Julian Date -> the level's date + civil clock (time is the engine's 0..1 day
-- fraction with noon at 0), using the observer's timezone. DST is taken from the UTC date, exact except
-- within an hour of a DST switch - fine for placing the clock.
local function jdToWhen(jd, w)
  local uy, umo, ud = jdToGregorian(jd)
  local offset = civilOffset({ lat = w.lat, lon = w.lon, y = uy, mo = umo, d = ud, utcOffset = w.utcOffset, dstRule = w.dstRule })
  local y, mo, d, frac = jdToGregorian(jd + offset / 24.0)
  return { year = y, month = mo, day = d, time = (frac - 0.5) % 1.0 }
end

-- Search forward from the instant described by `w` (a readWhen-style table) for the next solar eclipse
-- visible at w.lat/w.lon. Returns { year, month, day, time } at maximum eclipse, or nil.
local function findNextSolarEclipseFrom(w)
  local latRad = w.lat * DEG
  local startJD = whenToJD(w)
  -- "next" means strictly after the selected instant: ignore an eclipse whose maximum is at or just
  -- before now (e.g. the one we just jumped to), so repeated calls walk forward to each later eclipse.
  local minJD = startJD + 1.0 / 24.0
  local endJD = startJD + ECLIPSE_MAX_YEARS * 365.25
  -- An eclipse can only happen at a new moon, and new moons recur every synodic month, so jump straight
  -- from one to the next instead of scanning day by day. Start on the lunation at/just before now and
  -- golden-refine each half-month window to its single geocentric-separation minimum (the conjunction).
  local jd = NEWMOON_EPOCH_JD + floor((startJD - NEWMOON_EPOCH_JD) / SYNODIC_DAYS) * SYNODIC_DAYS

  while jd < endJD do
    local conj = goldenMin(geoSunMoonSep, jd - SYNODIC_DAYS * 0.5, jd + SYNODIC_DAYS * 0.5, 50)
    if geoSunMoonSep(conj) < ECLIPSE_GEO_LIMIT_DEG * DEG then
      -- scan the observer's local circumstances across the few hours around conjunction. Diurnal
      -- parallax can make the topocentric separation non-convex, so coarse-sample for the global
      -- minimum first, then golden-refine within one coarse step of it.
      local window = 0.18         -- ~4.3 h either side covers any partial phase at a single location
      local coarse = 5.0 / 1440.0 -- 5-minute coarse step
      local topoSepF = function(t) return (topoCircumstances(t, latRad, w.lon)) end
      local bestT, bestSep = conj, topoSepF(conj)
      local t = conj - window
      while t <= conj + window do
        local s = topoSepF(t)
        if s < bestSep then bestSep, bestT = s, t end
        t = t + coarse
      end
      local tMax = goldenMin(topoSepF, bestT - coarse, bestT + coarse, 40)
      local sep, sunAlt, sumR = topoCircumstances(tMax, latRad, w.lon)
      local magnitude = (sumR - sep) / (2 * SUN_RADIUS_RAD) -- fraction of the solar diameter covered
      if tMax > minJD and sunAlt > 0 and magnitude >= ECLIPSE_MIN_MAGNITUDE then
        return jdToWhen(tMax, w)
      end
    end
    jd = jd + SYNODIC_DAYS
  end
  return nil
end

-- public API ----------------------------------------------------------------
function M.setEnabled(on) enabled = on and true or false end -- onUpdate eases in/out from here

-- Next solar eclipse visible at the level's observer, from the level's current instant.
-- Returns { year, month, day, time } at maximum eclipse, or nil if none within range.
function M.findNextSolarEclipse()
  local tod = getTod(); if not tod then return end
  return findNextSolarEclipseFrom(readWhen(tod))
end
function M.isEnabled() return enabled end
-- Replace the per-frame sky driver. fn(ctx) gets the real-sky defaults pre-filled for the level's
-- time+place (ctx.sunAz/sunEl, ctx.bodies, ctx.star*, ctx.meteor*, ctx.time/jd/lst/lat/lon) and an
-- ctx.altAz(raDeg, decDeg) helper; mutate them to retarget the sky. Pass nil to restore the built-in.
function M.setDriver(fn) customDriver = (type(fn) == "function") and fn or nil end
function M.getDriver() return customDriver end
-- Mouse-over fact sheet: the UI overlay enables this while shown (default on); getHover() polls
-- the last result. Picking only runs while the sky is visible and is throttled to ~16 Hz.
function M.setHoverEnabled(on)
  hoverEnabled = on and true or false
  if not hoverEnabled then lastHoverKey, lastHover = nil, nil end
end
function M.getHover() return lastHover end
function M.setNorthOffset(deg) northOffsetDeg = tonumber(deg) or 0 end
function M.getNorthOffset() return northOffsetDeg end
function M.setAzimuthSign(s) azimuthSign = (s and s < 0) and -1 or 1 end

function M.setMoonScale(s)
  moonScale = tonumber(s) or moonScale
  local sky = getSky()
  if sky and saved then sky.moonScale = moonScale end -- live-apply while enabled
end

-- Debug: force a strong shower so the effect can be previewed off-season (apply() reads these).
function M.setMeteorTest(on) meteorTest = on and true or false end
function M.setMeteorTestRate(r) meteorTestRate = tonumber(r) or meteorTestRate; meteorTest = true end

function M.setMeteorRatePreset(preset)
  local rate = METEOR_RATE_PRESETS[preset or "default"]
  if rate == false then
    meteorTest = false
  elseif rate then
    meteorTestRate = rate
    meteorTest = true
  end
end

local function getMeteorRatePreset()
  if not meteorTest then return "default" end
  for key, rate in pairs(METEOR_RATE_PRESETS) do
    if rate and abs(meteorTestRate - rate) < 1e-6 then return key end
  end
  return "custom"
end

local DISPLAY_FIELD_MAP = {
  constellationLines = "constellationsEnabled",
  constellationLabels = "constellationNamesEnabled",
  horizonGrid = "gridEnabled",
  equatorialGrid = "equatorialGridEnabled",
  meridianGrid = "meridianEnabled",
  moonGrid = "moonPathEnabled",
}

local function getDisplayState()
  local sky = getSky()
  local res = { hasSky = sky ~= nil }
  if not sky then return res end
  for key, field in pairs(DISPLAY_FIELD_MAP) do
    res[key] = sky[field] == true
  end
  return res
end

function M.setDisplayOption(key, value)
  local field = DISPLAY_FIELD_MAP[key]
  local sky = field and getSky()
  if sky then sky[field] = value and true or false end
end

function M.getDisplayState() return getDisplayState() end

-- Location + date live on the level's TimeOfDay (the single source of truth); these
-- write-through helpers let scripts/UI set them through this extension if convenient.
function M.setLocation(latDeg, lonDeg)
  local tod = getTod(); if not tod then return end
  tod.latitude = tonumber(latDeg) or tod.latitude
  tod.longitude = tonumber(lonDeg) or tod.longitude
end

function M.setDate(y, mo, d)
  local tod = getTod(); if not tod then return end
  if y then tod.year = y end; if mo then tod.month = mo end; if d then tod.day = d end
end

-- Civil timezone: standard UTC offset in hours (nil = derive from longitude) and DST rule
-- ("auto"/"eu"/"us"/"au"/"none"). A level can instead set tod.utcOffset / tod.dstRule directly.
function M.setTimezone(stdOffsetHours, rule)
  tzStdOffset = tonumber(stdOffsetHours)
  if rule ~= nil then tzRule = rule end
end

-- Celestial profile: load/replace at runtime (a path to a JSON, or an already-decoded table).
-- The atmosphere block is re-pushed to ScatterSky on the next frame.
function M.loadProfile(profile)
  if type(profile) == "string" then profile = jsonReadFile(profile) end
  if type(profile) ~= "table" then return false end
  activeProfile, atmosphereApplied = profile, false
  return true
end
function M.getActiveProfile() return activeProfile end

-- Full config snapshot (for debug tools / scripting); the location/date come from the
-- level, the look/orientation from here. Live sun/moon/star values are read off the sky.
function M.getState()
  local tod = getTod()
  local w = tod and readWhen(tod) or {}
  local m = meteorState(w.y or DEF_Y, w.mo or DEF_MO, w.d or DEF_D)
  return {
    enabled = enabled, hoverEnabled = hoverEnabled, northOffsetDeg = northOffsetDeg, azimuthSign = azimuthSign, moonScale = moonScale,
    latitude = w.lat, longitude = w.lon, year = w.y, month = w.mo, day = w.d, time = w.time,
    meteor = {
      name = m.name, test = meteorTest,
      ratePreset = getMeteorRatePreset(),
      rate = meteorTest and meteorTestRate or m.rate,
      showerFraction = meteorTest and 1.0 or m.showerFraction,
    },
    display = getDisplayState(),
  }
end

-- Hover fact sheet: on mouse-over, pick the constellation (nearest figure) + the nearest catalog
-- star and hand the UI a fact sheet. Throttled, and only while the sky is visible. The rich star
-- metadata is loaded once from star_meta.json; pickCelestial returns the catalog index straight
-- into it. Fires the "CelestialHover" guihook on change; core_celestial.getHover() also polls it.
local function getStarMeta()
  if starMeta == nil then
    starMeta = jsonReadFile("/art/skies/stars/star_meta.json") or false
  end
  return starMeta or nil
end

-- Fact-sheet card: a Skia flex template rendered to a camera-facing WorldBillboard that floats
-- where you point. Two templates (star + constellation); labels are filled per render from _tr so
-- the card is fully localized and tracks the current language. Mirrors the taxi state billboards.
local cardRenderer = nil
local starCardId, constCardId = nil, nil
local currentCard, currentH = nil, 0
local currentTargetDir = nil -- world dir of the hovered object (leader line + shimmer target)
local shimmerT = 0.0         -- clock for the hover shimmer pulse
local cardHide = vec3(0, 0, 0)

-- Colours are intentionally near-black / low-saturation: the billboard is sampled display-referred
-- through an sRGB curve that lifts + desaturates everything, so a "normal" navy reads as candy blue.
local function cardRow(lbl, val)
  local k = M.hover.res
  return { type = "group", style = { flexDirection = "row", justifyContent = "space-between", height = 42 * k, marginTop = 2 * k },
    children = {
      { type = "text", text = "{" .. lbl .. "}", fontSize = 26 * k, color = "#8893a6", textAlign = "left", style = { width = "50%", height = 34 * k } },
      { type = "text", text = "{" .. val .. "}", fontSize = 26 * k, color = "#e9eef7", fit = "shrink", textAlign = "right", style = { width = "50%", height = 34 * k } },
    } }
end

local function starCardTemplate()
  local k = M.hover.res
  local W, H = 660 * k, 372 * k
  return { size = { W, H }, root = { type = "group", style = { flexDirection = "column", padding = 28 * k }, children = {
    { type = "box", color = "#0b0e15f2", radius = 18 * k, stroke = "#39435c", strokeWidth = 2 * k,
      shadow = { color = "#000000aa", blur = 22 * k, dy = 8 * k }, style = { position = "absolute", left = 0, top = 0, width = W, height = H } },
    { type = "text", text = "{name}", fontSize = 54 * k, color = "#f3f6fc", fit = "shrink", textAlign = "left", style = { height = 62 * k } },
    { type = "text", text = "{sub}", fontSize = 26 * k, color = "#8e9cb6", fit = "shrink", textAlign = "left", style = { height = 32 * k, marginBottom = 12 * k } },
    cardRow("lblMag", "mag"), cardRow("lblDist", "dist"), cardRow("lblSpect", "spect"),
    cardRow("lblTemp", "temp"), cardRow("lblRv", "rv"),
  } } }
end

local function constCardTemplate()
  local k = M.hover.res
  local W, H = 580 * k, 156 * k
  return { size = { W, H }, root = { type = "group", style = { flexDirection = "column", justifyContent = "center", padding = 26 * k }, children = {
    { type = "box", color = "#0b0e15f2", radius = 18 * k, stroke = "#39435c", strokeWidth = 2 * k,
      shadow = { color = "#000000aa", blur = 20 * k, dy = 6 * k }, style = { position = "absolute", left = 0, top = 0, width = W, height = H } },
    { type = "text", text = "{name}", fontSize = 52 * k, color = "#f3f6fc", fit = "shrink", textAlign = "left", style = { height = 60 * k } },
    { type = "text", text = "{blurb}", fontSize = 24 * k, color = "#9aa7c0", fit = "shrink", textAlign = "left", style = { height = 30 * k, marginTop = 6 * k } },
  } } }
end

local function ensureCardRenderer()
  if not (cardRenderer and cardRenderer.create) then
    local existing = scenetree and scenetree.celestialCards
    -- A renderer that outlived this module (a Lua reload) still holds the old cards; drop it so we
    -- rebuild cleanly instead of leaving a stale ghost card behind.
    if existing and not starCardId and existing.delete then existing:delete(); existing = nil end
    cardRenderer = existing or nil
  end
  if not cardRenderer then
    if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then return nil end
    local r = WorldBillboardRenderer()
    if not r then return nil end
    r:registerObject("celestialCards")
    scenetree.MissionGroup:addObject(r)
    cardRenderer = r
    starCardId, constCardId = nil, nil
  end
  if not starCardId then
    starCardId = cardRenderer:create(jsonEncode(M.hover.starTemplate()), true)
    if starCardId then cardRenderer:setScreenFacing(starCardId, true, M.hover.tilt) end
  end
  if not constCardId then
    constCardId = cardRenderer:create(jsonEncode(M.hover.constTemplate()), true)
    if constCardId then cardRenderer:setScreenFacing(constCardId, true, M.hover.tilt) end
  end
  return cardRenderer
end

local function tru(k) return (_tr and _tr(k)) or k end

local function starCardVars(s)
  local lyU, kU, kmsU = tru("ui.celestial.card.unit.ly"), tru("ui.celestial.card.unit.k"), tru("ui.celestial.card.unit.kms")
  local name = s.name or s.desig or (s.hr and ("HR " .. s.hr)) or tru("ui.celestial.card.star")
  local sub = {}
  if s.name and s.desig then sub[#sub + 1] = s.desig end
  if s.con then sub[#sub + 1] = tru("ui.celestial.constellation." .. s.con .. ".name") end
  return {
    name = name, sub = table.concat(sub, "   "),
    lblMag = tru("ui.celestial.card.magnitude"), mag = s.mag and string.format("%.2f", s.mag) or "-",
    lblDist = tru("ui.celestial.card.distance"), dist = s.dist_ly and (string.format("%.1f", s.dist_ly) .. " " .. lyU) or "-",
    lblSpect = tru("ui.celestial.card.spectralType"), spect = s.spect or "-",
    lblTemp = tru("ui.celestial.card.temperature"), temp = s.tempK and (tostring(s.tempK) .. " " .. kU) or "-",
    lblRv = tru("ui.celestial.card.radialVelocity"), rv = s.rv and (tostring(s.rv) .. " " .. kmsU) or "-",
  }
end

local function constCardVars(id)
  local blurbKey = "ui.celestial.constellation." .. id .. ".blurb"
  local blurb = tru(blurbKey)
  if blurb == blurbKey then blurb = "" end -- no blurb authored yet -> just the name
  return { name = tru("ui.celestial.constellation." .. id .. ".name"), blurb = blurb }
end

-- Public hover config + builders so mods can retune or fully replace the fact-sheet card / highlight
-- without forking this file, e.g.:
--   core_celestial.hover.dist = 20                  -- nudge a number (takes effect next frame)
--   core_celestial.hover.shimmerColor = {1, 0, 0}   -- red shimmer
--   core_celestial.hover.starTemplate = function() return { size = {...}, root = {...} } end
--   core_celestial.refreshHoverCards()              -- rebuild the cards after a *Template override
M.hover = {
  dist = 16,             -- metres in front of the camera where the card sits
  starHeight = 4.6,      -- world height of the star card
  constHeight = 2.5,     -- world height of the constellation card
  rightFrac = 0.82,      -- placement toward the right edge (fraction of dist)
  downFrac = 0.10,       -- slight drop below centre
  tilt = -0.22,          -- screen-facing yaw (~12 deg; sign picks which edge angles back, 0 = flat)
  res = 2,               -- card texture supersample (2 = sharp; higher = sharper + more VRAM)
  starPickDeg = 1.5,     -- within this angle of a star -> star card
  constPickDeg = 6,      -- else nearest star within this -> show its constellation
  shimmerDist = 40,      -- distance along the object dir for the shimmer ring
  shimmerRadiusFrac = 0.025,              -- ring radius as a fraction of shimmerDist
  shimmerColor = { 1.0, 0.9, 0.45 },      -- rgb; alpha pulses on its own
  leaderColor = { 0.95, 0.8, 0.25, 0.5 }, -- rgba of the leader line
  starTemplate = starCardTemplate,   -- () -> flex template table for the star card
  constTemplate = constCardTemplate, -- () -> flex template table for the constellation card
  starVars = starCardVars,           -- (meta) -> { token = value } for the star card
  constVars = constCardVars,         -- (id)   -> { token = value } for the constellation card
}

-- Drop the cards so the next hover rebuilds them from M.hover (call after a *Template override).
function M.refreshHoverCards()
  if cardRenderer and cardRenderer.destroy then
    if starCardId then cardRenderer:destroy(starCardId) end
    if constCardId then cardRenderer:destroy(constCardId) end
  end
  starCardId, constCardId, currentCard, currentTargetDir, lastHoverKey = nil, nil, nil, nil, nil
end

-- Pulsing ring around the hovered object (the star, or the nearest star of a constellation) so the
-- matched object - and only it - is highlighted. Drawn in the plane facing the camera at its dir.
local function drawShimmer(cam, dir)
  if not debugDrawer then return end
  local h = M.hover
  local center = cam + dir * h.shimmerDist
  local rt = dir:cross(vec3(0, 0, 1))
  if rt:length() < 1e-3 then rt = vec3(1, 0, 0) end
  rt:normalize()
  local upv = rt:cross(dir); upv:normalize()
  local radius = h.shimmerDist * h.shimmerRadiusFrac
  local a = 0.25 + 0.30 * math.abs(math.sin(shimmerT * 5.0))
  local sc = h.shimmerColor
  local col = ColorF(sc[1], sc[2], sc[3], a)
  local prev = nil
  for i = 0, 28 do
    local ang = (i / 28) * 6.2831853
    local p = center + rt * (math.cos(ang) * radius) + upv * (math.sin(ang) * radius)
    if prev then debugDrawer:drawLine(prev, p, col) end
    prev = p
  end
end

local function updateHover(sky, dtReal)
  shimmerT = shimmerT + (dtReal or 0)
  local h = M.hover
  local r = hoverEnabled and ensureCardRenderer() or nil
  local function hideCards()
    if cardRenderer and starCardId then cardRenderer:update(starCardId, cardHide, 0, false) end
    if cardRenderer and constCardId then cardRenderer:update(constCardId, cardHide, 0, false) end
    currentCard, currentTargetDir = nil, nil
  end
  if not r or not pickCelestial or (sky.starVisibility or 0) <= 0.0 then hideCards(); lastHoverKey = nil; return end

  local ok, _, dir = getCameraMouseRayPosDir()
  if not ok then hideCards(); return end

  -- Throttled: decide what is under the cursor + (re)render that card's content only on change.
  hoverAccum = hoverAccum + (dtReal or 0)
  if hoverAccum >= 0.06 then
    hoverAccum = 0
    -- Nearest star within the (larger) constellation radius. On a star -> star card; otherwise that
    -- star's constellation, anchored on the star so the highlight sits next to the cursor. The old
    -- nearest-centroid pick jumped to far-off figure centres - that was the "random" highlighting.
    local hit = pickCelestial(sky:getID(), dir, h.constPickDeg)
    local star = hit and hit.star
    local ang = (hit and hit.starAngle) or 99
    local sm = star and getStarMeta()
    sm = sm and sm[star + 1]
    local onStar = star ~= nil and ang <= h.starPickDeg
    -- Constellation only when near a figure star (within constPickDeg) but not on it: name from that
    -- star's catalogue constellation when known, else the figure the cursor sits nearest to.
    local con = (star ~= nil and not onStar) and ((sm and sm.con) or hit.constellation) or nil
    local key = (onStar and ("s" .. star)) or (con and ("c" .. con)) or "-"
    if key ~= lastHoverKey then
      lastHoverKey = key
      lastHover = hit
      r:update(starCardId, cardHide, 0, false)
      r:update(constCardId, cardHide, 0, false)
      currentCard, currentTargetDir = nil, nil
      if onStar then
        r:render(starCardId, jsonEncode(h.starVars(sm or { mag = hit.starMag })))
        currentCard, currentH, currentTargetDir = starCardId, h.starHeight, hit.starDir
      elseif con then
        r:render(constCardId, jsonEncode(h.constVars(con)))
        currentCard, currentH, currentTargetDir = constCardId, h.constHeight, hit.starDir
      end
    end
  end

  -- Every frame: pin the card to the right edge of the view, then draw the leader line + shimmer to
  -- the matched object only (its actual sky position, not the raw cursor ray).
  if currentCard then
    local cam = core_camera.getPosition()
    local fwd = core_camera.getForward()
    local rt = fwd:cross(vec3(0, 0, 1))
    if rt:length() < 1e-3 then rt = vec3(1, 0, 0) end
    rt:normalize()
    local upv = rt:cross(fwd); upv:normalize()
    local cp = cam + fwd * h.dist + rt * (h.dist * h.rightFrac) - upv * (h.dist * h.downFrac)
    r:update(currentCard, cp, currentH, true)
    if currentTargetDir then
      local lc = h.leaderColor
      if debugDrawer then debugDrawer:drawLine(cp, cam + currentTargetDir * h.dist, ColorF(lc[1], lc[2], lc[3], lc[4])) end
      drawShimmer(cam, currentTargetDir)
    end
  end
end

-- Positioned in onPreRender, not onUpdate: the engine's TimeOfDay advances `time` in its
-- tick, which runs *after* onUpdate but *before* onPreRender. Reading it here gives the
-- current frame's freshly-advanced clock, so the sky stays in lockstep with the C++ time
-- with no one-frame lag.
function M.onPreRender(dtReal, dtSim)
  local sky = getSky()
  if not sky then return end
  if activeProfile and not atmosphereApplied then
    applyAtmosphere(sky, activeProfile.atmosphere)
    atmosphereApplied = true
  end
  if enabled then
    if applied ~= true then enableChrome(sky); applied = true end
    local tod = getTod()
    if tod then apply(sky, tod) end
    updateHover(sky, dtReal)
  elseif applied ~= false then
    disableSky(sky); applied = false
  end
end

function M.onExtensionLoaded()
  setExtensionUnloadMode(M, "manual") -- stay loaded across level/mode changes
end

-- each level gets a fresh ScatterSky/TimeOfDay: drop caches so the next frame re-captures
local function resetCaches()
  skyId, todId, saved, applied = nil, nil, nil, nil
  namesDirty = true
  lastHoverKey, lastHover = nil, nil
  cardRenderer, starCardId, constCardId, currentCard, currentTargetDir = nil, nil, nil, nil, nil -- fresh renderer per level
  atmosphereApplied = false
end
M.onClientPostStartMission = function() resetCaches(); loadLevelProfile() end
M.onClientEndMission = function() resetCaches(); activeProfile = nil end
-- Re-bake the name atlas + refresh the hover cards whenever the language switches or the locale files
-- are hot-reloaded (translator iteration). The C++ side only re-bakes if the rebuilt JSON differs, so
-- this is free when nothing actually changed (e.g. a locale with no celestial keys falls back to en-US).
local function onLocalesChanged() namesDirty = true; lastHoverKey = nil end
M.onLanguageChanged = onLocalesChanged
M.onReloadLocales = onLocalesChanged

-- one runnable self-check for the astronomy math: core_celestial.selftest()
function M.selftest()
  local function approx(a, b, tol, what)
    assert(abs(a - b) <= tol, string.format("celestial.selftest: %s expected ~%.4f got %.4f", what, b, a))
  end
  -- J2000 epoch
  approx(julianDate(2000, 1, 1, 12.0), 2451545.0, 1e-6, "JD(J2000)")
  -- Sun on 2000-01-01: RA ~ 281.3 deg, Dec ~ -23.0 deg
  local jd = julianDate(2000, 1, 1, 12.0)
  local sunRA, sunDec = computeSun(jd - 2451543.5)
  approx(rev(sunRA * toDeg), 281.1, 1.5, "sunRA(2000-01-01)")
  approx(sunDec * toDeg, -23.0, 1.0, "sunDec(2000-01-01)")
  -- A point at dec = latitude culminates at the zenith (H = 0 -> alt = 90deg)
  local alt = altAz(0.0, 0.8, 0.8)
  approx(alt, pi / 2, 1e-3, "zenith culmination")
  -- The celestial pole sits at altitude = latitude, due north
  local altP, azP = altAz(1.234, pi / 2, 0.8)
  approx(altP, 0.8, 1e-6, "pole altitude == latitude")
  approx(azP, 0.0, 1e-6, "pole azimuth == north")
  approx(skyAzimuthDeg(60 * DEG, -90 * DEG, 1), 330.0, 1e-9, "sky azimuth wraps negative")
  -- Full moon (total lunar eclipse 2000-01-21): illuminated fraction ~ 1
  local fjd = julianDate(2000, 1, 21, 4.4)
  local fSunRA, fSunDec, fMs, fws, fobl = computeSun(fjd - 2451543.5)
  local fMoonRA, fMoonDec = computeMoon(fjd - 2451543.5, fMs, fws, fobl)
  local cosE = sin(fSunDec) * sin(fMoonDec) + cos(fSunDec) * cos(fMoonDec) * cos(fSunRA - fMoonRA)
  local illum = (1 - cosE) * 0.5
  assert(illum > 0.97, string.format("celestial.selftest: full-moon illumination %.3f (expected >0.97)", illum))
  -- Atmospheric refraction lifts a body ~0.5 deg at the horizon and is negligible high up.
  approx(refractionDeg(0.0), 0.48, 0.1, "refraction at horizon")
  assert(refractionDeg(45.0) < 0.02, "celestial.selftest: refraction should be tiny at 45 deg")
  -- Lunar parallax: a moon on the geocentric horizon sits ~1 deg lower for a ground observer,
  -- and ~0 at the zenith (60.27 Earth radii = mean lunar distance).
  local pAlt = topocentric(0.0, 0.0, 60.27)
  approx(pAlt * toDeg, -0.95, 0.1, "lunar parallax at horizon")
  approx(topocentric(pi / 2, 0.0, 60.27) * toDeg, 90.0, 0.01, "lunar parallax at zenith")
  -- Civil timezone + DST. Zurich (lon 8, lat 47) is UTC+1 standard, UTC+2 in EU summer time.
  assert(dstActive("eu", 2026, 7, 1) and not dstActive("eu", 2026, 1, 1), "celestial.selftest: EU DST summer/winter")
  assert(dstActive("eu", 2026, 3, 29) and not dstActive("eu", 2026, 3, 28), "celestial.selftest: EU DST starts last Sun March")
  assert(not dstActive("eu", 2026, 10, 25) and dstActive("eu", 2026, 10, 24), "celestial.selftest: EU DST ends last Sun October")
  assert(dstActive("au", 2026, 1, 1) and not dstActive("au", 2026, 7, 1), "celestial.selftest: AU DST is southern-summer")
  approx(civilOffset({ lon = 8, lat = 47, y = 2026, mo = 7, d = 1 }), 2, 1e-9, "Zurich summer UTC+2")
  approx(civilOffset({ lon = 8, lat = 47, y = 2026, mo = 1, d = 1 }), 1, 1e-9, "Zurich winter UTC+1")
  -- meteor schedule: Perseids peak in mid-August, Geminids mid-December, sporadic-only mid-March.
  local aug = meteorState(2026, 8, 12)
  assert(aug.name == "Perseids" and aug.showerFraction > 0.8, "celestial.selftest: Perseid peak not detected on Aug 12")
  assert(meteorState(2026, 12, 14).name == "Geminids", "celestial.selftest: Geminids not detected on Dec 14")
  local mar = meteorState(2026, 3, 15)
  assert(mar.showerFraction < 0.2 and mar.rate <= SPORADIC_RATE + 0.5, "celestial.selftest: mid-March should be sporadic-only")
  -- Next solar eclipse from Dallas (lat 32.78, lon -96.80) after 2024-03-01: the 2024-04-08 total eclipse.
  local ecl = findNextSolarEclipseFrom({ lat = 32.78, lon = -96.80, y = 2024, mo = 3, d = 1, time = 0.0 })
  assert(ecl and ecl.year == 2024 and ecl.month == 4 and ecl.day == 8,
    "celestial.selftest: next eclipse from Dallas should be 2024-04-08, got " ..
    (ecl and string.format("%04d-%02d-%02d", ecl.year, ecl.month, ecl.day) or "nil"))
  -- Industrial map observer (lat 29.776, lon -93.904, UTC-6/US DST) from its default 2026-06-22, walked
  -- against known solar eclipses: the 2028-01-26 partial, then the 2029-01-14 partial. Guards the search
  -- (lunation stepping + topocentric refinement) at the current ECLIPSE_MIN_MAGNITUDE threshold.
  local iw = { lat = 29.7763577, lon = -93.903862, utcOffset = -6, dstRule = "us", y = 2026, mo = 6, d = 22, time = 0.92 }
  local iecl = findNextSolarEclipseFrom(iw)
  assert(iecl and iecl.year == 2028 and iecl.month == 1 and iecl.day == 26,
    "celestial.selftest: next eclipse from Industrial should be 2028-01-26, got " ..
    (iecl and string.format("%04d-%02d-%02d", iecl.year, iecl.month, iecl.day) or "nil"))
  local iw2 = { lat = iw.lat, lon = iw.lon, utcOffset = iw.utcOffset, dstRule = iw.dstRule,
                y = iecl.year, mo = iecl.month, d = iecl.day, time = iecl.time }
  local iecl2 = findNextSolarEclipseFrom(iw2)
  assert(iecl2 and iecl2.year == 2029 and iecl2.month == 1 and iecl2.day == 14,
    "celestial.selftest: eclipse after 2028-01-26 at Industrial should be 2029-01-14, got " ..
    (iecl2 and string.format("%04d-%02d-%02d", iecl2.year, iecl2.month, iecl2.day) or "nil"))
  log("I", "celestial", "selftest passed (full-moon illum=" .. string.format("%.3f", illum) .. ")")
  return true
end

return M
