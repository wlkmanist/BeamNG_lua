-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Mesh refinement.

local M = {}

-- Module constants.
local sqrt, ceil = math.sqrt, math.ceil

-- Module state.
local tmpP = vec3()
local segA, segB = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }


-- Max over all m stations of the squared (o,dz)->(x,y) point-to-chord distance of column k inside the run [i,j]. Module
-- scope (not nested in decimateCols) so LuaJIT can compile it -- it reads only the module scratch vec3/segments.
local function colMaxDev(ptsA, m, k, i, j)
  local d = 0
  for s = 1, m do
    local ps, as, bs = ptsA[s][k], ptsA[s][i], ptsA[s][j]
    segA.x, segA.y = as.o, as.dz
    segB.x, segB.y = bs.o, bs.dz
    tmpP:set(ps.o, ps.dz, 0)
    local dd = tmpP:squaredDistanceToLineSegment(segA, segB)
    if dd > d then d = dd end
  end
  return d
end

-- Squared deviation of p from the chord a-b, split into its plan and vertical parts, each scaled by the inverse squared tolerance
-- (so > 1 is out of tolerance on either).
local function splitDev(p, a, b, ih2, iz2)
  local abx, aby, abz = b.x - a.x, b.y - a.y, b.z - a.z
  local l2 = abx * abx + aby * aby + abz * abz
  local t = 0
  if l2 > 1e-12 then
    t = ((p.x - a.x) * abx + (p.y - a.y) * aby + (p.z - a.z) * abz) / l2
    t = t < 0 and 0 or (t > 1 and 1 or t)
  end
  local dx, dy, dz = p.x - a.x - abx * t, p.y - a.y - aby * t, p.z - a.z - abz * t
  local h, v = (dx * dx + dy * dy) * ih2, dz * dz * iz2
  return h > v and h or v
end

-- Multi-channel RDP over stations 1..m. With tolZM, tolM bounds the plan deviation only and tolZM the vertical one (a plan chord
-- just moves an edge sideways, while a vertical one is a bump under the wheels).
local function decimateStations(centres, W, numCols, tolM, m, maxSegM, mustKeep, tolZM)
  local tol2 = tolM * tolM
  local ih2, iz2 = 1 / tol2, tolZM and 1 / (tolZM * tolZM)
  local lim = iz2 and 1 or tol2
  local keep = table.new(m, 0)
  for i = 1, m do keep[i] = false end
  keep[1], keep[m] = true, true
  if mustKeep then for i = 2, m - 1 do if mustKeep[i] then keep[i] = true end end end
  if m > 2 then
    local stack, sp = { { 1, m } }, 1
    while sp > 0 do
      local seg = stack[sp]; sp = sp - 1
      local a, b = seg[1], seg[2]
      if b - a >= 2 then
        local ca, cb = centres[a], centres[b]
        local la, lb = W[a][1], W[b][1]
        local ra, rb = W[a][numCols], W[b][numCols]
        local maxD, maxI = -1, -1
        for k = a + 1, b - 1 do
          local ck, lk, rk = centres[k], W[k][1], W[k][numCols]
          local d, dl, dr
          if iz2 then
            d, dl, dr = splitDev(ck, ca, cb, ih2, iz2), splitDev(lk, la, lb, ih2, iz2), splitDev(rk, ra, rb, ih2, iz2)
          else
            tmpP:set(ck.x, ck.y, ck.z); d = tmpP:squaredDistanceToLineSegment(ca, cb)
            tmpP:set(lk.x, lk.y, lk.z); dl = tmpP:squaredDistanceToLineSegment(la, lb)
            tmpP:set(rk.x, rk.y, rk.z); dr = tmpP:squaredDistanceToLineSegment(ra, rb)
          end
          if dl > d then d = dl end
          if dr > d then d = dr end
          if d > maxD then maxD, maxI = d, k end
        end
        if maxD > lim and maxI > 0 then
          keep[maxI] = true
          sp = sp + 1; stack[sp] = { a, maxI }
          sp = sp + 1; stack[sp] = { maxI, b }
        end
      end
    end
  end

  -- Max segment-length cap: re-add original stations to break up any kept gap longer than maxSegM into near-even sub-gaps.
  -- (Best-effort down to the original station spacing -- can't subdivide finer than the full-res grid.)
  if maxSegM and maxSegM > 0 and m > 2 then
    local arc = table.new(m, 0); arc[1] = 0
    for i = 2, m do
      local a, b = centres[i - 1], centres[i]
      local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
      arc[i] = arc[i - 1] + sqrt(dx * dx + dy * dy + dz * dz)
    end
    local prev = 1
    for i = 2, m do
      if keep[i] then
        local L = arc[i] - arc[prev]
        if L > maxSegM then
          local nSub = ceil(L / maxSegM)
          local step = L / nSub
          local k = prev + 1
          for s = 1, nSub - 1 do
            local target = arc[prev] + s * step
            while k < i - 1 and arc[k + 1] <= target do k = k + 1 end
            local kk = k
            if k + 1 <= i - 1 and (arc[k + 1] - target) < (target - arc[k]) then kk = k + 1 end
            keep[kk] = true
          end
        end
        prev = i
      end
    end
  end

  local out, c = table.new(m, 0), 0
  for i = 1, m do if keep[i] then c = c + 1; out[c] = i end end
  return out
end

-- Lateral column decimation. ptsA[s] is station s's cross-section ({o,dz} per column); bandMat has one material per band
-- (between columns c and c+1). Force-keeps col 1, col numCols and every material-band boundary, then RDPs the interior
-- columns using the MAX (o,dz) deviation ACROSS ALL stations -- so a column stays if the profile bends at ANY station
-- (e.g. a crown that fades in bends still keeps its apex columns). Returns a sorted array of kept column indices.
local function decimateCols(ptsA, bandMat, tolM, m)
  local tol2 = tolM * tolM
  local numCols = #ptsA[1]
  local keep = table.new(numCols, 0)
  for i = 1, numCols do keep[i] = false end
  keep[1], keep[numCols] = true, true
  for b = 1, numCols - 2 do -- boundary between band b and b+1 lives at column b+1.
    if bandMat[b] ~= bandMat[b + 1] then keep[b + 1] = true end
  end

  -- RDP each run between consecutive force-kept anchors (keeps every band-boundary as a hard split).
  local anchors, ac = table.new(numCols, 0), 0
  for i = 1, numCols do if keep[i] then ac = ac + 1; anchors[ac] = i end end
  local stack, sp = {}, 0
  for a = 1, ac - 1 do sp = sp + 1; stack[sp] = { anchors[a], anchors[a + 1] } end
  while sp > 0 do
    local seg = stack[sp]; sp = sp - 1
    local i, j = seg[1], seg[2]
    if j - i >= 2 then
      local maxD, maxI = -1, -1
      for k = i + 1, j - 1 do
        local d = colMaxDev(ptsA, m, k, i, j)
        if d > maxD then maxD, maxI = d, k end
      end
      if maxD > tol2 and maxI > 0 then
        keep[maxI] = true
        sp = sp + 1; stack[sp] = { i, maxI }
        sp = sp + 1; stack[sp] = { maxI, j }
      end
    end
  end

  local out, c = table.new(numCols, 0), 0
  for i = 1, numCols do if keep[i] then c = c + 1; out[c] = i end end
  return out
end


-- Public interface.
M.decimateStations = decimateStations
M.decimateCols = decimateCols

return M