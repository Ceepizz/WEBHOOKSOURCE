local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Globals = getgenv and getgenv() or _G
local LOBBY_PLACE_ID = 3260590327

local STRATEGY_CONFIG_URL =
    "https://raw.githubusercontent.com/RyaaV2/lists/refs/heads/main/strategies/config.lua"

local SendRequest =
    request
    or http_request
    or httprequest
    or (syn and syn.request)
    or (GetDevice and GetDevice().request)

local ProgressWebhook = {}

local WebhookURL =
    tostring(
        Globals.WebhookURL
        or Globals.Webhook
        or ""
    )

local WatcherRunning = false
local Sending = false
local LastDetectedLevel = nil
local LastGameReplicator = nil
local LastGameOver = nil
local LastActiveMode = "idle"
local OwnedTowers = {}
local TowersInitialized = false

local EMBED_COLOR = 7085778

local StrategyConfig = {}

pcall(function()
    local source = game:HttpGet(STRATEGY_CONFIG_URL)
    local loader = loadstring(source)

    if loader then
        local result = loader()

        if type(result) == "table" then
            StrategyConfig = result
        end
    end
end)

local Session =
    type(Globals.__RyaWebhookSession) == "table"
    and Globals.__RyaWebhookSession
    or {
        Mode = "idle",
        StartingLevel = nil,
        StartingCoins = nil,
        StartingGems = nil,
        Matches = 0,
        Wins = 0,
        Losses = 0
    }

Globals.__RyaWebhookSession = Session

