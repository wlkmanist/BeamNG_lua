local M = {}
local platoonsManager = require('ge\\extensions\\tech\\platoonsIDFileManager')
local platoonsManagerFile = "platoonsIDFileManager.txt"
local fileName

function M.init(platoonLeaderID, vehicle)
    -- local emptyPlatoonmanagerData = " "
    -- writeFile(platoonsManagerFile,emptyPlatoonmanagerData)
    local platoonID = platoonsManager.setPlatoonID(platoonLeaderID)
    if M.state ==  nil then
        M.state = {
            -- Initialize your state variables here
            platoonLeaderID = platoonLeaderID,
            relayVehicles = {vehicle},
            platoonTail = vehicle
        }
    else 
        M.state.platoonLeaderID = platoonLeaderID
        M.state.relayVehicles = { vehicle }
        M.state.platoonTail = vehicle
    end
    local data = string.format("PlatoonLeaderID:%s\nPlatoonTail:%s\n", platoonLeaderID, vehicle)

    for _, vehicleID in ipairs(M.state.relayVehicles) do
        data = data .. string.format("RelayVehicles:%s\n", vehicleID)
    end
    print("init")
    -- print("outcome: "..outcome)
    fileName = "platoonArchitetureData"..platoonID..".txt"
    print("generatedFile name: "..fileName)
    writeFile(fileName,data)
    -- writeFile('platoonArchitetureData.txt',data)
    local platoonData = readFile(fileName)
    -- local platoonData = readFile('platoonArchitetureData.txt')

    if platoonData then
        for line in platoonData:gmatch("[^\r\n]+") do
            local key, value = line:match("([^:]+):(.+)")
             print("key: "..key.." value: "..value)
        end
    end
    
end

function M.getLeader(platoonID)
    fileName = "platoonArchitetureData"..platoonID..".txt"
    local platoonData = readFile(fileName) --just replace with fileName
    -- local platoonData = readFile('platoonArchitetureData.txt')
    print(readData)

    if platoonData then
        for line in platoonData:gmatch("[^\r\n]+") do
            local key, value = line:match("([^:]+):(.+)")
            if key == "PlatoonLeaderID" then
                return value
            end
        end
    end

    return nil
end

function M.getLeader()
    -- fileName = "platoonArchitetureData"..platoonID..".txt"
    local platoonData = readFile(fileName) --just replace with fileName
    -- local platoonData = readFile('platoonArchitetureData.txt')
    print(readData)

    if platoonData then
        for line in platoonData:gmatch("[^\r\n]+") do
            local key, value = line:match("([^:]+):(.+)")
            if key == "PlatoonLeaderID" then
                return value
            end
        end
    end

    return nil
end

function M.getTail()
    local platoonData = readFile(fileName) --just replace with filename
    -- local platoonData = readFile('platoonArchitetureData.txt')
    print(readData)

    if platoonData then
        for line in platoonData:gmatch("[^\r\n]+") do
            local key, value = line:match("([^:]+):(.+)")
            if key == "PlatoonTail" then
                return value
            end
        end
    end

    return nil
end



function M.addRelayVehicle(leaderID, vehicleID)
    local platoonID = platoonsManager.getPlatoonIDByLeaderID(leaderID)
    print("platonID in add relay vehicle: "..platoonID)
    fileName = "platoonArchitetureData"..platoonID..".txt"
    print("file name:  "..fileName)
    local platoonData = readFile(fileName)
    -- local platoonData = readFile('platoonArchitetureData.txt')
    local platoonLeaderID, platoonTail
    local platoonLeaderID, platoonTail
    local relayVehicles = {}
    if platoonData then
        for line in platoonData:gmatch("[^\r\n]+") do
            local key, value = line:match("([^:]+):(.+)")
            if key == "PlatoonLeaderID" then
                platoonLeaderID = value
            elseif key == "PlatoonTail" then
                platoonTail = value
            elseif key == "RelayVehicles" then 
                value = value:gsub(",$", "")
                -- Split the values by comma
                for vehicleIDToAdd in value:gmatch("[^,]+") do
                    table.insert(relayVehicles, vehicleIDToAdd)
                    print("relayVehicle adding old: "..vehicleIDToAdd)
                end
            end
        end
    end
    table.insert(relayVehicles,vehicleID)
    local data = string.format("PlatoonLeaderID:%s\nPlatoonTail:%s\n", platoonLeaderID, vehicleID)
    local relayVehiclesString
    for i, id in ipairs(relayVehicles) do
        print("index: "..i.." vehicleID: "..id)
        if relayVehiclesString == nil then
            relayVehiclesString = id .. "," 
            print("relayVehiclesString1: "..relayVehiclesString)
        else
            relayVehiclesString = relayVehiclesString .. id .. "," 
            print("relayVehiclesString2: "..relayVehiclesString)
        end
    end
    print("vehicles list: "..relayVehiclesString)
    data = data .. string.format("RelayVehicles:%s\n", relayVehiclesString)
    print("data2: "..data)
    
    -- writeFile('platoonArchitetureData.txt',data)
    writeFile(fileName,data)
end

