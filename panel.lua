--[[
    Daseeki Conduit — panel.lua

    The mailbox panel: a compact DaseekiUI-styled frame anchored beside the open
    mail window (shown on MAIL_SHOW, hidden with the mail window by core.lua's
    mailbox teardown coordinator — MAIL_CLOSED or MailFrame OnHide). It lists the
    configured rules with a per-rule Send button, a Run All button, a live
    progress line, and — during an active run — a "Send Next" button that drives
    each continuation mail (SendMail needs a hardware event, so the click is real).

    Above Run All sits the optional BOON ROW (Chronoboon replenishment): the button
    on the designated source character, a muted one-liner naming that character
    everywhere else, and nothing at all until a source has been designated. All of
    the deciding is boons.lua's ButtonState — this file only draws the answer.

    Style-guide compliance: DaseekiUI tokens only (no hardcoded colors/fonts),
    every frame sets BOTH dimensions at creation, compact/labeled layout, no
    Sushi/Poncho. Errors surface via geterrorhandler (ns:SafeCall), never swallowed.
--]]

local ADDON, ns = ...
local UI = DaseekiUI

local Panel = {}
ns.Panel = Panel

-- ── Metrics ───────────────────────────────────────────────────────────────────
local PANEL_W   = 280
local PANEL_H   = 360
local PAD       = 10
local HEADER_H  = 22
local ROW_H     = 34
local SEND_W    = 54
local FOOT_H    = 78   -- footer band: Run All + Send Next + progress
local BOON_H    = 28   -- the boon row's extra footer height, when it is drawn at all

-- Header control cluster (suite glyph metrics — see makeGlyphButton below).
local ART        = "Interface\\AddOns\\" .. tostring(ADDON) .. "\\art\\"
local ICONBTN    = 22   -- control button edge
local ICON_INSET = 2    -- glyph inset inside the button => 18x18 drawn
local ICON_SPACE = 8    -- gap between adjacent controls
-- The cluster's vertical centre is the header row's, so the glyphs sit on the same
-- optical line as the 18px maker mark and the title beside it: the mark spans
-- -PAD..-(PAD+18), centre -19, so a 22px button's top edge is -(19-11) = -8.
local ICON_TOP   = -8

local frame       -- the panel frame (lazy)
local rowPool = {}

