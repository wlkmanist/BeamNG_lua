-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- extensions.utils_simpleProfiler_report.createReport('vehicle_spawn.html')

local M = {}

local lustache = require('common/libs/lustach/src/lustache')

local templateFile = "lua/common/utils/simpleProfiler/interactiveBarChart.mustache.html"

local function mdEscapeCode(s)
  s = tostring(s or "")
  -- keep it simple: avoid breaking inline code formatting
  s = string.gsub(s, "`", "'")
  s = string.gsub(s, "\r", "")
  return s
end

local function getSummaryMdFilename(htmlFilename)
  if not htmlFilename or htmlFilename == "" then return "profilerReport.summary.md" end
  if string.match(htmlFilename, "%.html$") then
    return string.gsub(htmlFilename, "%.html$", ".summary.md")
  end
  return htmlFilename .. ".summary.md"
end

local function computeSelfDuration(node)
  if not node then return 0 end
  if type(node.selfDuration) == "number" then
    return node.selfDuration
  end
  local children = node.children
  if type(children) ~= "table" then
    return tonumber(node.duration) or 0
  end
  local childSum = 0
  for _, c in ipairs(children) do
    childSum = childSum + (tonumber(c.duration) or 0)
  end
  local sd = (tonumber(node.duration) or 0) - childSum
  if sd < 0 then sd = 0 end
  return sd
end

local function aggregateTree(node, agg)
  if not node then return end
  local name = node.name
  if type(name) == "string" and name ~= "" and name ~= "root" then
    local a = agg[name]
    if not a then
      a = { total = 0, self = 0, calls = 0, maxTotal = 0, maxSelf = 0 }
      agg[name] = a
    end
    local dur = tonumber(node.duration) or 0
    local selfDur = computeSelfDuration(node)
    a.total = a.total + dur
    a.self = a.self + selfDur
    a.calls = a.calls + 1
    if dur > a.maxTotal then a.maxTotal = dur end
    if selfDur > a.maxSelf then a.maxSelf = selfDur end
  end

  local children = node.children
  if type(children) == "table" then
    for _, c in ipairs(children) do
      aggregateTree(c, agg)
    end
  end
end

