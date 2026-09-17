-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Loader for the mcp tool modules. Discovers lua/ge/extensions/mcp/tools/*.lua and
-- merges each module into this one. A category module returns a table with:
--   - tool functions: M.<name>(args) -> (text, isError)  (exposed as MCP tools)
--   - schemas: optional per-tool metadata
--   - cb: optional callbacks, exposed under mcp_tools._cb (for JS / vehicle-VM round-trips)
--   - onUpdate / onInstabilityDetected: optional hooks, fanned out below
-- Edits to category files are picked up by reload_lua (full VM reload).

local M = { dependencies = { 'core_vehicles', 'core_vehicle_manager' } }
M.schemas = {}
M._cb = {}

-- Extension hooks a category module may expose; the loader fans each out to all modules.
local HOOKS = { 'onUpdate', 'onPreRender', 'onInstabilityDetected' }
local hookFns = {}
for _, h in ipairs(HOOKS) do hookFns[h] = {} end

local function loadCategories()
  for _, file in ipairs(FS:findFiles('/lua/ge/extensions/mcp/tools', "*.lua", 1, false, false)) do
    local _, name = path.splitWithoutExt(file)
    local ok, mod = pcall(require, 'mcp/tools/' .. name)
    if not ok or type(mod) ~= 'table' then
      log('E', 'mcp_tools', 'failed to load tool module "' .. name .. '": ' .. tostring(mod))
    else
      for k, v in pairs(mod) do
        if type(v) == 'function' and not k:match('^on%u') then M[k] = v end -- tool functions only
      end
      for k, v in pairs(mod.schemas or {}) do M.schemas[k] = v end
      for k, v in pairs(mod.cb or {}) do M._cb[k] = v end
      for _, h in ipairs(HOOKS) do if mod[h] then table.insert(hookFns[h], mod[h]) end end
    end
  end
end
loadCategories()

for _, h in ipairs(HOOKS) do
  M[h] = function(...) for _, f in ipairs(hookFns[h]) do f(...) end end
end

return M
