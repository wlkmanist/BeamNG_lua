--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

local M = {}

local expressionParser = require("jbeam/expressionParser")
local jbeamTableSchema = require('jbeam/tableSchema')

local min, max = math.min, math.max
local str_byte, str_sub, str_match, str_gmatch = string.byte, string.sub, string.match, string.gmatch

local debugParts = false -- set this to true to dump the parts to disk for manual inspection

-- lookup a value in a table using a path
local function getValueFromPath(rootTable, path, enforcedFirstKey)
  if enforcedFirstKey and rootTable then
    local firstKey = str_match(path, "[^.]+")
    if firstKey ~= enforcedFirstKey then
      log('E', 'component', 'path not starting with "' .. tostring(enforcedFirstKey) .. '" [' .. tostring(path) .. '] - rejecting.')
      return nil
    end
  end

  local current = rootTable
  for part in str_gmatch(path, "[^.]+") do
    if current[part] ~= nil then
      current = current[part]
    else
      -- The path does not exist in the table
      return nil
    end
  end
  return current
end


-- Resolve "$..." strings used in jbeam values/keys.
-- Returns (resolvedValue, didChange)
-- Notes:
-- - "$=" is always evaluated (even when assignEqualsOnly=true)
-- - "$>>" component redirects are only allowed for VALUES (never for keys)
-- - missing variables resolve to nil (and log an error), matching previous behavior
local function resolveJbeamVarString(s, vars, assignEqualsOnly, rootData, allowComponentRedirect)
  if type(s) ~= "string" or str_byte(s, 1) ~= 36 then return s, false end -- $

  local secondChar = str_byte(s, 2)
  if secondChar == 61 then -- =
    return expressionParser.parseSafe(s, vars), true
  end

  if assignEqualsOnly then return s, false end

  -- component handling START
  if allowComponentRedirect and secondChar == 62 and str_byte(s, 3) == 62 then -- $>>
    local componentKey = str_sub(s, 4)
    local new_val = getValueFromPath(rootData, componentKey, 'components')
    if new_val == nil then
      log('E', 'component', 'path not found: "' .. tostring(componentKey) .. '"')
      return nil, true
    end
    log('I', 'component', 'path processed: "' .. tostring(componentKey) .. '" = ' .. dumps(new_val))
    return deepcopy(new_val), true
  end
  -- component handling END

  if secondChar == 46 then -- $.
    return (vars['$prefix'] or '') .. str_sub(s, 3) .. (vars['$suffix'] or ''), true
  end

  if secondChar ~= 43 and secondChar ~= 60 and secondChar ~= 62 and (allowComponentRedirect or secondChar ~= 42) then -- + < > * exclude merge indicators
    local val = vars[s]
    if val == nil then
      log('E', "jbeam.applyVariables", "missing variable "..tostring(s))
      return nil, true
    end
    if type(val) == "table" then return val.val, true end
    return val, true
  end

  return s, false
end

