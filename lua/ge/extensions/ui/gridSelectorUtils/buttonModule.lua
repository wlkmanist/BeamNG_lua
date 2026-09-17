local M = {}

-- Create a new button management instance
function M.create()
  local instance = {}

  -- Instance variables
  local buttonIdCounter = 0
  local buttonsInfos = {}

  -- Get a free button ID
  local function getFreeButtonId()
    buttonIdCounter = buttonIdCounter + 1
    return buttonIdCounter
  end

  -- Clear all button functions
  local function clearButtonFunctions()
    buttonsInfos = {}
  end

  -- Add a button with callback function
  local function addButton(callback, meta)
    local buttonId = getFreeButtonId()
    meta = meta or {}
    meta.buttonId = buttonId

    buttonsInfos[buttonId] = {
      callback = callback,
      meta = meta,
    }
    return meta
  end

  -- Execute button callback by ID
  local function executeButton(buttonId, additionalData)
    local buttonInfo = buttonsInfos[buttonId]
    if buttonInfo then
      local data = buttonInfo.callback(additionalData)
      return data
    else
      log("E", "", "Button function not found for ID: " .. tostring(buttonId))
    end
  end

  -- Get button info by ID
  local function getButtonInfo(buttonId)
    return buttonsInfos[buttonId]
  end


  -- Get all button infos
  local function getAllButtonInfos()
    return buttonsInfos
  end

  -- Export instance methods
  instance.getFreeButtonId = getFreeButtonId
  instance.clearButtonFunctions = clearButtonFunctions
  instance.addButton = addButton
  instance.executeButton = executeButton
  instance.getButtonInfo = getButtonInfo
  instance.getAllButtonInfos = getAllButtonInfos

  return instance
end

return M
