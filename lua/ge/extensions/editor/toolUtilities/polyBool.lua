-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- First-party 2D polygon boolean (Martinez-style segment pipeline), adapted from the MIT polybooljs approach.

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')

-- Module constants.
local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local eps = 1e-10 -- sweep tolerance; keep tight (widening folds distinct endpoints and breaks the coincidence tests).
-- Input grid in the local frame. An edge leaning less than eps per piece reads as vertical once split, and orders its own ends
-- backwards; snapped, an edge is either square or leans by at least this.
local SNAP = 1e-6
-- A clip corner this close to a subject corner is moved onto it. Two outlines offset from the same edge agree only to a few
-- SNAP, and edges that nearly but not exactly coincide make the sweep drop whole rings.
local WELD = 1e-4
local SPLIT_CELL = 4.0 -- bucket size for the corners splitOnto looks up

-- Segment-selection fill tables, indexed by the four fill flags. 1 => output filled above, 2 => below, 0 => discard.
local SEL_UNION = {
  0, 2, 1, 0,
  2, 2, 0, 0,
  1, 0, 1, 0,
  0, 0, 0, 0,
}
local SEL_DIFFERENCE = { -- primary minus secondary: kept side is myFill and not otherFill.
  0, 0, 0, 0,
  2, 0, 2, 0,
  1, 1, 0, 0,
  0, 1, 2, 0,
}

-- Scratch compare contexts (reused; never nest predicate closures).
local eventCtx = { isStart = false, pt = nil, otherPt = nil }
local statusCtx = { ev = nil }


-- Copies a point.
local function ptCopy(p) return { x = p.x, y = p.y } end

-- Normalises a point from {x,y} or {[1],[2]} form; nil passes through.
local function ptFrom(p)
  if not p then return nil end
  if p.x then return { x = p.x, y = p.y } end
  return { x = p[1], y = p[2] }
end

-- Creates an empty list.
local function llCreate()
  local root = { root = true, next = nil, prev = nil }
  return { root = root }
end

-- True if node is a real (non-root) member.
local function llExists(list, node)
  return node ~= nil and node ~= list.root
end

-- True if the list has no nodes.
local function llIsEmpty(list)
  return list.root.next == nil
end

-- Returns the first node.
local function llGetHead(list)
  return list.root.next
end

-- Unlinks a node from its list.
local function llNodeRemove(node)
  if node.prev then node.prev.next = node.next end
  if node.next then node.next.prev = node.prev end
  node.prev, node.next = nil, nil
end

-- Wraps a data table as a fresh (unlinked) node.
local function llNode(data)
  data.prev = nil
  data.next = nil
  return data
end

-- Inserts node before the first entry where shouldBefore(here, ctx) is true, else appends.
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

-- Finds the first node where shouldStop(here, ctx); returns the prev/here pair for an insert.
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

-- Links node between prev and here.
local function llInsertAt(prev, here, node)
  node.prev = prev
  node.next = here
  prev.next = node
  if here then here.prev = node end
  return node
end

-- New segment with empty fill flags.
local function segmentNew(start, finish)
  return {
    start = start,
    finish = finish,
    myFill = { above = nil, below = nil },
    otherFill = nil,
  }
end

-- Copies a segment's endpoints and myFill (otherFill reset).
local function segmentCopy(start, finish, seg)
  return {
    start = start,
    finish = finish,
    myFill = { above = seg.myFill.above, below = seg.myFill.below },
    otherFill = nil,
  }
end

-- New intersecter state.
local function ixCreate(selfIntersection)
  return { eventRoot = llCreate(), selfIntersection = selfIntersection }
end

-- Orders two events by point, then start/end, then above/below.
local function ixEventCompare(p1Start, p1a, p1b, p2Start, p2a, p2b)
  local pointsCompare2D, pointsSame2D, pointAboveOrOnLine2D = geom.pointsCompare2D, geom.pointsSame2D, geom.pointAboveOrOnLine2D
  local comp = pointsCompare2D(p1a, p2a, eps)
  if comp ~= 0 then return comp end
  if pointsSame2D(p1b, p2b, eps) then return 0 end
  if p1Start ~= p2Start then return p1Start and 1 or -1 end
  local left = p2Start and p2a or p2b
  local right = p2Start and p2b or p2a
  return pointAboveOrOnLine2D(p1b, left, right, eps) and 1 or -1
