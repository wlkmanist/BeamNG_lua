return {
  ignore = true,
  id = "sandbox",
  order = 400,
  tier = "minor",
  title = "Sandbox",
  description = "Start with 50 million bucks and everthing unlocked.",
  image = "images/career/start_sandbox.jpg",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 50000000}, {label = "Starting Capital. You're rich!"})
  end,
  setupInventory = function()
    -- default placement is in front of the dealership, facing it
    spawn.safeTeleport(getPlayerVehicle(0), vec3(-808.5581055, 898.5614624, 75.51378632))
    gameplay_walk.setRot(vec3(-0.8602500027, 0.4771060959, 0.1798324389), vec3(0, 0, 1))
  end,
}
