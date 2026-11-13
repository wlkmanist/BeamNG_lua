-- Run with require('testFramework/TestManager'):runTestFiles('ui/arrowGPS')
local M = {}

local function runtime()
  local state = {created = {}, objects = {}, player = {}}
  local environment = setmetatable({
    getPlayerVehicle = function() return state.player end,
    core_camera = {
      getPosition = function() return vec3() end,
      getForward = function() return vec3(0, 1, 0) end,
      getRight = function() return vec3(1, 0, 0) end,
      getUp = function() return vec3(0, 0, 1) end,
      getFovDeg = function() return 90 end
    },
    GFXDevice = {getVideoMode = function() return {width = 200, height = 100} end},
    Sim = {getUniqueName = function(name) return name end},
    scenetree = {findObjectById = function(id) return state.objects[id] end},
    createObject = function(className)
      assert(className == 'TSStatic')
      local id = #state.created + 1
      local data = {fields = {}, deleted = false, updates = 0}
      local object = setmetatable({}, {
        __index = function(_, key)
          assert(not data.deleted, 'Access to deleted arrow: ' .. key)
          return data[key]
        end,
        __newindex = function(_, key, value)
          assert(not data.deleted, 'Write to deleted arrow: ' .. key)
          data[key] = value
        end
      })
      function data:setField(name, _, value) data.fields[name] = value end
      function data:registerObject() state.objects[id] = object end
      function data:getId() return id end
      function data:updateInstanceRenderData() data.updates = data.updates + 1 end
      function data:setPosRot(x, y, z, qx, qy, qz, qw)
        data.position = vec3(x, y, z)
        data.rotation = quat(qx, qy, qz, qw)
      end
      function data:delete() data.deleted = true; state.objects[id] = nil end
      data.object = object
      state.created[id] = data
      return object
    end
  }, {__index = _G})
  local chunk, err = loadfile('/lua/ge/extensions/ui/arrowGPS.lua')
  assert(chunk, err)
  setfenv(chunk, environment)
  local gps = chunk()
  if gps.onExtensionLoaded then gps.onExtensionLoaded() end
  return gps, state
end

function M.testIdleExtensionDoesNotCreateArrow(ctx)
  local gps, state = runtime()
  ctx:assertEqual(#state.created, 0)
  gps.onPreRender(0)
  gps.setTarget('route', 1, {})
  gps.onPreRender(0)
  gps.removeTarget('route')
  gps.setTarget('route', 1, {pos = {10, 0, 0}})
  gps.removeTarget('route')
  gps.onPreRender(0)
  gps.onExtensionUnloaded()
  ctx:assertEqual(#state.created, 0)
end

function M.testTargetWaitsForPlayerAndRender(ctx)
  local gps, state = runtime()
  state.player = nil
  gps.setTarget('route', 1, {pos = {10, 0, 0}})
  ctx:assertEqual(#state.created, 0)
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 0)
  state.player = {}
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 1)
  ctx:assertEqual(state.created[1].hidden, false)
end

function M.testRenderedArrowIsReusedAndHidesWithoutPlayer(ctx)
  local gps, state = runtime()
  gps.setTarget('route', 1, {pos = {10, 0, 0}})
  gps.onPreRender(0)
  local arrow = state.created[1]
  ctx:assertEqual(arrow.fields.instanceColor, '1 0.4 0.2 1')
  ctx:assertEqual(arrow.fields.shapeName, 'art/shapes/interface/s_mm_arrow_floating.dae')
  state.player = nil
  gps.onPreRender(0)
  ctx:assertEqual(arrow.hidden, true)
  state.player = {}
  gps.onPreRender(0)
  ctx:assertEqual(arrow.hidden, false)
  ctx:assertEqual(#state.created, 1)
end

function M.testPriorityColorAndTargetRemoval(ctx)
  local gps, state = runtime()
  gps.setTarget('route', 10, {pos = {10, 0, 0}, color = {1, 0, 0}})
  gps.setTarget('mission', 1, {pos = {-10, 0, 0}, color = {0, 1, 0}})
  gps.onPreRender(0)
  local arrow = state.created[1]
  ctx:assertEqual(arrow.fields.instanceColor, '0 1 0 1')
  ctx:assert((arrow.rotation * vec3(0, 1, 0)).x < -0.9)
  gps.removeTarget('mission')
  gps.onPreRender(0)
  ctx:assertEqual(arrow.fields.instanceColor, '1 0 0 1')
  ctx:assert((arrow.rotation * vec3(0, 1, 0)).x > 0.9)
  gps.removeTarget('route')
  ctx:assertEqual(arrow.hidden, true)
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 1)
end

function M.testSceneDeletionRecreatesArrowWithoutTargetUpdate(ctx)
  local gps, state = runtime()
  gps.setTarget('route', 1, {pos = {10, 0, 0}, color = {0, 0, 1}})
  gps.onPreRender(0)
  state.created[1].object:delete()
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 2)
  ctx:assertEqual(state.created[2].hidden, false)
  ctx:assertEqual(state.created[2].fields.instanceColor, '0 0 1 1')
  state.created[2].object:delete()
  gps.setScale(0.08)
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 3)
  ctx:assertNear(state.created[3].scale.x, 0.08)
end

function M.testTargetUpdateAfterSceneDeletionDoesNotUseOldObject(ctx)
  local gps, state = runtime()
  gps.setTarget('route', 1, {pos = {10, 0, 0}})
  gps.onPreRender(0)
  state.created[1].object:delete()
  gps.setTarget('route', 1, {pos = {-10, 0, 0}, color = {0, 1, 0}})
  gps.setScale(0.08)
  ctx:assertEqual(#state.created, 1)
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 2)
  ctx:assertEqual(state.created[2].fields.instanceColor, '0 1 0 1')
  ctx:assertNear(state.created[2].scale.x, 0.08)
end

function M.testSettingsBeforeCreationAffectFirstRender(ctx)
  local gps, state = runtime()
  gps.setScale(0.08)
  gps.setDepth(0.3)
  gps.setAppScreenPos(0.75, 0.25)
  ctx:assertEqual(#state.created, 0)
  gps.setTarget('route', 1, {pos = vec3(10, 0, 0)})
  gps.onPreRender(0)
  local arrow = state.created[1]
  ctx:assertNear(arrow.scale.x, 0.08)
  ctx:assertNear(arrow.scale.y, 0.08)
  ctx:assertNear(arrow.scale.z, 0.08)
  ctx:assertNear(arrow.position.x, 0.3)
  ctx:assertNear(arrow.position.y, 0.3)
  ctx:assertNear(arrow.position.z, 0.15)
end

function M.testUnloadClearsObjectAndTargetState(ctx)
  local gps, state = runtime()
  gps.setTarget('route', 1, {pos = {10, 0, 0}})
  gps.onPreRender(0)
  gps.onExtensionUnloaded()
  ctx:assertEqual(state.created[1].deleted, true)
  ctx:assertEqual(next(state.objects), nil)
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 1)
  gps.setTarget('newRoute', 2, {pos = {-10, 0, 0}})
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 2)
  ctx:assert((state.created[2].rotation * vec3(0, 1, 0)).x < -0.9)
  state.created[2].object:delete()
  gps.onExtensionUnloaded()
  gps.onPreRender(0)
  ctx:assertEqual(#state.created, 2)
end

return M
