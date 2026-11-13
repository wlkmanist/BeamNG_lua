return {
  id = "apmOnboarding",
  order = 100,
  tier = "major",
  image = "images/career/start_apm.jpg",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 0}, {label = "Starting Capital"})
  end,
  setupInventory = function()
    gameplay_tutorial_setup.setupVehicles()
  end,
}
