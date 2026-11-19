--------------------------------------------------------------------------------
-- Cys's Auction House - scanning
-- Full scan: the game's "replicate" list of every auction (one every 15 minutes, the game's limit).
-- Searches: every browse / item / commodity search you make in the AH also updates prices.
--------------------------------------------------------------------------------
local AH = CysAH
local P = AH.Prices
local Scan = {}
AH.Scan = Scan

local COOLDOWN = 15 * 60   -- the game allows one full scan per 15 minutes
local BATCH = 1000         -- auctions read per frame
local TIMEOUT = 90         -- seconds to wait for the server's answer
local DEPTH = 5

Scan.state = "idle"        -- idle / waiting / reading
Scan.progress = 0
Scan.isOpen = false

local function Changed()
    if Scan.OnChange then pcall(Scan.OnChange) end
end

-- Seconds until the next full scan is allowed (0 = now)
function Scan.Cooldown()
    local last = AH.realm and AH.realm.lastFullStart
    if not last then return 0 end
    return math.max(0, COOLDOWN - (time() - last))
end

function Scan.Start(manual)
    if Scan.state ~= "idle" then
        if manual then AH.Print("A full scan is already running.") end
        return
    end
    if not Scan.isOpen then
        if manual then AH.Print("Open the Auction House first.") end
        return
    end
    local wait = Scan.Cooldown()
    if wait > 0 then
        if manual then AH.Print(("The next full scan is allowed in %d:%02d."):format(wait / 60, wait % 60)) end
        return
    end
    AH.realm.lastFullStart = time()
    Scan.state, Scan.progress = "waiting", 0
    Scan.token = (Scan.token or 0) + 1
    local token = Scan.token
    AH.events:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    C_AuctionHouse.ReplicateItems()
    Changed()
    C_Timer.After(TIMEOUT, function()
        if Scan.token == token and Scan.state == "waiting" then
            Scan.Stop("The server did not answer the full scan. Try again in 15 minutes.")
        end
    end)
end

function Scan.Stop(msg)
    Scan.token = (Scan.token or 0) + 1
    Scan.state, Scan.progress = "idle", 0
    AH.events:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    if msg then AH.Print(msg) end
    Changed()
end

-- Read the replicate list in batches so the game doesn't freeze
local function Read(token)
    local total = C_AuctionHouse.GetNumReplicateItems() or 0
    if total == 0 then
        Scan.Stop("The full scan came back empty.")
        return
    end
    Scan.state = "reading"
    local agg, names = {}, AH.db.names
    local suffixed = {} -- itemIDs seen with a random suffix: priced per suffix only
    local i = 0
    local function Step()
        if Scan.token ~= token then return end -- stopped (AH closed)
        local last = math.min(i + BATCH, total)
        while i < last do
            local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
            if itemID and buyout and buyout > 0 and count and count > 0 then
                local unit = buyout / count
                local link = C_AuctionHouse.GetReplicateItemLink and C_AuctionHouse.GetReplicateItemLink(i)
                local key = link and AH.PriceKey(link) or itemID
                if key ~= itemID then suffixed[itemID] = true end
                local a = agg[key]
                if not a then a = { q = 0, n = 0, u = {} }; agg[key] = a end
                a.q = a.q + count
                a.n = a.n + 1
                a.u[#a.u + 1] = { unit, count }
                if name and name ~= "" and not names[itemID] then names[itemID] = name end
            end
            i = i + 1
        end
        Scan.progress = i / total
        Changed()
        if i < total then
            C_Timer.After(0, Step)
            return
        end
        local now, n = time(), 0
        local byUnit = function(x, y) return x[1] < y[1] end
        for itemID, a in pairs(agg) do
            table.sort(a.u, byUnit)
            local units, counts = {}, {}
            for k = 1, math.min(DEPTH, #a.u) do units[k], counts[k] = a.u[k][1], a.u[k][2] end
            P.Record(itemID, units[1], a.q, a.n, units, now, counts)
            n = n + 1
        end
        -- a record under the bare itemID of suffixed gear mixed every suffix together: drop it
        for itemID in pairs(suffixed) do if not agg[itemID] then AH.realm.items[itemID] = nil end end
        AH.realm.lastFull = now
        AH.realm.lastFullCount = n
        Scan.Stop()
        AH.Print(("Full scan done: %d items priced."):format(n))
        AH.FirePricesChanged()
    end
    Step()
end

AH.On("REPLICATE_ITEM_LIST_UPDATE", function()
    if Scan.state ~= "waiting" then return end
    -- the event can come more than once; read after it settles
    local token = Scan.token
    Scan.settle = (Scan.settle or 0) + 1
    local mine = Scan.settle
    C_Timer.After(1, function()
        if Scan.settle == mine and Scan.token == token and Scan.state == "waiting" then Read(token) end
    end)
end)

AH.On("AUCTION_HOUSE_SHOW", function()
    Scan.isOpen = true
    Changed()
    if AH.settings.autoScan and Scan.Cooldown() == 0 then
        C_Timer.After(3, function()
            if Scan.isOpen and Scan.state == "idle" and Scan.Cooldown() == 0 then Scan.Start(false) end
        end)
    end
end)

AH.On("AUCTION_HOUSE_CLOSED", function()
    Scan.isOpen = false
    if Scan.state ~= "idle" then
        Scan.Stop("Full scan stopped: the Auction House was closed.")
    end
    Changed()
end)

--------------------------------------------------------------------------------
-- Prices from your own searches
--------------------------------------------------------------------------------
local function FromBrowse(results)
    if type(results) ~= "table" then return end
    local now, any = time(), false
    for _, r in ipairs(results) do
        local id = r.itemKey and AH.PriceKey(r.itemKey)
        if id and r.minPrice and r.minPrice > 0 and (r.itemKey.battlePetSpeciesID or 0) == 0 then
            local old = P.Get(r.itemKey)
            -- keep the deeper listing info from a full scan when the lowest price did not change
            if old and old.p == r.minPrice and old.l then
                old.t = now
            else
                P.Record(id, r.minPrice, r.totalQuantity, nil, nil, now)
            end
            any = true
        end
    end
    if any then AH.FirePricesChanged() end
end

AH.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    FromBrowse(C_AuctionHouse.GetBrowseResults())
end)
AH.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added)
    FromBrowse(added)
end)

AH.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if not itemID then return end
    local num = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
    if num == 0 then return end
    local list, counts, listings = {}, {}, 0
    for i = 1, num do -- the game sends these cheapest first
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice > 0 then
            listings = listings + 1
            if #list < DEPTH then list[#list + 1] = r.unitPrice; counts[#counts + 1] = r.quantity end
        end
    end
    if #list == 0 then return end
    P.Record(itemID, list[1], C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID), listings, list, nil, counts)
    AH.FirePricesChanged()
end)

AH.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    if not itemKey or not itemKey.itemID or (itemKey.battlePetSpeciesID or 0) ~= 0 then return end
    local num = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    local rows, qty = {}, 0
    for i = 1, num do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 and r.quantity and r.quantity > 0 then
            rows[#rows + 1] = { r.buyoutAmount / r.quantity, r.quantity }
            qty = qty + r.quantity
        end
    end
    if #rows == 0 then return end
    table.sort(rows, function(x, y) return x[1] < y[1] end)
    local units, counts = {}, {}
    for k = 1, math.min(DEPTH, #rows) do units[k], counts[k] = rows[k][1], rows[k][2] end
    P.Record(AH.PriceKey(itemKey), units[1], qty, #rows, units, nil, counts)
    AH.FirePricesChanged()
end)
