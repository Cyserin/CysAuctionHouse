--------------------------------------------------------------------------------
-- Cys's Auction House - tooltip lines
--   Cys AH: 1g 20s (2h)          lowest buyout per item, and how long ago it was seen
--   Cys AH usual: 1g 05s         middle of the daily lows (only when 2+ days are saved and it differs)
--------------------------------------------------------------------------------
local AH = CysAH

local function Add(tt, itemID)
    if not AH.settings or not AH.settings.tooltip or not itemID then return end
    local price = AH.GetPrice(itemID)
    if not price then return end
    local age = AH.GetPriceAge(itemID)
    local right = AH.Money(price)
    if age then right = right .. " |cff8a8a8a(" .. AH.Age(age) .. ")|r" end
    tt:AddDoubleLine("|cffd9a421Cys AH|r", "|cffffffff" .. right .. "|r")
    local market = AH.GetMarketPrice(itemID)
    if market and math.abs(market - price) > price * 0.05 then
        tt:AddDoubleLine("|cffd9a421Cys AH usual|r", "|cffffffff" .. AH.Money(market) .. "|r")
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
        if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
        local id = data and data.id
        if type(id) ~= "number" then return end
        Add(tt, id)
    end)
else
    -- older clients
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
        local _, link = tt:GetItem()
        Add(tt, AH.ItemID(link))
    end)
end
