--[[
    Daseeki Conduit — panel.lua

    The mailbox panel: a compact DaseekiUI-styled frame anchored beside the open
    mail window (shown on MAIL_SHOW, hidden on MAIL_CLOSED). It lists the
    configured rules with a per-rule Send button, a Run All button, a live
    progress line, and — during an active run — a "Send Next" button that drives
    each continuation mail (SendMail needs a hardware event, so the click is real).

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

local frame       -- the panel frame (lazy)
local rowPool = {}

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
    flatBacker(function(t)
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

    -- Top-right ✕ (BRAND_SPEC §8) — matches the hub/Nexus close treatment. ESC-close is
    -- wired via UISpecialFrames above. Closing only hides the panel; an in-progress run is
    -- left intact (reopen with /conduit show — see core.lua).
    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY")
    cx:SetFontObject(UI.fonts.body)
    cx:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
    cx:SetText("X")
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body) end)
    closeBtn:SetScript("OnClick", function() Panel.Hide() end)
    f.closeBtn = closeBtn

    -- Slash-command hint → uppercase letter-spaced micro-label (§3); stays faint (calm).
    -- Sits to the LEFT of the ✕ (created above); vertical offset preserves its original
    -- title-baseline alignment while clearing the close button.
    local hint = f:CreateFontString(nil, "OVERLAY")
    hint:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
    hint:SetPoint("TOPRIGHT", closeBtn, "LEFT", -4, 4)
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

    local prog = f:CreateFontString(nil, "OVERLAY")
    prog:SetFontObject(UI.fonts.small)
    prog:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD)
    prog:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
    prog:SetJustifyH("LEFT")
    prog:SetHeight(26)
    prog:SetWordWrap(true)
    UI.Skin(prog, function(self) self:SetTextColor(UI.Color("muted")) end)
    f.prog = prog

    frame = f
    return f
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
    anchorToMail(f)
    f:Show()
    Panel.Refresh()
end

function Panel.Hide()
    if frame then frame:Hide() end
end

ns:RegisterEvent("MAIL_SHOW", function() ns:SafeCall(Panel.Show) end)
ns:RegisterEvent("MAIL_CLOSED", function()
    -- mail.lua aborts any active run on MAIL_CLOSED; we just hide the panel.
    Panel.Hide()
end)
