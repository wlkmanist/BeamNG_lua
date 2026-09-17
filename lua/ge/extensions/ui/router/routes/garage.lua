-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "garage"

M.Root = {
  screenId = "garage",
  title = "Garage",
  scopeTree = {
    ["garage-layout"] = {
      ["garage-sidemenu"] = {
        backTarget = "garage-layout",
        backTargetType = "scope",
      },
    },
  },
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = {
      visible = true,
      showSysInfo = false
    },
    topBar = {
      visible = false
    },
    uiApps = {
      shown = false
    },
  },
  onEnter = "gameplay_garageMode.onGarageEnter",
}

M.Children = {
  ["vehicle"] = {
    abstract = true,
    title = {
      mode = "dynamic",
      source = "gameplay_garageMode.vehicleByIdOrActive",
      paramKey = "vehicleId",
      fallback = "Vehicle"
    },

    children = {
      ["selector"] = {
        screenId = "vehicleSelector",
        title = "Vehicle Selector",
      },

      ["tuning"] = {
        screenId = "garage.vehicle.tuning",
        title = "Tune",
        scopeTree = {
          ["garage-layout"] = {
            ["garage-sidemenu"] = {}
          }
        },
        children = {
          ["mirrors"] = {
            screenId = "garage.vehicle.tuning.mirrors",
            title = "ui.mirrors.name",
            backTarget = "garage.vehicle.tuning",
            ui = {
              topBar = Constants.TopBarDefaultsHidden,
            },
          },
        },
      },

      ["paint"] = {
        screenId = "garage.vehicle.paint",
        title = "Paint",
        scopeTree = {
          ["garage-layout"] = {
            ["garage-sidemenu"] = {}
          }
        },
      },

      ["parts"] = {
        screenId = "garage.vehicle.parts",
        title = "Parts",
        scopeTree = {
          ["garage-layout"] = {
            ["garage-sidemenu"] = {}
          }
        },
      },

      ["save"] = {
        screenId = "garage.vehicle.save",
        title = "Save Configuration",
        scopeTree = {
          ["garage-layout"] = {
            ["garage-vehicle-save"] = { backTarget = "garage", backTargetType = "route" },
            ["garage-vehicle-save-form"] = { backTarget = "garage-vehicle-save", backTargetType = "scope" },
            ["garage-sidemenu"] = { backTarget = "garage-vehicle-save" },
          }
        },
        targetScope = "garage-vehicle-save",
      }
    }
  },

  ["vehicles"] = {
    screenId = "garage.vehicles",
    title = "Garage",
    backTarget = "garage",
    onEnter = "ui_vehicleSelector_general.onRootRouteEnter",
    onMount = "ui_vehicleSelector_general.onRootRouteMount",
    onLeave = "ui_vehicleSelector_general.onRootRouteLeave",
    scopeTree = {
      ["root"] = {
        ["grid"] = {},
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      },
    },
    targetScope = "grid",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["vehicle"] = {
        screenId = "garage.vehicles.vehicle",
        title = {
          mode = "dynamic",
          source = "ui_vehicleSelector_general.resolveSelectedVehicleTitle",
          paramKey = "vehicleTitle",
          fallback = "ui.menu.vehicleSelector.title"
        },
        backTarget = "garage.vehicles",
        onEnter = "ui_vehicleSelector_general.onVehicleRouteEnter",
        onMount = "ui_vehicleSelector_general.onVehicleRouteMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTarget = "garage.vehicles",
              backTargetType = "route"
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
        targetScope = "grid",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      }
    },
  },

  ["mycars"] = {
    screenId = "garage.vehicles",
    title = "My Cars",
    backTarget = "garage",
    onEnter = "ui_vehicleSelector_general.onRootRouteEnter",
    onMount = "ui_vehicleSelector_general.onRootRouteMount",
    onLeave = "ui_vehicleSelector_general.onRootRouteLeave",
    scopeTree = {
      ["root"] = {
        ["grid"] = {},
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      },
    },
    targetScope = "grid",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["vehicle"] = {
        screenId = "garage.mycars.vehicle",
        title = {
          mode = "dynamic",
          source = "ui_vehicleSelector_general.resolveSelectedVehicleTitle",
          paramKey = "vehicleTitle",
          fallback = "ui.menu.vehicleSelector.title"
        },
        backTarget = "garage.mycars",
        onEnter = "ui_vehicleSelector_general.onVehicleRouteEnter",
        onMount = "ui_vehicleSelector_general.onVehicleRouteMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTarget = "garage.mycars",
              backTargetType = "route"
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
        targetScope = "grid",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      }
    },
  },

  ["photomode"] = {
    screenId = "garage.photomode",
    title = "ui.garage.tabs.photo",
    backTarget = "garage",
    exitGuards = {"confirmPhotomodeExit"},
    onEnter = "ui_garage_routeLifecycleCallbacks.onPhotomodeEnter",
    onMount = "ui_garage_routeLifecycleCallbacks.onPhotomodeMount",
    onLeave = "ui_garage_routeLifecycleCallbacks.onPhotomodeLeave",
    targetScope = "photomode-hidden",
    scopeTree = {
      ["pause-root"] = {
        ["photomode-hidden"] = {},
        ["photomode-panel"] = {}
      }
    },
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  }
}

return M