end

-- Event insert predicate; ctx = { isStart, pt, otherPt }.
local function ixEventShouldBefore(here, ctx)
  return ixEventCompare(ctx.isStart, ctx.pt, ctx.otherPt, here.isStart, here.pt, here.other.pt) < 0
end

-- Inserts an event in sweep order.
local function ixEventAdd(ix, ev, otherPt)
  eventCtx.isStart = ev.isStart
  eventCtx.pt = ev.pt
  eventCtx.otherPt = otherPt
  llInsertBefore(ix.eventRoot, ev, ixEventShouldBefore, eventCtx)
end

-- Adds a segment's start event.
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

-- Adds a segment's end event, linked to its start.
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

-- Adds both events for a segment.
local function ixEventAddSegment(ix, seg, primary)
  local evStart = ixEventAddSegmentStart(ix, seg, primary)
  ixEventAddSegmentEnd(ix, evStart, seg, primary)
  return evStart
end

-- Moves an event's end point and re-inserts it.
local function ixEventUpdateEnd(ix, ev, finish)
  llNodeRemove(ev.other)
  ev.seg.finish = finish
  ev.other.pt = finish
  ixEventAdd(ix, ev.other, ev.pt)
end

-- Splits a segment at pt, queueing the tail. A cut on one of the segment's own ends is refused: there is nothing to split
-- off, and the zero length piece it would leave reads as parallel to every segment and collinear with every segment, so it
-- goes on to chop a good edge at a point metres off that edge's own line and the chainer then finds no rings at all.
local function ixEventDivide(ix, ev, pt)
  local pointsSame2D = geom.pointsSame2D
  if pointsSame2D(pt, ev.seg.start, eps) or pointsSame2D(pt, ev.seg.finish, eps) then return nil end
  local ns = segmentCopy(pt, ev.seg.finish, ev.seg)
  ixEventUpdateEnd(ix, ev, pt)
  return ixEventAddSegment(ix, ns, ev.primary)
end

-- Orders two status entries by vertical position.
local function ixStatusCompare(ev1, ev2)
  local pointsCollinear2D, pointAboveOrOnLine2D = geom.pointsCollinear2D, geom.pointAboveOrOnLine2D
  local a1, a2 = ev1.seg.start, ev1.seg.finish
  local b1, b2 = ev2.seg.start, ev2.seg.finish
  if pointsCollinear2D(a1, b1, b2, eps) then
    if pointsCollinear2D(a2, b1, b2, eps) then return 1 end
    return pointAboveOrOnLine2D(a2, b1, b2, eps) and 1 or -1
  end
  return pointAboveOrOnLine2D(a1, b1, b2, eps) and 1 or -1
end

-- Status insert predicate; ctx = { ev }.
local function ixStatusShouldStop(here, ctx)
  return ixStatusCompare(ctx.ev, here.ev) > 0
end

-- Handles the intersection/overlap of two segments, dividing them as needed.
local function ixCheckIntersection(ix, ev1, ev2)
  local linesIntersect2D, pointsCollinear2D, pointsSame2D, pointBetween2D =
    geom.linesIntersect2D, geom.pointsCollinear2D, geom.pointsSame2D, geom.pointBetween2D
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

-- Sweeps the event queue, resolving fill flags; returns the annotated segments.
local function ixCalculate(ix, primaryInverted, secondaryInverted)
  local statusRoot = llCreate()
  local segments = {}
  local selfIntersection = ix.selfIntersection
  local eventRoot = ix.eventRoot

  -- Termination guard: degenerate/overlapping input can re-queue events forever; cap and raise so the caller's pcall falls back.
  local iterGuard, iterCap = 0, 500000

  while not llIsEmpty(eventRoot) do
    iterGuard = iterGuard + 1
    if iterGuard > iterCap then error('polyBool sweep exceeded iteration cap (degenerate/overlapping input)') end
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
              -- Written out rather than as "a and b or c", which silently yields primaryInverted whenever
              -- secondaryInverted is false, which is the usual case.
              if ev.primary then inside = secondaryInverted else inside = primaryInverted end
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
      -- st == nil: this end's start was dropped as coincident (tight eps => a true duplicate edge), so discard it non-fatally.
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