-- ── Suite glyph buttons (the header's upper-right control cluster) ────────────
-- The upper right of a Daseeki window is ONE object across the suite, and this is
-- it — the same button Nexus' dashboard titlebar builds, Bags 2.0's title row
-- builds, and Raid Prep's checklist header builds:
--
--   * 22x22 BackdropTemplate, FLAT_BACKDROP filled `inset` with a `borderLite` edge.
--   * a 64x64 white-on-transparent glyph mask inset 2px on all four sides (18x18
--     drawn, NO SetTexCoord crop — our glyphs carry their own margin).
--   * the GLYPH carries the hover, not the border: `muted` at rest, `accent` on
--     enter — and `danger` on the close, the one destructive affordance in the row.
--
-- The art is Conduit's OWN copy (art/icon-close.tga, art/icon-gear.tga) of the
-- canonical Nexus masks, byte-for-byte. That per-addon copy IS the suite pattern:
-- there is no shared texture path in Core to point at, and the gear and the close
-- mark are meant to be pixel-identical everywhere they appear. The harness pins
-- both digests so a re-export or an accidental redraw fails the build instead of
-- quietly drifting this window away from its neighbours.
--
-- `_hot` is stashed on the button so the UI.Skin callback — which re-runs on every
-- ThemeChanged — re-reads the CURRENT hover state instead of resetting a button the
-- cursor happens to be parked on. Pure child textures; no protected op.
--
-- Every colour here is a THEME TOKEN. Core is a hard Dependency for Conduit, but an
-- OLDER Core may predate FLAT_BACKDROP (this file already guards PaintLedgerGround,
-- Hairline and MakerMark the same way), so the factory REPORTS FAILURE rather than
-- guessing literals and the caller keeps a plain fallback header.
local function glyphCapable()
    return (UI and UI.Color and UI.Skin and UI.FLAT_BACKDROP) and true or false
end

local function makeGlyphButton(parent, spec)
    if not glyphCapable() then return nil end
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(ICONBTN, ICONBTN)          -- both dims at creation
    b:RegisterForClicks("LeftButtonUp")
    local hot = spec.hot or "accent"

    local face = b:CreateTexture(nil, "ARTWORK")
    face:SetPoint("TOPLEFT",     b, "TOPLEFT",      ICON_INSET, -ICON_INSET)
    face:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -ICON_INSET,  ICON_INSET)
    face:SetTexture(ART .. spec.icon)
    b._face = face

    UI.Skin(b, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
        self._face:SetVertexColor(UI.Color(self._hot and hot or "muted"))
    end)

    b:SetScript("OnEnter", function(self)
        self._hot = true
        self._face:SetVertexColor(UI.Color(hot))
        if GameTooltip and spec.tooltip then
            GameTooltip:SetOwner(self, spec.tipAnchor or "ANCHOR_BOTTOM")
            GameTooltip:SetText(spec.tooltip, UI.Color("text"))
            -- UI.Color returns r,g,b,a; the alpha lands on AddLine's wrapText slot
            -- (always 1, so the sub-line wraps). Same call shape as Nexus, Bags and
            -- Raid Prep — deliberately not "improved" here, so the tooltips read alike.
            if spec.tooltip2 then GameTooltip:AddLine(spec.tooltip2, UI.Color("muted")) end
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self._hot = nil
        self._face:SetVertexColor(UI.Color("muted"))
        if GameTooltip then GameTooltip:Hide() end
    end)
    if spec.onClick then b:SetScript("OnClick", spec.onClick) end
    return b
end

-- ── Row construction ──────────────────────────────────────────────────────────
local function makeRow(parent, i)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(PANEL_W - PAD * 2 - 12, ROW_H)   -- both dims (12 = scrollbar gutter)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    UI.Skin(row.bg, function(self) self:SetColorTexture(UI.Color(i % 2 == 0 and "raised" or "panel", 0.6)) end)

    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(8, 8)
    row.dot:SetPoint("LEFT", row, "LEFT", 6, 0)

    row.send = UI.MakeButton(row, { text = "Send", width = SEND_W, height = 22 })
    row.send:ClearAllPoints()
    row.send:SetPoint("RIGHT", row, "RIGHT", -4, 0)

    row.name = row:CreateFontString(nil, "OVERLAY")
    row.name:SetFontObject(UI.fonts.body)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 18, -4)
    row.name:SetPoint("RIGHT", row.send, "LEFT", -6, 0)

    row.sub = row:CreateFontString(nil, "OVERLAY")
    row.sub:SetFontObject(UI.fonts.small)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("RIGHT", row.send, "LEFT", -6, 0)
    UI.Skin(row.sub, function(self) self:SetTextColor(UI.Color("muted")) end)

    return row
end

