-- GrindSpotter.lua
-- World of Warcraft Classic Era (1.15.x) Grinding Spot Recommender
-- Pure client-side Lua

local ADDON_NAME, GrindSpotter = ...

GrindSpotterDB = GrindSpotterDB or {}

-- -----------------------------------------------------------------
-- Helpers & Constants
-- -----------------------------------------------------------------
local CLASS_MELEE = {
    ["WARRIOR"] = true,
    ["ROGUE"] = true,
    ["PALADIN"] = true,
}

local CLASS_CASTER = {
    ["MAGE"] = true,
    ["PRIEST"] = true,
    ["WARLOCK"] = true,
}

local function HasTag(tags, targetTag)
    if not tags then return false end
    for _, tag in ipairs(tags) do
        if tag == targetTag then
            return true
        end
    end
    return false
end

-- -----------------------------------------------------------------
-- Fuzzy Matching (Damerau-Levenshtein)
-- -----------------------------------------------------------------
local function DamerauLevenshtein(s1, s2)
    local len1 = #s1
    local len2 = #s2
    if len1 == 0 then return len2 end
    if len2 == 0 then return len1 end

    local d = {}
    for i = 0, len1 do
        d[i] = {}
        d[i][0] = i
    end
    for j = 0, len2 do
        d[0][j] = j
    end

    local b1 = { string.byte(s1, 1, len1) }
    local b2 = { string.byte(s2, 1, len2) }

    for i = 1, len1 do
        local ch1 = b1[i]
        for j = 1, len2 do
            local cost = (ch1 == b2[j]) and 0 or 1
            local delCost = d[i - 1][j] + 1
            local insCost = d[i][j - 1] + 1
            local subCost = d[i - 1][j - 1] + cost

            local minCost = delCost
            if insCost < minCost then minCost = insCost end
            if subCost < minCost then minCost = subCost end

            if i > 1 and j > 1 and ch1 == b2[j - 1] and b1[i - 1] == b2[j] then
                local transCost = d[i - 2][j - 2] + 1
                if transCost < minCost then minCost = transCost end
            end

            d[i][j] = minCost
        end
    end

    return d[len1][len2]
end

local function IsFuzzyMatch(needle, haystack)
    if not needle or needle == "" then return true end
    if not haystack or haystack == "" then return false end

    needle = needle:lower()
    haystack = haystack:lower()

    -- Check exact substring match first
    if haystack:find(needle, 1, true) then
        return true
    end

    local needleLen = #needle
    local maxDist = 1
    if needleLen > 7 then
        maxDist = 3
    elseif needleLen > 4 then
        maxDist = 2
    else
        maxDist = 1
    end

    -- Split haystack into words and compare edit distance
    for word in haystack:gmatch("%S+") do
        local wordLen = #word
        if math.abs(wordLen - needleLen) <= maxDist then
            if DamerauLevenshtein(needle, word) <= maxDist then
                return true
            end
        end
    end

    return false
end

-- -----------------------------------------------------------------
-- Map & Continent Helpers
-- -----------------------------------------------------------------
local function GetContinentMapID(mapID)
    if not mapID or not C_Map or not C_Map.GetMapInfo then return nil end
    local mapInfo = C_Map.GetMapInfo(mapID)
    local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
    local depth = 0
    while mapInfo and depth < 10 do
        if mapInfo.mapType == continentType then
            return mapInfo.mapID
        end
        if not mapInfo.parentMapID or mapInfo.parentMapID == 0 or mapInfo.parentMapID == mapInfo.mapID then
            break
        end
        mapInfo = C_Map.GetMapInfo(mapInfo.parentMapID)
        depth = depth + 1
    end
    return nil
end

-- -----------------------------------------------------------------
-- Skinning Math & Skill Resolver
-- ----------------------------------------------------------------
local function GetPlayerSkinningRank()
    local numSkills = GetNumSkillLines and GetNumSkillLines() or 0
    for i = 1, numSkills do
        local skillName, _, _, skillRank, _, _, maxRank = GetSkillLineInfo(i)
        if skillName and (skillName == "Skinning" or skillName:find("Skinning") or skillName:find("Kürschnerei") or skillName:find("Dépeçage") or skillName:find("Desuello") or skillName:find("Снятие шкур") or skillName:find("刚皮")) then
            return skillRank, maxRank
        end
    end
    return 0, 0
end

