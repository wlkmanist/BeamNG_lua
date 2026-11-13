-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local function rememberResult(self, x, y, result)
  self.lastInputX = x
  self.lastInputY = y
  self.lastResult = result
  return result
end

local function getBiLinear(self, x, y)
  if x == self.lastInputX and y == self.lastInputY then
    return self.lastResult
  end
  local inputX, inputY = x, y

  local xMin, xMax = self.xMin, self.xMax
  local yMin, yMax = self.yMin, self.yMax
  if x < xMin then
    if not self.clampToDataRange then return rememberResult(self, inputX, inputY, nil) end
    x = xMin
  elseif x > xMax then
    if not self.clampToDataRange then return rememberResult(self, inputX, inputY, nil) end
    x = xMax
  end
  if y < yMin then
    if not self.clampToDataRange then return rememberResult(self, inputX, inputY, nil) end
    y = yMin
  elseif y > yMax then
    if not self.clampToDataRange then return rememberResult(self, inputX, inputY, nil) end
    y = yMax
  end

  local xIndices = self.xIndices
  local xIndex = self.xLastIndex
  local xInvSpan = self.xLastInvSpan
  if x < xIndices[xIndex] then
    repeat
      xIndex = xIndex - 1
    until x >= xIndices[xIndex]
    xInvSpan = 1 / (xIndices[xIndex + 1] - xIndices[xIndex])
    self.xLastIndex = xIndex
    self.xLastInvSpan = xInvSpan
  elseif x > xIndices[xIndex + 1] then
    repeat
      xIndex = xIndex + 1
    until x <= xIndices[xIndex + 1]
    xInvSpan = 1 / (xIndices[xIndex + 1] - xIndices[xIndex])
    self.xLastIndex = xIndex
    self.xLastInvSpan = xInvSpan
  end

  local yIndices = self.yIndices
  local yIndex = self.yLastIndex
  local yInvSpan = self.yLastInvSpan
  if y < yIndices[yIndex] then
    repeat
      yIndex = yIndex - 1
    until y >= yIndices[yIndex]
    yInvSpan = 1 / (yIndices[yIndex + 1] - yIndices[yIndex])
    self.yLastIndex = yIndex
    self.yLastInvSpan = yInvSpan
  elseif y > yIndices[yIndex + 1] then
    repeat
      yIndex = yIndex + 1
    until y <= yIndices[yIndex + 1]
    yInvSpan = 1 / (yIndices[yIndex + 1] - yIndices[yIndex])
    self.yLastIndex = yIndex
    self.yLastInvSpan = yInvSpan
  end

  local tx = (x - xIndices[xIndex]) * xInvSpan
  local ty = (y - yIndices[yIndex]) * yInvSpan
  local data = self.data
  local row1, row2 = data[yIndex], data[yIndex + 1]
  local q11, q12 = row1[xIndex], row1[xIndex + 1]
  local q21, q22 = row2[xIndex], row2[xIndex + 1]
  local r1 = q11 + (q12 - q11) * tx
  local r2 = q21 + (q22 - q21) * tx
  return rememberResult(self, inputX, inputY, r1 + (r2 - r1) * ty)
end

local function getLinear(self, x)
  if x == self.lastInputX and self.lastInputY == nil then
    return self.lastResult
  end
  local inputX = x

  local xMin, xMax = self.xMin, self.xMax
  if x < xMin then
    if not self.clampToDataRange then return rememberResult(self, inputX, nil, nil) end
    x = xMin
  elseif x > xMax then
    if not self.clampToDataRange then return rememberResult(self, inputX, nil, nil) end
    x = xMax
  end

  local xIndices = self.xIndices
  local xIndex = self.xLastIndex
  local invSpan = self.xLastInvSpan
  if x < xIndices[xIndex] then
    repeat
      xIndex = xIndex - 1
    until x >= xIndices[xIndex]
    invSpan = 1 / (xIndices[xIndex + 1] - xIndices[xIndex])
    self.xLastIndex = xIndex
    self.xLastInvSpan = invSpan
  elseif x > xIndices[xIndex + 1] then
    repeat
      xIndex = xIndex + 1
    until x <= xIndices[xIndex + 1]
    invSpan = 1 / (xIndices[xIndex + 1] - xIndices[xIndex])
    self.xLastIndex = xIndex
    self.xLastInvSpan = invSpan
  end

  local y1Value = self.data[xIndex] or 0
  local y2Value = self.data[xIndex + 1] or y1Value
  return rememberResult(self, inputX, nil, y1Value + (y2Value - y1Value) * ((x - xIndices[xIndex]) * invSpan))
end

