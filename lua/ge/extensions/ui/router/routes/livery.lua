-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "livery"
M.Root = {
  screenId = "livery",
  title = "Liveries",
  scopeTree = {
    ["root"] = {}
  },
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaults,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults
  }
}

M.Children = {
  ["saves"] = {
    screenId = "livery.saves",
    title = "Saves",
    backTarget = "livery",
    ui = {
      infoBar = Constants.InfoBarDefaults
    },
    scopeTree = {
      ["root"] = {}
    }
  },
  ["editor"] = {
    screenId = "livery.editor",
    title = "Livery Editor",
    scopeTree = {
      ["root"] = {}
    },
    children = {
      ["paint"] = {
        screenId = "livery.editor.paint",
        title = "Paint",
        backTarget = "livery.editor",
        scopeTree = {
          ["root"] = {}
        }
      },
      ["decals"] = {
        screenId = "livery.editor.decals",
        title = "Decals",
        backTarget = "livery.editor",
        scopeTree = {
          ["root"] = {
            ["layers-manager"] = {
              backTarget = "livery.editor",
              backTargetType = "route"
            },
            ["actions-drawer"] = {
              optional = true,
              backTarget = "layers-manager",
              backTargetType = "scope"
            },
            ["layer-order"] = {
              optional = true,
              backTarget = "actions-drawer",
              backTargetType = "scope"
            }
          }
        },
        targetScope = "layers-manager",
        children = {
          ["selector"] = {
            screenId = "livery.editor.decals.selector",
            title = "Decal Selector",
            backTarget = "livery.editor.decals",
            scopeTree = {
              ["root"] = {}
            }
          },
          ["materials"] = {
            screenId = "livery.editor.decals.materials",
            title = "Materials",
            backTarget = "livery.editor.decals",
            scopeTree = {
              ["root"] = {}
            }
          },
          ["transform"] = {
            screenId = "livery.editor.decals.transform",
            title = "Transform",
            backTarget = "livery.editor.decals",
            scopeTree = {
              ["root"] = {}
            }
          }
        }
      },
      ["settings"] = {
        screenId = "livery.editor.settings",
        title = "Settings",
        backTarget = "livery.editor",
        scopeTree = {
          ["root"] = {}
        }
      }
    }
  },
  ["main"] = {
    screenId = "livery.main",
    title = "Livery Editor",
    backTarget = "livery",
    scopeTree = {
      ["root"] = {}
    }
  },
  ["cameraSettings"] = {
    screenId = "livery.cameraSettings",
    title = "Camera Settings",
    backTarget = "livery.editor.decals",
    scopeTree = {
      ["root"] = {}
    }
  },
  ["layerEdit"] = {
    screenId = "livery.layerEdit",
    title = "Layer Edit",
    backTarget = "livery.editor.decals",
    scopeTree = {
      ["root"] = {}
    }
  },
  ["layerProjection"] = {
    screenId = "livery.layerProjection",
    title = "Projection",
    backTarget = "livery.layerEdit",
    scopeTree = {
      ["root"] = {}
    }
  },
  ["manager"] = {
    screenId = "livery.manager",
    title = "Manager",
    backTarget = "livery",
    scopeTree = {
      ["livery-manager"] = {}
    }
  }
}

return M
