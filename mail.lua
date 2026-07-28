--[[
    Daseeki Conduit — mail.lua

    The send engine. Turns a mail QUEUE (built by rules.lua) into actual mails,
    honouring the two hard constraints of Classic mail:

      1. SendMail() requires a HARDWARE EVENT (a real click). So the FIRST mail of
         a run is fired from the confirm popup's Accept handler (a hardware event),
         and each CONTINUATION mail is pre-attached on MAIL_SEND_SUCCESS and then
         sent by the player's click on the panel's "Send Next" button. This is the
         same proven pattern Daseeki Raid Prep uses.

      2. A mail carries at most 12 attachments (ATTACHMENTS_MAX_SEND). rules.lua
         has already split item stacks into <=12-attachment batches, one per mail.

    Every run is gated by a MANDATORY confirm-before-send popup showing a dry-run
    summary (items / gold / mail count + per-recipient breakdown). Nothing is
    attached or sent until Accept. Guards: recipient validation, no self-send,
    soulbound/quest/unmailable exclusion (rules.lua), never hijack an in-progress
    draft, and abort on mailbox close / mail failure / relevant UI error.
--]]

local ADDON, ns = ...

local Mail = {}
ns.Mail = Mail

local Rules = ns.Rules

-- ── Run state ─────────────────────────────────────────────────────────────────
local S = {
    active        = false,
    queue         = nil,   -- array of mail entries (item or gold)
    idx           = 0,     -- index of the mail currently in flight / just attached
    sentMails     = 0,
    sentItems     = 0,
    sentGold      = 0,
    awaitingClick = false, -- next mail pre-attached; waiting for a hardware click
    pendingCount  = 0,     -- attachments on the in-flight/prepared mail
    pendingGold   = 0,     -- copper on the in-flight/prepared mail
}

local function notifyPanel()
    if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
end

local function say(text)
    ns:Print(text)
end

-- ── Form helpers ──────────────────────────────────────────────────────────────

-- Refuse to touch a mail the user is already composing. We only ever run on a
-- pristine Send Mail form (no recipient/subject/body text, no attachments).
local function sendFormHasContent()
    local function nonEmpty(box)
        if not box or not box.GetText then return false end
        return ((box:GetText() or ""):match("^%s*(.-)%s*$")) ~= ""
    end
    if nonEmpty(SendMailNameEditBox)    then return true end
    if nonEmpty(SendMailSubjectEditBox) then return true end
    if nonEmpty(SendMailBodyEditBox)    then return true end
    if GetSendMailItem then
        for i = 1, (ns.MAX_ATTACH or 12) do
            if GetSendMailItem(i) then return true end
        end
    end
    -- Any gold already staged on the form counts as user content too.
    if GetSendMailMoney and (GetSendMailMoney() or 0) > 0 then return true end
    return false
end

-- Detach anything currently staged on the Send Mail form.
local function clearForm()
    ClearCursor()
    if GetSendMailItem then
        for i = 1, (ns.MAX_ATTACH or 12) do
            if GetSendMailItem(i) then
                ClickSendMailItemButton(i, "RightButton")  -- right-click detaches
            end
        end
    end
    if SetSendMailMoney then SetSendMailMoney(0) end
    if SendMailNameEditBox then SendMailNameEditBox:SetText("") end
    if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText("") end
end

-- Is the Send Mail tab available to send from? (edit boxes + frame present)
local function sendFrameReady()
    return SendMailFrame and SendMailFrame:IsShown()
        and SendMailNameEditBox and SendMailSubjectEditBox
end

-- Try to switch the mail window to the Send tab (not a hardware-gated action).
-- Wrapped defensively: a client that lays the tabs out differently must not error.
local function ensureSendTab()
    if SendMailFrame and SendMailFrame:IsShown() then return true end
    if _G.MailFrameTab_OnClick and _G.MailFrameTab2 then
        ns:SafeCall(_G.MailFrameTab_OnClick, _G.MailFrameTab2, 2)
    end
    return SendMailFrame and SendMailFrame:IsShown()
end

