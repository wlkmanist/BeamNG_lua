local M = {}

--[[
  To run these tests:
  1. Open the GE Lua Console
  2. Run: require('testFramework/TestManager'):runTestFiles("mathlib")

  Or to run all tests:
  require('testFramework/TestManager'):runTestFiles()
]]

local EPS = 1e-6

-- Asserts vec3 components are near expected values.
local function assertVec3(ctx, v, x, y, z, msg)
  local base = msg or "vec3 mismatch"
  ctx:assertNear(v.x, x, EPS, base .. " (x)")
  ctx:assertNear(v.y, y, EPS, base .. " (y)")
  ctx:assertNear(v.z, z, EPS, base .. " (z)")
end

-- Asserts a scalar is finite (not NaN, +inf, or -inf).
local function assertFinite(ctx, v, msg)
  local base = msg or "value not finite"
  ctx:assertEqual(v == v, true, base .. " (NaN)")
  ctx:assertEqual(v ~= math.huge, true, base .. " (+inf)")
  ctx:assertEqual(v ~= -math.huge, true, base .. " (-inf)")
end

--MARK: ordered coverage

-- Tests vec3 constructors, core arithmetic, normalization, and helpers.
function M.testMathlibVec3Core(ctx)
  ctx:setDescription("Vec3 core functions")

  -- Vec3 construction from different input shapes.
  local v0 = vec3()
  assertVec3(ctx, v0, 0, 0, 0, "vec3()")
  local v1 = vec3(1, 2, 3)
  local v2 = vec3({1, 2, 3})
  local v3 = vec3({x = 1, y = 2, z = 3})
  local v4 = vec3(v1)
  assertVec3(ctx, v2, 1, 2, 3, "vec3(table)")
  assertVec3(ctx, v3, 1, 2, 3, "vec3(dict)")
  assertVec3(ctx, v4, 1, 2, 3, "vec3(vec3)")

  -- In-place mutation and component accessors.
  local s = vec3(0, 0, 0)
  s:set(1, 2, 3)
  assertVec3(ctx, s, 1, 2, 3, "LuaVec3:set xyz")
  s:set(v4)
  assertVec3(ctx, s, 1, 2, 3, "LuaVec3:set vec3")

  local x, y, z = s:xyz()
  ctx:assertEqual(x, 1, "LuaVec3:xyz x")
  ctx:assertEqual(y, 2, "LuaVec3:xyz y")
  ctx:assertEqual(z, 3, "LuaVec3:xyz z")
  local x2, y2 = s:xy()
  ctx:assertEqual(x2, 1, "LuaVec3:xy x")
  ctx:assertEqual(y2, 2, "LuaVec3:xy y")
  -- String/table/dict conversion helpers.
  local c = s:copy()
  assertVec3(ctx, c, 1, 2, 3, "LuaVec3:copy")
  s:fromString("4,5,6")
  assertVec3(ctx, s, 4, 5, 6, "LuaVec3:fromString")
  ctx:assertEqual(type(tostring(s)), "string", "LuaVec3:__tostring")
  local t = s:toTable()
  ctx:assertEqual(t[1], 4, "LuaVec3:toTable [1]")
  ctx:assertEqual(t[2], 5, "LuaVec3:toTable [2]")
  ctx:assertEqual(t[3], 6, "LuaVec3:toTable [3]")
  s:setFromTable({7, 8, 9})
  assertVec3(ctx, s, 7, 8, 9, "LuaVec3:setFromTable")
  local d = s:toDict()
  ctx:assertEqual(d.x, 7, "LuaVec3:toDict x")
  ctx:assertEqual(d.y, 8, "LuaVec3:toDict y")
  ctx:assertEqual(d.z, 9, "LuaVec3:toDict z")

  -- Magnitude and squared magnitude.
  ctx:assertNear(vec3(3, 4, 0):length(), 5, EPS, "LuaVec3:length")
  ctx:assert(vec3(0, 0, 0):lengthGuarded() > 0, "LuaVec3:lengthGuarded")
  ctx:assertEqual(vec3(3, 4, 0):squaredLength(), 25, "LuaVec3:squaredLength")

  -- Arithmetic metamethods and vector algebra.
  assertVec3(ctx, vec3(1, 2, 3) + vec3(4, 5, 6), 5, 7, 9, "LuaVec3.__add")
  assertVec3(ctx, vec3(4, 5, 6) - vec3(1, 2, 3), 3, 3, 3, "LuaVec3.__sub")
  assertVec3(ctx, -vec3(1, 2, 3), -1, -2, -3, "LuaVec3.__unm")
  assertVec3(ctx, vec3(1, 2, 3) * 2, 2, 4, 6, "LuaVec3.__mul")
  assertVec3(ctx, vec3(2, 4, 6) / 2, 1, 2, 3, "LuaVec3.__div")
  ctx:assertEqual(vec3(1, 2, 3) == vec3(1, 2, 3), true, "LuaVec3.__eq")

  local va, vb = vec3(1, 2, 3), vec3(4, 5, 6)
  ctx:assertEqual(va:dot(vb), 32, "LuaVec3:dot")
  assertVec3(ctx, vec3(1, 0, 0):cross(vec3(0, 1, 0)), 0, 0, 1, "LuaVec3:cross")
  assertVec3(ctx, vec3(1, 2, 3):z0(), 1, 2, 0, "LuaVec3:z0")

  -- Perpendicular/slerp/angle relationships.
  local perp = vec3(1, 2, 3):perpendicular()
  ctx:assertNear(perp:dot(vec3(1, 2, 3)), 0, 1e-4, "LuaVec3:perpendicular")
  local perpN = vec3(1, 2, 3):perpendicularN()
  ctx:assertNear(perpN:length(), 1, 1e-4, "LuaVec3:perpendicularN")

  local slerpV = vec3(1, 0, 0):slerp(vec3(0, 1, 0), 0.5)
  assertFinite(ctx, slerpV.x, "LuaVec3:slerp x")
  ctx:assertNear(vec3(1, 0, 0):cosAngle(vec3(0, 1, 0)), 0, EPS, "LuaVec3:cosAngle")

  -- Normalize/resize/ropeRock variants.
  local n = vec3(3, 0, 0)
  n:normalize()
  assertVec3(ctx, n, 1, 0, 0, "LuaVec3:normalize")
  local rz = vec3(1, 0, 0)
  rz:resize(5)
  assertVec3(ctx, rz, 5, 0, 0, "LuaVec3:resize")
  local rr = vec3(3, 0, 0)
  local before = rr:ropeRock(2)
  ctx:assertNear(before, 3, EPS, "LuaVec3:ropeRock return")
  assertVec3(ctx, rr, 2, 0, 0, "LuaVec3:ropeRock value")
  assertVec3(ctx, vec3(2, 0, 0):normalized(), 1, 0, 0, "LuaVec3:normalized")
  assertVec3(ctx, vec3(1, 0, 0):resized(3), 3, 0, 0, "LuaVec3:resized")
