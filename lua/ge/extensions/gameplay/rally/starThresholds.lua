-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Rally stage star thresholds, derived from one authored reference (gold-standard,
-- e.g. Alex Kihurani) time per stage plus the stage length:
--
--   gold   = baseline * goldMult                                  (tight pace, no reset headroom)
--   silver = baseline * silverPaceMult + K * lengthKm * perReset
--   bronze = baseline * bronzePaceMult + H * lengthKm * perReset
--
-- The additive term forgives ~K/H resets per km (each reset costs perReset seconds:
-- the flat recovery clock penalty plus the typical accel/momentum loss). Because it
-- scales with length like the baseline does, the effective time multiplier stays
-- roughly constant across stage lengths.

local M = {}

-- Pace multipliers (clean-run targets, x baseline). Gold is intentionally tight.
M.goldMult       = 1.03
M.silverPaceMult = 1.13
M.bronzePaceMult = 1.23

-- Reset tolerance (resets per km) forgiven at each tier.
M.silverResetsPerKm = 0.9   -- ~2 resets on the shortest (~2.2 km) stages
M.bronzeResetsPerKm = 2.233 -- ~5 resets on the shortest (~2.2 km) stages

-- Time added per reset for the tier headroom: flat recovery clock (~5s) plus the
-- typical accel/momentum loss (~3.5s). A single constant on purpose (per-stage
-- variance is negligible).
M.perResetSeconds = 8.5

local function round1(x)
  return math.floor(x * 10 + 0.5) / 10
end

-- baselineSeconds: authored reference time; lengthKm: stage race distance.
-- Missing/zero length -> pace-only (no reset headroom).
function M.compute(baselineSeconds, lengthKm)
  baselineSeconds = tonumber(baselineSeconds) or 0
  lengthKm = tonumber(lengthKm) or 0
  local resetHeadroom = lengthKm * M.perResetSeconds
  return {
    gold   = round1(baselineSeconds * M.goldMult),
    silver = round1(baselineSeconds * M.silverPaceMult + M.silverResetsPerKm * resetHeadroom),
    bronze = round1(baselineSeconds * M.bronzePaceMult + M.bronzeResetsPerKm * resetHeadroom),
  }
end

return M
