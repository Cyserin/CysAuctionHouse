--------------------------------------------------------------------------------
-- Cys's Auction House - Sell
-- Pick an item (from the list of your bags, or drop it on the slot) -> the AH's current listings for it
-- load, the price is set to undercut the cheapest one (or match it when the cheapest is yours), quantity
-- is everything you carry. Post with your own click. After posting, the next item in your bags is picked.
-- Smart prices: never below a floor (your own per item, or a % of the usual price, never under the vendor);
-- Post all walks every worthwhile bag item, one Post click each.
--------------------------------------------------------------------------------
local AH = CysAH
local S = AH.Style
local P = AH.Prices
local UI = AH.UI
local Sell = {}
AH.Sell = Sell

-- duration 2 (medium); undercut by 1 copper; smart prices never go below the floor (70% of the usual price,
-- and never under what a vendor pays)
local DEFAULTS = { sellDuration = 2, sellUndercut = 1, sellSmart = true, sellFloorPct = 70 }
AH.On("ADDON_LOADED", function(name)
    if name ~= "CysAuctionHouse" then return end
    for k, v in pairs(DEFAULTS) do if AH.settings[k] == nil then AH.settings[k] = v end end
    AH.db.sellRules = AH.db.sellRules or {} -- [itemID] = { floor = copper you set, dur = 1-3 }
    AH.db.noSell = AH.db.noSell or {}       -- [itemID] = true: left out of Post all
end)

-- the game's own duration names (WoW Forever: short / medium / long, e.g. "8 Hours"), shortened to "8h"
local function DurText(s, fallback)
    if type(s) ~= "string" or s == "" then return fallback end
    local h = s:match("(%d+)")
    return h and (h .. "h") or s
end
local DURATIONS = { { 1, DurText(_G.AUCTION_DURATION_ONE, "Short") }, { 2, DurText(_G.AUCTION_DURATION_TWO, "Medium") },
                    { 3, DurText(_G.AUCTION_DURATION_THREE, "Long") } }
local LIST_ROWS, BAG_ROWS = 7, 9

local function Short(copper)
    copper = math.floor((copper or 0) + 0.5)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then return s > 0 and ("%dg %ds"):format(g, s) or (g .. "g") end
    if s > 0 then return c > 0 and ("%ds %dc"):format(s, c) or (s .. "s") end
    return c .. "c"
end
Sell.Short = Short

-- How often this item sells on the AH (0-1, History.lua), or nil while unknown
local function Rate(id)
    if not AH.GetSellRate then return nil end
    local ok, r = pcall(AH.GetSellRate, id)
    return ok and r or nil
end
local function Pct(r) return r and (math.floor(r * 100 + 0.5) .. "%") or "?" end
Sell.Pct = Pct

local function SellPrice(id)
    local v
    if GetItemInfo then v = select(11, GetItemInfo(id)) end
    if v == nil and C_Item and C_Item.GetItemInfo then v = select(11, C_Item.GetItemInfo(id)) end
    return v
end

local function Valid(loc)
    return loc and loc:IsValid() and C_Item.DoesItemExist(loc)
end

--------------------------------------------------------------------------------
-- Your sellable bag items: one row per item (gear: one row per piece, their stats can differ)
--------------------------------------------------------------------------------
function Sell.BagItems()
    local out, byID = {}, {}
    local last = (Enum.BagIndex and Enum.BagIndex.ReagentBag) or 4
    for bag = 0, last do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                if C_AuctionHouse.IsSellItemValid(loc, false) then
                    local gear = info.hyperlink and select(6, C_Item.GetItemInfoInstant(info.itemID))
                    gear = gear == 2 or gear == 4
                    local name = info.hyperlink and info.hyperlink:match("%[(.-)%]")
                    if name and name ~= "" and AH.db and (AH.db.names[info.itemID] or "") == "" then AH.db.names[info.itemID] = name end
                    local e = (not gear) and byID[info.itemID]
                    if e then
                        e.count = e.count + (info.stackCount or 1)
                    else
                        e = { id = info.itemID, loc = loc, count = info.stackCount or 1, link = info.hyperlink, gear = gear,
                              quality = info.quality, icon = info.iconFileID }
                        out[#out + 1] = e
                        if not gear then byID[info.itemID] = e end
                    end
                end
            end
        end
    end
    -- most valuable first (AH price x count), items without a price after
    table.sort(out, function(a, b)
        local pa, pb = (AH.GetPrice(a.link or a.id) or 0) * a.count, (AH.GetPrice(b.link or b.id) or 0) * b.count
        if pa ~= pb then return pa > pb end
        return (P.Name(a.id) or "") < (P.Name(b.id) or "")
    end)
    return out
end

-- /cysah bags: every unbound item the AH turns down, so we can see why something is missing from Your bags
function Sell.CheckBags()
    local last = (Enum.BagIndex and Enum.BagIndex.ReagentBag) or 4
    local n = 0
    for bag = 0, last do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                local valid = C_AuctionHouse.IsSellItemValid(loc, false)
                if info.isBound or not valid then
                    n = n + 1
                    AH.Print(("%s  bag %d slot %d  -  %s"):format(info.hyperlink or info.itemID, bag, slot,
                        info.isBound and "soulbound" or "the AH says it can't be sold"))
                end
            end
        end
    end
    AH.Print(n == 0 and "Every item in your bags can be listed." or (n .. " items left out (see above)."))
end

--------------------------------------------------------------------------------
-- Selected item + live listings
--------------------------------------------------------------------------------
-- Sell.sel = { id, loc, key (ItemKey), commodity, link, icon }
-- Sell.listings = { { unit, qty, mine } } cheapest first (nil while loading)
Sell.state = "idle" -- idle / searching / ready / posting / warning

--------------------------------------------------------------------------------
-- Cloth into bandages: First Aid recipes (our own table). For a cloth, is making bandages and selling them
-- to a vendor worth more than selling the cloth? Vendor prices are read live from the game.
-- { cloth, cloth per bandage, bandage item, recipe spell }
--------------------------------------------------------------------------------
local BANDAGES = {
    { 2589, 1, 1251, 3275 },   { 2589, 2, 2581, 3276 },   -- Linen / Heavy Linen
    { 2592, 1, 3530, 3277 },   { 2592, 2, 3531, 3278 },   -- Wool / Heavy Wool
    { 4306, 1, 6450, 7928 },   { 4306, 2, 6451, 7929 },   -- Silk / Heavy Silk
    { 4338, 1, 8544, 10840 },  { 4338, 2, 8545, 10841 },  -- Mageweave / Heavy Mageweave
    { 14047, 1, 14529, 18629 }, { 14047, 2, 14530, 18630 }, -- Runecloth / Heavy Runecloth
}
-- Ore into bars: Mining smelting (our own table). Bars sell on the AH, so a bar is worth its AH price after
-- the 5% cut, or what a vendor pays if that is more. { ore, ore per bar, bar item, smelt spell }
local SMELT = {
    { 2770, 1, 2840, 2657 },   -- Copper
    { 2771, 1, 3576, 3304 },   -- Tin
    { 2775, 1, 2842, 2658 },   -- Silver
    { 2772, 1, 3575, 3307 },   -- Iron
    { 2776, 1, 3577, 3308 },   -- Gold
    { 3858, 1, 3860, 10097 },  -- Mithril
    { 7911, 1, 6037, 10098 },  -- Truesilver
    { 10620, 1, 12359, 16153 }, -- Thorium
    { 11370, 8, 11371, 14891 }, -- Dark Iron (only at the Black Forge)
}
-- Stone into sharpening / grinding stones: Blacksmithing (our own table; weightstones need cloth, left out).
-- Valued like bars: AH price after the cut, or the vendor price if more. { stone, stones per item, item, spell }
local STONES = {
    { 2835, 1, 2862, 2660 },   { 2835, 2, 3470, 3320 },   -- Rough: sharpening / grinding
    { 2836, 1, 2863, 2665 },   { 2836, 2, 3478, 3326 },   -- Coarse
    { 2838, 1, 2871, 2674 },   { 2838, 3, 3486, 3337 },   -- Heavy
    { 7912, 1, 7964, 9918 },   { 7912, 4, 7966, 9920 },   -- Solid
    { 12365, 1, 12404, 16641 }, { 12365, 4, 12644, 16639 }, -- Dense
}
local BY_CLOTH = {} -- material -> its recipes (cloth and ore)
for _, r in ipairs(BANDAGES) do
    r.kind = "bandage"
    BY_CLOTH[r[1]] = BY_CLOTH[r[1]] or {}
    table.insert(BY_CLOTH[r[1]], r)
end
for _, r in ipairs(SMELT) do
    r.kind = "bar"
    BY_CLOTH[r[1]] = BY_CLOTH[r[1]] or {}
    table.insert(BY_CLOTH[r[1]], r)
end
for _, r in ipairs(STONES) do
    r.kind = "stone"
    BY_CLOTH[r[1]] = BY_CLOTH[r[1]] or {}
    table.insert(BY_CLOTH[r[1]], r)
end

-- known recipe? the spell check first, then what the First Aid window showed us
local function KnowsRecipe(spell)
    local ok, v = pcall(function()
        if C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(spell) then return true end
        if IsPlayerSpell and IsPlayerSpell(spell) then return true end
        return false
    end)
    if ok and v then return true end
    local seen = AH.db and AH.db.recipes
    if seen and seen[spell] ~= nil then return seen[spell] end
    return nil -- don't know
end
local function ReadRecipes()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and AH.db) then return end
    AH.db.recipes = AH.db.recipes or {}
    for _, list in ipairs({ BANDAGES, SMELT, STONES }) do
        for _, r in ipairs(list) do
            local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, r[4])
            if ok and info then AH.db.recipes[r[4]] = info.learned and true or false end
        end
    end