end

-- Tests vec3 geometry methods (distances, barycentric, projection, basis, mutators).
function M.testMathlibVec3Geom(ctx)
  ctx:setDescription("Vec3 geometry-oriented methods")

  -- Point-line and point-segment distance family.
  local p = vec3(1, 0, 0)
  local q = vec3(4, 0, 0)
  ctx:assertNear(p:distance(q), 3, EPS, "LuaVec3:distance")
  ctx:assertNear(p:squaredDistance(q), 9, EPS, "LuaVec3:squaredDistance")
  ctx:assertNear(vec3(1, 1, 0):squaredDistanceToLine(vec3(0, 0, 0), vec3(2, 0, 0)), 1, EPS, "LuaVec3:squaredDistanceToLine")
  ctx:assertNear(vec3(1, 1, 0):distanceToLine(vec3(0, 0, 0), vec3(2, 0, 0)), 1, EPS, "LuaVec3:distanceToLine")
  ctx:assertNear(vec3(2, 1, 0):squaredDistanceToLineSegment(vec3(0, 0, 0), vec3(1, 0, 0)), 2, EPS, "LuaVec3:squaredDistanceToLineSegment")
  ctx:assertNear(vec3(2, 1, 0):distanceToLineSegment(vec3(0, 0, 0), vec3(1, 0, 0)), math.sqrt(2), EPS, "LuaVec3:distanceToLineSegment")
  local xn, xsd = vec3(2, 1, 0):xnormSquaredDistanceToLineSegment(vec3(0, 0, 0), vec3(1, 0, 0))
  ctx:assertNear(xsd, 2, EPS, "LuaVec3:xnormSquaredDistanceToLineSegment")
  ctx:assert(xn >= 1, "LuaVec3:xnormSquaredDistanceToLineSegment xnorm")
  local xn2, xd = vec3(2, 1, 0):xnormDistanceToLineSegment(vec3(0, 0, 0), vec3(1, 0, 0))
  ctx:assertNear(xd, math.sqrt(2), EPS, "LuaVec3:xnormDistanceToLineSegment")
  ctx:assert(xn2 >= 1, "LuaVec3:xnormDistanceToLineSegment xnorm")
  ctx:assertNear(vec3(0.5, 0, 0):xnormOnLine(vec3(0, 0, 0), vec3(1, 0, 0)), 0.5, EPS, "LuaVec3:xnormOnLine")

  -- Triangle UV/barycentric helpers.
  local aTri, bTri, cTri = vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 0)
  local u, v, nrm = vec3(0.2, 0.3, 0):triangleBarycentricNorm(aTri, bTri, cTri)
  ctx:assertNear(u, 0.2, 1e-3, "LuaVec3:triangleBarycentricNorm u")
  ctx:assertNear(v, 0.3, 1e-3, "LuaVec3:triangleBarycentricNorm v")
  ctx:assertNear(math.abs(nrm.z), 1, 1e-3, "LuaVec3:triangleBarycentricNorm |nrm.z|")
  local tp = vec3(0, 0, 0)
  tp:setTrianglePointFromUV(aTri, bTri, cTri, 0.2, 0.3)
  assertVec3(ctx, tp, 0.2, 0.3, 0, "LuaVec3:setTrianglePointFromUV")
  local iu, iv = vec3(0.5, 0.5, 0):invBilinear2D(vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0), vec3(1, 1, 0))
  ctx:assertNear(iu, 0.5, 1e-3, "LuaVec3:invBilinear2D u")
  ctx:assertNear(iv, 0.5, 1e-3, "LuaVec3:invBilinear2D v")
  local cu, cv = vec3(2, 2, 0):triangleClosestPointUV(aTri, bTri, cTri)
  assertFinite(ctx, cu, "LuaVec3:triangleClosestPointUV u")
  assertFinite(ctx, cv, "LuaVec3:triangleClosestPointUV v")
  local cp, _, _ = vec3(2, 2, 0):triangleClosestPoint(aTri, bTri, cTri)
  ctx:assert(cp ~= nil, "LuaVec3:triangleClosestPoint")
  ctx:assert(vec3(0.5, 0.5, 0):inPolygon(vec3(0, 0, 0), vec3(1, 0, 0), vec3(1, 1, 0), vec3(0, 1, 0)), "LuaVec3:inPolygon")

  -- Plane/sphere projection and xnorm intersection helpers.
  assertVec3(ctx, vec3(1, 1, 1):projectToOriginPlane(vec3(0, 0, 1)), 1, 1, 0, "LuaVec3:projectToOriginPlane")
  local xPlane = vec3(0, 0, 0):xnormPlaneWithLine(vec3(1, 0, 0), vec3(-1, 0, 0), vec3(1, 0, 0))
  ctx:assertNear(xPlane, 0.5, EPS, "LuaVec3:xnormPlaneWithLine")
  local low, high = vec3(0, 0, 0):xnormsSphereWithLine(1, vec3(-2, 0, 0), vec3(2, 0, 0))
  ctx:assert(low < high, "LuaVec3:xnormsSphereWithLine")

  -- Basis transforms and component-wise operators.
  local bc = vec3(2, 3, 4):basisCoordinates(vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1))
  assertVec3(ctx, bc, 2, 3, 4, "LuaVec3:basisCoordinates")
  local tb = vec3(1, 2, 3)
  tb:setToBase(vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1))
  assertVec3(ctx, tb, 1, 2, 3, "LuaVec3:setToBase")
  local tb2 = vec3(1, 2, 3):toBase(vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1))
  assertVec3(ctx, tb2, 1, 2, 3, "LuaVec3:toBase")
  assertVec3(ctx, vec3(2, 3, 4):componentMul(vec3(5, 6, 7)), 10, 18, 28, "LuaVec3:componentMul")

  -- In-place mutator family (setMin/setMax/setAdd/...).
  local vm = vec3(2, 4, 6)
  vm:setMin(vec3(3, 1, 7))
  assertVec3(ctx, vm, 2, 1, 6, "LuaVec3:setMin")
  vm:setMax(vec3(3, 2, 8))
  assertVec3(ctx, vm, 3, 2, 8, "LuaVec3:setMax")
  vm:setAddXYZ(1, 1, 1)
  assertVec3(ctx, vm, 4, 3, 9, "LuaVec3:setAddXYZ")
  vm:setAdd(vec3(1, 2, 3))
  assertVec3(ctx, vm, 5, 5, 12, "LuaVec3:setAdd")
  vm:setAdd2(vec3(1, 1, 1), vec3(2, 3, 4))
  assertVec3(ctx, vm, 3, 4, 5, "LuaVec3:setAdd2")
  vm:setSub(vec3(1, 2, 3))
  assertVec3(ctx, vm, 2, 2, 2, "LuaVec3:setSub")
  vm:setSub2(vec3(5, 6, 7), vec3(1, 2, 3))
  assertVec3(ctx, vm, 4, 4, 4, "LuaVec3:setSub2")
  vm:setScaled(0.5)
  assertVec3(ctx, vm, 2, 2, 2, "LuaVec3:setScaled")
  vm:setScaled2(vec3(1, 2, 3), 2)
  assertVec3(ctx, vm, 2, 4, 6, "LuaVec3:setScaled2")
  vm:setComponentMul(vec3(2, 0.5, 1))
  assertVec3(ctx, vm, 4, 2, 6, "LuaVec3:setComponentMul")
  vm:setLerp(vec3(0, 0, 0), vec3(2, 4, 6), 0.5)
  assertVec3(ctx, vm, 1, 2, 3, "LuaVec3:setLerp")
  vm:setCross(vec3(1, 0, 0), vec3(0, 1, 0))
  assertVec3(ctx, vm, 0, 0, 1, "LuaVec3:setCross")

  -- Rotation/Euler/perpendicular directional helpers.
  local qRot = quatFromEuler(0, 0, math.pi * 0.5)
  local sr = vec3(1, 0, 0)
  sr:setRotate(qRot)
  ctx:assertNear(sr.x, 0, 1e-4, "LuaVec3:setRotate x")
  ctx:assertNear(sr.z, 0, 1e-4, "LuaVec3:setRotate z")
  ctx:assertNear(math.abs(sr.y), 1, 1e-4, "LuaVec3:setRotate abs(y)")
  local e = vec3(0, 0, 0)
  e:setEulerYXZ(quat(0, 0, 0, 1))
  assertFinite(ctx, e.x, "LuaVec3:setEulerYXZ")
  local spp = vec3(1, 1, 1)
  spp:setProjectToOriginPlane(vec3(0, 0, 1))
  assertVec3(ctx, spp, 1, 1, 0, "LuaVec3:setProjectToOriginPlane")
  local sp = vec3(1, 2, 3)
  sp:setPerpendicular()
  ctx:assertNear(sp:dot(vec3(1, 2, 3)), 0, 1e-4, "LuaVec3:setPerpendicular")
  local rotTo = vec3(1, 0, 0):getRotationTo(vec3(0, 1, 0))
  ctx:assertEqual(type(rotTo.w), "number", "LuaVec3:getRotationTo")
  local rVec = vec3(1, 0, 0):rotated(qRot)
  ctx:assertNear(rVec.x, 0, 1e-4, "LuaVec3:rotated x")
  ctx:assertNear(rVec.z, 0, 1e-4, "LuaVec3:rotated z")
  ctx:assertNear(math.abs(rVec.y), 1, 1e-4, "LuaVec3:rotated abs(y)")