local function writeAiSummaryMarkdown(mdFilename, reportTitle, root, durationFilterSec, meta)
  local stats = (root and root.stats) or {}
  local duration = tonumber(stats.duration) or 0
  local eventCount = tonumber(stats.eventCount) or 0
  local filteredCount = tonumber(stats.filteredCount) or 0
  local startTime = tonumber(stats.startTime) or 0
  local endTime = tonumber(stats.endTime) or 0

  local topN = (meta and type(meta.topN) == "number") and meta.topN or 30
  if topN < 1 then topN = 30 end

  local function safeAvg(total, calls)
    if not calls or calls <= 0 then return 0 end
    return total / calls
  end

  local function startsWith(s, prefix)
    return type(s) == "string" and string.sub(s, 1, #prefix) == prefix
  end

  local out = ""
  out = out .. string.format("# %s (AI summary)\n\n", reportTitle or "Profiler Summary")
  out = out .. string.format("- generated: %s\n", os.date("%Y-%m-%d %H:%M:%S"))
  out = out .. string.format("- output: `%s`\n\n", mdFilename)

  out = out .. "## Session\n\n"
  out = out .. string.format("- time range: %.6fs .. %.6fs\n", startTime, endTime)
  out = out .. string.format("- duration: **%.6fs**\n", duration)
  out = out .. string.format("- events: **%d** (filtered subtrees: %d)\n", eventCount, filteredCount)
  out = out .. string.format("- durationFilterSec: %.6fs\n\n", tonumber(durationFilterSec) or 0)

  if meta then
    out = out .. "## Cache state\n\n"

    if meta.jbeamCached ~= nil then
      out = out .. string.format("- jbeamCached: **%s**\n", tostring(meta.jbeamCached))
    end

    local mcs = meta.meshCacheSummary
    if type(mcs) == "table" then
      if mcs.percentLoaded ~= nil then out = out .. string.format("- meshCache: percentLoaded=%.2f%%\n", tonumber(mcs.percentLoaded) or 0) end
      if mcs.totalFiles ~= nil then out = out .. string.format("- meshCache: totalFiles=%d\n", tonumber(mcs.totalFiles) or 0) end
      if mcs.loadedFiles ~= nil then out = out .. string.format("- meshCache: loadedFiles=%d\n", tonumber(mcs.loadedFiles) or 0) end
      if mcs.filesAlreadyInCache ~= nil then out = out .. string.format("- meshCache: filesAlreadyInCache=%d\n", tonumber(mcs.filesAlreadyInCache) or 0) end
      if mcs.totalMeshes ~= nil then out = out .. string.format("- meshCache: totalMeshes=%d\n", tonumber(mcs.totalMeshes) or 0) end
      if mcs.loadedMeshes ~= nil then out = out .. string.format("- meshCache: loadedMeshes=%d\n", tonumber(mcs.loadedMeshes) or 0) end
    end

    out = out .. "\n"
  end

  out = out .. "## Interpretation notes\n\n"
  out = out .. "- **totalDuration**: inclusive time (includes children)\n"
  out = out .. "- **selfDuration**: exclusive time (total minus direct children)\n"
  out = out .. "- Nodes are aggregated by exact event name string\n\n"

  local agg = {}
  if root and type(root.children) == "table" then
    for _, c in ipairs(root.children) do
      aggregateTree(c, agg)
    end
  end

  local rows = {}
  for name, a in pairs(agg) do
    rows[#rows + 1] = { name = name, total = a.total, self = a.self, calls = a.calls, maxTotal = a.maxTotal, maxSelf = a.maxSelf }
  end

  local bySelf = {}
  local byTotal = {}
  for i = 1, #rows do
    bySelf[i] = rows[i]
    byTotal[i] = rows[i]
  end
  table.sort(bySelf, function(a, b) return a.self > b.self end)
  table.sort(byTotal, function(a, b) return a.total > b.total end)

  out = out .. "## Top by selfDuration (exclusive hotspots)\n\n"
  out = out .. "| rank | name | selfDuration (s) | self% | calls | maxSelf (s) |\n"
  out = out .. "|---:|---|---:|---:|---:|---:|\n"
  for i = 1, math.min(#bySelf, topN) do
    local r = bySelf[i]
    local pct = (duration > 0) and (100 * r.self / duration) or 0
    out = out .. string.format("| %d | `%s` | %.6f | %.2f%% | %d | %.6f |\n",
      i, mdEscapeCode(r.name), r.self, pct, r.calls, r.maxSelf)
  end
  out = out .. "\n"

  out = out .. "## Top by totalDuration (inclusive hotspots)\n\n"
  out = out .. "| rank | name | totalDuration (s) | total% | calls | maxTotal (s) |\n"
  out = out .. "|---:|---|---:|---:|---:|---:|\n"
  for i = 1, math.min(#byTotal, topN) do
    local r = byTotal[i]
    local pct = (duration > 0) and (100 * r.total / duration) or 0
    out = out .. string.format("| %d | `%s` | %.6f | %.2f%% | %d | %.6f |\n",
      i, mdEscapeCode(r.name), r.total, pct, r.calls, r.maxTotal)
  end
  out = out .. "\n"

  local byCalls = {}
  local byMaxSelf = {}
  local byMaxTotal = {}
  for i = 1, #rows do
    byCalls[i] = rows[i]
    byMaxSelf[i] = rows[i]
    byMaxTotal[i] = rows[i]
  end
  table.sort(byCalls, function(a, b) return a.calls > b.calls end)
  table.sort(byMaxSelf, function(a, b) return a.maxSelf > b.maxSelf end)
  table.sort(byMaxTotal, function(a, b) return a.maxTotal > b.maxTotal end)

  out = out .. "## Top by call count (hot loops)\n\n"
  out = out .. "| rank | name | calls | self (s) | avgSelf (us) | maxSelf (us) |\n"
  out = out .. "|---:|---|---:|---:|---:|---:|\n"
  for i = 1, math.min(#byCalls, topN) do
    local r = byCalls[i]
    out = out .. string.format("| %d | `%s` | %d | %.6f | %.2f | %.2f |\n",
      i,
      mdEscapeCode(r.name),
      r.calls,
      r.self,
      safeAvg(r.self, r.calls) * 1e6,
      (r.maxSelf or 0) * 1e6)
  end
  out = out .. "\n"

  out = out .. "## Spiky events (max selfDuration)\n\n"
  out = out .. "| rank | name | maxSelf (ms) | calls | self (s) | total (s) |\n"
  out = out .. "|---:|---|---:|---:|---:|---:|\n"
  for i = 1, math.min(#byMaxSelf, topN) do
    local r = byMaxSelf[i]
    out = out .. string.format("| %d | `%s` | %.3f | %d | %.6f | %.6f |\n",
      i, mdEscapeCode(r.name), (r.maxSelf or 0) * 1e3, r.calls, r.self, r.total)
  end
  out = out .. "\n"

  out = out .. "## Spiky events (max totalDuration)\n\n"
  out = out .. "| rank | name | maxTotal (ms) | calls | total (s) | self (s) |\n"
  out = out .. "|---:|---|---:|---:|---:|---:|\n"
  for i = 1, math.min(#byMaxTotal, topN) do
    local r = byMaxTotal[i]
    out = out .. string.format("| %d | `%s` | %.3f | %d | %.6f | %.6f |\n",
      i, mdEscapeCode(r.name), (r.maxTotal or 0) * 1e3, r.calls, r.total, r.self)
  end
  out = out .. "\n"

  out = out .. "## I/O-related (readFile*/readFiles*)\n\n"
  out = out .. "| name | calls | total (s) | self (s) | avgSelf (us) |\n"
  out = out .. "|---|---:|---:|---:|---:|\n"
  local ioHits = 0
  for i = 1, #byTotal do
    local r = byTotal[i]
    if startsWith(r.name, "readFile") or startsWith(r.name, "readFiles") then
      ioHits = ioHits + 1
      out = out .. string.format("| `%s` | %d | %.6f | %.6f | %.2f |\n",
        mdEscapeCode(r.name), r.calls, r.total, r.self, safeAvg(r.self, r.calls) * 1e6)
      if ioHits >= 20 then break end
    end
  end
  out = out .. "\n"

  writeFile(mdFilename, out)
  return true
end

--------------------------------------------------------------------------------
-- The main function for generating a flame chart / HTML report
--------------------------------------------------------------------------------
local function createReport(filebasename, reportTitle, meta)
  if not simpleProfilerGetJournal then
    log('E','simpleProfilerReport',"simpleProfiler is not available.")
    return
  end

  filebasename = filebasename or 'profilerReport'
  log('I','simpleProfilerReport',"Creating report for " .. filebasename .. " ...")
  -- duration filter (seconds) can be provided via meta; default to 0 (no filter)
  local durationFilterSec = (meta and type(meta.durationFilterSec) == 'number') and meta.durationFilterSec or 0
  local root = simpleProfilerGetJournal(true, durationFilterSec) or { children = {}, stats = {} }
  -- allow passing through metadata to template via root and include the used filter
  local metaTbl = meta or {}
  metaTbl.durationFilterSec = durationFilterSec
  root.meta = metaTbl

  local dataForTemplate = {
    reportTitle = reportTitle or 'Profiler Summary',
    date        = os.date("%Y-%m-%d %H:%M:%S"),
    totalTimeString = string.format("%.3f", root.stats.duration or 0),
    profilerJSON = jsonEncode(root),
    vehicleName = (meta and meta.vehicleName) or 'Unknown',
  }

  local templateStr = readFile(templateFile)
  if not templateStr then
    log('E','simpleProfilerReport',"Failed to read template file: "..tostring(templateFile))
    return
  end

  local html = lustache:render(templateStr, dataForTemplate)
  local htmlPath = filebasename .. '.html'
  writeFile(htmlPath, html)
  log('I', 'simpleProfilerReport', 'Report created: ' .. htmlPath)

  -- Always emit an AI-friendly markdown summary next to the HTML.
  local mdPath = getSummaryMdFilename(htmlPath)
  writeAiSummaryMarkdown(mdPath, reportTitle or 'Profiler Summary', root, durationFilterSec, meta)
  log('I', 'simpleProfilerReport', 'Summary created: ' .. mdPath)
end


M.createReport = createReport

return M