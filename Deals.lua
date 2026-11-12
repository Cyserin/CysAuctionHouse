--------------------------------------------------------------------------------
-- Cys's Auction House - Deals
--   Vendor deals: listings below what a vendor pays for the item -> buy, then sell to any vendor.
--   Flips: the cheapest listings are far below the next one -> buy, relist just under that next price.
-- Deals come from prices seen in the last hour (full scan or your own searches). Clicking a deal runs a
-- live search for that item; the Buy button only buys what is still at or under the deal's price.
-- The game needs your own click for every purchase. Purchases over the "Ask before buying" amount need
-- a second click on Confirm, which shows the item and total.
--------------------------------------------------------------------------------
local AH = CysAH
local S = AH.Style
local P = AH.Prices
local UI = AH.UI
local D = {}
AH.Deals = D

local AH_CUT = 0.05
local MAX_AGE = 3600
local ROWS = 16
local ROW_H = 20

local DEFAULTS = { dealMinProfit = 2000, dealFlipPct = 30, dealConfirmOver = 10000, dealHideRecipes = true }

AH.On("ADDON_LOADED", function(name)
    if name ~= "CysAuctionHouse" then return end
    for k, v in pairs(DEFAULTS) do if AH.settings[k] == nil then AH.settings[k] = v end end
    AH.db.hidden = AH.db.hidden or {} -- [itemID] = true: never show as a deal
end)

local function SellPrice(id)
    local sell
    if GetItemInfo then sell = select(11, GetItemInfo(id)) end
    if sell == nil and C_Item and C_Item.GetItemInfo then sell = select(11, C_Item.GetItemInfo(id)) end
    if sell == nil then P.Request(id) end
    return sell
end

local function ClassID(id)
    if C_Item and C_Item.GetItemInfoInstant then return select(6, C_Item.GetItemInfoInstant(id)) end
    if GetItemInfoInstant then return select(6, GetItemInfoInstant(id)) end
end