end

-- Tests vec3 noise/random generators and axis/line helper utilities.
function M.testMathlibVec3NoiseAndHelpers(ctx)
  ctx:setDescription("Vec3 noise/random/helper functions")

  -- Blue-noise and random point generation ranges.
  local bn = getBlueNoise1d(0.1)
  ctx:assert(bn >= 0 and bn < 1, "getBlueNoise1d")
  local b2 = vec3(0.1, 0.2, 0.3):getBlueNoise2d()
  ctx:assert(b2.x >= 0 and b2.x < 1 and b2.y >= 0 and b2.y < 1, "LuaVec3:getBlueNoise2d")
  local b3 = vec3(0.1, 0.2, 0.3):getBlueNoise3d()
  ctx:assert(b3.z >= 0 and b3.z < 1, "LuaVec3:getBlueNoise3d")
  local rs = vec3(0, 0, 0):getRandomPointInSphere(2)
  ctx:assert(rs:length() <= 2 + 1e-4, "LuaVec3:getRandomPointInSphere")
  local rc = vec3(0, 0, 0):getRandomPointInCircle(2)
  ctx:assert(math.sqrt(rc.x * rc.x + rc.y * rc.y) <= 2 + 1e-4, "LuaVec3:getRandomPointInCircle radius")
  ctx:assertEqual(rc.z, 0, "LuaVec3:getRandomPointInCircle z")
  local bps = vec3(0.1, 0.2, 0.3):getBluePointInSphere(2)
  ctx:assert(bps:length() <= 2 + 1e-4, "LuaVec3:getBluePointInSphere")
  local bpc = vec3(0.1, 0.2, 0.3):getBluePointInCircle(2)
  ctx:assert(math.sqrt(bpc.x * bpc.x + bpc.y * bpc.y) <= 2 + 1e-4, "LuaVec3:getBluePointInCircle radius")
  ctx:assertEqual(bpc.z, 0, "LuaVec3:getBluePointInCircle z")
  -- Axis helpers and conversion shortcuts.
  local ga = vec3(9, 8, 7)
  ctx:assertEqual(ga:getAxis(0), 9, "LuaVec3:getAxis")
  ga:setAxis(2, 42)
  ctx:assertEqual(ga.z, 42, "LuaVec3:setAxis")
  ctx:assertEqual(ga:toFloat3(), ga, "LuaVec3:toFloat3")

  -- Random scalar helpers and line closest-point utilities.
  local rg = randomGauss3()
  ctx:assert(rg >= 0 and rg <= 3, "randomGauss3")
  local rsn = randomState(0.5)
  ctx:assert(rsn > 0 and rsn <= 1, "randomState")
  local cl1, cl2 = closestLinePoints(vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0), vec3(1, 1, 0))
  assertFinite(ctx, cl1, "closestLinePoints a")
  assertFinite(ctx, cl2, "closestLinePoints b")
  local cs1, cs2 = closestLineSegmentPoints(vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0), vec3(1, 1, 0))
  ctx:assert(cs1 >= 0 and cs1 <= 1 and cs2 >= 0 and cs2 <= 1, "closestLineSegmentPoints")
  assertVec3(ctx, linePointFromXnorm(vec3(0, 0, 0), vec3(2, 0, 0), 0.25), 0.5, 0, 0, "linePointFromXnorm")