-- Attach one mail entry onto the (already cleared) Send Mail form. For item mails
-- each stack is re-verified against live bags (slots shift) and only attached if it
-- still matches and lands in an attachment slot. Sets recipient/subject, and money
-- for gold mails. Returns attachedCount (items) or true (gold). SendMail is NOT
-- called here — the caller fires it from a hardware event.
local function attachMail(mail)
    clearForm()
    local attached = 0

    if mail.stacks then
        local C = C_Container
        for _, st in ipairs(mail.stacks) do
            if attached >= (ns.MAX_ATTACH or 12) then break end
            local info = Rules.SlotInfo(st.bag, st.slot)
            -- The slot must still hold the SAME itemID and still be mailable.
            if info and info.itemID == st.itemID and Rules.IsMailable(info) then
                local nextSlot = attached + 1
                ClearCursor()
                if C and C.PickupContainerItem then C.PickupContainerItem(st.bag, st.slot) end
                if CursorHasItem() then
                    ClickSendMailItemButton(nextSlot)
                    -- Verify it actually landed; an item the server refuses (conjured,
                    -- etc.) is skipped rather than allowed to stall the batch.
                    if GetSendMailItem and GetSendMailItem(nextSlot) then
                        attached = nextSlot
                    else
                        ClearCursor()
                    end
                else
                    ClearCursor()
                end
            end
        end
    end

    if SendMailNameEditBox then SendMailNameEditBox:SetText(mail.recipient or "") end
    if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText(mail.subject or ns.MAIL_SUBJECT) end

    if mail.money and mail.money > 0 then
        if SetSendMailMoney then SetSendMailMoney(mail.money) end
        S.pendingGold = mail.money
    else
        S.pendingGold = 0
    end

    S.pendingCount = attached
    return mail.money and true or attached
end

-- ── Run control ───────────────────────────────────────────────────────────────

local function resetState()
    S.active, S.queue, S.idx = false, nil, 0
    S.awaitingClick, S.pendingCount, S.pendingGold = false, 0, 0
end

function Mail.IsActive() return S.active end
function Mail.IsAwaitingClick() return S.active and S.awaitingClick end

-- Human-readable progress line for the panel.
function Mail.Status()
    if not S.active then return nil end
    local total = S.queue and #S.queue or 0
    if S.awaitingClick then
        return ("Sent %d/%d. Click Send Next for the next mail."):format(S.sentMails, total)
    end
    return ("Sending %d/%d…"):format(math.min(S.sentMails + 1, total), total)
end

local function abort(reason)
    if not S.active then return end
    local sent = S.sentMails
    resetState()
    clearForm()
    if reason then
        say(("stopped: %s (%d mail(s) already sent)."):format(reason, sent))
    end
    notifyPanel()
end
Mail.Abort = abort

local function finish()
    local mails, items, gold = S.sentMails, S.sentItems, S.sentGold
    resetState()
    if mails > 0 then
        local goldStr = (gold > 0 and GetCoinTextureString) and (" and " .. GetCoinTextureString(gold)) or ""
        say(("done — sent %d mail(s), %d item(s)%s."):format(mails, items, goldStr))
    else
        say("nothing to send.")
    end
    notifyPanel()
end

-- Advance to the next queued mail. Called after a MAIL_SEND_SUCCESS. Pre-attaches
-- the next mail and arms the panel's Send-Next click (SendMail needs a hardware
-- event, so we can't auto-fire it). Skips any mail that attaches nothing.
local function armNext()
    while true do
        S.idx = S.idx + 1
        if not S.queue or S.idx > #S.queue then
            finish()
            return
        end
        local mail = S.queue[S.idx]
        local n = attachMail(mail)
        if (mail.money and mail.money > 0) or (type(n) == "number" and n > 0) then
            S.awaitingClick = true
            local total = #S.queue
            if mail.money and mail.money > 0 then
                say(("mail %d/%d ready: %s to %s. Click |cffffd200Send Next|r.")
                    :format(S.idx, total, GetCoinTextureString and GetCoinTextureString(mail.money) or (mail.money .. "c"), mail.recipient))
            else
                say(("mail %d/%d ready: %d item(s) to %s. Click |cffffd200Send Next|r.")
                    :format(S.idx, total, S.pendingCount, mail.recipient))
            end
            notifyPanel()
            return
        end
        -- Nothing attached (bags shifted): skip this mail and try the next.
    end
