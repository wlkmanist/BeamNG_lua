local M = {}

--[[
  To run these tests:
  1. Open the GE Lua Console
  2. Run: require('testFramework/TestManager'):runTestFiles("utils")

  Or to run all tests:
  require('testFramework/TestManager'):runTestFiles()

  Example test:
  function M.testMyFeature(ctx)
    ctx:setDescription("Tests my feature")
    local result = myFeature()
    if result ~= expected then
      ctx:fail("myFeature failed: expected " .. expected .. ", got " .. result)
    end
  end
]]

-- Ensure utils is loaded
require('utils')

local GC_ARRAY_123 = {1, 2, 3}
local GC_DICT_A1 = {a = 1}
local GC_NEG_INDEX = {[-1] = 1}
local GC_EMPTY = {}
local GC_ARRAY_1 = {1}
local GC_FINDKEY_AB = {a = 1, b = 2}
local GC_FINDIDX_ABC = {"a", "b", "c"}
local GC_FINDIDX_ABB = {"a", "b", "b"}

--MARK: color things

-- Tests RGB/HSV and hex color conversion helpers.
function M.testColorConversion(ctx)
  ctx:setDescription("Tests RGB <-> HSV conversion")
  local r, g, b = 1, 0, 0
  local h, s, v = RGBtoHSV(r, g, b)
  -- Red is H=0, S=1, V=1
  -- Note: RGBtoHSV adds a small epsilon (1e-10) to denominators, so results aren't exact
  ctx:assertNear(h, 0, 0.001, "RGBtoHSV red failed (h)")
  ctx:assertNear(s, 1, 0.001, "RGBtoHSV red failed (s)")
  ctx:assertNear(v, 1, 0.001, "RGBtoHSV red failed (v)")

  local r2, g2, b2 = HSVtoRGB(h, s, v)
  ctx:assertNear(r2, r, 0.001, "HSVtoRGB roundtrip failed (r)")
  ctx:assertNear(g2, g, 0.001, "HSVtoRGB roundtrip failed (g)")
  ctx:assertNear(b2, b, 0.001, "HSVtoRGB roundtrip failed (b)")

  local h2, s2, v2 = RGBtoHSV(0.5, 0.5, 0.5)
  ctx:assertNear(s2, 0, 0.001, "RGBtoHSV gray saturation should be 0")
  local rr, gg, bb = HSVtoRGB(0.0, 0.0, 0.5)
  ctx:assertNear(rr, 0.5, 0.001, "HSVtoRGB gray failed (r)")
  ctx:assertNear(gg, 0.5, 0.001, "HSVtoRGB gray failed (g)")
  ctx:assertNear(bb, 0.5, 0.001, "HSVtoRGB gray failed (b)")

  local hb, sb, vb = RGBtoHSV(0, 0, 0)
  ctx:assertNear(hb, 0, 0.001, "RGBtoHSV black failed (h)")
  ctx:assertNear(sb, 0, 0.001, "RGBtoHSV black failed (s)")
  ctx:assertNear(vb, 0, 0.001, "RGBtoHSV black failed (v)")

  local hw, sw, vw = RGBtoHSV(1, 1, 1)
  ctx:assertNear(hw, 0, 0.001, "RGBtoHSV white failed (h)")
  ctx:assertNear(sw, 0, 0.001, "RGBtoHSV white failed (s)")
  ctx:assertNear(vw, 1, 0.001, "RGBtoHSV white failed (v)")
end

-- Tests rainbow color generation at range boundaries.
function M.testRainbowColor(ctx)
  local c = rainbowColor(10, 0) -- Red
  -- rainbowColor returns {r, g, b, a}
  ctx:assertNear(c[1], 0, 1, "rainbowColor start failed (expected Blue, r)")
  ctx:assertNear(c[2], 0, 1, "rainbowColor start failed (expected Blue, g)")
  ctx:assertNear(c[3], 255, 1, "rainbowColor start failed (expected Blue, b)")

  local c2 = rainbowColor(10, 5, 1)
  ctx:assertEqual(c2[4], 1, "rainbowColor format=1 alpha failed")
  ctx:assert(c2[1] >= 0 and c2[1] <= 1 and c2[2] >= 0 and c2[2] <= 1 and c2[3] >= 0 and c2[3] <= 1, "rainbowColor format=1 range failed")
end

-- Tests color constructors for RGBA and packed values.
function M.testColorCreation(ctx)
  ctx:setDescription("Tests color creation functions")
  local c1 = color(255, 0, 0, 255)
  local c2 = colorHex(0xFF0000, 255)
  ctx:assertEqual(c1, c2, "color vs colorHex mismatch")

  local r, g, b, a = colorGetRGBA(c1)
  ctx:assertEqual(r, 255, "colorGetRGBA r failed")
  ctx:assertEqual(g, 0, "colorGetRGBA g failed")
  ctx:assertEqual(b, 0, "colorGetRGBA b failed")
  ctx:assertEqual(a, 255, "colorGetRGBA a failed")

  local c3 = color(-1, 260, 12.9)
  r, g, b, a = colorGetRGBA(c3)
  ctx:assertEqual(r, 0, "color clamp/default alpha r failed")
  ctx:assertEqual(g, 255, "color clamp/default alpha g failed")
  ctx:assertEqual(b, 12, "color clamp/default alpha b failed")
  ctx:assertEqual(a, 255, "color clamp/default alpha a failed")

  local c4 = colorHex(0x010203)
  r, g, b, a = colorGetRGBA(c4)
  ctx:assertEqual(r, 1, "colorHex default alpha r failed")
  ctx:assertEqual(g, 2, "colorHex default alpha g failed")
  ctx:assertEqual(b, 3, "colorHex default alpha b failed")
  ctx:assertEqual(a, 255, "colorHex default alpha a failed")
end

