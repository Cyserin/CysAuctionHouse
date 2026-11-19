--------------------------------------------------------------------------------
-- Cys's Auction House - sell history
-- How often does an item actually sell? Two sources, blended:
--   Yours:  AH mails you collect (Auction successful / expired / cancelled), per realm + faction:
--           AH.realm.hist[itemID] = { s = items sold, e = items expired, c = items cancelled,
--                                     ms = sale mails, me = expired mails, t = last seen }
--   Market: listed quantity dropping between price checks 10 min - 6 h apart (Prices.lua keeps
--           r.mv = { s = items gone, w = items listed x hours, h = hours watched }). Noisy: cancels and
--           expiries look like sales, new listings hide them.
-- CysAH.GetSellRate(item) -> chance (0-1) a fairly priced auction sells, how many of your own auctions it
-- is based on, and whether market data was used. nil while there is not enough history.
--------------------------------------------------------------------------------
local AH = CysAH
local H = {}
AH.History = H

local OWN_MIN = 3     -- own auctions needed before your history alone counts
local MARKET_W = 3    -- the market estimate weighs as much as this many of your own auctions
local MARKET_MIN_H = 12 -- hours of market watching needed
local CAP = 40        -- past this many own auctions, older history is halved (recent counts more)

local function Hist()
    if not AH.realm then return nil end
    AH.realm.hist = AH.realm.hist or {}
    return AH.realm.hist
end

--------------------------------------------------------------------------------
-- Market estimate (called from P.Record with the previous and the new quantity)
--------------------------------------------------------------------------------
function H.Watch(r, qty, now)
    if not r or not qty then return end
    local bq, bt = r.bq, r.bt
    if not bq or not bt or now - bt > 6 * 3600 or now < bt then
        r.bq, r.bt = qty, now -- new baseline
        return
    end
    local hours = (now - bt) / 3600
    if hours < 1 / 6 then return end -- too close to the last one; keep the baseline
    local mv = r.mv or { s = 0, w = 0, h = 0 }
    mv.s = mv.s + math.max(0, bq - qty)
    mv.w = mv.w + (bq + qty) / 2 * hours
    mv.h = mv.h + hours
    if mv.h > 24 * 14 then mv.s, mv.w, mv.h = mv.s / 2, mv.w / 2, mv.h / 2 end
    r.mv = mv
    r.bq, r.bt = qty, now
end

local function MarketRate(id)
    local r = AH.realm and AH.realm.items and AH.realm.items[id]
    local mv = r and r.mv
    if not mv or mv.h < MARKET_MIN_H or mv.w <= 0 then return nil end
    -- share of what is listed that goes in a day; a 24 h auction gets about that chance
    return math.min(0.95, mv.s / mv.w * 24)
end

--------------------------------------------------------------------------------
-- The blended rate
--------------------------------------------------------------------------------
function AH.GetSellRate(item)
    local id = AH.ItemID(item)
    if not id then return nil end
    local own = Hist() and Hist()[id]
    local n = own and ((own.ms or 0) + (own.me or 0)) or 0
    local ownRate = own and (own.s + own.e) > 0 and own.s / (own.s + own.e) or nil
    local m = MarketRate(id)
    if m and ownRate and n > 0 then
        return (ownRate * n + m * MARKET_W) / (n + MARKET_W), n, true
    elseif ownRate and n >= OWN_MIN then
        return ownRate, n, false
    elseif m then
        return m, n, true
    end
    return nil, n, false
end

function H.Add(id, kind, qty)
    local hist = Hist()
    if not hist or not id then return end
    qty = qty or 1
    local h = hist[id]
    if not h then h = { s = 0, e = 0, c = 0, ms = 0, me = 0 }; hist[id] = h end
    if kind == "sold" then h.s, h.ms = h.s + qty, h.ms + 1
    elseif kind == "expired" then h.e, h.me = h.e + qty, h.me + 1
    elseif kind == "cancelled" then h.c = h.c + qty end
    h.t = time()
    if h.ms + h.me > CAP then
        for _, k in ipairs({ "s", "e", "c", "ms", "me" }) do h[k] = math.floor(h[k] / 2) end
    end