-- Adds every edge of a region as segments.
local function ixAddRegion(ix, region)
  local pointsCompare2D = geom.pointsCompare2D
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

-- Keeps the segments the selection table marks, tagging each output fill side.
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

-- Reverses chain[index] in place.
local function reverseChain(chains, index)
  local c = chains[index]
  local n = #c
  for i = 1, floor(n * 0.5) do
    c[i], c[n - i + 1] = c[n - i + 1], c[i]
  end
end

-- Appends chain2 onto chain1, dropping collinear seams, then removes chain2.
local function appendChain(chains, index1, index2)
  local pointsCollinear2D = geom.pointsCollinear2D
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

-- Stitches the swept segments into closed region rings.
local function segmentChainer(segments)
  local pointsSame2D, pointsCollinear2D = geom.pointsSame2D, geom.pointsCollinear2D
  local chains, regions = {}, {}

  for si = 1, #segments do
    local seg = segments[si]
    local pt1, pt2 = seg.start, seg.finish
    if not pointsSame2D(pt1, pt2, eps) then
      local firstIndex, firstHead, firstPt1 = 0, false, false
      local secondIndex, secondHead = 0, false
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
            secondIndex, secondHead = i, matchesHead
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

-- True if t looks like a list of points.
local function isPointList(t)
  if type(t) ~= 'table' or #t < 1 then return false end
  local p = t[1]
  return type(p) == 'table' and (p.x ~= nil or p[1] ~= nil)
end

-- Drops duplicate and closing points from a region.
local function normalizeRegion(region)
  local pointsSame2D = geom.pointsSame2D
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

-- Coerces flexible input (a { regions }, a single ring, or a list of rings) into { regions, inverted }.
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

-- Builds the self-intersected segment set for one poly.
local function segmentsFromPoly(poly)
  poly = normalize(poly)
  local ix = ixCreate(true)
  for r = 1, #poly.regions do
    ixAddRegion(ix, poly.regions[r])
  end
  return { segments = ixCalculate(ix, poly.inverted, false), inverted = poly.inverted }
end

-- Combines two segment sets into one annotated set.
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

-- Selects the union of a combined set.
local function selectUnion(combined)
  return { segments = selectSegments(combined.combined, SEL_UNION), inverted = combined.inverted1 or combined.inverted2 }
end

-- Selects the difference of a combined set.
local function selectDifference(combined)
  return { segments = selectSegments(combined.combined, SEL_DIFFERENCE), inverted = combined.inverted1 and not combined.inverted2 }
end

-- Chains a selected segment set back into regions.
local function polygonFromSegments(seg)
  return { regions = segmentChainer(seg.segments), inverted = seg.inverted }
end

-- A ring moved into the local frame and onto the input grid.
local function toLocal(ring, ox, oy)
  local out = {}
  for k = 1, #ring do
    out[k] = { x = floor((ring[k].x - ox) / SNAP + 0.5) * SNAP, y = floor((ring[k].y - oy) / SNAP + 0.5) * SNAP }
  end
  return out
end

-- Moves every corner of `clip` that lies within WELD of a corner of `subject` onto that corner, in place.
local function weld(subject, clip)
  local cells = {}
  for r = 1, #subject.regions do
    local ring = subject.regions[r]
    for k = 1, #ring do
      local p = ring[k]
      cells[floor(p.x / WELD) * 1e8 + floor(p.y / WELD)] = p
    end
  end
  for r = 1, #clip.regions do
    local ring = clip.regions[r]
    for k = 1, #ring do
      local p = ring[k]
      local cx, cy, best, bd = floor(p.x / WELD), floor(p.y / WELD), nil, WELD * WELD
      for dx = -1, 1 do
        for dy = -1, 1 do
          local s = cells[(cx + dx) * 1e8 + cy + dy]
          if s then
            local d = (s.x - p.x) ^ 2 + (s.y - p.y) ^ 2
            if d <= bd then best, bd = s, d end
          end
        end
      end
      if best then p.x, p.y = best.x, best.y end
    end
  end