-- Tests table-to-color conversion with nil handling.
function M.testTableToColor(ctx)
  local col = tableToColor({r=255, g=0, b=0, a=255})
  local expected = color(255, 0, 0, 255)
  ctx:assertEqual(col, expected, "tableToColor failed")
  ctx:assertEqual(tableToColor(nil), 0, "tableToColor nil failed")
end

-- Tests parseColor for hex, table input, and invalid values.
function M.testParseColor(ctx)
  ctx:setDescription("Tests parseColor with hex and table input")
  local c = parseColor("#ff0000ff")
  local expected = color(255, 0, 0, 255)
  ctx:assertEqual(c, expected, "parseColor hex failed: " .. tostring(c))

  local c2 = parseColor({r=255, g=0, b=0, a=255})
  ctx:assertEqual(c2, expected, "parseColor table failed: " .. tostring(c2))

  local c3 = parseColor(nil)
  ctx:assertEqual(c3, color(0, 0, 0, 0), "parseColor nil failed")

  ctx:assertEqual(parseColor("#ff"), nil, "parseColor short hex should be nil")

  local ok = pcall(function() parseColor("#gg0000ff") end)
  if ok then ctx:fail("parseColor malformed hex should fail") end
end

-- Tests procedural color generators return valid color values.
function M.testColorGenerators(ctx)
  ctx:setDescription("Tests procedural color generators")
  -- Just check they return numbers (colors)
  ctx:assertEqual(type(ironbowColor(0.5, 255)), "number", "ironbowColor failed")
  ctx:assertEqual(type(jetColor(0.5, 255)), "number", "jetColor failed")
  ctx:assertEqual(type(greyColor(0.5, 255)), "number", "greyColor failed")
end

--MARK: String utils

-- Tests dumps string formatting for basic argument shapes.
function M.testDumps(ctx)
  local s = dumps({a=1})
  if not string.find(s, "a = 1") then ctx:fail("dumps failed") end

  local multi = dumps(1, "x")
  if not string.find(multi, "1") or not string.find(multi, '"x"') then ctx:fail("dumps multi-arg failed: " .. tostring(multi)) end

  local empty = dumps()
  ctx:assertEqual(empty, "", "dumps empty args failed")
end

-- Tests dumps GC budgets for single-shot common call paths.
function M.testNoGarbageDumpDumpsSingleShot(ctx)
  ctx:setDescription("No-garbage: dump/dumps single-shot")
  ctx:allowGarbage(12288)

  local payload = {a = 1, b = {2, 3}}
  -- Warm up inspect/dumps internals so measured calls reflect steady-state cost.
  dumps(payload)

  ctx:resetGarbageCheckpoint()
  local s = dumps(payload)
  if not string.find(s, "a = 1") then ctx:fail("dumps table output missing a=1") end
  if not string.find(s, "2") then ctx:fail("dumps nested output missing values") end
  ctx:checkGarbage(4096, "dumps table call allocated too much garbage")

  ctx:resetGarbageCheckpoint()
  local multi = dumps(1, "x", true)
  if not string.find(multi, "1") or not string.find(multi, '"x"') then
    ctx:fail("dumps multi-arg failed: " .. tostring(multi))
  end
  ctx:checkGarbage(3072, "dumps multi call allocated too much garbage")

  ctx:resetGarbageCheckpoint()
  local empty = dumps()
  ctx:assertEqual(empty, "", "dumps empty call should return empty string")
  ctx:checkGarbage(128, "dumps empty call allocated too much garbage")
end

-- Tests left/right padding helpers.
function M.testLpadRpad(ctx)
  ctx:assertEqual(lpad("a", 3, " "), "  a", "lpad failed")
  ctx:assertEqual(rpad("a", 3, " "), "a  ", "rpad failed")
end

-- Tests whitespace trimming behavior.
function M.testTrim(ctx)
  ctx:assertEqual(trim("  hello  "), "hello", "trim failed: '  hello  ' -> '" .. tostring(trim("  hello  ")) .. "'")
  ctx:assertEqual(trim("hello"), "hello", "trim failed no spaces")
  ctx:assertEqual(trim(""), "", "trim failed empty")
  ctx:assertEqual(trim("   "), "", "trim failed only spaces")
end

