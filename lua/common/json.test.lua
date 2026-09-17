local M = {}

local json = require('json')
local buffer = require('string.buffer')

local function expectDecodeFail(ctx, text, message)
  local ok = pcall(function()
    json.decode(text)
  end)
  ctx:assertEqual(ok, false, message)
end

-- Tests decode(nil) returns nil.
function M.testJsonDecodeNil(ctx)
  ctx:assertEqual(json.decode(nil), nil, "json.decode(nil) should return nil")
end

-- Tests decoding a plain JSON object string.
function M.testJsonDecodeObjectString(ctx)
  local obj = json.decode('{"a":1,"b":"x","ok":true}')
  ctx:assertEqual(type(obj), "table", "decoded object should be table")
  ctx:assertEqual(obj.a, 1, "decoded object field a mismatch")
  ctx:assertEqual(obj.b, "x", "decoded object field b mismatch")
  ctx:assertEqual(obj.ok, true, "decoded object field ok mismatch")
end

-- Tests decoding a plain JSON array string.
function M.testJsonDecodeArrayString(ctx)
  local arr = json.decode('[1,2,3]')
  ctx:assertEqual(type(arr), "table", "decoded array should be table")
  ctx:assertEqual(#arr, 3, "decoded array length mismatch")
  ctx:assertEqual(arr[1], 1, "decoded array first element mismatch")
  ctx:assertEqual(arr[3], 3, "decoded array third element mismatch")
end

-- Tests decode path that takes a string.buffer instance.
function M.testJsonDecodeFromBuffer(ctx)
  local b = buffer.new()
  b:set('{"v":42,"name":"buf"}')
  local obj = json.decode(b)
  ctx:assertEqual(type(obj), "table", "buffer decode should return table")
  ctx:assertEqual(obj.v, 42, "buffer decode number mismatch")
  ctx:assertEqual(obj.name, "buf", "buffer decode string mismatch")
end

-- Tests SJSON-like features expected by BeamNG parser.
function M.testJsonDecodeSjsonFeatures(ctx)
  local txt = [[
  // header comment
  {
    a = 1,
    b: "x",
    c = [1, 2, 3,],
  }
  ]]
  local obj = json.decode(txt)
  ctx:assertEqual(type(obj), "table", "SJSON decode should return table")
  ctx:assertEqual(obj.a, 1, "SJSON decode key a mismatch")
  ctx:assertEqual(obj.b, "x", "SJSON decode key b mismatch")
  ctx:assertEqual(#obj.c, 3, "SJSON decode array length mismatch")
  ctx:assertEqual(obj.c[3], 3, "SJSON decode array value mismatch")
end

-- Tests permissive parsing where commas may be omitted.
function M.testJsonDecodeMissingCommasAccepted(ctx)
  local obj = json.decode('{"a":1 "b":2}')
  ctx:assertEqual(obj.a, 1, "missing-comma object parse key a mismatch")
  ctx:assertEqual(obj.b, 2, "missing-comma object parse key b mismatch")

  local arr = json.decode('[1 2 3]')
  ctx:assertEqual(#arr, 3, "missing-comma array parse length mismatch")
  ctx:assertEqual(arr[2], 2, "missing-comma array parse value mismatch")
end

-- Tests top-level key/value format without surrounding braces.
function M.testJsonDecodeTopLevelAssignments(ctx)
  local obj = json.decode('a=1 b=2 c="x"')
  ctx:assertEqual(type(obj), "table", "top-level assignments should decode to table")
  ctx:assertEqual(obj.a, 1, "top-level assignments key a mismatch")
  ctx:assertEqual(obj.b, 2, "top-level assignments key b mismatch")
  ctx:assertEqual(obj.c, "x", "top-level assignments key c mismatch")
end

-- Tests comment handling in both object and array contexts.
function M.testJsonDecodeComments(ctx)
  local txt = [[
  {
    a = 1, // inline
    /* block */
    b = 2
  }
  ]]
  local obj = json.decode(txt)
  ctx:assertEqual(obj.a, 1, "commented object key a mismatch")
  ctx:assertEqual(obj.b, 2, "commented object key b mismatch")

  local arr = json.decode('[1, /*m*/ 2, // n\n 3]')
  ctx:assertEqual(#arr, 3, "commented array length mismatch")
  ctx:assertEqual(arr[3], 3, "commented array value mismatch")
end

-- Tests string escape decoding.
function M.testJsonDecodeEscapes(ctx)
  local obj = json.decode('{"s":"a\\n\\t\\\\"}')
  ctx:assertEqual(type(obj.s), "string", "escaped string should decode as string")
  ctx:assert(obj.s:find("\n", 1, true) ~= nil, "escaped newline not decoded")
  ctx:assert(obj.s:find("\t", 1, true) ~= nil, "escaped tab not decoded")
  ctx:assert(obj.s:sub(-1) == "\\", "escaped backslash not decoded")
end

-- Tests number parsing variants supported by the parser.
function M.testJsonDecodeNumbers(ctx)
  local obj = json.decode('{"a":1.5,"b":1e3,"c":+7,"d":-2}')
  ctx:assertNear(obj.a, 1.5, 1e-9, "float parse mismatch")
  ctx:assertNear(obj.b, 1000, 1e-9, "exponent parse mismatch")
  ctx:assertEqual(obj.c, 7, "plus-prefix number parse mismatch")
  ctx:assertEqual(obj.d, -2, "negative number parse mismatch")
end

-- Tests Infinity spellings accepted by SJSON parser.
function M.testJsonDecodeInfinityTokens(ctx)
  local obj = json.decode('{"a":Infinity,"b":-Infinity,"c":1#INF00}')
  ctx:assertEqual(obj.a, math.huge, "Infinity parse mismatch")
  ctx:assertEqual(obj.b, -math.huge, "-Infinity parse mismatch")
  ctx:assertEqual(obj.c, math.huge, "1#INF00 parse mismatch")
end

-- Tests malformed number/Infinity tokens rejected by parser rules.
function M.testJsonDecodeInvalidNumberTokens(ctx)
  local cases = {
    {text = '{"x":+Infinity}', msg = "plus Infinity token should fail"},
    {text = '{"x":1#INF01}', msg = "invalid #INF token should fail"},
    {text = '{"x":-1#INF01}', msg = "invalid negative #INF token should fail"},
    {text = '{"x":1e+}', msg = "invalid exponent token should fail"},
    {text = '{"x":-}', msg = "bare minus token should fail"},
    {text = '{"x":+}', msg = "bare plus token should fail"},
  }

  for _, c in ipairs(cases) do
    expectDecodeFail(ctx, c.text, c.msg)
  end
end

-- Tests encode/decode behavior for BeamNG special cdata-like types.
function M.testJsonEncodeDecodeVec3Quat(ctx)
  local payload = {
    pos = vec3(1.5, 2.5, 3.5),
    rot = quat(1, 2, 3, 4),
  }
  local encoded = json.encode(payload)
  local decoded = json.decode(encoded)

  ctx:assertEqual(type(decoded.pos), "table", "vec3 should decode into table")
  ctx:assertEqual(type(decoded.rot), "table", "quat should decode into table")

  ctx:assertNear(decoded.pos.x, 1.5, 1e-6, "vec3 decoded x mismatch")
  ctx:assertNear(decoded.pos.y, 2.5, 1e-6, "vec3 decoded y mismatch")
  ctx:assertNear(decoded.pos.z, 3.5, 1e-6, "vec3 decoded z mismatch")

  ctx:assertNear(decoded.rot.x, 1, 1e-6, "quat decoded x mismatch")
  ctx:assertNear(decoded.rot.y, 2, 1e-6, "quat decoded y mismatch")
  ctx:assertNear(decoded.rot.z, 3, 1e-6, "quat decoded z mismatch")
  ctx:assertNear(decoded.rot.w, 4, 1e-6, "quat decoded w mismatch")
end

-- Tests encode/decode roundtrip for nested values.
function M.testJsonEncodeDecodeRoundtrip(ctx)
  local payload = {
    n = 123,
    s = "hello",
    t = true,
    arr = {1, 2, 3},
    obj = {x = 1, y = "z"},
  }
  local encoded = json.encode(payload)
  ctx:assertEqual(type(encoded), "string", "json.encode should return string")
  local decoded = json.decode(encoded)
  ctx:assertEqual(decoded.n, payload.n, "roundtrip number mismatch")
  ctx:assertEqual(decoded.s, payload.s, "roundtrip string mismatch")
  ctx:assertEqual(decoded.t, payload.t, "roundtrip bool mismatch")
  ctx:assertEqual(decoded.arr[2], payload.arr[2], "roundtrip array mismatch")
  ctx:assertEqual(decoded.obj.y, payload.obj.y, "roundtrip nested object mismatch")
end

-- Tests invalid text returns an error via pcall.
function M.testJsonDecodeInvalidString(ctx)
  local ok = pcall(function()
    json.decode("{bad")
  end)
  ctx:assertEqual(ok, false, "invalid json should raise an error")
end

-- Tests invalid input type raises an error.
function M.testJsonDecodeInvalidInputType(ctx)
  local ok = pcall(function()
    json.decode(123)
  end)
  ctx:assertEqual(ok, false, "json.decode(number) should raise an error")
end

-- Tests malformed JSON/SJSON inputs fail decoding.
function M.testJsonDecodeMalformedCases(ctx)
  local cases = {
    {text = '{"a" 1}', msg = "missing ':' between key/value should fail"},
    {text = '{"a": [1, 2}', msg = "missing closing ']' should fail"},
    {text = '{"a": 1', msg = "missing closing '}' should fail"},
    {text = '{"a":"unterminated}', msg = "unterminated string should fail"},
    {text = '{a; 1}', msg = "invalid key separator should fail"},
    {text = '/ not-a-comment', msg = "invalid comment prefix should fail"},
    {text = '/* outer /* inner */ */ {"a":1}', msg = "nested block comments should fail"},
    {text = '{"a": truee}', msg = "invalid true token should fail"},
    {text = '{"a": fals}', msg = "invalid false token should fail"},
    {text = '{"a": nul}', msg = "invalid null token should fail"},
    {text = '{"a": 1e+}', msg = "invalid exponent should fail"},
  }

  for _, c in ipairs(cases) do
    expectDecodeFail(ctx, c.text, c.msg)
  end
end

return M
