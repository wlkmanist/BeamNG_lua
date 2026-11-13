-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Delaunay interpolation for unstructured 2D points. Triangulation is built
-- during load; get() walks adjacent triangles without allocating.

local abs = math.abs
local huge = math.huge

-- Indexed records avoid hot-path hash lookups:
-- {b1x,b1y,b1c, b2x,b2y,b2c, va,vb-va,vc-va, n1,n2,n3}.
local INSIDE_TOL = 1e-9
local AREA_EPS = 1e-14
local DEDUP_TOL = 1e-9
-- Joggling is opt-in because it moves hull vertices and can reject original boundary points.
local JOGGLE_DEFAULT = 0

local function orient2d(ax, ay, bx, by, cx, cy)
  return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

-- Positive when d lies inside the circumcircle of CCW triangle abc.
local function inCircle(ax, ay, bx, by, cx, cy, dx, dy)
  local adx, ady = ax - dx, ay - dy
  local bdx, bdy = bx - dx, by - dy
  local cdx, cdy = cx - dx, cy - dy
  local ad = adx * adx + ady * ady
  local bd = bdx * bdx + bdy * bdy
  local cd = cdx * cdx + cdy * cdy
  return adx * (bdy * cd - cdy * bd)
       - ady * (bdx * cd - cdx * bd)
       + ad  * (bdx * cdy - cdx * bdy)
end

