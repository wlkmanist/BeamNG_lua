-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.Root = {
  screenId = "menu",
  title = "ui.common.menu",
  scopeTree = {
    ["root"] = {}
  },
  back = {
    mode = "handler",
    handler = "mainmenuExitHandler"
  },
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
  }
}

M.Children = {
  { include = "mods" },
  ["start"] = {
    screenId = "menu.start",
    children = {
      ["loadmainmenu"] = {
        screenId = "menu.start.loadmainmenu"
      }
    }
  },
  -- Legacy Angular startup route alias. Keep until startup flow is migrated to dotted route names.
  ["start_loadmainmenu"] = {
    screenId = "menu.start_loadmainmenu"
  },
  ["bigmapMenu"] = {
    screenId = "menu.bigmapMenu",
    ui = {
      uiTypes = {"vue"},
      topBar = Constants.TopBarDefaults
    }
  },
  ["campaigns"] = {
    screenId = "menu.campaigns"
  },
  ["dragRaceOverview"] = {
    screenId = "menu.dragRaceOverview"
  },
  ["careerPause"] = {
    screenId = "menu.careerPause",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaults,
      topBar = Constants.TopBarDefaults,
      uiApps = Constants.UiAppsDefaults
    }
  },
  ["freeroamconfigurator"] = {
    screenId = "menu.freeroamconfigurator",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["freeroamselector"] = {
    screenId = "menu.freeroamselector",
    onEnter = "ui_gridSelectorRouteLifecycleCallbacks.onRouteEnter",
    onMount = "ui_gridSelectorRouteLifecycleCallbacks.onRouteMount",
    onLeave = "ui_gridSelectorRouteLifecycleCallbacks.onRouteLeave",
    meta = {
      gridSelector = {
        backendName = "freeroamSelector",
        routePath = "/freeroam-selector",
        defaultPath = { keys = { "allFreeroam" } },
      }
    },
    scopeTree = {
      ["grid-selector-grid"] = {
        ["grid-selector-details"] = {
          backTarget = "grid-selector-grid",
          backTargetType = "scope"
        }
      }
    },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only
    }
  },
  { include = "freeroamLevels",
    backTarget = "menu",
    scopeTree = {
      ["root"] = {
        ["grid"] = {
          backTargetType = "route",
          backTarget = "menu",
        },
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      }
    },
    children = {
      ["level"] = {
        isMinorRoute = true,
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTargetType = "route",
              backTarget = "menu.freeroamLevels",
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
      },
      ["vehicles"] = {
        backTarget = "menu.freeroamLevels",
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTargetType = "route",
              backTarget = "menu.freeroamLevels",
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
        children = {
          ["vehicle"] = {
            isMinorRoute = true,
            scopeTree = {
              ["root"] = {
                ["grid"] = {
                  backTargetType = "route",
                  backTarget = "menu.freeroamLevels.vehicles",
                },
                ["auxillary"] = {
                  backTarget = "grid",
                  backTargetType = "scope"
                }
              },
            },
          },
          ["options"] = {
            backTarget = "menu.freeroamLevels.vehicles",
            scopeTree = {
              ["root"] = {}
            },
            targetScope = "root",
            children = {
              ["multiplayer"] = {
                isMinorRoute = true,
                backTarget = "menu.freeroamLevels.vehicles.options",
                scopeTree = {
                  ["root"] = {}
                },
                targetScope = "root",
              }
            }
          }
        }
      }
    }
  },
  ["quickraceWizard"] = {
    include = "quickraceWizard",
    backTarget = "menu.others",
    scopeTree = {
      ["root"] = {}
    },
    children = {
      ["level"] = {
        backTarget = "menu.quickraceWizard",
        scopeTree = {
          ["root"] = {
            ["grid-selector-grid"] = {
              backTargetType = "route",
              backTarget = "menu.quickraceWizard",
            },
            ["grid-selector-details"] = {
              backTarget = "grid-selector-grid",
              backTargetType = "scope"
            }
          },
        },
        children = {
          ["middle"] = {
            isMinorRoute = true,
            backTarget = "menu.quickraceWizard.level",
            scopeTree = {
              ["root"] = {
                ["grid-selector-grid"] = {
                  backTargetType = "route",
                  backTarget = "menu.quickraceWizard.level",
                },
                ["grid-selector-details"] = {
                  backTarget = "grid-selector-grid",
                  backTargetType = "scope"
                }
              },
            },
          },
        }
      },
      ["vehicle"] = {
        backTarget = "menu.quickraceWizard",
        scopeTree = {
          ["root"] = {
            ["grid-selector-grid"] = {
              backTargetType = "route",
              backTarget = "menu.quickraceWizard",
            },
            ["grid-selector-details"] = {
              backTarget = "grid-selector-grid",
              backTargetType = "scope"
            }
          },
        },
      },
    }
  },
  ["lightrunnerWizard"] = {
    include = "lightrunnerWizard",
    backTarget = "menu.others",
    scopeTree = {
      ["root"] = {}
    },
    children = {
      ["level"] = {
        backTarget = "menu.lightrunnerWizard",
        scopeTree = {
          ["root"] = {
            ["grid-selector-grid"] = {
              backTargetType = "route",
              backTarget = "menu.lightrunnerWizard",
            },
            ["grid-selector-details"] = {
              backTarget = "grid-selector-grid",
              backTargetType = "scope"
            }
          },
        },
        children = {
          ["middle"] = {
            isMinorRoute = true,
            -- Level selection is locked for lightRunner
            backTarget = "menu.lightrunnerWizard",
            scopeTree = {
              ["root"] = {
                ["grid-selector-grid"] = {
                  backTargetType = "route",
                  backTarget = "menu.lightrunnerWizard",
                },
                ["grid-selector-details"] = {
                  backTarget = "grid-selector-grid",
                  backTargetType = "scope"
                }
              },
            },
          },
        }
      },
      ["vehicle"] = {
        backTarget = "menu.lightrunnerWizard",
        scopeTree = {
          ["root"] = {
            ["grid-selector-grid"] = {
              backTargetType = "route",
              backTarget = "menu.lightrunnerWizard",
            },
            ["grid-selector-details"] = {
              backTarget = "grid-selector-grid",
              backTargetType = "scope"
            }
          },
        },
      },
    }
  },
  ["busRouteWizard"] = {
    include = "busRouteWizard",
    backTarget = "menu.others",
    scopeTree = {
      ["root"] = {}
    },
    children = {
      ["level"] = {
        backTarget = "menu.busRouteWizard",
        scopeTree = {
          ["root"] = {
            ["grid-selector-grid"] = {
              backTargetType = "route",
              backTarget = "menu.busRouteWizard",
            },
            ["grid-selector-details"] = {
              backTarget = "grid-selector-grid",
              backTargetType = "scope"
            }
          },
        },
        children = {
          ["middle"] = {
            isMinorRoute = true,
            backTarget = "menu.busRouteWizard.level",
            scopeTree = {
              ["root"] = {
                ["grid-selector-grid"] = {
                  backTargetType = "route",
                  backTarget = "menu.busRouteWizard.level",
                },
                ["grid-selector-details"] = {
                  backTarget = "grid-selector-grid",
                  backTargetType = "scope"
                }
              },
            },
          },
        }
      },
      ["vehicle"] = {
        backTarget = "menu.busRouteWizard",
        scopeTree = {
          ["root"] = {
            ["grid-selector-grid"] = {
              backTargetType = "route",
              backTarget = "menu.busRouteWizard",
            },
            ["grid-selector-details"] = {
              backTarget = "grid-selector-grid",
              backTargetType = "scope"
            }
          },
        },
      },
    }
  },
  ["environment"] = {
    screenId = "menu.environment"
  },
  ["discover"] = {
    screenId = "menu.discover",
    backTarget = "menu",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      topBar = {
        visible = false
      }
    }
  },
  ["gameContext"] = {
    screenId = "menu.gameContext"
  },
  ["gameplay"] = {
    screenId = "menu.gameplay",
    title = "Gameplay",
    onMount = "ui_gameplaySelector_general.onRouteMount",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      topBar = Constants.TopBarDefaultsHidden,
    },
    meta = {
      gridSelector = {
        backendName = "gameplaySelector",
        routePath = "/gameplay-selector",
        defaultPath = { keys = { "allGameplay" } },
      }
    },
    scopeTree = {
      ["root"] = {
        ["grid"] = {
          backTargetType = "route",
          backTarget = "menu.others",
        },
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      },
    },
    backTarget = "menu.others",
    targetScope = "grid",
    children = {
      ["type"] = {
        screenId = "menu.gameplay.type",
        title = {
          mode = "dynamic",
          source = "ui_gameplaySelector_general.resolveClusterTitle",
          paramKey = "clusterTitle",
          fallback = "Gameplay"
        },
        onEnter = "ui_gameplaySelector_general.onClusterRouteEnter",
        onMount = "ui_gameplaySelector_general.onClusterRouteMount",
        backTarget = "menu.gameplay",
        ui = {
          uiTypes = {"vue"},
          uiTypesFilter = Constants.UiTypesFilter.only,
          topBar = Constants.TopBarDefaultsHidden,
        },
        scopeTree = {
          ["root"] = {
            ["grid"] = {
              backTargetType = "route",
              backTarget = "menu.gameplay",
            },
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
        targetScope = "grid",
      }
    }
  },
  ["rallySelector"] = {
    screenId = "menu.rallySelector",
    title = "Rally",
    onMount = "ui_gameplaySelector_general.onRouteMount",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      topBar = Constants.TopBarDefaultsHidden,
    },
    meta = {
      gridSelector = {
        backendName = "gameplaySelector",
        routePath = "/gameplay-selector",
        defaultPath = { keys = { "allGameplay" } },
      }
    },
    scopeTree = {
      ["root"] = {
        ["grid"] = {
          backTargetType = "route",
          backTarget = "menu.others",
        },
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      },
    },
    targetScope = "grid",
    backTarget = "menu.others",
  },
  -- This route is handled by the menuRouteLifecycleCallbacks extension, forwarding the player to the new photomode route
  ["photomode"] = {
    --screenId = "menu.photomode",
    onEnter = "ui_menuRouteLifecycleCallbacks.onPhotomodeEnter",
  },
  ["rally"] = {
    screenId = "menu.rally"
  },
  ["levels"] = {
    screenId = "menu.levels",
    ui = {
      uiTypes = {"angular"},
      uiTypesFilter = Constants.UiTypesFilter.only,
    },
    children = {
      -- ["details"] = {}
    }
  },
  -- TODO: this needs to be setup in angular to have a child-parent relationship between levels and levelDetails
  -- currently, they are setup as siblings
  ["levelDetails"] = {
    screenId = "menu.levelDetails"
  },
  ["others"] = {
    screenId = "menu.others",
    backTarget = "menu",
    scopeTree = {
      ["root"] = {}
    }
  },
  ["extras"] = {
    screenId = "menu.extras",
    title = "Extras",
    backTarget = "menu",
    scopeTree = {
      ["mainmenu-extras"] = {}
    },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaults,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = {
        shown = false
      },
    },
    children = {
      ["licenses"] = {
        screenId = "menu.extras.licenses",
        title = "Licenses",
        backTarget = "menu.extras",
        scopeTree = {
          ["mainmenu-extras"] = {}
        }
      },
      ["help"] = {
        screenId = "menu.extras.help",
        title = "Help",
        backTarget = "menu.extras",
        scopeTree = {
          ["mainmenu-extras"] = {}
        }
      },
      ["performance"] = {
        screenId = "menu.extras.performance",
        title = "Performance",
        backTarget = "menu.extras",
        scopeTree = {
          ["mainmenu-extras"] = {}
        }
      },
      ["stats"] = {
        screenId = "menu.extras.stats",
        title = "Stats",
        backTarget = "menu.extras",
        scopeTree = {
          ["mainmenu-extras"] = {}
        }
      },
      ["credits"] = {
        screenId = "menu.extras.credits",
        title = "Credits",
        backTarget = "menu.extras",
        scopeTree = {
          ["mainmenu-extras-credits"] = {}
        },
        ui = {
          uiTypes = {"vue"},
          uiTypesFilter = Constants.UiTypesFilter.only,
          infoBar = Constants.InfoBarDefaultsHidden,
          topBar = Constants.TopBarDefaultsHidden,
          uiApps = {
            shown = false
          },
        }
      }
    }
  },
  ["modsDetails"] = {
    screenId = "menu.modsDetails"
  },
  ["options"] = {
    screenId = "menu.options",
    abstract = true,
    ui = {
      uiTypesFilter = Constants.UiTypesFilter.only,
    },
    children = {
      ["audio"] = {
        screenId = "menu.options.audio"
      },
      ["camera"] = {
        screenId = "menu.options.camera"
      },
      ["controls"] = {
        screenId = "menu.options.controls",
        children = {
          ["bindings"] = {
            screenId = "menu.options.controls.bindings",
            children = {
              ["edit"] = {
                screenId = "menu.options.controls.bindings.edit"
              },
              ["multistep"] = {
                screenId = "menu.options.controls.bindings.multistep"
              }
            }
          },
          ["filters"] = {
            screenId = "menu.options.controls.filters"
          },
          ["ffb"] = {
            screenId = "menu.options.controls.ffb",
            children = {
              ["edit"] = {
                screenId = "menu.options.controls.ffb.edit"
              }
            }
          },
          ["hardware"] = {
            screenId = "menu.options.controls.hardware"
          }
        }
      },
      ["display"] = {
        screenId = "menu.options.display"
      },
      ["gameplay"] = {
        screenId = "menu.options.gameplay"
      },
      ["graphics"] = {
        screenId = "menu.options.graphics"
      },
      ["language"] = {
        screenId = "menu.options.language"
      },
      ["other"] = {
        screenId = "menu.options.other"
      },
      ["userInterface"] = {
        screenId = "menu.options.userInterface"
      }
    }
  },
  ["release-info"] = {
    screenId = "menu.release-info",
    backTarget = "menu",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only
    }
  },
  ["replay"] = {
    screenId = "menu.replay",
    title = "ui.menu.replay",
    backTarget = "menu",
    scopeTree = {
      ["menu-replay-assembly"] = {
        ["menu-replay-browser"] = {
          backTarget = "menu",
          backTargetType = "route",
          preferAutoFocus = true
        }
      }
    },
    targetScope = "menu-replay-browser",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaults,
      topBar = Constants.TopBarDefaults,
      uiApps = {
        shown = false
      }
    }
  },
  ["scenarios"] = {
    screenId = "menu.scenarios"
  },
  ["threeElementSelect"] = {
    screenId = "menu.threeElementSelect"
  },
  ["uiSounds"] = {
    screenId = "menu.uiSounds",
    title = "UI Sounds",
    backTarget = "menu",
    scopeTree = {
      ["ui-sounds-demo"] = {}
    },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaults,
      topBar = Constants.TopBarDefaults,
      uiApps = {
        shown = false
      },
    }
  },
  ["vehicleconfig"] = {
    screenId = "menu.vehicleconfig",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.all
    },
    children = {
      ["partpacks"] = {
        screenId = "menu.vehicleconfig.partpacks"
      },
      ["parts"] = {
        screenId = "menu.vehicleconfig.parts"
      },
      ["tuning"] = {
        screenId = "menu.vehicleconfig.tuning",
        children = {
          ["mirrors"] = {
            screenId = "menu.vehicleconfig.tuning.mirrors",
            ui = {
              topBar = Constants.TopBarDefaultsHidden
            }
          },
          ["mirrors.with-angular"] = {
            screenId = "menu.vehicleconfig.tuning.mirrors.with-angular"
          },
          ["mirrors.in-garage"] = {
            screenId = "menu.vehicleconfig.tuning.mirrors.in-garage"
          }
        }
      },
      ["color"] = {
        screenId = "menu.vehicleconfig.color"
      },
      ["save"] = {
        screenId = "menu.vehicleconfig.save"
      },
      ["debug"] = {
        screenId = "menu.vehicleconfig.debug"
      }
    }
  },
  ["vehicles"] = {
    screenId = "menu.vehicles",
    ui = {
      uiTypesFilter = Constants.UiTypesFilter.only
    }
  },
  ["vehiclesdetails"] = {
    screenId = "menu.vehiclesdetails",
    ui = {
      uiTypesFilter = Constants.UiTypesFilter.only
    }
  },
  ["vehiclesnew"] = {
    screenId = "menu.vehiclesnew",
    onEnter = "ui_gridSelectorRouteLifecycleCallbacks.onRouteEnter",
    onMount = "ui_gridSelectorRouteLifecycleCallbacks.onRouteMount",
    onLeave = "ui_gridSelectorRouteLifecycleCallbacks.onRouteLeave",
    meta = {
      gridSelector = {
        backendName = "vehicleSelector",
        routePath = "/vehicle-selector",
        defaultPath = { keys = { "allModels" } },
      }
    },
    scopeTree = {
      ["grid-selector-grid"] = {
        ["grid-selector-details"] = {
          backTarget = "grid-selector-grid",
          backTargetType = "scope"
        }
      }
    },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
    }
  },
  { include = "multiplayer",
    screenId = "menu.multiplayerSessions",
    backTarget = "menu.others",
    scopeTree = {
      ["multiplayer-sessions"] = {
        ["multiplayer-required-mods"] = {
          backTarget = "multiplayer-sessions",
          backTargetType = "scope",
        },
      },
    },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      topBar = {
        visible = true
      }
    }
  },
}

return M
