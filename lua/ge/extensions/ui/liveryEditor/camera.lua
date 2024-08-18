local M = {}

local api = extensions.editor_api_dynamicDecals
local garageMode = extensions.gameplay_garageMode

local CAMERA_VIEWS = {
  FRONT = 1,
  LEFT = 2,
  TOP = 3,
  RIGHT = 4,
  BACK = 5,
  FREEROAM = 6
}

local orientationCoordinates = {
  -- z inverted, y
  [CAMERA_VIEWS.LEFT] = {
    x = {
      index = 2,
      inverted = false
    },
    y = {
      index = 3,
      inverted = false
    }
  },
  -- z, y face
  [CAMERA_VIEWS.RIGHT] = {
    x = {
      index = 2,
      inverted = true
    },
    y = {
      index = 3,
      inverted = false
    }
  },
  -- x inverted, y face
  [CAMERA_VIEWS.FRONT] = {
    x = {
      index = 1,
      inverted = false
    },
    y = {
      index = 3,
      inverted = false
    }
  },
  -- x, y face
  [CAMERA_VIEWS.BACK] = {
    x = {
      index = 1,
      inverted = true
    },
    y = {
      index = 3,
      inverted = false
    }
  },
  -- x, z face
  [CAMERA_VIEWS.TOP] = {
    x = {
      index = 2,
      inverted = true
    },
    y = {
      index = 1,
      inverted = false
    }
  }
}

local currentCameraView = CAMERA_VIEWS.FREEROAM

local resetCursorPosition = function()
  local cursorPosition = api.getCursorPosition()
  cursorPosition.x = 0.5
  cursorPosition.y = 0.5
  api.setCursorPosition(cursorPosition)
end

local setCameraPresetByView = function(view)
  local camPreset
  if view == CAMERA_VIEWS.RIGHT then
    -- camPreset = garageMode.camPresets.right
    camPreset = "right"
  elseif view == CAMERA_VIEWS.LEFT then
    -- camPreset = garageMode.camPresets.left
    camPreset = "left"
  elseif view == CAMERA_VIEWS.FRONT then
    -- camPreset = garageMode.camPresets.front
    camPreset = "front"
  elseif view == CAMERA_VIEWS.BACK then
    -- camPreset = garageMode.camPresets.back
    camPreset = "back"
  elseif view == CAMERA_VIEWS.TOP then
    -- camPreset = garageMode.camPresets.top
    camPreset = "top"
  end

  if camPreset then
    garageMode.setCamera(camPreset)
  end
end

local setCameraView = function(cameraView)
  log("D", "", "set camera view")
  dump(cameraView)
  currentCameraView = cameraView
  setCameraPresetByView(currentCameraView)
  resetCursorPosition()
end

M.setCameraViewByPosition = function(pos)
  local cameraView

  if pos.x < 0 then
    cameraView = CAMERA_VIEWS.RIGHT
  elseif pos.y < 0 then
    cameraView = CAMERA_VIEWS.FRONT
  elseif pos.x > 1 then
    cameraView = CAMERA_VIEWS.LEFT
  elseif pos.y > 1 then
    cameraView = CAMERA_VIEWS.BACK
  elseif pos.z > 1 then
    cameraView = CAMERA_VIEWS.TOP
  end

  setCameraView(cameraView)
end

M.getCameraView = function()
  return currentCameraView
end

M.getOrientationCoordinates = function()
  return orientationCoordinates[currentCameraView]
end

M.setCameraView = setCameraView
M.CAMERA_VIEWS = CAMERA_VIEWS
M.orientationCoordinates = orientationCoordinates

return M
