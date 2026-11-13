return {
  id = "freshStart",
  order = 200,
  tier = "minor",
  image = "images/career/start_fresh.jpg",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 10000}, {label = "Starting Capital"})
  end,
  setupInventory = function()
    -- default placement is in front of the dealership, facing it
    spawn.safeTeleport(getPlayerVehicle(0), vec3(905.54, -542.39, 164.31))
    gameplay_walk.setRot(vec3(-1, 1.5, 0.75), vec3(0, 0, 1))
  end,
}
