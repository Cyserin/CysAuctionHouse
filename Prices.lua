--------------------------------------------------------------------------------
-- Cys's Auction House - price store
-- Per realm + faction, per itemID:
--   p = lowest buyout per item (copper), q = items listed, n = listings, t = when seen (time()),
--   l = the lowest few listings' price per item (cheapest first), c = items in each of those listings,
--   d = { [day] = lowest price that day }
-- The market price is the middle of the daily lows (needs 2+ days), so one odd listing doesn't move it.
--------------------------------------------------------------------------------
local AH = CysAH
local P = {}
AH.Prices = P

local DEPTH = 5 -- prices kept per item
local floor = math.floor

local function Today() return floor(time() / 86400) end

local function Items() return AH.realm and AH.realm.items end

-- Drop daily lows older than the history setting
function P.Prune()
    local items = Items()
    if not items then return end
    local oldest = Today() - (AH.settings.historyDays or 14)
    for _, r in pairs(items) do
        if r.d then
            for day in pairs(r.d) do
                if day < oldest then r.d[day] = nil end
            end
        end
    end
end

-- Save what was seen for one item.
--   unit  = lowest price per item, qty = items listed (or nil), count = listings (or nil),
--   list  = sorted lowest prices per item (or nil), counts = items in each of those listings (or nil)
function P.Record(itemID, unit, qty, count, list, now, counts)
    local items = Items()
    if not items or not itemID or not unit or unit <= 0 then return end
    now = now or time()
    local r = items[itemID]
    if not r then r = {}; items[itemID] = r end
    r.p, r.t = floor(unit), now
    r.q, r.n = qty, count
    if list and #list > 0 then
        local l = {}
        for i = 1, math.min(DEPTH, #list) do l[i] = floor(list[i]) end
        r.l = l
        if counts then
            local c = {}
            for i = 1, #l do c[i] = counts[i] or 1 end
            r.c = c
        else
            r.c = nil
        end
    else
        r.l, r.c = nil, nil
    end
    r.d = r.d or {}
    local day = floor(now / 86400)
    if not r.d[day] or unit < r.d[day] then r.d[day] = floor(unit) end
end

function P.Get(item)
    local items = Items()
    local id = AH.ItemID(item)
    return items and id and items[id], id
end

function AH.GetPrice(item)
    local r = P.Get(item)
    return r and r.p or nil
end

function AH.GetPriceAge(item)
    local r = P.Get(item)
    return r and r.t and (time() - r.t) or nil
end

-- Middle of the daily lows (2+ days needed)
function AH.GetMarketPrice(item)
    local r = P.Get(item)
    if not r or not r.d then return nil end
    local v = {}
    for _, price in pairs(r.d) do v[#v + 1] = price end
    if #v < 2 then return nil end
    table.sort(v)
    local mid = (#v + 1) / 2
    if mid == floor(mid) then return v[mid] end
    return floor((v[floor(mid)] + v[floor(mid) + 1]) / 2)
end

-- Listings seen: count of listings, items listed, lowest prices list
function AH.GetListings(item)
    local r = P.Get(item)
    if not r then return nil end
    return r.n, r.q, r.l
end

function P.Count()
    local n = 0
    for _ in pairs(Items() or {}) do n = n + 1 end
    return n
end

-- Item name for the search list (saved names first, then the game's item cache)
function P.Name(itemID)
    local n = AH.db and AH.db.names[itemID]
    if n and n ~= "" then return n end
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if not name and GetItemInfo then name = GetItemInfo(itemID) end
    if name and AH.db then AH.db.names[itemID] = name end
    if not name then P.Request(itemID) end
    return name
end

-- Ask the game for item data we don't have yet; when it arrives the lists repaint (once per burst)
local pending, asked, waiting = {}, {}, false
function P.Request(itemID)
    if asked[itemID] then return end -- once per session per item
    asked[itemID] = true
    pending[itemID] = true
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
end
AH.On("ITEM_DATA_LOAD_RESULT", function(itemID, ok)
    if not pending[itemID] then return end
    pending[itemID] = nil
    if ok then P.Name(itemID) end
    if waiting then return end
    waiting = true
    C_Timer.After(0.5, function()
        waiting = false
        if P.OnNames then pcall(P.OnNames) end
    end)
end)