local function Trim(text)
    return tostring(text or "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function FormatNumber(value)
    local number = math.floor(tonumber(value) or 0)
    local formatted = tostring(number)

    while true do
        local updated, count =
            formatted:gsub(
                "^(-?%d+)(%d%d%d)",
                "%1,%2"
            )

        formatted = updated

        if count == 0 then
            break
        end
    end

    return formatted
end

local function FormatReward(value)
    value = tonumber(value)

    if value == nil then
        return "Unavailable"
    end

    return "+" .. FormatNumber(
        math.max(
            math.floor(value),
            0
        )
    )
end

local function StripStatusPrefix(text)
    text = Trim(text)

    text =
        text:gsub(
            "^STATUS:%s*",
            ""
        )

    text =
        text:gsub(
            "^Status:%s*",
            ""
        )

    return Trim(text)
end

local function AddField(
    fields,
    name,
    value,
    inline
)
    table.insert(fields, {
        name = tostring(name or ""),
        value = tostring(value or "Unavailable"),
        inline = inline == true
    })
end

local function GetGameReplicator()
    local stateReplicators =
        ReplicatedStorage:FindFirstChild(
            "StateReplicators"
        )

    return stateReplicators
        and stateReplicators:FindFirstChild(
            "GameStateReplicator"
        )
        or nil
end

local function GetPlayerReplicator()
    local stats = shared.AutoProgressStats

    if stats and stats.GetPlayerReplicator then
        local ok, result = pcall(function()
            return stats.GetPlayerReplicator()
        end)

        if ok and result then
            return result
        end
    end

    local stateReplicators =
        ReplicatedStorage:FindFirstChild(
            "StateReplicators"
        )

    if not stateReplicators then
        return nil
    end

    for _, replicator in ipairs(
        stateReplicators:GetChildren()
    ) do
        if replicator.Name == "PlayerReplicator"
            and tonumber(
                replicator:GetAttribute("UserId")
            ) == LocalPlayer.UserId then

            return replicator
        end
    end

    return nil
end

local function ReadDirectStat(name)
    local direct =
        LocalPlayer:FindFirstChild(name)

    if direct
        and direct.Value ~= nil then

        return tonumber(direct.Value)
    end

    local attribute =
        LocalPlayer:GetAttribute(name)

    if attribute ~= nil then
        return tonumber(attribute)
    end

    local leaderstats =
        LocalPlayer:FindFirstChild("leaderstats")

    local stat =
        leaderstats
        and leaderstats:FindFirstChild(name)

    if stat
        and stat.Value ~= nil then

        return tonumber(stat.Value)
    end

    return nil
end

local function GetProgressSnapshot()
    local snapshot = {}
    local stats = shared.AutoProgressStats

    if stats
        and stats.GetSnapshot then

        local ok, result = pcall(function()
            return stats.GetSnapshot()
        end)

        if ok
            and type(result) == "table" then

            for key, value in pairs(result) do
                snapshot[key] = value
            end
        end
    end

    if snapshot.Level == nil then
        snapshot.Level =
            ReadDirectStat("Level")
    end

    if game.PlaceId == LOBBY_PLACE_ID
        and Globals.__RyaGetLobbyCurrencyBalance then

        local okCoins, lobbyCoins =
            pcall(function()
                return
                    Globals.__RyaGetLobbyCurrencyBalance(
                        "Coins"
                    )
            end)

        if okCoins
            and tonumber(lobbyCoins) ~= nil then

            snapshot.Coins =
                tonumber(lobbyCoins)
        end

        local okGems, lobbyGems =
            pcall(function()
                return
                    Globals.__RyaGetLobbyCurrencyBalance(
                        "Gems"
                    )
            end)

        if okGems
            and tonumber(lobbyGems) ~= nil then

            snapshot.Gems =
                tonumber(lobbyGems)
        end
    end

    if snapshot.Coins == nil
        and stats
        and stats.GetCoins then

        local ok, value = pcall(function()
            return stats.GetCoins()
        end)

        if ok
            and tonumber(value) ~= nil then

            snapshot.Coins =
                tonumber(value)
        end
    end

    if snapshot.Gems == nil
        and stats
        and stats.GetGems then

        local ok, value = pcall(function()
            return stats.GetGems()
        end)

        if ok
            and tonumber(value) ~= nil then

            snapshot.Gems =
                tonumber(value)
        end
    end

    snapshot.Level =
        tonumber(snapshot.Level) or 0

    snapshot.Coins =
        tonumber(snapshot.Coins) or 0

    snapshot.Gems =
        tonumber(snapshot.Gems) or 0

    snapshot.GatlingOwned =
        snapshot.GatlingOwned == true

    return snapshot
end

local function ReadNumberObject(object)
    if not object then
        return nil
    end

    local value

    pcall(function()
        value = object.ContentText
    end)

    if value == nil
        or tostring(value) == "" then

        pcall(function()
            value = object.Text
        end)
    end

    if value == nil
        or tostring(value) == "" then

        pcall(function()
            value = object.Value
        end)
    end

    local text =
        tostring(value or "")
        :gsub(",", "")

    return tonumber(
        text:match("%d+")
    )
end

local function GetRewardScreenLevel()
    local rewards =
        PlayerGui:FindFirstChild(
            "ReactGameNewRewards"
        )

    local frame =
        rewards
        and rewards:FindFirstChild("Frame")

    local gameOver =
        frame
        and frame:FindFirstChild("gameOver")

    local rewardsScreen =
        gameOver
        and gameOver:FindFirstChild(
            "RewardsScreen"
        )

    local other =
        rewardsScreen
        and rewardsScreen:FindFirstChild("other")

    local levelFrame =
        other
        and other:FindFirstChild("level")

    local currentLevel =
        levelFrame
        and levelFrame:FindFirstChild(
            "currentLevel"
        )

    return ReadNumberObject(currentLevel)
end

local function GetCurrentLevel()
    local rewardLevel =
        GetRewardScreenLevel()

    if rewardLevel
        and rewardLevel > 0 then

        return rewardLevel
    end

    local snapshot =
        GetProgressSnapshot()

    if snapshot.Level > 0 then
        return snapshot.Level
    end

    return nil
end

local function GetOwnedTowers()
    local inventory =
        PlayerGui:FindFirstChild(
            "ReactUniversalInventoryView"
        )

    if not inventory then
        return nil
    end

    local holder =
        inventory:FindFirstChild("Holder")

    local windowFrame =
        holder
        and holder:FindFirstChild(
            "windowFrame"
        )

    local towerFrame =
        windowFrame
        and windowFrame:FindFirstChild(
            "towersInventoryFrame"
        )

    if not towerFrame then
        return nil
    end

    local owned = {}
    local foundAny = false

    for _, object in ipairs(
        towerFrame:GetDescendants()
    ) do
        if object:IsA("Frame") then
            local refLabel =
                object:FindFirstChild(
                    "refLabel",
                    true
                )

            local background =
                object:FindFirstChild(
                    "background",
                    true
                )

            if refLabel
                and background then

                local towerName =
                    Trim(refLabel.Text)

                if towerName ~= "" then
                    foundAny = true

                    if background.Visible == false then
                        owned[towerName] = true
                    end
                end
            end
        end
    end

    if not foundAny then
        return nil
    end

    return owned
end

local function RefreshOwnedTowerCache()
    local currentOwned =
        GetOwnedTowers()

    if currentOwned then
        OwnedTowers = currentOwned
        TowersInitialized = true
    end

    return TowersInitialized
        and OwnedTowers
        or {}
end

local function GetTowerConfig()
    local towers =
        type(StrategyConfig) == "table"
        and type(StrategyConfig.Towers) == "table"
        and StrategyConfig.Towers
        or {}

    local priority =
        type(towers.Priority) == "table"
        and towers.Priority
        or {}

    local info =
        type(towers.Info) == "table"
        and towers.Info
        or {}

    local golden =
        type(towers.GoldenTowers) == "table"
        and towers.GoldenTowers
        or {}

    return priority, info, golden
end

local function FindTowerInfo(towerName)
    local _, info =
        GetTowerConfig()

    return type(info[tostring(towerName)]) == "table"
        and info[tostring(towerName)]
        or nil
end

local function GetNormalTowerCounts(owned)
    local priority, info =
        GetTowerConfig()

    local totalOwned = 0
    local totalCount = 0
    local coinOwned = 0
    local coinCount = 0
    local gemOwned = 0
    local gemCount = 0

    for _, towerName in ipairs(priority) do
        local towerInfo =
            info[towerName]

        if type(towerInfo) == "table"
            and tostring(
                towerInfo.Type or ""
            ) ~= "Unavailable" then

            totalCount += 1

            if owned[tostring(towerName)] == true then
                totalOwned += 1
            end

            if tostring(
                towerInfo.Type or ""
            ) == "Currency" then

                local currency =
                    tostring(
                        towerInfo.Currency
                        or ""
                    )

                if currency == "Coins" then
                    coinCount += 1

                    if owned[tostring(towerName)] == true then
                        coinOwned += 1
                    end
                elseif currency == "Gems" then
                    gemCount += 1

                    if owned[tostring(towerName)] == true then
                        gemOwned += 1
                    end
                end
            end
        end
    end

    return {
        TotalOwned = totalOwned,
        Total = totalCount,
        CoinOwned = coinOwned,
        CoinTotal = coinCount,
        GemOwned = gemOwned,
        GemTotal = gemCount
    }
end

local function GetGoldenOwnedLookup()
    if Globals.__RyaGetGoldenTowersOwned then
        local ok, result =
            pcall(function()
                return
                    Globals.__RyaGetGoldenTowersOwned()
            end)

        if ok
            and type(result) == "table" then

            return result
        end
    end

    local owned = {}

    if not filtergc then
        return owned
    end

    local stores =
        filtergc("table", {
            Keys = {"getState"}
        }) or {}

    for _, store in ipairs(stores) do
        local success, stateData =
            pcall(
                store.getState,
                store
            )

        if success
            and type(stateData) == "table" then

            local skins =
                stateData.skins
                or stateData.Skins
                or stateData.towerSkins
                or stateData.TowerSkins

            if type(skins) == "table" then
                for towerName, ownedSkins
                    in pairs(skins) do

                    if type(ownedSkins) == "table" then
                        for _, skinName
                            in pairs(ownedSkins) do

                            if tostring(skinName)
                                == "Golden" then

                                owned[
                                    tostring(towerName)
                                ] = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    return owned
end

local function GetGoldenCounts()
    local _, _, goldenTowers =
        GetTowerConfig()

    local ownedLookup =
        GetGoldenOwnedLookup()

    local ownedCount = 0

    for _, towerName
        in ipairs(goldenTowers) do

        if ownedLookup[
            tostring(towerName)
        ] == true then

            ownedCount += 1
        end
    end

    return ownedCount, #goldenTowers
end

local function ReadSkillNodeLevel(nodeId)
    local node =
        workspace:FindFirstChild(
            tostring(nodeId)
        )

    local gui =
        node
        and node:FindFirstChild(
            "TileSurfaceGui"
        )

    local frame =
        gui
        and gui:FindFirstChild("Frame")

    local skillLevel =
        frame
        and frame:FindFirstChild(
            "SkillLevel"
        )

    if not skillLevel then
        return nil, nil
    end

    local text =
        tostring(skillLevel.Text or "")

    local current, maximum =
        text:match(
            "(%d+)%s*/%s*(%d+)"
        )

    current = tonumber(current)
    maximum = tonumber(maximum)

    if current
        and maximum then

        return current, maximum
    end

    local maxOnly =
        tonumber(
            text:match(
                "MAX%s*%[(%d+)%]"
            )
        )

    if maxOnly then
        return maxOnly, maxOnly
    end

    return nil, nil
end

local function GetSkillTreeCounts()
    local skillTree =
        type(StrategyConfig.SkillTree)
            == "table"
        and StrategyConfig.SkillTree
        or nil

    local priority =
        skillTree
        and type(skillTree.Priority)
            == "table"
        and skillTree.Priority
        or {}

    local currentTotal = 0
    local targetTotal = 0
    local foundAny = false

    for _, entry in ipairs(priority) do
        local nodeId =
            tonumber(
                entry.Id
                or entry[1]
            )

        local targetLevel =
            tonumber(
                entry.TargetLevel
                or entry[2]
            )

        if nodeId
            and targetLevel then

            local current, maximum =
                ReadSkillNodeLevel(nodeId)

            if current
                and maximum then

                local target =
                    math.min(
                        targetLevel,
                        maximum
                    )

                currentTotal +=
                    math.min(
                        current,
                        target
                    )

                targetTotal += target
                foundAny = true
            end
        end
    end

    if foundAny
        and targetTotal > 0 then

        return currentTotal, targetTotal
    end

    return nil, nil
end

local function GetFarm()
    return shared.AutoProgress
end

local function GetFarmStatus(mode)
    local farm = GetFarm()

    if mode == "story"
        and farm
        and farm.GetStoryStatus then

        local ok, value =
            pcall(function()
                return farm.GetStoryStatus()
            end)

        if ok
            and value then

            return
                StripStatusPrefix(value)
        end
    end

    if farm
        and farm.GetStatus then

        local ok, value =
            pcall(function()
                return farm.GetStatus()
            end)

        if ok
            and value then

            return
                StripStatusPrefix(value)
        end
    end

    return "Running"
end

local function DetectMode()
    if Globals.AutoMaxEnabled == true then
        return "auto_max"
    end

    if Globals.AutoBuyAllTowersEnabled == true then
        return "auto_buy"
    end

    if Globals.AutoFarmTowerXP == true then
        return "tower_xp"
    end

    if Globals.StoryModeEnabled == true then
        return "story"
    end

    if Globals.AutoProgressEnabled == true then
        return "gatling"
    end

    if Globals.__RyaStoryModeCompleted == true
        and LastActiveMode == "story" then

        return "story"
    end

    return "idle"
end

local function GetModeRunningLabel(mode)
    if mode == "story"
        and Globals.__RyaStoryModeCompleted == true then

        return "COMPLETED"
    end

    local active =
        (mode == "auto_max"
            and Globals.AutoMaxEnabled == true)
        or (mode == "auto_buy"
            and Globals.AutoBuyAllTowersEnabled == true)
        or (mode == "tower_xp"
            and Globals.AutoFarmTowerXP == true)
        or (mode == "story"
            and Globals.StoryModeEnabled == true)
        or (mode == "gatling"
            and Globals.AutoProgressEnabled == true)

    return active
        and "RUNNING"
        or "STOPPED"
end

local function EnsureSession(mode, snapshot)
    snapshot =
        snapshot
        or GetProgressSnapshot()

    if Session.Mode ~= mode then
        Session.Mode = mode
        Session.StartingLevel =
            tonumber(snapshot.Level) or 0
        Session.StartingCoins =
            tonumber(snapshot.Coins) or 0
        Session.StartingGems =
            tonumber(snapshot.Gems) or 0
        Session.Matches = 0
        Session.Wins = 0
        Session.Losses = 0
    elseif Session.StartingLevel == nil then
        Session.StartingLevel =
            tonumber(snapshot.Level) or 0
        Session.StartingCoins =
            tonumber(snapshot.Coins) or 0
        Session.StartingGems =
            tonumber(snapshot.Gems) or 0
    end

    Globals.__RyaWebhookSession =
        Session
end

local function ReadRewardAttribute(names)
    local rep =
        GetPlayerReplicator()

    if not rep then
        return nil
    end

    for _, name in ipairs(names) do
        local value =
            tonumber(
                rep:GetAttribute(name)
            )

        if value ~= nil then
            return value
        end
    end

    return nil
end

local function GetMatchRewards()
    return {
        Coins =
            ReadRewardAttribute({
                "CoinsReward",
                "CoinReward"
            }),

        Gems =
            ReadRewardAttribute({
                "GemsReward",
                "GemReward"
            }),

        XP =
            ReadRewardAttribute({
                "XPReward",
                "ExpReward",
                "ExperienceReward",
                "Experience"
            })
    }
end

local function GetMatchResult(rep)
    rep = rep or GetGameReplicator()

    if rep then
        for _, name in ipairs({
            "Won",
            "Win",
            "Victory"
        }) do
            local value =
                rep:GetAttribute(name)

            if type(value) == "boolean" then
                return value
                    and "win"
                    or "loss"
            end
        end

        for _, name in ipairs({
            "Result",
            "Outcome",
            "GameResult"
        }) do
            local value =
                tostring(
                    rep:GetAttribute(name)
                    or ""
                ):lower()

            if value:find("victory", 1, true)
                or value:find("win", 1, true) then

                return "win"
            end

            if value:find("defeat", 1, true)
                or value:find("loss", 1, true)
                or value:find("lose", 1, true) then

                return "loss"
            end
        end
    end

    local rewards =
        PlayerGui:FindFirstChild(
            "ReactGameNewRewards"
        )

    if rewards then
        for _, object
            in ipairs(
                rewards:GetDescendants()
            ) do

            if object:IsA("TextLabel")
                or object:IsA("TextButton") then

                local text =
                    tostring(
                        object.Text
                        or ""
                    ):lower()

                if text:find(
                    "victory",
                    1,
                    true
                ) then

                    return "win"
                end

                if text:find(
                    "defeat",
                    1,
                    true
                ) then

                    return "loss"
                end
            end
        end
    end

    return nil
end

local function GetAutoProgressTargetLevel()
    if Globals.__RyaGetAutoProgressTargetLevel then
        local ok, result =
            pcall(function()
                return
                    Globals.__RyaGetAutoProgressTargetLevel()
            end)

        if ok
            and tonumber(result) then

            return tonumber(result)
        end
    end

    return 175
end

local function GetCurrentRouteLabel(level)
    local farm = GetFarm()

    if farm
        and farm.GetRouteKey then

        local ok, route =
            pcall(function()
                return farm.GetRouteKey(level)
            end)

        route =
            ok
            and tostring(route or "")
            or ""

        if route ~= "" then
            return
                route:match("^[^.]+")
                or route
        end
    end

    return "Progression"
end

local function FindNextMissingCurrencyTower(
    owned,
    currency
)
    local priority, info =
        GetTowerConfig()

    for _, towerName in ipairs(priority) do
        local towerInfo =
            info[towerName]

        if type(towerInfo) == "table"
            and tostring(
                towerInfo.Type
                or ""
            ) == "Currency"
            and tostring(
                towerInfo.Currency
                or ""
            ) == currency
            and owned[
                tostring(towerName)
            ] ~= true then

            return towerName, towerInfo
        end
    end

    return nil, nil
end

local function GetSavingTower()
    local farm = GetFarm()

    if farm
        and farm.GetSavingTower then

        local ok, result =
            pcall(function()
                return farm.GetSavingTower()
            end)

        if ok
            and Trim(result) ~= "" then

            return Trim(result)
        end
    end

    local status =
        GetFarmStatus(
            DetectMode()
        )

    local parsed =
        status:match(
            "Saving for%s+([^%(]+)"
        )

    return Trim(parsed)
end

local function GetTargetInfo(mode)
    local owned =
        RefreshOwnedTowerCache()

    local towerName =
        GetSavingTower()

    if towerName ~= "" then
        local info =
            FindTowerInfo(towerName)

        return {
            Name = towerName,
            Currency =
                info
                and tostring(
                    info.Currency
                    or ""
                )
                or "",
            Price =
                info
                and tonumber(
                    info.Price
                    or info.Cost
                )
                or nil
        }
    end

    if mode == "auto_buy"
        or mode == "auto_max" then

        local coinTower, coinInfo =
            FindNextMissingCurrencyTower(
                owned,
                "Coins"
            )

        if coinTower then
            return {
                Name = coinTower,
                Currency = "Coins",
                Price =
                    tonumber(
                        coinInfo.Price
                        or coinInfo.Cost
                    )
            }
        end

        local gemTower, gemInfo =
            FindNextMissingCurrencyTower(
                owned,
                "Gems"
            )

        if gemTower then
            return {
                Name = gemTower,
                Currency = "Gems",
                Price =
                    tonumber(
                        gemInfo.Price
                        or gemInfo.Cost
                    )
            }
        end

        local goldenOwned,
            goldenTotal =
            GetGoldenCounts()

        if goldenTotal > 0
            and goldenOwned < goldenTotal then

            return {
                Name = "Golden Crate",
                Currency = "Coins",
                Price = 50000
            }
        end
    end

    return {
        Name = "None",
        Currency = "",
        Price = nil
    }
end

local function FormatTarget(target)
    local first =
        tostring(
            target.Name
            or "None"
        )

    if target.Price
        and target.Currency ~= "" then

        return
            first
            .. "\nCost: "
            .. FormatNumber(target.Price)
            .. " "
            .. target.Currency
    end

    return first
end

local function GetTowerXPLevel()
    local inventory =
        PlayerGui:FindFirstChild(
            "ReactUniversalInventoryView"
        )

    local holder =
        inventory
        and inventory:FindFirstChild("Holder")

    local buttons =
        holder
        and holder:FindFirstChild("Buttons")

    local towerLevel =
        buttons
        and buttons:FindFirstChild(
            "towerLevel"
        )

    local content =
        towerLevel
        and towerLevel:FindFirstChild(
            "content"
        )

    local currentLevel =
        content
        and content:FindFirstChild(
            "currentLevel"
        )

    local level =
        currentLevel
        and ReadNumberObject(currentLevel)
        or nil

    if level ~= nil then
        Globals.__RyaWebhookTowerXPLevel =
            level
    end

    return level
        or tonumber(
            Globals.__RyaWebhookTowerXPLevel
        )
        or 0
end

local function GetStoryInfo()
    local story =
        type(StrategyConfig.Story) == "table"
        and StrategyConfig.Story
        or {}

    local order =
        type(story.Order) == "table"
        and story.Order
        or {}

    local missions =
        type(story.Missions) == "table"
        and story.Missions
        or {}

    local rep =
        GetGameReplicator()

    local missionId =
        rep
        and tostring(
            rep:GetAttribute("Difficulty")
            or ""
        )
        or ""

    if missionId == ""
        or (
            missions[missionId] == nil
            and not missionId:match(
                "^Chapter%d+Mission%d+$"
            )
        ) then

        local status =
            GetFarmStatus("story")

        for id, config in pairs(missions) do
            local name =
                type(config) == "table"
                and tostring(
                    config.Name
                    or ""
                )
                or ""

            if name ~= ""
                and status:find(
                    name,
                    1,
                    true
                ) then

                missionId = tostring(id)
                break
            end
        end
    end

    local index = nil

    for i, id in ipairs(order) do
        if tostring(id) == missionId then
            index = i
            break
        end
    end

    local chapter, mission =
        missionId:match(
            "^Chapter(%d+)Mission(%d+)$"
        )

    chapter = tonumber(chapter)
    mission = tonumber(mission)

    local chapterMissionTotal = 0

    if chapter ~= nil then
        for _, id in ipairs(order) do
            local chapterNumber =
                tonumber(
                    tostring(id):match(
                        "^Chapter(%d+)Mission%d+$"
                    )
                )

            if chapterNumber == chapter then
                chapterMissionTotal += 1
            end
        end
    end

    local config =
        missions[missionId]

    local missionName =
        type(config) == "table"
        and tostring(
            config.Name
            or ""
        )
        or ""

    if missionName == "" then
        missionName =
            mission
            and (
                "Mission "
                .. tostring(mission)
            )
            or missionId
    end

    return {
        MissionId = missionId,
        MissionName = missionName,
        Chapter = chapter,
        Mission = mission,
        ChapterMissionTotal =
            chapterMissionTotal,
        Index = index,
        Total = #order
    }
end

local function BuildMatchRewardsField(rewards)
    return
        "Coins: **"
        .. FormatReward(rewards.Coins)
        .. "**\nGems: **"
        .. FormatReward(rewards.Gems)
        .. "**\nXP: **"
        .. FormatReward(rewards.XP)
        .. "**"
end

local function BuildAutoMaxEmbed(
    snapshot,
    data
)
    local fields = {}
    local eventType =
        tostring(data.EventType or "")

    local title =
        eventType == "match_complete"
        and "⚡ Auto Max Account — Match Complete"
        or "⚡ Auto Max Account — Current Progress"

    local status =
        GetModeRunningLabel(
            "auto_max"
        )

    AddField(
        fields,
        "📋 Account Overview",
        "┃ Status: **"
            .. status
            .. "**\n┃ Current Level: **"
            .. FormatNumber(snapshot.Level)
            .. "**\n┃ Starting Level: **"
            .. FormatNumber(
                Session.StartingLevel
                or snapshot.Level
            )
            .. "**",
        false
    )

    AddField(
        fields,
        "⚙️ Settings",
        "Mode: **Auto Max**"
            .. "\nAll Towers: "
            .. (
                Globals.AutoMaxAllTowers == true
                and "✅"
                or "❌"
            )
            .. "\nAll Skill Tree: "
            .. (
                Globals.AutoMaxAllSkillTree == true
                and "✅"
                or "❌"
            ),
        true
    )

    AddField(
        fields,
        "📈 Session Info",
        "Matches: **"
            .. FormatNumber(Session.Matches)
            .. "**\nWins: **"
            .. FormatNumber(Session.Wins)
            .. "**\nLosses: **"
            .. FormatNumber(Session.Losses)
            .. "**",
        true
    )

    if eventType == "match_complete" then
        AddField(
            fields,
            "✨ Match Rewards",
            BuildMatchRewardsField(
                data.Rewards or {}
            ),
            false
        )
    end

    local target =
        GetTargetInfo("auto_max")

    AddField(
        fields,
        "📊 Session Totals",
        "Coins: **"
            .. FormatNumber(snapshot.Coins)
            .. "**\nGems: **"
            .. FormatNumber(snapshot.Gems)
            .. "**",
        true
    )

    AddField(
        fields,
        "🎯 Current Target",
        FormatTarget(target),
        true
    )

    AddField(
        fields,
        "🔄 Current State",
        GetFarmStatus("auto_max"),
        false
    )

    local owned =
        RefreshOwnedTowerCache()

    local towerCounts =
        GetNormalTowerCounts(owned)

    local goldenOwned,
        goldenTotal =
        GetGoldenCounts()

    local skillCurrent,
        skillTarget =
        GetSkillTreeCounts()

    local skillText =
        skillCurrent
        and skillTarget
        and (
            FormatNumber(skillCurrent)
            .. " / "
            .. FormatNumber(skillTarget)
        )
        or "Unavailable"

    local coinTarget = nil
    local farm = GetFarm()

    if farm
        and farm.GetAutoMaxCoinFarmState then

        local ok, active, targetAmount =
            pcall(function()
                return
                    farm.GetAutoMaxCoinFarmState()
            end)

        if ok
            and active == true
            and tonumber(targetAmount)
            and tonumber(targetAmount) > 0 then

            coinTarget =
                tonumber(targetAmount)
        end
    end

    local coinText =
        FormatNumber(snapshot.Coins)

    if coinTarget then
        coinText =
            coinText
            .. " / "
            .. FormatNumber(coinTarget)
    end

    local goldenText =
        FormatNumber(goldenOwned)
        .. " / "
        .. FormatNumber(goldenTotal)

    if goldenTotal > 0
        and goldenOwned >= goldenTotal then

        goldenText =
            "✅ " .. goldenText
    end

    AddField(
        fields,
        "📈 Auto Max Progress",
        "Level: **"
            .. FormatNumber(snapshot.Level)
            .. " / "
            .. FormatNumber(
                GetAutoProgressTargetLevel()
            )
            .. "**\nCoins: **"
            .. coinText
            .. "**\nGems: **"
            .. FormatNumber(snapshot.Gems)
            .. "**\nTowers: **"
            .. FormatNumber(
                towerCounts.TotalOwned
            )
            .. " / "
            .. FormatNumber(
                towerCounts.Total
            )
            .. "**\nSkill Tree: **"
            .. skillText
            .. "**\nGolden Towers: **"
            .. goldenText
            .. "**\nGatling Gun: **"
            .. (
                snapshot.GatlingOwned
                and "✅ Purchased"
                or "🔒 Locked"
            )
            .. "**",
        false
    )

    return title, fields
end

local function BuildGatlingEmbed(
    snapshot,
    data
)
    local fields = {}
    local eventType =
        tostring(data.EventType or "")

    local targetLevel =
        GetAutoProgressTargetLevel()

    local title =
        eventType == "match_complete"
        and "🔫 Auto Farm Until Gatling — Match Complete"
        or "🔫 Auto Farm Until Gatling — Current Progress"

    AddField(
        fields,
        "📋 Progress Overview",
        "┃ Status: **"
            .. GetModeRunningLabel(
                "gatling"
            )
            .. "**\n┃ Current Level: **"
            .. FormatNumber(snapshot.Level)
            .. "**\n┃ Starting Level: **"
            .. FormatNumber(
                Session.StartingLevel
                or snapshot.Level
            )
            .. "**\n┃ Gatling Gun: **"
            .. (
                snapshot.GatlingOwned
                and "✅ Purchased"
                or "🔒 Locked"
            )
            .. "**",
        false
    )

    AddField(
        fields,
        "⚙️ Farm Settings",
        "Strategy: **"
            .. (
                Globals.AutoFarmGatlingStrategy
                    == "Win"
                and "Win"
                or "Lose"
            )
            .. "**\nTarget Level: **"
            .. FormatNumber(targetLevel)
            .. "**\nCurrent Mode: **"
            .. GetCurrentRouteLabel(
                snapshot.Level
            )
            .. "**",
        true
    )

    AddField(
        fields,
        "📈 Session Info",
        "Matches: **"
            .. FormatNumber(Session.Matches)
            .. "**\nWins: **"
            .. FormatNumber(Session.Wins)
            .. "**\nLosses: **"
            .. FormatNumber(Session.Losses)
            .. "**",
        true
    )

    if eventType == "match_complete" then
        AddField(
            fields,
            "✨ Match Rewards",
            BuildMatchRewardsField(
                data.Rewards or {}
            ),
            false
        )
    end

    AddField(
        fields,
        "📊 Session Totals",
        "Coins: **"
            .. FormatNumber(snapshot.Coins)
            .. "**\nGems: **"
            .. FormatNumber(snapshot.Gems)
            .. "**\nLevels Gained: **+"
            .. FormatNumber(
                math.max(
                    snapshot.Level
                    - (
                        tonumber(
                            Session.StartingLevel
                        )
                        or snapshot.Level
                    ),
                    0
                )
            )
            .. "**",
        true
    )

    local currentGoal

    if snapshot.GatlingOwned then
        currentGoal =
            "Gatling Gun Purchased"
    elseif snapshot.Level < targetLevel then
        currentGoal =
            "Reach Level "
            .. FormatNumber(targetLevel)
            .. "\nCurrent: "
            .. FormatNumber(snapshot.Level)
            .. " / "
            .. FormatNumber(targetLevel)
    else
        currentGoal =
            "Purchase Gatling Gun"
    end

    AddField(
        fields,
        "🎯 Current Goal",
        currentGoal,
        true
    )

    local currentState =
        snapshot.GatlingOwned
        and "Gatling Gun Purchased — Auto Farm Complete"
        or GetFarmStatus("gatling")

    AddField(
        fields,
        "🔄 Current State",
        currentState,
        false
    )

    AddField(
        fields,
        "🔫 Gatling Progress",
        "Current Level: **"
            .. FormatNumber(snapshot.Level)
            .. "**\nTarget Level: **"
            .. FormatNumber(targetLevel)
            .. "**\nGatling Gun: **"
            .. (
                snapshot.GatlingOwned
                and "✅ Purchased"
                or "🔒 Locked"
            )
            .. "**\nNext Action: **"
            .. (
                snapshot.GatlingOwned
                and "Complete"
                or snapshot.Level < targetLevel
                    and "Continue Farming"
                    or "Purchase Gatling Gun"
            )
            .. "**",
        false
    )

    return title, fields
end

local function BuildAutoBuyEmbed(
    snapshot,
    data
)
    local fields = {}
    local eventType =
        tostring(data.EventType or "")

    local title =
        eventType == "match_complete"
        and "🏰 Auto Buy All Towers — Match Complete"
        or "🏰 Auto Buy All Towers — Current Progress"

    local target =
        GetTargetInfo("auto_buy")

    local currentFarm =
        target.Currency ~= ""
        and target.Currency
        or "Checking"

    AddField(
        fields,
        "📋 Farm Overview",
        "┃ Status: **"
            .. GetModeRunningLabel(
                "auto_buy"
            )
            .. "**\n┃ Current Level: **"
            .. FormatNumber(snapshot.Level)
            .. "**\n┃ Current Farm: **"
            .. currentFarm
            .. "**",
        false
    )

    if eventType == "match_complete" then
        AddField(
            fields,
            "✨ Match Rewards",
            BuildMatchRewardsField(
                data.Rewards or {}
            ),
            false
        )
    end

    AddField(
        fields,
        "📊 Session Totals",
        "Coins: **"
            .. FormatNumber(snapshot.Coins)
            .. "**\nGems: **"
            .. FormatNumber(snapshot.Gems)
            .. "**",
        true
    )

    AddField(
        fields,
        "🎯 Current Target",
        FormatTarget(target),
        true
    )

    AddField(
        fields,
        "🔄 Current State",
        GetFarmStatus("auto_buy"),
        false
    )

    local owned =
        RefreshOwnedTowerCache()

    local towerCounts =
        GetNormalTowerCounts(owned)

    local goldenOwned,
        goldenTotal =
        GetGoldenCounts()

    local goldenText =
        FormatNumber(goldenOwned)
        .. " / "
        .. FormatNumber(goldenTotal)

    if goldenTotal > 0
        and goldenOwned >= goldenTotal then

        goldenText =
            "✅ " .. goldenText
    end

    AddField(
        fields,
        "🏰 Tower Progress",
        "Coin Towers: **"
            .. FormatNumber(
                towerCounts.CoinOwned
            )
            .. " / "
            .. FormatNumber(
                towerCounts.CoinTotal
            )
            .. "**\nGem Towers: **"
            .. FormatNumber(
                towerCounts.GemOwned
            )
            .. " / "
            .. FormatNumber(
                towerCounts.GemTotal
            )
            .. "**\nGolden Towers: **"
            .. goldenText
            .. "**\nTotal Towers: **"
            .. FormatNumber(
                towerCounts.TotalOwned
            )
            .. " / "
            .. FormatNumber(
                towerCounts.Total
            )
            .. "**",
        false
    )

    return title, fields
end

local function BuildTowerXPEmbed(
    snapshot,
    data
)
    local fields = {}
    local eventType =
        tostring(data.EventType or "")

    local selectedTower =
        tostring(
            Globals.TowerXPSelectedTower
            or "None"
        )

    local towerLevel =
        GetTowerXPLevel()

    local title =
        eventType == "match_complete"
        and "🧪 Auto Farm Tower XP — Match Complete"
        or "🧪 Auto Farm Tower XP — Current Progress"

    AddField(
        fields,
        "📋 Tower Overview",
        "┃ Status: **"
            .. GetModeRunningLabel(
                "tower_xp"
            )
            .. "**\n┃ Selected Tower: **"
            .. selectedTower
            .. "**\n┃ Tower Level: **"
            .. FormatNumber(towerLevel)
            .. " / 20**",
        false
    )

    if eventType == "match_complete" then
        AddField(
            fields,
            "✨ Match Rewards",
            BuildMatchRewardsField(
                data.Rewards or {}
            ),
            false
        )
    end

    AddField(
        fields,
        "📊 Session Totals",
        "Coins: **"
            .. FormatNumber(snapshot.Coins)
            .. "**\nGems: **"
            .. FormatNumber(snapshot.Gems)
            .. "**",
        false
    )

    AddField(
        fields,
        "🔄 Current State",
        GetFarmStatus("tower_xp"),
        false
    )

    AddField(
        fields,
        "📈 Tower XP Progress",
        "Tower: **"
            .. selectedTower
            .. "**\nLevel: **"
            .. (
                towerLevel >= 20
                and (
                    "✅ "
                    .. FormatNumber(towerLevel)
                    .. " / 20"
                )
                or (
                    FormatNumber(towerLevel)
                    .. " / 20"
                )
            )
            .. "**",
        false
    )

    return title, fields
end

local function BuildStoryEmbed(
    snapshot,
    data
)
    local fields = {}
    local eventType =
        tostring(data.EventType or "")

    local info =
        GetStoryInfo()

    local title =
        eventType == "match_complete"
        and "📖 Story Mode — Match Complete"
        or "📖 Story Mode — Current Progress"

    local chapterText =
        info.Chapter ~= nil
        and (
            "Chapter "
            .. tostring(info.Chapter)
        )
        or "Unknown"

    local missionText =
        info.MissionName ~= ""
        and info.MissionName
        or "Unknown"

    AddField(
        fields,
        "📋 Story Overview",
        "┃ Status: **"
            .. GetModeRunningLabel(
                "story"
            )
            .. "**\n┃ Current Chapter: **"
            .. chapterText
            .. "**\n┃ Current Mission: **"
            .. missionText
            .. "**",
        false
    )

    if eventType == "match_complete" then
        AddField(
            fields,
            "✨ Match Rewards",
            BuildMatchRewardsField(
                data.Rewards or {}
            ),
            false
        )
    end

    AddField(
        fields,
        "📊 Session Totals",
        "Coins: **"
            .. FormatNumber(snapshot.Coins)
            .. "**\nGems: **"
            .. FormatNumber(snapshot.Gems)
            .. "**",
        false
    )

    local currentState

    if Globals.__RyaStoryModeCompleted == true then
        currentState =
            "✅ Story Mode Completed"
    elseif eventType == "match_complete" then
        currentState =
            "✅ Mission Completed\nLoading Next Story Mission..."
    else
        currentState =
            GetFarmStatus("story")
    end

    AddField(
        fields,
        "🔄 Current State",
        currentState,
        false
    )

    local missionProgress =
        info.Mission
        and info.ChapterMissionTotal > 0
        and (
            tostring(info.Mission)
            .. " / "
            .. tostring(
                info.ChapterMissionTotal
            )
        )
        or "Unavailable"

    local completedMissions =
        info.Index
        and (
            eventType == "match_complete"
            and info.Index
            or math.max(
                info.Index - 1,
                0
            )
        )
        or 0

    AddField(
        fields,
        "📖 Story Progress",
        "Chapter: **"
            .. (
                info.Chapter ~= nil
                and tostring(info.Chapter)
                or "Unavailable"
            )
            .. "**\nMission: **"
            .. missionProgress
            .. "**\nCompleted Missions: **"
            .. FormatNumber(
                completedMissions
            )
            .. " / "
            .. FormatNumber(
                info.Total
            )
            .. "**",
        false
    )

    return title, fields
end

local function BuildGenericEmbed(
    snapshot
)
    local fields = {}

    AddField(
        fields,
        "📋 Current Progress",
        "Level: **"
            .. FormatNumber(snapshot.Level)
            .. "**\nCoins: **"
            .. FormatNumber(snapshot.Coins)
            .. "**\nGems: **"
            .. FormatNumber(snapshot.Gems)
            .. "**\nGatling Gun: **"
            .. (
                snapshot.GatlingOwned
                and "✅ Purchased"
                or "🔒 Locked"
            )
            .. "**",
        false
    )

    return
        "📊 Current Progress",
        fields
end

local function BuildEmbed(
    eventType,
    data
)
    data =
        type(data) == "table"
        and data
        or {}

    local snapshot =
        GetProgressSnapshot()

    local mode =
        tostring(
            data.Mode
            or DetectMode()
        )

    if mode == "idle"
        and LastActiveMode ~= "idle" then

        mode = LastActiveMode
    end

    EnsureSession(
        mode,
        snapshot
    )

    data.EventType = eventType

    local title
    local fields

    if mode == "auto_max" then
        title, fields =
            BuildAutoMaxEmbed(
                snapshot,
                data
            )
    elseif mode == "auto_buy" then
        title, fields =
            BuildAutoBuyEmbed(
                snapshot,
                data
            )
    elseif mode == "tower_xp" then
        title, fields =
            BuildTowerXPEmbed(
                snapshot,
                data
            )
    elseif mode == "story" then
        title, fields =
            BuildStoryEmbed(
                snapshot,
                data
            )
    elseif mode == "gatling" then
        title, fields =
            BuildGatlingEmbed(
                snapshot,
                data
            )
    else
        title, fields =
            BuildGenericEmbed(
                snapshot
            )
    end

    return {
        title = title,
        description =
            "**"
            .. LocalPlayer.Name
            .. "**",
        color = EMBED_COLOR,
        fields = fields,
        footer = {
            text =
                "Rya Auto Progression  Progress Tracker"
        },
        timestamp =
            DateTime.now():ToIsoDate()
    }
end

local function SendPayload(
    eventType,
    data
)
    if Sending then
        return false, "Already sending"
    end

    local webhook =
        Trim(WebhookURL)

    if webhook == "" then
        return false, "Webhook is empty"
    end

    if not SendRequest then
        return
            false,
            "Executor does not support HTTP requests"
    end

    Sending = true

    local payload = {
        username = "Rya Progression",
        embeds = {
            BuildEmbed(
                eventType,
                data
            )
        }
    }

    local success, response =
        pcall(function()
            return SendRequest({
                Url = webhook,
                Method = "POST",
                Headers = {
                    ["Content-Type"] =
                        "application/json"
                },
                Body =
                    HttpService:JSONEncode(
                        payload
                    )
            })
        end)

    Sending = false

    if not success then
        return false, response
    end

    local statusCode =
        response
        and (
            response.StatusCode
            or response.Status
        )

    if statusCode
        and tonumber(statusCode)
        and tonumber(statusCode) >= 400 then

        return
            false,
            "HTTP "
            .. tostring(statusCode)
    end

    return true
end

local function HandleMatchComplete(
    mode,
    rep
)
    task.wait(1.25)

    local snapshot =
        GetProgressSnapshot()

    EnsureSession(
        mode,
        snapshot
    )

    Session.Matches =
        (tonumber(Session.Matches) or 0)
        + 1

    local result =
        GetMatchResult(rep)

    if result == "win" then
        Session.Wins =
            (tonumber(Session.Wins) or 0)
            + 1
    elseif result == "loss" then
        Session.Losses =
            (tonumber(Session.Losses) or 0)
            + 1
    end

    Globals.__RyaWebhookSession =
        Session

    local rewards =
        GetMatchRewards()

    SendPayload(
        "match_complete",
        {
            Mode = mode,
            Rewards = rewards,
            MatchResult = result
        }
    )
end

function ProgressWebhook.SetWebhook(url)
    WebhookURL = Trim(url)
    Globals.WebhookURL = WebhookURL
    Globals.Webhook = WebhookURL

    return true
end

function ProgressWebhook.GetWebhook()
    return WebhookURL
end

function ProgressWebhook.Send(
    eventType,
    data
)
    if eventType == true
        or eventType == "manual"
        or eventType == "stats"
        or eventType == nil then

        return SendPayload(
            "manual",
            data
        )
    end

    if eventType == "match_complete"
        or eventType == "level_up"
        or eventType == "tower_bought" then

        return SendPayload(
            tostring(eventType),
            data
        )
    end

    return false, "Unknown webhook event"
end

function ProgressWebhook.GetLevel()
    return GetCurrentLevel()
end

function ProgressWebhook.Start()
    if WatcherRunning then
        return true
    end

    WatcherRunning = true

    task.spawn(function()
        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        task.wait(1)

        local initialSnapshot =
            GetProgressSnapshot()

        local initialMode =
            DetectMode()

        if initialMode ~= "idle" then
            LastActiveMode = initialMode
            EnsureSession(
                initialMode,
                initialSnapshot
            )
        end

        while WatcherRunning do
            local mode =
                DetectMode()

            if mode ~= "idle" then
                if mode ~= LastActiveMode then
                    EnsureSession(
                        mode,
                        GetProgressSnapshot()
                    )
                end

                LastActiveMode = mode
            end

            local currentLevel =
                GetCurrentLevel()

            if currentLevel
                and currentLevel > 0 then

                LastDetectedLevel =
                    currentLevel
            end

            RefreshOwnedTowerCache()

            local rep =
                GetGameReplicator()

            if rep ~= LastGameReplicator then
                LastGameReplicator = rep

                if rep then
                    LastGameOver =
                        rep:GetAttribute(
                            "GameOver"
                        ) == true
                else
                    LastGameOver = nil
                end
            elseif rep then
                local isGameOver =
                    rep:GetAttribute(
                        "GameOver"
                    ) == true

                if isGameOver
                    and LastGameOver ~= true then

                    local matchMode =
                        mode ~= "idle"
                        and mode
                        or LastActiveMode

                    if matchMode ~= "idle" then
                        task.spawn(
                            HandleMatchComplete,
                            matchMode,
                            rep
                        )
                    end
                end

                LastGameOver = isGameOver
            end

            task.wait(0.25)
        end
    end)

    return true
end

function ProgressWebhook.Stop()
    WatcherRunning = false
    return true
end

function ProgressWebhook.GetLastLevel()
    return LastDetectedLevel
end

function ProgressWebhook.GetMode()
    return DetectMode()
end

shared.ProgressWebhook =
    ProgressWebhook

return ProgressWebhook
