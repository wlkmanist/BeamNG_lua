-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

return {
  links = {
    { threshold = 5, text = nil },
    { threshold = 20, text = "into" },
    { threshold = 40, text = "and" },
  },
  units = {
    base = "m",
    large = "km",
    point = "point"
  },
  rounding = {
    small = 10,
    medium = 50,
    mediumThreshold = 100,
    large = 250,
    largeThreshold = 1000
  },
  max = 2000,
}
