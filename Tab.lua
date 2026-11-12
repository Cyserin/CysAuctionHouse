--------------------------------------------------------------------------------
-- Cys's Auction House - the "Cys's AH" tab inside the game's Auction House window
-- Our tab button sits after the game's own tabs; clicking it lays our panel over the AH's content area.
-- Clicking any of the game's tabs (Buy / Sell / Auctions) hides our panel again.
-- Safety: only our own frames are created and changed. The game's frames, tables and scripts are never
-- written to; we only post-hook SetDisplayMode and the window's OnHide.
--------------------------------------------------------------------------------
local AH = CysAH
local S = AH.Style
local P = AH.Prices
local Scan = AH.Scan
local UI = {}
AH.UI = UI

local ROWS = 16
local ROW_H = 20

local function Quality(itemID)
    local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID)
    if not q and GetItemInfo then q = select(3, GetItemInfo(itemID)) end
    return q
end

local function Icon(itemID)
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
    return GetItemIcon and GetItemIcon(itemID)
end

local function Clock(sec)
    return ("%d:%02d"):format(sec / 60, sec % 60)
end

--------------------------------------------------------------------------------
-- List data: items in your bags (empty search) or saved prices matching the search
--------------------------------------------------------------------------------
local function BagItems()
    local counts, order = {}, {}
    local last = (Enum.BagIndex and Enum.BagIndex.ReagentBag) or NUM_BAG_SLOTS or 4
    for bag = 0, last do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local name = info.hyperlink and info.hyperlink:match("%[(.-)%]")
                if name and name ~= "" and AH.db and not AH.db.names[info.itemID] then AH.db.names[info.itemID] = name end
                if not counts[info.itemID] then order[#order + 1] = info.itemID end
                counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        if AH.GetPrice(id) then out[#out + 1] = { id = id, have = counts[id] } end
    end
    -- most valuable stacks first
    table.sort(out, function(a, b) return AH.GetPrice(a.id) * a.have > AH.GetPrice(b.id) * b.have end)
    return out
end

local function SearchItems(text)
    text = text:lower()
    local out = {}
    for id in pairs(AH.realm.items) do
        local name = P.Name(id)
        if name and name:lower():find(text, 1, true) then
            out[#out + 1] = { id = id, name = name }
            if #out >= 500 then break end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------
function UI.Build()
    if UI.panel or not AuctionHouseFrame then return end
    local T = S.T()
    local AHF = AuctionHouseFrame

    -- the tab button
    local tab = CreateFrame("Button", "CysAHTab", AHF)
    tab:SetSize(104, 28)
    if AHF.AuctionsTab then
        tab:SetPoint("TOPLEFT", AHF.AuctionsTab, "TOPRIGHT", 4, -3)
    else
        tab:SetPoint("TOPLEFT", AHF, "BOTTOMLEFT", 320, 2)
    end
    tab.bg = S.Tex(tab, "BACKGROUND", T.bg)
    tab.bg:SetAllPoints()
    tab.edges = S.Border(tab, T.border)
    tab.line = S.Tex(tab, "ARTWORK", T.glow)
    tab.line:SetPoint("BOTTOMLEFT", 1, 1)
    tab.line:SetPoint("BOTTOMRIGHT", -1, 1)
    tab.line:SetHeight(2)
    tab.line:Hide()
    tab.label = S.Text(tab, 12, T.accent, "CENTER")
    tab.label:SetPoint("CENTER", 0, 1)
    tab.label:SetText("Cys's AH")
    tab:SetScript("OnEnter", function(s) S.SetBorder(s.edges, T.glow) end)
    tab:SetScript("OnLeave", function(s) S.SetBorder(s.edges, T.border) end)
    UI.tab = tab

    -- the panel over the AH's content area (the gold display at the bottom stays visible)
    local f = CreateFrame("Frame", "CysAHPanel", AHF)
    f:SetPoint("TOPLEFT", AHF, "TOPLEFT", 4, -24)
    f:SetPoint("BOTTOMRIGHT", AHF, "BOTTOMRIGHT", -4, 30)
    -- the game gives some Sell-tab parts fixed layers up to 1500 (item slot, Post button, Buyout Mode, overlays),
    -- so our panel sits well above them; set again on every show because the AH window rises when clicked
    local function Lift() f:SetFrameLevel(math.min(AHF:GetFrameLevel() + 2000, 9000)) end
    Lift()
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function() end)
    f:Hide()
    f.bg = S.Tex(f, "BACKGROUND", T.bg)
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(T.bg[1], T.bg[2], T.bg[3], 1) -- fully solid: the AH's own search bar must not show through
    S.Border(f, T.border)
    UI.panel = f

    local title = S.Text(f, 14, T.accent)
    title:SetPoint("TOPLEFT", 62, -12)
    title:SetText("Cys's Auction House")
    local ver = S.Text(f, 10, T.dim)
    ver:SetPoint("LEFT", title, "RIGHT", 8, -1)
    ver:SetText("v" .. AH.version .. "  -  Prices")

    ---------------------------------------------------------------- scan card
    local card = S.Panel(f, T.card, T.line)
    card:SetPoint("TOPLEFT", 12, -38)
    card:SetPoint("BOTTOMLEFT", 12, 12)
    card:SetWidth(232)

    local h = S.Text(card, 12, T.accent)
    h:SetPoint("TOPLEFT", 12, -12)
    h:SetText("Full scan")

    local last = S.Text(card, 11, T.text)
    last:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -10)
    last:SetWidth(208)
    local next_ = S.Text(card, 11, T.text)
    next_:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -6)
    next_:SetWidth(208)

    local bar = CreateFrame("StatusBar", nil, card)
    bar:SetPoint("TOPLEFT", next_, "BOTTOMLEFT", 0, -10)
    bar:SetSize(208, 8)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(T.brand[1], T.brand[2], T.brand[3])
    bar:SetMinMaxValues(0, 1)
    S.Tex(bar, "BACKGROUND", T.field):SetAllPoints()
    bar:Hide()

    local btn = S.Button(card, 208, 24, "Scan now")
    btn:SetPoint("TOPLEFT", next_, "BOTTOMLEFT", 0, -26)
    btn:SetScript("OnClick", function() Scan.Start(true) end)

    local c1 = S.Check(card, "Scan when the AH opens",
        function() return AH.settings.autoScan end, function(v) AH.settings.autoScan = v end)
    c1:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -16)
    local c2 = S.Check(card, "Prices on item tooltips",
        function() return AH.settings.tooltip end, function(v) AH.settings.tooltip = v end)
    c2:SetPoint("TOPLEFT", c1, "BOTTOMLEFT", 0, -8)

    local note = S.Text(card, 10, T.dim)
    note:SetPoint("TOPLEFT", c2, "BOTTOMLEFT", 0, -16)
    note:SetWidth(208)
    note:SetText("The game allows one full scan every 15 minutes. Every search you make in the Auction House updates prices too.\n\n\"Usual\" is the middle of the daily lows over the last two weeks.")

    local function PaintScan()
        if not f:IsShown() then return end
        local realm = AH.realm
        if realm.lastFull then
            last:SetText(("Last scan: |cffffffff%s ago|r  -  %s items"):format(AH.Age(time() - realm.lastFull),
                BreakUpLargeNumbers and BreakUpLargeNumbers(realm.lastFullCount or 0) or (realm.lastFullCount or 0)))
        else
            last:SetText("Last scan: |cffffffffnever|r")
        end
        if Scan.state == "waiting" then
            next_:SetText("Waiting for the server...")
            bar:Show(); bar:SetValue(0.05)
            btn:SetActive(false)
        elseif Scan.state == "reading" then
            next_:SetText(("Reading auctions... %d%%"):format(Scan.progress * 100))
            bar:Show(); bar:SetValue(Scan.progress)
            btn:SetActive(false)
        else
            bar:Hide()
            local wait = Scan.Cooldown()
            if wait > 0 then
                next_:SetText("Next scan allowed in |cffffffff" .. Clock(wait) .. "|r")
                btn:SetActive(false)
            else
                next_:SetText("|cff4fd66bA full scan is allowed now.|r")
                btn:SetActive(true)
            end
        end
    end
    UI.PaintScan = PaintScan
    Scan.OnChange = PaintScan

    -- the countdown ticks once a second while the panel shows
    local tick = 0
    f:SetScript("OnUpdate", function(_, el)
        tick = tick + el
        if tick >= 1 then tick = 0; PaintScan() end
    end)

    ---------------------------------------------------------------- price list
    local list = S.Panel(f, T.card, T.line)
    list:SetPoint("TOPLEFT", card, "TOPRIGHT", 10, 0)
    list:SetPoint("BOTTOMRIGHT", -12, 12)
    list:EnableMouseWheel(true)

    local box = S.EditBox(list, 240, 22)
    box:SetPoint("TOPLEFT", 10, -10)
    box.hint:SetText("Search saved prices")
    local mode = S.Text(list, 11, T.accent)
    mode:SetPoint("LEFT", box, "RIGHT", 12, 0)

    -- column headers
    local COLS = { { "Item", 34, "LEFT" }, { "Price each", -250, "RIGHT" }, { "Usual", -150, "RIGHT" }, { "Listed", -60, "RIGHT" }, { "Seen", -10, "RIGHT" } }
    local headY = -42
    for _, c in ipairs(COLS) do
        local fs = S.Text(list, 10, T.accent, c[3])
        if c[2] > 0 then fs:SetPoint("TOPLEFT", c[2], headY) else fs:SetPoint("TOPRIGHT", c[2], headY) end
        fs:SetText(c[1])
    end
    local sep = S.Tex(list, "ARTWORK", T.line)
    sep:SetPoint("TOPLEFT", 8, headY - 14)
    sep:SetPoint("TOPRIGHT", -8, headY - 14)
    sep:SetHeight(1)

    local rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 8, headY - 18 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", -8, headY - 18 - (i - 1) * ROW_H)
        r.hl = S.Tex(r, "BACKGROUND", T.cardHover)
        r.hl:SetAllPoints()
        r.hl:Hide()
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("LEFT", 4, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.name = S.Text(r, 11, T.text)
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetWidth(150)
        r.name:SetWordWrap(false)
        r.price = S.Text(r, 11, T.text, "RIGHT"); r.price:SetPoint("RIGHT", -242, 0)
        r.usual = S.Text(r, 11, T.text, "RIGHT"); r.usual:SetPoint("RIGHT", -142, 0)
        r.listed = S.Text(r, 11, T.text, "RIGHT"); r.listed:SetPoint("RIGHT", -52, 0)
        r.seen = S.Text(r, 11, T.dim, "RIGHT"); r.seen:SetPoint("RIGHT", -2, 0)
        r:SetScript("OnEnter", function(s)
            s.hl:Show()
            if s.itemID then
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(s.itemID)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
        rows[i] = r
    end

    local foot = S.Text(list, 10, T.dim)
    foot:SetPoint("BOTTOMLEFT", 12, 10)

    local data, offset = {}, 0

    local function PaintRows()
        local max = math.max(0, #data - ROWS)
        if offset > max then offset = max end
        local now = time()
        for i = 1, ROWS do
            local r, e = rows[i], data[offset + i]
            if e then
                local rec = AH.realm.items[e.id]
                r.itemID = e.id
                r.icon:SetTexture(Icon(e.id) or 134400)
                local name = e.name or P.Name(e.id) or ("item " .. e.id)
                if e.have and e.have > 1 then name = name .. " |cff8a8a8ax" .. e.have .. "|r" end
                r.name:SetText(name)
                local q = Quality(e.id)
                local col = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
                if col then r.name:SetTextColor(col.r, col.g, col.b) else r.name:SetTextColor(T.text[1], T.text[2], T.text[3]) end
                r.price:SetText(rec and AH.Money(rec.p) or "-")
                local m = AH.GetMarketPrice(e.id)
                r.usual:SetText(m and AH.Money(m) or "|cff8a8a8a-|r")
                r.listed:SetText(rec and rec.q and tostring(rec.q) or "|cff8a8a8a-|r")
                r.seen:SetText(rec and rec.t and AH.Age(now - rec.t) or "")
                r:Show()
            else
                r.itemID = nil
                r:Hide()
            end
        end
        if #data == 0 then
            foot:SetText(box:GetText() == "" and "No priced items in your bags yet - run a full scan or search the AH." or "No saved prices match.")
        else
            foot:SetText(("%d-%d of %d  -  mouse wheel to scroll"):format(offset + 1, math.min(offset + ROWS, #data), #data))
        end
    end

    local function Refresh()
        if not f:IsShown() then return end
        local text = box:GetText() or ""
        box.hint:SetShown(text == "" and not box:HasFocus())
        if text == "" then
            data = BagItems()
            mode:SetText("Items in your bags")
        else
            data = SearchItems(text)
            mode:SetText("Saved prices")
        end
        PaintRows()
    end
    UI.Refresh = Refresh

    box:SetScript("OnTextChanged", function() offset = 0; Refresh() end)
    box:HookScript("OnEditFocusGained", function(s) s.hint:Hide() end)
    box:HookScript("OnEditFocusLost", function(s) s.hint:SetShown(s:GetText() == "") end)
    list:SetScript("OnMouseWheel", function(_, d)
        offset = math.max(0, offset - d * 3)
        PaintRows()
    end)

    AH.RegisterCallback(Refresh)
    P.OnNames = Refresh -- item names that arrive late fill in
    AH.On("BAG_UPDATE_DELAYED", Refresh)

    f:SetScript("OnShow", function()
        Lift()
        tab.line:Show()
        tab.bg:SetColorTexture(T.selected[1], T.selected[2], T.selected[3], 1)
        PaintScan()
        Refresh()
    end)
    f:SetScript("OnHide", function()
        tab.line:Hide()
        tab.bg:SetColorTexture(T.bg[1], T.bg[2], T.bg[3], T.bg[4] or 1)
        box:ClearFocus()
    end)

    tab:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841)
        f:Show()
    end)

    -- the game's own tabs (and anything else that changes what the AH shows) hide our panel
    hooksecurefunc(AHF, "SetDisplayMode", function() f:Hide() end)
    AHF:HookScript("OnHide", function() f:Hide() end)
end

local function TryBuild()
    if AuctionHouseFrame and not UI.panel then UI.Build() end
end

AH.On("ADDON_LOADED", function(name)
    if name == "Blizzard_AuctionHouseUI" then TryBuild() end
end)
AH.On("PLAYER_LOGIN", function()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI")
    if loaded then TryBuild() end
end)
AH.On("AUCTION_HOUSE_SHOW", TryBuild)
