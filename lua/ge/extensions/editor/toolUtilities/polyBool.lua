-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- First-party 2D polygon boolean (Martinez-style segment pipeline).
-- Algorithm: F. Martinez (2008); adapted from the MIT polybooljs approach
-- (Sean Connelly / @voidqk). Used by transportNetwork junctions (unionMany).
-- Flat module locals only — no nested functions (LuaJIT closure cost / FNEW).

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')

-- Module constants.
local floor = math.floor
-- Point-comparison tolerance for the whole sweep (coincidence, collinearity, above/below, intersection). Keep it
-- TIGHT. Widening it (a past 1e-4 experiment) is counter-productive: the coincidence tests below then fold
-- genuinely-distinct endpoints together, so real metre-scale edges lose their start-event insertion and trip the
-- orphaned-end path in ixCalculate en masse. At 1e-10 only true numeric duplicates merge, so an orphaned end is a
-- sub-nm twin that is safe to discard (see the st == nil branch in ixCalculate).
local eps = 1e-10

local pointsSame2D = geom.pointsSame2D
local pointsCompare2D = geom.pointsCompare2D
local pointAboveOrOnLine2D = geom.pointAboveOrOnLine2D
local pointsCollinear2D = geom.pointsCollinear2D
local pointBetween2D = geom.pointBetween2D
local linesIntersect2D = geom.linesIntersect2D

-- Scratch compare contexts (reuse; never nest predicate closures).
local eventCtx = { isStart = false, pt = nil, otherPt = nil }
local statusCtx = { ev = nil }

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Point helpers
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function ptCopy(p) return { x = p.x, y = p.y } end

local function ptFrom(p)
  if not p then return nil end
  if p.x then return { x = p.x, y = p.y } end
  return { x = p[1], y = p[2] }
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Doubly-linked list (no methods / no predicate closures)
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function llCreate()
  local root = { root = true, next = nil, prev = nil }
  return { root = root }
end

local function llExists(list, node)
  return node ~= nil and node ~= list.root
end

local function llIsEmpty(list)
  return list.root.next == nil
end

local function llGetHead(list)
  return list.root.next
end

local function llNodeRemove(node)
  if node.prev then node.prev.next = node.next end
  if node.next then node.next.prev = node.prev end
  node.prev, node.next = nil, nil
end

local function llNode(data)
  data.prev = nil
  data.next = nil
  return data
end

-- Insert node before the first node where shouldBefore(here) is true; else append.
-- shouldBefore is a module-level fn(here, ctx) — ctx carries compare state.
local function llInsertBefore(list, node, shouldBefore, ctx)
  local root = list.root
  local last, here = root, root.next
  while here do
    if shouldBefore(here, ctx) then
      node.prev = here.prev
      node.next = here
      here.prev.next = node
      here.prev = node
      return
    end
    last = here
    here = here.next
  end
  last.next = node
  node.prev = last
  node.next = nil
end

-- Find first node where shouldStop(here, ctx); return before/after for insert.
local function llFindTransition(list, shouldStop, ctx)
  local root = list.root
  local prev, here = root, root.next
  while here do
    if shouldStop(here, ctx) then break end
    prev = here
    here = here.next
  end
  return prev, here
end

local function llInsertAt(prev, here, node)
  node.prev = prev
  node.next = here
  prev.next = node
  if here then here.prev = node end
  return node
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Segments
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function segmentNew(start, finish)
  return {
    start = start,
    finish = finish,
    myFill = { above = nil, below = nil },
    otherFill = nil,
  }
end

local function segmentCopy(start, finish, seg)
  return {
    start = start,
    finish = finish,
    myFill = { above = seg.myFill.above, below = seg.myFill.below },
    otherFill = nil,
  }
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Intersecter (explicit state table; all helpers at module scope)
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function ixCreate(selfIntersection)
  return { eventRoot = llCreate(), selfIntersection = selfIntersection }
end

local function ixEventCompare(p1Start, p1a, p1b, p2Start, p2a, p2b)
  local comp = pointsCompare2D(p1a, p2a, eps)
  if comp ~= 0 then return comp end
  if pointsSame2D(p1b, p2b, eps) then return 0 end
  if p1Start ~= p2Start then return p1Start and 1 or -1 end
  local left = p2Start and p2a or p2b
  local right = p2Start and p2b or p2a
  return pointAboveOrOnLine2D(p1b, left, right, eps) and 1 or -1
end

