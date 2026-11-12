--------------------------------------------------------------------------------
-- Cys's Auction House - My auctions
-- Everything you have listed, what it all brings in if it sells (after the AH's 5% cut), what has sold and
-- waits in your mail, and which listings someone has undercut. Refresh checks the current prices of each
-- item you have up. Cancel is your own click (two clicks: the first shows what cancelling costs).
--------------------------------------------------------------------------------
local AH = CysAH
local S = AH.Style
local P = AH.Prices
local UI = AH.UI
local M = {}
AH.Mine = M

local AH_CUT = 0.05
local ROWS = 18
local ROW_H = 20

M.list = {}       -- { auctionID, id, link, qty, unit, status, timeLeft, key }
M.cheapOther = {} -- [itemID] = cheapest price per item that isn't yours (from Refresh)
M.checked = {}    -- [itemID] = time()

local function Short(c) return AH.Sell and AH.Sell.Short and AH.Sell.Short(c) or AH.Money(c) end

local function Changed() if M.OnChange then pcall(M.OnChange) end end

function M.Query()
    if not C_AuctionHouse.QueryOwnedAuctions then return end
    C_AuctionHouse.QueryOwnedAuctions({})
end

AH.On("OWNED_AUCTIONS_UPDATED", function()
    local out = {}
    for _, a in ipairs(C_AuctionHouse.GetOwnedAuctions() or {}) do
        local unit = a.buyoutAmount or a.bidAmount or 0
        -- a sold auction reports the total it sold for, not the price each
        if a.status == 1 and (a.quantity or 1) > 1 then unit = unit / a.quantity end
        local id = a.itemKey and a.itemKey.itemID
        if id then
            if a.itemLink then
                local nm = a.itemLink:match("%[(.-)%]")
                if nm and nm ~= "" and (AH.db.names[id] or "") == "" then AH.db.names[id] = nm end
            end
            out[#out + 1] = { auctionID = a.auctionID, id = id, key = a.itemKey, link = a.itemLink, qty = a.quantity or 1,
                              unit = unit, status = a.status, timeLeft = a.timeLeftSeconds }
        end
    end
    -- active first (undercut ones on top), then sold
    table.sort(out, function(x, y)
        if (x.status == 1) ~= (y.status == 1) then return x.status ~= 1 end
        local ux, uy = M.Undercut(x) and 1 or 0, M.Undercut(y) and 1 or 0
        if ux ~= uy then return ux > uy end
        return (P.Name(x.id) or "") < (P.Name(y.id) or "")
    end)
    M.list = out
    Changed()
end)

-- cheaper listing from someone else than yours? (live check from Refresh first, else the saved lowest price)
function M.Undercut(a)
    if a.status == 1 then return nil end
    local other = M.cheapOther[a.id]
    if other == nil then
        local r = AH.realm.items[a.id]
        if r and r.p and r.t and time() - r.t < 3600 and r.p < a.unit then other = r.p end
    end
    if other and other < a.unit then return other end
    return nil
end

function M.Totals()
    local active, activeN, sold, under = 0, 0, 0, 0
    for _, a in ipairs(M.list) do
        local v = a.unit * a.qty
        if a.status == 1 then sold = sold + v
        else
            active = active + v
            activeN = activeN + 1
            if M.Undercut(a) then under = under + 1 end
        end
    end
    return active, activeN, sold, under
end

--------------------------------------------------------------------------------
-- Refresh: one sell search per item you have listed, one after another
--------------------------------------------------------------------------------
local queue, current = {}, nil
local function Next()
    current = table.remove(queue, 1)
    if not current then
        M.refreshing = false
        M.Query()
        Changed()
        return
    end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(0.3, function() table.insert(queue, 1, current); Next() end)
        return
    end
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    C_AuctionHouse.SendSellSearchQuery(current.key, sorts, true)
    local mine = current
    C_Timer.After(3, function() if current == mine then Next() end end) -- no answer: move on
end

function M.Refresh()
    if M.refreshing then return end
    wipe(queue)
    local seen = {}
    for _, a in ipairs(M.list) do
        if a.status ~= 1 and not seen[a.id] then
            seen[a.id] = true
            queue[#queue + 1] = { id = a.id, key = a.key }
        end
    end
    M.refreshing = #queue > 0
    Changed()
    Next()
end

local function Got(id, cheapest)
    if not current or current.id ~= id then return end
    M.cheapOther[id] = cheapest or false
    M.checked[id] = time()
    current = nil
    C_Timer.After(0.2, Next)
end

AH.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if not current or current.id ~= itemID then return end
    local best
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        -- a row can mix your items with others'; it only counts as someone else's when not all of it is yours
        if r and r.unitPrice and (r.quantity or 0) > (r.numOwnerItems or 0) then
            if not best or r.unitPrice < best then best = r.unitPrice end
        end
    end
    Got(itemID, best)
end)

AH.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    if not current or not itemKey or current.id ~= itemKey.itemID then return end
    local best
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and r.quantity and r.quantity > 0 and not r.containsOwnerItem then
            local unit = r.buyoutAmount / r.quantity
            if not best or unit < best then best = unit end
        end
    end
    Got(itemKey.itemID, best)
end)