end
AH.On("TRADE_SKILL_SHOW", function() C_Timer.After(0.5, ReadRecipes) end)
AH.On("TRADE_SKILL_LIST_UPDATE", ReadRecipes)

-- Best bandage for n of this cloth, if it beats `beat` (copper). Returns
-- { name, crafts, value, gain, sure } or nil. Leftover cloth counts at the cloth's vendor price.
function Sell.BandageBest(clothID, n, beat)
    local list = BY_CLOTH[clothID]
    if not list or not n or n <= 0 then return nil end
    local clothV = SellPrice(clothID) or 0
    local best
    for _, r in ipairs(list) do
        local known = KnowsRecipe(r[4])
        local bv = SellPrice(r[3])
        if bv == nil and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(r[3]) end
        local onAH, rate = false, nil
        if r.kind ~= "bandage" then
            -- bars and stones: the AH price after the cut, times how often it sells (when known),
            -- when that beats the vendor (a vendor always buys)
            local p = AH.GetPrice(r[3]) or AH.GetMarketPrice(r[3])
            rate = Rate(r[3])
            local net = p and math.floor(p * 0.95 * (rate or 1))
            if net and net > (bv or 0) then bv, onAH = net, true end
        end
        local crafts = math.floor(n / r[2])
        if known ~= false and bv and bv > 0 and crafts > 0 then
            local value = crafts * bv + (n - crafts * r[2]) * clothV
            -- a tie goes to the recipe using more cloth per bandage (fewer crafts, better skill-ups)
            if not best or value > best.value or (value == best.value and r[2] > best.per) then
                best = { id = r[3], crafts = crafts, value = value, sure = known == true, per = r[2], each = bv,
                    kind = r.kind, onAH = onAH, spell = r[4], rate = onAH and rate or nil }
            end
        end
    end
    if best and best.value > (beat or 0) then
        best.gain = best.value - (beat or 0)
        best.name = (P and P.Name and P.Name(best.id)) or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(best.id)) or (best.kind == "bar" and "bars" or best.kind == "stone" and "stones" or "bandages")
        return best
    end
end
-- For the item tooltip (anywhere, from the last scan's prices): n of this material sold as is (AH after the
-- cut, or vendor if more) vs the best known recipe. Returns best, asIs, n, stack (n was guessed) or nil.
function Sell.CraftAdvice(id, n)
    if not BY_CLOTH[id] then return nil end
    local stack = not n or n <= 0
    if stack then n = 20 end
    local p = AH.GetPrice(id) or AH.GetMarketPrice(id)
    local rate = Rate(id)
    local net = p and math.floor(p * 0.95 * (rate or 1)) or 0
    local vend = SellPrice(id) or 0
    local each = math.max(net, vend)
    local best = Sell.BandageBest(id, n, -1)
    if not best then return nil end
    best.matRate = net > vend and rate or nil
    return best, each * n, n, stack
end

AH.repost = AH.repost or {} -- [itemID] = true: cancelled in My auctions, Post all lists these first
Sell.msg = ""

local function Changed() if Sell.OnChange then pcall(Sell.OnChange) end end
local function Say(text, state)
    Sell.msg = text or ""
    if state then Sell.state = state end
    Changed()
end

local waiting = false
local ReadCommodity, ReadItem -- below
local token = 0
local waitSince
local function Search(tries)
    local sel = Sell.sel
    if not sel then return end
    -- the AH holds searches back for a while (e.g. right after a full scan): check again every half second
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        waiting = true
        waitSince = waitSince or GetTime()
        if GetTime() - waitSince > 15 then
            waiting, waitSince = false, nil
            Sell.listings, Sell.noAnswer = nil, true
            Say("The Auction House is busy (searches are held back after a full scan). You can still post; click the item again later to see the listings.", "ready")
            return
        end
        Say("The Auction House is busy - waiting to look up the listings. You can post meanwhile.")
        C_Timer.After(0.5, function() if waiting and Sell.sel == sel and Sell.state == "searching" then Search(tries) end end)
        return
    end
    waiting, waitSince = false, nil
    tries = tries or 1
    token = token + 1
    local mine = token
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    -- like the game's own sell window: commodities and other stackables use the normal search,
    -- only gear (one auction per item level) uses the sell search
    local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(sel.key)
    local gear = info and info.isEquipment
    if gear == nil then gear = sel.gear end
    if gear and not sel.commodity then
        C_AuctionHouse.SendSellSearchQuery(sel.key, sorts, true)
    else
        C_AuctionHouse.SendSearchQuery(sel.key, sorts, true)
    end
    -- the game does not always send an event (e.g. results it already had): look for results ourselves
    local function Check()
        if mine ~= token or Sell.state ~= "searching" or Sell.sel ~= sel then return end
        local has = C_AuctionHouse.HasSearchResults and C_AuctionHouse.HasSearchResults(sel.key)
        if (C_AuctionHouse.GetNumCommoditySearchResults(sel.id) or 0) > 0 then ReadCommodity(sel.id)
        elseif (C_AuctionHouse.GetNumItemSearchResults(sel.key) or 0) > 0 then ReadItem(sel.key)
        elseif has then
            if sel.commodity then ReadCommodity(sel.id) else ReadItem(sel.key) end
        end
    end
    C_Timer.After(0.6, Check)
    C_Timer.After(2, Check)
    C_Timer.After(5, function()
        if mine ~= token or Sell.state ~= "searching" or Sell.sel ~= sel then return end
        if tries < 2 then
            Search(tries + 1)
        else
            -- no answer is not the same as nobody selling: keep the listings unknown
            Sell.listings, Sell.noAnswer = nil, true
            Say("The Auction House did not answer. Click the item again to retry.", "ready")
        end
    end)