-- ctx = { isStart, pt, otherPt }
local function ixEventShouldBefore(here, ctx)
  return ixEventCompare(ctx.isStart, ctx.pt, ctx.otherPt, here.isStart, here.pt, here.other.pt) < 0
end

local function ixEventAdd(ix, ev, otherPt)
  eventCtx.isStart = ev.isStart
  eventCtx.pt = ev.pt
  eventCtx.otherPt = otherPt
  llInsertBefore(ix.eventRoot, ev, ixEventShouldBefore, eventCtx)
end

local function ixEventAddSegmentStart(ix, seg, primary)
  local evStart = llNode({
    isStart = true,
    pt = seg.start,
    seg = seg,
    primary = primary,
    other = nil,
    status = nil,
  })
  ixEventAdd(ix, evStart, seg.finish)
  return evStart
end

local function ixEventAddSegmentEnd(ix, evStart, seg, primary)
  local evEnd = llNode({
    isStart = false,
    pt = seg.finish,
    seg = seg,
    primary = primary,
    other = evStart,
    status = nil,
  })
  evStart.other = evEnd
  ixEventAdd(ix, evEnd, evStart.pt)
end

local function ixEventAddSegment(ix, seg, primary)
  local evStart = ixEventAddSegmentStart(ix, seg, primary)
  ixEventAddSegmentEnd(ix, evStart, seg, primary)
  return evStart
end

local function ixEventUpdateEnd(ix, ev, finish)
  llNodeRemove(ev.other)
  ev.seg.finish = finish
  ev.other.pt = finish
  ixEventAdd(ix, ev.other, ev.pt)
end

local function ixEventDivide(ix, ev, pt)
  local ns = segmentCopy(pt, ev.seg.finish, ev.seg)
  ixEventUpdateEnd(ix, ev, pt)
  return ixEventAddSegment(ix, ns, ev.primary)
end

local function ixStatusCompare(ev1, ev2)
  local a1, a2 = ev1.seg.start, ev1.seg.finish
  local b1, b2 = ev2.seg.start, ev2.seg.finish
  if pointsCollinear2D(a1, b1, b2, eps) then
    if pointsCollinear2D(a2, b1, b2, eps) then return 1 end
    return pointAboveOrOnLine2D(a2, b1, b2, eps) and 1 or -1
  end
  return pointAboveOrOnLine2D(a1, b1, b2, eps) and 1 or -1
end

-- ctx = { ev }
local function ixStatusShouldStop(here, ctx)
  return ixStatusCompare(ctx.ev, here.ev) > 0
end

local function ixCheckIntersection(ix, ev1, ev2)
  local seg1, seg2 = ev1.seg, ev2.seg
  local a1, a2, b1, b2 = seg1.start, seg1.finish, seg2.start, seg2.finish
  local i = linesIntersect2D(a1, a2, b1, b2, eps)

  if not i then
    if not pointsCollinear2D(a1, a2, b1, eps) then return nil end
    if pointsSame2D(a1, b2, eps) or pointsSame2D(a2, b1, eps) then return nil end

    local a1eqb1 = pointsSame2D(a1, b1, eps)
    local a2eqb2 = pointsSame2D(a2, b2, eps)
    if a1eqb1 and a2eqb2 then return ev2 end

    local a1Between = not a1eqb1 and pointBetween2D(a1, b1, b2, eps)
    local a2Between = not a2eqb2 and pointBetween2D(a2, b1, b2, eps)

    if a1eqb1 then
      if a2Between then ixEventDivide(ix, ev2, a2)
      else ixEventDivide(ix, ev1, b2) end
      return ev2
    elseif a1Between then
      if not a2eqb2 then
        if a2Between then ixEventDivide(ix, ev2, a2)
        else ixEventDivide(ix, ev1, b2) end
      end
      ixEventDivide(ix, ev2, a1)
    end
    return nil
  end

  if i.alongA == 0 then
    if i.alongB == -1 then ixEventDivide(ix, ev1, b1)
    elseif i.alongB == 0 then ixEventDivide(ix, ev1, i.pt)
    elseif i.alongB == 1 then ixEventDivide(ix, ev1, b2) end
  end
  if i.alongB == 0 then
    if i.alongA == -1 then ixEventDivide(ix, ev2, a1)
    elseif i.alongA == 0 then ixEventDivide(ix, ev2, i.pt)
    elseif i.alongA == 1 then ixEventDivide(ix, ev2, a2) end
  end
  return nil