end

-- Tests StackVec3 (push3) parity with core vec3 operations.
function M.testMathlibPush3(ctx)
  ctx:setDescription("push3 and StackVec3")

  -- StackVec3 mirrors core vec3 operators and metrics.
  local px, py, pz = push3(1, 2, 3):xyz()
  ctx:assertEqual(px, 1, "push3 / StackVec3:xyz x")
  ctx:assertEqual(py, 2, "push3 / StackVec3:xyz y")
  ctx:assertEqual(pz, 3, "push3 / StackVec3:xyz z")
  assertVec3(ctx, push3(1, 2, 3):copy(), 1, 2, 3, "StackVec3:copy")
  ctx:assertEqual(type(tostring(push3(1, 2, 3))), "string", "StackVec3:__tostring")
  assertVec3(ctx, (push3(1, 2, 3) + vec3(1, 1, 1)):copy(), 2, 3, 4, "StackVec3.__add")
  assertVec3(ctx, (push3(3, 4, 5) - vec3(1, 1, 1)):copy(), 2, 3, 4, "StackVec3.__sub")
  assertVec3(ctx, (-push3(1, 2, 3)):copy(), -1, -2, -3, "StackVec3.__unm")
  assertVec3(ctx, (push3(1, 2, 3) * 2):copy(), 2, 4, 6, "StackVec3.__mul")
  assertVec3(ctx, (push3(2, 4, 6) / 2):copy(), 1, 2, 3, "StackVec3.__div")
  ctx:assertEqual(push3(1, 2, 3):dot(vec3(1, 0, 0)), 1, "StackVec3:dot")
  assertVec3(ctx, push3(1, 0, 0):cross(vec3(0, 1, 0)):copy(), 0, 0, 1, "StackVec3:cross")
  assertVec3(ctx, push3(1, 2, 3):z0():copy(), 1, 2, 0, "StackVec3:z0")
  ctx:assertNear(push3(3, 4, 0):length(), 5, EPS, "StackVec3:length")
  ctx:assertEqual(push3(3, 4, 0):squaredLength(), 25, "StackVec3:squaredLength")
  assertVec3(ctx, push3(2, 0, 0):normalized():copy(), 1, 0, 0, "StackVec3:normalized")
  assertVec3(ctx, push3(1, 0, 0):resized(3):copy(), 3, 0, 0, "StackVec3:resized")
  assertFinite(ctx, push3(1, 2, 3):distance(vec3(0, 0, 0)), "StackVec3:distance")
  assertFinite(ctx, push3(1, 2, 3):squaredDistance(vec3(0, 0, 0)), "StackVec3:squaredDistance")
end

