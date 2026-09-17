-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Guard for the v1/runRepro scheme command. Decides whether a decoded command
-- line may be handed to run_repro.bat, using a Claude-Code-style allowlist of
-- glob patterns. Pure logic in isAllowed (no engine calls) so it is testable in
-- isolation; loadPatterns performs the file IO. The allowlist is read from
-- `ALLOWLIST_PATH`, a VFS-relative path under `DevTools/`.

local M = {}
local logTag = 'reproGuard'

-- Allowlist file (VFS path; lives in the SVN game tree).
local ALLOWLIST_PATH = '/DevTools/tests/micropy/resources/repro_allowlist.json'

-- Characters never allowed anywhere in the command (redirection / escape /
-- command substitution). '^' is escaped as '%^' and placed away from the start
-- of the class so it is not read as negation.
local FORBIDDEN_CHARS = '[<>%^`]'

-- Internal split marker: SOH (byte 0x01), chosen because it cannot occur in a
-- shell command string. NOTE: this is '\1' (a literal byte), NOT '\\1' (which
-- would be a gsub back-reference) — do not "correct" it.
local SPLIT_MARKER = '\1'

-- Convert one allow pattern (with '*' wildcards) into an anchored Lua pattern.
-- Literal characters are escaped; '*' becomes '.*'.
local function globToLuaPattern(glob)
  local out = {}
  for i = 1, #glob do
    local c = glob:sub(i, i)
    if c == '*' then
      out[#out + 1] = '.*'
    else
      -- '*' is handled above; escape every other Lua-pattern magic char as a literal.
      out[#out + 1] = c:gsub('([%^%$%(%)%%%.%[%]%+%-%?])', '%%%1')
    end
  end
  return '^' .. table.concat(out) .. '$'
end

-- Split a command on shell operators (&&, ||, ;, |, &). Returns trimmed,
-- non-empty segments. Multi-char operators are handled before single-char ones.
local function splitSegments(command)
  local tmp = command
  tmp = tmp:gsub('&&', SPLIT_MARKER)
  tmp = tmp:gsub('||', SPLIT_MARKER)
  tmp = tmp:gsub(';', SPLIT_MARKER)
  tmp = tmp:gsub('|', SPLIT_MARKER)
  tmp = tmp:gsub('&', SPLIT_MARKER)
  local segments = {}
  for seg in (tmp .. SPLIT_MARKER):gmatch('(.-)' .. SPLIT_MARKER) do
    seg = seg:gsub('^%s+', '') -- trim leading whitespace only; trailing space stays in the segment and is matched by the glob's '*'
    if seg ~= '' then segments[#segments + 1] = seg end
  end
  return segments
end

-- pure: does `command` satisfy `patterns` (array of glob strings)?
-- returns allowed:boolean, reason:string
function M.isAllowed(command, patterns)
  if type(command) ~= 'string' or command == '' then
    return false, 'empty command'
  end
  if command:find(FORBIDDEN_CHARS) then
    return false, 'forbidden shell metacharacter'
  end
  if type(patterns) ~= 'table' or #patterns == 0 then
    return false, 'empty allowlist'
  end
  local luaPatterns = {}
  for _, p in ipairs(patterns) do
    luaPatterns[#luaPatterns + 1] = globToLuaPattern(p)
  end
  local segments = splitSegments(command)
  if #segments == 0 then
    return false, 'no command segments'
  end
  for _, seg in ipairs(segments) do
    local matched = false
    for _, lp in ipairs(luaPatterns) do
      if seg:match(lp) then matched = true break end
    end
    if not matched then
      return false, 'segment not allowed: ' .. seg
    end
  end
  return true, 'ok'
end

-- IO: read allowlist patterns from the JSON file. Fail closed (empty list).
function M.loadPatterns()
  local data = jsonReadFile(ALLOWLIST_PATH)
  if type(data) ~= 'table' or type(data.permissions) ~= 'table'
      or type(data.permissions.allow) ~= 'table' then
    log('E', logTag, 'allowlist missing/invalid: ' .. ALLOWLIST_PATH)
    return {}
  end
  return data.permissions.allow
end

-- convenience: load patterns from disk and test the command.
function M.isCommandAllowed(command)
  return M.isAllowed(command, M.loadPatterns())
end

return M