end

-- Adds every corner of `from` lying within WELD of an edge of `into`, short of its ends, to that edge. Two outlines cut
-- from the same road edge run along one line a hair apart; sharing every corner on it, they are one edge to the sweep.
local function splitOnto(into, from)
  local cells = {}
  for r = 1, #from.regions do
    local ring = from.regions[r]
    for k = 1, #ring do
      local p = ring[k]
      local key = floor(p.x / SPLIT_CELL) * 1e8 + floor(p.y / SPLIT_CELL)
      local list = cells[key]
      if not list then list = {} cells[key] = list end
      list[#list + 1] = p
    end
  end
  local w2 = WELD * WELD
  for r = 1, #into.regions do
    local ring, out = into.regions[r], {}
    local n = #ring
    for k = 1, n do
      local a, b = ring[k], ring[k % n + 1]
      out[#out + 1] = a
      local dx, dy = b.x - a.x, b.y - a.y
      local L2 = dx * dx + dy * dy
      if L2 > w2 then
        local hits
        for cx = floor((min(a.x, b.x) - WELD) / SPLIT_CELL), floor((max(a.x, b.x) + WELD) / SPLIT_CELL) do
          for cy = floor((min(a.y, b.y) - WELD) / SPLIT_CELL), floor((max(a.y, b.y) + WELD) / SPLIT_CELL) do
            local list = cells[cx * 1e8 + cy]
            for i = 1, (list and #list or 0) do
              local p = list[i]
              local t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2
              local ex, ey = a.x + dx * t - p.x, a.y + dy * t - p.y
              if t > 0 and t < 1 and ex * ex + ey * ey <= w2
                 and (p.x - a.x) ^ 2 + (p.y - a.y) ^ 2 > w2 and (p.x - b.x) ^ 2 + (p.y - b.y) ^ 2 > w2 then
                hits = hits or {}
                hits[#hits + 1] = { t = t, p = p }
              end
            end
          end
        end
        if hits then
          table.sort(hits, function(u, v) return u.t < v.t end)
          for i = 1, #hits do out[#out + 1] = { x = hits[i].p.x, y = hits[i].p.y } end
        end
      end
    end
    into.regions[r] = out
  end
end

-- Unions many polys. Works in a local frame near the origin so the absolute epsilon does not underflow at world coords.
local function unionMany(polys)
  if not polys or #polys == 0 then return { regions = {}, inverted = false } end

  local first = polys[1].regions and polys[1].regions[1] and polys[1].regions[1][1]
  local ox, oy = first and first.x or 0, first and first.y or 0

  local shifted = {}
  for i = 1, #polys do
    local regs, out = polys[i].regions or {}, {}
    for r = 1, #regs do out[r] = toLocal(regs[r], ox, oy) end
    shifted[i] = { regions = out, inverted = polys[i].inverted }
  end

  local acc = segmentsFromPoly(shifted[1])
  for i = 2, #shifted do
    local seg2 = segmentsFromPoly(shifted[i])
    acc = selectUnion(combineSegments(acc, seg2))
  end
  local result = polygonFromSegments(acc)

  local regs, outRegions = result.regions, {}
  for r = 1, #regs do
    local ring, ringOut = regs[r], {}
    for k = 1, #ring do ringOut[k] = { x = ring[k].x + ox, y = ring[k].y + oy } end
    outRegions[r] = ringOut
  end
  return { regions = outRegions, inverted = result.inverted }
end

-- Boolean difference: subject minus clip; accepts the same flexible input as normalize. Local-frame like unionMany.
local function difference(subject, clip)
  local a, b = normalize(subject), normalize(clip)
  if #a.regions == 0 then return { regions = {}, inverted = a.inverted } end
  if #b.regions == 0 then return { regions = a.regions, inverted = a.inverted } end -- nothing to subtract

  local first = a.regions[1] and a.regions[1][1]
  local ox, oy = first and first.x or 0, first and first.y or 0

  local sa = { regions = {}, inverted = a.inverted }
  for r = 1, #a.regions do sa.regions[r] = toLocal(a.regions[r], ox, oy) end
  local sb = { regions = {}, inverted = b.inverted }
  for r = 1, #b.regions do sb.regions[r] = toLocal(b.regions[r], ox, oy) end
  weld(sa, sb)
  splitOnto(sa, sb)
  splitOnto(sb, sa)

  local comb = combineSegments(segmentsFromPoly(sa), segmentsFromPoly(sb))
  local result = polygonFromSegments(selectDifference(comb))

  local outRegions = {}
  for r = 1, #result.regions do
    local ring, ringOut = result.regions[r], {}
    for k = 1, #ring do ringOut[k] = { x = ring[k].x + ox, y = ring[k].y + oy } end
    outRegions[r] = ringOut
  end
  return { regions = outRegions, inverted = result.inverted }
end


--- A point to test a ring's nesting by: the midpoint of its longest edge. ON the boundary rather than inside it, which is
--- what makes it cheap -- a ring is never asked about itself, and every other ring gives a clean answer for a point on some
--- unrelated outline.
local function probePoint(r)
  local n, bi, bl = #r, 1, -1
  for i = 1, n do
    local a, b = r[i], r[i % n + 1]
    local l = (b.x - a.x) ^ 2 + (b.y - a.y) ^ 2
    if l > bl then bi, bl = i, l end
  end
  local a, b = r[bi], r[bi % n + 1]
  return (a.x + b.x) * 0.5, (a.y + b.y) * 0.5
end

local function wind(r, wantCCW)
  if (geom.ringSignedArea2(r) >= 0) ~= wantCCW then
    for a = 1, floor(#r * 0.5) do r[a], r[#r - a + 1] = r[#r - a + 1], r[a] end
  end
  return r
end

--- Sort a boolean result's flat ring list into outer rings each carrying its own holes, wound CCW outside and CW inside so a
--- triangulator can take them as they come. Nesting is by containment depth: even is solid, odd is a hole.
---
--- The companion to `difference` -- subtracting one shape from another is what produces a ring list that has to be read this
--- way, and every caller that cuts real ground out of real ground needs the same answer from it.
local function areas(regions)
  local rings = {}
  for i = 1, #regions do
    local r = regions[i]
    if r and #r >= 3 and abs(geom.ringSignedArea2(r)) > 1e-9 then rings[#rings + 1] = r end
  end
  local px, py = {}, {}
  for i = 1, #rings do px[i], py[i] = probePoint(rings[i]) end

  local depth = {}
  for i = 1, #rings do
    local d = 0
    for k = 1, #rings do
      if k ~= i and geom.pointInRing2D(px[i], py[i], rings[k]) then d = d + 1 end
    end
    depth[i] = d
  end

  local out = {}
  for i = 1, #rings do
    if depth[i] % 2 == 0 then out[i] = { ring = wind(rings[i], true), holes = {} } end
  end
  -- A hole belongs to the DEEPEST ring that contains it, which is its immediate parent rather than some ring further out.
  for i = 1, #rings do
    if depth[i] % 2 == 1 then
      local best = nil
      for k = 1, #rings do
        if out[k] and geom.pointInRing2D(px[i], py[i], rings[k])
           and (not best or depth[k] > depth[best]) then best = k end
      end
      if best then
        local t = out[best].holes
        t[#t + 1] = wind(rings[i], false)
      end
    end
  end

  local list = {}
  for i = 1, #rings do
    if out[i] then list[#list + 1] = out[i] end
  end
  return list
end


-- Public interface.
M.unionMany = unionMany
M.difference = difference
M.areas = areas

return M