-- Tests quaternion construction, algebra, interpolation, and conversions.
function M.testMathlibQuat(ctx)
  ctx:setDescription("Quaternion functions")

  -- Quaternion construction and component access.
  local q1 = quat(1, 2, 3, 4)
  local q2 = quat({1, 2, 3, 4})
  local q3 = quat({x = 1, y = 2, z = 3, w = 4})
  ctx:assertEqual(q1.x, q2.x, "quat x (q1/q2)")
  ctx:assertEqual(q2.x, q3.x, "quat x (q2/q3)")
  local qx, qy, qz = q1:xyz()
  ctx:assertEqual(qx, 1, "LuaQuat:xyz x")
  ctx:assertEqual(qy, 2, "LuaQuat:xyz y")
  ctx:assertEqual(qz, 3, "LuaQuat:xyz z")
  local qxx, qyy, qzz, qww = q1:xyzw()
  ctx:assertEqual(qxx, 1, "LuaQuat:xyzw x")
  ctx:assertEqual(qyy, 2, "LuaQuat:xyzw y")
  ctx:assertEqual(qzz, 3, "LuaQuat:xyzw z")
  ctx:assertEqual(qww, 4, "LuaQuat:xyzw w")
  ctx:assertEqual(type(tostring(q1)), "string", "LuaQuat:__tostring")
  local qt = q1:toTable()
  ctx:assertEqual(qt[4], 4, "LuaQuat:toTable")
  local qd = q1:toDict()
  ctx:assertEqual(qd.w, 4, "LuaQuat:toDict")
  local qc = q1:copy()
  ctx:assertEqual(qc.w, 4, "LuaQuat:copy")
  qc:set(0, 0, 0, 1)
  ctx:assertEqual(qc.w, 1, "LuaQuat:set values")
  qc:set(q1)
  ctx:assertEqual(qc.x, 1, "LuaQuat:set quat x")
  ctx:assertEqual(qc.w, 4, "LuaQuat:set quat w")
  ctx:assertNear(quat(0, 0, 0, 1):norm(), 1, EPS, "LuaQuat:norm")
  ctx:assertEqual(quat(0, 0, 0, 1):squaredNorm(), 1, "LuaQuat:squaredNorm")
  -- Norm/normalize/inverse primitives.
  local qn = quat(0, 0, 0, 2)
  qn:normalize()
  ctx:assertNear(qn.w, 1, EPS, "LuaQuat:normalize")
  local qnn = quat(0, 0, 0, 2):normalized()
  ctx:assertNear(qnn.w, 1, EPS, "LuaQuat:normalized")
  local qi = quat(0, 0, 0, 1)
  qi:inverse()
  ctx:assertNear(qi.w, 1, EPS, "LuaQuat:inverse")
  ctx:assertNear(quat(0, 0, 0, 1):inversed().w, 1, EPS, "LuaQuat:inversed")
  -- Quaternion arithmetic and mixed-type multiplication.
  ctx:assertEqual((-quat(1, 2, 3, 4)).x, -1, "LuaQuat.__unm")
  ctx:assertEqual((quat(1, 2, 3, 4) * 2).w, 8, "LuaQuat.__mul scalar")
  local qv = quatFromEuler(0, 0, math.pi * 0.5) * vec3(1, 0, 0)
  ctx:assertNear(qv.x, 0, 1e-4, "LuaQuat.__mul vec3 x")
  ctx:assertNear(qv.z, 0, 1e-4, "LuaQuat.__mul vec3 z")
  ctx:assertNear(math.abs(qv.y), 1, 1e-4, "LuaQuat.__mul vec3 |y|")
  local qq = quat(0, 0, 0, 1) * quat(0, 0, 0, 1)
  ctx:assertNear(qq.w, 1, EPS, "LuaQuat.__mul quat")
  ctx:assertEqual((quat(1, 2, 3, 4) - quat(1, 1, 1, 1)).x, 0, "LuaQuat.__sub")
  ctx:assertEqual((quat(2, 4, 6, 8) / 2).w, 4, "LuaQuat.__div scalar")
  ctx:assertEqual(type((quat(0, 0, 0, 1) / quat(0, 0, 0, 1)).w), "number", "LuaQuat.__div quat")
  ctx:assertEqual((quat(1, 2, 3, 4) + quat(1, 1, 1, 1)).z, 4, "LuaQuat.__add")
  ctx:assertEqual(quat(1, 0, 0, 0):dot(quat(1, 0, 0, 0)), 1, "LuaQuat:dot")
  ctx:assertEqual(quat(1, 0, 0, 0):distance(quat(1, 0, 0, 0)), 0, "LuaQuat:distance")
  ctx:assertNear(quat(0, 0, 0, 1):nlerp(quat(0, 0, 0, 1), 0.5).w, 1, EPS, "LuaQuat:nlerp")
  ctx:assertNear(quat(0, 0, 0, 1):slerp(quat(0, 0, 0, 1), 0.5).w, 1, EPS, "LuaQuat:slerp")
  ctx:assertEqual(quat(1, 2, 3, 4):conjugated().w, 4, "LuaQuat:conjugated")
  local qs = quat(1, 2, 3, 4)
  qs:scale(2)
  ctx:assertEqual(qs.w, 8, "LuaQuat:scale")
  -- Builder/setter helpers for common rotation representations.
  local qaa = quat(0, 0, 0, 1)
  qaa:setFromAxisAngle(vec3(0, 0, 1), math.pi)
  assertFinite(ctx, qaa.w, "LuaQuat:setFromAxisAngle")
  local qrt = quat(0, 0, 0, 1)
  qrt:setRotationFromTo(vec3(1, 0, 0), vec3(0, 1, 0))
  assertFinite(ctx, qrt.w, "LuaQuat:setRotationFromTo")
  local qfe = quat(0, 0, 0, 1)
  qfe:setFromEuler(0, 0, math.pi * 0.5)
  assertFinite(ctx, qfe.w, "LuaQuat:setFromEuler")
  local qfd = quat(0, 0, 0, 1)
  qfd:setFromDir(vec3(0, 1, 0), vec3(0, 0, 1))
  assertFinite(ctx, qfd.w, "LuaQuat:setFromDir")
  local qmx = quat(0, 0, 0, 1)
  qmx:setMulXYZW(0, 0, 0, 1, 0, 0, 0, 1)
  ctx:assertEqual(qmx.w, 1, "LuaQuat:setMulXYZW")
  local qsm = quat(0, 0, 0, 1)
  qsm:setMul2(quat(0, 0, 0, 1), quat(0, 0, 0, 1))
  ctx:assertNear(qsm.w, 1, EPS, "LuaQuat:setMul2")
  local qim = quat(0, 0, 0, 1)
  qim:setInvMul2(quat(0, 0, 0, 1), quat(0, 0, 0, 1))
  assertFinite(ctx, qim.w, "LuaQuat:setInvMul2")
  local qmi = quat(0, 0, 0, 1)
  qmi:setMulInv2(quat(0, 0, 0, 1), quat(0, 0, 0, 1))
  assertFinite(ctx, qmi.w, "LuaQuat:setMulInv2")
  -- Conversion helpers back to Euler/torque/direction forms.
  local eyx = quat(0, 0, 0, 1):toEulerYXZ()
  assertFinite(ctx, eyx.x, "LuaQuat:toEulerYXZ")
  local tq = quat(0, 0, 0, 1):toTorqueQuat()
  ctx:assertEqual(type(tq.w), "number", "LuaQuat:toTorqueQuat")
  local dir, up = quat(0, 0, 0, 1):toDirUp()
  ctx:assert(dir and up, "LuaQuat:toDirUp")
  ctx:assertEqual(type(quatFromDir(vec3(0, 1, 0), vec3(0, 0, 1)).w), "number", "quatFromDir")
  ctx:assertEqual(type(quatFromAxisAngle(vec3(0, 0, 1), math.pi).w), "number", "quatFromAxisAngle")
  ctx:assertEqual(type(quatFromEuler(0, 0, math.pi * 0.5).w), "number", "quatFromEuler")
end