--------------------------------------------------------------------------------
-- Cancel (two clicks)
--------------------------------------------------------------------------------
function M.Cancel(a)
    if not a or a.status == 1 then return end
    if C_AuctionHouse.CanCancelAuction and not C_AuctionHouse.CanCancelAuction(a.auctionID) then
        M.msg = "This auction can't be cancelled."
        Changed()
        return
    end
    if M.armed ~= a.auctionID then
        M.armed = a.auctionID
        local cost = C_AuctionHouse.GetCancelCost and C_AuctionHouse.GetCancelCost(a.auctionID) or 0
        M.msg = cost > 0 and ("Cancelling costs " .. AH.Money(cost) .. ". Click Cancel again to confirm.")
            or "Click Cancel again to confirm."
        Changed()
        C_Timer.After(5, function() if M.armed == a.auctionID then M.armed = nil; M.msg = nil; Changed() end end)
        return
    end
    M.armed = nil
    C_AuctionHouse.CancelAuction(a.auctionID)
    M.msg = "Cancelled - the item comes back by mail."
    Changed()
end

AH.On("AUCTION_CANCELED", function() C_Timer.After(0.3, M.Query) end)
AH.On("AUCTION_HOUSE_AUCTION_CREATED", function() C_Timer.After(0.5, M.Query) end)
AH.On("AUCTION_HOUSE_SHOW", function() C_Timer.After(1, M.Query) end)
AH.On("AUCTION_HOUSE_CLOSED", function() wipe(queue); current = nil; M.refreshing = false; M.armed = nil end)

--------------------------------------------------------------------------------
-- The view
--------------------------------------------------------------------------------
local function TimeText(sec)
    if not sec then return "" end
    if sec >= 3600 then return math.floor(sec / 3600) .. "h" end
    if sec >= 60 then return math.floor(sec / 60) .. "m" end
    return "<1m"
end

