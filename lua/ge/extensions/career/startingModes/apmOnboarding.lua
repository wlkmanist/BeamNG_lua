return {
  id = "apmOnboarding",
  order = 100,
  tier = "major",
  title = "APM Onboarding",
  description = "You've been selected for Apex Performance Metrics: The pinnacle of vehicle testing. Complete introductory assessments to showcase your abilities and meet APM's world-class standards.",
  image = "images/career/start_apm.jpg",
  tag = "Recommended for new players",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 0}, {label = "Starting Capital"})
  end,
  setupInventory = function()
    gameplay_tutorial_setup.setupVehicles()
  end,
}