-- apply variable replacements into a table
-- when assignEqualsOnly is true, only "$=" expressions are evaluated;
--   plain "$var" and component redirects "$>>" are ignored to avoid
--   renaming keys (used for processing variables lists safely)
-- when traverseVariablesForKeysOnly is true, we still traverse nested 'variables' tables
-- to allow renaming $... KEYS there, but we do not resolve values inside those tables.
local function apply(data, vars, assignEqualsOnly, traverseVariablesForKeysOnly)
  -- this is also doing components now, so always need to run
  local stackidx = 2
  local stack = {data}
  local stackProcessValues = {true}
  while stackidx > 1 do
    stackidx = stackidx - 1
    local d = stack[stackidx]
    local processValues = stackProcessValues[stackidx]
    local keyRenames = nil
    for key, v in pairs(d) do
      -- allow variables on keys too (unless we explicitly only want to evaluate "$=" inside variables lists)
      if type(key) == "string" and str_byte(key, 1) == 36 then -- $
        local newKey, changed = resolveJbeamVarString(key, vars, assignEqualsOnly, data, false) -- do not allow $>> on keys
        if changed and newKey ~= nil and newKey ~= key then
          if keyRenames == nil then keyRenames = {} end
          keyRenames[#keyRenames + 1] = {key, newKey}
        end
      end

      local typev = type(v)
      if processValues and typev == "string" then
        local newVal, changed = resolveJbeamVarString(v, vars, assignEqualsOnly, data, true)
        if changed then d[key] = newVal end
      elseif typev == 'table' then
        if key ~= 'variables' then
          stack[stackidx] = v
          stackProcessValues[stackidx] = processValues
          stackidx = stackidx + 1
        elseif traverseVariablesForKeysOnly then
          -- keep old components behavior: allow renaming $... keys inside variables tables,
          -- but do not resolve values there
          stack[stackidx] = v
          stackProcessValues[stackidx] = false
          stackidx = stackidx + 1
        end
      end
    end

    if keyRenames ~= nil then
      for _, r in ipairs(keyRenames) do
        local oldKey, newKey = r[1], r[2]
        if d[oldKey] ~= nil then
          if d[newKey] ~= nil then
            -- collisions can happen when multiple $... keys resolve to the same final key:
            -- warn and overwrite deterministically with the renamed value.
            log('W', 'jbeam.applyVariables', 'key rename collision: ' .. tostring(oldKey) .. ' -> ' .. tostring(newKey) .. ' (overwriting)')
          end
          d[newKey] = d[oldKey]
          d[oldKey] = nil
        end
      end
    end
  end
end

-- processes the slot variables repeatedly until they are all resolved
-- resolves slot-scope variables repeatedly against a parent scope
local function applySlotVars(slotVars, _vars)
  if tableIsEmpty(_vars) then return deepcopy(slotVars) end
  local vars = deepcopy(_vars)
  local succeed = {}
  for iters = 1, 400 do
    local passed = false
    for k, v in pairs(slotVars) do
      if str_byte(v,1) == 36 then -- $
        local secondChar = str_byte(v,2)
        if secondChar == 61 then -- =
          local ok, res = pcall(expressionParser.parse, v, vars)
          if ok then
            passed = true
            succeed[k] = res
            vars[k] = res
            slotVars[k] = nil
          end
        else
          if secondChar ~= 43 and secondChar ~= 60 and secondChar ~= 62 then -- + < > we need to exlcude these because they are used as custom merging strategy indicators
            passed = true
            slotVars[k] = nil
            if vars[v] == nil then
            else
              local val = vars[v]
              if type(val) == "table" then
                succeed[k] = val.val
                vars[k] = val.val
              else
                succeed[k] = val
                vars[k] = val
              end
            end
          end
        end
      else
        passed = true
        succeed[k] = v
        vars[k] = v
        slotVars[k] = nil
      end
    end
    if passed == false then break end
  end
  if not tableIsEmpty(slotVars) then
    for k, v in ipairs(slotVars) do
      succeed[k] = expressionParser.parseSafe(v, vars)
    end
  end
  return succeed
end

local function _sanitizeVars(allVariables, userVars)
  profilerPushEvent('jbeam/variables._sanitizeVars')

  local vars = {}
  for kv,vv in pairs(allVariables) do
    if vv.type == 'range' then
      if vv.unit == '' then vv.unit = nil end
      if type(vv.min) ~= 'number' then
        log('E', 'postProcess.variables', 'variable ' .. vv.name .. ' ignored, min not a number: ' .. dumps(vv))
        goto continue
      end
      if type(vv.max) ~= 'number' then
        log('E', 'postProcess.variables', 'variable ' .. vv.name .. ' ignored, max not a number' .. dumps(vv))
        goto continue
      end
      if type(vv.default) ~= 'number' then
        log('E', 'postProcess.variables', 'variable ' .. vv.name .. ' ignored, default not a number' .. dumps(vv))
        goto continue
      end
      -- choose the default or the user set value
      if userVars[vv.name] ~= nil then
        vv.val = userVars[vv.name]
      else
        vv.val = vv.default
      end
      -- set defaults for variables
      if not vv.minDis then
        if vv.unit then
          vv.minDis = vv.min
        else
          vv.minDis = -100
        end
      end
      if not vv.maxDis then
        if vv.unit then
          vv.maxDis = vv.max
        else
          vv.maxDis = 100
        end
      end
      if not vv.stepDis then
        if vv.unit then
          vv.stepDis = (vv.maxDis - vv.minDis) / 100
        else
          vv.stepDis = 1
        end
      end
      -- this should at some point be the given one and then stepDis is calculated from this value
      vv.step = vv.stepDis * (vv.max - vv.min) / (vv.maxDis - vv.minDis)
      if vv.step ~= vv.step then --NaN
        log("D",'postProcess.variables', dumps(vv.name) .." have max and min the same!" )
        vv.step = vv.stepDis
      end
      if vv.unit == nil or vv.unit == '' then
        vv.unit = '%'
      end
      if vv.category == nil or vv.category == '' then
        vv.category = 'alignment'
      end

      if string.match(vv.category, "(.*)%.(.*)") then
        vv.category, vv.subCategory = string.match(vv.category, "(.*)%.(.*)")
      end

      local valBeforeClamp = vv.val

      --we can't be sure that "min" is actually the smaller number and "max" the bigger one, so for clamping we need to find out which is which first
      vv.val = clamp(vv.val, min(vv.min, vv.max), max(vv.min, vv.max))

      --Make sure our value is actually inside the min/max limits
      if valBeforeClamp ~= vv.val then
        log('W', 'variables', 'variable ' .. tostring(vv.name) .. ' value out of range! value ' .. tostring(valBeforeClamp) .. ' clamped to range [' .. tostring(vv.min) .. ',' .. tostring(vv.max) .. '] as ' .. tostring(vv.val))
      end

      vars[vv.name] = vv
    else
      log('E', 'variables', 'variable ' .. tostring(vv.name) .. ' ignored, unknown type: ' .. tostring(vv.type))
    end
    ::continue::
  end

  profilerPopEvent('jbeam/variables._sanitizeVars')
  return vars
end


local function _getPartVariables_ParsingVariablesSectionDestructive(part)
  local res = {}
  if type(part.variables) ~= 'table' then return {} end
  jbeamTableSchema.processTableWithSchemaDestructive(part.variables, res)
  return res
end

local function varMerge(dict, dest, src)
  local destEnd = #dest
  for _, v in ipairs(src) do
    if dict[v.name] then
      -- dump({'val=',v.default, 'overwrites=', dest[dict[v.name]].default})
      dest[dict[v.name]] = v
    else
      if v.name then
        destEnd = destEnd + 1
        dict[v.name] = destEnd
        dest[destEnd] = v
      else
        -- log('W', 'variables', 'anonymous variable ignored: ' .. dumps(v))
      end
    end
  end
end

-- Collects and resolves all variables across parts respecting slot scoping.
-- Strategy:
-- 1) Parse root variables list, evaluate only $= inside it (do not rename keys)
-- 2) Sanitize root variables -> numeric values map used in expressions
-- 3) Traverse unifyJournal; for each part:
--    - build svars = parentScope + resolved slot vars
--    - evaluate only $= inside the part's variables list using svars
--    - sanitize and extend scope so children can reference these variables
local function getAllVariables(rootPart, unifyJournal, vehicleConfig)
  -- collect all the known variables across all parts, evaluating within slot scope
  -- build a slot variable stack similar to processParts, but only for evaluating the variables sections
  local varDict = {}

  -- base scope seeded with sanitized root variables and allow component access via $components
  local varStack = {}

  -- process root part variables in its base scope
  -- note: only evaluate $= inside variables to avoid renaming keys like "$AAA"
  local rootVarsList = _getPartVariables_ParsingVariablesSectionDestructive(rootPart)
  do
    local wrapper = { _v = deepcopy(rootVarsList) }
    -- only evaluate $= inside variables
    apply(wrapper, {}, true)
    rootVarsList = wrapper._v
  end

  -- sanitize root variables to obtain concrete values accessible as $var in expressions
  -- this produces a map like { ['$AAA'] = { val = 1, ... }, ... } used by expressionParser
  local currentVarsMap = _sanitizeVars(deepcopy(rootVarsList), vehicleConfig.vars or {})
  currentVarsMap['$components'] = {val = rootPart.components}
  varStack[rootPart] = currentVarsMap

  local allVariables = rootVarsList

  -- walk journal from child to parent like processParts
  -- each journal entry layout: { parentPart, part, level, slotOptions, partPath, slotDef }
  -- evaluate each part's variables with its slot scope
  for i = #unifyJournal, 1, -1 do
    local uj = unifyJournal[i]
    local parentPart, part, slot = uj[1], uj[2], uj[6]

    local parentScope = varStack[parentPart] or currentVarsMap
    local slotVars = slot and slot.variables or {}

    -- resolve slot variables against parent scope, then merge to form this part scope
    local svars = applySlotVars(deepcopy(slotVars or {}), parentScope)
    svars = tableMerge(deepcopy(parentScope), svars)

    -- extract and evaluate this part's variables with svars
    -- again, only evaluate $= so variable names remain intact
    local partVarsList = _getPartVariables_ParsingVariablesSectionDestructive(part)
    if #partVarsList > 0 then
      local wrap = { _v = deepcopy(partVarsList) }
      apply(wrap, svars, true)
      partVarsList = wrap._v
      varMerge(varDict, allVariables, partVarsList)

      -- sanitize these part variables and extend the scope for children
      -- this makes values like $BBB_1 available to deeper parts
      local sanitizedPartVars = _sanitizeVars(deepcopy(partVarsList), vehicleConfig.vars or {})
      svars = tableMerge(svars, sanitizedPartVars)
    end

    varStack[part] = svars
  end
  --dumpz({'allVariables = ', allVariables}, 3)
  return _sanitizeVars(allVariables, vehicleConfig.vars or {})