-- ── Panel construction (lazy; on first MAIL_SHOW) ─────────────────────────────
local function build()
    if frame then return frame end
    if not (UI and UI.FlatFrame) then return nil end   -- Core not present

    local f = UI.FlatFrame(UIParent, "panel", "borderLite")
    f:SetSize(PANEL_W, PANEL_H)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(true)
    f:Hide()

    -- ESC-close (BRAND_SPEC §8). The panel is an unprotected frame, so UISpecialFrames is
    -- safe. Named + guarded add (idempotent) so a rebuild never double-registers.
    local GNAME = "DaseekiConduitPanel"
    _G[GNAME] = f
    if type(UISpecialFrames) == "table" then
        local seen = false
        for _, n in ipairs(UISpecialFrames) do if n == GNAME then seen = true; break end end
        if not seen then table.insert(UISpecialFrames, GNAME) end
    end

    -- Ledger ground: grain substrate + aged-edge vignette + 1px bronze window keyline
    -- (BRAND_SPEC §4). Kit calls are guarded so an older Core (no Phase-0 kit) still
    -- loads — the panel just renders flat.
    if UI.PaintLedgerGround then UI.PaintLedgerGround(f) end

    -- §4 layering contract: chrome text must sit on a flat fill, never on grain. The
    -- header and footer text bands get a flat "panel" backer at BACKGROUND sublevel 3
    -- (above the kit's grain[1]/vignette[2]); the bronze keyline (BORDER) and the side
    -- vignettes still draw above/around them. The middle (the rules list) already sits
    -- on its own inset card. No-op-safe if the kit painted nothing.
    local function flatBacker(anchorSetup)
        local t = f:CreateTexture(nil, "BACKGROUND", nil, 3)
        UI.Skin(t, function(self) self:SetColorTexture(UI.Color("panel")) end)
        anchorSetup(t)
        return t
    end
    flatBacker(function(t)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        t:SetHeight(PAD + HEADER_H)
    end)
    f.footBacker = flatBacker(function(t)
        t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
        t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        t:SetHeight(FOOT_H + PAD)
    end)

    -- Header. ONE maker's mark per window (§5), on the titlebar (§4).
    local title = f:CreateFontString(nil, "OVERLAY")
    -- Window title → ceremonial MORPHEUS ≥16 (§3); falls back to the serif header font.
    title:SetFontObject(UI.fonts.ceremonial or UI.fonts.header)
    title:SetText("Conduit")
    f.title = title

    if UI.MakerMark then
        local mark = UI.MakerMark(f, { size = 18 })
        mark:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
        title:SetPoint("LEFT", mark, "RIGHT", 6, -1)
        f.mark = mark
    else
        title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
    end

    -- ── Header control cluster (BRAND_SPEC §8) ────────────────────────────────
    -- Laid RIGHT→LEFT from the window edge, so the visual order is
    --
    --     [gear] [✕]
    --
    -- which is the Nexus dashboard's, Bags 2.0's and Raid Prep's right cluster
    -- verbatim (… gear then ✕ hard against the edge).
    --
    -- Closing only hides the panel; an in-progress run is left intact (reopen with
    -- /conduit show — see core.lua). ESC-close is wired via UISpecialFrames above.
    --
    -- ⚠ EDGE JUDGEMENT: the suite's cluster sits ICON_SPACE (8) from the window
    -- edge, but every other right edge in THIS panel — the header hairline, the
    -- rules card, the footer buttons — is at PAD (10). Grid discipline inside one
    -- window beats a 2px suite habit, so the ✕ is flush at -PAD and ICON_SPACE is
    -- kept as the gap BETWEEN the controls. Easy to flip if Drew wants the 8.
    local doClose    = function() Panel.Hide() end
    local doSettings = function() ns:SafeCall(function() ns:OpenSettings() end) end

    local closeBtn, gearBtn
    if glyphCapable() then
        -- ✕ — hovers `danger`, and carries NO tooltip: the mark is universal, and
        -- Nexus leaves its close bare for the same reason.
        closeBtn = makeGlyphButton(f, { icon = "icon-close", hot = "danger", onClick = doClose })
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, ICON_TOP)

        -- GEAR — byte-identical to the Nexus/Bags/Raid-Prep settings glyph. A cog is
        -- ambiguous, so unlike the ✕ it keeps its tooltip. Same door as /conduit
        -- settings, through core.lua's single ns:OpenSettings.
        gearBtn = makeGlyphButton(f, { icon = "icon-gear",
            tooltip  = "Conduit Settings",
            tooltip2 = "Open the Daseeki hub to Conduit's rules and options.",
            onClick  = doSettings })
        gearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -ICON_SPACE, 0)
    else
        -- NO-CORE FALLBACK: an older Core with no FLAT_BACKDROP, so there is no
        -- themed button object to hang a tinted glyph on. The header keeps the plain
        -- text ✕ this panel shipped with, plus a stock-art gear beside it.
        closeBtn = CreateFrame("Button", nil, f)
        closeBtn:SetSize(ICONBTN, ICONBTN)
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, ICON_TOP)
        local cx = closeBtn:CreateFontString(nil, "OVERLAY")
        cx:SetFontObject(UI.fonts.body)
        cx:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
        cx:SetText("X")
        closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
        closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body) end)
        closeBtn:SetScript("OnClick", doClose)

        gearBtn = CreateFrame("Button", nil, f)
        gearBtn:SetSize(ICONBTN, ICONBTN)
        gearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -ICON_SPACE, 0)
        gearBtn:SetNormalTexture("Interface/Icons/Trade_Engineering")
        gearBtn:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square", "ADD")
        gearBtn:SetScript("OnClick", doSettings)
        gearBtn:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine("Conduit Settings", 1, 1, 1)
            GameTooltip:Show()
        end)
        gearBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    f.closeBtn = closeBtn
    f.gearBtn  = gearBtn

    -- Slash-command hint → uppercase letter-spaced micro-label (§3); stays faint (calm).
    -- Sits to the LEFT of the cluster, vertically centred on it (§3: mixed-height row
    -- items centre rather than share a baseline).
    local hint = f:CreateFontString(nil, "OVERLAY")
    hint:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
    hint:SetPoint("RIGHT", gearBtn, "LEFT", -6, 0)
    hint:SetJustifyH("RIGHT")
    UI.Skin(hint, function(self) self:SetTextColor(UI.Color("faint")) end)
    hint:SetText("/CONDUIT")
    f.hint = hint

    -- Header divider: the ONE section hairline, pixel-snapped via the kit (§1). Falls
    -- back to a plain 1px texture on an older Core.
    if UI.Hairline then
        local hair = UI.Hairline(f, { token = "border" })
        hair:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + HEADER_H))
        hair:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -(PAD + HEADER_H))
    else
        local hair = f:CreateTexture(nil, "ARTWORK")
        hair:SetHeight(1)
        hair:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + HEADER_H))
        hair:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -(PAD + HEADER_H))
        UI.Skin(hair, function(self) self:SetColorTexture(UI.Color("border")) end)
    end

    -- Disabled banner (shown when this character is opted out).
    local banner = f:CreateFontString(nil, "OVERLAY")
    banner:SetFontObject(UI.fonts.small)
    banner:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + HEADER_H + 6))
    banner:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -(PAD + HEADER_H + 6))
    banner:SetJustifyH("LEFT")
    banner:SetWordWrap(true)
    UI.Skin(banner, function(self) self:SetTextColor(UI.Color("danger")) end)
    banner:Hide()
    f.banner = banner

    -- Scroll list host (inset card).
    local listHost = UI.FlatFrame(f, "inset", "border")
    listHost:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + HEADER_H + 8))
    listHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOT_H + PAD)
    f.listHost = listHost

    local scroll = CreateFrame("ScrollFrame", nil, listHost)
    scroll:SetPoint("TOPLEFT", listHost, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", listHost, "BOTTOMRIGHT", -4, 4)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        if maxs > 0 then
            local cur = self:GetVerticalScroll()
            self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * ROW_H)))
        end
    end)
    f.scroll, f.child = scroll, child

    -- Empty-state label.
    local empty = child:CreateFontString(nil, "OVERLAY")
    empty:SetFontObject(UI.fonts.small)
    empty:SetPoint("TOPLEFT", child, "TOPLEFT", 6, -10)
    empty:SetWidth(PANEL_W - PAD * 2 - 24)
    empty:SetJustifyH("LEFT")
    empty:SetWordWrap(true)
    UI.Skin(empty, function(self) self:SetTextColor(UI.Color("muted")) end)
    empty:SetText("No rules yet. Open " .. ns:Wrap("brand", "/conduit settings") .. " to add a rule, or the Send Consumes preset.")
    empty:Hide()
    f.empty = empty

    -- Footer: Run All + Send Next + progress line.
    local runAll = UI.MakeButton(f, { text = "Run All", width = PANEL_W - PAD * 2, height = 24 })
    runAll:ClearAllPoints()
    runAll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD + 30)
    runAll:SetScript("OnClick", function()
        ns:SafeCall(function() ns.Mail.RunAll() end)
    end)
    f.runAll = runAll

    local sendNext = UI.MakeButton(f, { text = "Send Next", width = PANEL_W - PAD * 2, height = 24 })
    sendNext:ClearAllPoints()
    sendNext:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD + 30)
    sendNext:SetScript("OnClick", function()
        ns:SafeCall(function() ns.Mail.ContinueClick() end)
    end)
    sendNext:Hide()
    f.sendNext = sendNext

    -- ── The boon row (Chronoboon replenishment) ───────────────────────────────
    --
    -- One row, three possible faces, and MOST OF THE TIME NONE OF THEM: the whole
    -- band is drawn only when a boon source has been designated, so a panel nobody
    -- configured for this looks exactly as it did before the feature existed
    -- (boons.lua ButtonState "off"). Where it does draw it is either the button —
    -- on the source character, greyed when it cannot fire, exactly like Run All —
    -- or one muted line saying who does the sending. Refresh() decides; see
    -- layoutFooter for the height the decision costs.
    local boonBtn = UI.MakeButton(f, { text = "Replenish Boons", width = PANEL_W - PAD * 2, height = 24 })
    boonBtn:ClearAllPoints()
    boonBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD + 30 + BOON_H)
    boonBtn:SetScript("OnClick", function()
        ns:SafeCall(function() if ns.Boons then ns.Boons.Run() end end)
    end)
    -- The one caveat the numbers cannot state themselves: Nexus's per-character
    -- counts are carried+bank+mail, so an alt with a drawer full of boons in the
    -- BANK reads as stocked and is left out of the plan on purpose.
    boonBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Replenish Boons")

        -- WHY IT IS GREYED, FIRST. A refusing button that explains nothing is the
        -- defect this round fixes, and the reason must be the SAME answer the alpha
        -- was drawn from: Refresh stashes the ButtonState string it used, and the
        -- tooltip only translates it. Re-deriving from the live world here would let
        -- the sentence and the greying disagree — precisely the class of bug that
        -- produced a greyed button at an open mailbox.
        local reason = ns.Boons and ns.Boons.StateReason(self._state)
        if reason then GameTooltip:AddLine(reason, 1, 0.35, 0.35, true) end

        GameTooltip:AddLine("Tops every level-60 character in the mesh up to "
            .. tostring(ns.Boons and ns.Boons.TARGET or 10) .. " Chronoboon Displacers,"
            .. " biggest need first.", 1, 1, 1, true)
        GameTooltip:AddLine("Counts come from Daseeki Nexus and include the bank — a"
            .. " character with boons banked reads as stocked.", 1, 0.82, 0, true)
        GameTooltip:AddLine("You will see every character and amount before anything sends.",
            1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    boonBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    boonBtn:Hide()
    f.boonBtn = boonBtn

    local boonHint = f:CreateFontString(nil, "OVERLAY")
    boonHint:SetFontObject(UI.fonts.small)
    boonHint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD + 30 + BOON_H + 4)
    boonHint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD + 30 + BOON_H + 4)
    boonHint:SetJustifyH("LEFT")
    boonHint:SetHeight(24)
    boonHint:SetWordWrap(true)
    UI.Skin(boonHint, function(self) self:SetTextColor(UI.Color("muted")) end)
    boonHint:Hide()
    f.boonHint = boonHint

    local prog = f:CreateFontString(nil, "OVERLAY")
    prog:SetFontObject(UI.fonts.small)
    prog:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD)
    prog:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
    prog:SetJustifyH("LEFT")
    prog:SetHeight(26)
    prog:SetWordWrap(true)
    UI.Skin(prog, function(self) self:SetTextColor(UI.Color("muted")) end)
    f.prog = prog

    -- Anything that puts this panel on screen redraws it, including a route that
    -- does not go through Panel.Show (UISpecialFrames restore, a future caller).
    -- Refresh() no-ops on a hidden frame and is idempotent on a shown one, so this
    -- can only ever cost a redraw.
    f:SetScript("OnShow", function() ns:SafeCall(Panel.Refresh) end)

    frame = f
    return f