end
AH.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    if waiting and Sell.state == "searching" then Search() end
end)

function Sell.Select(entry)
    if not entry or not Valid(entry.loc) then
        Sell.sel, Sell.listings = nil, nil
        Say("", "idle")
        return
    end
    local loc = entry.loc
    local status = C_AuctionHouse.GetItemCommodityStatus(loc)
    Sell.sel = {
        id = entry.id or C_Item.GetItemID(loc), loc = loc, key = C_AuctionHouse.GetItemKeyFromItem(loc),
        commodity = status == Enum.ItemCommodityStatus.Commodity, link = entry.link or C_Item.GetItemLink(loc), gear = entry.gear,
        icon = entry.icon or C_Item.GetItemIcon(loc),
    }
    Sell.listings, Sell.noAnswer = nil, nil
    Sell.priceSet = false
    waitSince = nil
    Say("Loading the current listings...", "searching")
    Search()
end

-- Drop / click with an item on the cursor
function Sell.FromCursor()
    local loc = C_Cursor and C_Cursor.GetCursorItem and C_Cursor.GetCursorItem()
    if not loc then return false end
    ClearCursor()
    if not C_AuctionHouse.IsSellItemValid(loc, true) then return true end
    Sell.Select({ loc = loc })
    return true
end

local function Loaded(list)
    table.sort(list, function(a, b) return a.unit < b.unit end)
    Sell.listings, Sell.noAnswer = list, nil
    Say("", "ready")
    if Sell.OnListings then pcall(Sell.OnListings) end
end