end

-- Send the currently prepared (pre-attached) mail. MUST be called from a hardware
-- event: the panel's Send-Next button OnClick, or the confirm popup's Accept.
local function fireCurrent()
    local mail = S.queue and S.queue[S.idx]
    if not mail then return end
    if not sendFrameReady() then
        abort("mailbox is no longer open")
        return
    end
    S.awaitingClick = false
    SendMail(mail.recipient, mail.subject or ns.MAIL_SUBJECT, "")
end

-- Panel calls this from its Send-Next button click (a hardware event).
function Mail.ContinueClick()
    if not (S.active and S.awaitingClick) then return end
    fireCurrent()
end

-- Begin a confirmed run. Called ONLY from the confirm popup's Accept (hardware
-- event) so the first SendMail is legal and the confirm gate can't be bypassed.
local function beginConfirmed(queue)
    if S.active then return end
    if type(queue) ~= "table" or #queue == 0 then return end
    if not sendFrameReady() then
        say("the Send Mail window is not open — nothing sent.")
        return
    end
    -- Re-check the form is still pristine (user may have started a draft while the
    -- popup was up).
    if sendFormHasContent() then
        say("the Send Mail form now has content — refusing to send. Clear it and try again.")
        return
    end

    S.active, S.queue, S.idx = true, queue, 1
    S.sentMails, S.sentItems, S.sentGold = 0, 0, 0
    S.awaitingClick = false

    local n = attachMail(queue[1])
    if not ((queue[1].money and queue[1].money > 0) or (type(n) == "number" and n > 0)) then
        -- First mail attached nothing (bags shifted): try to advance to a real one.
        S.idx = 0
        armNext()
        -- armNext sets awaitingClick; but we're already in a hardware event, so if a
        -- mail got armed we can fire it immediately.
        if S.active and S.awaitingClick then fireCurrent() end
        return
    end
    fireCurrent()
    notifyPanel()
end

-- ── Confirm popup (StaticPopup — its Accept is a guaranteed hardware event) ────
StaticPopupDialogs["DASEEKI_CONDUIT_SEND_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = CANCEL,
    OnAccept = function(_, data)
        if data and data.queue then beginConfirmed(data.queue) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true,
    preferredIndex = 3,  -- avoid taint from the default StaticPopup pool
}

