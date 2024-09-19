local M = {}

local textureType = {
  greyscale = 0,
  color = 1,
  sdf = 2,        -- obsolete
  fillTexture = 3
}

local function version1ToVersion2(data)
  -- v1 data template
  --[[
  local sidecarTemplate = {
    version = 1,
    path = "",
    type = M.textureType.sdf, -- 0: greyscale; 1: color; 2: sdf; 3: fillTexture
    tags = {},
    vehicle = ""
  }
  ]]

  data.version = 2
  data.path = nil
  if data.type == textureType.sdf then
    data.isSdfCompatible = true
  else
    data.isSdfCompatible = false
  end
end

M.migrate = function(data)
  if data.version == 1 then
    version1ToVersion2(data)
  end
end

return M