--[[
    Daseeki Conduit — options.lua

    Hub settings, migrated to the DaseekiUI flow API and the list+editor two-pane
    convention (the Armory-Sets / Buff-Tracker pattern the style guide mandates for
    anything managing a list of things):

      LEFT column  — the rules List + CRUD (New Item / New Gold / Clone / Rename /
                     Delete), the Send Consumes preset button, and the
                     per-character disable toggle.
      RIGHT column — a Rule Editor card whose fields adapt to the selected rule
                     (Items vs Gold; Category vs List) via condRow collapse, so a
                     hidden field leaves no leftover gap.

    No caller-supplied y-offsets, tokens only, every frame sets both dimensions.
--]]

local ADDON, ns = ...

local Options = {}
ns.Options = Options

local Rules = ns.Rules

-- ── Layout metrics ────────────────────────────────────────────────────────────
local SPLIT_LEFT = 300
local SPLIT_GAP  = 16
local SPLIT_MIN  = 716
local LBL_W      = 74
local ROW_ITEM_GAP = 8
local FIELD_X    = LBL_W + ROW_ITEM_GAP
local LIST_H     = 150
local MGMT_BTN   = 142
local MGMT_GRID  = MGMT_BTN * 2 + 8
local FIELD_W    = 180
local ITEMLIST_ROW_H = 22
local SUBGRID_ROW_H  = 22

local function rowGap() return (DaseekiUI.Token and DaseekiUI.Token("rowGap")) or 10 end

-- ── Flow helpers (copied convention from Buff-Tracker options) ────────────────
local function addBlock(flow, frame, arrange, topGap)
    flow.pane:AddBlock(frame, arrange, topGap or rowGap(), 0)
