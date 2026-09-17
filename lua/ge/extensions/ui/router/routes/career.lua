-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Constants = require("ge/extensions/ui/router/constants")

local M = {}
local ProgressLandingScopeTree = {
  ["career-progress-landing"] = {
    preferAutoFocus = true,
  },
}

local ComputerScopeTree = {
  ["root"] = {}
}

local PartShoppingScopeTree = {
  ["root"] = {
    ["part-shopping-categories"] = {
      preferAutoFocus = true,
      backTargetType = "route",
    },
    ["part-shopping-cart"] = {
      backTarget = "part-shopping-categories",
      backTargetType = "scope",
    },
  },
}

local TuningScopeTree = {
  ["root"] = {
    ["career-tuning"] = {
      preferAutoFocus = true,
    },
    ["career-tuning-cart"] = {
      backTarget = "career-tuning",
      backTargetType = "scope",
    },
  },
}

local PaintingScopeTree = {
  ["root"] = {
    ["career-painting"] = {
      preferAutoFocus = true,
      backTargetType = "route",
    },
    ["career-painting-cart"] = {
      backTarget = "career-painting",
      backTargetType = "scope",
    },
  },
}

local PartInventoryScopeTree = {
  ["root"] = {
    ["part-inventory-list"] = {
      preferAutoFocus = true,
      backTargetType = "route",
    },
  },
}

local VehicleShoppingScopeTree = {
  ["root"] = {
    ["vehicle-shopping"] = {
      preferAutoFocus = true,
      backTargetType = "route",
    },
  },
}

local VehicleShoppingVehiclesScopeTree = {
  ["root"] = {
    ["vehicle-shopping-vehicles"] = {
      preferAutoFocus = true,
      backTargetType = "route",
    },
  },
}

local VehiclePurchaseScopeTree = {
  ["root"] = {
    ["vehicle-purchase"] = {
      preferAutoFocus = true,
      backTargetType = "route",
    },
  },
}

local RefuelingScopeTree = {
  ["career-refueling"] = {}
}

-- ModuleName(optional) by default is the name of the file unless specified otherwise
M.ModuleName = "career"
M.Root = {
  abstract = true,
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaults,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults
  }
}