-- Tests generic scalar helpers: sign, clamp, interpolation, medians, and bounds.
function M.testMathlibGeneric(ctx)
  ctx:setDescription("Generic scalar math helpers")

  -- Sign, clamp, rounding and classification helpers.
  ctx:assertEqual(sign2(2), 1, "sign2 positive")
  ctx:assertEqual(sign2(-2), -1, "sign2 negative")
  ctx:assertEqual(sign(2), 1, "sign positive")
  ctx:assertEqual(sign(-2), -1, "sign negative")
  ctx:assertEqual(sign(0), 0, "sign zero")
  ctx:assertEqual(signApply(-2, 3), -3, "signApply")
  assertFinite(ctx, guardZero(0), "guardZero")
  ctx:assertEqual(clamp(5, 0, 3), 3, "clamp")
  ctx:assertEqual(square(4), 16, "square")
  ctx:assertEqual(round(1.5), 2, "round")
  ctx:assertNear(roundNear(1.23, 0.1), 1.2, EPS, "roundNear")
  ctx:assert(isnan(0 / 0), "isnan")
  ctx:assert(isinf(math.huge), "isinf")
  ctx:assert(isnaninf(0 / 0) and isnaninf(math.huge), "isnaninf")
  local ok = pcall(nanError, 0 / 0)
  ctx:assert(not ok, "nanError")
  -- Scale/interpolation and smooth step families.
  ctx:assertNear(linearScale(5, 0, 10, 0, 1), 0.5, EPS, "linearScale")
  ctx:assertNear(rescale(5, 0, 10, 0, 100), 50, EPS, "rescale")
  ctx:assertNear(lerp(0, 10, 0.5), 5, EPS, "lerp")
  ctx:assertNear(inverseLerp(0, 10, 5), 0.5, EPS, "inverseLerp")
  ctx:assertNear(smoothstep(0), 0, EPS, "smoothstep(0)")
  ctx:assertNear(smoothstep(1), 1, EPS, "smoothstep(1)")
  ctx:assertNear(smootherstep(0), 0, EPS, "smootherstep(0)")
  ctx:assertNear(smootherstep(1), 1, EPS, "smootherstep(1)")
  ctx:assertNear(smootheststep(0), 0, EPS, "smootheststep(0)")
  ctx:assertNear(smootheststep(1), 1, EPS, "smootheststep(1)")
  -- Bias/gain, bump, medians and 2D bounding boxes.
  ctx:assert(smoothmin(1, 2, 0.5) <= 2, "smoothmin")
  ctx:assert(smoothmax(1, 2, 0.5) >= 1, "smoothmax")
  ctx:assertNear(biasFun(0.5, 1), 2 / 3, EPS, "biasFun")
  local bg = biasGainFun(0.25, 0.5, 0.25)
  ctx:assert(bg >= 0 and bg <= 1, "biasGainFun")
  ctx:assertEqual(sigmoid1(0, 1), 0, "sigmoid1")
  local bf = bumpFun(0.5, 0.2, 0.8)
  assertFinite(ctx, bf, "bumpFun")
  ctx:assertEqual(median3(1, 9, 3), 3, "median3")
  ctx:assertEqual(median4(1, 2, 3, 100), 2.5, "median4")
  ctx:assertEqual(median5(1, 9, 3, 8, 5), 5, "median5")
  local minx, miny, maxx, maxy = pointBB2d(1, 2, 3)
  ctx:assertEqual(minx, -2, "pointBB2d minx")
  ctx:assertEqual(miny, -1, "pointBB2d miny")
  ctx:assertEqual(maxx, 4, "pointBB2d maxx")
  ctx:assertEqual(maxy, 5, "pointBB2d maxy")
  local lminx, lminy, lmaxx, lmaxy = lineBB2d(0, 1, 4, 3, 1)
  ctx:assertEqual(lminx, -1, "lineBB2d minx")
  ctx:assertEqual(lminy, 0, "lineBB2d miny")
  ctx:assertEqual(lmaxx, 5, "lineBB2d maxx")
  ctx:assertEqual(lmaxy, 4, "lineBB2d maxy")
end

-- Tests curve interpolation helpers (spline/Catmull-Rom/Bezier families).
function M.testMathlibCurves(ctx)
  ctx:setDescription("Curve interpolation helpers")

  -- Cardinal/Catmull-Rom/Bezier and monotonic interpolation checks.
  local cs = cardinalSpline(0, 1, 2, 3, 0.5, 0.5, 1, 1, 1)
  assertFinite(ctx, cs, "cardinalSpline")
  assertFinite(ctx, catmullRom(0, 1, 2, 3, 0.5, 0.5), "catmullRom")
  local p0, p1c, p2c, p3c = vec3(0, 0, 0), vec3(1, 0, 0), vec3(2, 0, 0), vec3(3, 0, 0)
  ctx:assert(catmullRomChordal(p0, p1c, p2c, p3c, 0.5, 0.5) ~= nil, "catmullRomChordal")
  ctx:assert(catmullRomCentripetal(p0, p1c, p2c, p3c, 0.5, 0.5) ~= nil, "catmullRomCentripetal")
  assertFinite(ctx, monotonicSteffen(0, 1, 2, 3, 0, 1, 2, 3, 1.5), "monotonicSteffen")
  ctx:assertNear(quadraticBezier(0, 1, 2, 0.5), 1, EPS, "quadraticBezier")
  ctx:assertNear(conicBezier(0, 1, 2, 0.5, 1), 1, EPS, "conicBezier")
  assertFinite(ctx, biQuadratic(0, 1, 2, 3, 0.5), "biQuadratic")
end

-- Tests geometry overlap/containment/intersection helper families.
function M.testMathlibGeom(ctx)
  ctx:setDescription("Geometric intersection/containment helpers")

  -- OBB/Sphere/Plane overlap/containment predicates.
  local c1, x1a, y1a, z1a = vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)
  local c2, x2a, y2a, z2a = vec3(0.2, 0.2, 0.2), vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)
  ctx:assert(overlapsOBB_OBB(c1, x1a, y1a, z1a, c2, x2a, y2a, z2a), "overlapsOBB_OBB")
  ctx:assert(containsOBB_OBB(c1, x1a, y1a, z1a, c2, vec3(0.2, 0, 0), vec3(0, 0.2, 0), vec3(0, 0, 0.2)), "containsOBB_OBB")
  ctx:assertNear(OBBsquaredDistance(c1, x1a, y1a, z1a, vec3(0, 0, 0)), 0, EPS, "OBBsquaredDistance")
  ctx:assert(overlapsOBB_Sphere(c1, x1a, y1a, z1a, vec3(0.5, 0, 0), 0.5), "overlapsOBB_Sphere")
  ctx:assert(overlapsOBB_Plane(c1, x1a, y1a, z1a, vec3(0, 0, 0), vec3(0, 0, 1)), "overlapsOBB_Plane")
  ctx:assert(containsOBB_Sphere(c1, x1a, y1a, z1a, vec3(0, 0, 0), 0.25), "containsOBB_Sphere")
  ctx:assert(containsSphere_OBB(c1, 5, c2, vec3(0.5, 0, 0), vec3(0, 0.5, 0), vec3(0, 0, 0.5)), "containsSphere_OBB")
  ctx:assert(containsOBB_point(c1, x1a, y1a, z1a, vec3(0, 0, 0)), "containsOBB_point")
  ctx:assert(containsEllipsoid_Point(c1, x1a, y1a, z1a, vec3(0, 0, 0)), "containsEllipsoid_Point")
  ctx:assert(constainsCylinder_Point(vec3(0, 0, -1), vec3(0, 0, 1), 1, vec3(0.5, 0, 0)), "constainsCylinder_Point")
  -- Ray primitive intersection families (OBB, sphere, ellipsoid, cylinder, capsule, triangle).
  assertFinite(ctx, altitudeOBB_Plane(c1, x1a, y1a, z1a, vec3(0, 0, 0), vec3(0, 0, 1)), "altitudeOBB_Plane")
  assertFinite(ctx, intersectsRay_Plane(vec3(0, 0, -1), vec3(0, 0, 1), vec3(0, 0, 0), vec3(0, 0, 1)), "intersectsRay_Plane")
  local minHit, maxHit = intersectsRay_OBB(vec3(-3, 0, 0), vec3(1, 0, 0), c1, x1a, y1a, z1a)
  ctx:assert(minHit <= maxHit, "intersectsRay_OBB")
  local sMin, sMax = intersectsRay_Sphere(vec3(-3, 0, 0), vec3(1, 0, 0), c1, 1)
  ctx:assert(sMin <= sMax, "intersectsRay_Sphere")
  local eMin, eMax = intersectsRay_Ellipsoid(vec3(-3, 0, 0), vec3(1, 0, 0), c1, x1a, y1a, z1a)
  ctx:assert(eMin <= eMax, "intersectsRay_Ellipsoid")
  local cyMin, cyMax = intersectsRay_Cylinder(vec3(-3, 0, 0), vec3(1, 0, 0), vec3(0, 0, -1), vec3(0, 0, 1), 1)
  ctx:assert(cyMin <= cyMax, "intersectsRay_Cylinder")
  assertFinite(ctx, intersectsRay_Capsule(vec3(-3, 0, 0), vec3(1, 0, 0), vec3(0, 0, -1), vec3(0, 0, 1), 1), "intersectsRay_Capsule")
  local triHit, bu, bv = intersectsRay_Triangle(vec3(0.2, 0.2, 1), vec3(0, 0, -1), vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0))
  ctx:assert(triHit < math.huge and bu >= 0 and bv >= 0, "intersectsRay_Triangle")