end

local function processParts(rootPart, unifyJournal, vehicleConfig, vars)
  profilerPushEvent('jbeam/variables.processParts')
  vars['$components'] = {val = rootPart.components} -- with this you can use '$components.' in your expressions
  -- dumpz({'vars = ', vars}, 2)

  local varStack = {}
  varStack[rootPart] = vars

  -- apply component variables before everything because they can be used in everything else
  if rootPart.components then
    apply(rootPart.components, vars)
  end
  local c = rootPart.components
  rootPart.components = nil
  -- process root part without components
  apply(rootPart, vars)
  rootPart.components = c
  for i = #unifyJournal, 1, -1 do
    local parentPart, part, level, slotOptions, path, slot = unpack(unifyJournal[i])
    local slotVars = slot.variables
    local slotId = slot.name or slot.type

    if slotVars == nil then slotVars = {} end
    local svars = applySlotVars(slotVars, varStack[parentPart])
    -- dump{'svars = ', svars}

    local partOrig
    if debugParts then
      partOrig = deepcopy(part)
    end

    svars = tableMerge(deepcopy(varStack[parentPart]), svars)
    varStack[part] = svars
    apply(slotOptions, svars) -- nodeoffset
    apply(part, svars) -- part

    if debugParts then
      jsonWriteFile(slotId .. '.json', {partPost=part, partPre=partOrig, slotvars=svars, slotOptions=slotOptions}, true)
    end
  end

  profilerPopEvent('jbeam/variables.processParts')
  return vars