local function GetMaxSkinnableMobLevel(skinningRank)
    if not skinningRank or skinningRank <= 0 then
        return 0
    end
    if skinningRank <= 100 then
        return math.floor(skinningRank / 10) + 10
    else
        return math.floor(skinningRank / 5)
    end
end

local function GetRequiredSkinningRank(mobLevel)
    if mobLevel <= 20 then
        return math.max(1, (mobLevel - 10) * 10)
    else
        return mobLevel * 5
    end
end

-- ----------------------------------------------------------------
-- XP Calculation (Classic Era Mob Kill XP)
-- ----------------------------------------------------------------
local function EstimateMobXP(playerLevel, mobLevel)
    if playerLevel >= 60 then return 0 end
    local levelDiff = mobLevel - playerLevel
    if levelDiff < -5 and playerLevel > 20 then
        local zd = 5
        if playerLevel <= 29 then zd = 6
        elseif playerLevel <= 39 then zd = 7
        elseif playerLevel <= 44 then zd = 8
        elseif playerLevel <= 49 then zd = 9
        else zd = 10 end
        local greyThreshold = playerLevel - zd
        if mobLevel <= greyThreshold then
            return 0
        end
    end

    local baseXP = (mobLevel * 5) + 45
    if levelDiff == 0 then
        return baseXP
    elseif levelDiff > 0 then
        local bonusMultiplier = 1 + (0.05 * math.min(levelDiff, 4))
        return math.floor(baseXP * bonusMultiplier)
    else
        local reduction = 1 - (math.abs(levelDiff) * 0.1)
        return math.max(0, math.floor(baseXP * math.max(0.2, reduction)))
    end
end

-- ----------------------------------------------------------------
-- UI Creation
-- ----------------------------------------------------------------
local mainFrame = nil
local resultCards = {}

local function CreateResultCard(parent, index)
    local card = CreateFrame("Frame", "GrindSpotterCard"..index, parent, "BackdropTemplate")
    card:SetSize(410, 105)
    card:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    card:SetBackdropColor(0.08, 0.08, 0.1, 0.85)
    card:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)

    local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalMed2")
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
    card.title = title

    local levelZone = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    levelZone:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    card.levelZone = levelZone

    local scoreText = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scoreText:SetPoint("TOPRIGHT", card, "TOPRIGHT", -90, -8)
    card.scoreText = scoreText

    local details = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    details:SetPoint("TOPLEFT", levelZone, "BOTTOMLEFT", 0, -4)
    details:SetWidth(295)
    details:SetJustifyH("LEFT")
    card.details = details

    local warning = card:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    warning:SetPoint("TOPLEFT", details, "BOTTOMLEFT", 0, -2)
    warning:SetWidth(295)
    warning:SetJustifyH("LEFT")
    card.warning = warning

    local waypointBtn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    waypointBtn:SetSize(82, 22)
    waypointBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 8)
    waypointBtn:SetText("Waypoint")
    card.waypointBtn = waypointBtn

    return card
end

