-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local bench = require('lua/console/bananabench')

local function exportCSV(res, outputFilename)
  local header = 'Vehicle,Count,MBeams,RealTime,SpawnTime,ExecTime'
  local row = '%s,%d,%f,%f,%f,%f'

  print('*** CSV START')

  print(header)
  local f = io.open(outputFilename, "w")

  f:write(header .. '\n')

  for vecname, v in pairs(res.tests) do
    for i, test in ipairs(v.tests) do
      local r = test.res
      local line = string.format(row,
                                 vecname,
                                 test.vehicles,
                                 r.Mbeamspersec,
                                 r.percentRealtime,
                                 r.time,
                                 r.spawntime)
      print(line)
      f:write(line .. '\n')
    end
  end
  f:close()

  print('*** CSV END')
end

local outputFilename = 'bananabench.csv'

if args and #args > 1 then
    outputFilename = args[2]
end

local res = bench.physics()

exportCSV(res, outputFilename)
