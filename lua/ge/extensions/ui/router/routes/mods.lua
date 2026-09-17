local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "mods"

M.Root = {
  screenId = "menu.mods",
  abstract = true,
  ui = {
    -- legacy Angular: without this, uiTypes inherits "vue" from the
    -- menu/pause hosts, so the router waits for a Vue mount ack that never
    -- comes and the transition time-outs, wiping back-target data
    uiTypes = {"angular"},
    uiTypesFilter = Constants.UiTypesFilter.only
  },
}

M.Children = {
  ["local"] = {
    screenId = "menu.mods.local"
  },
  ["downloaded"] = {
    screenId = "menu.mods.downloaded"
  },
  ["scheduled"] = {
    screenId = "menu.mods.scheduled"
  },
  ["repository"] = {
    screenId = "menu.mods.repository"
  },
  ["automation"] = {
    screenId = "menu.mods.automation"
  },
  ["automationDetails"] = {
    screenId = "menu.mods.automationDetails"
  },
  ["details"] = {
    screenId = "menu.mods.details"
  }
}

return M