end

local function ixCalculate(ix, primaryInverted, secondaryInverted)
  local statusRoot = llCreate()
  local segments = {}
  local selfIntersection = ix.selfIntersection
  local eventRoot = ix.eventRoot

  while not llIsEmpty(eventRoot) do
    local ev = llGetHead(eventRoot)
    local skipRemove = false

    if ev.isStart then
      statusCtx.ev = ev
      local prev, after = llFindTransition(statusRoot, ixStatusShouldStop, statusCtx)
      local above = (prev ~= statusRoot.root) and prev.ev or nil
      local below = after and after.ev or nil

      local eve = nil
      if above then eve = ixCheckIntersection(ix, ev, above) end
      if not eve and below then eve = ixCheckIntersection(ix, ev, below) end

      if eve then
        if selfIntersection then
          local toggle
          if ev.seg.myFill.below == nil then toggle = true
          else toggle = ev.seg.myFill.above ~= ev.seg.myFill.below end
          if toggle then eve.seg.myFill.above = not eve.seg.myFill.above end
        else
          eve.seg.otherFill = ev.seg.myFill
        end
        llNodeRemove(ev.other)
        llNodeRemove(ev)
      end

      if llGetHead(eventRoot) ~= ev then
        skipRemove = true
      else
        if selfIntersection then
          local toggle
          if ev.seg.myFill.below == nil then toggle = true
          else toggle = ev.seg.myFill.above ~= ev.seg.myFill.below end
          if not below then
            ev.seg.myFill.below = primaryInverted
          else
            ev.seg.myFill.below = below.seg.myFill.above
          end
          if toggle then
            ev.seg.myFill.above = not ev.seg.myFill.below
          else
            ev.seg.myFill.above = ev.seg.myFill.below
          end
        else
          if ev.seg.otherFill == nil then
            local inside
            if not below then
              inside = ev.primary and secondaryInverted or primaryInverted
            else
              if ev.primary == below.primary then
                inside = below.seg.otherFill.above
              else
                inside = below.seg.myFill.above
              end
            end
            ev.seg.otherFill = { above = inside, below = inside }
          end
        end

        ev.other.status = llInsertAt(prev, after, llNode({ ev = ev }))
      end
    else
      local st = ev.status
      -- st == nil: this end event's start was dropped earlier as coincident (within eps) with another point, so
      -- the segment was never inserted on the sweep. With a tight eps that only happens for a true numeric
      -- duplicate of a segment already swept (junction arms legitimately share boundary edges), which contributes
      -- no new boundary. Fall through and let the loop tail discard the event. This MUST be non-fatal: erroring
      -- here aborted the entire junction seal (caller pcall -> empty regions) over a redundant sub-nm sliver.
      if st then
        if llExists(statusRoot, st.prev) and llExists(statusRoot, st.next) then
          ixCheckIntersection(ix, st.prev.ev, st.next.ev)
        end
        llNodeRemove(st)
        if not ev.primary then
          local s = ev.seg.myFill
          ev.seg.myFill = ev.seg.otherFill
          ev.seg.otherFill = s
        end
        segments[#segments + 1] = ev.seg
      end
    end

    if not skipRemove then
      llNodeRemove(llGetHead(eventRoot))
    end
  end

  return segments
end

local function ixAddRegion(ix, region)
  local n = #region
  if n < 2 then return end
  local pt2 = region[n]
  for i = 1, n do
    local pt1 = pt2
    pt2 = region[i]
    local forward = pointsCompare2D(pt1, pt2, eps)
    if forward ~= 0 then
      ixEventAddSegment(
        ix,
        segmentNew(forward < 0 and pt1 or pt2, forward < 0 and pt2 or pt1),
        true
      )
    end
  end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Segment selection
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local SEL_UNION = {
  0, 2, 1, 0,
  2, 2, 0, 0,
  1, 0, 1, 0,
  0, 0, 0, 0,
}

local function selectSegments(segments, selection)
  local result = {}
  for i = 1, #segments do
    local seg = segments[i]
    local index =
      (seg.myFill.above and 8 or 0) +
      (seg.myFill.below and 4 or 0) +
      ((seg.otherFill and seg.otherFill.above) and 2 or 0) +
      ((seg.otherFill and seg.otherFill.below) and 1 or 0)
    local sel = selection[index + 1]
    if sel ~= 0 then
      result[#result + 1] = {
        start = seg.start,
        finish = seg.finish,
        myFill = { above = sel == 1, below = sel == 2 },
        otherFill = nil,
      }
    end
  end
  return result
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Segment chainer
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function reverseChain(chains, index)
  local c = chains[index]
  local n = #c
  for i = 1, floor(n * 0.5) do
    c[i], c[n - i + 1] = c[n - i + 1], c[i]
  end
end

local function appendChain(chains, index1, index2)
  local chain1, chain2 = chains[index1], chains[index2]
  local tail, tail2 = chain1[#chain1], chain1[#chain1 - 1]
  local head, head2 = chain2[1], chain2[2]
  if pointsCollinear2D(tail2, tail, head, eps) then
    table.remove(chain1)
    tail = tail2
  end
  if pointsCollinear2D(tail, head, head2, eps) then
    table.remove(chain2, 1)
  end
  for i = 1, #chain2 do
    chain1[#chain1 + 1] = chain2[i]
  end
  table.remove(chains, index2)
end

local function segmentChainer(segments)
  local chains, regions = {}, {}

  for si = 1, #segments do
    local seg = segments[si]
    local pt1, pt2 = seg.start, seg.finish
    if not pointsSame2D(pt1, pt2, eps) then
      local firstIndex, firstHead, firstPt1 = 0, false, false
      local secondIndex, secondHead, secondPt1 = 0, false, false
      local matchCount = 0

      for i = 1, #chains do
        local chain = chains[i]
        local head = chain[1]
        local tail = chain[#chain]
        local matched = false
        local matchesHead, matchesPt1 = false, false
        if pointsSame2D(head, pt1, eps) then
          matched, matchesHead, matchesPt1 = true, true, true
        elseif pointsSame2D(head, pt2, eps) then
          matched, matchesHead, matchesPt1 = true, true, false
        elseif pointsSame2D(tail, pt1, eps) then
          matched, matchesHead, matchesPt1 = true, false, true
        elseif pointsSame2D(tail, pt2, eps) then
          matched, matchesHead, matchesPt1 = true, false, false
        end
        if matched then
          matchCount = matchCount + 1
          if matchCount == 1 then
            firstIndex, firstHead, firstPt1 = i, matchesHead, matchesPt1
          else
            secondIndex, secondHead, secondPt1 = i, matchesHead, matchesPt1
            break
          end
        end
      end

      if matchCount == 0 then
        chains[#chains + 1] = { ptCopy(pt1), ptCopy(pt2) }
      elseif matchCount == 1 then
        local index = firstIndex
        local pt = firstPt1 and pt2 or pt1
        local addToHead = firstHead
        local chain = chains[index]
        local grow = addToHead and chain[1] or chain[#chain]
        local grow2 = addToHead and chain[2] or chain[#chain - 1]
        local oppo = addToHead and chain[#chain] or chain[1]
        local oppo2 = addToHead and chain[#chain - 1] or chain[2]

        if pointsCollinear2D(grow2, grow, pt, eps) then
          if addToHead then table.remove(chain, 1) else table.remove(chain) end
          grow = grow2
        end

        if pointsSame2D(oppo, pt, eps) then
          table.remove(chains, index)
          if pointsCollinear2D(oppo2, oppo, grow, eps) then
            if addToHead then table.remove(chain) else table.remove(chain, 1) end
          end
          regions[#regions + 1] = chain
        elseif addToHead then
          table.insert(chain, 1, ptCopy(pt))
        else
          chain[#chain + 1] = ptCopy(pt)
        end
      else
        local F, S = firstIndex, secondIndex
        local reverseF = #chains[F] < #chains[S]
        if firstHead then
          if secondHead then
            if reverseF then reverseChain(chains, F); appendChain(chains, F, S)
            else reverseChain(chains, S); appendChain(chains, S, F) end
          else
            appendChain(chains, S, F)
          end
        else
          if secondHead then
            appendChain(chains, F, S)
          else
            if reverseF then reverseChain(chains, F); appendChain(chains, S, F)
            else reverseChain(chains, S); appendChain(chains, F, S) end
          end
        end
      end
    end
  end

  return regions
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Normalize / core API
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function isPointList(t)
  if type(t) ~= 'table' or #t < 1 then return false end
  local p = t[1]
  return type(p) == 'table' and (p.x ~= nil or p[1] ~= nil)
end

local function normalizeRegion(region)
  local out, n = {}, 0
  for i = 1, #region do
    local p = ptFrom(region[i])
    if p then
      if n == 0 or not pointsSame2D(out[n], p, eps) then
        n = n + 1
        out[n] = p
      end
    end
  end
  if n >= 2 and pointsSame2D(out[1], out[n], eps) then
    out[n] = nil
  end
  return out
end

local function normalize(poly)
  if not poly then return { regions = {}, inverted = false } end
  if poly.regions then
    local regions = {}
    for i = 1, #poly.regions do
      local r = normalizeRegion(poly.regions[i])
      if #r >= 3 then regions[#regions + 1] = r end
    end
    return { regions = regions, inverted = poly.inverted and true or false }
  end
  if isPointList(poly) then
    if poly[1] and poly[1].x == nil and poly[1][1] == nil and type(poly[1]) == 'table' and isPointList(poly[1]) then
      local regions = {}
      for i = 1, #poly do
        local r = normalizeRegion(poly[i])
        if #r >= 3 then regions[#regions + 1] = r end
      end
      return { regions = regions, inverted = false }
    end
    local r = normalizeRegion(poly)
    return { regions = #r >= 3 and { r } or {}, inverted = false }
  end
  return { regions = {}, inverted = false }
end

local function segmentsFromPoly(poly)
  poly = normalize(poly)
  local ix = ixCreate(true)
  for r = 1, #poly.regions do
    ixAddRegion(ix, poly.regions[r])
  end
  return { segments = ixCalculate(ix, poly.inverted, false), inverted = poly.inverted }
end

local function combineSegments(seg1, seg2)
  local ix = ixCreate(false)
  local s1, s2 = seg1.segments, seg2.segments
  for i = 1, #s1 do
    local s = s1[i]
    ixEventAddSegment(ix, segmentCopy(s.start, s.finish, s), true)
  end
  for i = 1, #s2 do
    local s = s2[i]
    ixEventAddSegment(ix, segmentCopy(s.start, s.finish, s), false)
  end
  return {
    combined = ixCalculate(ix, seg1.inverted, seg2.inverted),
    inverted1 = seg1.inverted,
    inverted2 = seg2.inverted,
  }
end

local function selectUnion(combined)
  return { segments = selectSegments(combined.combined, SEL_UNION), inverted = combined.inverted1 or combined.inverted2 }
end

local function polygonFromSegments(seg)
  return { regions = segmentChainer(seg.segments), inverted = seg.inverted }
end

local function unionMany(polys)
  if not polys or #polys == 0 then return { regions = {}, inverted = false } end

  -- Work in a LOCAL frame near the origin. Every compare/intersection epsilon in this kernel (and geom)
  -- is ABSOLUTE (1e-10), but junction geometry arrives in WORLD coords (imported terrain sits tens of
  -- thousands of metres from the origin), where 1e-10 is right at float64's resolution. Intersection
  -- points that should coincide then differ by more than eps and a segment collapses mid-sweep -> the
  -- "zero-length segment" error. Shifting to a local origin makes coords small (metres) so the epsilons
  -- behave; the result is shifted straight back. Pure translation: the union shape is unchanged.
  local first = polys[1].regions and polys[1].regions[1] and polys[1].regions[1][1]
  local ox, oy = first and first.x or 0, first and first.y or 0

  local shifted = {}
  for i = 1, #polys do
    local regs, out = polys[i].regions or {}, {}
    for r = 1, #regs do
      local ring, ringOut = regs[r], {}
      for k = 1, #ring do ringOut[k] = { x = ring[k].x - ox, y = ring[k].y - oy } end
      out[r] = ringOut
    end
    shifted[i] = { regions = out, inverted = polys[i].inverted }
  end

  local acc = segmentsFromPoly(shifted[1])
  for i = 2, #shifted do
    local seg2 = segmentsFromPoly(shifted[i])
    local comb = combineSegments(acc, seg2)
    acc = selectUnion(comb)
  end
  local result = polygonFromSegments(acc)

  -- Shift the result back to world coords (fresh points, so no aliasing / double-shift).
  local regs, outRegions = result.regions, {}
  for r = 1, #regs do
    local ring, ringOut = regs[r], {}
    for k = 1, #ring do ringOut[k] = { x = ring[k].x + ox, y = ring[k].y + oy } end
    outRegions[r] = ringOut
  end
  return { regions = outRegions, inverted = result.inverted }
end


-- Public interface.
M.unionMany =                                           unionMany

return M