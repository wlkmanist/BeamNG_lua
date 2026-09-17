-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "pause"

M.Root = {
  screenId = "pause",
  back = {
    mode = "handler",
    handler = "pauseExitHandler"
  },
  title = "ui.environment.pause",
  onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
  onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
  onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
  targetScope = "pause-left-rails",
  scopeTree = {
    ["pause-root"] = {
      ["pause-left-rails"] = {
        optional = true,
        backTargetType = "route",
        preferAutoFocus = true
      },
      ["pause-right-rails"] = {
        optional = true,
        backTargetType = "route",
        preferAutoFocus = true
      },
      ["pause-bottom-rails"] = {
        optional = true,
        backTargetType = "route",
        preferAutoFocus = true,
        escapeTargets = {
          top = "menu-content-card-1"
        }
      },
      ["menu-content-card-1"] = {
        backTargetType = "route",
      }
    }
  },
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    topBar = Constants.TopBarDefaultsHidden
  }
}

-- without onLeave the ui_pause_home_tab physics pause request sticks
local modsPauseLifecycle = {
  onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
  onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
  onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
}

M.Children = {
  { include = "mods",
    backTarget = "pause.system",
    Children = {
      ["local"] = modsPauseLifecycle,
      ["downloaded"] = modsPauseLifecycle,
      ["scheduled"] = modsPauseLifecycle,
      ["repository"] = modsPauseLifecycle,
      ["automation"] = modsPauseLifecycle,
      ["automationDetails"] = modsPauseLifecycle,
      ["details"] = modsPauseLifecycle,
    },
  },
  { include = "bigmap",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseBigmapLeave",
  },
  ["hudApps"] = {
    screenId = "pause.hudApps",
    title = "ui.hudApps.layouts",
    backTarget = "pause.system",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["menu-content-card-1"] = {
          backTarget = "pause.system",
          backTargetType = "route",
          ["hudapps-layout-browser"] = {
            backTarget = "pause.system",
            backTargetType = "route",
            preferAutoFocus = true
          }
        }
      }
    },
    targetScope = "hudapps-layout-browser",
    ui = {
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = {
        shown = true
      }
    },
    children = {
      ["editlayout"] = {
        screenId = "pause.hudApps.editlayout",
        title = "ui.hudApps.editLayout",
        backTarget = "pause.hudApps",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.hudApps",
              backTargetType = "route",
              ["hudapps-edit-layout"] = {
                backTarget = "pause.hudApps",
                backTargetType = "route",
                preferAutoFocus = true
              }
            }
          }
        },
        targetScope = "hudapps-edit-layout",
        ui = {
          topBar = Constants.TopBarDefaultsHidden,
          infoBar = {
            visible = true,
            showSysInfo = false
          },
          uiApps = {
            shown = true
          }
        },
        children = {
          ["transform"] = {
            screenId = "pause.hudApps.editlayout.transform",
            title = "ui.hudApps.adjustApp",
            backTarget = "pause.hudApps.editlayout",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["pause-root"] = {
                ["menu-content-card-1"] = {
                  backTarget = "pause.hudApps.editlayout",
                  backTargetType = "route",
                  ["hudapps-edit-layout"] = {
                    backTarget = "pause.hudApps.editlayout",
                    backTargetType = "route",
                    preferAutoFocus = true
                  }
                }
              }
            },
            targetScope = "hudapps-edit-layout",
            ui = {
              topBar = Constants.TopBarDefaultsHidden,
              infoBar = {
                visible = true,
                showSysInfo = false
              },
              uiApps = {
                shown = true
              }
            },
          }
        },
      },
      ["selector"] = {
        screenId = "pause.hudApps.selector",
        title = "Apps",
        backTarget = "pause.hudApps.editlayout",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_appSelector_general.onRouteMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTargetType = "route",
              backTarget = "pause.hudApps.editlayout",
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          }
        },
        targetScope = "grid",
        ui = {
          topBar = Constants.TopBarDefaultsHidden,
          uiApps = {
            shown = false
          }
        }
      }
    }
  },
  ["system"] = {
    screenId = "pause.system",
    title = "ui.pause.system",
    backTarget = "pause",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["pause-left-rails"] = {
          optional = true,
          backTarget = "pause",
          backTargetType = "route",
          preferAutoFocus = true
        },
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route",
        }
      }
    },
    targetScope = "pause-left-rails",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["milestones"] = {
    screenId = "career.milestones",
    title = "ui.career.milestones.title",
    backTarget = "pause",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    targetScope = "milestones",
    scopeTree = {
      ["milestones"] = {
        preferAutoFocus = true,
      },
    },
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["career"] = {
    screenId = "pause.career",
    title = "ui.career.landingPage.name",
    backTarget = "pause",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["pause-left-rails"] = {
          optional = true,
          backTarget = "pause",
          backTargetType = "route",
          preferAutoFocus = true
        },
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route",
          preferAutoFocus = true
        }
      }
    },
    targetScope = "menu-content-card-1",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["branch"] = {
        screenId = "pause.career.branch",
        title = {
          mode = "dynamic",
          source = "career_modules_branches_landing.resolveBranchTitle",
          paramKey = "pathId",
          fallback = "ui.career.landingPage.name"
        },
        backTarget = "pause.career",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["career-progress-landing"] = {
            backTarget = "pause.career",
            backTargetType = "route",
            preferAutoFocus = true
          }
        },
        targetScope = "career-progress-landing",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        },
        children = {
          ["missionDetails"] = {
            screenId = "pause.career.branch.missionDetails",
            title = "ui.missions.details.startChallenge",
            backTarget = "pause.career.branch",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["root"] = {
                ["details-scope"] = {
                  backTarget = "pause.career.branch",
                  backTargetType = "route"
                }
              }
            },
            targetScope = "root",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          },
          ["bigmap"] = {
            screenId = "pause.career.branch.bigmap",
            title = "Map",
            backTarget = "pause.career.branch",
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
            },
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          }
        }
      },
      ["missionDetails"] = {
        screenId = "pause.career.missionDetails",
        title = "ui.missions.details.startChallenge",
        backTarget = "pause.career",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["root"] = {
            ["details-scope"] = {
              backTarget = "pause.career",
              backTargetType = "route"
            }
          }
        },
        targetScope = "root",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["history"] = {
        screenId = "pause.career.history",
        title = "ui.pause.career.history",
        backTarget = "pause",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["pause-left-rails"] = {
              optional = true,
              backTarget = "pause.career",
              backTargetType = "route",
              preferAutoFocus = true
            },
            ["menu-content-card-1"] = {
              backTarget = "pause.career",
              backTargetType = "route",
              optional = true
            }
          }
        },
        targetScope = "pause-left-rails",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        },
        children = {
          ["financial"] = {
            screenId = "pause.career.history.financial",
            title = "ui.pause.career.financialHistory",
            backTarget = "pause.career.history",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["pause-root"] = {
                ["menu-content-card-1"] = {
                  backTarget = "pause.career.history",
                  backTargetType = "route",
                  preferAutoFocus = true
                }
              }
            },
            targetScope = "menu-content-card-1",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          },
          ["gameplay"] = {
            screenId = "pause.career.history.gameplay",
            title = "ui.pause.career.gameplayHistory",
            backTarget = "pause.career.history",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["pause-root"] = {
                ["menu-content-card-1"] = {
                  backTarget = "pause.career.history",
                  backTargetType = "route",
                  preferAutoFocus = true
                }
              }
            },
            targetScope = "menu-content-card-1",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          },
          ["logbook"] = {
            screenId = "pause.career.history.logbook",
            title = "ui.career.logbook.subHeading",
            backTarget = "pause.career.history",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["pause-root"] = {
                ["pause-history-logbook"] = {
                  backTarget = "pause.career.history",
                  backTargetType = "route",
                  preferAutoFocus = true
                }
              }
            },
            targetScope = "pause-history-logbook",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          }
        }
      },
      ["milestones"] = {
        screenId = "pause.career.milestones",
        title = "ui.career.milestones.title",
        backTarget = "pause.career.history",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["milestones"] = {
            backTarget = "pause.career.history",
            backTargetType = "route",
            preferAutoFocus = true
          }
        },
        targetScope = "milestones",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["logbook"] = {
        screenId = "pause.career.logbook",
        title = "ui.career.logbook.subHeading",
        backTarget = "pause.career",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["logbook"] = {
            backTarget = "pause.career",
            backTargetType = "route",
            preferAutoFocus = true
          }
        },
        targetScope = "logbook",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      }
    }
  },
  ["vehicleDetails"] = {
    screenId = "pause.vehicleDetails",
    title = "ui.pause.route.vehicleDetails",
    backTarget = "pause",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route"
        }
      }
    },
    targetScope = "menu-content-card-1",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["vehicleSelector"] = {
    screenId = "pause.vehicleSelector",
    title = "ui.dashboard.vehicles",
    backTarget = "pause",
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
        screenId = "pause.vehicleSelector.vehicle",
        title = {
          mode = "dynamic",
          source = "ui_vehicleSelector_general.resolveSelectedVehicleTitle",
          paramKey = "vehicleTitle",
          fallback = "ui.menu.vehicleSelector.title"
        },
        backTarget = "pause.vehicleSelector",
        onEnter = "ui_vehicleSelector_general.onVehicleRouteEnter",
        onMount = "ui_vehicleSelector_general.onVehicleRouteMount",
        onLeave = "ui_vehicleSelector_general.onVehicleRouteLeave",
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTarget = "pause.vehicleSelector",
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
    }
  },
  { include = "options",
    screenId = "pause.options",
    title = "ui.dashboard.options",
    backTarget = "pause.system",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["options-subcategories"] = {
        optional = true
      },
      ["options-content-wrapper"] = {
        optional = true,
        ["options-search"] = {
          optional = true
        }
      }
    },
    targetScope = "options-subcategories",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["category"] = {
        screenId = "pause.options.category",
        title = "ui.dashboard.options",
        backTarget = "pause.options",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["options-subcategories"] = {
            optional = true,
            backTarget = "pause.options",
            backTargetType = "route"
          },
          ["options-content-wrapper"] = {
            optional = true,
            ["options-search"] = {
              optional = true
            }
          }
        },
        targetScope = "options-subcategories",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        },
      },
      ["stats"] = {
        screenId = "pause.options.stats",
        title = "ui.statspage.title",
        backTarget = "pause.options",
        scopeTree = {
          ["options-stats-subview"] = {}
        },
        ui = {
          uiTypes = {"vue"},
          uiTypesFilter = Constants.UiTypesFilter.only,
          topBar = Constants.TopBarDefaultsHidden,
          uiApps = {
            shown = false
          }
        }
      }
    }
  },
  ["vehicle"] = {
    screenId = "pause.vehicle",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["pause-left-rails"] = {
          optional = true,
          backTarget = "pause",
          backTargetType = "route",
          preferAutoFocus = true
        },
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route"
        }
      }
    },
    targetScope = "pause-left-rails",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["parts"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.vehicle",
              backTargetType = "route"
            }
          },
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        },
      },
      ["configurationcombined"] = {
        screenId = "pause.vehicle.configurationcombined",
        title = "ui.dashboard.vehicleconfig",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              ["pause-tab-combined-parts"] = {
                backTarget = "pause.vehicle",
                backTargetType = "route"
              },
              ["pause-tab-combined-search"] = {
                backTarget = "pause-tab-combined-parts",
                backTargetType = "scope"
              },
              ["pause-tab-combined-tuning"] = {
                optional = true,
                backTarget = "pause.vehicle",
                backTargetType = "route"
              },
              ["pause-tab-combined-paint"] = {
                optional = true,
                backTarget = "pause.vehicle",
                backTargetType = "route"
              },
              ["pause-tab-combined-options"] = {
                optional = true,
                backTarget = "pause.vehicle",
                backTargetType = "route"
              }
            }
          }
        },
        targetScope = "pause-tab-combined-parts",
        children = {
          ["save"] = {
            screenId = "pause.vehicle.configurationcombined.save",
            title = "ui.pause.route.saveConfig",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["pause-root"] = {
                ["menu-content-card-1"] = {
                  backTarget = "pause.vehicle.configurationcombined",
                  backTargetType = "route"
                },
                ["menu-content-card-2"] = {
                  backTarget = "menu-content-card-1",
                  backTargetType = "scope"
                }
              }
            },
            targetScope = "menu-content-card-1",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          },
          ["configlistmanage"] = {
            screenId = "pause.vehicle.configurationcombined.configlistmanage",
            title = "ui.pause.route.manageConfigs",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["pause-root"] = {
                ["menu-content-card-1"] = {
                  backTarget = "pause.vehicle.configurationcombined",
                  backTargetType = "route"
                }
              }
            },
            targetScope = "menu-content-card-1",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          },
          ["mirrors"] = {
            screenId = "pause.vehicle.configurationcombined.mirrors",
            title = "ui.mirrors.name",
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            backTarget = "pause.vehicle.configurationcombined",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          },
        },
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["tuning"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.vehicle",
              backTargetType = "route"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["vehicleSelector"] = {
        screenId = "pause.vehicle.vehicleSelector",
        title = "ui.dashboard.vehicles",
        backTarget = "pause.vehicle",
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
            screenId = "pause.vehicle.vehicleSelector.vehicle",
            title = {
              mode = "dynamic",
              source = "ui_vehicleSelector_general.resolveSelectedVehicleTitle",
              paramKey = "vehicleTitle",
              fallback = "ui.menu.vehicleSelector.title"
            },
            backTarget = "pause.vehicle.vehicleSelector",
            onEnter = "ui_vehicleSelector_general.onVehicleRouteEnter",
            onMount = "ui_vehicleSelector_general.onVehicleRouteMount",
            onLeave = "ui_vehicleSelector_general.onVehicleRouteLeave",
            scopeTree = {
              ["root"] = {
                ["grid"] = {
                  backTarget = "pause.vehicle.vehicleSelector",
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
        }
      },
      ["debug"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.vehicle",
              backTargetType = "route",
              ["pause-vehicle-debug-content"] = {
                backTarget = "pause.vehicle",
                backTargetType = "route",
                preferAutoFocus = true
              }
            }
          }
        },
        targetScope = "pause-vehicle-debug-content",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["paint"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              ["pause-skin-paint-tab"] = {
                backTarget = "pause.vehicle",
                backTargetType = "route"
              },
              ["pause-skin-parts-tab"] = {
                backTarget = "pause.vehicle",
                backTargetType = "route"
              }
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["save"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.vehicle",
              backTargetType = "route"
            },
            ["menu-content-card-2"] = {
              backTarget = "menu-content-card-1",
              backTargetType = "scope"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["vehicleDetails"] = {
        screenId = "pause.vehicle.vehicleDetails",
        title = "ui.pause.route.vehicleDetails",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.vehicle",
              backTargetType = "route"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        },
      },
      ["packs"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.vehicle",
              backTargetType = "route"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        },
        children = {
          ["path"] = {
            onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
            onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
            onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
            scopeTree = {
              ["pause-root"] = {
                ["menu-content-card-1"] = {
                  backTarget = "pause.vehicle",
                  backTargetType = "route"
                }
              }
            },
            targetScope = "menu-content-card-1",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          }
        }
      }
    }
  },
  ["manageVehicles"] = {
    screenId = "pause.manageVehicles",
    title = "ui.radialmenu2.categories.manageVehicles",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route"
        }
      }
    },
    targetScope = "menu-content-card-1",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["vehicleDetails"] = {
        screenId = "pause.manageVehicles.vehicleDetails",
        title = "ui.pause.route.vehicleDetails",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.manageVehicles",
              backTargetType = "route"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        },
      },
      ["vehicleSelector"] = {
        screenId = "pause.manageVehicles.vehicleSelector",
        title = "ui.dashboard.vehicles",
        backTarget = "pause.manageVehicles",
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
            screenId = "pause.manageVehicles.vehicleSelector.vehicle",
            title = {
              mode = "dynamic",
              source = "ui_vehicleSelector_general.resolveSelectedVehicleTitle",
              paramKey = "vehicleTitle",
              fallback = "ui.menu.vehicleSelector.title"
            },
            backTarget = "pause.manageVehicles.vehicleSelector",
            onEnter = "ui_vehicleSelector_general.onVehicleRouteEnter",
            onMount = "ui_vehicleSelector_general.onVehicleRouteMount",
            onLeave = "ui_vehicleSelector_general.onVehicleRouteLeave",
            scopeTree = {
              ["root"] = {
                ["grid"] = {
                  backTarget = "pause.manageVehicles.vehicleSelector",
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
        }
      }
    }
  },
  ["photomode"] = {
    screenId = "pause.photomode",
    exitGuards = {"confirmPhotomodeExit"},
    onEnter = "ui_pause_routeLifecycleCallbacks.onPhotomodeEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPhotomodeMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPhotomodeLeave",
    targetScope = "photomode-hidden",
    scopeTree = {
      ["pause-root"] = {
        ["photomode-hidden"] = {},
        ["photomode-panel"] = {},
        ["photomode-gallery"] = {}
      }
    },
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["freeroamselector"] = {
    screenId = "freeroamselector",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only
    }
  },
  ["environment"] = {
    screenId = "pause.environment",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route",
          preferAutoFocus = true
        }
      }
    },
    targetScope = "menu-content-card-1",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["weather"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.environment",
              backTargetType = "route"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["simulation"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.environment",
              backTargetType = "route"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      },
      ["traffic"] = {
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.environment",
              backTargetType = "route"
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      }
    }
  },
  { include = "multiplayer",
    screenId = "pause.multiplayer",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route"
        }
      }
    },
    targetScope = "menu-content-card-1",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  { include = "freeroamLevels",
    backTarget = "pause",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["root"] = {
        ["grid"] = {
          backTargetType = "route",
          backTarget = "pause",
        },
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      }
    },
    children = {
      ["level"] = {
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTargetType = "route",
              backTarget = "pause.freeroamLevels",
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
      },
      ["vehicles"] = {
        backTarget = "pause.freeroamLevels",
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTargetType = "route",
              backTarget = "pause.freeroamLevels",
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
        children = {
          ["vehicle"] = {
            scopeTree = {
              ["root"] = {
                ["grid"] = {
                  backTargetType = "route",
                  backTarget = "pause.freeroamLevels.vehicles",
                },
                ["auxillary"] = {
                  backTarget = "grid",
                  backTargetType = "scope"
                }
              },
            },
          },
          ["options"] = {
            backTarget = "pause.freeroamLevels.vehicles",
            children = {
              ["multiplayer"] = {
                backTarget = "pause.freeroamLevels.vehicles.options",
              }
            }
          }
        }
      }
    }
  },
  ["replay"] = {
    screenId = "pause.replay",
    title = "ui.apps.replay.name",
    backTarget = "pause",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["menu-content-card-1"] = {
          backTarget = "pause",
          backTargetType = "route",
          preferAutoFocus = true,
          ["pause-replay-player"] = {
            backTarget = "menu-content-card-1",
            backTargetType = "scope",
            preferAutoFocus = true
          }
        }
      }
    },
    targetScope = "menu-content-card-1",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    },
    children = {
      ["all"] = {
        screenId = "pause.replay.all",
        title = "ui.pause.route.allReplays",
        backTarget = "pause.replay",
        onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
        onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
        onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
        scopeTree = {
          ["pause-root"] = {
            ["menu-content-card-1"] = {
              backTarget = "pause.replay",
              backTargetType = "route",
              preferAutoFocus = true
            }
          }
        },
        targetScope = "menu-content-card-1",
        ui = {
          topBar = Constants.TopBarDefaultsHidden
        }
      }
    }
  }
}

return M