end

-- Tests NaN/inf/div-by-zero edge behavior across math helpers.
function M.testMathlibSpecialValuesAndOddities(ctx)
  ctx:setDescription("Tests NaN, infinities, div-by-zero and odd cases")

  -- Canonical NaN/inf identities and arithmetic.
  local inf = math.huge
  local ninf = -math.huge
  local nan = 0 / 0

  ctx:assert(nan ~= nan, "NaN self-inequality")
  ctx:assertEqual((1 / 0), inf, "positive infinity from div/0")
  ctx:assertEqual((-1 / 0), ninf, "negative infinity from div/0")
  ctx:assertEqual((1 / 0) + 1, inf, "infinity arithmetic")

  -- Scalar helper behavior with NaN/inf inputs.
  ctx:assert(isnan(nan), "isnan NaN")
  ctx:assert(not isnan(inf), "isnan inf false")
  ctx:assert(isinf(inf) and isinf(ninf), "isinf infinities")
  ctx:assert(not isinf(0), "isinf zero false")
  ctx:assert(isnaninf(nan) and isnaninf(inf), "isnaninf odd values")

  ctx:assertEqual(sign(inf), 1, "sign infinities +inf")
  ctx:assertEqual(sign(ninf), -1, "sign infinities -inf")
  ctx:assertEqual(signApply(ninf, 3), -3, "signApply infinities -inf")
  ctx:assertEqual(signApply(inf, 3), 3, "signApply infinities +inf")
  ctx:assertEqual(clamp(nan, 7, 9), 7, "clamp NaN -> min")
  ctx:assertEqual(clamp(inf, 0, 10), 10, "clamp +inf")
  ctx:assertEqual(clamp(ninf, 0, 10), 0, "clamp -inf")
  ctx:assertEqual(inverseLerp(1, 1, 999), 0, "inverseLerp zero delta")
  ctx:assertEqual(smoothstep(inf), 1, "smoothstep +inf")
  ctx:assertEqual(smoothstep(ninf), 0, "smoothstep -inf")
  ctx:assertEqual(smootherstep(inf), 1, "smootherstep +inf")
  ctx:assertEqual(smootherstep(ninf), 0, "smootherstep -inf")
  ctx:assertEqual(smootheststep(inf), 1, "smootheststep +inf")
  ctx:assertEqual(smootheststep(ninf), 0, "smootheststep -inf")
  ctx:assertEqual(guardZero(0), guardZero(0), "guardZero finite with zero input")

  -- Error-path behavior for nanError.
  local okNanErrorInf, resInf = pcall(nanError, inf)
  ctx:assert(okNanErrorInf, "nanError keeps non-NaN pcall")
  ctx:assertEqual(resInf, inf, "nanError keeps non-NaN value")
  local okNanErrorNaN = pcall(nanError, nan)
  ctx:assert(not okNanErrorNaN, "nanError rejects NaN")

  -- Vec3/quat divide-by-zero component semantics.
  local vDiv0 = vec3(1, -1, 0) / 0
  ctx:assertEqual(vDiv0.x, inf, "vec3 div/0 x sign")
  ctx:assertEqual(vDiv0.y, ninf, "vec3 div/0 y sign")
  ctx:assert(vDiv0.z ~= vDiv0.z, "vec3 div/0 zero component -> NaN")

  local qDiv0 = quat(1, -1, 0, 2) / 0
  ctx:assertEqual(qDiv0.x, inf, "quat div/0 x sign")
  ctx:assertEqual(qDiv0.y, ninf, "quat div/0 y sign")
  ctx:assertEqual(qDiv0.w, inf, "quat div/0 w sign")
  ctx:assert(qDiv0.z ~= qDiv0.z, "quat div/0 zero component -> NaN")

  -- Ray/plane edge behavior: parallel and direct-hit cases.
  local minHit, maxHit = intersectsRay_Plane(vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 0, 1), vec3(0, 0, 1)), intersectsRay_Plane(vec3(0, 0, 0), vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1))
  ctx:assert(minHit == inf or minHit == ninf or minHit ~= minHit, "ray/plane parallel oddity handled")
  ctx:assertEqual(maxHit, 1, "ray/plane normal hit")
end

-- Benchmarks representative vec3 math in a tight loop.
function M.testPerfVec3Batch(ctx)
  ctx:setDescription("Perf batch: vec3 arithmetic/algebra, 10000 iterations")

  local acc = 0
  for i = 1, 10000 do
    local a = vec3(i * 0.001, 2, 3)
    local b = vec3(4, 5, 6)
    acc = acc + a:dot(b)
    acc = acc + a:length() + a:squaredLength()

    local c = a:cross(b)
    acc = acc + c:length()

    local n = a:normalized()
    acc = acc + n.x + n.y + n.z

    local d = (a + b) - b
    acc = acc + d.x
  end

  assertFinite(ctx, acc, "perf vec3 accumulator")
end