--------------------------------------------------------------------------------
-- Finding deals
--------------------------------------------------------------------------------
-- deal = { id, kind = "vendor" | "flip", qty, cost, maxUnit (highest price per item worth paying),
--          sellAt (per item: vendor price, or relist price), profit, listings }
function D.Find()
    local out = {}
    local set = AH.settings
    local now = time()
    local keep = 1 - (set.dealFlipPct or 30) / 100
    for id, r in pairs(AH.realm.items) do
        if r.l and r.t and now - r.t <= MAX_AGE and not AH.db.hidden[id]
            and not (set.dealHideRecipes and ClassID(id) == 9) then
            local l, c = r.l, r.c or {}
            local best

            -- vendor deal
            local sell = SellPrice(id)
            if sell and sell > 0 then
                local qty, cost, profit, maxUnit = 0, 0, 0, 0
                for i = 1, #l do
                    if l[i] < sell then
                        local n = c[i] or 1
                        qty, cost = qty + n, cost + l[i] * n
                        profit = profit + (sell - l[i]) * n
                        maxUnit = l[i]
                    end
                end
                if qty > 0 and profit >= set.dealMinProfit then
                    best = { id = id, kind = "vendor", qty = qty, cost = cost, maxUnit = maxUnit,
                             sellAt = sell, profit = profit, listings = r.n }
                end
            end

            -- flip (not weapons / armor: the same item can carry different stats, so prices don't compare)
            local class = ClassID(id)
            if #l >= 2 and class ~= 2 and class ~= 4 then
                local k
                for i = 1, #l - 1 do
                    if l[i] <= l[i + 1] * keep then k = i; break end
                end
                if k then
                    local relist = l[k + 1] - 1
                    local usual = AH.GetMarketPrice(id)
                    if usual and usual < relist then relist = usual end -- don't count on a price above the usual
                    local net = relist * (1 - AH_CUT)
                    local qty, cost, profit, maxUnit = 0, 0, 0, 0
                    for i = 1, k do
                        if l[i] < net then
                            local n = c[i] or 1
                            qty, cost = qty + n, cost + l[i] * n
                            profit = profit + (net - l[i]) * n
                            maxUnit = l[i]
                        end
                    end
                    if qty > 0 and profit >= set.dealMinProfit and (not best or profit > best.profit) then
                        best = { id = id, kind = "flip", qty = qty, cost = cost, maxUnit = maxUnit,
                                 sellAt = relist, profit = math.floor(profit), listings = r.n }
                    end
                end
            end

            if best then out[#out + 1] = best end
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
    return out
end

--------------------------------------------------------------------------------
-- Live check + buying
--------------------------------------------------------------------------------
-- D.live = { id, commodity = bool, qty, cost, auctions = { { auctionID, buyout, qty, unit } } }
D.state = "idle" -- idle / searching / ready / quote / confirm / buying
D.msg = ""

local function Say(text, state)
    D.msg = text or ""
    if state then D.state = state end
    if D.OnChange then pcall(D.OnChange) end
end

local ReadCommodity, ReadItem -- below
local token = 0
local function Search(id)
    local key = C_AuctionHouse.MakeItemKey(id)
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    C_AuctionHouse.SendSearchQuery(key, sorts, true)
    token = token + 1
    local mine, sel = token, D.sel
    -- read results the game already had (it may send no event for those)
    local function Check()
        if mine ~= token or D.state ~= "searching" or D.sel ~= sel then return end
        if (C_AuctionHouse.GetNumCommoditySearchResults(id) or 0) > 0 then ReadCommodity(id)
        elseif (C_AuctionHouse.GetNumItemSearchResults(key) or 0) > 0 then ReadItem(key)
        elseif C_AuctionHouse.HasSearchResults and C_AuctionHouse.HasSearchResults(key) then ReadItem(key) end
    end
    C_Timer.After(0.6, Check)
    C_Timer.After(2, Check)
    C_Timer.After(6, function()
        if mine == token and D.state == "searching" and D.sel == sel then
            Say("The Auction House did not answer. Click the deal again to retry.", "idle")
        end
    end)
end

local waitingReady = false
function D.Select(deal)
    D.sel, D.live = deal, nil
    if not deal then Say("", "idle"); return end
    Say("Checking the Auction House...", "searching")
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        waitingReady = true
        return
    end
    Search(deal.id)
end

AH.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    if waitingReady and D.sel and D.state == "searching" then
        waitingReady = false
        Search(D.sel.id)
    end
end)

local function LiveDone(live)
    D.live = live
    local sel = D.sel
    if live.qty == 0 then
        Say("Gone - nothing is listed at the deal's price any more.", "idle")
        D.gone = D.gone or {}
        D.gone[sel.id] = time()
        if D.OnListChange then pcall(D.OnListChange) end
        return
    end
    local each = live.cost / live.qty
    local profit
    if sel.kind == "vendor" then profit = (sel.sellAt - each) * live.qty
    else profit = (sel.sellAt * (1 - AH_CUT) - each) * live.qty end
    live.profit = profit
    Say(("Now: %d for %s  -  profit about %s"):format(live.qty, AH.Money(live.cost), AH.Money(math.max(0, profit))), "ready")
end

function ReadCommodity(itemID)
    local sel = D.sel
    if not sel or itemID ~= sel.id or D.state ~= "searching" then return end
    local qty, cost = 0, 0
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice <= sel.maxUnit and not r.containsOwnerItem then
            qty, cost = qty + r.quantity, cost + r.unitPrice * r.quantity
        end
    end
    LiveDone({ id = itemID, commodity = true, qty = qty, cost = cost })
end
AH.On("COMMODITY_SEARCH_RESULTS_UPDATED", ReadCommodity)
AH.On("COMMODITY_SEARCH_RESULTS_ADDED", ReadCommodity)

function ReadItem(itemKey)
    local sel = D.sel
    if not sel or not itemKey or itemKey.itemID ~= sel.id or D.state ~= "searching" then return end
    local auctions, qty, cost = {}, 0, 0
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and r.quantity and r.quantity > 0 and not r.containsOwnerItem then
            local unit = r.buyoutAmount / r.quantity
            if unit <= sel.maxUnit then
                auctions[#auctions + 1] = { auctionID = r.auctionID, buyout = r.buyoutAmount, qty = r.quantity, unit = unit }
                qty, cost = qty + r.quantity, cost + r.buyoutAmount
            end
        end
    end
    table.sort(auctions, function(a, b) return a.unit < b.unit end)
    LiveDone({ id = sel.id, itemKey = itemKey, commodity = false, qty = qty, cost = cost, auctions = auctions })
end
AH.On("ITEM_SEARCH_RESULTS_UPDATED", ReadItem)
AH.On("ITEM_SEARCH_RESULTS_ADDED", ReadItem)

-- The Buy / Confirm button (always the player's own click)
function D.Buy()
    local sel, live = D.sel, D.live
    if not sel or not live then return end
    local limit = AH.settings.dealConfirmOver or 0
    if live.commodity then
        if D.state == "ready" then
            D.expect = live.cost
            C_AuctionHouse.StartCommoditiesPurchase(live.id, live.qty)
            Say("Getting the price from the server...", "quote")
        elseif D.state == "confirm" then
            C_AuctionHouse.ConfirmCommoditiesPurchase(live.id, live.qty)
            Say("Buying...", "buying")
        end
    else
        local a = live.auctions[1]
        if not a then return end
        if D.state == "ready" and a.buyout > limit then
            D.pending = a
            Say(("Confirm: buy %d for %s?"):format(a.qty, AH.Money(a.buyout)), "confirm")
        elseif D.state == "ready" or (D.state == "confirm" and D.pending == a) then
            C_AuctionHouse.PlaceBid(a.auctionID, a.buyout)
            table.remove(live.auctions, 1)
            live.qty, live.cost = live.qty - a.qty, live.cost - a.buyout
            Say("Buying...", "buying")
        end
    end
end

AH.On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
    if D.state ~= "quote" or not D.live then return end
    local live = D.live
    -- never pay more than the live check showed (1% slack for rounding)
    if totalPrice > (D.expect or 0) * 1.01 + 1 then
        C_AuctionHouse.CancelCommoditiesPurchase()
        Say(("Not bought: the price rose to %s."):format(AH.Money(totalPrice)), "idle")
        return
    end
    if totalPrice > (AH.settings.dealConfirmOver or 0) then
        Say(("Confirm: buy %d for %s?"):format(live.qty, AH.Money(totalPrice)), "confirm")
    else
        C_AuctionHouse.ConfirmCommoditiesPurchase(live.id, live.qty)
        Say("Buying...", "buying")
    end
end)

AH.On("COMMODITY_PRICE_UNAVAILABLE", function()
    if D.state == "quote" then Say("The server could not price this right now. Try again.", "idle") end
end)

local function Bought(text)
    local sel = D.sel
    if not sel then return end
    local tip = sel.kind == "vendor" and "Sell it to any vendor." or ("Relist at about " .. AH.Money(sel.sellAt) .. " each.")
    Say(text .. " " .. tip, "idle")
    D.gone = D.gone or {}
    D.gone[sel.id] = time()
    if D.OnListChange then pcall(D.OnListChange) end
end

AH.On("COMMODITY_PURCHASE_SUCCEEDED", function() if D.state == "buying" then Bought("Bought.") end end)
AH.On("COMMODITY_PURCHASE_FAILED", function() if D.state == "buying" or D.state == "confirm" then Say("The purchase failed.", "idle") end end)
AH.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function()
    if D.state ~= "buying" or not D.live or D.live.commodity then return end
    if #D.live.auctions > 0 then
        Say(("Bought. %d more at the deal price - click Buy again."):format(D.live.qty), "ready")
    else
        Bought("Bought.")
    end
end)
AH.On("AUCTION_HOUSE_SHOW_ERROR", function()
    if D.state == "buying" or D.state == "quote" then Say("The purchase failed.", "idle") end
end)
AH.On("AUCTION_HOUSE_CLOSED", function() D.sel, D.live, D.state, D.msg = nil, nil, "idle", "" end)

--------------------------------------------------------------------------------
-- The Deals view (built into the Cys's AH panel)
--------------------------------------------------------------------------------
local function Quality(id)
    local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
    if not q and GetItemInfo then q = select(3, GetItemInfo(id)) end
    return q
end

local function Short(copper)
    -- compact money: 1g 20s / 35s 10c / 80c
    copper = math.floor(copper + 0.5)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then return s > 0 and ("%dg %ds"):format(g, s) or (g .. "g") end
    if s > 0 then return c > 0 and ("%ds %dc"):format(s, c) or (s .. "s") end
    return c .. "c"
end

local function MoneyStep(v)
    if v == 0 then return "always" end
    return Short(v)
end

function UI.BuildDeals(parent)
    local T = S.T()
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    ---------------------------------------------------------------- left card: settings + selected deal
    local card = S.Panel(v, T.card, T.line)
    card:SetPoint("TOPLEFT", 10, -46)
    card:SetPoint("BOTTOMLEFT", 10, 8)
    card:SetWidth(232)

    local h = S.Text(card, 12, T.accent)
    h:SetPoint("TOPLEFT", 12, -12)
    h:SetText("Deals")

    local function Changed() if UI.RefreshDeals then UI.RefreshDeals() end end
    local s1 = S.Stepper(card, "Minimum profit", { 100, 500, 1000, 2000, 5000, 10000, 20000, 50000 },
        function() return AH.settings.dealMinProfit end, function(x) AH.settings.dealMinProfit = x; Changed() end, Short)
    s1:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -10)
    local s2 = S.Stepper(card, "Flip: under next by", { 20, 30, 40, 50, 60 },
        function() return AH.settings.dealFlipPct end, function(x) AH.settings.dealFlipPct = x; Changed() end,
        function(x) return x .. "%" end)
    s2:SetPoint("TOPLEFT", s1, "BOTTOMLEFT", 0, -6)
    local s3 = S.Stepper(card, "Confirm over", { 0, 5000, 10000, 20000, 50000, 100000 },
        function() return AH.settings.dealConfirmOver end, function(x) AH.settings.dealConfirmOver = x end, MoneyStep)
    s3:SetPoint("TOPLEFT", s2, "BOTTOMLEFT", 0, -6)

    local recipes = S.Check(card, "Hide recipes and formulas",
        function() return AH.settings.dealHideRecipes end, function(x) AH.settings.dealHideRecipes = x; Changed() end)
    recipes:SetPoint("TOPLEFT", s3, "BOTTOMLEFT", 0, -8)

    local sep = S.Tex(card, "ARTWORK", T.line)
    sep:SetPoint("TOPLEFT", recipes, "BOTTOMLEFT", 0, -10)
    sep:SetSize(208, 1)

    -- selected deal
    local selIcon = card:CreateTexture(nil, "ARTWORK")
    selIcon:SetSize(28, 28)
    selIcon:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -12)
    selIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local selName = S.Text(card, 12, T.text)
    selName:SetPoint("TOPLEFT", selIcon, "TOPRIGHT", 8, -1)
    selName:SetWidth(172)
    selName:SetWordWrap(false)
    local selKind = S.Text(card, 10, T.dim)
    selKind:SetPoint("TOPLEFT", selName, "BOTTOMLEFT", 0, -3)
    local selInfo = S.Text(card, 11, T.text)
    selInfo:SetPoint("TOPLEFT", selIcon, "BOTTOMLEFT", 0, -10)
    selInfo:SetWidth(208)
    local selMsg = S.Text(card, 11, T.accent)
    selMsg:SetPoint("TOPLEFT", selInfo, "BOTTOMLEFT", 0, -8)
    selMsg:SetWidth(208)
    local buy = S.Button(card, 208, 26, "Buy")
    buy:SetPoint("TOPLEFT", selMsg, "BOTTOMLEFT", 0, -10)
    buy:SetScript("OnClick", function() D.Buy() end)

    local hiddenTxt = S.Text(card, 10, T.dim)
    hiddenTxt:SetPoint("BOTTOMLEFT", 12, 14)
    local unhide = S.Button(card, 80, 18, "Show again")
    unhide:SetPoint("BOTTOMRIGHT", -12, 10)
    unhide:SetScript("OnClick", function() wipe(AH.db.hidden); Changed() end)

    local function PaintSel()
        local sel = D.sel
        local show = sel ~= nil
        selIcon:SetShown(show); selName:SetShown(show); selKind:SetShown(show); selInfo:SetShown(show); buy:SetShown(show)
        if not sel then
            selMsg:SetText("Click a deal to check it live and buy it.")
            return
        end
        selIcon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(sel.id)) or 134400)
        selName:SetText(P.Name(sel.id) or ("item " .. sel.id))
        selKind:SetText(sel.kind == "vendor" and ("Vendor deal  -  vendor pays " .. Short(sel.sellAt) .. " each")
            or ("Flip  -  relist at about " .. Short(sel.sellAt) .. " each"))
        selInfo:SetText(("From the scan: %d for %s  -  profit about %s"):format(sel.qty, AH.Money(sel.cost), AH.Money(sel.profit)))
        selMsg:SetText(D.msg or "")
        if D.state == "confirm" then
            buy:SetLabel("Confirm")
            buy:SetActive(true)
        elseif D.state == "ready" then
            buy:SetLabel(D.live and not D.live.commodity and D.live.auctions[1]
                and ("Buy " .. D.live.auctions[1].qty .. " for " .. Short(D.live.auctions[1].buyout))
                or ("Buy " .. (D.live and D.live.qty or 0)))
            buy:SetActive(true)
        else
            buy:SetLabel("Buy")
            buy:SetActive(false)
        end
    end
    D.OnChange = PaintSel

    ---------------------------------------------------------------- deal list
    local list = S.Panel(v, T.card, T.line)
    list:SetPoint("TOPLEFT", card, "TOPRIGHT", 10, 0)
    list:SetPoint("BOTTOMRIGHT", -10, 8)
    list:EnableMouseWheel(true)

    local title = S.Text(list, 11, T.accent)
    title:SetPoint("TOPLEFT", 12, -14)
    local note = S.Text(list, 10, T.dim, "RIGHT")
    note:SetPoint("TOPRIGHT", -12, -15)
    note:SetText("From prices seen in the last hour")

    local headY = -42
    local HEAD = { { "Item", 34, "LEFT" }, { "Type", 158, "LEFT" }, { "Buy", -214, "RIGHT" }, { "Sell each", -124, "RIGHT" }, { "Profit", -34, "RIGHT" } }
    for _, c in ipairs(HEAD) do
        local fs = S.Text(list, 10, T.accent, c[3])
        if c[2] > 0 then fs:SetPoint("TOPLEFT", c[2], headY) else fs:SetPoint("TOPRIGHT", c[2], headY) end
        fs:SetText(c[1])
    end
    local line = S.Tex(list, "ARTWORK", T.line)
    line:SetPoint("TOPLEFT", 8, headY - 14)
    line:SetPoint("TOPRIGHT", -8, headY - 14)
    line:SetHeight(1)

    local data, offset = {}, 0
    local rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 8, headY - 18 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", -8, headY - 18 - (i - 1) * ROW_H)
        r.hl = S.Tex(r, "BACKGROUND", T.cardHover)
        r.hl:SetAllPoints()
        r.hl:Hide()
        r.selbar = S.Tex(r, "ARTWORK", T.glow)
        r.selbar:SetPoint("TOPLEFT"); r.selbar:SetPoint("BOTTOMLEFT"); r.selbar:SetWidth(2)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("LEFT", 6, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.name = S.Text(r, 11, T.text)
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetWidth(122)
        r.name:SetWordWrap(false)
        r.kind = S.Text(r, 10, T.dim)
        r.kind:SetPoint("LEFT", 150, 0)
        r.buy = S.Text(r, 11, T.text, "RIGHT"); r.buy:SetPoint("RIGHT", -206, 0)
        r.sell = S.Text(r, 11, T.text, "RIGHT"); r.sell:SetPoint("RIGHT", -116, 0)
        r.profit = S.Text(r, 11, T.green, "RIGHT"); r.profit:SetPoint("RIGHT", -26, 0)
        r.x = CreateFrame("Button", nil, r)
        r.x:SetSize(16, 16)
        r.x:SetPoint("RIGHT", -2, 0)
        r.x.t = S.Text(r.x, 11, T.dim, "CENTER")
        r.x.t:SetPoint("CENTER")
        r.x.t:SetText("x")
        r.x:SetScript("OnEnter", function(s)
            s.t:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetText("Never show this item as a deal")
            GameTooltip:Show()
        end)
        r.x:SetScript("OnLeave", function(s) s.t:SetTextColor(T.dim[1], T.dim[2], T.dim[3]); GameTooltip:Hide() end)
        r.x:SetScript("OnClick", function(s)
            local d = s:GetParent().deal
            if d then
                AH.db.hidden[d.id] = true
                if D.sel == d then D.Select(nil) end
                Changed()
            end
        end)
        r:SetScript("OnEnter", function(s)
            s.hl:Show()
            if s.deal then
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(s.deal.id)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
        r:SetScript("OnClick", function(s)
            if s.deal then D.Select(s.deal); UI.PaintDeals() end
        end)
        rows[i] = r
    end

    local foot = S.Text(list, 10, T.dim)
    foot:SetPoint("BOTTOMLEFT", 12, 10)

    local function Confidence(n)
        if not n then return "|cff8a8a8a" end
        if n >= 10 then return "|cff4fd66b" elseif n >= 4 then return "|cffffd100" end
        return "|cffff6060"
    end

    function UI.PaintDeals()
        local max = math.max(0, #data - ROWS)
        if offset > max then offset = max end
        local money = GetMoney()
        for i = 1, ROWS do
            local r, d = rows[i], data[offset + i]
            r.deal = d
            if d then
                r:SetAlpha(d.cost > money and 0.4 or 1) -- more than you carry: greyed
                r.icon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(d.id)) or 134400)
                r.name:SetText(P.Name(d.id) or ("item " .. d.id))
                local q = Quality(d.id)
                local col = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
                if col then r.name:SetTextColor(col.r, col.g, col.b) else r.name:SetTextColor(T.text[1], T.text[2], T.text[3]) end
                r.kind:SetText(Confidence(d.listings) .. (d.kind == "vendor" and "Vendor" or "Flip") .. "|r")
                r.buy:SetText(("|cff8a8a8a%d x|r %s"):format(d.qty, Short(d.cost / d.qty)))
                r.sell:SetText(Short(d.sellAt))
                r.profit:SetText(Short(d.profit))
                r.selbar:SetShown(D.sel and D.sel.id == d.id or false)
                r:Show()
            else
                r:Hide()
            end
        end
        if #data == 0 then
            foot:SetText("No deals right now. They come from a full scan or your own searches in the last hour.")
        else
            foot:SetText(("%d-%d of %d  -  Type color = listings (green many, red few); grey = costs more than you carry"):format(
                offset + 1, math.min(offset + ROWS, #data), #data))
        end
        local n = 0
        for _ in pairs(AH.db.hidden) do n = n + 1 end
        hiddenTxt:SetText(n > 0 and (n .. " hidden") or "")
        unhide:SetShown(n > 0)
        PaintSel()
    end

    function UI.RefreshDeals()
        if not v:IsVisible() then return end
        local all = D.Find()
        data = {}
        local gone = D.gone or {}
        for _, d in ipairs(all) do
            local g = gone[d.id]
            local r = AH.realm.items[d.id]
            -- bought or sold out: hidden until the price is seen again after that
            if not g or (r and r.t > g) then data[#data + 1] = d end
        end
        title:SetText(#data .. (#data == 1 and " deal" or " deals"))
        UI.PaintDeals()
    end
    D.OnListChange = UI.RefreshDeals

    list:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 3)
        UI.PaintDeals()
    end)
    v:SetScript("OnShow", UI.RefreshDeals)
    AH.RegisterCallback(function() if v:IsVisible() then UI.RefreshDeals() end end)
    return v
end
