local M = {}

M.types = {
  angular = "angular",
  vue = "vue"
}

M.routes = {
  ["menu.mainmenu"] = { name = "menu.mainmenu", type = M.types.angular },
  ["liveryMain"] = { name = "LiveryMain", type = M.types.vue },
}

return M