-- Tests split behavior for limits and delimiter edge cases.
function M.testSplit(ctx)
  local parts = split("a,b,c", ",")
  ctx:assertEqual(#parts, 3, "split size failed")
  ctx:assertEqual(parts[2], "b", "split middle element failed")

  parts = split("a,b,c", ",", 1)
  ctx:assertEqual(#parts, 2, "split nMax size failed")
  ctx:assertEqual(parts[1], "a", "split nMax first element failed")
  ctx:assertEqual(parts[2], "b,c", "split nMax remainder failed")

  parts = split("a,,b", ",")
  ctx:assertEqual(#parts, 3, "split consecutive delimiter size failed")
  ctx:assertEqual(parts[2], "", "split consecutive delimiter middle failed")

  parts = split("", ",")
  ctx:assertEqual(#parts, 0, "split empty string failed")

  parts = split("a--b--c", "--")
  ctx:assertEqual(#parts, 3, "split multi-char delimiter size failed")
  ctx:assertEqual(parts[1], "a", "split multi-char first failed")
  ctx:assertEqual(parts[2], "b", "split multi-char middle failed")
  ctx:assertEqual(parts[3], "c", "split multi-char last failed")

  parts = split(",a,b,", ",")
  ctx:assertEqual(#parts, 4, "split edge-delimiter size failed")
  ctx:assertEqual(parts[1], "", "split edge-delimiter leading empty failed")
  ctx:assertEqual(parts[2], "a", "split edge-delimiter second failed")
  ctx:assertEqual(parts[3], "b", "split edge-delimiter third failed")
  ctx:assertEqual(parts[4], "", "split edge-delimiter trailing empty failed")
end

-- Tests string startswith/endswith helpers.
function M.testStringStartEnd(ctx)
  ctx:setDescription("Tests string startswith and endswith")
  ctx:assert(string.startswith("hello world", "hello"), "startswith failed")
  ctx:assert(not string.startswith("hello world", "world"), "startswith failed false positive")
  ctx:assert(string.endswith("hello world", "world"), "endswith failed")
  ctx:assert(not string.endswith("hello world", "hello"), "endswith failed false positive")
  ctx:assert(string.startswith("abc", ""), "startswith empty prefix failed")
  ctx:assert(string.endswith("abc", ""), "endswith empty suffix failed")
  ctx:assert(not string.startswith("ab", "abc"), "startswith longer prefix failed")
  ctx:assert(not string.endswith("ab", "abc"), "endswith longer suffix failed")
end

-- Tests string strip with explicit character classes.
function M.testStringStrip(ctx)
  ctx:setDescription("Tests string strip functions")
  ctx:assertEqual(string.stripchars("a.b.c", "."), "abc", "stripchars failed")
  ctx:assertEqual(string.rstripchars("abc.", "."), "abc", "rstripchars single char failed: " .. string.rstripchars("abc.", "."))
  ctx:assertEqual(string.stripcharsFrontBack(".abc.", "."), "abc", "stripcharsFrontBack failed")
  ctx:assertEqual(string.rstripchars("abc..", "."), "abc.", "rstripchars should strip one trailing char")
  ctx:assertEqual(string.stripchars("", "."), "", "stripchars empty string failed")
  ctx:assertEqual(string.stripcharsFrontBack("abc", "."), "abc", "stripcharsFrontBack no-op failed")
end

-- Tests string.split API variants and limits.
function M.testStringSplit(ctx)
  local parts = string.split("a b c")
  ctx:assertEqual(#parts, 3, "string.split default size failed")
  ctx:assertEqual(parts[1], "a", "string.split default first failed")
  ctx:assertEqual(parts[3], "c", "string.split default last failed")

  -- string.split uses gmatch with the pattern, so we need a pattern that matches the content
  parts = string.split("a,b,c", "[^,]+")
  ctx:assertEqual(#parts, 3, "string.split custom size failed")
  ctx:assertEqual(parts[2], "b", "string.split custom middle failed")

  parts = string.split("", "%S+")
  ctx:assertEqual(#parts, 0, "string.split empty input failed")
end

-- Tests sentence-case conversion helper.
function M.testStringSentenceCase(ctx)
  ctx:assertEqual(string.sentenceCase("helloWorld"), "Hello World", "sentenceCase failed")
  ctx:assertEqual(string.sentenceCase(""), "", "sentenceCase empty failed")
end

-- Tests deterministic string hashing outputs.
function M.testStringHash(ctx)
  local asciiBlock = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
  local longAscii = asciiBlock .. "|TAB:\t|NL:\n|" .. asciiBlock .. "|END|"

  local known = {
    test = 3897812295,
    other = 2685343290,
    [longAscii] = 3576902570,
  }

  for text, expected in pairs(known) do
    local h = stringHash(text)
    ctx:assertEqual(h, expected, "stringHash changed for '" .. text .. "': got " .. tostring(h) .. ", expected " .. tostring(expected))
  end

  local h1 = stringHash("test")
  local h2 = stringHash("test")
  ctx:assertEqual(h1, h2, "stringHash deterministic failed")
  ctx:assertEqual(type(stringHash("")), "number", "stringHash empty input failed")
end

-- Tests byte-size formatting across units and edge cases.
function M.testBytesToString(ctx)
  ctx:setDescription("Tests bytes_to_string formatting")
  local res = bytes_to_string(500)
  ctx:assertEqual(res, "500.00 B", "500 B failed: " .. tostring(res))

  res = bytes_to_string(1000)
  ctx:assertEqual(res, "1.00 KB", "1 KB failed: " .. tostring(res))

  res = bytes_to_string(1500)
  ctx:assertEqual(res, "1.50 KB", "1.5 KB failed: " .. tostring(res))

  res = bytes_to_string(1000000)
  ctx:assertEqual(res, "1.00 MB", "1 MB failed: " .. tostring(res))

  res = bytes_to_string(0)
  ctx:assertEqual(res, "0.00 B", "0 B failed: " .. tostring(res))

  res = bytes_to_string(1000000000)
  ctx:assertEqual(res, "1.00 GB", "1 GB failed: " .. tostring(res))
end

-- Tests current-time formatting helper output shape.
function M.testFormatTimeStringNow(ctx)
  local s = formatTimeStringNow("{YYYY}")
  ctx:assertEqual(#s, 4, "formatTimeStringNow year length failed")
  ctx:assert(tonumber(s) ~= nil, "formatTimeStringNow numeric year failed")
end

-- Tests ASCII graph rendering for signs and clamping.
function M.testGraphs(ctx)
  local g = graphs(5, 10)
  ctx:assertEqual(g, "[+++++     ]", "graphs failed: " .. tostring(g))

  g = graphs(-5, 10)
  ctx:assertEqual(g, "[-----     ]", "graphs negative failed: " .. tostring(g))

  g = graphs(0, 4)
  ctx:assertEqual(g, "[    ]", "graphs zero failed: " .. tostring(g))

  g = graphs(-20, 4)
  ctx:assertEqual(g, "[----]", "graphs clamp failed: " .. tostring(g))

  g = graphs(0.5, 4)
  ctx:assertEqual(g, "[    ]", "graphs fractional positive failed: " .. tostring(g))

  g = graphs(-0.5, 4)
  ctx:assertEqual(g, "[    ]", "graphs fractional negative failed: " .. tostring(g))
end

--MARK: Json

-- Tests JSON encode/decode roundtrip for plain tables.
function M.testJsonRoundtrip(ctx)
  local t = {a=1, b="test", c={true, false}}
  local json = jsonEncode(t)
  local decoded = jsonDecode(json)
  ctx:assertEqual(decoded.a, 1, "JSON roundtrip a failed")
  ctx:assertEqual(decoded.b, "test", "JSON roundtrip b failed")
  ctx:assertEqual(decoded.c[1], true, "JSON roundtrip c[1] failed")
end

-- Tests pretty JSON encoding contains formatted keys.
function M.testJsonEncodePretty(ctx)
  local t = {a=1}
  local json = jsonEncodePretty(t)
  if not string.find(json, '\n') then ctx:fail("jsonEncodePretty no newlines") end

  local p = jsonEncodePretty({pi=1.23456}, 1, 2)
  if not string.find(p, '"pi":1.23', 1, true) then ctx:fail("jsonEncodePretty numberPrecision failed: " .. tostring(p)) end
end

-- Tests JSON encoding with optional output prefix.
function M.testJsonEncodePrefix(ctx)
  local s = jsonEncodePrefix("prefix:", {a=1}, ":post")
  ctx:assert(string.startswith(s, "prefix:{"), "jsonEncodePrefix prefix failed: " .. tostring(s))
  ctx:assert(string.endswith(s, "}:post"), "jsonEncodePrefix postfix failed: " .. tostring(s))
end

-- Tests encodePretty->decode roundtrip stability.
function M.testJsonEncodePrettyDecodeRoundtrip(ctx)
  local src = {
    a = 1,
    b = "test",
    c = {true, false, 3},
    d = {x = 2, y = "z"},
  }
  local pretty = jsonEncodePretty(src)
  local decoded = jsonDecode(pretty, "pretty->decode roundtrip")

  ctx:assert(decoded ~= nil, "jsonEncodePretty->jsonDecode returned nil")
  ctx:assertEqual(decoded.a, 1, "pretty->decode field a failed")
  ctx:assertEqual(decoded.b, "test", "pretty->decode field b failed")
  ctx:assertEqual(decoded.c[1], true, "pretty->decode array[1] failed")
  ctx:assertEqual(decoded.c[2], false, "pretty->decode array[2] failed")
  ctx:assertEqual(decoded.c[3], 3, "pretty->decode array[3] failed")
  ctx:assertEqual(decoded.d.x, 2, "pretty->decode nested object x failed")
  ctx:assertEqual(decoded.d.y, "z", "pretty->decode nested object y failed")
end

-- Tests decode->encodePretty roundtrip stability.
function M.testJsonDecodeEncodePrettyRoundtrip(ctx)
  local raw = '{"name":"beam","count":42,"arr":[1,2,3],"obj":{"k":"v","f":false}}'
  local d1 = jsonDecode(raw, "decode->pretty roundtrip input")
  ctx:assert(d1 ~= nil, "jsonDecode raw input failed")

  local pretty = jsonEncodePretty(d1)
  if not string.find(pretty, '\n') then ctx:fail("decode->pretty no newlines") end

  local d2 = jsonDecode(pretty, "decode->pretty->decode roundtrip")
  ctx:assert(d2 ~= nil, "decode->pretty->decode failed")

  ctx:assertEqual(d2.name, "beam", "decode->pretty roundtrip name failed")
  ctx:assertEqual(d2.count, 42, "decode->pretty roundtrip count failed")
  ctx:assertEqual(d2.arr[1], 1, "decode->pretty roundtrip array[1] failed")
  ctx:assertEqual(d2.arr[2], 2, "decode->pretty roundtrip array[2] failed")
  ctx:assertEqual(d2.arr[3], 3, "decode->pretty roundtrip array[3] failed")
  ctx:assertEqual(d2.obj.k, "v", "decode->pretty roundtrip nested object k failed")
  ctx:assertEqual(d2.obj.f, false, "decode->pretty roundtrip nested object f failed")
end

-- Tests JSON handling for BeamNG vec3/quat cdata values.
function M.testJsonCdataRoundtrip(ctx)
  local payload = {
    pos = vec3(1.5, 2.5, 3.5),
    rot = quat(1, 2, 3, 4),
  }
  local encoded = jsonEncode(payload)
  local decoded = jsonDecode(encoded, "cdata json roundtrip")

  ctx:assert(decoded ~= nil, "cdata json roundtrip decode returned nil")
  ctx:assertEqual(type(decoded.pos), "table", "vec3 should decode into table")
  ctx:assertEqual(type(decoded.rot), "table", "quat should decode into table")

  ctx:assertNear(decoded.pos.x, 1.5, 1e-6, "vec3 decoded x failed")
  ctx:assertNear(decoded.pos.y, 2.5, 1e-6, "vec3 decoded y failed")
  ctx:assertNear(decoded.pos.z, 3.5, 1e-6, "vec3 decoded z failed")

  ctx:assertNear(decoded.rot.x, 1, 1e-6, "quat decoded x failed")
  ctx:assertNear(decoded.rot.y, 2, 1e-6, "quat decoded y failed")
  ctx:assertNear(decoded.rot.z, 3, 1e-6, "quat decoded z failed")
  ctx:assertNear(decoded.rot.w, 4, 1e-6, "quat decoded w failed")
end

-- Tests invalid JSON decode behavior and logging suppression.
function M.testJsonDecodeInvalid(ctx)
  local oldLog = log
  log = function(level, tag, msg)
    if tag == "jsonDecode" then
      return
    end
    return oldLog(level, tag, msg)
  end

  local ok, err = pcall(function()
    ctx:assertEqual(jsonDecode("{bad", "invalid json test"), nil, "jsonDecode invalid should return nil")
    local emptyDecoded = jsonDecode("", "empty json test")
    local emptyOk = emptyDecoded == nil or (type(emptyDecoded) == "table" and next(emptyDecoded) == nil)
    ctx:assert(emptyOk, "jsonDecode empty should be nil or empty table")
  end)

  log = oldLog
  if not ok then
    error(err)
  end
end

--MARK: Table utils

-- Tests set-like table helpers for membership and updates.
function M.testSetOperations(ctx)
  local s1 = {1, 2, 3}
  local s2 = {3, 4, 5}

  if not setEqual({1, 2}, {2, 1}) then ctx:fail("setEqual failed") end
  if setEqual({1, 2}, {1, 2, 3}) then ctx:fail("setEqual false positive failed") end

  local u = shallowcopy(s1)
  setUnion(u, s2)
  ctx:assertEqual(#u, 5, "setUnion size failed: " .. #u)
  if not tableContains(u, 4) then ctx:fail("setUnion missing element") end

  local d = shallowcopy(s1)
  setDifference(d, {2})
  ctx:assertEqual(#d, 2, "setDifference size failed: " .. #d)
  if tableContains(d, 2) then ctx:fail("setDifference failed to remove") end

  local u2 = setUnion({}, {})
  ctx:assertEqual(#u2, 0, "setUnion empty failed")

  local u3 = setUnion({1}, {1, 1, 2})
  ctx:assertEqual(#u3, 2, "setUnion duplicate src size failed")
  ctx:assert(tableContains(u3, 1) and tableContains(u3, 2), "setUnion duplicate src contents failed")

  local d2 = setDifference({1, 2}, {})
  ctx:assertEqual(#d2, 2, "setDifference empty src size failed")
  ctx:assert(tableContains(d2, 1) and tableContains(d2, 2), "setDifference empty src contents failed")

  local d3 = setDifference({1, 2, 3}, {1, 2, 3})
  ctx:assertEqual(#d3, 0, "setDifference remove all failed")
end

-- Tests common table utility helpers.
function M.testTableHelpers(ctx)
  ctx:setDescription("Tests tableSize, tableContains, tableKeys, tableIsDict")
  local t = {a=1, b=2}
  ctx:assertEqual(tableSize(t), 2, "tableSize failed: " .. tostring(tableSize(t)))
  ctx:assertEqual(tableSize("x"), 0, "tableSize non-table failed")
  ctx:assert(tableContains(t, 1), "tableContains failed")
  ctx:assert(not tableContains(t, 3), "tableContains false positive failed")

  local keys = tableKeys(t)
  ctx:assertEqual(#keys, 2, "tableKeys size failed")

  local target = {}
  local keys2 = tableKeys(t, target)
  ctx:assertEqual(keys2, target, "tableKeys target reuse failed")
  ctx:assertEqual(#keys2, 2, "tableKeys target size failed")

  local t2 = {1, 2, 3}
  ctx:assert(not tableIsDict(t2), "tableIsDict array failed")
  ctx:assertEqual(tableIsDict(t), true, "tableIsDict dict failed")
end

-- Tests tableIsArray classification.
function M.testTableIsArray(ctx)
  ctx:allowGarbage(0)
  ctx:resetGarbageCheckpoint()
  ctx:assertEqual(tableIsArraySlow(GC_ARRAY_123), true, "tableIsArraySlow true failed")
  ctx:assert(not tableIsArraySlow(GC_DICT_A1), "tableIsArraySlow false failed")
  ctx:assert(not tableIsArraySlow(GC_NEG_INDEX), "tableIsArraySlow negative index failed")
  ctx:assertEqual(tableIsArraySlow(GC_EMPTY), true, "tableIsArraySlow empty table failed")
  ctx:checkGarbage(0, "tableIsArraySlow allocated garbage")
end

-- Tests table emptiness checks.
function M.testTableIsEmpty(ctx)
  ctx:allowGarbage(0)
  ctx:resetGarbageCheckpoint()
  ctx:assertEqual(tableIsEmpty(GC_EMPTY), true, "tableIsEmpty true failed")
  ctx:assert(not tableIsEmpty(GC_ARRAY_1), "tableIsEmpty false failed")
  ctx:assertEqual(tableIsEmpty(nil), true, "tableIsEmpty nil failed")
  ctx:checkGarbage(0, "tableIsEmpty allocated garbage")
end

-- Tests sorted key extraction from tables.
function M.testTableKeysSorted(ctx)
  local t = {b=2, a=1, c=3}
  local keys = tableKeysSorted(t)
  ctx:assertEqual(keys[1], "a", "tableKeysSorted key1 failed")
  ctx:assertEqual(keys[2], "b", "tableKeysSorted key2 failed")
  ctx:assertEqual(keys[3], "c", "tableKeysSorted key3 failed")

  local target = {}
  local keys2 = tableKeysSorted(t, target)
  ctx:assertEqual(keys2, target, "tableKeysSorted target reuse failed")
  ctx:assertEqual(keys2[1], "a", "tableKeysSorted target first key failed")
end

-- Tests conversion of values array into lookup dictionary.
function M.testTableValuesAsLookupDict(ctx)
  local t = {"a", "b"}
  local lookup = tableValuesAsLookupDict(t)
  ctx:assert(lookup.a and lookup.b, "tableValuesAsLookupDict failed")

  local target = {keep = 1}
  local lookup2 = tableValuesAsLookupDict(t, target)
  ctx:assertEqual(lookup2, target, "tableValuesAsLookupDict target reuse failed")
  ctx:assertEqual(lookup2.keep, 1, "tableValuesAsLookupDict keep value failed")
  ctx:assert(lookup2.a and lookup2.b, "tableValuesAsLookupDict content failed")
end

-- Tests array concatenation behavior.
function M.testArrayConcat(ctx)
  local a1 = {1, 2}
  local a2 = {3, 4}
  arrayConcat(a1, a2)
  ctx:assertEqual(#a1, 4, "arrayConcat size failed")
  ctx:assertEqual(a1[3], 3, "arrayConcat value failed")

  local a3 = {10}
  local a4 = {[0] = 20, [1] = 30}
  arrayConcat(a3, a4)
  ctx:assertEqual(#a3, 3, "arrayConcat [0]-index size failed")
  ctx:assertEqual(a3[2], 20, "arrayConcat [0]-index second failed")
  ctx:assertEqual(a3[3], 30, "arrayConcat [0]-index third failed")
end

-- Tests shallow table merge behavior.
function M.testTableMerge(ctx)
  local t1 = {a=1}
  local t2 = {b=2}
  tableMerge(t1, t2)
  ctx:assertEqual(t1.a, 1, "tableMerge a failed")
  ctx:assertEqual(t1.b, 2, "tableMerge b failed")
end

-- Tests recursive table merge semantics.
function M.testTableRecursive(ctx)
  local t1 = {a={x=1}, b=2}
  local t2 = {a={y=2}, c=3}
  tableMergeRecursive(t1, t2)
  ctx:assertEqual(t1.a.x, 1, "tableMergeRecursive a.x failed")
  ctx:assertEqual(t1.a.y, 2, "tableMergeRecursive a.y failed")
  ctx:assertEqual(t1.b, 2, "tableMergeRecursive b failed")
  ctx:assertEqual(t1.c, 3, "tableMergeRecursive c failed")

  local t3 = {a = 1}
  local t4 = {a = {z = 9}}
  tableMergeRecursive(t3, t4)
  ctx:assertEqual(type(t3.a), "table", "tableMergeRecursive number->table type overwrite failed")
  ctx:assertEqual(t3.a.z, 9, "tableMergeRecursive number->table value overwrite failed")

  local t5 = {a = {z = 1}}
  local t6 = {a = 42}
  tableMergeRecursive(t5, t6)
  ctx:assertEqual(t5.a, 42, "tableMergeRecursive table->number overwrite failed")
end

-- Tests recursive merge behavior with array values.
function M.testTableRecursiveArray(ctx)
  local t1 = {a={1, 2}}
  local t2 = {a={3, 4}}
  tableMergeRecursiveArray(t1, t2)
  ctx:assertEqual(#t1.a, 4, "tableMergeRecursiveArray size failed")
  ctx:assertEqual(t1.a[3], 3, "tableMergeRecursiveArray appended value failed")

  local t3 = {obj={x=1}, arr={1}}
  local t4 = {obj={y=2}, arr={2, 3}, newObj={k=4}}
  tableMergeRecursiveArray(t3, t4)
  ctx:assertEqual(t3.obj.x, 1, "tableMergeRecursiveArray dict merge x failed")
  ctx:assertEqual(t3.obj.y, 2, "tableMergeRecursiveArray dict merge y failed")
  ctx:assertEqual(#t3.arr, 3, "tableMergeRecursiveArray array concat size failed")
  ctx:assertEqual(t3.arr[2], 2, "tableMergeRecursiveArray array concat second failed")
  ctx:assertEqual(t3.arr[3], 3, "tableMergeRecursiveArray array concat third failed")
  ctx:assertEqual(t3.newObj.k, 4, "tableMergeRecursiveArray new table copy failed")
end

-- Tests read-only table protection behavior.
function M.testTableReadOnly(ctx)
  local t = {a=1}
  local ro = tableReadOnly(t)
  ctx:assertEqual(ro.a, 1, "tableReadOnly read failed")
  local ok, err = pcall(function() ro.a = 2 end)
  ctx:assert(not ok, "tableReadOnly write should fail")
end

-- Tests C-side table size helper wrapper.
function M.testTableSizeC(ctx)
  local t = {[0]=0, [1]=1}
  ctx:assertEqual(tableSizeC(t), 2, "tableSizeC failed")
  ctx:assertEqual(tableSizeC({1, 2}), 2, "tableSizeC without zero-index failed")
end

-- Tests C-side table end helper wrapper.
function M.testTableEndC(ctx)
  local t = {[0]=0, [1]=1}
  ctx:assertEqual(tableEndC(t), 2, "tableEndC failed")
  ctx:assertEqual(tableEndC({}), 0, "tableEndC empty failed")
  ctx:assertEqual(tableEndC({1}), 2, "tableEndC no zero-index failed")
end

-- Tests C-side table insert helper wrapper.
function M.testTableInsertC(ctx)
  local t = {}
  tableInsertC(t, 1) -- index 0
  tableInsertC(t, 2) -- index 1
  tableInsertC(t, 3) -- index 2
  ctx:assertEqual(t[0], 1, "tableInsertC [0] failed")
  ctx:assertEqual(t[1], 2, "tableInsertC [1] failed")
  ctx:assertEqual(t[2], 3, "tableInsertC [2] failed")
end

-- Tests finding a key by value in a table.
function M.testTableFindKey(ctx)
  ctx:allowGarbage(0)
  ctx:resetGarbageCheckpoint()
  ctx:assertEqual(tableFindKey(GC_FINDKEY_AB, 2), "b", "tableFindKey failed")
  ctx:assertEqual(tableFindKey(GC_FINDKEY_AB, 3), nil, "tableFindKey not-found failed")
  ctx:checkGarbage(0, "tableFindKey allocated garbage")
end

-- Tests case-insensitive table value membership.
function M.testTableContainsCaseInsensitive(ctx)
  local t = {"AbC"}
  ctx:assert(tableContainsCaseInsensitive(t, "abc"), "tableContainsCaseInsensitive failed")
  ctx:assert(not tableContainsCaseInsensitive(t, "xyz"), "tableContainsCaseInsensitive false-positive failed")
end

-- Tests array value index lookup helper.
function M.testArrayFindValueIndex(ctx)
  ctx:allowGarbage(0)
  ctx:resetGarbageCheckpoint()
  ctx:assertEqual(arrayFindValueIndex(GC_FINDIDX_ABC, "b"), 2, "arrayFindValueIndex failed")
  ctx:assertEqual(arrayFindValueIndex(GC_FINDIDX_ABC, "x"), false, "arrayFindValueIndex not-found failed")
  ctx:assertEqual(arrayFindValueIndex(GC_FINDIDX_ABB, "b"), 2, "arrayFindValueIndex should return first match")
  ctx:checkGarbage(0, "arrayFindValueIndex allocated garbage")
end

-- Tests array shuffle preserves members and size.
function M.testArrayShuffle(ctx)
  local t = {1, 2, 3, 4, 5}
  local original = shallowcopy(t)
  arrayShuffle(t)
  ctx:assertEqual(#t, 5, "arrayShuffle size changed")
  -- Probability of not shuffling is low but possible, so maybe just check elements exist?
  local lookup = tableValuesAsLookupDict(t)
  for _, v in ipairs(original) do
    ctx:assert(lookup[v], "arrayShuffle lost element")
  end

  local empty = {}
  arrayShuffle(empty)
  ctx:assertEqual(#empty, 0, "arrayShuffle empty failed")

  local one = {9}
  arrayShuffle(one)
  ctx:assertEqual(#one, 1, "arrayShuffle single size failed")
  ctx:assertEqual(one[1], 9, "arrayShuffle single value failed")
end

-- Tests array reverse helper.
function M.testArrayReverse(ctx)
  local t = {1, 2, 3}
  arrayReverse(t)
  ctx:assertEqual(t[1], 3, "arrayReverse first failed")
  ctx:assertEqual(t[3], 1, "arrayReverse last failed")

  local t2 = {1, 2, 3, 4}
  arrayReverse(t2)
  ctx:assertEqual(t2[1], 4, "arrayReverse even first failed")
  ctx:assertEqual(t2[2], 3, "arrayReverse even second failed")
  ctx:assertEqual(t2[3], 2, "arrayReverse even third failed")
  ctx:assertEqual(t2[4], 1, "arrayReverse even fourth failed")
end

-- Tests recursive table depth calculation.
function M.testTableDepth(ctx)
  local t = {a={b={c=1}}}
  ctx:assertEqual(tableDepth(t), 3, "tableDepth failed: " .. tableDepth(t))

  ctx:assertEqual(tableDepth(123), 0, "tableDepth non-table failed")

  local keyTbl = {k=1}
  local t2 = {}
  t2[keyTbl] = {a=1}
  ctx:assertEqual(tableDepth(t2), 2, "tableDepth table key/value failed")
end

-- Tests round-robin key selection helper.
function M.testTableRoundRobinKey(ctx)
  local t = {a=1, b=2}
  local k1 = tableRoundRobinKey(t, nil)
  local k2 = tableRoundRobinKey(t, k1)
  local k3 = tableRoundRobinKey(t, k2)
  ctx:assert(k1 ~= k2, "tableRoundRobinKey stuck")
  ctx:assertEqual(k3, k1, "tableRoundRobinKey didn't loop")

  local kInvalid = tableRoundRobinKey(t, "missing")
  ctx:assert(kInvalid ~= nil, "tableRoundRobinKey invalid key failed")

  local kEmpty = tableRoundRobinKey({}, nil)
  ctx:assertEqual(kEmpty, nil, "tableRoundRobinKey empty table failed")
end

-- Tests shallow copy preserves first-level references.
function M.testShallowCopy(ctx)
  local t = {a=1, b={c=2}}
  local copy = shallowcopy(t)
  ctx:assertEqual(copy.a, 1, "shallowcopy failed copy")
  ctx:assertEqual(copy.b, t.b, "shallowcopy should share reference")
  ctx:assertEqual(shallowcopy(123), 123, "shallowcopy non-table failed")
end

-- Tests deep copy behavior including shared-reference diamonds.
function M.testDeepCopy(ctx)
  local t = {a=1, b={c=2}}
  local copy = deepcopy(t)
  ctx:assertEqual(copy.b.c, 2, "deepcopy value failed")

  copy.b.c = 3
  ctx:assertEqual(t.b.c, 2, "deepcopy independence failed")

  ctx:assertEqual(copy.a, 1, "deepcopy top level failed")
  ctx:assertEqual(deepcopy("x"), "x", "deepcopy non-table failed")

  local cyc = {a=1}
  cyc.self = cyc
  local cycCopy = deepcopy(cyc)
  ctx:assert(cycCopy ~= cyc, "deepcopy circular should create new table")
  ctx:assertEqual(cycCopy.self, cycCopy, "deepcopy circular self-link failed")

  local d = {id = "shared"}
  local src = {b = {ref = d}, c = {ref = d}}
  local srcCopy = deepcopy(src)
  ctx:assert(srcCopy ~= src, "deepcopy diamond root copy failed")
  ctx:assert(srcCopy.b ~= src.b and srcCopy.c ~= src.c, "deepcopy diamond branch copy failed")
  ctx:assertEqual(srcCopy.b.ref, srcCopy.c.ref, "deepcopy diamond shared ref not preserved")
  ctx:assert(srcCopy.b.ref ~= d, "deepcopy diamond should not reuse source node")
end

-- Tests table datatype validation helper.
function M.testCheckTableDataTypes(ctx)
  local t = {"a", 1}
  local ok, err = checkTableDataTypes(t, {"string", "number"})
  ctx:assertEqual(ok, true, "checkTableDataTypes valid failed")

  ok, err = checkTableDataTypes(t, {"number", "number"})
  ctx:assert(not ok, "checkTableDataTypes invalid passed")

  ok, err = checkTableDataTypes({"a"}, {"string", "optional:number"})
  ctx:assertEqual(ok, true, "checkTableDataTypes optional failed")

  ok, err = checkTableDataTypes({"a", 1, true}, {"string", "number"})
  ctx:assert(not ok, "checkTableDataTypes count mismatch passed")

  ok, err = checkTableDataTypes({"a", false}, {"string", "optional:number"})
  ctx:assert(not ok, "checkTableDataTypes optional wrong type passed")

  ok, err = checkTableDataTypes({"a"}, {"string", "number"})
  ctx:assert(not ok, "checkTableDataTypes missing required param passed")
end

--MARK: path utils

-- Tests path and level-name parsing helpers.
function M.testPathUtils(ctx)
  ctx:assertEqual(path.dirname("/a/b/c.txt"), "/a/b/", "path.dirname failed")
  ctx:assertEqual(path.dirname("file.txt"), ".", "path.dirname file failed")
  ctx:assertEqual(path.dirname("/"), "/", "path.dirname root failed")

  local dir, file, ext = path.split("/a/b/c.txt")
  ctx:assertEqual(dir, "/a/b/", "path.split dir failed")
  ctx:assertEqual(file, "c.txt", "path.split file failed")
  ctx:assertEqual(ext, "txt", "path.split ext failed")

  local dir2, file2, ext2 = path.splitWithoutExt("/a/b/c.txt")
  ctx:assertEqual(dir2, "/a/b/", "path.splitWithoutExt dir failed")
  ctx:assertEqual(file2, "c", "path.splitWithoutExt file failed")
  ctx:assertEqual(ext2, "txt", "path.splitWithoutExt ext failed")

  local dir3, file3, ext3 = path.split("file")
  ctx:assertEqual(dir3, nil, "path.split no-ext dir failed")
  ctx:assertEqual(file3, "file", "path.split no-ext file failed")
  ctx:assertEqual(ext3, "", "path.split no-ext ext failed")

  local dir4, file4, ext4 = path.split("archive.tar.gz", true)
  ctx:assertEqual(dir4, nil, "path.split composite dir failed")
  ctx:assertEqual(file4, "archive.tar.gz", "path.split composite file failed")
  ctx:assertEqual(ext4, "tar.gz", "path.split composite ext failed")

  local level, rest = path.levelFromPath("/levels/smallgrid/main.level.json")
  ctx:assertEqual(level, "smallgrid", "path.levelFromPath level failed")
  ctx:assertEqual(rest, "/main.level.json", "path.levelFromPath rest failed")

  local noLevel = path.levelFromPath("/vehicles/car.jbeam")
  ctx:assertEqual(noLevel, nil, "path.levelFromPath non-level should be nil")

  local dir5, file5, ext5 = path.split("/a/b/file")
  ctx:assertEqual(dir5, "/a/b/", "path.split no extension dir failed")
  ctx:assertEqual(file5, "file", "path.split no extension file failed")
  ctx:assertEqual(ext5, "", "path.split no extension ext failed")
end

--MARK: Serialization

-- Tests serialization and deserialization helpers.
function M.testSerialization(ctx)
  local t = {a=1, b="test", c={d=true}}
  local s = serialize(t)
  local d = deserialize(s)

  ctx:assertEqual(d.a, 1, "serialization int failed")
  ctx:assertEqual(d.b, "test", "serialization string failed")
  ctx:assertEqual(d.c.d, true, "serialization nested bool failed")

  local ok = pcall(function() deserialize("{") end)
  ctx:assert(not ok, "deserialize malformed input should fail")
end

-- Tests INI parsing and malformed line handling.
function M.testLoadIni(ctx)
  local tmp = "/temp/utils_test_temp.ini"
  local f = io.open(tmp, "w")
  if not f then
    ctx:fail("testLoadIni: unable to create temp file")
    return
  end
  f:write("# comment\n")
  f:write("; comment2\n")
  f:write("/ comment3\n")
  f:write("num = 123\n")
  f:write("flag = true\n")
  f:write("name = hello\n")
  f:write("badline\n")
  f:close()

  local oldLog = log
  log = function(level, tag, msg)
    if type(msg) == "string" and msg:find("Unable to parse INI line:", 1, true) then
      return
    end
    return oldLog(level, tag, msg)
  end

  local d = loadIni(tmp)
  log = oldLog

  ctx:assert(d ~= nil, "loadIni failed to read temp file")
  ctx:assertEqual(d.num, 123, "loadIni number parsing failed: " .. tostring(d.num))
  ctx:assertEqual(d.flag, true, "loadIni bool parsing failed: " .. tostring(d.flag))
  ctx:assertEqual(d.name, "hello", "loadIni string parsing failed: " .. tostring(d.name))
  ctx:assertEqual(d.badline, nil, "loadIni malformed line should not parse")

  ctx:assertEqual(loadIni("/temp/utils_test_missing_file.ini"), nil, "loadIni missing file should return nil")
end

--MARK: Other

-- Tests nested table flattening behavior.
function M.testFlattenTable(ctx)
  local t = { a = { x = 1 } }
  t.b = t.a
  local flat = flattenTable(t)
  ctx:assert(type(flat.a) == "string" or type(flat.b) == "string", "flattenTable should encode shared references")

  unflattenTable(flat)
  ctx:assertEqual(type(flat.a), "table", "unflattenTable should restore table references")
  ctx:assertEqual(flat.a, flat.b, "unflattenTable should restore shared reference identity")
end

-- Tests deterministic iteration order via sortedPairs.
function M.testSortedPairs(ctx)
  local t = {b=2, a=1, c=3}
  local keys = {}
  for k, v in sortedPairs(t) do
    table.insert(keys, k)
  end
  ctx:assertEqual(keys[1], "a", "sortedPairs key[1] failed")
  ctx:assertEqual(keys[2], "b", "sortedPairs key[2] failed")
  ctx:assertEqual(keys[3], "c", "sortedPairs key[3] failed")
end

-- Tests shuffledPairs yields each pair exactly once.
function M.testShuffledPairs(ctx)
  local t = {a=1, b=2, c=3, d=4, e=5}
  local keys = {}
  for k, v in shuffledPairs(t) do
    table.insert(keys, k)
  end
  ctx:assertEqual(#keys, 5, "shuffledPairs missing keys")
end

return M