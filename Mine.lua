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
    if a.status == 1 or a.status == -1 then return nil end
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
        elseif a.status == -1 then -- cancelled, waiting for the AH's new list
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
    -- like the game's own windows: the sell search only for gear, the normal search for everything else
    local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(current.key)
    if info and info.isEquipment then
        C_AuctionHouse.SendSellSearchQuery(current.key, sorts, true)
    else
        C_AuctionHouse.SendSearchQuery(current.key, sorts, true)
    end
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
    AH.repost[a.id] = true
    M.msg = "Cancelled. It comes back by mail - collect it, then Post all (Sell) lists it first."
    Changed()
end

-- Cancel undercut: one click per auction, always the next undercut one (the button names it)
function M.NextUndercut()
    local n, first = 0, nil
    for _, a in ipairs(M.list) do
        if M.Undercut(a) and (not C_AuctionHouse.CanCancelAuction or C_AuctionHouse.CanCancelAuction(a.auctionID)) then
            n = n + 1
            first = first or a
        end
    end
    return first, n
end

function M.CancelUndercut()
    local a = M.NextUndercut()
    if not a then return end
    M.armed = nil
    C_AuctionHouse.CancelAuction(a.auctionID)
    AH.repost[a.id] = true
    a.status = -1 -- hidden from the undercut list until the AH sends the new list
    M.msg = ("Cancelled %s. It comes back by mail - collect it, then Post all (Sell) lists it first."):format(P.Name(a.id) or "it")
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

    ---------------------------------------------------------------- left: totals + the picked auction
    local card = S.Panel(v, T.card, T.line)
    card:SetPoint("TOPLEFT", 10, -46)
    card:SetPoint("BOTTOMLEFT", 10, 8)
    card:SetWidth(232)

    local h = S.Text(card, 12, T.accent)
    h:SetPoint("TOPLEFT", 12, -12)
    h:SetText("My auctions")

    -- a small box of label / value rows (the Sell view's summary look)
    local function Box(anchor, y, height)
        local box = S.Panel(card, T.field, T.line)
        box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
        box:SetSize(208, height)
        function box:Row(ry, label, size, lcol)
            local l = S.Text(self, size or 10, lcol or T.dim)
            l:SetPoint("TOPLEFT", 8, ry)
            l:SetText(label)
            local r = S.Text(self, size or 10, T.text, "RIGHT")
            r:SetPoint("TOPRIGHT", -8, ry)
            r:SetPoint("LEFT", l, "RIGHT", 6, 0)
            r:SetWordWrap(false)
            return r, l
        end
        function box:Line(ry)
            local s = S.Tex(self, "ARTWORK", T.line)
            s:SetPoint("TOPLEFT", 8, ry); s:SetPoint("TOPRIGHT", -8, ry); s:SetHeight(1)
        end
        return box
    end

    local tot = Box(h, -8, 68)
    local totListed = tot:Row(-6, "Listed")
    local totWorth = tot:Row(-19, "Worth")
    local totCut = tot:Row(-32, "AH cut (5%)")
    tot:Line(-46)
    local totNet = tot:Row(-50, "You get if all sells", 12, T.accent)

    local mail = S.Text(card, 10, T.green)
    mail:SetPoint("TOPLEFT", tot, "BOTTOMLEFT", 2, -6)
    mail:SetWidth(204)
    mail:SetWordWrap(false)
    local underT = S.Text(card, 10, T.danger)
    underT:SetPoint("TOPLEFT", mail, "BOTTOMLEFT", 0, -3)
    underT:SetWidth(204)
    underT:SetWordWrap(false)

    local refresh = S.Button(card, 208, 24, "Check prices now")
    refresh:SetPoint("TOPLEFT", tot, "BOTTOMLEFT", 0, -38)
    refresh:SetScript("OnClick", function() M.Refresh() end)
    refresh:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:SetText("Check prices now")
        GameTooltip:AddLine("Looks up the current listings of every item you have up, to find the ones someone has undercut.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local cancelAll = S.Button(card, 208, 24, "Cancel undercut")
    cancelAll:SetPoint("TOPLEFT", refresh, "BOTTOMLEFT", 0, -6)
    cancelAll.label:SetWidth(196)
    cancelAll.label:SetWordWrap(false)
    cancelAll:SetScript("OnClick", function() M.CancelUndercut() end)
    cancelAll:SetScript("OnEnter", function(s)
        local a = M.NextUndercut()
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:SetText("Cancel undercut")
        GameTooltip:AddLine("Each click cancels the next undercut auction (the button names it). Cancelled items come back by mail; collect them and Post all in Sell lists them first, at a fresh price.", 1, 1, 1, true)
        if a then
            local cost = C_AuctionHouse.GetCancelCost and C_AuctionHouse.GetCancelCost(a.auctionID) or 0
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Next", P.Name(a.id) or "", 1, 0.82, 0, 1, 1, 1)
            GameTooltip:AddDoubleLine("Cancelling costs", cost > 0 and AH.Money(cost) or "nothing", 1, 0.82, 0, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    cancelAll:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local sep = S.Tex(card, "ARTWORK", T.line)
    sep:SetPoint("TOPLEFT", cancelAll, "BOTTOMLEFT", 0, -12)
    sep:SetSize(208, 1)

    -- the picked auction
    local selIcon = card:CreateTexture(nil, "ARTWORK")
    selIcon:SetSize(28, 28)
    selIcon:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -10)
    selIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local selName = S.Text(card, 12, T.text)
    selName:SetPoint("LEFT", selIcon, "RIGHT", 8, 0)
    selName:SetWidth(172)
    selName:SetWordWrap(false)
    local det = Box(selIcon, -8, 58)
    local detEach = det:Row(-6, "Price each")
    local detQty = det:Row(-19, "Quantity")
    local detOther = det:Row(-32, "Cheapest other")
    local detLeft = det:Row(-45, "Time left")
    local selState = S.Text(card, 10, T.green)
    selState:SetPoint("TOPLEFT", det, "BOTTOMLEFT", 2, -6)
    selState:SetWidth(204)
    local cancel = S.Button(card, 208, 24, "Cancel")
    cancel:SetPoint("TOPLEFT", det, "BOTTOMLEFT", 0, -24)
    local msg = S.Text(card, 10, T.accent)
    msg:SetPoint("TOPLEFT", cancel, "BOTTOMLEFT", 0, -6)
    msg:SetWidth(208)

    local note = S.Text(card, 9, T.dim)
    note:SetPoint("BOTTOMLEFT", 12, 10)
    note:SetWidth(208)
    note:SetText("Undercut = someone else lists it cheaper.")

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
        local dash = "|cff8a8a8a-|r"
        totListed:SetText(("%d auction%s"):format(activeN, activeN == 1 and "" or "s"))
        totWorth:SetText(active > 0 and AH.Money(active) or dash)
        local net = math.floor(active * (1 - AH_CUT))
        totCut:SetText(active > 0 and ("|cffd97a7a-" .. Short(active - net) .. "|r") or dash)
        totNet:SetText(active > 0 and AH.Money(net) or dash)
        mail:SetText(sold > 0 and ("Sold, waiting in your mail:  " .. AH.Money(math.floor(sold * (1 - AH_CUT)))) or "")
        underT:SetText(under > 0 and ("%d undercut auction%s"):format(under, under == 1 and "" or "s") or "")
        if sold == 0 and under == 0 then
            mail:SetText(activeN > 0 and "|cff8a8a8aNothing sold yet.|r" or "")
        end
        refresh:SetLabel(M.refreshing and "Checking prices..." or "Check prices now")
        refresh:SetActive(not M.refreshing and activeN > 0)
        local nextU, nU = M.NextUndercut()
        if nextU then
            cancelAll:SetLabel(("Cancel undercut (%d): %s"):format(nU, P.Name(nextU.id) or "next"))
        else
            cancelAll:SetLabel("Cancel undercut")
        end
        cancelAll:SetActive(nextU ~= nil)

        -- keep the selection on the same auction after a refresh
        if sel then
            local still
            for _, a in ipairs(M.list) do if a.auctionID == sel.auctionID then still = a; break end end
            sel = still
        end
        local show = sel ~= nil
        selIcon:SetShown(show); selName:SetShown(show); det:SetShown(show); selState:SetShown(show)
        cancel:SetShown(show and sel.status ~= 1 and sel.status ~= -1)
        if sel then
            selIcon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(sel.id)) or 134400)
            selName:SetText(P.Name(sel.id) or (sel.link and sel.link:match("%[(.-)%]")) or "")
            local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(sel.id)
            local col = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
            if col then selName:SetTextColor(col.r, col.g, col.b) else selName:SetTextColor(T.text[1], T.text[2], T.text[3]) end
            detEach:SetText(AH.Money(sel.unit))
            detQty:SetText(tostring(sel.qty))
            local other = M.cheapOther[sel.id]
            detOther:SetText(other and AH.Money(other) or dash)
            detLeft:SetText(sel.status == 1 and dash or (TimeText(sel.timeLeft) ~= "" and TimeText(sel.timeLeft) or dash))
            local u = M.Undercut(sel)
            if sel.status == 1 then
                selState:SetText("Sold - collect it from your mail."); selState:SetTextColor(T.green[1], T.green[2], T.green[3])
            elseif sel.status == -1 then
                selState:SetText("Cancelled - it comes back by mail."); selState:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
            elseif u then
                selState:SetText("Undercut: someone lists it at " .. Short(u) .. "."); selState:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
            elseif M.checked[sel.id] then
                selState:SetText("Yours is the cheapest."); selState:SetTextColor(T.green[1], T.green[2], T.green[3])
            else
                selState:SetText("Not checked yet - Check prices now."); selState:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
            end
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
                elseif a.status == -1 then
                    r.left:SetText("")
                    r.state:SetText("|cff8a8a8aCancelled|r")
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
