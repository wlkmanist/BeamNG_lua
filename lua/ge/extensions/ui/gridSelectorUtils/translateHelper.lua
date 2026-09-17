local M = {}

local debugTranslations = false

local translateCache = {}

-- Helper function to process nested translations
local function processNestedTranslations(text)
  if not text or type(text) ~= "string" then
    return text
  end

  local result = text
  local changed = true
  local iterations = 0
  local maxIterations = 10 -- Prevent infinite loops

  while changed and iterations < maxIterations do
    changed = false
    iterations = iterations + 1

    -- Pattern 1: {{ 'foo' | translate}} or {{::'foo' | translate}} - quoted string with pipe syntax
    local newResult = result:gsub("{{%s*::%s*'([^'|}]+)'%s*|%s*translate%s*}}", function(key)
      changed = true
      return M.translate(key)
    end)
    newResult = newResult:gsub("{{%s*'([^'|}]+)'%s*|%s*translate%s*}}", function(key)
      changed = true
      return M.translate(key)
    end)

    -- Pattern 2: {{ foo | translate}} - unquoted translation with pipe syntax
    newResult = newResult:gsub("{{%s*([^%s|}]+)%s*|%s*translate%s*}}", function(key)
      changed = true
      return M.translate(key)
    end)

    -- Pattern 3: {{foo}} - simple variable substitution (context translations)
    newResult = newResult:gsub("{{%s*([a-zA-Z0-9_.]+)%s*}}", function(key)
      changed = true
      return M.translate(key)
    end)

    result = newResult
  end

  if debugTranslations then
    -- Only randomize the first letter of each word
    local debugTranslated = {}
    local wordStart = true

    for i = 1, #result do
      local char = result:sub(i, i)
      local charCode = string.byte(char)

      if charCode >= 65 and charCode <= 90 then
        -- Uppercase letter
        if wordStart then
          debugTranslated[#debugTranslated + 1] = string.char(math.random(65, 90))
          wordStart = false
        else
          debugTranslated[#debugTranslated + 1] = char
        end
      elseif charCode >= 97 and charCode <= 122 then
        -- Lowercase letter
        if wordStart then
          debugTranslated[#debugTranslated + 1] = string.char(math.random(97, 122))
          wordStart = false
        else
          debugTranslated[#debugTranslated + 1] = char
        end
      else
        -- Non-letter character - next character starts a new word
        debugTranslated[#debugTranslated + 1] = char
        wordStart = true
      end
    end

    return table.concat(debugTranslated)
  end

  return result
end

local function translate(key, fallback)

  if not key or type(key) ~= "string" then
    return key or "Missing Translation Key!"
  end

  if translateCache[key] then
    return translateCache[key]
  end

  local translated = _tr(key, fallback or key)

  -- Process nested translations in the result
  translated = processNestedTranslations(translated)

  translateCache[key] = translated
  return translated
end

M.translate = translate
return M