-- Benchmarks representative quaternion math in a tight loop.
function M.testPerfQuatBatch(ctx)
  ctx:setDescription("Perf batch: quaternion ops, 10000 iterations")

  local acc = 0
  local qA = quatFromEuler(0.1, 0.2, 0.3)
  local qB = quatFromEuler(-0.2, 0.1, -0.1)
  local v = vec3(1, 0, 0)

  for i = 1, 10000 do
    local t = (i % 100) / 100
    local q = qA:slerp(qB, t)
    local qx, qy, qz, qw = q:xyzw()
    acc = acc + qx + qy + qz + qw

    local r = q * v
    acc = acc + r.x + r.y + r.z

    local n = q:normalized()
    local nx, ny, nz, nw = n:xyzw()
    acc = acc + nx + ny + nz + nw
  end

  assertFinite(ctx, acc, "perf quat accumulator")
end

-- Benchmarks representative scalar helper math in a tight loop.
function M.testPerfScalarBatch(ctx)
  ctx:setDescription("Perf batch: scalar helpers, 10000 iterations")

  local acc = 0
  for i = 1, 10000 do
    local t = i / 1000
    acc = acc + smoothstep(t) + smootherstep(t) + smootheststep(t)
    acc = acc + linearScale(i, 1, 1000, 0, 1)
    acc = acc + rescale(i, 1, 1000, -1, 1)
    acc = acc + lerp(0, 10, t)
    acc = acc + inverseLerp(0, 10, t * 10)
    acc = acc + biasFun(t, 1.5)
    acc = acc + median3(i % 3, (i + 1) % 5, (i + 2) % 7)
  end

  assertFinite(ctx, acc, "perf scalar accumulator")
end

-- Benchmarks representative geometric query helpers in a tight loop.
function M.testPerfGeometryBatch(ctx)
  ctx:setDescription("Perf batch: geometric queries, 10000 iterations")

  local acc = 0
  local p = vec3(1, 2, 3)
  local q = vec3(4, 5, 6)
  local a = vec3(0, 0, 0)
  local b = vec3(2, 0, 0)

  for i = 1, 10000 do
    acc = acc + p:distance(q)
    acc = acc + p:squaredDistance(q)
    acc = acc + p:distanceToLine(a, b)
    acc = acc + p:distanceToLineSegment(a, b)

    local hit = intersectsRay_Plane(vec3(0, 0, -1), vec3(0, 0, 1), vec3(0, 0, 0), vec3(0, 0, 1))
    acc = acc + hit

    local tMin, tMax = intersectsRay_Sphere(vec3(-3, 0, 0), vec3(1, 0, 0), vec3(0, 0, 0), 1)
    acc = acc + tMin + tMax
  end

  assertFinite(ctx, acc, "perf geometry accumulator")
end

-- Verifies scalar helper loop stays allocation-free under strict garbage allowance.
function M.testNoGarbageScalarMathHelpers(ctx)
  ctx:setDescription("No-garbage: scalar math helpers")
  ctx:allowGarbage(512)

  local acc = 0
  ctx:resetGarbageCheckpoint()
  for i = 1, 10000 do
    local t = i / 10000
    acc = acc + sign2(i) + sign(-i) + signApply(-i, 1)
    acc = acc + clamp(i, 0, 5000)
    acc = acc + square(i % 11)
    acc = acc + roundNear(t, 0.01)
    acc = acc + linearScale(i, 1, 10000, 0, 1)
    acc = acc + rescale(i, 1, 10000, -1, 1)
    acc = acc + lerp(0, 100, t)
    acc = acc + inverseLerp(0, 100, t * 100)
    acc = acc + smoothstep(t) + smootherstep(t) + smootheststep(t)
    acc = acc + smoothmin(1, 2, 0.5) + smoothmax(1, 2, 0.5)
    acc = acc + biasFun(t, 1.1)
  end
  ctx:checkGarbage(0, "scalar helper loop allocated garbage")
  assertFinite(ctx, acc, "no-garbage scalar accumulator")
end

-- Verifies in-place vec3 operations stay allocation-free under strict garbage allowance.
function M.testNoGarbageVec3InPlace(ctx)
  ctx:setDescription("No-garbage: vec3 in-place ops")
  ctx:allowGarbage(1024)

  local a = vec3(1, 2, 3)
  local b = vec3(4, 5, 6)
  local c = vec3(0, 0, 0)
  local m = vec3(2, 1, 0.5)
  local acc = 0

  ctx:resetGarbageCheckpoint()
  for i = 1, 10000 do
    c:setAdd2(a, b)
    c:setSub(b)
    c:setScaled(0.5)
    c:setComponentMul(m)
    c:setLerp(a, b, 0.25)
    c:setCross(a, b)
    acc = acc + c.x + c.y + c.z
  end
  ctx:checkGarbage(0, "vec3 in-place loop allocated garbage")
  assertFinite(ctx, acc, "no-garbage vec3 accumulator")
end

-- Verifies in-place quaternion operations stay allocation-free under strict garbage allowance.
function M.testNoGarbageQuatInPlace(ctx)
  ctx:setDescription("No-garbage: quat in-place ops")
  ctx:allowGarbage(1024)

  local qa = quat(0, 0, 0, 1)
  local qb = quatFromEuler(0.1, 0.2, 0.3)
  local qc = quat(0, 0, 0, 1)
  local acc = 0

  ctx:resetGarbageCheckpoint()
  for i = 1, 10000 do
    qc:setMul2(qa, qb)
    qc:setInvMul2(qa, qb)
    qc:setMulInv2(qa, qb)
    qc:normalize()
    acc = acc + qc.w
  end
  ctx:checkGarbage(0, "quat in-place loop allocated garbage")
  assertFinite(ctx, acc, "no-garbage quat accumulator")
end

-- Verifies single-shot scalar helpers stay allocation-free without loops.
function M.testNoGarbageScalarSingleShot(ctx)
  ctx:setDescription("No-garbage: scalar single-shot")
  ctx:allowGarbage(0)

  local a = clamp(12, 0, 10)
  local b = lerp(0, 100, 0.25)
  local c = inverseLerp(0, 100, 25)
  local d = smoothstep(0.5)

  ctx:assertEqual(a, 10, "single-shot clamp result mismatch")
  ctx:assertNear(b, 25, 1e-6, "single-shot lerp result mismatch")
  ctx:assertNear(c, 0.25, 1e-6, "single-shot inverseLerp result mismatch")
  ctx:assertNear(d, 0.5, 1e-6, "single-shot smoothstep result mismatch")
end

return M
