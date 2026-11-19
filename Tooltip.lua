--------------------------------------------------------------------------------
-- Cys's Auction House - tooltip lines
--   Cys AH: 1g 20s (2h)          lowest buyout per item, and how long ago it was seen
--   Cys AH usual: 1g 05s         middle of the daily lows (only when 2+ days are saved and it differs)
--   Hold Shift for the usual price, how often it sells and the craft details; the plain tooltip keeps only
--   the current price and the craft-or-sell line.
--------------------------------------------------------------------------------
local AH = CysAH

local function Add(tt, itemID, link) -- link: for random-suffix gear (priced per suffix)
    if not AH.settings or not AH.settings.tooltip or not itemID then return end
    local item = link or itemID
    local price = AH.GetPrice(item)
    if not price then return end
    local age = AH.GetPriceAge(item)
    local right = AH.Money(price)
    if age then right = right .. " |cff8a8a8a(" .. AH.Age(age) .. ")|r" end
    tt:AddDoubleLine("|cffd9a421Cys AH|r", "|cffffffff" .. right .. "|r")
    if not IsShiftKeyDown() then return end
    local market = AH.GetMarketPrice(item)
    if market and math.abs(market - price) > price * 0.05 then
        tt:AddDoubleLine("|cffd9a421Cys AH usual|r", "|cffffffff" .. AH.Money(market) .. "|r")
    end
    -- how often it sells (History.lua): your own auctions, plus the market when watched long enough
    if AH.GetSellRate then
        local ok, rate, n, market = pcall(AH.GetSellRate, itemID)
        if ok and rate then
            local src = (n and n > 0) and (("your %d auction%s"):format(n, n == 1 and "" or "s") .. (market and " + market" or "")) or "market"
            tt:AddDoubleLine("|cffd9a421Cys AH sells|r", ("|cffffffff%d%%|r |cff8a8a8a(%s)|r"):format(math.floor(rate * 100 + 0.5), src))
        end
    end
end

-- Cloth / ore / stone: craft it or sell it as is? From the last scan, for what you carry (or a stack of 20).
local VERB = { bandage = "Make", bar = "Smelt into", stone = "Make" }
local MAT = { bandage = "cloth", bar = "ore", stone = "stone" }
local function AddCraft(tt, itemID)
    if not AH.settings or not AH.settings.tooltip or not AH.Sell or not AH.Sell.CraftAdvice then return end
    local have = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID)) or (GetItemCount and GetItemCount(itemID)) or 0
    local ok, best, asIs, n, stack = pcall(AH.Sell.CraftAdvice, itemID, have)
    if not ok or not best then return end
    local diff = best.value - asIs
    local who = stack and "a stack of 20" or ("your " .. n)
    local maybe = best.sure and "" or " |cff8a8a8a(if known)|r"
    if diff > 0 then
        tt:AddDoubleLine(("|cffd9a421%s %s|r%s"):format(VERB[best.kind] or "Make", best.name, maybe),
            "|cff4fd66b+" .. AH.Money(diff) .. "|r")
        if IsShiftKeyDown() then
            tt:AddLine(("|cff8a8a8a%d crafted from %s, vs selling the %s|r"):format(best.crafts, who, MAT[best.kind] or "material"))
        end
    else
        tt:AddDoubleLine(("|cffd9a421Sell the %s|r"):format(MAT[best.kind] or "material"),
            ("|cff8a8a8a%s pays %s less|r"):format(best.name, AH.Money(-diff)))
    end
    if IsShiftKeyDown() and (best.rate or best.matRate) then
        local pct = AH.Sell.Pct
        tt:AddLine(("|cff8a8a8aCounts how often each sells: %s %s, %s %s|r"):format(best.name, best.onAH and pct(best.rate) or "vendor",
            MAT[best.kind] or "material", pct(best.matRate)))
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
        if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
        local id = data and data.id
        if type(id) ~= "number" then return end
        -- the tooltip's own link only when it is this item (a recipe tooltip's GetItem is the crafted item)
        local link = data.hyperlink
        if not link and tt.GetItem then link = select(2, tt:GetItem()) end
        if link and AH.ItemID(link) ~= id then link = nil end
        Add(tt, id, link)
        AddCraft(tt, id)
    end)
else
    -- older clients
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
        local _, link = tt:GetItem()
        Add(tt, AH.ItemID(link), link)
        local id = AH.ItemID(link)
        if id then AddCraft(tt, id) end
    end)
end

-- Shift pressed or let go while an item tooltip is up: redraw it. Blizzard's own buttons redraw by themselves
-- (UpdateTooltip); for others (our bags, windows) run the owner's OnEnter again, out of combat only.
AH.On("MODIFIER_STATE_CHANGED", function(key)
    if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
    if not AH.settings or not AH.settings.tooltip or InCombatLockdown() or not GameTooltip:IsShown() then return end
    local owner = GameTooltip:GetOwner()
    if not owner or owner.UpdateTooltip or owner:IsForbidden() or owner:IsProtected() then return end
    if not GameTooltip:GetItem() or not owner:IsMouseOver() then return end
    local enter = owner:GetScript("OnEnter")
    if enter then pcall(enter, owner) end
end)
