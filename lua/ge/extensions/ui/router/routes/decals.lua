-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "decals"
M.Root = {
  screenId = "liveries.edit.decals",
  title = "ui.liveries.edit.decals",
  backTarget = "liveries.edit",
  -- the screen switches between the layers manager and a non-navigable camera scope
  scopeTree = {
    ["root"] = {
      ["liveries-decals-hidden"] = {
        backTarget = "layers-manager",
        backTargetType = "scope"
      },
      ["layers-manager"] = {
        backTarget = "liveries.edit",
        backTargetType = "route"
      }
    }
  },
  targetScope = "layers-manager",
  onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalsEnter",
  onMount = "ui_liveries_routeLifecycleCallbacks.onDecalsMount",
  onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalsLeave",
}

M.Children = {
  -- picking a camera view now happens before the texture selector, so the flow becomes
  -- decals -> camera -> selector -> transform; the camera route stays inside the decals
  -- branch (screenId prefix) so ui_liveries_decal setup/teardown is unaffected
  ["camera"] = {
    screenId = "liveries.edit.decals.camera",
    title = "ui.liveries.edit.cameraView",
    backTarget = "liveries.edit.decals",
    scopeTree = {
      ["root"] = {}
    },
    onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalCameraEnter",
    onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalsLeave",
    children = {
      ["selector"] = {
        screenId = "liveries.edit.decals.camera.selector",
        title = "ui.liveries.edit.selectDecal",
        backTarget = "liveries.edit.decals.camera",
        -- grid selector layout: the decal tiles live in the "grid" scope, the
        -- category list in "auxillary"; back from the categories returns to the grid
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTarget = "liveries.edit.decals.camera",
              backTargetType = "route"
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          }
        },
        targetScope = "grid",
        onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalsEnter",
        onMount = "ui_liveries_routeLifecycleCallbacks.onDecalSelectorMount",
        onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalsLeave",
        children = {
          ["transform"] = {
            screenId = "liveries.edit.decals.camera.selector.transform",
            title = "ui.liveries.edit.addDecal",
            backTarget = "liveries.edit.decals.camera.selector",
            scopeTree = {
              ["root"] = {}
            },
            onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalsEnter",
            onMount = "ui_liveries_routeLifecycleCallbacks.onDecalTransformMount",
            onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalTransformLeave",
            children = {
              ["settings"] = {
                screenId = "liveries.edit.decals.camera.selector.transform.settings",
                title = "ui.liveries.edit.settings",
                backTarget = "liveries.edit.decals.camera.selector.transform",
                scopeTree = {
                  ["root"] = {}
                },
                onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalTransformSettingsEnter",
                onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalTransformSettingsLeave"
              }
            }
          }
        }
      }
    }
  },
  -- opened from the layers manager for the decal that is currently selected
  ["material"] = {
    screenId = "liveries.edit.decals.material",
    title = "ui.liveries.edit.decalActions.material",
    backTarget = "liveries.edit.decals",
    scopeTree = {
      ["root"] = {}
    },
    onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalMaterialEnter",
    onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalsLeave"
  },
  -- opened from the layers manager for the decal that is currently selected
  ["mirror"] = {
    screenId = "liveries.edit.decals.mirror",
    title = "ui.liveries.edit.decalSettings.mirror",
    backTarget = "liveries.edit.decals",
    scopeTree = {
      ["root"] = {}
    },
    onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalMirrorEnter",
    onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalsLeave"
  },
  -- opened from the layers manager to re-transform the decal that is currently selected;
  -- distinct from the nested add flow above, which transforms a brand new decal
  ["transform"] = {
    screenId = "liveries.edit.decals.transform",
    title = "ui.liveries.edit.decalActions.transform",
    backTarget = "liveries.edit.decals",
    scopeTree = {
      ["root"] = {}
    },
    onEnter = "ui_liveries_routeLifecycleCallbacks.onExistingDecalTransformEnter",
    onMount = "ui_liveries_routeLifecycleCallbacks.onExistingDecalTransformMount",
    onLeave = "ui_liveries_routeLifecycleCallbacks.onExistingDecalTransformLeave",
    children = {
      ["settings"] = {
        screenId = "liveries.edit.decals.transform.settings",
        title = "ui.liveries.edit.settings",
        backTarget = "liveries.edit.decals.transform",
        scopeTree = {
          ["root"] = {}
        },
        onEnter = "ui_liveries_routeLifecycleCallbacks.onDecalTransformSettingsEnter",
        onLeave = "ui_liveries_routeLifecycleCallbacks.onDecalTransformSettingsLeave"
      }
    }
  }
}

return M