-- Build the dry-run summary text for the popup from a summary table.
local function summaryText(summary, mailCount, skipped)
    local lines = {}
    lines[#lines + 1] = ("Send |cffffd200%d|r mail(s)?"):format(mailCount)
    lines[#lines + 1] = ""
    if summary.itemCount > 0 then
        lines[#lines + 1] = ("Items:  |cffffffff%d|r"):format(summary.itemCount)
    end
    if summary.goldCopper > 0 then
        local g = GetCoinTextureString and GetCoinTextureString(summary.goldCopper) or (summary.goldCopper .. "c")
        lines[#lines + 1] = ("Gold:   %s"):format(g)
    end
    -- Per-recipient breakdown (compact).
    local recips = {}
    for name in pairs(summary.byRecipient) do recips[#recips + 1] = name end
    table.sort(recips)
    if #recips > 0 then
        lines[#lines + 1] = ""
        for _, name in ipairs(recips) do
            local r = summary.byRecipient[name]
            local parts = {}
            if r.items > 0 then parts[#parts + 1] = r.items .. " item(s)" end
            if r.gold  > 0 then parts[#parts + 1] = (GetCoinTextureString and GetCoinTextureString(r.gold) or (r.gold .. "c")) end
            lines[#lines + 1] = ("|cffffd200%s|r  <-  %s  (%d mail)"):format(name, table.concat(parts, " + "), r.mails)
        end
    end
    if skipped and #skipped > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("|cff9a8f79%d rule(s) skipped (nothing to send / bad recipient).|r"):format(#skipped)
    end
    return table.concat(lines, "\n")
end

-- ── Public entry points (called by the panel) ────────────────────────────────

-- Start a run for a specific list of rules (single rule, or all enabled). Builds
-- the queue, runs the guards, and shows the mandatory confirm popup. Returns
-- true if a popup was shown, false + reason otherwise.
function Mail.RunForRules(rules)
    if S.active then
        say("already sending — finish or close the mailbox first.")
        return false, "busy"
    end
    if ns:IsCharDisabled() then
        say("Conduit is disabled on this character (/conduit enable to turn on).")
        return false, "disabled"
    end
    if not ensureSendTab() then
        say("open a mailbox and the Send Mail tab first.")
        return false, "no mailbox"
    end
    if sendFormHasContent() then
        say("the Send Mail form already has a recipient, subject, body, or attachment. Clear it first.")
        return false, "draft"
    end

    local me = UnitName and UnitName("player") or ""
    local money = GetMoney and GetMoney() or 0
    local queue, summary, skipped = Rules.BuildMailQueue(rules, {
        me = me, money = money,
        maxAttach = ns.MAX_ATTACH, postageBuffer = ns.POSTAGE_BUFFER,
        subject = ns.MAIL_SUBJECT,
    })

    if #queue == 0 then
        local reason = (skipped and #skipped > 0) and skipped[1].reason or "no matching items or gold to send"
        say("nothing to send — " .. reason .. ".")
        return false, "empty"
    end

    -- The dialog's text is "%s"; StaticPopup_Show substitutes arg1 into it, so the
    -- assembled dry-run block becomes the popup body.
    local text = summaryText(summary, #queue, skipped)
    StaticPopup_Show("DASEEKI_CONDUIT_SEND_CONFIRM", text, nil, { queue = queue })
    return true
end

-- Run every enabled rule.
function Mail.RunAll()
    local db = ns.db
    return Mail.RunForRules(db and db.rules or {})
end

-- Run a single rule by id.
function Mail.RunRule(id)
    local rule = Rules.FindById(id)
    if not rule then return false, "no such rule" end
    return Mail.RunForRules({ rule })
end

-- ── Mail events drive the batch loop ──────────────────────────────────────────

-- Locale-correct set of mail errors that should abort a run. Built from the game's
-- own globals so an UNRELATED red error (a spell failure, etc.) never cancels a run.
local ABORT_ERRORS = {}
do
    local names = {
        "ERR_MAIL_TO_SELF", "ERR_MAIL_TARGET_NOT_FOUND", "ERR_MAIL_DATABASE_ERROR",
        "ERR_MAIL_REACHED_CAP", "ERR_MAIL_INVALID_ATTACHMENT_SLOT",
        "ERR_MAIL_ATTACHMENT_INVALID", "ERR_MAIL_ATTACHMENT_EXPIRED",
        "ERR_MAIL_LOCKED_CONTAINER", "ERR_MAIL_BOUND_ITEM", "ERR_MAIL_CONJURED_ITEM",
        "ERR_MAIL_BAG", "ERR_MAIL_QUEST_ITEM", "ERR_MAIL_WRAPPED_COD",
        "ERR_NOT_ENOUGH_MONEY", "ERR_ITEM_NOT_FOUND",
    }
    for _, n in ipairs(names) do
        local s = _G[n]
        if type(s) == "string" and s ~= "" then ABORT_ERRORS[s] = true end
    end
end

ns:RegisterEvent("MAIL_SEND_SUCCESS", function()
    if not S.active then return end
    S.sentMails = S.sentMails + 1
    S.sentItems = S.sentItems + (S.pendingCount or 0)
    S.sentGold  = S.sentGold  + (S.pendingGold or 0)
    S.pendingCount, S.pendingGold = 0, 0
    armNext()
end)

ns:RegisterEvent("MAIL_FAILED", function()
    if S.active then abort("mail failed — check the recipient name and your gold") end
end)

ns:RegisterEvent("MAIL_CLOSED", function()
    if S.active then abort("mailbox closed") end
end)

ns:RegisterEvent("UI_ERROR_MESSAGE", function(_, arg1, arg2)
    if not S.active then return end
    local msg = (type(arg2) == "string" and arg2) or (type(arg1) == "string" and arg1) or nil
    if msg and ABORT_ERRORS[msg] then abort(msg) end
end)
