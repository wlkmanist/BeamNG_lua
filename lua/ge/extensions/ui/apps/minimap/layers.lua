-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Layer constants for minimap drawing
-- Layers are rendered in order from lowest to highest (0 = bottom, higher = top)
-- Each constant defines which layer a particular drawing element should be rendered on

local M = {}

-- Background layers (bottom-most)
M.BACKGROUND = 0
M.BG_GRID = 10

-- Road segments
M.ROADS_BG = 20
M.ROADS_FG = 30

-- Route/navigation
M.ROUTE_BG = 40
M.ROUTE_FG = 50

-- Markers and gameplay elements
M.GAMEPLAY_MARKERS = 60

-- Vehicles (drawn in order of importance)
M.VEHICLES_OTHER = 70
M.VEHICLES_POLICE = 80
M.VEHICLES_USABLE = 90
M.VEHICLE_PLAYER = 100

-- Mask layer (occlusion)
M.ROUND_OR_SQUARE_MASK = 110

-- Foreground objects (top-most)
M.COMPASS = 120
M.ROUTE_POINTER = 130
M.GAMEPLAY_POINTER = 140

-- Debug layer (absolute top)
M.DEBUG = 150

return M