function ReadCommodity(itemID)
    local sel = Sell.sel
    if not sel or itemID ~= sel.id or Sell.state ~= "searching" then return end
    sel.commodity = true -- an answer as a commodity settles what kind of item it is
    local list = {}
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice > 0 then
            list[#list + 1] = { unit = r.unitPrice, qty = r.quantity, mine = (r.numOwnerItems or 0) > 0 or r.containsOwnerItem }
        end
    end
    Loaded(list)
end
AH.On("COMMODITY_SEARCH_RESULTS_UPDATED", ReadCommodity)
AH.On("COMMODITY_SEARCH_RESULTS_ADDED", ReadCommodity)

function ReadItem(itemKey)
    local sel = Sell.sel
    if not sel or not itemKey or itemKey.itemID ~= sel.id or Sell.state ~= "searching" then return end
    sel.commodity = false
    local list = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 and r.quantity and r.quantity > 0 then
            list[#list + 1] = { unit = r.buyoutAmount / r.quantity, qty = r.quantity, mine = r.containsOwnerItem }
        end
    end
    Loaded(list)
end
AH.On("ITEM_SEARCH_RESULTS_UPDATED", ReadItem)
AH.On("ITEM_SEARCH_RESULTS_ADDED", ReadItem)

-- Per-item memory: your own floor and the duration you last picked for it
function Sell.Rule(id, make)
    local rules = AH.db and AH.db.sellRules
    if not rules or not id then return nil end
    if make and not rules[id] then rules[id] = {} end
    return rules[id]
end
function Sell.Dur()
    local r = Sell.sel and Sell.Rule(Sell.sel.id)
    return (r and r.dur) or AH.settings.sellDuration or 2
end

-- The lowest price smart pricing will go to: your own floor for this item, else the higher of
-- (a % of the usual price) and (the price that still beats a vendor after the 5% cut). Returns price, kind.
function Sell.Floor(id, pk) -- pk: link / price key for suffixed gear (prices), id: rules + vendor
    local r = Sell.Rule(id)
    if r and r.floor and r.floor > 0 then return r.floor, "own" end
    local vend = SellPrice(id)
    local vendFloor = vend and vend > 0 and (math.ceil(vend / 0.95) + 1) or nil
    local pct = AH.settings.sellFloorPct or 70
    local usual = AH.GetMarketPrice(pk or id)
    local pctFloor = usual and pct > 0 and math.floor(usual * pct / 100) or nil
    if pctFloor and vendFloor then
        if vendFloor > pctFloor then return vendFloor, "vendor" end
        return pctFloor, "pct"
    end
    if pctFloor then return pctFloor, "pct" end
    if vendFloor then return vendFloor, "vendor" end
end

-- Price to suggest + a short reason why.
--   Smart: undercut the cheapest listing that isn't yours, but never below the floor (a crashed market is
--   held at the floor); match yours when yours is already the cheapest; nobody selling -> the usual price.
--   Not smart: plain undercut / match, nothing listed -> last price or usual price.
function Sell.Suggest()
    local sel = Sell.sel
    if not sel then return nil end
    local id = sel.id
    local pk = sel.link or id
    local list = Sell.listings
    local under = AH.settings.sellUndercut or 1
    local usual = AH.GetMarketPrice(pk)
    local smart = AH.settings.sellSmart
    local fl, kind
    if smart then fl, kind = Sell.Floor(id, pk) end
    local fname = kind == "own" and "your floor" or kind == "vendor" and "the vendor price"
        or ((AH.settings.sellFloorPct or 70) .. "% of usual")
    if list and list[1] then
        local first
        for _, e in ipairs(list) do if not e.mine then first = e; break end end
        if list[1].mine then return list[1].unit, "Yours is already the cheapest, so this matches it." end
        local target = math.max(1, first.unit - under)
        if fl and target < fl then
            return fl, ("The cheapest (%s) is below the floor (%s), so this holds at %s."):format(Short(first.unit), fname, Short(fl))
        end
        local why = ("Undercuts the cheapest (%s)."):format(Short(first.unit))
        if smart and usual and target > usual * 1.5 then why = why .. " Well above the usual " .. Short(usual) .. "." end
        return target, why
    end
    if list then
        local p = usual or AH.GetPrice(pk)
        if p then
            if fl and p < fl then p = fl end
            return p, usual and ("Nobody is selling. Usual price " .. Short(usual) .. ".") or "Nobody is selling. Last price seen."
        end
        if fl then return fl, "Nobody is selling and there is no price history, so this starts at the floor." end
        return nil, "No price known yet. You set it."
    end
    local p = AH.GetPrice(pk) or usual
    if Sell.noAnswer then return p, p and "Last price seen (the live listings did not load)." or nil end
    return p, p and "Last price seen (live listings still loading)." or nil
end

function Sell.Available()
    local sel = Sell.sel
    if not sel or not Valid(sel.loc) then return 0 end
    return C_AuctionHouse.GetAvailablePostCount(sel.loc) or 1
end

function Sell.Deposit(qty)
    local sel = Sell.sel
    if not sel or not Valid(sel.loc) or not qty or qty < 1 then return nil end
    local dur = Sell.Dur()
    if sel.commodity then return C_AuctionHouse.CalculateCommodityDeposit(sel.id, dur, qty) end
    return C_AuctionHouse.CalculateItemDeposit(sel.loc, dur, qty)
end

-- Post (the player's click)
function Sell.Post(qty, unit)
    local sel = Sell.sel
    if not sel or not Valid(sel.loc) then return end
    if Sell.state == "warning" and Sell.pending then
        local p = Sell.pending
        if p.commodity then C_AuctionHouse.ConfirmPostCommodity(p.loc, p.dur, p.qty, p.unit)
        else C_AuctionHouse.ConfirmPostItem(p.loc, p.dur, p.qty, nil, p.unit) end
        Sell.pending = nil
        Say("Posting...", "posting")
        return
    end
    if not qty or qty < 1 or not unit or unit < 1 then
        Say("Set a quantity and a price first.")
        return
    end
    local dur = Sell.Dur()
    local status = C_AuctionHouse.GetItemCommodityStatus(sel.loc)
    if status == Enum.ItemCommodityStatus.Commodity then sel.commodity = true
    elseif status == Enum.ItemCommodityStatus.Item then sel.commodity = false end
    local ok
    if sel.commodity then ok = C_AuctionHouse.PostCommodity(sel.loc, dur, qty, unit)
    else ok = C_AuctionHouse.PostItem(sel.loc, dur, qty, nil, unit) end
    if ok then
        Sell.pending = { commodity = sel.commodity, loc = sel.loc, dur = dur, qty = qty, unit = unit }
        Sell.lastPost = { id = sel.id, key = sel.link or sel.id, qty = qty, unit = unit }
        Say("Posting...", "posting")
    else
        Say("The game did not accept this post.", "ready")
    end
end

AH.On("AUCTION_HOUSE_POST_WARNING", function()
    if Sell.state == "posting" and Sell.pending then
        Say("The game asks you to confirm this post. Click Confirm post (its own pop-up can be closed).", "warning")
    end
end)
AH.On("AUCTION_HOUSE_POST_ERROR", function()
    if Sell.state == "posting" or Sell.state == "warning" then Sell.pending = nil; Say("The post failed.", "ready") end
end)
AH.On("AUCTION_HOUSE_AUCTION_CREATED", function()
    if Sell.state ~= "posting" then return end
    Sell.pending = nil
    local lp = Sell.lastPost
    if lp then AH.repost[lp.id] = nil end
    local text = lp and ("Posted %d %s at %s each."):format(lp.qty, P.Name(lp.id) or "", Short(lp.unit)) or "Posted."
    if lp then
        -- what we just posted is now the cheapest listing we know of
        local r = P.Get(lp.key or lp.id)
        if not r or not r.p or lp.unit < r.p then P.Record(AH.PriceKey(lp.key or lp.id), lp.unit, nil, nil, nil) end
    end
    Say(text, "idle")
    Sell.justPosted = true
    if Sell.OnPosted then C_Timer.After(0.4, function() pcall(Sell.OnPosted) end) end
end)
AH.On("AUCTION_HOUSE_CLOSED", function() Sell.sel, Sell.listings, Sell.pending, Sell.state, Sell.msg = nil, nil, nil, "idle", "" end)

--------------------------------------------------------------------------------
-- The Sell view
--------------------------------------------------------------------------------
function UI.BuildSell(parent)
    local T = S.T()
    local bandHit
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    ---------------------------------------------------------------- left card: the item and the post form
    local card = S.Panel(v, T.card, T.line)
    card:SetPoint("TOPLEFT", 10, -46)
    card:SetPoint("BOTTOMLEFT", 10, 8)
    card:SetWidth(232)

    local slot = CreateFrame("Button", nil, card)
    slot:SetSize(40, 40)
    slot:SetPoint("TOPLEFT", 12, -12)
    S.Tex(slot, "BACKGROUND", T.field):SetAllPoints()
    slot.edges = S.Border(slot, T.border)
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetPoint("TOPLEFT", 2, -2)
    slot.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    slot.hint = S.Text(slot, 9, T.dim, "CENTER")
    slot.hint:SetPoint("CENTER")
    slot.hint:SetText("drop\nitem")
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slot:SetScript("OnReceiveDrag", function() Sell.FromCursor() end)
    slot:SetScript("OnClick", function(_, btn)
        if Sell.FromCursor() then return end
        if btn == "RightButton" then Sell.queue = nil; Sell.Select(nil) end
    end)
    slot:SetScript("OnEnter", function(s)
        S.SetBorder(s.edges, T.glow)
        if Sell.sel and Sell.sel.link then
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(Sell.sel.link)
            GameTooltip:Show()
        end
    end)
    slot:SetScript("OnLeave", function(s) S.SetBorder(s.edges, T.border); GameTooltip:Hide() end)

    local name = S.Text(card, 12, T.text)
    name:SetPoint("TOPLEFT", slot, "TOPRIGHT", 8, -3)
    name:SetWidth(160)
    name:SetWordWrap(false)
    local have = S.Text(card, 10, T.dim)
    have:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
    have:SetWidth(160)

    -- quantity
    local qLabel = S.Text(card, 11, T.accent)
    qLabel:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -10)
    qLabel:SetText("Quantity")
    local qty = S.EditBox(card, 60, 22)
    qty:SetNumeric(true)
    qty:SetMaxLetters(5)
    qty:SetJustifyH("RIGHT")
    qty:SetPoint("TOPLEFT", qLabel, "BOTTOMLEFT", 0, -4)
    local maxB = S.Button(card, 44, 22, "Max")
    maxB:SetPoint("LEFT", qty, "RIGHT", 6, 0)
    local ofN = S.Text(card, 10, T.dim)
    ofN:SetPoint("LEFT", maxB, "RIGHT", 8, 0)

    -- price
    local pLabel = S.Text(card, 11, T.accent)
    pLabel:SetPoint("TOPLEFT", qty, "BOTTOMLEFT", 0, -10)
    pLabel:SetText("Price each")
    local price = S.MoneyInput(card)
    price:SetPoint("TOPLEFT", pLabel, "BOTTOMLEFT", 0, -4)
    local floorB = S.Button(card, 84, 16, "Set floor")
    floorB:SetPoint("BOTTOMRIGHT", price, "TOPRIGHT", 0, 3)
    local under = S.Button(card, 100, 20, "Undercut")
    under:SetPoint("TOPLEFT", price, "BOTTOMLEFT", 0, -6)
    local match = S.Button(card, 100, 20, "Match")
    match:SetPoint("LEFT", under, "RIGHT", 8, 0)

    -- duration
    local dLabel = S.Text(card, 11, T.accent)
    dLabel:SetPoint("TOPLEFT", under, "BOTTOMLEFT", 0, -10)
    dLabel:SetText("Duration")
    local durB = {}
    for i, d in ipairs(DURATIONS) do
        local b = S.Button(card, 64, 20, d[2])
        if i == 1 then b:SetPoint("TOPLEFT", dLabel, "BOTTOMLEFT", 0, -4) else b:SetPoint("LEFT", durB[i - 1], "RIGHT", 8, 0) end
        b.value = d[1]
        durB[i] = b
    end

    -- price guide: usual price + floor, then why this price was suggested
    local info = S.Text(card, 10, T.dim)
    info:SetPoint("TOPLEFT", durB[1], "BOTTOMLEFT", 0, -10)
    info:SetWidth(208)
    info:SetWordWrap(false)
    local why = S.Text(card, 9, T.dim)
    why:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -3)
    why:SetWidth(208)
    why:SetMaxLines(2)

    -- money summary: what the post sells for, what the AH takes, the deposit, what you get
    local sum = S.Panel(card, T.field, T.line)
    sum:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 82)
    sum:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 82)
    sum:SetHeight(80)
    local function Row(y, label, size, lcol)
        local l = S.Text(sum, size or 10, lcol or T.dim)
        l:SetPoint("TOPLEFT", 8, y)
        l:SetText(label)
        local r = S.Text(sum, size or 10, T.text, "RIGHT")
        r:SetPoint("TOPRIGHT", -8, y)
        return l, r
    end
    local _, sumGross = Row(-6, "Sells for")
    local _, sumCut = Row(-19, "AH cut (5%)")
    local depL, sumDep = Row(-32, "Deposit")
    local sep = S.Tex(sum, "ARTWORK", T.line)
    sep:SetPoint("TOPLEFT", 8, -46)
    sep:SetPoint("TOPRIGHT", -8, -46)
    sep:SetHeight(1)
    local _, sumNet = Row(-50, "You get", 12, T.accent)
    local warn = S.Text(sum, 9, T.green)
    warn:SetPoint("TOPLEFT", 8, -66)
    warn:SetPoint("TOPRIGHT", -8, -66)
    warn:SetWordWrap(false)
    -- hover the deposit line for how it works
    -- hover the bottom line when it suggests bandages
    bandHit = CreateFrame("Frame", nil, sum)
    bandHit:SetPoint("TOPLEFT", 4, -64)
    bandHit:SetPoint("TOPRIGHT", -4, -64)
    bandHit:SetHeight(14)
    bandHit:Hide()
    bandHit:SetScript("OnEnter", function(s)
        local bd = Sell.band
        if not bd then return end
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        if bd.kind == "bar" or bd.kind == "stone" then
            local bar = bd.kind == "bar"
            local mat = bar and "ore" or "stone"
            GameTooltip:SetText(bar and "Smelt into bars instead" or "Make " .. bd.name .. "s instead")
            GameTooltip:AddLine(("%d %s (%d %s each), %s at %s each."):format(bd.crafts, bd.name, bd.per, mat,
                bd.onAH and "sold on the AH" or "sold to a vendor", Short(bd.each)), 1, 1, 1, true)
            if bd.onAH then
                GameTooltip:AddLine(bd.rate and ("AH price after the 5% cut, times how often it sells (" .. Pct(bd.rate) .. ").")
                    or "AH price after the 5% cut.", 0.6, 0.6, 0.6, true)
            end
            if bd.matRate then GameTooltip:AddLine(("The %s sells %s of the time, counted the same way."):format(mat, Pct(bd.matRate)), 0.6, 0.6, 0.6, true) end
            GameTooltip:AddDoubleLine(bd.per > 1 and ((bar and "Bars" or "Stones") .. " + leftover " .. mat) or (bar and "Bars" or "Stones"),
                AH.Money(bd.value), 1, 0.82, 0, 1, 1, 1)
            GameTooltip:AddDoubleLine("More than selling the " .. mat, AH.Money(bd.gain), 1, 0.82, 0, 0.31, 0.84, 0.42)
            if bar then
                GameTooltip:AddLine(bd.spell == 14891 and "Dark Iron only smelts at the Black Forge in Blackrock Depths."
                    or "Smelting needs a forge.", 0.6, 0.6, 0.6, true)
            else
                GameTooltip:AddLine("Blacksmithing, with a Blacksmith Hammer in your bags.", 0.6, 0.6, 0.6, true)
            end
            if not bd.sure then GameTooltip:AddLine(("Open %s once so Cys's Auction House knows your recipes."):format(bar and "Mining" or "Blacksmithing"), 0.6, 0.6, 0.6, true) end
        else
            GameTooltip:SetText("Make bandages instead")
            GameTooltip:AddLine(("%d %s (%d cloth each), sold to a vendor at %s each."):format(bd.crafts, bd.name, bd.per, Short(bd.each)), 1, 1, 1, true)
            GameTooltip:AddDoubleLine("Bandages + leftover cloth", AH.Money(bd.value), 1, 0.82, 0, 1, 1, 1)
            GameTooltip:AddDoubleLine("More than selling the cloth", AH.Money(bd.gain), 1, 0.82, 0, 0.31, 0.84, 0.42)
            if not bd.sure then GameTooltip:AddLine("Open First Aid once so Cys's Auction House knows your recipes.", 0.6, 0.6, 0.6, true) end
        end
        GameTooltip:Show()
    end)
    bandHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local depHit = CreateFrame("Frame", nil, sum)
    depHit:SetPoint("TOPLEFT", 4, -30)
    depHit:SetPoint("TOPRIGHT", -4, -30)
    depHit:SetHeight(14)
    depHit:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:SetText("Deposit")
        GameTooltip:AddLine("Paid when you post. You get it back when the auction sells; the Auction House keeps it if the auction expires or you cancel it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    depHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local post = S.Button(card, 208, 28, "Post")
    post:SetPoint("BOTTOMLEFT", 12, 34)
    local skip = S.Button(card, 56, 28, "Skip")
    skip:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 34)
    skip:Hide()
    local qText = S.Text(card, 10, T.accent)
    qText:SetPoint("BOTTOMLEFT", post, "TOPLEFT", 0, 5)
    local msg = S.Text(card, 10, T.accent)
    msg:SetPoint("TOPLEFT", post, "BOTTOMLEFT", 0, -6)
    msg:SetWidth(208)
    msg:SetWordWrap(true)

    ---------------------------------------------------------------- right: current listings (top) + your bags (bottom)
    local right = S.Panel(v, T.card, T.line)
    right:SetPoint("TOPLEFT", card, "TOPRIGHT", 10, 0)
    right:SetPoint("BOTTOMRIGHT", -10, 8)

    local lTitle = S.Text(right, 11, T.accent)
    lTitle:SetPoint("TOPLEFT", 12, -10)
    lTitle:SetText("Current listings")
    local lNote = S.Text(right, 10, T.dim, "RIGHT")
    lNote:SetPoint("TOPRIGHT", -84, -11)
    lNote:SetText("Click a price to undercut it")

    local function Header(parentF, y, cols)
        for _, c in ipairs(cols) do
            local fs = S.Text(parentF, 10, T.accent, c[3])
            if c[2] > 0 then fs:SetPoint("TOPLEFT", c[2], y) else fs:SetPoint("TOPRIGHT", c[2], y) end
            fs:SetText(c[1])
        end
        local ln = S.Tex(parentF, "ARTWORK", T.line)
        ln:SetPoint("TOPLEFT", 8, y - 14)
        ln:SetPoint("TOPRIGHT", -8, y - 14)
        ln:SetHeight(1)
    end
    Header(right, -28, { { "Price each", 20, "LEFT" }, { "Available", -150, "RIGHT" }, { "", -20, "RIGHT" } })

    local lrows = {}
    for i = 1, LIST_ROWS do
        local r = CreateFrame("Button", nil, right)
        r:SetHeight(18)
        r:SetPoint("TOPLEFT", 8, -46 - (i - 1) * 18)
        r:SetPoint("TOPRIGHT", -8, -46 - (i - 1) * 18)
        r.hl = S.Tex(r, "BACKGROUND", T.cardHover); r.hl:SetAllPoints(); r.hl:Hide()
        r.price = S.Text(r, 11, T.text); r.price:SetPoint("LEFT", 12, 0)
        r.qty = S.Text(r, 11, T.text, "RIGHT"); r.qty:SetPoint("RIGHT", -142, 0)
        r.mine = S.Text(r, 10, T.green, "RIGHT"); r.mine:SetPoint("RIGHT", -12, 0)
        r:SetScript("OnEnter", function(s) s.hl:Show() end)
        r:SetScript("OnLeave", function(s) s.hl:Hide() end)
        lrows[i] = r
    end
    local lEmpty = S.Text(right, 11, T.dim)
    lEmpty:SetPoint("TOPLEFT", 20, -52)

    local bTop = -46 - LIST_ROWS * 18 - 14
    local sepB = S.Tex(right, "ARTWORK", T.line)
    sepB:SetPoint("TOPLEFT", 8, bTop + 6)
    sepB:SetPoint("TOPRIGHT", -8, bTop + 6)
    sepB:SetHeight(1)
    local bTitle = S.Text(right, 11, T.accent)
    bTitle:SetPoint("TOPLEFT", 12, bTop - 4)
    bTitle:SetText("Your bags")
    local bNote = S.Text(right, 10, T.dim, "RIGHT")
    bNote:SetPoint("TOPRIGHT", -84, bTop - 5)
    local postAll = S.Button(right, 64, 18, "Post all")
    postAll:SetPoint("TOPRIGHT", -12, bTop - 2)
    Header(right, bTop - 22, { { "Item", 34, "LEFT" }, { "AH each", -214, "RIGHT" }, { "Vendor each", -114, "RIGHT" }, { "Worth", -16, "RIGHT" } })

    local brows = {}
    for i = 1, BAG_ROWS do
        local r = CreateFrame("Button", nil, right)
        r:SetHeight(20)
        r:SetPoint("TOPLEFT", 8, bTop - 40 - (i - 1) * 20)
        r:SetPoint("TOPRIGHT", -8, bTop - 40 - (i - 1) * 20)
        r.hl = S.Tex(r, "BACKGROUND", T.cardHover); r.hl:SetAllPoints(); r.hl:Hide()
        r.selbar = S.Tex(r, "ARTWORK", T.glow)
        r.selbar:SetPoint("TOPLEFT"); r.selbar:SetPoint("BOTTOMLEFT"); r.selbar:SetWidth(2)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 6, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.name = S.Text(r, 11, T.text); r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetWidth(150); r.name:SetWordWrap(false)
        r.ah = S.Text(r, 11, T.text, "RIGHT"); r.ah:SetPoint("RIGHT", -206, 0)
        r.vendor = S.Text(r, 11, T.dim, "RIGHT"); r.vendor:SetPoint("RIGHT", -106, 0)
        r.worth = S.Text(r, 11, T.text, "RIGHT"); r.worth:SetPoint("RIGHT", -8, 0)
        r:SetScript("OnEnter", function(s)
            s.hl:Show()
            if s.entry and s.entry.link then
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(s.entry.link)
                GameTooltip:AddLine(AH.db.noSell[s.entry.id] and "Left out of Post all. Right-click to put it back."
                    or "Right-click: leave out of Post all.", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetScript("OnClick", function(s, btn)
            if not s.entry then return end
            if btn == "RightButton" then
                local id = s.entry.id
                AH.db.noSell[id] = (not AH.db.noSell[id]) or nil
                if UI.PaintSellBags then UI.PaintSellBags() end
                return
            end
            Sell.Select(s.entry)
        end)
        brows[i] = r
    end
    right:EnableMouseWheel(true)

    ---------------------------------------------------------------- painting
    local bags, bOff = {}, 0

    local function Total()
        return (tonumber(qty:GetText()) or 0), price:GetAmount()
    end

    -- cancelled auctions come back by mail, not to your bags: say so until they are picked up
    local function MailNote()
        local names = {}
        local Count = (C_Item and C_Item.GetItemCount) or GetItemCount
        for id in pairs(AH.repost) do
            if not Count or (Count(id) or 0) == 0 then names[#names + 1] = P.Name(id) or ("item " .. id) end
        end
        if #names == 0 then return "" end
        table.sort(names)
        return "|cff8a8a8aCancelled, waiting in your mail: " .. table.concat(names, ", ")
            .. ". They go first in Post all once you take them.|r"
    end

    local function PaintForm()
        local sel = Sell.sel
        local on = sel ~= nil
        local q = Sell.queue
        post:SetWidth(q and 146 or 208)
        skip:SetShown(q ~= nil)
        qText:SetText(q and ("Post all:  %d of %d"):format(math.min(q.i, #q.ids), #q.ids) or "")
        postAll:SetLabel(q and "Stop" or "Post all")
        for _, w in ipairs({ qty, maxB, price, under, match, floorB }) do w:SetShown(on) end
        qLabel:SetShown(on); pLabel:SetShown(on); ofN:SetShown(on)
        if not sel then
            slot.icon:SetTexture(nil)
            slot.hint:Show()
            name:SetText("Pick an item")
            name:SetTextColor(T.text[1], T.text[2], T.text[3])
            have:SetText("from your bags on the right,\nor drop one on the slot")
            info:SetText("")
            why:SetText("")
            sum:Hide()
            post:SetLabel("Post")
            post:SetActive(false)
            msg:SetText((Sell.msg and Sell.msg ~= "") and Sell.msg or MailNote())
            return
        end
        slot.hint:Hide()
        slot.icon:SetTexture(sel.icon or 134400)
        name:SetText(P.Name(sel.id) or (sel.link and sel.link:match("%[(.-)%]")) or "")
        local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(sel.id)
        local col = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        if col then name:SetTextColor(col.r, col.g, col.b) end
        local avail = Sell.Available()
        have:SetText(("You have %d%s"):format(avail, sel.commodity and "" or "  -  one auction each"))
        ofN:SetText("of " .. avail)
        local n, unit = Total()
        local dep = Sell.Deposit(n)
        local usual = AH.GetMarketPrice(sel.link or sel.id)
        local fl, kind
        if AH.settings.sellSmart then fl, kind = Sell.Floor(sel.id, sel.link) end
        local ref = {}
        if usual then ref[#ref + 1] = "Usual |cffffffff" .. Short(usual) .. "|r" end
        if fl then ref[#ref + 1] = (kind == "own" and "Your floor " or "Floor ") .. "|cffffffff" .. Short(fl) .. "|r" end
        local sr = Rate(sel.id)
        if sr then ref[#ref + 1] = "Sells |cffffffff" .. Pct(sr) .. "|r" end
        info:SetText(table.concat(ref, #ref > 2 and "  |cff555555|||r  " or "   |cff555555|||r   "))
        why:SetText(Sell.why or "")
        local rule = Sell.Rule(sel.id)
        floorB:SetLabel(rule and rule.floor and "Clear floor" or "Set floor")
        sum:Show()
        local gross = (n > 0 and unit > 0) and unit * n or 0
        local net = math.floor(gross * 0.95)
        sumGross:SetText(gross > 0 and AH.Money(gross) or "|cff8a8a8a-|r")
        sumCut:SetText(gross > 0 and ("|cffd97a7a-" .. Short(gross - net) .. "|r") or "|cff8a8a8a-|r")
        sumDep:SetText(dep and ("|cffd97a7a" .. Short(dep) .. "|r  |cff8a8a8aback if sold|r") or "|cff8a8a8a-|r")
        sumNet:SetText(gross > 0 and AH.Money(net) or "|cff8a8a8a-|r")
        local vend = SellPrice(sel.id)
        local mrate = Rate(sel.id)
        local band = n > 0 and Sell.BandageBest(sel.id, n, math.max(math.floor(net * (mrate or 1)), (vend or 0) * n)) or nil
        if band then band.matRate = mrate end
        Sell.band = band
        bandHit:SetShown(band ~= nil)
        if band then
            warn:SetText(("Better: %d %s  +%s%s"):format(band.crafts, band.name, Short(band.gain),
                band.sure and "" or " (if known)"))
            warn:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
        elseif gross > 0 and vend and vend > 0 then
            local diff = net - vend * n
            if diff > 0 then
                warn:SetText(("+%s more than a vendor pays"):format(Short(diff)))
                warn:SetTextColor(T.green[1], T.green[2], T.green[3])
            else
                warn:SetText(("A vendor pays more (%s each)"):format(Short(vend)))
                warn:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
            end
        elseif gross > 0 then
            warn:SetText("Vendors don't buy this")
            warn:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        else
            warn:SetText("Set a quantity and price")
            warn:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        end
        for _, b in ipairs(durB) do
            local on2 = b.value == Sell.Dur()
            S.SetBorder(b.edges, on2 and T.glow or T.line)
        end
        if Sell.state == "warning" then
            post:SetLabel("Confirm post"); post:SetActive(true)
        elseif Sell.state == "posting" then
            post:SetLabel("Posting..."); post:SetActive(false)
        else
            post:SetLabel(n > 0 and unit > 0 and ("Post " .. n .. " at " .. Short(unit)) or "Post")
            post:SetActive(n > 0 and unit > 0 and n <= avail)
        end
        msg:SetText(Sell.msg or "")
    end

    local function PaintListings()
        local list = Sell.listings
        for i = 1, LIST_ROWS do
            local r, e = lrows[i], list and list[i]
            r.entry = e
            if e then
                r.price:SetText(AH.Money(e.unit))
                r.qty:SetText(tostring(e.qty))
                r.mine:SetText(e.mine and "yours" or "")
                r:Show()
            else
                r:Hide()
            end
        end
        if not Sell.sel then lEmpty:SetText("")
        elseif Sell.state == "searching" then lEmpty:SetText("Loading...")
        elseif Sell.noAnswer then lEmpty:SetText("The listings did not load. Click the item to try again.")
        elseif list and #list == 0 then lEmpty:SetText("Nobody is selling this right now - you set the price.")
        else lEmpty:SetText("") end
    end

    local function PaintBags()
        local max = math.max(0, #bags - BAG_ROWS)
        if bOff > max then bOff = max end
        local sid = Sell.sel and Sell.sel.loc
        for i = 1, BAG_ROWS do
            local r, e = brows[i], bags[bOff + i]
            r.entry = e
            if e then
                r.icon:SetTexture(e.icon or 134400)
                local nm = P.Name(e.id) or (e.link and e.link:match("%[(.-)%]")) or ""
                if e.count > 1 then nm = nm .. " |cff8a8a8ax" .. e.count .. "|r" end
                if AH.db.noSell[e.id] then nm = nm .. " |cff8a8a8a(left out)|r" end
                r.name:SetText(nm)
                local col = e.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality]
                if col then r.name:SetTextColor(col.r, col.g, col.b) else r.name:SetTextColor(T.text[1], T.text[2], T.text[3]) end
                local ah = AH.GetPrice(e.link or e.id)
                local vend = SellPrice(e.id)
                r.ah:SetText(ah and Short(ah) or "|cff8a8a8a-|r")
                r.vendor:SetText(vend and vend > 0 and Short(vend) or "-")
                local best = math.max((ah or 0) * 0.95, vend or 0)
                r.worth:SetText(best > 0 and Short(best * e.count) or "")
                r.selbar:SetShown(sid ~= nil and Sell.sel.id == e.id)
                r:Show()
            else
                r:Hide()
            end
        end
        bNote:SetText(#bags > BAG_ROWS and ("%d-%d of %d  -  mouse wheel"):format(bOff + 1, math.min(bOff + BAG_ROWS, #bags), #bags)
            or (#bags .. " items you can sell"))
    end

    local function RefreshBags()
        if not v:IsVisible() then return end
        bags = Sell.BagItems()
        PaintBags()
    end

    function UI.PaintSell() PaintForm(); PaintListings() end
    UI.PaintSellBags = PaintBags
    Sell.OnChange = UI.PaintSell

    -- listings arrived: fill the price unless the player already typed one
    local function Resuggest()
        local s, why = Sell.Suggest()
        Sell.why = why
        if not Sell.priceSet and s then price:SetAmount(s) end
        UI.PaintSell()
    end
    Sell.OnListings = Resuggest

    local lastSelID
    local baseSelect = Sell.Select
    Sell.Select = function(entry)
        Sell.why = nil
        baseSelect(entry)
        if Sell.sel then
            if Sell.sel.id ~= lastSelID then
                qty:SetText(tostring(Sell.Available()))
                local s = AH.GetPrice(Sell.sel.link or Sell.sel.id)
                if s then price:SetAmount(s) else price:SetAmount(0) end
            end
            lastSelID = Sell.sel.id
        else
            lastSelID = nil
            qty:SetText("")
            price:SetAmount(0)
        end
        UI.PaintSell()
        PaintBags()
    end

    -- Post all: a list of every bag item worth listing (an AH price that beats the vendor, not left out);
    -- each Post click lists one, then the next item is picked and priced from its live listings
    function Sell.BuildQueue()
        local ids, first, later = {}, {}, {}
        for _, e in ipairs(Sell.BagItems()) do
            if not AH.db.noSell[e.id] then
                if AH.repost[e.id] then
                    first[#first + 1] = e.id -- cancelled undercut auctions go first
                else
                    local p = AH.GetPrice(e.link or e.id) or AH.GetMarketPrice(e.link or e.id)
                    local vend = SellPrice(e.id) or 0
                    local band = p and Sell.BandageBest(e.id, e.count, math.floor(p * 0.95 * (Rate(e.id) or 1)) * e.count)
                    if p and p * 0.95 > vend and not band then ids[#ids + 1] = e.id
                    elseif not p then later[#later + 1] = e.id end -- no price yet: last, priced from its live listings
                end
            end
        end
        for i = #first, 1, -1 do table.insert(ids, 1, first[i]) end
        for _, id in ipairs(later) do ids[#ids + 1] = id end
        return ids
    end
    local function QueueNext()
        local q = Sell.queue
        if not q then return end
        bags = Sell.BagItems()
        while q.i <= #q.ids do
            local id = q.ids[q.i]
            for _, e in ipairs(bags) do
                if e.id == id then lastSelID = nil; Sell.Select(e); PaintBags(); return end
            end
            q.i = q.i + 1
        end
        Sell.queue = nil
        Sell.Select(nil)
        Sell.msg = ("Post all done: %d posted."):format(q.posted)
        UI.PaintSell()
        PaintBags()
    end

    -- after posting: next item in the Post all list, or the next item in your bags (the same one if some are left)
    Sell.OnPosted = function()
        if Sell.queue then
            Sell.queue.i = Sell.queue.i + 1
            Sell.queue.posted = Sell.queue.posted + 1
            QueueNext()
            return
        end
        bags = Sell.BagItems()
        local nextE
        local prevID = Sell.lastPost and Sell.lastPost.id
        for _, e in ipairs(bags) do if e.id == prevID then nextE = e; break end end
        lastSelID = nil
        if nextE then Sell.Select(nextE) else Sell.Select(bags[1]) end
        PaintBags()
    end

    qty:SetScript("OnTextChanged", function() PaintForm() end)
    maxB:SetScript("OnClick", function() qty:SetText(tostring(Sell.Available())); PaintForm() end)
    price.OnChange = function() Sell.priceSet = true; PaintForm() end
    under:SetScript("OnClick", function()
        local list = Sell.listings
        local first
        if list then for _, e in ipairs(list) do if not e.mine then first = e; break end end end
        if first then price:SetAmount(math.max(1, first.unit - (AH.settings.sellUndercut or 1))); Sell.priceSet = true; PaintForm() end
    end)
    match:SetScript("OnClick", function()
        local list = Sell.listings
        if list and list[1] then price:SetAmount(list[1].unit); Sell.priceSet = true; PaintForm() end
    end)
    for _, b in ipairs(durB) do
        b:SetScript("OnClick", function()
            AH.settings.sellDuration = b.value
            local rr = Sell.sel and Sell.Rule(Sell.sel.id, true)
            if rr then rr.dur = b.value end
            PaintForm()
        end)
        b:SetScript("OnLeave", function(s) S.SetBorder(s.edges, s.value == Sell.Dur() and T.glow or T.line) end)
    end
    for _, r in ipairs(lrows) do
        r:SetScript("OnClick", function(s)
            if not s.entry then return end
            price:SetAmount(s.entry.mine and s.entry.unit or math.max(1, s.entry.unit - (AH.settings.sellUndercut or 1)))
            Sell.priceSet = true
            PaintForm()
        end)
    end
    post:SetScript("OnClick", function()
        price:ClearFocus(); qty:ClearFocus()
        local n, unit = Total()
        Sell.Post(n, unit)
    end)
    floorB:SetScript("OnClick", function()
        local sel = Sell.sel
        if not sel then return end
        local rr = Sell.Rule(sel.id, true)
        if rr.floor then
            rr.floor = nil
        else
            local _, unit = Total()
            if unit and unit > 0 then rr.floor = unit end
        end
        Resuggest()
    end)
    floorB:HookScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:SetText("Floor for this item")
        GameTooltip:AddLine("Set floor: the price in the box becomes the lowest this item is ever listed for. Smart prices hold here when others sell cheaper.", 1, 1, 1, true)
        GameTooltip:AddLine("Without one, the floor is a % of the usual price (Options), and never under what a vendor pays.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    floorB:HookScript("OnLeave", function() GameTooltip:Hide() end)

    skip:SetScript("OnClick", function()
        if not Sell.queue or Sell.state == "posting" then return end
        Sell.pending = nil
        Sell.queue.i = Sell.queue.i + 1
        QueueNext()
    end)
    postAll:SetScript("OnClick", function()
        if Sell.queue then
            Sell.queue = nil
            Sell.Select(nil)
            PaintBags()
            return
        end
        local ids = Sell.BuildQueue()
        if #ids == 0 then
            Sell.msg = "Nothing to post: no item in your bags has an AH price above what a vendor pays."
            UI.PaintSell()
            return
        end
        Sell.queue = { ids = ids, i = 1, posted = 0 }
        QueueNext()
    end)
    postAll:HookScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:SetText("Post all")
        GameTooltip:AddLine("Goes through every item in your bags with an AH price above what a vendor pays. Each item is priced from its live listings; you click Post (or Skip) for each one.", 1, 1, 1, true)
        GameTooltip:AddLine("Right-click an item in the list to leave it out.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    postAll:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Options: smart prices, undercut amount, floor %
    local optB = S.Button(right, 64, 18, "Options")
    optB:SetPoint("TOPRIGHT", -12, -8)
    local opt = S.Panel(right, T.card, T.glow)
    opt:SetPoint("TOPRIGHT", optB, "BOTTOMRIGHT", 0, -4)
    opt:SetSize(240, 150)
    opt:SetFrameLevel(right:GetFrameLevel() + 30)
    opt:EnableMouse(true)
    opt:Hide()
    local oTitle = S.Text(opt, 11, T.accent)
    oTitle:SetPoint("TOPLEFT", 12, -10)
    oTitle:SetText("Selling")
    local smart = S.Check(opt, "Smart prices (hold at the floor)", function() return AH.settings.sellSmart end,
        function(val) AH.settings.sellSmart = val; Resuggest() end)
    smart:SetPoint("TOPLEFT", 12, -30)
    local und = S.Stepper(opt, "Undercut by", { 1, 5, 10, 50, 100, 500, 1000, 5000, 10000 },
        function() return AH.settings.sellUndercut or 1 end, function(val) AH.settings.sellUndercut = val; Resuggest() end, Short)
    und:SetPoint("TOPLEFT", 12, -56)
    local fp = S.Stepper(opt, "Floor (% of usual)", { 0, 40, 50, 60, 70, 80, 90, 100 },
        function() return AH.settings.sellFloorPct or 70 end, function(val) AH.settings.sellFloorPct = val; Resuggest() end,
        function(val) return val == 0 and "off" or (val .. "%") end)
    fp:SetPoint("TOPLEFT", 12, -82)
    local oNote = S.Text(opt, 10, T.dim)
    oNote:SetPoint("TOPLEFT", 12, -108)
    oNote:SetWidth(216)
    oNote:SetText("The floor never goes under what a vendor pays. Set floor (above the price) gives one item its own floor.")
    optB:SetScript("OnClick", function() opt:SetShown(not opt:IsShown()) end)
    v:HookScript("OnHide", function() opt:Hide() end)

    right:SetScript("OnMouseWheel", function(_, d)
        bOff = math.max(0, bOff - d * 3)
        PaintBags()
    end)

    AH.On("BAG_UPDATE_DELAYED", function()
        if not v:IsVisible() then return end
        RefreshBags()
        if Sell.sel and not Valid(Sell.sel.loc) and Sell.state ~= "posting" then
            -- the stack moved or is gone: pick it again from the bags if it is still there
            local again
            for _, e in ipairs(bags) do if e.id == Sell.sel.id then again = e; break end end
            Sell.Select(again)
        else
            local n = tonumber(qty:GetText())
            if Sell.sel and n and n > Sell.Available() then qty:SetText(tostring(Sell.Available())) end
            PaintForm()
        end
    end)
    AH.RegisterCallback(function() if v:IsVisible() then PaintBags() end end)
    v:SetScript("OnShow", function() RefreshBags(); UI.PaintSell() end)
    return v
end