end

-- The footer band grows by one row when the boon feature has something to show,
-- and the rules list gives the space back. Both dimensions are still set at
-- creation (build); this only re-anchors the list's bottom edge and re-heights the
-- footer's flat backer, so an unconfigured panel is pixel-identical to 1.0.1's.
local function layoutFooter(f, extra)
    local h = FOOT_H + extra
    if f._footH == h then return end
    f._footH = h
    f.listHost:ClearAllPoints()
    f.listHost:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + HEADER_H + 8))
    f.listHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, h + PAD)
    if f.footBacker then f.footBacker:SetHeight(h + PAD) end
end

-- ── Refresh (rebuild rows + sync footer/progress state) ───────────────────────
function Panel.Refresh()
    local f = frame
    if not f or not f:IsShown() then return end

    local db = ns.db
    local rules = (db and db.rules) or {}
    local disabled = ns:IsCharDisabled()
    local active = ns.Mail and ns.Mail.IsActive()
    local awaiting = ns.Mail and ns.Mail.IsAwaitingClick()

    -- Disabled banner nudges the list down when shown.
    f.banner:SetShown(disabled)
    f.banner:SetText(disabled and "Disabled on this character. /conduit enable to turn on." or "")

    -- Rows.
    for _, r in ipairs(rowPool) do r:Hide() end
    local y = 0
    local shown = 0
    for i, rule in ipairs(rules) do
        local row = rowPool[i]
        if not row then row = makeRow(f.child, i); rowPool[i] = row end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.child, "TOPLEFT", 2, -y)
        row:Show()
        shown = shown + 1

        row.name:SetText(rule.name or ("Rule " .. i))
        local hasRecip = rule.recipient and rule.recipient ~= ""
        local recip = hasRecip and rule.recipient or ns:Wrap("danger", "no recipient")
        local kindStr = rule.kind == "gold" and "gold" or "items"
        row.sub:SetText(kindStr .. "  ->  " .. recip)

        -- Attention inversion (§2/§5): rows are calm by default; only a rule that is
        -- enabled yet can't send (no recipient) tints. Disabled + ready rules stay idle.
        local problem = rule.enabled and not hasRecip
        row.dot:SetColorTexture(UI.Color(problem and "danger" or "idle"))

        -- Per-rule Send: disabled while a run is active or char disabled.
        local canSend = rule.enabled and not active and not disabled
        row.send:SetEnabled(canSend)
        row.send:SetAlpha(canSend and 1 or 0.4)
        row.send:SetScript("OnClick", function()
            ns:SafeCall(function() ns.Mail.RunRule(rule.id) end)
        end)

        y = y + ROW_H + 2
    end
    f.child:SetHeight(math.max(1, y))
    f.empty:SetShown(shown == 0)

    -- The boon row. Mid-batch (`awaiting`) it is hidden outright rather than
    -- greyed: the footer belongs to Send Next while a run is stepping, and the row
    -- comes back the moment the run ends.
    local boonState, boonHint = "off", nil
    if ns.Boons and not awaiting then boonState, boonHint = ns.Boons.State() end

    -- The ONE answer this redraw is working from. The tooltip reads it back rather
    -- than asking the world a second time, so the reason it prints can never
    -- contradict the alpha set three lines below.
    f.boonBtn._state = boonState

    if boonState == "off" then
        f.boonBtn:Hide()
        f.boonHint:Hide()
        layoutFooter(f, 0)
    elseif ns.Boons.StateShowsButton(boonState) then
        f.boonHint:Hide()
        f.boonBtn:Show()
        local canBoon = (boonState == "armed")
        f.boonBtn:SetEnabled(canBoon)
        f.boonBtn:SetAlpha(canBoon and 1 or 0.4)
        layoutFooter(f, BOON_H)
    else
        f.boonBtn:Hide()
        f.boonHint:SetText(boonHint or "")
        f.boonHint:Show()
        layoutFooter(f, BOON_H)
    end

    -- Footer buttons.
    if awaiting then
        f.runAll:Hide()
        f.sendNext:Show()
    else
        f.sendNext:Hide()
        f.runAll:Show()
        local canRun = not active and not disabled and shown > 0
        f.runAll:SetEnabled(canRun)
        f.runAll:SetAlpha(canRun and 1 or 0.4)
    end

    -- Progress line.
    local status = ns.Mail and ns.Mail.Status()
    f.prog:SetText(status or (disabled and "" or "Ready."))
