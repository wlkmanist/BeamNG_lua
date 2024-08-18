-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local data = {
  ["foo4"] = "Hello world from Lua 4!",
}

local function initNoesis()
  log('I', 'ui_noesis', 'Lua part initialized')

  noesis.setBindings({
    {name="foo4", varType="String"},
  })
  noesis.loadUri('/noesis/Button.xaml')
end

local function getData(propertyName)
  dump{'ui_noesis.getData', propertyName}
  return data[propertyName]
end

local function setData(propertyName, value)
  dump{'ui_noesis.setData', propertyName, value}
  data[propertyName] = value
end

local function xamlChanged(xamlUri)
  dump{'ui_noesis.xamlChanged', xamlUri}
end

M.getData = getData
M.setData = setData
M.initNoesis = initNoesis
M.xamlChanged = xamlChanged

return M