function UI.BuildMine(parent)
    local T = S.T()
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    ---------------------------------------------------------------- left: totals
    local card = S.Panel(v, T.card, T.line)
    card:SetPoint("TOPLEFT", 10, -46)
    card:SetPoint("BOTTOMLEFT", 10, 8)
    card:SetWidth(232)

    local h = S.Text(card, 12, T.accent)
    h:SetPoint("TOPLEFT", 12, -12)
    h:SetText("My auctions")

    local bigLabel = S.Text(card, 10, T.dim)
    bigLabel:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -12)
    bigLabel:SetText("If everything sells you get")
    local big = S.Text(card, 16, T.text)
    big:SetPoint("TOPLEFT", bigLabel, "BOTTOMLEFT", 0, -4)

    local lines = S.Text(card, 11, T.text)
    lines:SetPoint("TOPLEFT", big, "BOTTOMLEFT", 0, -12)
    lines:SetWidth(208)
    lines:SetSpacing(4)

    local refresh = S.Button(card, 208, 24, "Check prices now")
    refresh:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -14)
    refresh:SetScript("OnClick", function() M.Refresh() end)

    local sep = S.Tex(card, "ARTWORK", T.line)
    sep:SetPoint("TOPLEFT", refresh, "BOTTOMLEFT", 0, -14)
    sep:SetSize(208, 1)

    local selName = S.Text(card, 12, T.text)
    selName:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -12)
    selName:SetWidth(208)
    selName:SetWordWrap(false)
    local selInfo = S.Text(card, 11, T.text)
    selInfo:SetPoint("TOPLEFT", selName, "BOTTOMLEFT", 0, -6)
    selInfo:SetWidth(208)
    selInfo:SetSpacing(3)
    local cancel = S.Button(card, 208, 24, "Cancel")
    cancel:SetPoint("TOPLEFT", selInfo, "BOTTOMLEFT", 0, -10)
    local msg = S.Text(card, 10, T.accent)
    msg:SetPoint("TOPLEFT", cancel, "BOTTOMLEFT", 0, -6)
    msg:SetWidth(208)

    local note = S.Text(card, 10, T.dim)
    note:SetPoint("BOTTOMLEFT", 12, 12)
    note:SetWidth(208)
    note:SetText("Undercut = someone else lists it cheaper. Check prices now looks up each item you have up.")

    ---------------------------------------------------------------- right: the list
    local list = S.Panel(v, T.card, T.line)
    list:SetPoint("TOPLEFT", card, "TOPRIGHT", 10, 0)
    list:SetPoint("BOTTOMRIGHT", -10, 8)
    list:EnableMouseWheel(true)

    local headY = -12
    local COLS = { { "Item", 34, "LEFT" }, { "Each", -230, "RIGHT" }, { "Cheapest other", -130, "RIGHT" }, { "Left", -64, "RIGHT" }, { "", -10, "RIGHT" } }
    for _, c in ipairs(COLS) do
        local fs = S.Text(list, 10, T.accent, c[3])
        if c[2] > 0 then fs:SetPoint("TOPLEFT", c[2], headY) else fs:SetPoint("TOPRIGHT", c[2], headY) end
        fs:SetText(c[1])
    end
    local ln = S.Tex(list, "ARTWORK", T.line)
    ln:SetPoint("TOPLEFT", 8, headY - 14)
    ln:SetPoint("TOPRIGHT", -8, headY - 14)
    ln:SetHeight(1)

    local rows, offset, sel = {}, 0, nil
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 8, headY - 18 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", -8, headY - 18 - (i - 1) * ROW_H)
        r.hl = S.Tex(r, "BACKGROUND", T.cardHover); r.hl:SetAllPoints(); r.hl:Hide()
        r.selbar = S.Tex(r, "ARTWORK", T.glow)
        r.selbar:SetPoint("TOPLEFT"); r.selbar:SetPoint("BOTTOMLEFT"); r.selbar:SetWidth(2)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 6, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.name = S.Text(r, 11, T.text); r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetWidth(150); r.name:SetWordWrap(false)
        r.each = S.Text(r, 11, T.text, "RIGHT"); r.each:SetPoint("RIGHT", -222, 0)
        r.other = S.Text(r, 11, T.text, "RIGHT"); r.other:SetPoint("RIGHT", -122, 0)
        r.left = S.Text(r, 11, T.dim, "RIGHT"); r.left:SetPoint("RIGHT", -56, 0)
        r.state = S.Text(r, 10, T.green, "RIGHT"); r.state:SetPoint("RIGHT", -2, 0)
        r:SetScript("OnEnter", function(s)
            s.hl:Show()
            if s.a and s.a.link then
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(s.a.link)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
        r:SetScript("OnClick", function(s) sel = s.a; M.armed = nil; M.msg = nil; UI.PaintMine() end)
        rows[i] = r
    end
    local foot = S.Text(list, 10, T.dim)
    foot:SetPoint("BOTTOMLEFT", 12, 10)

    function UI.PaintMine()
        if not v:IsVisible() then return end
        local active, activeN, sold, under = M.Totals()
        big:SetText(AH.Money(math.floor(active * (1 - AH_CUT))))
        local t = {}
        t[#t + 1] = ("Listed  |cffffffff%d auction%s|r"):format(activeN, activeN == 1 and "" or "s")
        t[#t + 1] = "Before the 5% cut  |cffffffff" .. AH.Money(active) .. "|r"
        if sold > 0 then t[#t + 1] = "|cff4fd66bSold, waiting in your mail  " .. AH.Money(math.floor(sold * (1 - AH_CUT))) .. "|r" end
        if under > 0 then t[#t + 1] = ("|cffff6060Undercut  %d|r"):format(under) end
        lines:SetText(table.concat(t, "\n"))
        refresh:SetLabel(M.refreshing and "Checking prices..." or "Check prices now")
        refresh:SetActive(not M.refreshing and activeN > 0)

        -- keep the selection on the same auction after a refresh
        if sel then
            local still
            for _, a in ipairs(M.list) do if a.auctionID == sel.auctionID then still = a; break end end
            sel = still
        end
        local show = sel ~= nil
        selName:SetShown(show); selInfo:SetShown(show); cancel:SetShown(show and sel.status ~= 1)
        if sel then
            selName:SetText(P.Name(sel.id) or (sel.link and sel.link:match("%[(.-)%]")) or "")
            local u = M.Undercut(sel)
            local info = { ("%d at %s each"):format(sel.qty, AH.Money(sel.unit)) }
            if sel.status == 1 then info[#info + 1] = "|cff4fd66bSold - collect it from your mail.|r"
            elseif u then info[#info + 1] = "|cffff6060Undercut: someone lists it at " .. AH.Money(u) .. "|r"
            else info[#info + 1] = "|cff4fd66bYours is the cheapest we know of.|r" end
            selInfo:SetText(table.concat(info, "\n"))
            cancel:SetLabel(M.armed == sel.auctionID and "Click again to cancel" or "Cancel")
            cancel:SetScript("OnClick", function() M.Cancel(sel) end)
        end
        msg:SetText(M.msg or (show and "" or "Click an auction to see it or cancel it."))

        local max = math.max(0, #M.list - ROWS)
        if offset > max then offset = max end
        for i = 1, ROWS do
            local r, a = rows[i], M.list[offset + i]
            r.a = a
            if a then
                r.icon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(a.id)) or 134400)
                local nm = P.Name(a.id) or (a.link and a.link:match("%[(.-)%]")) or ("item " .. a.id)
                if a.qty > 1 then nm = nm .. " |cff8a8a8ax" .. a.qty .. "|r" end
                r.name:SetText(nm)
                local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(a.id)
                local col = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
                if col then r.name:SetTextColor(col.r, col.g, col.b) else r.name:SetTextColor(T.text[1], T.text[2], T.text[3]) end
                r.each:SetText(Short(a.unit))
                local u = M.Undercut(a)
                local other = M.cheapOther[a.id]
                r.other:SetText(other and Short(other) or "|cff8a8a8a-|r")
                if a.status == 1 then
                    r.left:SetText("")
                    r.state:SetText("|cff4fd66bSold|r")
                elseif u then
                    r.left:SetText(TimeText(a.timeLeft))
                    r.state:SetText("|cffff6060Undercut|r")
                else
                    r.left:SetText(TimeText(a.timeLeft))
                    r.state:SetText(M.checked[a.id] and "|cff4fd66bCheapest|r" or "")
                end
                r.selbar:SetShown(sel ~= nil and sel.auctionID == a.auctionID)
                r:Show()
            else
                r:Hide()
            end
        end
        if #M.list == 0 then
            foot:SetText("You have nothing listed.")
        else
            foot:SetText(#M.list > ROWS and ("%d-%d of %d  -  mouse wheel"):format(offset + 1, math.min(offset + ROWS, #M.list), #M.list) or "")
        end
    end
    M.OnChange = UI.PaintMine

    list:SetScript("OnMouseWheel", function(_, d)
        offset = math.max(0, offset - d * 3)
        UI.PaintMine()
    end)
    v:SetScript("OnShow", function() M.Query(); UI.PaintMine() end)
    AH.RegisterCallback(function() if v:IsVisible() then UI.PaintMine() end end)
    return v
end