function M.getRelayVehicles()
    print("fileName"..fileName)
    local platoonData = readFile(fileName)
    -- local platoonData = readFile('platoonArchitetureData.txt')
    local relayVehicles = {}
    print("hi")
    if platoonData then
        print("platoon data")
        for line in platoonData:gmatch("[^\r\n]+") do
            print("lines: "..line)
            local key, value = line:match("([^:]+):(.+)")
            print("key: "..key.." value: "..value)
            if key == "RelayVehicles" then
                for id in value:gmatch ("[^,]+") do
                    print(id)
                    table.insert(relayVehicles, id)
                end
            end
        end
    end
    return relayVehicles
end

function M.getRelayVehiclesWtihID(platoonID)
    print("platoonID: "..platoonID.." platoonID type: "..type(platoonID))
    fileName = "platoonArchitetureData"..platoonID..".txt"
    -- print("fileName"..fileName)
    local platoonData = readFile(fileName)
    -- local platoonData = readFile('platoonArchitetureData.txt')
    local relayVehicles = {}
    print("hi")
    if platoonData then
        print("platoon data")
        for line in platoonData:gmatch("[^\r\n]+") do
            print("lines: "..line)
            local key, value = line:match("([^:]+):(.+)")
            print("key: "..key.." value: "..value)
            if key == "RelayVehicles" then
                for id in value:gmatch ("[^,]+") do
                    print(id)
                    table.insert(relayVehicles, id)
                end
            end
        end
    end
    return relayVehicles
end

function M.updateLeader(platoonID,ID)
    print("new leaderID here: "..ID)
    print("id type: ".. type(ID))
    print("Platooon architecture platoonID: "..platoonID)
    local fileName = "platoonArchitetureData"..platoonID..".txt"
    M.state.platoonLeaderID = tonumber(ID)
    local platoonTail = M.getTail()
    local platoonLeader = ID
    local relayVehicles = M.getRelayVehiclesWtihID(platoonID)
    local data = string.format("PlatoonLeaderID:%s\nPlatoonTail:%s\n", platoonLeader, platoonTail)
    table.remove(relayVehicles,1)
    local relayVehiclesString
    for _, id in ipairs(relayVehicles) do
        if relayVehiclesString == nil then
            relayVehiclesString = id .. "," 
            print("relayVehiclesString1: "..relayVehiclesString)
        else
            relayVehiclesString = relayVehiclesString .. id .. "," 
            print("relayVehiclesString2: "..relayVehiclesString)
        end
    end
    data = data .. string.format("RelayVehicles:%s\n", relayVehiclesString)
    print("data2: "..data)
    platoonsManager.changePlatoonLeaderID(platoonID,ID)
    
    writeFile(fileName,data) --just replace with filename **need to change the leader in the platoonManager file
    -- writeFile('platoonArchitetureData.txt',data)
end

function M.getRelayVehicleIndexById(vehicleID)
    local relayVehicles = M.getRelayVehicles()
    print("relayVehicles: ")
    print(relayVehicles)

    for i, id in ipairs(relayVehicles) do
        if tonumber(id) == vehicleID then
            return i
        end
    end

    return nil
end

function M.vehicleInPlatoon(vehicleID)
    local relayVehicles = M.getRelayVehicles()
    for i, id in ipairs(relayVehicles) do
        if tonumber(id) == vehicleID then
            return true
        else 
            return false
        end

    end
end

function M.removeRelayVehicle(vehicleID)
    local removeVehicleIndex = M.getRelayVehicleIndexById(vehicleID)
    local platoonLeaderID = M.getLeader(platoonID) --editted for platoonID, should be existing previously 
    local relayVehicles = M.getRelayVehicles()
    local platoonData = readFile(fileName) --just replace with filename
    -- local platoonData = readFile('platoonArchitetureData.txt')
    table.remove(relayVehicles,removeVehicleIndex)
    local platoonTail = relayVehicles[#relayVehicles]


    local data = string.format("PlatoonLeaderID:%s\nPlatoonTail:%s\n", platoonLeaderID, platoonTail)
    local relayVehiclesString
    for _, id in ipairs(relayVehicles) do
        if relayVehiclesString == nil then
            relayVehiclesString = id .. "," 
            print("relayVehiclesString1: "..relayVehiclesString)
        else
            relayVehiclesString = relayVehiclesString .. id .. "," 
            print("relayVehiclesString2: "..relayVehiclesString)
        end
    end
    data = data .. string.format("RelayVehicles:%s\n", relayVehiclesString)
    print("data2: "..data)
    
    writeFile(fileName,data) --just replace with filename
    -- writeFile('platoonArchitetureData.txt',data)
end

function M.getPlatoonID(leaderID)
    local platoonID = platoonsManager.getPlatoonIDByLeaderID(leaderID)
    print("platoon ID: "..platoonID)
    return platoonID
end

function M.emptydata(platoonID)
    platoonsManager.removePlatoonData(platoonID)
    local data = " "
    writeFile(fileName,data) --just replace with filename **edit the platoonsManager file as well and platoonFile
    -- writeFile('platoonArchitetureData.txt',data)
end



return M