M.Children = {
  ["chooseInsurance"] = { screenId = "career.chooseInsurance" },
  ["pauseBigMiddlePanel"] = { screenId = "career.pauseBigMiddlePanel" },
  ["logbook"] = { screenId = "career.logbook" },
  ["refueling"] = {
    screenId = "refueling",
    title = "ui.career.refueling.title",
    backTarget = "play",
    targetScope = "career-refueling",
    scopeTree = RefuelingScopeTree,
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = {
        visible = true,
        showSysInfo = false,
      },
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = Constants.UiAppsDefaults,
    }
  },
  ["computer"] = {
    screenId = "career.computer",
    title = "ui.career.shared.myComputer",
    back = { mode = "rootExit" },
    targetScope = "root",
    scopeTree = ComputerScopeTree,
    -- ui inherits to nested children, so this shows the InfoBar for the
    -- whole career.computer route family.
    ui = {
      infoBar = Constants.InfoBarDefaults,
    },
    children = {
      ["vehicleInventory"] = {
        screenId = "career.computer.vehicleInventory",
        title = "ui.career.shared.myVehicles",
        back = { mode = "handler", handler = "vehicleInventoryExitHandler" },
        targetScope = "root",
        scopeTree = ComputerScopeTree,
      },
      ["partShopping"] = {
        screenId = "career.computer.partShopping",
        title = "ui.career.shared.pathPartCustomization",
        -- Root of the shopping flow: BACK exits shopping (with a cart-discard
        -- confirmation in the UI) rather than navigating to the parent screen.
        back = { mode = "handler", handler = "partShoppingExitHandler" },
        targetScope = "part-shopping-categories",
        scopeTree = PartShoppingScopeTree,
        onEnter = "career_modules_partShopping.onRouteEnter",
        onMount = "career_modules_partShopping.onRouteMount",
        children = {
          ["category"] = {
            screenId = "career.computer.partShopping.category",
            title = {
              mode = "dynamic",
              source = "career_modules_partShopping.getCategoryBreadcrumbTitle",
              paramKey = "category",
              fallback = "ui.career.partShopping.allParts",
            },
            backTarget = "career.computer.partShopping",
            targetScope = "part-shopping-categories",
            scopeTree = PartShoppingScopeTree,
            onEnter = "career_modules_partShopping.onRouteEnter",
            onMount = "career_modules_partShopping.onRouteMount",
            children = {
              ["slot"] = {
                screenId = "career.computer.partShopping.category.slot",
                title = {
                  mode = "dynamic",
                  source = "career_modules_partShopping.getSlotBreadcrumbTitle",
                  paramKey = "slotPath",
                  fallback = "ui.career.shared.pathPartCustomization",
                },
                backTarget = "career.computer.partShopping.category",
                targetScope = "part-shopping-categories",
                scopeTree = PartShoppingScopeTree,
                onEnter = "career_modules_partShopping.onRouteEnter",
                onMount = "career_modules_partShopping.onRouteMount",
              },
            },
          },
        },
      },
      ["repair"] = {
        screenId = "career.computer.repair",
        title = "ui.career.shared.pathRepair",
        targetScope = "root",
        scopeTree = ComputerScopeTree,
      },
      ["tuning"] = {
        screenId = "career.computer.tuning",
        title = "ui.career.shared.pathTuning",
        targetScope = "career-tuning",
        scopeTree = TuningScopeTree,
      },
      ["painting"] = {
        screenId = "career.computer.painting",
        title = "ui.career.shared.pathPainting",
        backTarget = "career.computer",
        targetScope = "career-painting",
        scopeTree = PaintingScopeTree,
        onMount = "career_modules_painting.onRouteMount",
      },
      ["partInventory"] = {
        screenId = "career.computer.partInventory",
        title = "ui.career.shared.pathPartInventory",
        backTarget = "career.computer",
        targetScope = "part-inventory-list",
        scopeTree = PartInventoryScopeTree,
        onMount = "career_modules_partInventory.onRouteMount",
      },
      ["insurances"] = {
        screenId = "career.computer.insurances",
        title = "ui.career.insurance.title",
        backTarget = "career.computer",
        targetScope = "root",
        scopeTree = ComputerScopeTree,
      },
      ["playerAbstract"] = {
        screenId = "career.computer.playerAbstract",
        title = "ui.career.driverAbstract.title",
        backTarget = "career.computer",
        targetScope = "root",
        scopeTree = ComputerScopeTree,
        onMount = "career_modules_playerAbstract.onRouteMount",
        onLeave = "career_modules_playerAbstract.onRouteLeave",
      },
      ["vehiclePerformance"] = {
        screenId = "career.computer.vehiclePerformance",
        title = "ui.career.shared.pathPerformanceIndex",
        backTarget = "career.computer",
        targetScope = "root",
        scopeTree = ComputerScopeTree,
        onMount = "career_modules_vehiclePerformance.onRouteMount",
        children = {
          ["certificationTest"] = {
            screenId = "career.computer.vehiclePerformance.certificationTest",
            title = "ui.career.shared.pathPerformanceIndex",
            backTarget = "career.computer.vehiclePerformance",
            targetScope = "root",
            scopeTree = ComputerScopeTree,
            ui = {
              infoBar = Constants.InfoBarDefaultsHidden
            }
          },
        },
      },
      ["vehicleShopping"] = {
        screenId = "career.computer.vehicleShopping",
        title = "ui.career.vehicleShopping.vehicleMarketplace",
        -- BACK is origin-aware: computer-origin returns to the computer, while
        -- dealership-origin exits to play (handled in vehicleShopping.requestExit).
        back = { mode = "handler", handler = "vehicleShoppingExitHandler" },
        targetScope = "vehicle-shopping",
        scopeTree = VehicleShoppingScopeTree,
        onMount = "career_modules_vehicleShopping.onRouteMount",
        children = {
          ["vehicles"] = {
            screenId = "career.computer.vehicleShopping.vehicles",
            title = {
              mode = "dynamic",
              source = "career_modules_vehicleShopping.getSelectedSellerBreadcrumbTitle",
              fallback = "ui.career.vehicleShopping.vehicleMarketplace",
            },
            back = { mode = "handler", handler = "vehicleShoppingVehicleListExitHandler" },
            targetScope = "vehicle-shopping-vehicles",
            scopeTree = VehicleShoppingVehiclesScopeTree,
            onMount = "career_modules_vehicleShopping.onRouteMount",
            children = {
              ["vehiclePurchase"] = {
                screenId = "career.computer.vehicleShopping.vehicles.vehiclePurchase",
                title = "ui.career.vehiclePurchase.purchaseInformation",
                back = { mode = "handler", handler = "vehiclePurchaseExitHandler" },
                backTarget = "career.computer.vehicleShopping.vehicles",
                targetScope = "vehicle-purchase",
                scopeTree = VehiclePurchaseScopeTree,
              },
            },
          },
        },
      },
    },
  },
  ["negotiation"] = { screenId = "career.negotiation" },
  ["cargoDeliveryReward"] = { screenId = "career.cargoDeliveryReward" },
  ["cargoDropOff"] = { screenId = "career.cargoDropOff" },
  ["cargoOverview"] = { screenId = "career.cargoOverview" },
  ["myCargo"] = {
    screenId = "career.myCargo",
    title = "ui.career.myCargo.title2",
    backTarget = "career.computer",
    targetScope = "root",
    scopeTree = ComputerScopeTree,
  },
  ["progressLanding"] = {
    screenId = "career.progressLanding",
    title = {
      mode = "dynamic",
      source = "career_modules_branches_landing.resolveBranchTitle",
      paramKey = "pathId",
      fallback = "ui.career.landingPage.name"
    },
    backTarget = "career.domainSelection",
    targetScope = "career-progress-landing",
    scopeTree = ProgressLandingScopeTree,
  },
  ["domainSelection"] = {
    screenId = "career.domainSelection",
    title = "ui.career.landingPage.name",
    backTarget = "pause",
    targetScope = "career-progress-landing",
    scopeTree = ProgressLandingScopeTree,
  },
  ["organizations"] = {
    screenId = "career.organizations",
    title = "ui.career.organizations.title",
    backTarget = "career.domainSelection",
  },
  ["branchPage"] = {
    screenId = "career.progressLanding",
    title = {
      mode = "dynamic",
      source = "career_modules_branches_landing.resolveBranchTitle",
      paramKey = "pathId",
      fallback = "ui.career.landingPage.name"
    },
    back = {
      mode = "handler",
      handler = "careerBranchPageBackHandler",
    },
    targetScope = "career-progress-landing",
    scopeTree = ProgressLandingScopeTree,
    children = {
      ["mission"] = {
        abstract = true,
        children = {
          ["details"] = {
            screenId = "mission.details",
            backTarget = "career.branchPage",
            scopeTree = {
              ["root"] = {
                ["details-scope"] = {},
              },
            }
          }
        }
      },
      ["bigmap"] = {
        screenId = "bigmap",
        title = "Map",
        backTarget = "career.branchPage",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseBigmapLeave",
        targetScope = "bigmap-main",
        scopeTree = {
          ["bigmap-layout"] = {
            ["bigmap-camera"] = {},
            ["bigmap-main"] = {
              ["bigmap-details"] = {},
            },
          },
        },
        children = {
          ["bigmapMenu"] = {
            screenId = "bigmap.bigmapMenu",
            ui = {
              uiTypes = {"vue"},
            }
          },
        }
      },
    },
  },
  ["profiles"] = {
    screenId = "career.profiles",
    scopeTree = {
      ["career-profiles"] = {
        ["career-profiles-hero"] = {
          optional = true,
          preferAutoFocus = true,
          backTargetType = "route",
          escapeTargets = {
            right = "career-profiles-new",
            down = "career-profiles-list",
          },
        },
        ["career-profiles-new"] = {
          optional = true,
          backTargetType = "route",
          escapeTargets = {
            left = "career-profiles-hero",
            down = "career-profiles-list",
          },
        },
        ["career-profiles-list"] = {
          optional = true,
          backTargetType = "route",
          escapeTargets = {
            left = "career-profiles-hero",
            up = "career-profiles-new",
          },
        },
      },
    },
    back = {
      mode = "handler",
      handler = "careerProfilesExitHandler",
    },
    children = {
      ["new"] = {
        screenId = "career.profiles.new",
        backTarget = "career.profiles",
        scopeTree = {
          ["career-profiles-new"] = {},
        },
      },
      ["saves"] = {
        screenId = "career.profiles.saves",
        title = "ui.career.profiles.saves.title",
        backTarget = "career.profiles",
        scopeTree = {
          ["career-profiles-saves"] = {},
        },
      },
      ["saveAs"] = {
        screenId = "career.profiles.saveAs",
        title = "ui.common.save",
        backTarget = "pause",
        scopeTree = {
          ["career-profiles-saveas"] = {},
        },
      },
    },
  },

}

return M