local function get(self, x, y)
end

-- Accepts [x, z] pairs with an optional header. Bare numeric two-row tables,
-- including 2x2 tables, are reserved for the native {xValues, zValues} format.
local function tryTransposePairs(inputData, xScale, zScale)
  if type(inputData) ~= "table" or type(inputData[1]) ~= "table" then
    return nil
  end

  local hasHeader = type(inputData[1][1]) == "string"
  if not hasHeader and #inputData == 2 then
    return nil
  end
  local firstDataRow = hasHeader and 2 or 1
  local pointCount = #inputData - (firstDataRow - 1)
  if pointCount < 2 then
    return nil
  end

  for i = firstDataRow, #inputData do
    local row = inputData[i]
    if type(row) ~= "table" or #row ~= 2
       or type(row[1]) ~= "number" or type(row[2]) ~= "number" then
      return nil
    end
  end

  local xs, zs = {}, {}
  for i = firstDataRow, #inputData do
    local row = inputData[i]
    xs[#xs + 1] = row[1] * xScale
    zs[#zs + 1] = row[2] * zScale
  end
  return xs, zs
end

local function loadData(self, inputData, opts)
  local xScale = (opts and opts.xScale) or 1
  local yScale = (opts and opts.yScale) or 1
  local zScale = (opts and opts.zScale) or 1
  self.lastInputX = nil
  self.lastInputY = nil
  self.lastResult = nil
  self.is1D = false
  self.is2D = false

  local pairsX, pairsY = tryTransposePairs(inputData, xScale, zScale)
  if pairsX then
    self.is1D = true
    self.xIndices = pairsX
    self.data = pairsY
    self.xMin = self.xIndices[1]
    self.xMax = self.xIndices[#self.xIndices]
    self.yIndices = {}
    self.yMin = 0
    self.yMax = 0
    self.xLastIndex = 1
    self.xLastInvSpan = 1 / (self.xIndices[2] - self.xIndices[1])
    self.get = getLinear
    return
  end

  if inputData[1] and inputData[2] and #inputData == 2 and type(inputData[1][1]) == "number" and type(inputData[2][1]) == "number" then
    self.is1D = true
    self.xIndices = {}
    self.data = {}
    for i = 1, #inputData[1] do self.xIndices[i] = inputData[1][i] * xScale end
    for i = 1, #inputData[2] do self.data[i] = inputData[2][i] * zScale end
    self.xMin = self.xIndices[1]
    self.xMax = self.xIndices[#self.xIndices]
    self.yIndices = {}
    self.yMin = 0
    self.yMax = 0
    self.xLastIndex = 1
    self.xLastInvSpan = 1 / (self.xIndices[2] - self.xIndices[1])
    self.get = getLinear
    return
  end

  local xInput = inputData[1]
  local hasEmptyCorner = xInput[1] == nil
  local firstXIndex = (hasEmptyCorner or #xInput == #inputData[2]) and 2 or 1
  local lastXIndex = hasEmptyCorner and #inputData[2] or #xInput
  self.xIndices = {}
  for i = firstXIndex, lastXIndex do
    self.xIndices[#self.xIndices + 1] = xInput[i] * xScale
  end
  self.yIndices = {}
  self.data = {}
  for yIndex = 2, #inputData do
    local inputRow = inputData[yIndex]
    self.yIndices[#self.yIndices + 1] = inputRow[1] * yScale
    local outputRow = {}
    for xIndex = 2, #inputRow do
      outputRow[#outputRow + 1] = inputRow[xIndex] * zScale
    end
    self.data[#self.data + 1] = outputRow
  end

  self.xMin = self.xIndices[1]
  self.xMax = self.xIndices[#self.xIndices]
  self.yMin = self.yIndices[1]
  self.yMax = self.yIndices[#self.yIndices]
  self.xLastIndex = 1
  self.xLastInvSpan = 1 / (self.xIndices[2] - self.xIndices[1])
  self.yLastIndex = 1
  self.yLastInvSpan = 1 / (self.yIndices[2] - self.yIndices[1])
  self.is2D = true
  self.get = getBiLinear
end

local function reset(self)
end

local methods = {
  get = get,
  loadData = loadData,
  reset = reset
}
methods.__index = methods

local function new()
  local result = {
    data = {},
    xIndices = {},
    yIndices = {},
    xMin = 0,
    xMax = 0,
    yMin = 0,
    yMax = 0,
    xLastIndex = 1,
    xLastInvSpan = 0,
    yLastIndex = 1,
    yLastInvSpan = 0,
    clampToDataRange = false
  }

  return setmetatable(result, methods)
end

return {
  new = new
}