end
local function addCustom(row, w, pin)
    row._items[#row._items + 1] = { w = w, pin = pin }
    return w
end

-- A flow row that collapses to zero height (and swallows its top gap) when hidden.
local function condRow(flow)
    local row = flow:AddRow()
    local blk = flow.pane.blocks[#flow.pane.blocks]
    row._blk, row._baseGap = blk, blk.topGap
    local origArrange = blk.arrange
    blk.arrange = function(width)
        if row._applicable == false then row:Hide(); return 0 end
        row:Show(); return origArrange(width)
    end
    function row:SetApplicable(on)
        self._applicable = on and true or false
        self._blk.topGap = self._applicable and self._baseGap or 0
    end
    return row
end

-- Same collapse behavior for a caller-built custom block.
local function condBlock(flow, frame, arrange, topGap)
    flow.pane:AddBlock(frame, function(width)
        if frame._applicable == false then frame:Hide(); return 0 end
        frame:Show(); return arrange(width)
    end, topGap or rowGap(), 0)
    local blk = flow.pane.blocks[#flow.pane.blocks]
    blk._baseGap = blk.topGap
    function frame:SetApplicable(on)
        self._applicable = on and true or false
        blk.topGap = self._applicable and blk._baseGap or 0
    end
    return frame
end

-- ── Module state ──────────────────────────────────────────────────────────────
local O = {
    selectedId = nil,
    ruleList   = nil,
    pane       = nil,
    E          = {},   -- editor field refs
    subChecks  = {},   -- pooled subclass checkboxes
    itemRows   = {},   -- pooled chosen-item rows
    built      = false,
}

local function selectedRule()
    return O.selectedId and Rules.FindById(O.selectedId) or nil
end

local function refreshAll()
    if O.ruleList then O.ruleList:Rebuild() end
    if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
end

-- ── Editor visibility + relayout ──────────────────────────────────────────────
local relayoutEditor, updateEditorVis, populateEditor

relayoutEditor = function()
    if O.card and O.card.Relayout then O.card:Relayout() end
    if O.pane and O.pane.Layout then O.pane:Layout() end
end

-- ── Editor build ──────────────────────────────────────────────────────────────
local function ItemIconGetter(result)
    if result.itemID then
        local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(result.itemID)
        if tex then return tex end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Rebuild the subclass checklist for the selected rule's class.
local function rebuildSubGrid()
    local host = O.subHost
    if not host then return end
    local rule = selectedRule()
    for _, cb in ipairs(O.subChecks) do cb:Hide() end
    host._subs = {}
    if not (rule and rule.kind == "items" and rule.filter.mode == "category") then return end
    host._subs = Rules.SubClassesFor(rule.filter.classID)
end

-- Rebuild the chosen-items list for a list-mode rule.
local function rebuildItemList()
    local host = O.itemHost
    if not host then return end
    local rule = selectedRule()
    for _, r in ipairs(O.itemRows) do r:Hide() end
    host._items = {}
    if not (rule and rule.kind == "items" and rule.filter.mode == "list") then return end
    for itemID in pairs(rule.filter.items or {}) do
        host._items[#host._items + 1] = itemID
    end
    table.sort(host._items)
end

local function buildEditor(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite
    local card = UI.MakeEditorCard(flow.pane.child, { title = "Rule Editor" })
    O.card = card
    local cflow = card.flow
    local E = O.E

    card.arrange = function(width)
        card:SetWidth(width)
        card.pane:Layout()
        local h = card.pane.child:GetHeight() or 0
        if h < 2 then
            if not card._deferred then
                card._deferred = true
                C_Timer.After(0, function()
                    card._deferred = false
                    if O.pane and O.pane.Layout then O.pane:Layout() end
                end)
            end
            h = card._lastH or 60
        else
            card._lastH = h
        end
        card:SetHeight(h)
        return h
    end

    -- Empty-state hint.
    E.hintRow = condRow(cflow)
    local hint = E.hintRow:Label("Select a rule on the left, or create one.", { muted = true })
    hint.uiWidth = 360; hint:SetWidth(360)

    -- Name.
    E.nameRow = condRow(cflow)
    local nl = E.nameRow:Label("Name"); nl.uiWidth = LBL_W; nl:SetWidth(LBL_W)
    E.name = E.nameRow:EditBox({ width = FIELD_W, get = function()
        local r = selectedRule(); return r and r.name or ""
    end, set = function(v)
        local r = selectedRule(); if r then r.name = (v ~= "" and v) or r.name; refreshAll() end
    end })
    E.name._fillWidth = false

    -- Enabled + Kind.
    E.kindRow = condRow(cflow)
    local kl = E.kindRow:Label("Type"); kl.uiWidth = LBL_W; kl:SetWidth(LBL_W)
    E.enabled = E.kindRow:Checkbox({
        label = "Enabled",
        get = function() local r = selectedRule(); return r and r.enabled end,
        set = function(v) local r = selectedRule(); if r then r.enabled = v and true or false; refreshAll() end end,
    })
    E.kind = E.kindRow:SegmentedChoice({
        choices = { { value = "items", text = "Items" }, { value = "gold", text = "Gold" } },
        get = function() local r = selectedRule(); return r and r.kind or "items" end,
        set = function(v)
            local r = selectedRule()
            if r and r.kind ~= v then
                r.kind = v
                -- Ensure the shape has the fields the new kind needs.
                if v == "items" then
                    r.filter = r.filter or { mode = "category", classID = 7, subClasses = {}, items = {} }
                elseif v == "gold" then
                    r.keepCopper = r.keepCopper or 0
                end
                updateEditorVis(); refreshAll()
            end
        end,
    })

    -- Recipient + optional alt dropdown (only when a Nexus registry is present).
    E.recipRow = condRow(cflow)
    local rl = E.recipRow:Label("Recipient"); rl.uiWidth = LBL_W; rl:SetWidth(LBL_W)
    E.recip = E.recipRow:EditBox({ width = FIELD_W, get = function()
        local r = selectedRule(); return r and r.recipient or ""
    end, set = function(v)
        local r = selectedRule(); if r then r.recipient = (v or ""):match("^%s*(.-)%s*$"); refreshAll() end
    end })
    E.recip._fillWidth = false

    E.altRow = condRow(cflow)
    local al = E.altRow:Label("Alt"); al.uiWidth = LBL_W; al:SetWidth(LBL_W)
    -- Populate the convenience picker from the optional Nexus alt registry if one is
    -- present at build time; otherwise it stays a single placeholder (and the whole
    -- row is hidden by updateEditorVis when no registry is available).
    local altChoices = { { value = "", text = "— alts —" } }
    if ns.Network and ns.Network.Available() then
        for _, name in ipairs(ns.Network.GetAltNames()) do
            altChoices[#altChoices + 1] = { value = name, text = name }
        end
    end
    E.altDD = E.altRow:Dropdown({
        label = "", width = FIELD_W,
        choices = altChoices,
        get = function() return "" end,
        set = function(v)
            if v and v ~= "" then
                local r = selectedRule()
                if r then r.recipient = v; E.recip.Refresh(); refreshAll() end
            end
        end,
    })

    -- ── Items: filter mode ────────────────────────────────────────────────────
    E.modeRow = condRow(cflow)
    local ml = E.modeRow:Label("Filter"); ml.uiWidth = LBL_W; ml:SetWidth(LBL_W)
    E.mode = E.modeRow:SegmentedChoice({
        choices = { { value = "category", text = "Category" }, { value = "list", text = "Item List" } },
        get = function() local r = selectedRule(); return r and r.filter and r.filter.mode or "category" end,
        set = function(v)
            local r = selectedRule()
            if r and r.filter and r.filter.mode ~= v then
                r.filter.mode = v
                rebuildSubGrid(); rebuildItemList()
                updateEditorVis(); refreshAll()
            end
        end,
    })

    -- ── Items + Category: class dropdown ───────────────────────────────────────
    E.classRow = condRow(cflow)
    local cl = E.classRow:Label("Class"); cl.uiWidth = LBL_W; cl:SetWidth(LBL_W)
    local classChoices = {}
    for _, c in ipairs(Rules.ROUTABLE_CLASSES) do
        classChoices[#classChoices + 1] = { value = c.classID, text = Rules.ClassName(c.classID) }
    end
    E.class = E.classRow:Dropdown({
        label = "", width = FIELD_W, choices = classChoices,
        get = function() local r = selectedRule(); return r and r.filter and r.filter.classID or 7 end,
        set = function(v)
            local r = selectedRule()
            if r and r.filter then
                r.filter.classID = v
                r.filter.subClasses = {}   -- subclasses reset when the class changes
                rebuildSubGrid(); updateEditorVis(); refreshAll()
            end
        end,
    })

    -- Subclass checklist (custom collapsing block). Empty selection = whole class.
    local subHost = CreateFrame("Frame", nil, cflow.pane.child)
    subHost._fillWidth = true
    subHost._subs = {}
    O.subHost = subHost
    subHost.arrange = function(width)
        subHost:SetWidth(width)
        local UI2 = DaseekiUI
        local rule = selectedRule()
        local subs = subHost._subs or {}
        -- Header label.
        if not subHost._hdr then
            subHost._hdr = subHost:CreateFontString(nil, "OVERLAY")
            subHost._hdr:SetFontObject(UI2.fonts.small)
            subHost._hdr:SetPoint("TOPLEFT", subHost, "TOPLEFT", FIELD_X, -2)
            UI2.Skin(subHost._hdr, function(self) self:SetTextColor(UI2.Color("muted")) end)
        end
        subHost._hdr:SetText("Subclasses (none = whole class)")
        local cols = width - FIELD_X >= 300 and 2 or 1
        local colW = (width - FIELD_X) / cols
        for _, cb in ipairs(O.subChecks) do cb:Hide() end
        local rows = 0
        for i, s in ipairs(subs) do
            local cb = O.subChecks[i]
            if not cb then
                cb = UI2.MakeCheckbox(subHost, {})
                O.subChecks[i] = cb
            end
            cb._get = function() return rule and rule.filter and rule.filter.subClasses[s.subClassID] end
            cb._set = function(on)
                local r = selectedRule()
                if r and r.filter then
                    r.filter.subClasses[s.subClassID] = on and true or nil
                    refreshAll()
                end
            end
            if cb._label then cb._label:SetText(s.name) end
            local col = (i - 1) % cols
            local rowN = math.floor((i - 1) / cols)
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", subHost, "TOPLEFT", FIELD_X + col * colW, -(18 + rowN * SUBGRID_ROW_H))
            cb:SetWidth(math.max(1, colW - ROW_ITEM_GAP))
            cb:Refresh()
            cb:Show()
            rows = math.max(rows, rowN + 1)
        end
        local h = 18 + math.max(rows, 1) * SUBGRID_ROW_H
        subHost:SetHeight(h)
        return h
    end
    E.subBlock = condBlock(cflow, subHost, subHost.arrange)

    -- ── Items + List: search + chosen list ─────────────────────────────────────
    E.searchRow = condRow(cflow)
    local sl = E.searchRow:Label("Add Item"); sl.uiWidth = LBL_W; sl:SetWidth(LBL_W)
    E.search = E.searchRow:EditBox({ width = FIELD_W, get = function() return "" end })
    E.search._fillWidth = false
    E.search.editBox:SetScript("OnShow", nil)
    if DS and DS.AttachSearchDropdown then
        DS.AttachSearchDropdown(E.search.editBox, 260,
            function(q) return Rules.SearchConsumables(q) end,
            "name", "name",
            function(result)
                local r = selectedRule()
                if r and r.filter and result.itemID then
                    r.filter.items[result.itemID] = true
                    E.search.editBox:SetText("")
                    rebuildItemList(); updateEditorVis(); refreshAll()
                end
            end,
            ItemIconGetter)
    end

    local itemHost = CreateFrame("Frame", nil, cflow.pane.child)
    itemHost._fillWidth = true
    itemHost._items = {}
    O.itemHost = itemHost
    itemHost.arrange = function(width)
        itemHost:SetWidth(width)
        local UI2 = DaseekiUI
        local rule = selectedRule()
        local ids = itemHost._items or {}
        for _, r in ipairs(O.itemRows) do r:Hide() end
        if #ids == 0 then
            if not itemHost._empty then
                itemHost._empty = itemHost:CreateFontString(nil, "OVERLAY")
                itemHost._empty:SetFontObject(UI2.fonts.small)
                itemHost._empty:SetPoint("TOPLEFT", itemHost, "TOPLEFT", FIELD_X, -2)
                UI2.Skin(itemHost._empty, function(self) self:SetTextColor(UI2.Color("faint")) end)
            end
            itemHost._empty:SetText("No items yet — search above (e.g. flask, potion).")
            itemHost._empty:Show()
            itemHost:SetHeight(18)
            return 18
        end
        if itemHost._empty then itemHost._empty:Hide() end
        local y = 0
        for i, itemID in ipairs(ids) do
            local r = O.itemRows[i]
            if not r then
                r = CreateFrame("Frame", nil, itemHost)
                r:SetSize(10, ITEMLIST_ROW_H)
                r.icon = r:CreateTexture(nil, "ARTWORK")
                r.icon:SetSize(16, 16)
                r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
                r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                r.lbl = r:CreateFontString(nil, "OVERLAY")
                r.lbl:SetFontObject(UI2.fonts.body)
                r.lbl:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
                r.lbl:SetJustifyH("LEFT"); r.lbl:SetWordWrap(false)
                r.rm = UI2.MakeButton(r, { text = "X", width = 22, height = 18, variant = "danger" })
                r.rm:ClearAllPoints()
                r.rm:SetPoint("RIGHT", r, "RIGHT", 0, 0)
                O.itemRows[i] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", itemHost, "TOPLEFT", FIELD_X, -y)
            r:SetPoint("RIGHT", itemHost, "RIGHT", 0, 0)
            r.lbl:ClearAllPoints()
            r.lbl:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
            r.lbl:SetPoint("RIGHT", r.rm, "LEFT", -6, 0)
            local name = (GetItemInfo(itemID)) or Rules.ConsumablesSeed[itemID] or ("Item #" .. itemID)
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(itemID)
            r.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.lbl:SetText(name)
            r.rm:SetScript("OnClick", function()
                local rr = selectedRule()
                if rr and rr.filter then
                    rr.filter.items[itemID] = nil
                    rebuildItemList(); updateEditorVis(); refreshAll()
                end
            end)
            r:Show()
            y = y + ITEMLIST_ROW_H
        end
        itemHost:SetHeight(math.max(y, 1))
        return math.max(y, 1)
    end
    E.itemBlock = condBlock(cflow, itemHost, itemHost.arrange)

    -- ── Gold: keep amount ──────────────────────────────────────────────────────
    E.goldRow = condRow(cflow)
    local gl = E.goldRow:Label("Keep (g)"); gl.uiWidth = LBL_W; gl:SetWidth(LBL_W)
    E.keep = E.goldRow:EditBox({ width = 100, numeric = true, get = function()
        local r = selectedRule()
        return r and tostring(math.floor((r.keepCopper or 0) / 10000)) or "0"
    end, set = function(v)
        local r = selectedRule()
        if r then
            local g = tonumber(v) or 0
            if g < 0 then g = 0 end
            r.keepCopper = math.floor(g) * 10000
            refreshAll()
        end
    end })
    E.keep._fillWidth = false

    E.goldHintRow = condRow(cflow)
    local ghl = E.goldHintRow:Label(""); ghl.uiWidth = LBL_W; ghl:SetWidth(LBL_W)
    local ghint = E.goldHintRow:Label("Sends everything above this, less a 30s postage buffer.", { muted = true })
    ghint.uiWidth = 320; ghint:SetWidth(320)

    -- ── Delete ─────────────────────────────────────────────────────────────────
    E.deleteRow = condRow(cflow)
    E.deleteRow:Button({ text = "Delete Rule", width = 110, variant = "danger", pin = "right", onClick = function()
        local r = selectedRule()
        if not r then return end
        DaseekiUI.Confirm({
            title = "Delete Rule", danger = true,
            text = ("Delete rule \"%s\"? This cannot be undone."):format(r.name or "?"),
            acceptText = "Delete", cancelText = "Cancel",
            onAccept = function()
                local _, idx = Rules.FindById(r.id)
                if idx then table.remove(ns.db.rules, idx) end
                O.selectedId = ns.db.rules[1] and ns.db.rules[1].id or nil
                populateEditor(); refreshAll()
            end,
        })
    end })

    addBlock(flow, card, card.arrange, rowGap())
end

-- ── Editor visibility rules ───────────────────────────────────────────────────
updateEditorVis = function()
    local r = selectedRule()
    local hasSel = r ~= nil
    local isItems = hasSel and r.kind == "items"
    local isGold  = hasSel and r.kind == "gold"
    local isCat   = isItems and r.filter and r.filter.mode == "category"
    local isList  = isItems and r.filter and r.filter.mode == "list"
    local hasAlts = ns.Network and ns.Network.Available()

    local E = O.E
    E.hintRow:SetApplicable(not hasSel)
    E.nameRow:SetApplicable(hasSel)
    E.kindRow:SetApplicable(hasSel)
    E.recipRow:SetApplicable(hasSel)
    E.altRow:SetApplicable(hasSel and hasAlts)
    E.modeRow:SetApplicable(isItems)
    E.classRow:SetApplicable(isCat)
    E.subBlock:SetApplicable(isCat)
    E.searchRow:SetApplicable(isList)
    E.itemBlock:SetApplicable(isList)
    E.goldRow:SetApplicable(isGold)
    E.goldHintRow:SetApplicable(isGold)
    E.deleteRow:SetApplicable(hasSel)

    relayoutEditor()
end

-- ── Populate editor from the selected rule ────────────────────────────────────
populateEditor = function()
    local E = O.E
    local r = selectedRule()
    if r then
        if E.name and E.name.Refresh then E.name.Refresh() end
        if E.enabled and E.enabled.Refresh then E.enabled:Refresh() end
        if E.kind and E.kind.Refresh then E.kind.Refresh() end
        if E.recip and E.recip.Refresh then E.recip.Refresh() end
        if E.mode and E.mode.Refresh then E.mode.Refresh() end
        if E.class and E.class.Refresh then E.class.Refresh() end
        if E.keep and E.keep.Refresh then E.keep.Refresh() end
        -- Refresh alt dropdown choices if a registry is present.
        if E.altDD and ns.Network and ns.Network.Available() then
            -- (choices are static-shaped; recipient is set on select — nothing to sync)
        end
        rebuildSubGrid(); rebuildItemList()
    end
    if O.ruleList then O.ruleList:SetSelected(O.selectedId) end
    updateEditorVis()
end

-- ── Build the whole page ──────────────────────────────────────────────────────
function Options.Build(flow)
    if O.built then return end
    O.built = true
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite
    local ShowNameInputDialog = DS.ShowNameInputDialog

    O.pane = flow.pane
    if not O.selectedId and ns.db and ns.db.rules[1] then
        O.selectedId = ns.db.rules[1].id
    end

    local split    = CreateFrame("Frame", nil, flow.pane.child)
    local leftCol  = UI.CreateColumn(split)
    local rightCol = UI.CreateColumn(split)
    local L, R = leftCol.flow, rightCol.flow

    -- ══ LEFT ══════════════════════════════════════════════════════════════════
    L:AddSection("Rules")
    L:Hint("One rule per mail job. Send at an open mailbox from the Conduit panel.")

    O.ruleList = L:List({
        height = LIST_H,
        selected = O.selectedId,
        items = function()
            local out = {}
            for _, rule in ipairs((ns.db and ns.db.rules) or {}) do
                -- Attention inversion (§2/§5): only a rule that is enabled yet can't send
                -- (no recipient) tints danger; disabled + ready rules stay calm (MakeList's
                -- default faint dot). MakeList's status vocabulary is ok/danger/faint.
                local hasRecip = rule.recipient and rule.recipient ~= ""
                local status = (rule.enabled and not hasRecip) and "danger" or nil
                local tag = rule.kind == "gold" and "  [gold]" or ""
                out[#out + 1] = { text = (rule.name or "Rule") .. tag, value = rule.id, status = status }
            end
            return out
        end,
        onSelect = function(id)
            O.selectedId = id
            populateEditor()
        end,
    })

    local crud1 = L:AddRow()
    crud1:Button({ text = "New Item", width = MGMT_BTN, onClick = function()
        local r = Rules.NewItemRule()
        table.insert(ns.db.rules, r); O.selectedId = r.id
        populateEditor(); refreshAll()
    end })
    crud1:Button({ text = "New Gold", width = MGMT_BTN, onClick = function()
        local r = Rules.NewGoldRule()
        table.insert(ns.db.rules, r); O.selectedId = r.id
        populateEditor(); refreshAll()
    end })

    local crud2 = L:AddRow()
    crud2:Button({ text = "Clone", width = MGMT_BTN, onClick = function()
        local r = selectedRule(); if not r then return end
        local copy = CopyTable(r)
        copy.id = Rules.NextId()
        copy.name = (r.name or "Rule") .. " Copy"
        table.insert(ns.db.rules, copy); O.selectedId = copy.id
        populateEditor(); refreshAll()
    end })
    crud2:Button({ text = "Rename", width = MGMT_BTN, onClick = function()
        local r = selectedRule(); if not r then return end
        ShowNameInputDialog("Rename Rule", r.name or "", function(name)
            if name and name ~= "" then r.name = name; populateEditor(); refreshAll() end
        end)
    end })

    L:AddRow():Button({ text = "+ Send Consumes preset", width = MGMT_GRID, onClick = function()
        local r = Rules.NewConsumesPreset()
        table.insert(ns.db.rules, r); O.selectedId = r.id
        populateEditor(); refreshAll()
    end })

    L:AddSection("This Character")
    L:Checkbox({
        label = "Disable Conduit on this character",
        get = function() return ns:IsCharDisabled() end,
        set = function(v) ns:SetCharDisabled(v); refreshAll() end,
    })
    L:Hint("Rules never send from a disabled character. Account-wide rules are unchanged.")

    -- ══ RIGHT ═════════════════════════════════════════════════════════════════
    R:AddSection("Editor")
    buildEditor(R)

    -- ── Split arrange ──────────────────────────────────────────────────────────
    split.arrange = function(width)
        split:SetWidth(width)
        if width >= SPLIT_MIN then
            local lw = SPLIT_LEFT
            local rw = math.max(1, width - lw - SPLIT_GAP)
            local lh = leftCol:Layout(lw)
            local rh = rightCol:Layout(rw)
            leftCol.frame:ClearAllPoints()
            leftCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", 0, 0)
            rightCol.frame:ClearAllPoints()
            rightCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", lw + SPLIT_GAP, 0)
            local total = math.max(lh, rh)
            split:SetHeight(math.max(total, 1))
            return total
        else
            local lh = leftCol:Layout(width)
            local rh = rightCol:Layout(width)
            leftCol.frame:ClearAllPoints()
            leftCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", 0, 0)
            rightCol.frame:ClearAllPoints()
            rightCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", 0, -(lh + SPLIT_GAP))
            local total = lh + SPLIT_GAP + rh
            split:SetHeight(math.max(total, 1))
            return total
        end
    end
    addBlock(flow, split, split.arrange, rowGap())

    populateEditor()
end

function Options.Refresh()
    if not O.built then return end
    populateEditor()
end

-- ── Register into the Daseeki hub ─────────────────────────────────────────────
function Options.Register()
    if not _G.DaseekiSuite then return end
    if not (_G.DaseekiUI and _G.DaseekiUI.Token) then
        ns:Print("requires Daseeki Core (DaseekiUI) — please update Daseeki Core.")
        return
    end
    DaseekiSuite:RegisterAddon({
        id    = "conduit",
        title = "Conduit",
        icon  = "Interface\\Icons\\INV_Letter_15",
        order = 40,
        flow  = true,
        sections = {
            {
                id      = "main",
                title   = "Conduit",
                build   = function(flow) Options.Build(flow) end,
                refresh = function() Options.Refresh() end,
            },
        },
    })
end