end

-- ── Show / hide with the mailbox ──────────────────────────────────────────────
local function anchorToMail(f)
    f:ClearAllPoints()
    if _G.MailFrame then
        f:SetPoint("TOPLEFT", _G.MailFrame, "TOPRIGHT", 6, 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    end
end

function Panel.Show()
    local f = build()
    if not f then return end
    -- Re-arm the teardown, so a panel re-opened with /conduit show at an already-open
    -- mailbox still closes with that mailbox (core.lua).
    ns:MailboxOpened()
    anchorToMail(f)
    f:Show()
    -- Refresh explicitly as well as via the frame's OnShow: OnShow does NOT fire when
    -- Show() is called on an already-shown frame, which is exactly the /conduit show
    -- case. Refresh is idempotent, so the two paths overlapping costs one redraw.
    Panel.Refresh()
end

function Panel.Hide()
    if frame then frame:Hide() end
end

ns:RegisterEvent("MAIL_SHOW", function() ns:SafeCall(Panel.Show) end)

-- …and again when the mail window is ACTUALLY on screen.
--
-- MAIL_SHOW is the server saying a mailbox was opened; FrameXML shows MailFrame from
-- its own handler for the same event, and the two handlers have no defined order. So
-- the Show above can run one beat BEFORE MailFrame:IsShown() becomes true — and the
-- boon row is drawn from Boons.State(), which reads exactly that. Landing on the
-- wrong side of that coin flip froze the row at "nomailbox" for the whole visit: a
-- greyed Replenish Boons button at a wide-open mailbox, panel reading "Ready.".
--
-- core.lua hooks MailFrame's OnShow (once) and fans out to the refreshers registered
-- here, so the answer is re-asked against observed visibility instead of inferred
-- visibility. Idempotent: on the ordering where MAIL_SHOW already read it correctly,
-- this is a second identical redraw.
ns:RegisterMailboxRefresher(function() Panel.Refresh() end)

-- The panel is furniture of the mail window, so it leaves when the window does —
-- every route out: walking away from the mailbox, Escape, the mail window's own
-- close button, or another UI panel taking its slot. core.lua owns the teardown
-- coordinator that funnels all of those into one call; registering here (rather
-- than listening for MAIL_CLOSED ourselves) also guarantees mail.lua's closer has
-- already aborted any in-flight batch and dismissed the confirm popup by the time
-- the panel goes, since closers run in load order and mail.lua loads first.
ns:RegisterMailboxCloser(function() Panel.Hide() end)
