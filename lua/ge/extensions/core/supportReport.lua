-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local lastReportFile = 'settings/lastSupportReport.json'
local reportLifetime = 15 * 60 -- seconds the support ID is shown, then forgotten
local lastReport -- { supportId, time }
local sending = false
local lastError = ''
local lastOutdated = false

local function forgetExpiredReport()
  if lastReport and os.time() - (lastReport.time or 0) >= reportLifetime then
    lastReport = nil
    FS:removeFile(lastReportFile)
  end
end

-- server errors can be whole html pages (e.g. a proxy's 502 page)
local function toPlainText(text)
  local title = text:match('<title>%s*(.-)%s*</title>')
  if title and title ~= '' then return title end
  return trim((text:gsub('<[^>]*>', ' '):gsub('%s+', ' ')))
end

local function requestState()
  forgetExpiredReport()
  guihooks.trigger('SupportReportState', {
    sending = sending,
    supportId = lastReport and lastReport.supportId or '',
    expires = lastReport and lastReport.time + reportLifetime or 0,
    error = toPlainText(lastError),
    outdated = lastOutdated,
  })
end

local function send()
  if sending then return end
  sending = true
  lastError = ''
  lastOutdated = false
  Engine.SupportReport.send()
  requestState()
end

local function onSupportReportSent(supportId, err, outdated)
  sending = false
  if supportId ~= '' then
    lastReport = { supportId = supportId, time = os.time() }
    jsonWriteFile(lastReportFile, lastReport, true)
  else
    lastError = err
    lastOutdated = outdated
  end
  requestState()
end

local function onExtensionLoaded()
  lastReport = jsonReadFile(lastReportFile)
  forgetExpiredReport()
end

M.send = send
M.requestState = requestState
M.onSupportReportSent = onSupportReportSent
M.onExtensionLoaded = onExtensionLoaded

return M