-- Bowyer-Watson triangulation using temporary super-triangle vertices.
local function triangulate(px, py, n)
  local minx, miny, maxx, maxy = huge, huge, -huge, -huge
  for i = 1, n do
    if px[i] < minx then minx = px[i] end
    if py[i] < miny then miny = py[i] end
    if px[i] > maxx then maxx = px[i] end
    if py[i] > maxy then maxy = py[i] end
  end
  local dx = maxx - minx
  local dy = maxy - miny
  local d = (dx > dy and dx or dy)
  if d <= 0 then d = 1 end
  local midx = (minx + maxx) * 0.5
  local midy = (miny + maxy) * 0.5
  local m = d * 1000

  local s1, s2, s3 = n + 1, n + 2, n + 3
  px[s1], py[s1] = midx - 20 * m, midy - m
  px[s2], py[s2] = midx,          midy + 20 * m
  px[s3], py[s3] = midx + 20 * m, midy - m

  local tris = {}
  if orient2d(px[s1], py[s1], px[s2], py[s2], px[s3], py[s3]) < 0 then
    s2, s3 = s3, s2
  end
  tris[1] = { a = s1, b = s2, c = s3 }

  local BIGK = n + 4 -- edge key base, must exceed any vertex index

  for i = 1, n do
    local ix, iy = px[i], py[i]

    -- Remove triangles containing this point, then retriangulate their cavity.
    local present = {}
    local bad = {}
    local nbad = 0
    for ti = 1, #tris do
      local t = tris[ti]
      local a, b, c = t.a, t.b, t.c
      if inCircle(px[a], py[a], px[b], py[b], px[c], py[c], ix, iy) > 0 then
        t.bad = true
        nbad = nbad + 1
        bad[nbad] = t
        present[a * BIGK + b] = true
        present[b * BIGK + c] = true
        present[c * BIGK + a] = true
      end
    end

    local kept = {}
    local nk = 0
    for ti = 1, #tris do
      local t = tris[ti]
      if not t.bad then
        nk = nk + 1
        kept[nk] = t
      end
    end
    tris = kept

    for bi = 1, nbad do
      local t = bad[bi]
      local a, b, c = t.a, t.b, t.c
      if not present[b * BIGK + a] then
        local u, v = a, b
        if orient2d(px[u], py[u], px[v], py[v], ix, iy) < 0 then u, v = v, u end
        tris[#tris + 1] = { a = u, b = v, c = i }
      end
      if not present[c * BIGK + b] then
        local u, v = b, c
        if orient2d(px[u], py[u], px[v], py[v], ix, iy) < 0 then u, v = v, u end
        tris[#tris + 1] = { a = u, b = v, c = i }
      end
      if not present[a * BIGK + c] then
        local u, v = c, a
        if orient2d(px[u], py[u], px[v], py[v], ix, iy) < 0 then u, v = v, u end
        tris[#tris + 1] = { a = u, b = v, c = i }
      end
    end
  end

  local out = {}
  local no = 0
  for ti = 1, #tris do
    local t = tris[ti]
    if t.a <= n and t.b <= n and t.c <= n then
      no = no + 1
      out[no] = t
    end
  end
  return out
end

local function buildTriangles(rawTris, px, py, pv, n, minX, minY, sx, sy)
  local BIGK = n + 4
  local edgeToTri = {} -- directed edge (u,v) -> owning triangle index
  local tris = {}
  local ta, tb, tc = {}, {}, {}
  local count = 0

  for ti = 1, #rawTris do
    local t = rawTris[ti]
    local a, b, c = t.a, t.b, t.c
    local ax, ay = px[a], py[a]
    local bx, by = px[b], py[b]
    local cx, cy = px[c], py[c]

    local det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
    if abs(det) > AREA_EPS then
      local inv = 1 / det
      count = count + 1
      local va = pv[a]
      local m11, m12 = (cy - ay) * inv, -(cx - ax) * inv
      local m21, m22 = -(by - ay) * inv, (bx - ax) * inv
      tris[count] = {
        m11 * sx, m12 * sy, -m11 * (minX * sx + ax) - m12 * (minY * sy + ay),
        m21 * sx, m22 * sy, -m21 * (minX * sx + ax) - m22 * (minY * sy + ay),
        va, pv[b] - va, pv[c] - va,
        0, 0, 0
      }
      edgeToTri[a * BIGK + b] = count
      edgeToTri[b * BIGK + c] = count
      edgeToTri[c * BIGK + a] = count
      ta[count], tb[count], tc[count] = a, b, c
    end
  end

  local hullEdges = {}
  for ti = 1, count do
    local t = tris[ti]
    local a, b, c = ta[ti], tb[ti], tc[ti]
    local n1 = edgeToTri[c * BIGK + b] or 0
    local n2 = edgeToTri[a * BIGK + c] or 0
    local n3 = edgeToTri[b * BIGK + a] or 0
    t[10], t[11], t[12] = n1, n2, n3
    if n1 == 0 then
      hullEdges[#hullEdges + 1] = { px[b], py[b], pv[b], px[c], py[c], pv[c] }
    end
    if n2 == 0 then
      hullEdges[#hullEdges + 1] = { px[c], py[c], pv[c], px[a], py[a], pv[a] }
    end
    if n3 == 0 then
      hullEdges[#hullEdges + 1] = { px[a], py[a], pv[a], px[b], py[b], pv[b] }
    end
  end

  return tris, count, hullEdges
end

-- Points accept {x,y,value} or keyed fields; opts controls outside mode, scaling and tolerances.
local function loadData(self, inputData, opts)
  opts = opts or {}
  self.outsideMode = opts.outsideMode or "default"
  self.defaultValue = opts.defaultValue or 0
  self.valid = false
  self.tris = {}
  self.triCount = 0
  self.lastTri = 1
  self.lastInputX = nil
  self.lastInputY = nil
  self.lastResult = nil

  local xScale = opts.xScale or 1
  local yScale = opts.yScale or 1
  local zScale = opts.zScale or 1

  local rx, ry, rv = {}, {}, {}
  local m = 0
  for i = 1, #inputData do
    local p = inputData[i]
    local x = p.x or p[1]
    local y = p.y or p[2]
    local v = p.value or p[3]
    if x and y and v then
      m = m + 1
      rx[m], ry[m], rv[m] = x * xScale, y * yScale, v * zScale
    end
  end
  if m < 3 then
    return self
  end

  local minX, minY, maxX, maxY = huge, huge, -huge, -huge
  for i = 1, m do
    if rx[i] < minX then minX = rx[i] end
    if ry[i] < minY then minY = ry[i] end
    if rx[i] > maxX then maxX = rx[i] end
    if ry[i] > maxY then maxY = ry[i] end
  end
  if maxX <= minX or maxY <= minY then
    return self
  end
  self.minX, self.minY = minX, minY
  self.maxX, self.maxY = maxX, maxY
  self.sx = 1 / (maxX - minX)
  self.sy = 1 / (maxY - minY)

  local joggle = opts.joggle
  if joggle == nil then joggle = JOGGLE_DEFAULT end
  local px, py, pv = {}, {}, {}
  for i = 1, m do
    local nx = (rx[i] - minX) * self.sx
    local ny = (ry[i] - minY) * self.sy
    if joggle ~= 0 then
      nx = nx + (((i * 12.9898) % 1.0) - 0.5) * 2 * joggle
      ny = ny + (((i * 78.2330) % 1.0) - 0.5) * 2 * joggle
    end
    px[i], py[i], pv[i] = nx, ny, rv[i]
  end

  local dedupTol = opts.dedupTol or DEDUP_TOL
  local dt2 = dedupTol * dedupTol
  local qx, qy, qv = {}, {}, {}
  local n = 0
  for i = 1, m do
    local dup = false
    for j = 1, n do
      local ex = px[i] - qx[j]
      local ey = py[i] - qy[j]
      if ex * ex + ey * ey < dt2 then dup = true; break end
    end
    if not dup then
      n = n + 1
      qx[n], qy[n], qv[n] = px[i], py[i], pv[i]
    end
  end
  if n < 3 then
    return self
  end

  local rawTris = triangulate(qx, qy, n)
  local tris, count, hullEdges = buildTriangles(rawTris, qx, qy, qv, n, minX, minY, self.sx, self.sy)
  if count < 1 then
    return self
  end

  self.tris = tris
  self.triCount = count
  self.hullEdges = hullEdges
  self.valid = true
  return self
end

local function bruteForce(self, x, y)
  local tris = self.tris
  local tol = INSIDE_TOL
  for ti = 1, self.triCount do
    local t = tris[ti]
    local b1 = t[1] * x + t[2] * y + t[3]
    local b2 = t[4] * x + t[5] * y + t[6]
    if b1 >= -tol and b2 >= -tol and b1 + b2 <= 1 + tol then
      return ti
    end
  end
  return 0
end

-- Project onto every hull edge and interpolate along the closest one.
local function nearestHullValue(self, px, py)
  local edges = self.hullEdges
  local bestD = huge
  local bestV = self.defaultValue
  for i = 1, #edges do
    local e = edges[i]
    local x1, y1, v1 = e[1], e[2], e[3]
    local x2, y2, v2 = e[4], e[5], e[6]
    local ex, ey = x2 - x1, y2 - y1
    local len2 = ex * ex + ey * ey
    local tt = 0
    if len2 > 0 then
      tt = ((px - x1) * ex + (py - y1) * ey) / len2
      if tt < 0 then tt = 0 elseif tt > 1 then tt = 1 end
    end
    local cx = x1 + ex * tt
    local cy = y1 + ey * tt
    local ddx = px - cx
    local ddy = py - cy
    local d = ddx * ddx + ddy * ddy
    if d < bestD then
      bestD = d
      bestV = v1 + (v2 - v1) * tt
    end
  end
  return bestV
end

local function outsideValue(self, px, py, ti)
  local mode = self.outsideMode
  if mode == "nil" then return nil end
  if mode == "default" then return self.defaultValue end

  if mode == "clamp" then
    return nearestHullValue(self, px, py)
  end
  if mode == "extrapolate" and ti ~= 0 then
    local t = self.tris[ti]
    local x = px / self.sx + self.minX
    local y = py / self.sy + self.minY
    local b1 = t[1] * x + t[2] * y + t[3]
    local b2 = t[4] * x + t[5] * y + t[6]
    return t[7] + b1 * t[8] + b2 * t[9]
  end
  return self.defaultValue
end

local function rememberResult(self, x, y, result)
  self.lastInputX = x
  self.lastInputY = y
  self.lastOutsideMode = self.outsideMode
  self.lastDefaultValue = self.defaultValue
  self.lastResult = result
  return result
end

local function get(self, x, y)
  if x == self.lastInputX and y == self.lastInputY
     and self.lastOutsideMode == self.outsideMode
     and self.lastDefaultValue == self.defaultValue then
    return self.lastResult
  end

  local n = self.triCount
  if n == 0 then return rememberResult(self, x, y, self.defaultValue) end

  local tris = self.tris
  local tol = INSIDE_TOL
  local cur = self.lastTri
  if cur < 1 or cur > n then cur = 1 end
  local t = tris[cur]
  local b1 = t[1] * x + t[2] * y + t[3]
  local b2 = t[4] * x + t[5] * y + t[6]
  local b12 = b1 + b2

  if b1 >= -tol and b2 >= -tol and b12 <= 1 + tol then
    self.lastTri = cur
    return rememberResult(self, x, y, t[7] + b1 * t[8] + b2 * t[9])
  end

  if self.outsideMode ~= "extrapolate"
     and (x < self.minX or x > self.maxX or y < self.minY or y > self.maxY) then
    local px = (x - self.minX) * self.sx
    local py = (y - self.minY) * self.sy
    return rememberResult(self, x, y, outsideValue(self, px, py, cur))
  end

  local prev = 0
  local maxSteps = n + 8

  for _ = 1, maxSteps do
    -- Avoid immediate backtracking to prevent float-induced cycles.
    local b0 = 1 - b12
    local n1, n2, n3 = t[10], t[11], t[12]
    local nextTri, best = 0, -tol
    if n1 ~= 0 and n1 ~= prev and b0 < best then best = b0; nextTri = n1 end
    if n2 ~= 0 and n2 ~= prev and b1 < best then best = b1; nextTri = n2 end
    if n3 ~= 0 and n3 ~= prev and b2 < best then best = b2; nextTri = n3 end

    if nextTri == 0 then
      best = -tol
      if n1 ~= 0 and b0 < best then best = b0; nextTri = n1 end
      if n2 ~= 0 and b1 < best then best = b1; nextTri = n2 end
      if n3 ~= 0 and b2 < best then best = b2; nextTri = n3 end
    end

    if nextTri == 0 then
      local px = (x - self.minX) * self.sx
      local py = (y - self.minY) * self.sy
      return rememberResult(self, x, y, outsideValue(self, px, py, cur))
    end

    prev = cur
    cur = nextTri
    t = tris[cur]
    b1 = t[1] * x + t[2] * y + t[3]
    b2 = t[4] * x + t[5] * y + t[6]
    b12 = b1 + b2
    if b1 >= -tol and b2 >= -tol and b12 <= 1 + tol then
      self.lastTri = cur
      return rememberResult(self, x, y, t[7] + b1 * t[8] + b2 * t[9])
    end
  end

  -- Degenerate meshes can prevent the directed walk from converging.
  local ti = bruteForce(self, x, y)
  if ti ~= 0 then
    self.lastTri = ti
    local t = tris[ti]
    local b1 = t[1] * x + t[2] * y + t[3]
    local b2 = t[4] * x + t[5] * y + t[6]
    return rememberResult(self, x, y, t[7] + b1 * t[8] + b2 * t[9])
  end
  local px = (x - self.minX) * self.sx
  local py = (y - self.minY) * self.sy
  return rememberResult(self, x, y, outsideValue(self, px, py, cur))
end

-- Returns maximum input-point error and whether it is within tolerance.
local function validate(self, inputData, tolerance)
  tolerance = tolerance or 1e-4
  local maxErr = 0
  for i = 1, #inputData do
    local p = inputData[i]
    local x = p.x or p[1]
    local y = p.y or p[2]
    local v = p.value or p[3]
    if x and y and v then
      local got = self:get(x, y)
      if got ~= nil then
        local e = abs(got - v)
        if e > maxErr then maxErr = e end
      end
    end
  end
  return maxErr, (maxErr <= tolerance)
end

-- Reconstruct triangle corners in input coordinates for debugging and visualization.
local function exportTriangles(self)
  local out = {}
  if self.triCount == 0 then return out end
  local tris = self.tris
  for ti = 1, self.triCount do
    local t = tris[ti]
    local m11, m12, c1 = t[1], t[2], t[3]
    local m21, m22, c2 = t[4], t[5], t[6]
    local detM = m11 * m22 - m12 * m21
    local abx = m22 / detM
    local aby = -m21 / detM
    local acx = -m12 / detM
    local acy = m11 / detM
    local ax = (-m22 * c1 + m12 * c2) / detM
    local ay = (m21 * c1 - m11 * c2) / detM
    local bx, by = ax + abx, ay + aby
    local cx, cy = ax + acx, ay + acy
    local va = t[7]
    out[ti] = {
      ax = ax, ay = ay,
      bx = bx, by = by,
      cx = cx, cy = cy,
      va = va, vb = va + t[8], vc = va + t[9],
    }
  end
  return out
end

local methods = {
  loadData = loadData,
  get = get,
  validate = validate,
  outsideValue = outsideValue,
  bruteForce = bruteForce,
  exportTriangles = exportTriangles,
}

local new = function()
  local r = {
    tris = {},
    triCount = 0,
    hullEdges = {},
    lastTri = 1,
    valid = false,
    outsideMode = "default",
    defaultValue = 0,
    minX = 0, minY = 0,
    maxX = 0, maxY = 0,
    sx = 1, sy = 1,
  }
  return setmetatable(r, { __index = methods })
end

return {
  new = new
}
