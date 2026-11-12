--------------------------------------------------------------------------------
-- Cys's Auction House - core
-- Saved data, events, slash command and the public API other addons use:
--   CysAH.GetPrice(item)        -> lowest buyout per item in copper, or nil (item = itemID or item link)
--   CysAH.GetPriceAge(item)     -> seconds since that price was seen, or nil
--   CysAH.GetMarketPrice(item)  -> usual price (middle of the daily lows of the last days), or nil
--   CysAH.RegisterCallback(fn)  -> fn() runs after prices change (full scan done, a search seen)
-- By Cyserin (Cys).
--------------------------------------------------------------------------------
local ADDON = ...
local AH = {}
CysAH = AH

AH.version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"

local DEFAULTS = {
    tooltip = true,       -- price lines on item tooltips
    autoScan = true,      -- start a full scan by itself when the AH opens and the game allows one
    historyDays = 14,     -- days of daily lows kept for the market price
}

local events = CreateFrame("Frame")
AH.events = events
local handlers = {}

-- AH.On("EVENT", fn): several files can listen to the same event
function AH.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        events:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

events:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end)

function AH.Print(msg)
    print("|cffd9a421Cys's AH|r " .. tostring(msg))
end

-- Prices are kept per realm and faction (each faction has its own Auction House)
local function RealmKey()
    return (GetRealmName() or "?") .. "-" .. (UnitFactionGroup("player") or "?")
end

AH.On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    CysAHDB = CysAHDB or {}
    local db = CysAHDB
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.realms = db.realms or {}
    db.names = db.names or {} -- [itemID] = name, so the price list can be searched by name
    for id, n in pairs(db.names) do if n == "" then db.names[id] = nil end end -- 0.1.0-0.1.2 saved some empty names
    local key = RealmKey()
    db.realms[key] = db.realms[key] or { items = {} }
    AH.db = db
    AH.settings = db.settings
    AH.realm = db.realms[key]
    if AH.Prices and AH.Prices.Prune then AH.Prices.Prune() end
end)

-- Hand our prices to Cys's UI's Crate Tracker (it marks the cheapest item of each crate)
AH.On("PLAYER_LOGIN", function()
    C_Timer.After(2, function()
        local crates = CysUI and CysUI.Crates
        if crates and crates.Price == nil then
            crates.Price = AH.GetPrice
            if crates.Refresh then pcall(crates.Refresh) end
        end
    end)
end)

-- Callbacks for other addons / our own panels
local callbacks = {}
function AH.RegisterCallback(fn) table.insert(callbacks, fn) end
local pending = false
function AH.FirePricesChanged()
    if pending then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = false
        for i = 1, #callbacks do pcall(callbacks[i]) end
        local crates = CysUI and CysUI.Crates
        if crates and crates.Price == AH.GetPrice and crates.Refresh then pcall(crates.Refresh) end
    end)
end

-- Money text: 1g 20s 5c with coin icons
function AH.Money(copper)
    if not copper then return "-" end
    copper = math.floor(copper + 0.5)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(copper)
    end
    return GetCoinTextureString(copper)
end

-- "5m", "2h", "3d"
function AH.Age(seconds)
    if not seconds then return "" end
    if seconds < 60 then return "now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
    return math.floor(seconds / 86400) .. "d"
end

-- itemID from an itemID, item link or item string
function AH.ItemID(item)
    if type(item) == "number" then return item end
    if type(item) == "string" then
        local id = item:match("item:(%d+)")
        return id and tonumber(id) or tonumber(item)
    end
end

SLASH_CYSAH1 = "/cysah"
SlashCmdList.CYSAH = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "scan" then
        AH.Scan.Start(true)
    elseif msg == "stats" then
        local n = 0
        for _ in pairs(AH.realm.items) do n = n + 1 end
        AH.Print(("%d items priced on this realm. Last full scan: %s."):format(n,
            AH.realm.lastFull and (AH.Age(time() - AH.realm.lastFull) .. " ago") or "never"))
    elseif msg == "tooltip" then
        AH.settings.tooltip = not AH.settings.tooltip
        AH.Print("Tooltip prices " .. (AH.settings.tooltip and "on." or "off."))
    else
        AH.Print("v" .. AH.version .. " - open the Auction House and pick the Cys's AH tab.")
        AH.Print("/cysah scan - full scan (the AH must be open)")
        AH.Print("/cysah stats - how many prices are saved")
        AH.Print("/cysah tooltip - price lines on tooltips on / off")
    end
end