local function CreateMainUI()
    if mainFrame then return mainFrame end

    local f = CreateFrame("Frame", "GrindSpotterFrame", UIParent, "BasicFrameTemplateWithInset, BackdropTemplate")
    f:SetSize(480, 560)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        GrindSpotterDB.posX = x
        GrindSpotterDB.posY = y
        GrindSpotterDB.point = point
        GrindSpotterDB.relPoint = relPoint
    end)
    f:SetClampedToScreen(true)

    f.TitleBg:SetHeight(28)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 10, -5)
    f.title:SetText("GrindSpotter |cff00ff00v1.0|r")

    local queryLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    queryLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -38)
    queryLabel:SetText("Search (Item/Mob/Leave empty for XP):")

    local queryBox = CreateFrame("EditBox", "GrindSpotterQueryBox", f, "InputBoxTemplate")
    queryBox:SetSize(220, 24)
    queryBox:SetPoint("TOPLEFT", queryLabel, "BOTTOMLEFT", 6, -4)
    queryBox:SetAutoFocus(false)
    f.queryBox = queryBox

    local targetLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    targetLabel:SetPoint("LEFT", queryLabel, "LEFT", 240, 0)
    targetLabel:SetText("Target (Qty or Level):")

    local targetBox = CreateFrame("EditBox", "GrindSpotterTargetBox", f, "InputBoxTemplate")
    targetBox:SetSize(90, 24)
    targetBox:SetPoint("TOPLEFT", targetLabel, "BOTTOMLEFT", 6, -4)
    targetBox:SetAutoFocus(false)
    targetBox:SetNumeric(true)
    f.targetBox = targetBox

    local searchBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    searchBtn:SetSize(80, 24)
    searchBtn:SetPoint("LEFT", targetBox, "RIGHT", 10, 0)
    searchBtn:SetText("Find Spots")
    searchBtn:SetScript("OnClick", function()
        GrindSpotter:RunSearch()
    end)
    f.searchBtn = searchBtn

    queryBox:SetScript("OnEnterPressed", function() searchBtn:Click() end)
    targetBox:SetScript("OnEnterPressed", function() searchBtn:Click() end)

    local banner = CreateFrame("Frame", nil, f, "BackdropTemplate")
    banner:SetPoint("TOPLEFT", queryBox, "BOTTOMLEFT", -6, -8)
    banner:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -88)
    banner:SetHeight(32)
    banner:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    banner:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
    banner:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    local bannerText = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bannerText:SetPoint("CENTER", banner, "CENTER", 0, 0)
    bannerText:SetText("Enter query or leave blank for optimal level-up grinding spots.")
    f.bannerText = bannerText

    local scrollFrame = CreateFrame("ScrollFrame", "GrindSpotterScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 14)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(415, 600)
    scrollFrame:SetScrollChild(content)

    f.content = content
    mainFrame = f
    f:Hide()
    return f
end

-- ----------------------------------------------------------------
-- Waypoint Integration
-- ----------------------------------------------------------------
function GrindSpotter:SetWaypoint(mapID, x, y, title)
    if TomTom and type(TomTom.AddWaypoint) == "function" then
        TomTom:AddWaypoint(mapID, x / 100, y / 100, {
            title = title or "Grind Spot",
            persistent = false,
            minimap = true,
            world = true,
        })
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GrindSpotter:|r TomTom waypoint set for |cffffd100" .. (title or "Spot") .. "|r at (" .. string.format("%.1f, %.1f", x, y) .. ")")
        return
    end

    if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local point = UiMapPoint.CreateFromCoordinates(mapID, x / 100, y / 100)
        C_Map.SetUserWaypoint(point)
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GrindSpotter:|r Blizzard map pin set for |cffffd100" .. (title or "Spot") .. "|r at (" .. string.format("%.1f, %.1f", x, y) .. ")")
        return
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cffff4444GrindSpotter:|r No waypoint addon (TomTom) found and native waypoints unavailable.")
end

-- ----------------------------------------------------------------
-- Scoring & Recommendation Engine
-- ----------------------------------------------------------------
function GrindSpotter:RunSearch()
    if not mainFrame then return end

    local query = strtrim(mainFrame.queryBox:GetText() or ""):lower()
    local targetVal = tonumber(strtrim(mainFrame.targetBox:GetText() or ""))
    local playerLevel = UnitLevel("player")
    local _, playerClass = UnitClass("player")
    local playerFaction = UnitFactionGroup("player")
    local skinningRank, maxSkinningRank = GetPlayerSkinningRank()
    local maxSkinnableLevel = GetMaxSkinnableMobLevel(skinningRank)

    local curMap = (C_Map and C_Map.GetBestMapForUnit) and C_Map.GetBestMapForUnit("player") or nil
    local curContinent = curMap and GetContinentMapID(curMap) or nil

    local isLeatherSearch = (query:find("leather") or query:find("hide") or query:find("skin"))

    if isLeatherSearch then
        if skinningRank <= 0 then
            mainFrame.bannerText:SetText("|cffff5555Warning: No Skinning skill learned!|r Max skinnable mob level: 0")
        else
            mainFrame.bannerText:SetText(string.format("Skinning Rank: |cffffd100%d/%d|r (Max skinnable mob level: |cff00ff00%d|r)", skinningRank, maxSkinningRank, maxSkinnableLevel))
        end
    else
        mainFrame.bannerText:SetText(string.format("Player: Lv |cffffd100%d|r %s (%s) | Skinning: |cffffd100%d|r", playerLevel, playerClass, playerFaction or "Neutral", skinningRank))
    end

    local camps = (GrindSpotterData and GrindSpotterData.camps) or {}
    local scoredResults = {}

    for _, camp in ipairs(camps) do
        local factionOk = (camp.faction == "Both" or camp.faction == playerFaction or camp.faction == "Neutral")
        
        if factionOk then
            local isMatch = false
            local matchedDropRate = 0
            local matchedItemName = nil

            if query == "" then
                if camp.maxLevel >= (playerLevel - 7) and camp.minLevel <= (playerLevel + 4) then
                    isMatch = true
                end
            else
                if IsFuzzyMatch(query, camp.name) or IsFuzzyMatch(query, camp.zone) then
                    isMatch = true
                else
                    for tagIdx = 1, #camp.tags do
                        if IsFuzzyMatch(query, camp.tags[tagIdx]) then
                            isMatch = true
                            break
                        end
                    end
                end

                for dropItem, rate in pairs(camp.drops) do
                    if IsFuzzyMatch(query, dropItem) then
                        isMatch = true
                        if rate > matchedDropRate then
                            matchedDropRate = rate
                            matchedItemName = dropItem
                        end
                    end
                end
            end

            if isMatch then
                local score = 100
                local warnings = {}
                local notes = {}

                local avgMobLevel = (camp.minLevel + camp.maxLevel) / 2
                local levelDiff = avgMobLevel - playerLevel

                -- Level difference weighting
                if levelDiff >= -2 and levelDiff <= 1 then
                    score = score + 25
                elseif levelDiff > 3 then
                    score = score - (levelDiff * 15)
                    table.insert(warnings, "Mob level high (+daze/misses)")
                elseif levelDiff < -5 then
                    score = score - (math.abs(levelDiff) * 12)
                end

                -- Combat & Class Suitability
                if CLASS_MELEE[playerClass] then
                    if HasTag(camp.tags, "HIGH_ARMOR") then
                        score = score - 20
                        table.insert(warnings, "High Armor (Melee Penalty)")
                    end
                    if HasTag(camp.tags, "THRASH") then
                        score = score - 25
                        table.insert(warnings, "Thrash (Extra Melee Hits)")
                    end
                    if HasTag(camp.tags, "STONE_SKIN") then
                        score = score - 20
                        table.insert(warnings, "Stone Skin (Damage Reduc.)")
                    end
                    if HasTag(camp.tags, "DISARM") then
                        score = score - 25
                        table.insert(warnings, "Disarm")
                    end
                end

                if CLASS_CASTER[playerClass] then
                    if HasTag(camp.tags, "SILENCE") then
                        score = score - 30
                        table.insert(warnings, "Silence / Spell Lockout")
                    end
                    if HasTag(camp.tags, "MANA_BURN") then
                        score = score - 25
                        table.insert(warnings, "Mana Burn")
                    end
                    if HasTag(camp.tags, "FAST_ATTACK") then
                        score = score - 15
                        table.insert(warnings, "Fast Attacks (Cast Pushback)")
                    end
                    if HasTag(camp.tags, "MAGIC_RESIST") then
                        score = score - 25
                        table.insert(warnings, "High Magic Resist")
                    end
                end

                -- General Traffic & Quest mob penalty
                if camp.isQuestMob then
                    score = score - 15
                    table.insert(notes, "Quest Objective (Contested tags)")
                end

                -- Skinning Resolution Bottleneck Check
                local reqRank = GetRequiredSkinningRank(camp.maxLevel)
                if isLeatherSearch or query == "leather" or query == "skinning" then
                    if maxSkinnableLevel < camp.maxLevel then
                        score = score - 35
                        table.insert(warnings, string.format("Skinning Bottleneck! Req Rank %d (You: %d)", reqRank, skinningRank))
                    else
                        table.insert(notes, "Skinnable (Knife ready)")
                    end
                end

                -- Distance / Proximity Scoring
                if curMap and camp.mapID then
                    if camp.mapID == curMap then
                        score = score + 15
                        table.insert(notes, "Local Zone")
                    elseif curContinent then
                        local campContinent = GetContinentMapID(camp.mapID)
                        if campContinent and campContinent ~= curContinent then
                            score = score - 35
                            table.insert(warnings, "Other Continent")
                        end
                    end
                end

                -- Estimates (Kills required)
                local estimateStr = ""
                if matchedItemName and matchedDropRate > 0 then
                    local qty = (targetVal and targetVal > 0) and targetVal or 20
                    local killsNeeded = math.ceil(qty / matchedDropRate)
                    estimateStr = string.format("Drop: ~%.0f%% %s | ~%d kills for %d qty", matchedDropRate * 100, matchedItemName, killsNeeded, qty)
                else
                    local targetLvl = (targetVal and targetVal > playerLevel) and math.min(60, targetVal) or (playerLevel + 1)
                    local currentXP = UnitXP("player")
                    local maxXP = UnitXPMax("player")
                    local xpRemaining = maxXP - currentXP
                    local mobXP = EstimateMobXP(playerLevel, math.floor(avgMobLevel + 0.5))
                    
                    if mobXP > 0 then
                        local killsForLevel = math.ceil(xpRemaining / mobXP)
                        if targetLvl > (playerLevel + 1) then
                            estimateStr = string.format("~%d XP/kill | ~%d kills to Lv %d", mobXP, killsForLevel, playerLevel + 1)
                        else
                            estimateStr = string.format("~%d XP/kill | ~%d kills to next level", mobXP, killsForLevel)
                        end
                    else
                        estimateStr = "Grey mobs (0 XP)"
                    end
                end

                table.insert(scoredResults, {
                    camp = camp,
                    score = math.max(0, score),
                    warnings = warnings,
                    notes = notes,
                    estimateStr = estimateStr,
                })
            end
        end
    end

    table.sort(scoredResults, function(a, b)
        return a.score > b.score
    end)

    for _, card in ipairs(resultCards) do
        card:Hide()
    end

    local cardY = 0
    local cardHeight = 105
    local spacing = 6

    for i, res in ipairs(scoredResults) do
        local card = resultCards[i]
        if not card then
            card = CreateResultCard(mainFrame.content, i)
            resultCards[i] = card
        end

        local camp = res.camp
        card:SetPoint("TOPLEFT", mainFrame.content, "TOPLEFT", 0, -cardY)
        card.title:SetText(string.format("|cffffffff%d.|r %s", i, camp.name))
        
        local lvlColor = "|cffffff00"
        if camp.maxLevel > (playerLevel + 3) then lvlColor = "|cffff3333"
        elseif camp.maxLevel >= playerLevel then lvlColor = "|cffffff00"
        elseif camp.maxLevel >= (playerLevel - 4) then lvlColor = "|cff40ff40"
        else lvlColor = "|cff808080" end

        card.levelZone:SetText(string.format("%s [Lv %d-%d]|r • %s (%.1f, %.1f)", lvlColor, camp.minLevel, camp.maxLevel, camp.zone, camp.x, camp.y))

        local scoreColor = res.score >= 80 and "|cff00ff00" or (res.score >= 50 and "|cffffcc00" or "|cffff4444")
        card.scoreText:SetText(string.format("Score: %s%d|r", scoreColor, res.score))

        local detailsText = res.estimateStr
        if #res.notes > 0 then
            detailsText = detailsText .. "\n|cff88ccff" .. table.concat(res.notes, ", ") .. "|r"
        end
        card.details:SetText(detailsText)

        if #res.warnings > 0 then
            card.warning:SetText("⚠️ " .. table.concat(res.warnings, " • "))
            card.warning:Show()
        else
            card.warning:SetText("")
            card.warning:Hide()
        end

        card.waypointBtn:SetScript("OnClick", function()
            GrindSpotter:SetWaypoint(camp.mapID, camp.x, camp.y, camp.name)
        end)

        card:Show()
        cardY = cardY + cardHeight + spacing
    end

    mainFrame.content:SetHeight(math.max(cardY, 400))

    if #scoredResults == 0 then
        mainFrame.bannerText:SetText("|cffff5555Could not find any camps matching your search. Try broadening your terms, or check Wowhead!|r")
    end
end

-- ----------------------------------------------------------------
-- Event Handling & Slash Command
-- ----------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("SKILL_LINES_CHANGED")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        CreateMainUI()
        if GrindSpotterDB.point and GrindSpotterDB.posX and GrindSpotterDB.posY then
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint(GrindSpotterDB.point, UIParent, GrindSpotterDB.relPoint or "CENTER", GrindSpotterDB.posX, GrindSpotterDB.posY)
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GrindSpotter loaded.|r Type |cffffd100/grind|r to open.")
    elseif event == "SKILL_LINES_CHANGED" then
        if mainFrame and mainFrame:IsShown() then
            GrindSpotter:RunSearch()
        end
    end
end)

SLASH_GRINDSPOTTER1 = "/grind"
SLASH_GRINDSPOTTER2 = "/grindspotter"
SlashCmdList["GRINDSPOTTER"] = function(msg)
    local f = CreateMainUI()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        GrindSpotter:RunSearch()
    end
end

