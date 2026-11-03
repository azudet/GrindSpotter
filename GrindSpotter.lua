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

function GrindSpotter:SelectCamp(campResult)
    GrindSpotter.selectedCamp = campResult
    local selectedCampObj = (type(campResult) == "table" and campResult.camp) and campResult.camp or campResult
    GrindSpotter.currentSelectedCamp = selectedCampObj

    for _, card in ipairs(resultCards) do
        if card:IsShown() and card.campData and selectedCampObj and card.campData == selectedCampObj then
            card:SetSelected(true)
        else
            card:SetSelected(false)
        end
    end

    if not mainFrame or not mainFrame.rightPage then return end
    local rightPage = mainFrame.rightPage

    if not selectedCampObj then
        rightPage.campNameText:SetText("|cffaaaaaaNo spot selected|r")
        rightPage.campSubText:SetText("")
        rightPage.campScoreText:SetText("")
        if rightPage.modelFrame then
            if rightPage.modelFrame.ClearModel then
                rightPage.modelFrame:ClearModel()
            elseif rightPage.modelFrame.SetModel then
                rightPage.modelFrame:SetModel("")
            end
        end
        rightPage.hazardsText:SetText("")
        rightPage.skinningText:SetText("")
        rightPage.lootText:SetText("")
        rightPage.waypointBtn:Disable()
        return
    end

    local camp = selectedCampObj
    rightPage.waypointBtn:Enable()

    -- 1. Top Header: Camp Name, Zone, Level Range, Coordinates, and Suitability Score
    local playerLevel = UnitLevel("player")
    local lvlColor = "|cffffff00"
    if camp.maxLevel > (playerLevel + 3) then lvlColor = "|cffff3333"
    elseif camp.maxLevel >= playerLevel then lvlColor = "|cffffff00"
    elseif camp.maxLevel >= (playerLevel - 4) then lvlColor = "|cff40ff40"
    else lvlColor = "|cff808080" end

    rightPage.campNameText:SetText(string.format("|cffffffff%s|r", camp.name))
    rightPage.campSubText:SetText(string.format("%s • %s [Lv %d-%d]|r • (%.1f, %.1f)", camp.zone, lvlColor, camp.minLevel, camp.maxLevel, camp.x, camp.y))

    local score = (type(campResult) == "table" and campResult.score) or nil
    if score then
        local scoreColor = score >= 80 and "|cff00ff00" or (score >= 50 and "|cffffcc00" or "|cffff4444")
        rightPage.campScoreText:SetText(string.format("Suitability Score: %s%d/100|r", scoreColor, score))
    else
        rightPage.campScoreText:SetText("")
    end

    -- 2. Middle: 3D Model Frame
    if rightPage.modelFrame then
        if rightPage.modelFrame.ClearModel then
            rightPage.modelFrame:ClearModel()
        elseif rightPage.modelFrame.SetModel then
            rightPage.modelFrame:SetModel("")
        end
        if camp.creatureEntry and camp.creatureEntry > 0 then
            rightPage.modelFrame:SetCreature(camp.creatureEntry)
        end
        rightPage.modelFrame:SetRotation(0.3)
    end

    -- 3. Under the model: Class Hazard warnings & Skinning requirements
    local hazardTags = {}
    local knownHazards = {
        ["HIGH_ARMOR"] = "High Armor",
        ["THRASH"] = "Thrash",
        ["STONE_SKIN"] = "Stone Skin",
        ["DISARM"] = "Disarm",
        ["SILENCE"] = "Silence / Lockout",
        ["MANA_BURN"] = "Mana Burn",
        ["FAST_ATTACK"] = "Fast Attack Speed",
        ["MAGIC_RESIST"] = "Magic Resist",
        ["POISON"] = "Poison",
        ["CURSE"] = "Curse",
        ["ENRAGE"] = "Enrage",
        ["FLEE_RUNNER"] = "Flee / Runner",
        ["STEALTH"] = "Stealth",
        ["NET_ROOT"] = "Net / Root",
        ["HEALER"] = "Healing Abilities",
        ["CASTER"] = "Spells / Ranged",
        ["HEAVY_PACKS"] = "Dense Packs",
    }

    if camp.tags then
        for _, tag in ipairs(camp.tags) do
            if knownHazards[tag] then
                table.insert(hazardTags, knownHazards[tag])
            end
        end
    end

    if #hazardTags > 0 then
        rightPage.hazardsText:SetText(string.format("|cffff5555⚠️ Hazards:|r |cffffddaa%s|r", table.concat(hazardTags, " • ")))
    else
        rightPage.hazardsText:SetText("|cff88cc88Hazards: None (Normal pulls)|r")
    end

    -- Skinning requirements
    local skinningRank, maxSkinningRank = GetPlayerSkinningRank()
    local reqRank = GetRequiredSkinningRank(camp.maxLevel)
    local isBeast = HasTag(camp.tags, "BEAST") or HasTag(camp.tags, "DRAGONKIN")
    
    if isBeast or HasTag(camp.tags, "SKINNING") then
        local skinnableColor = (skinningRank >= reqRank) and "|cff00ff00" or "|cffff4444"
        rightPage.skinningText:SetText(string.format("Skinning Req: %s%d|r (Your Rank: |cffffd100%d/%d|r)", skinnableColor, reqRank, skinningRank, maxSkinningRank))
    else
        rightPage.skinningText:SetText("|cff808080Skinning: Not skinnable|r")
    end

    -- 4. Trade Goods / Loot list with authentic drop percentages
    local lootList = {}
    if camp.drops then
        for itemName, dropRate in pairs(camp.drops) do
            table.insert(lootList, { name = itemName, rate = dropRate })
        end
        table.sort(lootList, function(a, b) return a.rate > b.rate end)
    end

    if #lootList > 0 then
        local lines = {}
        for _, item in ipairs(lootList) do
            local pct = item.rate * 100
            local rateStr
            if pct >= 10.0 then
                rateStr = string.format("%.1f%%", pct)
            elseif pct >= 1.0 then
                rateStr = string.format("%.1f%%", pct)
            else
                rateStr = string.format("%.2f%%", pct)
            end
            table.insert(lines, string.format("• |cffffffff%s|r: |cffffd100%s|r", item.name, rateStr))
        end
        rightPage.lootText:SetText(table.concat(lines, "\n"))
        rightPage.lootContent:SetHeight(math.max(#lootList * 16 + 10, 80))
    else
        rightPage.lootText:SetText("|cff808080No recorded trade drops (Standard coin/vendor loot)|r")
        rightPage.lootContent:SetHeight(60)
    end
end

local function CreateResultCard(parent, index)
    local card = CreateFrame("Button", "GrindSpotterCard"..index, parent, "BackdropTemplate")
    card:SetSize(370, 75)
    card:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    card:SetBackdropColor(0.08, 0.08, 0.1, 0.88)
    card:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    local highlight = card:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.35)
    highlight:SetAllPoints(card)
    card.highlight = highlight

    local selectBorder = card:CreateTexture(nil, "OVERLAY")
    selectBorder:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    selectBorder:SetBlendMode("ADD")
    selectBorder:SetAllPoints(card)
    selectBorder:Hide()
    card.selectBorder = selectBorder

    function card:SetSelected(isSelected)
        card.isSelected = isSelected
        if isSelected then
            card:SetBackdropBorderColor(1.0, 0.82, 0.0, 1.0)
            card:SetBackdropColor(0.15, 0.13, 0.05, 0.95)
            selectBorder:Show()
        else
            card:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            card:SetBackdropColor(0.08, 0.08, 0.1, 0.88)
            selectBorder:Hide()
        end
    end

    local scoreText = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scoreText:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -6)
    card.scoreText = scoreText

    local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -6)
    title:SetPoint("RIGHT", scoreText, "LEFT", -6, 0)
    title:SetWordWrap(false)
    title:SetJustifyH("LEFT")
    card.title = title

    local levelZone = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    levelZone:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    levelZone:SetWidth(354)
    levelZone:SetJustifyH("LEFT")
    card.levelZone = levelZone

    local details = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    details:SetPoint("TOPLEFT", levelZone, "BOTTOMLEFT", 0, -2)
    details:SetWidth(285)
    details:SetJustifyH("LEFT")
    card.details = details

    local warning = card:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    warning:SetPoint("TOPLEFT", details, "BOTTOMLEFT", 0, -2)
    warning:SetWidth(285)
    warning:SetJustifyH("LEFT")
    card.warning = warning

    local waypointBtn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    waypointBtn:SetSize(68, 20)
    waypointBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -6, 6)
    waypointBtn:SetText("Waypoint")
    card.waypointBtn = waypointBtn

    card:EnableMouse(true)
    card:RegisterForClicks("LeftButtonUp")
    card:SetScript("OnClick", function(self)
        if self.campResult then
            GrindSpotter:SelectCamp(self.campResult)
        end
    end)

    return card