end

--------------------------------------------------------------------------------
-- AH mails: remember what is in the inbox; a mail that leaves it (you took the money / item) counts once
--------------------------------------------------------------------------------
local function Pattern(fmt, fallback)
    fmt = type(fmt) == "string" and fmt or fallback
    fmt = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
    return "^" .. fmt
end
local SOLD = Pattern(_G.AUCTION_SOLD_MAIL_SUBJECT, "Auction successful: %s")
local EXPIRED = Pattern(_G.AUCTION_EXPIRED_MAIL_SUBJECT, "Auction expired: %s")
local CANCELLED = Pattern(_G.AUCTION_REMOVED_MAIL_SUBJECT, "Auction cancelled: %s")

local byName
local function IDFromName(name)
    if not name then return nil end
    name = name:gsub("%s*%(%d+%)$", "")
    if not byName then
        byName = {}
        for id, n in pairs(AH.db and AH.db.names or {}) do byName[n] = id end
    end
    local id = byName[name]
    if not id and C_Item and C_Item.GetItemInfoInstant then id = C_Item.GetItemInfoInstant(name) end
    if not id and GetItemInfoInstant then id = GetItemInfoInstant(name) end
    return type(id) == "number" and id or nil
end

local function Read(i)
    local _, _, _, subject, money, _, _, _, _, _, _, _, _, firstQty, firstLink = GetInboxHeaderInfo(i)
    if type(subject) ~= "string" then return nil end
    local kind, name
    name = subject:match(SOLD)
    if name then kind = "sold" else
        name = subject:match(EXPIRED)
        if name then kind = "expired" else
            name = subject:match(CANCELLED)
            if name then kind = "cancelled" end
        end
    end
    if not kind then return nil end
    local id, qty
    if kind == "sold" then
        local ok, invoiceType, itemName, _, _, _, _, _, _, _, _, count = pcall(GetInboxInvoiceInfo, i)
        if ok and invoiceType and invoiceType ~= "seller" then return nil end -- pending sale, no money yet
        id = IDFromName(ok and itemName or name)
        qty = ok and tonumber(count) or tonumber(subject:match("%((%d+)%)%s*$")) or 1
    else
        id = firstLink and AH.ItemID(firstLink) or IDFromName(name)
        qty = tonumber(firstQty) or tonumber(subject:match("%((%d+)%)%s*$")) or 1
    end
    if not id then return nil end
    return (subject .. "|" .. tostring(money) .. "|" .. tostring(firstQty)), kind, id, qty
end

local seen -- [signature] = { n, kind, id, qty }
local function Snapshot()
    local now = {}
    local count = GetInboxNumItems and GetInboxNumItems() or 0
    for i = 1, count do
        local sig, kind, id, qty = Read(i)
        if sig then
            local e = now[sig]
            if e then e.n = e.n + 1 else now[sig] = { n = 1, kind = kind, id = id, qty = qty } end
        end
    end
    return now
end

AH.On("MAIL_SHOW", function() seen = nil end)
AH.On("MAIL_INBOX_UPDATE", function()
    local now = Snapshot()
    if seen then
        local gone = {}
        for sig, e in pairs(seen) do
            local left = now[sig] and now[sig].n or 0
            for _ = 1, e.n - left do gone[#gone + 1] = e end
        end
        -- one or two mails per update is you taking them; more at once is the inbox reloading: don't count
        if #gone <= 3 then
            for _, e in ipairs(gone) do H.Add(e.id, e.kind, e.qty) end
        end
    end
    seen = now
end)
AH.On("MAIL_CLOSED", function() seen = nil end)