end

local function postProcessVariables(vehicle, allVariables)
  -- transform into more usable type where the name is the key
  local newVars = {}
  for k, v in pairs(allVariables) do
    if type(v) == 'table' and k ~= '$components' then
      newVars[v.name or k] = v
    else
      --log('W', 'variables', 'variable ignored for UI: ' .. tostring(k) .. ' = ' .. tostring(v))
      --newVars[k] = v
    end
  end
  vehicle.variables = newVars
end


local function unifyComponents(vehicle, svars, target, source_raw, level, slotOptions, partPath, slot)
  --dump(slot.variables or {})
  for sectionKey, section in pairs(source_raw) do
    if sectionKey == 'components' then
      for k3, v3 in pairs(section) do
        if type(v3) == 'table' then
          vehicle.components[k3] = vehicle.components[k3] or {}
          -- Components historically allowed $... key replacement everywhere (including nested 'variables' tables),
          -- so we preserve that behavior here.
          apply(v3, svars, nil, true)
          tableMergeRecursiveArray(vehicle.components[k3], v3)
        else
          vehicle.components[k3] = v3
        end
      end
      source_raw.components = nil
    end
  end
end

local function processComponents(rootPart, unifyJournal, vehicleConfig, vars)
  profilerPushEvent('jbeam/variables.processComponents')

  rootPart.components = rootPart.components or {}
  vars['$components'] = {val = rootPart.components}

  local varStack = {}
  varStack[tostring(rootPart)] = deepcopy(vars)

  for i = 1, #unifyJournal do
    local parentPart, part, level, slotOptions, path, slot = unpack(unifyJournal[i])

    -- get the slot variables into the proper stack
    local slotVarCopy = deepcopy(slot.variables or {})
    local svars = applySlotVars(slotVarCopy, varStack[tostring(parentPart)] or {})
    svars = tableMerge(deepcopy(varStack[tostring(parentPart)]), svars)
    svars['$components'] = {val = rootPart.components}

    varStack[tostring(part)] = svars
    --dump(varStack)

    unifyComponents(rootPart, svars, unpack(unifyJournal[i]))
  end

  --log('I', "jbeam.processComponents", "Final components: " .. dumps(rootPart.components))

  profilerPopEvent('jbeam/variables.processComponents')
  return true
end

local function setFunctionsToNil(t)
  for k, v in pairs(t) do
    if type(v) == "function" then
      t[k] = nil
    elseif type(v) == "table" then
      setFunctionsToNil(v)
    end
  end
end

local function cleanup(vehicle)
  profilerPushEvent('jbeam/variables.componentsCleanup')

  setFunctionsToNil(vehicle.components or {})


  -- remove any variables that are hidden
  for k, v in pairs(vehicle.variables) do
    if v.hidden == true then
      vehicle.variables[k] = nil
    end
  end


  profilerPopEvent('jbeam/variables.componentsCleanup')
  return true
end

M.processComponents = processComponents
M.cleanup = cleanup
M.getAllVariables = getAllVariables
M.postProcessVariables = postProcessVariables
M.processParts = processParts

return M
