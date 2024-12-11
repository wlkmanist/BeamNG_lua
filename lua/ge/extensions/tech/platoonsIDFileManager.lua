local M = {}

function M.getNextPlatoonID()
    print("get  next platoonID")
    local PlatoonsData = readFile('platoonManager.txt')
    local maxID = 0
    for line in PlatoonsData:gmatch("[^\r\n]+") do
        for platoonData in line:gmatch("[^,]+") do
            local key, value = platoonData:match("([^:]+):(.+)")
            print("platoonkey and value: "..key.." "..value)
            if key == "PlatoonID" then 
                print("Platoon ID: "..value)
                maxID = value
            end
            if key == "PlatoonLeaderID" then 
                print("platoonLeaderID: "..value)
            end
        end
    end
    return maxID

end

function M.setPlatoonID(leaderID)
    local platoonID
    local PlatoonsData = readFile('platoonManager.txt')
    if PlatoonsData == nil or PlatoonsData == "" or platoonsData == " " then                                                          --creating the file for the first time and adding the first platoon ID
        print("writing in file")
        local data = string.format("PlatoonID:%sPlatoonLeaderID:%s\n", "1,", leaderID)
        writeFile('platoonManager.txt',data)
        platoonID = "1"
    else
        platoonID = M.getNextPlatoonID() + 1
        -- platoonID = tostring(platoonID)..","
        local data = string.format("PlatoonID:%sPlatoonLeaderID:%s\n", platoonID..",", leaderID)
        PlatoonsData = PlatoonsData..data
        writeFile('platoonManager.txt',PlatoonsData)
        print(ID)
    end
    return platoonID
end

function M.checkPlatoonLeader(line, leaderID)
    -- print("check platoon leader")
    print(line)
    for platoonData in line:gmatch("[^,]+") do
        local key, value = platoonData:match("([^:]+):(.+)")
        -- print("key and value: "..key.. " "..value)
        -- print("type of key:"..type(key).." "..type(value))
        if key == "PlatoonLeaderID" then
            -- print("in if leader id") 
            if tonumber(value) == leaderID then 
                return true
            else
                return false
            end
        end
    end
end


function M.getPlatoonIDByLeaderID(leaderID)
    print("get platoon id by leader ID")
    -- local platoonData = {}
    local platoonsData = readFile('platoonManager.txt')
    for line in platoonsData:gmatch("[^\r\n]+") do
        print("reading line")
        for platoonData in line:gmatch("[^,]+") do
            print("platoonDtata: "..platoonData)
            local key, value = platoonData:match("([^:]+):(.+)")
            print("platoonID: "..value)
            if key == "PlatoonID" then 
                print("in if platoon id")
                local platoonIDCheck = M.checkPlatoonLeader(line, leaderID)
                if platoonIDCheck == true then 
                    print("value of PM: "..value)
                    return value
                end
            end
        end
    end
end


function M.changePlatoonLeaderID(platoonID, platoonLeaderID)
    local foundPlatoonData = false
    local platoonsData = readFile('platoonManager.txt')
    for line in platoonsData:gmatch("[^\r\n]+") do
        lineData = line
        for platoonData in line:gmatch("[^,]+") do
            local key, value = platoonData:match("([^:]+):(.+)")
            -- print("platoonID: "..value)
            if key == "PlatoonID"  then 
                if tonumber(value) == platoonID then
                    foundPlatoonData = true
                    if data == nil then 
                        data = "PlatoonID:"..platoonID..","
                        print(data)
                    else 
                        data = data.."PlatoonID:"..platoonID..","
                        print(data)
                    end
                else 
                    if data == nil then 
                        data = lineData.."\n"
                        print(data)
                    else 
                        data = data..lineData.."\n"
                        print(data)
                    end
                end
            elseif key == "PlatoonLeaderID" and foundPlatoonData == true then
                foundPlatoonData = false
                data = data.."PlatoonLeaderID:"..platoonLeaderID.."\n"
            end
        end
    end
    writeFile('platoonManager.txt',data)
end

function M.removePlatoonData(platoonID)
    local platoonData = {}
    local data
    local lineData
    local platoonsData = readFile('platoonManager.txt')
    for line in platoonsData:gmatch("[^\r\n]+") do
        lineData = line
        for platoonData in line:gmatch("[^,]+") do
            local key, value = platoonData:match("([^:]+):(.+)")
            -- print("platoonID: "..value)
            if key == "PlatoonID"  then 
                if tonumber(value) == platoonID then
                    print("platoon to be removed "..key.." "..value)
                else
                    if data == nil then 
                        data = lineData.."\n"
                        print(data)
                    else 
                        data = data..lineData.."\n"
                        print(data)
                    end
                end
            end
        end
    end
    writeFile('platoonManager.txt',data)
end

return M