end

local function CreateMainUI()
    if mainFrame then return mainFrame end

    local f = CreateFrame("Frame", "GrindSpotterFrame", UIParent, "BasicFrameTemplateWithInset, BackdropTemplate")
    f:SetSize(820, 520)
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

    -- Side-by-side book background textures inside the inset
    local insetFrame = f.Inset or f
    local leftBg = insetFrame:CreateTexture(nil, "BACKGROUND")
    leftBg:SetTexture("Interface\\ItemText\\ItemText-Stone-Left")
    leftBg:SetPoint("TOPLEFT", insetFrame, "TOPLEFT", 0, 0)
    leftBg:SetSize(410, 500)
    f.leftBg = leftBg

    local rightBg = insetFrame:CreateTexture(nil, "BACKGROUND")
    rightBg:SetTexture("Interface\\ItemText\\ItemText-Stone-Right")
    rightBg:SetPoint("TOPRIGHT", insetFrame, "TOPRIGHT", 0, 0)
    rightBg:SetSize(410, 500)
    f.rightBg = rightBg

    -- Two container frames for left and right pages
    local leftPage = CreateFrame("Frame", nil, f)
    leftPage:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
    leftPage:SetSize(390, 480)
    f.leftPage = leftPage

    local rightPage = CreateFrame("Frame", nil, f)
    rightPage:SetPoint("TOPLEFT", leftPage, "TOPRIGHT", 10, 0)
    rightPage:SetSize(390, 480)
    f.rightPage = rightPage

    -- Top Header: Camp Name, Zone/Coords/Level, Suitability Score
    local detailHeader = CreateFrame("Frame", nil, rightPage, "BackdropTemplate")
    detailHeader:SetPoint("TOPLEFT", rightPage, "TOPLEFT", 6, -6)
    detailHeader:SetPoint("TOPRIGHT", rightPage, "TOPRIGHT", -10, -6)
    detailHeader:SetHeight(72)
    detailHeader:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    detailHeader:SetBackdropColor(0.08, 0.08, 0.1, 0.85)
    detailHeader:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    rightPage.detailHeader = detailHeader

    local campNameText = detailHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
    campNameText:SetPoint("TOPLEFT", detailHeader, "TOPLEFT", 8, -6)
    campNameText:SetPoint("TOPRIGHT", detailHeader, "TOPRIGHT", -8, -6)
    campNameText:SetJustifyH("LEFT")
    campNameText:SetText("|cffffffffSelect a grinding spot|r")
    rightPage.campNameText = campNameText

    local campSubText = detailHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    campSubText:SetPoint("TOPLEFT", campNameText, "BOTTOMLEFT", 0, -3)
    campSubText:SetPoint("TOPRIGHT", detailHeader, "TOPRIGHT", -8, -26)
    campSubText:SetJustifyH("LEFT")
    campSubText:SetText("|cffaaaaaaZone • Level • Coordinates|r")
    rightPage.campSubText = campSubText

    local campScoreText = detailHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    campScoreText:SetPoint("BOTTOMLEFT", detailHeader, "BOTTOMLEFT", 8, 6)
    campScoreText:SetJustifyH("LEFT")
    campScoreText:SetText("")
    rightPage.campScoreText = campScoreText

    -- Middle: 3D Model Frame
    local modelContainer = CreateFrame("Frame", nil, rightPage, "BackdropTemplate")
    modelContainer:SetSize(224, 204)
    modelContainer:SetPoint("TOP", detailHeader, "BOTTOM", 0, -6)
    modelContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    modelContainer:SetBackdropColor(0.04, 0.04, 0.05, 0.9)
    modelContainer:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.8)
    rightPage.modelContainer = modelContainer

    local modelFrame = CreateFrame("PlayerModel", "GrindSpotterModelFrame", modelContainer)
    modelFrame:SetSize(220, 200)
    modelFrame:SetPoint("CENTER", modelContainer, "CENTER", 0, 0)
    modelFrame:SetRotation(0.3)
    modelFrame:EnableMouse(true)

    local isRotating = false
    local prevMouseX = 0
    modelFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isRotating = true
            prevMouseX = GetCursorPosition()
        end
    end)
    modelFrame:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            isRotating = false
        end
    end)
    modelFrame:SetScript("OnUpdate", function(self)
        if isRotating then
            local curX = GetCursorPosition()
            local diff = (curX - prevMouseX) * 0.01
            prevMouseX = curX
            local currentFacing = self:GetFacing() or 0.3
            self:SetFacing(currentFacing + diff)
        end
    end)
    rightPage.modelFrame = modelFrame

    -- Under Model: Hazards & Skinning info
    local hazardsText = rightPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hazardsText:SetPoint("TOPLEFT", modelContainer, "BOTTOMLEFT", -60, -6)
    hazardsText:SetPoint("TOPRIGHT", modelContainer, "BOTTOMRIGHT", 60, -6)
    hazardsText:SetJustifyH("CENTER")
    hazardsText:SetText("")
    rightPage.hazardsText = hazardsText

    local skinningText = rightPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    skinningText:SetPoint("TOPLEFT", hazardsText, "BOTTOMLEFT", 0, -2)
    skinningText:SetPoint("TOPRIGHT", hazardsText, "BOTTOMRIGHT", 0, -2)
    skinningText:SetJustifyH("CENTER")
    skinningText:SetText("")
    rightPage.skinningText = skinningText

    -- Trade Goods / Loot Section
    local lootHeader = rightPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lootHeader:SetPoint("TOPLEFT", skinningText, "BOTTOMLEFT", -5, -6)
    lootHeader:SetText("|cffffd100Trade Goods & Loot:|r")
    rightPage.lootHeader = lootHeader

    local lootScroll = CreateFrame("ScrollFrame", "GrindSpotterLootScrollFrame", rightPage, "UIPanelScrollFrameTemplate")
    lootScroll:SetPoint("TOPLEFT", lootHeader, "BOTTOMLEFT", 0, -4)
    lootScroll:SetPoint("BOTTOMRIGHT", rightPage, "BOTTOMRIGHT", -26, 36)

    local lootContent = CreateFrame("Frame", nil, lootScroll)
    lootContent:SetSize(350, 100)
    lootScroll:SetScrollChild(lootContent)
    rightPage.lootContent = lootContent

    local lootText = lootContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lootText:SetPoint("TOPLEFT", lootContent, "TOPLEFT", 2, -2)
    lootText:SetWidth(340)
    lootText:SetJustifyH("LEFT")
    lootText:SetText("")
    rightPage.lootText = lootText

    -- Bottom: Set Waypoint Button
    local rightWaypointBtn = CreateFrame("Button", "GrindSpotterRightWaypointBtn", rightPage, "UIPanelButtonTemplate")
    rightWaypointBtn:SetSize(130, 24)
    rightWaypointBtn:SetPoint("BOTTOM", rightPage, "BOTTOM", 0, 8)
    rightWaypointBtn:SetText("Set Waypoint")
    rightWaypointBtn:SetScript("OnClick", function()
        local camp = GrindSpotter.currentSelectedCamp
        if camp then
            GrindSpotter:SetWaypoint(camp.mapID, camp.x, camp.y, camp.name)
        end
    end)
    rightPage.waypointBtn = rightWaypointBtn

    -- Search inputs positioned at top of leftPage
    local queryLabel = leftPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    queryLabel:SetPoint("TOPLEFT", leftPage, "TOPLEFT", 10, -10)
    queryLabel:SetText("Search (Item/Mob/Leave empty for XP):")

    local queryBox = CreateFrame("EditBox", "GrindSpotterQueryBox", leftPage, "InputBoxTemplate")
    queryBox:SetSize(170, 24)
    queryBox:SetPoint("TOPLEFT", queryLabel, "BOTTOMLEFT", 6, -4)
    queryBox:SetAutoFocus(false)
    f.queryBox = queryBox

    local targetLabel = leftPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    targetLabel:SetPoint("LEFT", queryLabel, "LEFT", 185, 0)
    targetLabel:SetText("Target:")

    local targetBox = CreateFrame("EditBox", "GrindSpotterTargetBox", leftPage, "InputBoxTemplate")
    targetBox:SetSize(60, 24)
    targetBox:SetPoint("TOPLEFT", targetLabel, "BOTTOMLEFT", 6, -4)
    targetBox:SetAutoFocus(false)
    targetBox:SetNumeric(true)
    f.targetBox = targetBox

    local searchBtn = CreateFrame("Button", nil, leftPage, "UIPanelButtonTemplate")
    searchBtn:SetSize(80, 24)
    searchBtn:SetPoint("LEFT", targetBox, "RIGHT", 8, 0)
    searchBtn:SetText("Find Spots")
    searchBtn:SetScript("OnClick", function()
        GrindSpotter:RunSearch()
    end)
    f.searchBtn = searchBtn

    queryBox:SetScript("OnEnterPressed", function() searchBtn:Click() end)
    targetBox:SetScript("OnEnterPressed", function() searchBtn:Click() end)

    local banner = CreateFrame("Frame", nil, leftPage, "BackdropTemplate")
    banner:SetPoint("TOPLEFT", queryBox, "BOTTOMLEFT", -6, -8)
    banner:SetPoint("TOPRIGHT", leftPage, "TOPRIGHT", -10, -66)
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

    local scrollFrame = CreateFrame("ScrollFrame", "GrindSpotterScrollFrame", leftPage, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", leftPage, "BOTTOMRIGHT", -22, 10)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(364, 400)
    scrollFrame:SetScrollChild(content)

    f.scrollFrame = scrollFrame
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
        card:SetSelected(false)
        card.campResult = nil
        card.campData = nil
    end

    local cardY = 0
    local cardHeight = 75
    local spacing = 5

    for i, res in ipairs(scoredResults) do
        local card = resultCards[i]
        if not card then
            card = CreateResultCard(mainFrame.content, i)
            resultCards[i] = card
        end

        local camp = res.camp
        card.campResult = res
        card.campData = camp
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

    if #scoredResults > 0 then
        GrindSpotter:SelectCamp(scoredResults[1])
    else
        GrindSpotter:SelectCamp(nil)
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

