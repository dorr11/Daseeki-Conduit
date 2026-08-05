--[[
    Daseeki Conduit — mail.lua

    The send engine. Turns a mail QUEUE (built by rules.lua or boons.lua) into
    actual mails: preview -> ONE Accept -> the whole run, hands-free.

    ── What changed in 1.2.0, and why ────────────────────────────────────────────

    1) SENDMAIL DOES NOT NEED A HARDWARE EVENT. The old engine believed it did and
       therefore asked the player to click "Send Next" once per mail. That belief is
       wrong on Classic Era 11509: ClearSendMail, SetSendMailMoney and SendMail are
       all insecure, and a batch mailer can drive N sends from timer and event
       callbacks many frames removed from the originating click. So one Accept now
       runs the entire queue. The per-click stepping survives as a SETTING for
       anyone who wants to watch each mail go.

    2) THE ATTACH IS VERIFIED AGAINST THE PLAN, AND THE SEND IS REFUSED IF THEY
       DISAGREE. See attachMail and verifyAttach below. This is the fix for the live
       over-attach: a mail the plan sized at SEVEN arrived at the Send Mail form
       carrying two whole stacks of ten.

    ── The pacing contract (one mail in flight, strictly) ────────────────────────

    Send N+1 begins only when send N reaches a terminal state, and a terminal state
    needs TWO signals, not one:

      * the ACK — MAIL_SUCCESS. (Not MAIL_SEND_SUCCESS: on this client both exist
        and MAIL_SUCCESS is the one that resolves a send reliably. The old engine
        keyed on MAIL_SEND_SUCCESS, which is also a plausible source of the
        "Sent 2/8" counter running ahead of the mails that had actually gone.)
      * the EVIDENCE — proof the mail cost what it should have. For a gold mail
        that is the money delta (before - amount - postage). For an ITEM mail there
        is no money delta at all, so waiting on PLAYER_MONEY would stall every
        single send: the analogue is that the attachments actually LEFT THE BAGS,
        which we watch for on BAG_UPDATE_DELAYED.

    Ceilings: 15s for the ack, a further 15s for the evidence. On either timeout the
    in-flight latch is CLEARED and the run stops cleanly with a report — never
    latched until reload, which is the single worst failure mode in this design
    space. Every terminal path clears the latch; that is not negotiable.

    Spacing: none on the happy path (the round trip IS the throttle). A flat 0.5s
    after failures only, to separate a failed attempt's server state from the next
    ClearSendMail.

    Retries: ONE per mail, counted exactly once, and only for failures that happen
    BEFORE the ack — after an ack the mail may well have gone, so a second attempt
    could double-send. Past the budget the recipient is skipped with a line and the
    run continues; it does not abort the remaining nine mails over one bad name.

    Blizzard re-enables its own Send button on its internal mail-frame updates,
    which fire while a send is in flight, so a one-shot disable does not stick. We
    re-assert it on a 0.2s repeating ticker for the life of the send and release it
    at the terminal state. It looks arbitrary; it is load-bearing.

    Mailbox closed mid-run is a HARD ABORT that actually returns. Not a warning
    followed by a send into a closed mailbox.

    ── Still true from 1.0 ───────────────────────────────────────────────────────

    THIS IS THE ONLY SEND PATH IN THE ADDON. A feature that mails something builds a
    QUEUE and hands it to Mail.RunQueue with its own dry-run text; it does not touch
    SendMail, the attachment slots, or the confirm popup. Every run is gated by the
    mandatory confirm-before-send popup. A mail carries at most 12 attachments.
--]]

local ADDON, ns = ...

local Mail = {}
ns.Mail = Mail

local Rules = ns.Rules

-- Timings (seconds). Named, because every one of them is a decision.
local ACK_TIMEOUT      = 15      -- server acknowledges the send
local EVIDENCE_TIMEOUT = 15      -- the money/bags actually move
local FAILURE_SPACING  = 0.5     -- ONLY after a failure; the happy path is unpadded
local BUTTON_HOLD      = 0.2     -- re-assert Blizzard's disabled Send button
local RETRY_BUDGET     = 1       -- one retry per mail, then skip that recipient
local SETTLE_TIMEOUT   = 1.0     -- ceiling on waiting for the bags to stop moving
-- The measurement gets a longer rope than the settle. It is waiting on the client
-- to WRITE numbers it has already decided, which on a loaded machine can trail the
-- lock release by a good deal; and the cost of waiting is a pause, while the cost of
-- measuring early is a refused mail. The 15s ack ceiling is the real backstop.
local MEASURE_TIMEOUT  = 3.0

-- ── Run state ─────────────────────────────────────────────────────────────────
local S = {
    active        = false,
    runId         = 0,     -- bumped on every stop; see `thisRun` below
    queue         = nil,   -- array of mail entries (item or gold)
    idx           = 0,     -- index of the mail currently armed / in flight
    sentMails     = 0,
    sentItems     = 0,
    sentGold      = 0,
    sentUnits     = 0,     -- ITEMS, counted as units rather than as attachments
    skipped       = nil,   -- { { recipient, reason }, ... }

    -- single-flight
    inFlight      = false, -- a SendMail is out and unresolved
    acked         = false, -- the ack arrived; we are waiting on evidence
    token         = 0,     -- invalidates callbacks from a send we have moved past
    awaitingClick = false, -- step mode only: armed and waiting for a real click

    attempts      = 0,     -- failures charged to the CURRENT mail (see RETRY_BUDGET)
    stopping      = false, -- Stop pressed: finish the in-flight mail, then halt

    pendingCount  = 0,     -- attachments the FORM reports on the armed mail
    pendingUnits  = 0,     -- units inside those attachments, read back off the FORM
    pendingGold   = 0,     -- copper staged on the armed mail

    evidence      = nil,   -- pre-send snapshot; see snapshotEvidence
    ackTimer      = nil,
    evTimer       = nil,
    holdTicker    = nil,

    settleWaiter  = nil,   -- pending "wait for the bags to stop moving" request
    settleTimer   = nil,

    armMail       = nil,   -- the mail between "attached" and "verified"
    armIds        = nil,   -- itemIDs its draws touch
    armBefore     = nil,   -- bag total for those ids BEFORE the attach
    armQuiet      = nil,

    traceDraws    = nil,   -- per-draw observations for the attempt being armed
    traceEntry    = nil,   -- the stored trace row, so a later send can amend it

    onFinish      = nil,   -- optional per-run completion callback (see RunQueue)
    rebuild       = nil,   -- optional: re-derive the queue at run start
    check         = nil,   -- optional: re-check ONE mail against live truth
}

-- ── Attach diagnostics ────────────────────────────────────────────────────────
--
-- The live failure this file's 1.2.1 pass exists for could not be diagnosed from
-- chat: every mail simply refused with "the form holds 0". These counters make the
-- client's actual behaviour visible through /conduit debug boons, so the next
-- surprise is a report rather than a mystery. Session-cumulative, in memory only.
local D = {
    mails            = 0,   -- mails armed
    redrawn          = 0,   -- mails whose draws were re-derived from a fresh scan
    staleCoords      = 0,   -- plan-time slots that no longer held the item
    splitAttempted   = 0,
    splitDelivered   = 0,   -- C_Container.SplitContainerItem put it on the cursor
    splitAsync       = 0,   -- ...took it from the slot but not onto the cursor
    splitFellBack    = 0,   -- the legacy global delivered instead
    splitFailed      = 0,   -- nothing delivered
    lockedSlots      = 0,   -- draws skipped because the slot was mid-operation
    drawsRefused     = 0,
    formUnreadable   = 0,   -- GetSendMailItem would not yield a usable count
    formBagDisagree  = 0,   -- the form and the bag subtraction did not match
    decalibrations   = 0,   -- ...and the form's calibration was thrown away for it
    formVetoDropped  = 0,   -- a form total that disagreed was ignored, not obeyed
    settleWaits      = 0,
    settleTimeouts   = 0,
}
function Mail.Diagnostics() return D end
function Mail.ResetDiagnostics() for k in pairs(D) do D[k] = 0 end end

local function notifyPanel()
    if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
end

local function say(text)
    ns:Print(text)
end

-- ── Timers ────────────────────────────────────────────────────────────────────
-- Resolved through _G at CALL time so a headless harness can install a virtual
-- clock. The cancelled flag is what makes cancellation correct even on a client
-- that only offers the un-cancellable C_Timer.After.

local function newTimer(sec, fn)
    local h = { cancelled = false }
    function h:Cancel() self.cancelled = true; if self._t and self._t.Cancel then self._t:Cancel() end end
    local T = _G.C_Timer
    if T and T.NewTimer then
        h._t = T.NewTimer(sec, function() if not h.cancelled then fn() end end)
    elseif T and T.After then
        T.After(sec, function() if not h.cancelled then fn() end end)
    end
    return h
end

local function newTicker(sec, fn)
    local h = { cancelled = false }
    function h:Cancel() self.cancelled = true; if self._t and self._t.Cancel then self._t:Cancel() end end
    local T = _G.C_Timer
    if T and T.NewTicker then
        h._t = T.NewTicker(sec, function() if not h.cancelled then fn() end end)
    end
    return h
end

local function cancel(h) if h then h:Cancel() end return nil end

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

-- Is attachment slot `i` occupied?
local function slotAttached(i)
    return (GetSendMailItem and GetSendMailItem(i)) and true or false
end

-- ── Reading the quantity back off the Send Mail form ─────────────────────────
--
-- The form is the thing being sent, so the form is what the send guard should be
-- measuring. The wrinkle: GetSendMailItem carries no signature in the 11509 API
-- catalog (it is an undocumented FrameXML-era global — the catalog lists the name
-- and nothing else), and its return ORDER has differed across clients. Hard-coding
-- "the fourth return is the count" would be a guess, and a wrong guess here reads
-- an item quality as a stack size.
--
-- So the position is CALIBRATED instead of assumed. The bag subtraction (how much
-- left the slot we drew from) is a fact we already have and cannot be wrong about;
-- the first draw that lands unambiguously tells us which return position carried
-- that same number, and from then on the FORM is the authority and the bag
-- subtraction is a cross-check whose disagreements are counted.
local formCountIndex   -- nil until calibrated

local function formReturns(i)
    if not GetSendMailItem then return nil end
    local r = { GetSendMailItem(i) }
    if r[1] == nil then return nil end
    return r
end

-- Learn which return position holds the stack count, given a landing we KNOW the
-- size of. Only accepts an unambiguous answer (exactly one position matching).
local function calibrateFormCount(i, known)
    if formCountIndex or not known or known < 1 then return end
    local r = formReturns(i)
    if not r then return end
    local at
    for idx = 1, 6 do
        if tonumber(r[idx]) == known then
            if at then return end        -- ambiguous; wait for a clearer landing
            at = idx
        end
    end
    if at then formCountIndex = at end
end

-- THE CALIBRATION IS A GUESS, AND A GUESS MUST BE ABLE TO BE WRONG.
--
-- A calibration that turns out to disagree with a bag delta is not evidence that
-- the world is wrong; it is evidence that the calibration is. Before this existed,
-- one bad index — learned once, held for the whole session, never revisited —
-- silently turned every subsequent measurement into a number that could not match
-- what was asked for, and therefore turned every mail into "the form holds 0". A
-- session that calibrated badly stayed broken until the player reloaded, which is
-- precisely the shape of a failure that reproduces identically on retest.
--
-- So: the bag delta is the fact, the form read is the corroboration, and when they
-- disagree the corroboration is discarded and re-learned.
local function decalibrateFormCount()
    formCountIndex = nil
end

-- Units the form reports in slot `i`, or nil if we cannot read it yet.
local function formCount(i)
    if not formCountIndex then return nil end
    local r = formReturns(i)
    if not r then return nil end
    return tonumber(r[formCountIndex])
end

-- Total units the form reports across every attachment slot, or nil.
local function formTotal()
    if not formCountIndex then return nil end
    local total = 0
    for i = 1, (ns.MAX_ATTACH or 12) do
        if slotAttached(i) then
            local c = formCount(i)
            if not c then return nil end
            total = total + c
        end
    end
    return total
end
Mail._FormCalibration = function() return formCountIndex end   -- harness seam

-- Does the form hold any attachment at all?
local function formHasAttachment()
    for i = 1, (ns.MAX_ATTACH or 12) do
        if slotAttached(i) then return true end
    end
    return false
end

-- Take an attachment back off the form. FrameXML itself passes 1 (a number) for
-- the "clear this slot" argument, so we pass 1 too — a string like "RightButton"
-- reads as a click, not a clear, on any binding that takes the argument
-- numerically, and a clear that silently does not clear is how a form accumulates.
local function detach(i)
    if ClickSendMailItemButton then ClickSendMailItemButton(i, 1) end
end

-- Detach anything currently staged on the Send Mail form. Returns true when the
-- form is verifiably empty afterwards.
local function clearForm()
    ClearCursor()
    local clean = true
    if GetSendMailItem then
        for i = 1, (ns.MAX_ATTACH or 12) do
            if GetSendMailItem(i) then detach(i) end
        end
        ClearCursor()
        for i = 1, (ns.MAX_ATTACH or 12) do
            if GetSendMailItem(i) then clean = false end
        end
    end
    if SetSendMailMoney then SetSendMailMoney(0) end
    if SendMailNameEditBox then SendMailNameEditBox:SetText("") end
    if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText("") end
    return clean
end

-- Is the Send Mail tab available to send from? (edit boxes + frame present)
local function sendFrameReady()
    return SendMailFrame and SendMailFrame:IsShown()
        and SendMailNameEditBox and SendMailSubjectEditBox
end

-- Try to switch the mail window to the Send tab (not a hardware-gated action).
local function ensureSendTab()
    if SendMailFrame and SendMailFrame:IsShown() then return true end
    if _G.MailFrameTab_OnClick and _G.MailFrameTab2 then
        ns:SafeCall(_G.MailFrameTab_OnClick, _G.MailFrameTab2, 2)
    end
    return SendMailFrame and SendMailFrame:IsShown()
end

-- Units of the given items across every bag slot. Defined here rather than beside
-- the evidence code because the ATTACH's authoritative measurement is the same
-- arithmetic — see verifyAndFire.
local function bagUnitsFor(idSet)
    local C = C_Container
    if not (C and C.GetContainerNumSlots and Rules) then return 0 end
    local total = 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local n = C.GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local info = Rules.SlotInfo(bag, slot)
            if info and idSet[info.itemID] then total = total + (tonumber(info.count) or 0) end
        end
    end
    return total
end

local function idSetOf(stacks)
    local ids = {}
    for _, st in ipairs(stacks or {}) do
        if st.itemID then ids[st.itemID] = true end
    end
    return ids
end

-- ── The attach, and the reason this file was reopened ─────────────────────────
--
-- THE BUG THIS REPLACES. The old attach decided how many units it WANTED, called
-- split-or-pickup, checked only that the attachment slot had become non-empty, and
-- then asserted `units = units + want`. It never asked the form how much had
-- actually landed. Two consequences, and the live report was both at once:
--
--   * the same function contained an explicit `want = have` in the branch taken
--     whenever the split path was not used — turning a PARTIAL draw into a
--     WHOLE-STACK pickup. A seven-unit top-up drawn across two slots became two
--     whole stacks of ten;
--   * and because the accounting came from the plan rather than from the form,
--     S.pendingUnits still read seven. Nothing downstream could notice, so SendMail
--     fired on a form the engine had never looked at.
--
-- THE RULE NOW: the only number that counts is the one the WORLD moved — how much
-- actually left the bag slot — and a draw that does not move EXACTLY what was asked
-- for is put straight back. There is no rounding up. A top-up that cannot be split
-- exactly sends nothing rather than sending a whole stack: leaving boons behind is
-- recoverable, posting ten of them to the wrong character is not.
--
-- The measurement is deliberately a subtraction on the bag slot rather than a read
-- of the attachment's own fields. It needs no assumption about which return of
-- GetSendMailItem carries the stack count, and it cannot be fooled by a client that
-- reports one thing and does another.
--
-- Sets S.pendingCount / S.pendingUnits / S.pendingGold from the FORM, and returns
-- attached, units, refused (refused = a draw the form would not honour exactly).
-- Get `want` units out of (bag, slot) onto the cursor, or fail honestly.
--
-- THE 11509 FACTS, from the API catalog (build 1.15.9.68808):
--   * C_Container.SplitContainerItem(bag, slot, amount) EXISTS. The 1.2.0 theory
--     that the whole-stack fallback was firing because the function was missing is
--     therefore dead — the function is there, so any failure is one of DELIVERY,
--     not of absence.
--   * there is NO bare SplitContainerItem/PickupContainerItem global on this
--     client, so the "fall back to the legacy global" belt-and-braces below has
--     nothing to catch it here. It is kept for other clients and, more usefully,
--     so the diagnostics can say which door actually opened.
--
-- Delivery has three distinguishable outcomes, and telling them apart is the whole
-- point — two of them look identical from the cursor alone:
--   DELIVERED  the cursor holds it. Proceed.
--   ASYNC      the cursor is empty but the SLOT SHRANK: the split happened, the
--              client just has not handed it over yet. Calling split again here
--              would take a SECOND helping. So: take nothing, and let the
--              settlement wait re-read the world before the retry.
--   NOTHING    cursor empty and the slot untouched — a genuine no-op (a locked
--              slot is the common cause). Safe to try the legacy door.
local function pickupExactly(bag, slot, want, have)
    local C = C_Container
    ClearCursor()

    if want >= have then
        if C and C.PickupContainerItem then C.PickupContainerItem(bag, slot) end
        if CursorHasItem() then return "delivered", "pickup" end
        if _G.PickupContainerItem then _G.PickupContainerItem(bag, slot) end
        return (CursorHasItem() and "fellback" or "nothing"), "pickup-legacy"
    end

    D.splitAttempted = D.splitAttempted + 1
    if C and C.SplitContainerItem then
        C.SplitContainerItem(bag, slot, want)
        if CursorHasItem() then
            D.splitDelivered = D.splitDelivered + 1
            return "delivered", "split"
        end
        local after = Rules.SlotInfo(bag, slot)
        local left  = (after and after.count) or 0
        if left < have then
            -- It left the slot but not onto the cursor. Do NOT ask again.
            D.splitAsync = D.splitAsync + 1
            return "async", "split"
        end
    end
    if _G.SplitContainerItem then
        _G.SplitContainerItem(bag, slot, want)
        if CursorHasItem() then
            D.splitFellBack = D.splitFellBack + 1
            return "fellback", "legacy"
        end
    end
    D.splitFailed = D.splitFailed + 1
    return "nothing", "split"
end

-- `draws` overrides mail.stacks when the caller has re-derived them from a fresh
-- bag scan (which armCurrent does for every mail that names an itemID + units).
local function attachMail(mail, draws)
    clearForm()
    local attached, units, refused = 0, 0, 0
    local stacks = draws or mail.stacks
    -- The trace for THIS attempt. Filled as we go, handed to armCurrent, and
    -- written to SavedVariables with whatever verdict the attempt reaches.
    local T = { draws = {} }
    S.traceDraws = T

    if stacks then
        local C = C_Container
        for _, st in ipairs(stacks) do
            if attached >= (ns.MAX_ATTACH or 12) then break end
            local info = Rules.SlotInfo(st.bag, st.slot)
            local td = { bag = st.bag, slot = st.slot, want = tonumber(st.count),
                         exact = st.exact and true or false,
                         pre = info and tonumber(info.count) or 0,
                         locked = info and info.isLocked or false }
            T.draws[#T.draws + 1] = td
            if not (info and info.itemID == st.itemID) then
                -- The coordinates went stale under us. With re-derived draws this
                -- should not happen; counting it says whether it still does.
                D.staleCoords = D.staleCoords + 1
                td.path, td.outcome = "skip", "stale-slot"
            elseif info.isLocked then
                -- Mid-operation. Container calls against this slot are refused
                -- silently, so asking would only produce a mystery.
                D.lockedSlots = D.lockedSlots + 1
                refused = refused + 1
                td.path, td.outcome = "skip", "locked"
            elseif Rules.IsMailable(info) then
                local have = tonumber(info.count) or 0
                -- A descriptor carrying `exact` sends its `count` and NO MORE; one
                -- without it means "all of this stack" (a rule saying "send my
                -- herbs" means all of them). The ask is only ever clamped DOWN to
                -- what the slot really holds.
                local want = have
                if st.exact then
                    want = tonumber(st.count) or 0
                    if want > have then want = have end
                end

                if want >= 1 then
                    local nextSlot = attached + 1
                    td.want = want
                    local outcome, path = pickupExactly(st.bag, st.slot, want, have)
                    td.path, td.outcome = path, outcome
                    td.cursor = CursorHasItem and CursorHasItem() or false

                    if outcome == "delivered" or outcome == "fellback" then
                        ClickSendMailItemButton(nextSlot)
                        td.click, td.formSlot = true, nextSlot
                        -- WHAT FOLLOWS IS OBSERVATION, NOT JUDGEMENT.
                        --
                        -- Re-reading the bag slot HERE, one statement after the
                        -- click, asks the client for a number it has not written
                        -- yet: this client defers container updates to its next bag
                        -- event (which is exactly why the arm has to wait for one),
                        -- and a deferred COUNT reads back as the pre-split value. An
                        -- immediate `have - left` therefore measures ZERO on a draw
                        -- that worked perfectly, and judging the draw on it refuses
                        -- every mail — instantly, on quiet bags, first mail included.
                        --
                        -- So these numbers are recorded for the trace and nothing
                        -- else. The quantity that decides whether this mail may fly
                        -- is measured ONCE, for the whole mail, AFTER the bags have
                        -- flushed — see verifyAndFire.
                        -- TWO MEASUREMENTS, and the bag one is the FACT.
                        --   the BAGS — how much left the slot we drew from. This is
                        --     arithmetic on a value the client already gave us and
                        --     it cannot be misread.
                        --   the FORM — what the send slot reports. Corroboration,
                        --     and only once its shape has been worked out.
                        -- When they disagree the CALIBRATION is what is wrong, so it
                        -- is thrown away and re-learned rather than being allowed to
                        -- veto a draw. That veto is what turned one bad guess into a
                        -- session where every mail read "the form holds 0".
                        local after  = Rules.SlotInfo(st.bag, st.slot)
                        local left   = (after and after.itemID == st.itemID)
                                       and (tonumber(after.count) or 0) or 0
                        local viaBag = have - left
                        td.post   = left
                        td.viaBag = viaBag
                        calibrateFormCount(nextSlot, viaBag)
                        local viaForm = formCount(nextSlot)
                        td.cal     = formCountIndex
                        td.viaForm = viaForm
                        td.raw     = formReturns(nextSlot)
                        if viaForm == nil then D.formUnreadable = D.formUnreadable + 1 end
                        if viaForm ~= nil and viaForm ~= viaBag then
                            D.formBagDisagree = D.formBagDisagree + 1
                            D.decalibrations  = D.decalibrations + 1
                            decalibrateFormCount()
                            td.outcome = (td.outcome or "") .. "+recalibrate"
                            viaForm = nil
                        end
                        if slotAttached(nextSlot) then
                            -- It is ON THE FORM. That much is observable right now
                            -- and needs no deferred number to confirm.
                            attached = nextSlot
                            units    = units + want
                        else
                            -- Nothing landed — an item the server refuses (conjured,
                            -- and so on). It does not travel.
                            ClearCursor()
                            refused = refused + 1
                            td.outcome = (td.outcome or "") .. "+not-on-form"
                        end
                    else
                        -- "async" (already taken from the slot, cursor not yet) or
                        -- "nothing". Either way this draw does not travel now; the
                        -- settlement wait before the retry is what makes the second
                        -- attempt see a world that has stopped moving.
                        ClearCursor()
                        refused = refused + 1
                        td.click = false
                    end
                end
            end
        end
    end
    if refused > 0 then D.drawsRefused = D.drawsRefused + refused end

    if SendMailNameEditBox then SendMailNameEditBox:SetText(mail.recipient or "") end
    if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText(mail.subject or ns.MAIL_SUBJECT) end

    if mail.money and mail.money > 0 then
        if SetSendMailMoney then SetSendMailMoney(mail.money) end
        S.pendingGold = (GetSendMailMoney and GetSendMailMoney()) or mail.money
    else
        S.pendingGold = 0
    end

    S.pendingCount = attached
    S.pendingUnits = units
    return attached, units, refused
end

-- THE GUARD. Nothing is sent until what the form holds matches what the plan asked
-- for. A boon top-up mail may never exceed its plan; on a disagreement the mail is
-- refused in plain language and the run re-arms or skips — it never sends.
--
-- Returns ok, reason.
-- `moved` is the units that LEFT THE BAGS across this whole attach, measured after
-- the client flushed its container updates. It is the authority: it is arithmetic
-- on two totals the client itself reported, taken at moments when the client had
-- finished writing them.
local function verifyAttach(mail, moved)
    local planned = tonumber(mail.units)
    if planned and moved ~= nil and moved ~= planned then
        return false, ("%s's mail should carry %d %s but %d left your bags — not sending it.")
            :format(tostring(mail.recipient), planned, mail.unitLabel or "item(s)", moved)
    end
    if planned and moved == nil and S.pendingUnits ~= planned then
        return false, ("%s's mail should carry %d %s but the form holds %d — not sending it.")
            :format(tostring(mail.recipient), planned,
                    mail.unitLabel or "item(s)", S.pendingUnits)
    end
    if mail.stacks and not planned and S.pendingCount < 1 then
        return false, ("nothing would attach for %s."):format(tostring(mail.recipient))
    end
    local money = tonumber(mail.money) or 0
    if money > 0 and (S.pendingGold or 0) ~= money then
        return false, ("%s's mail should carry %s but the form holds %s — not sending it.")
            :format(tostring(mail.recipient),
                    GetCoinTextureString and GetCoinTextureString(money) or (money .. "c"),
                    GetCoinTextureString and GetCoinTextureString(S.pendingGold or 0) or ((S.pendingGold or 0) .. "c"))
    end
    if mail.stacks and S.pendingCount > (ns.MAX_ATTACH or 12) then
        return false, ("%s's mail has more attachments than a mail can carry — not sending it.")
            :format(tostring(mail.recipient))
    end
    -- THE FORM CORROBORATES; IT DOES NOT VETO.
    --
    -- Everything above compares the plan against measurements the engine made by
    -- SUBTRACTION on the bags — arithmetic on numbers the client already handed
    -- over, which cannot be misread. This last check asks the send slots what they
    -- think they are holding, which is a different and weaker kind of evidence: the
    -- position of the count in GetSendMailItem's returns is undocumented on 11509
    -- and has to be inferred.
    --
    -- So a disagreement here means the INFERENCE is wrong, not that the mail is.
    -- Treating it as a refusal is what let one bad guess, learned once and held for
    -- the whole session, turn every subsequent mail into "the form holds 0" — a
    -- failure that survives a retest because nothing ever revisits the guess.
    -- Throw the guess away, record it, and let the bag arithmetic stand.
    local onForm = formTotal()
    S.traceFormSum = onForm
    if planned and onForm ~= nil and onForm ~= planned then
        D.formVetoDropped = D.formVetoDropped + 1
        D.decalibrations  = D.decalibrations + 1
        decalibrateFormCount()
    end
    return true
end
Mail._VerifyAttach = verifyAttach   -- harness seam (mutation-checked)

-- ── Evidence ──────────────────────────────────────────────────────────────────
--
-- The second of the two signals a send needs. A pure-item mail moves no money, so
-- the money-delta test does not generalise: for items the analogue is that the
-- attachments left the bags.

-- The snapshot is taken at FIRE time, with the attachments already staged. Bag
-- totals therefore already exclude them, and the two things that can happen next
-- are distinguishable without counting anything on the form:
--
--   the mail GOES     -> the client empties the attachment slots, bags unchanged
--   the mail FAILS    -> the attachments stay on the form, or come back to the bags
--
-- so "the form is empty and the units did not come back" is the whole test.
local function snapshotEvidence(mail)
    if (tonumber(mail.money) or 0) > 0 then
        return { kind = "gold", money = (GetMoney and GetMoney()) or 0,
                 amount = tonumber(mail.money) or 0 }
    end
    local ids = {}
    for _, st in ipairs(mail.stacks or {}) do
        if st.itemID then ids[st.itemID] = true end
    end
    return { kind = "items", ids = ids, bags = bagUnitsFor(ids), units = S.pendingUnits or 0 }
end

-- Has the world moved the way a completed send would have moved it?
--   returns true (confirmed) | false (contradicted) | nil (not yet)
local function evidenceSatisfied(ev)
    if not ev then return true end
    if ev.kind == "gold" then
        local now = (GetMoney and GetMoney()) or 0
        local postage = ns.POSTAGE_PER_MAIL or 30
        if now == ev.money - ev.amount - postage then return true end
        -- A tolerance, not exact equality: a vendor sale or a quest reward landing
        -- in the same tick is not evidence the mail failed. "Went down by at least
        -- the amount we sent" is the assertion that actually means something.
        if now <= ev.money - ev.amount then return true end
        if now < ev.money then return nil end   -- money moved, but not far enough yet
        return nil
    end
    if (ev.units or 0) <= 0 then return true end
    if formHasAttachment() then return nil end                 -- still staged
    if bagUnitsFor(ev.ids or {}) > (ev.bags or 0) then return nil end  -- came back
    return true
end

-- ── Run control ───────────────────────────────────────────────────────────────

local function clearTimers()
    S.ackTimer   = cancel(S.ackTimer)
    S.evTimer    = cancel(S.evTimer)
end

local function releaseSendButton()
    S.holdTicker = cancel(S.holdTicker)
    local b = _G.SendMailMailButton
    if b and b.Enable then ns:SafeCall(function() b:Enable() end) end
end

local function holdSendButton()
    local b = _G.SendMailMailButton
    if b and b.Disable then ns:SafeCall(function() b:Disable() end) end
    S.holdTicker = cancel(S.holdTicker)
    S.holdTicker = newTicker(BUTTON_HOLD, function()
        local bb = _G.SendMailMailButton
        if bb and bb.Disable then bb:Disable() end
    end)
end

-- Drop everything belonging to the send that is (or was) in flight. EVERY terminal
-- path goes through here first, before any branching — that is what makes the
-- design single-flight safe, and what guarantees the latch can never survive a
-- timeout into the next run.
local function releaseFlight()
    clearTimers()
    releaseSendButton()
    S.token    = S.token + 1
    S.inFlight = false
    S.acked    = false
    S.evidence = nil
end

-- The 0.5s failure spacing means an armCurrent can be SCHEDULED for a run that
-- stops before it fires. `S.active` alone is not enough to catch that: a second run
-- started in the meantime would satisfy it and the stale hop would arm a mail out
-- of the wrong queue. Every deferred hop therefore carries the run it belongs to.
local function thisRun(fn)
    local id = S.runId
    return function() if S.active and S.runId == id then fn() end end
end

local function resetState()
    releaseFlight()
    S.runId = S.runId + 1
    -- A settlement wait belongs to the run that asked for it.
    S.settleWaiter = nil
    S.settlePred   = nil
    S.settleTimer  = cancel(S.settleTimer)
    S.active, S.queue, S.idx = false, nil, 0
    S.awaitingClick, S.pendingCount, S.pendingUnits, S.pendingGold = false, 0, 0, 0
    S.attempts, S.stopping = 0, false
    S.armMail, S.armIds, S.armBefore, S.armQuiet = nil, nil, nil, nil
    S.onFinish, S.rebuild, S.check, S.skipped = nil, nil, nil, nil
end

function Mail.IsActive() return S.active end
function Mail.IsAwaitingClick() return S.active and S.awaitingClick end
function Mail.IsInFlight() return S.inFlight end

-- Hands-free unless the player has asked to drive each mail themselves.
function Mail.StepMode()
    local db = ns.db
    return (db and type(db.settings) == "table" and db.settings.mailStepMode) and true or false
end
function Mail.SetStepMode(on)
    local db = ns.db
    if not db then return end
    db.settings = db.settings or {}
    db.settings.mailStepMode = on and true or nil
end

-- Human-readable progress line for the panel.
function Mail.Status()
    if not S.active then return nil end
    local total = S.queue and #S.queue or 0
    if S.awaitingClick then
        return ("Sent %d/%d. Click Send Next for the next mail."):format(S.sentMails, total)
    end
    if S.stopping then return ("Stopping after this mail (%d/%d sent)…"):format(S.sentMails, total) end
    return ("Sending %d/%d…"):format(math.min(S.sentMails + 1, total), total)
end

local function skipReport()
    if not (S.skipped and #S.skipped > 0) then return nil end
    local names = {}
    for _, s in ipairs(S.skipped) do names[#names + 1] = s.recipient end
    return names
end

-- Stop the run. `mailboxGone` says the mailbox itself has closed under us: in that
-- case we must NOT touch the Send Mail form on the way out. ClickSendMailItemButton
-- and SetSendMailMoney are mailbox-gated — calling them once the mailbox is closed
-- errors — and there is nothing to clean up anyway, because closing the mailbox
-- already returned the staged attachments and gold to the player.
local function abort(reason, mailboxGone)
    if not S.active then return end
    local sent = S.sentMails
    local skipped = skipReport()
    resetState()
    if not mailboxGone then clearForm() end
    if reason then
        say(("stopped: %s (%d mail(s) already sent)."):format(reason, sent))
    end
    if skipped then say(("skipped: %s."):format(table.concat(skipped, ", "))) end
    notifyPanel()
end
Mail.Abort = abort

-- The panel's Stop button. A send already on the wire cannot be recalled, so Stop
-- means "no further mails": the in-flight one is allowed to resolve, and the run
-- halts at its terminal state. With nothing in flight it halts immediately.
function Mail.Stop()
    if not S.active then return false end
    if S.inFlight then
        S.stopping = true
        say("stopping after the mail already sent…")
        notifyPanel()
        return true
    end
    abort("stopped by you")
    return true
end

local function finish()
    local mails, items, gold, units = S.sentMails, S.sentItems, S.sentGold, S.sentUnits
    local done, skipped, skippedRows = S.onFinish, skipReport(), S.skipped
    resetState()
    if mails > 0 then
        local goldStr = (gold > 0 and GetCoinTextureString) and (" and " .. GetCoinTextureString(gold)) or ""
        say(("done — sent %d mail(s), %d item(s)%s."):format(mails, items, goldStr))
    else
        say("nothing to send.")
    end
    if skipped then say(("skipped: %s."):format(table.concat(skipped, ", "))) end
    -- A caller that supplied its own completion line (RunQueue) gets it AFTER the
    -- generic one, and only on a clean finish.
    if done then
        ns:SafeCall(done, { mails = mails, items = items, units = units, gold = gold,
                            skipped = skippedRows })
    end
    notifyPanel()
end

-- Write ONE attach-attempt row. Called on every path that reaches a verdict, so a
-- capture is never missing the attempt that mattered. The stored row is kept so a
-- later terminal state can amend "armed" to "sent" in place.
local function traceAttempt(mail, verdict, why, quiet)
    if not (ns.Trace and ns.Trace.Record) then return end
    local T = S.traceDraws
    local ok, stored = pcall(ns.Trace.Record, {
        run     = S.runId, idx = S.idx,
        to      = mail and mail.recipient,
        planned = mail and tonumber(mail.units),
        label   = mail and mail.unitLabel,
        itemID  = mail and tonumber(mail.itemID),
        quiet   = quiet,
        redrawn = S.traceRedrawn,
        draws   = T and T.draws or nil,
        units   = S.pendingUnits, count = S.pendingCount,
        formSum = S.traceFormSum, cal = Mail._FormCalibration and Mail._FormCalibration(),
        verdict = verdict, why = why,
    })
    S.traceEntry = ok and stored or nil
    S.traceDraws = nil
end

local function noteSkip(recipient, reason)
    S.skipped = S.skipped or {}
    S.skipped[#S.skipped + 1] = { recipient = recipient, reason = reason }
    say(("skipping %s — %s"):format(tostring(recipient), tostring(reason)))
end

-- ── Waiting for the bags to stop moving ───────────────────────────────────────
--
-- THE LIVE FAILURE THIS EXISTS FOR. Hands-free arms mail N+1 the instant mail N
-- reaches its terminal state — the owner's log shows a whole tail of mails refused
-- inside one second. At that moment the client has not finished settling the bags:
-- slots involved in the send are still LOCKED, and a locked slot makes
-- C_Container.SplitContainerItem a silent no-op. Nothing reaches the cursor,
-- nothing lands on the form, and the send guard correctly refuses a mail that would
-- have carried zero. The guard was right; the attach was early.
--
-- So arming now waits for the world to hold still first:
--   * the primary signal is BAG_UPDATE_DELAYED, which is Blizzard's own "that is
--     the end of this burst of bag changes";
--   * the condition is that no bag slot is locked and nothing is on the cursor;
--   * and there is a hard 1s ceiling, because a wait that can hang is worse than a
--     wait that gives up — if it expires we attach anyway and the guard is still
--     there to refuse anything that comes out wrong.
--
-- This applies to STEP MODE too. A fast clicker hits precisely the same race, and
-- the arm happens on the same code path either way.

local function bagsQuiet()
    -- Nothing should be riding the cursor between mails. If something is, it is
    -- debris from a draw the client handed over late, and putting it back IS part
    -- of settling — waiting for it to clear itself would wait forever.
    if CursorHasItem and CursorHasItem() then
        ClearCursor()
        if CursorHasItem() then return false end
    end
    if Rules.AnySlotLocked and Rules.AnySlotLocked() then return false end
    return true
end

local function finishSettle()
    local w = S.settleWaiter
    if not w then return end
    S.settleWaiter = nil
    S.settlePred   = nil
    S.settleTimer  = cancel(S.settleTimer)
    w()
end

-- Run `fn` as soon as `pred()` is true — now if it already is, otherwise on the
-- next bag signal that makes it true, and unconditionally once the ceiling expires.
--
-- Waiting on a CONDITION rather than on an event is what keeps this free on a
-- well-behaved client (the predicate is already true, so nothing waits) while still
-- covering one that reports late. A ceiling always fires: a wait that can hang is
-- worse than a wait that gives up, and every caller re-checks after it resumes.
local function awaitCondition(pred, fn, ceiling)
    local wrapped = thisRun(fn)
    if pred() then return wrapped() end
    D.settleWaits = D.settleWaits + 1
    S.settleWaiter = wrapped
    S.settlePred   = pred
    S.settleTimer  = cancel(S.settleTimer)
    S.settleTimer  = newTimer(ceiling or SETTLE_TIMEOUT, function()
        if not S.settleWaiter then return end
        D.settleTimeouts = D.settleTimeouts + 1
        finishSettle()
    end)
end

-- Run `fn` once the bags have settled (or the ceiling expires).
local function awaitSettlement(fn)
    return awaitCondition(bagsQuiet, fn)
end

-- Any bag signal is a chance for a pending condition to have become true.
local function onBagsMaybeSettled()
    if not S.settleWaiter then return end
    local pred = S.settlePred or bagsQuiet
    if pred() then finishSettle() end
end

-- Wait until the bags AGREE that `planned` units have left them.
--
-- This is the fix for the failure that survived two rounds. The old code measured
-- one statement after the click, by re-reading the bag slot it had just drawn from.
-- This client does not write container updates that promptly: it defers them to its
-- next bag event — the same deferral the arm already waits on for LOCKS, and it
-- applies to COUNTS too. So the re-read returned the PRE-split number, the engine
-- measured that nothing had moved, and it refused a mail whose items were sitting
-- correctly on the form. Instantly. Every mail. First mail included, on quiet bags,
-- with no race to blame — which is exactly what the field logs showed and what an
-- empty outbox after a whole run proves.
--
-- Now the measurement waits for the client to agree, and asks the whole mail at
-- once rather than a slot at a time.
local function awaitMeasured(ids, before, planned, fn)
    if not (ids and before and planned) then return awaitSettlement(fn) end
    return awaitCondition(function()
        return (before - bagUnitsFor(ids)) == planned
    end, fn, MEASURE_TIMEOUT)
end

-- Forward declarations: the loop is mutually recursive by nature (arm -> fire ->
-- terminal -> arm), and naming the hops is clearer than one giant function.
local armCurrent, fireCurrent, advance, verifyAndFire

-- Move to the next queue index and arm it. Skips mails that cannot be armed.
function advance()
    if not S.active then return end
    if S.stopping then
        abort("stopped by you")
        return
    end
    S.idx = S.idx + 1
    S.attempts = 0
    -- A mail has just left. The bags are mid-settle; arming into that is what made
    -- every mail in the owner's tail attach nothing.
    awaitSettlement(armCurrent)
end

-- Attach the mail at S.idx and either fire it (hands-free) or await a click (step).
function armCurrent()
    while true do
        if not S.active then return end
        if not S.queue or S.idx > #S.queue then
            finish()
            return
        end
        if not sendFrameReady() then
            abort("mailbox is no longer open")
            return
        end
        local mail = S.queue[S.idx]
        local skipThis = false
        -- Observed BEFORE anything is touched, so the trace can say whether this
        -- attempt was made into a still world or a moving one.
        local quiet = bagsQuiet()
        S.traceDraws, S.traceRedrawn, S.traceFormSum = nil, false, nil

        -- RE-CHECK THE PLAN AGAINST LIVE TRUTH, per mail, immediately before the
        -- attach. This is what makes a resumed run send only the remainder: the
        -- caller's check reads the mesh + the outbound ledger + the bags as they
        -- are NOW, not as they were when the preview was drawn.
        if S.check then
            local okCheck, whyCheck = S.check(mail)
            if not okCheck then
                noteSkip(mail.recipient, whyCheck or "no longer needed")
                traceAttempt(mail, "skipped", whyCheck or "no longer needed", quiet)
                skipThis = true
            end
        end

        if not skipThis then
            -- RE-DERIVE THE DRAWS. The plan's quantity is the contract; its bag
            -- COORDINATES are not. They were worked out before the run started and
            -- every mail since has moved the bags underneath them, so for any mail
            -- that names an item and a quantity the slots are resolved fresh, here,
            -- against the bags as they are at this instant. A stack that moved,
            -- merged or emptied simply resolves to wherever the goods actually are.
            local draws
            if mail.itemID and tonumber(mail.units) and Rules.ScanStacksForItem then
                local live = Rules.ScanStacksForItem(mail.itemID)
                local total
                draws, total = Rules.DrawExact(live, mail.units, ns.MAX_ATTACH)
                D.redrawn = D.redrawn + 1
                S.traceRedrawn = true
                if total < tonumber(mail.units) then
                    -- Not enough of it left in the bags to honour the plan. This is
                    -- a shortfall, not a race — say so plainly and move on rather
                    -- than burning the retry on a wait that cannot help.
                    clearForm()
                    S.pendingCount, S.pendingUnits, S.pendingGold = 0, 0, 0
                    local why = ("only %d %s left in your bags, %d were planned")
                        :format(total, mail.unitLabel or "item(s)", tonumber(mail.units))
                    noteSkip(mail.recipient, why)
                    traceAttempt(mail, "skipped", why, quiet)
                    skipThis = true
                end
            end

            if not skipThis then
            -- The bag total BEFORE we touch anything, measured on settled state.
            -- The mail may only fly if exactly `planned` has left this total once
            -- the client has flushed — see verifyAndFire.
            local ids = idSetOf(draws or mail.stacks)
            S.armIds, S.armBefore = ids, bagUnitsFor(ids)
            S.armMail, S.armQuiet = mail, quiet

            attachMail(mail, draws)
            -- ALWAYS through the measurement, even when nothing appeared to
            -- attach. "Nothing attached" used to skip the mail on the spot, which
            -- is wrong for exactly the client this round is about: an attach that
            -- came away empty because the bags had not settled deserves the retry,
            -- not a silent skip. The measurement decides, and one path decides it.
            awaitMeasured(S.armIds, S.armBefore, tonumber(mail.units), verifyAndFire)
            return
            end
        end

        if skipThis then
            S.idx = S.idx + 1
            S.attempts = 0
            notifyPanel()
        end
    end
end

-- THE GUARD, MOVED TO WHERE IT CAN SEE. Runs after the client has flushed its bag
-- changes, so the numbers it reads are the ones the client actually believes.
--
--   measured = what LEFT THE BAGS across the whole mail
--   planned  = what the plan said this recipient gets
--
-- Nothing fires unless those are equal. Over-attaching (the 1.2.0 defect) fails it
-- because too much left; under-attaching fails it because too little did; and a
-- correctly attached mail on a client that reports counts late now PASSES, because
-- by the time this runs the counts have been written.
function verifyAndFire()
    if not S.active then return end
    local mail = S.armMail or (S.queue and S.queue[S.idx])
    if not mail then return end
    local quiet = S.armQuiet

    local moved = nil
    if S.armIds and S.armBefore then
        moved = S.armBefore - bagUnitsFor(S.armIds)
        -- The authoritative units for this mail. Everything downstream — the send
        -- guard, the completion line, the outbound ledger — uses this number and
        -- not the attach's running total.
        if (tonumber(mail.money) or 0) <= 0 then S.pendingUnits = moved end
    end

    local okAttach, whyAttach = verifyAttach(mail, moved)
    if not okAttach then
        traceAttempt(mail, "refused", whyAttach, quiet)
        clearForm()
        S.pendingCount, S.pendingUnits, S.pendingGold = 0, 0, 0
        say(whyAttach)
        if S.attempts < RETRY_BUDGET then
            S.attempts = S.attempts + 1
            -- ONE re-arm, and it waits for the bags to settle first. A retry that
            -- does not wait is not a retry, it is the same attempt twice.
            newTimer(FAILURE_SPACING, thisRun(function()
                awaitSettlement(armCurrent)
            end))
            return
        end
        noteSkip(mail.recipient, "what would attach did not match the plan")
        S.idx = S.idx + 1
        S.attempts = 0
        awaitSettlement(armCurrent)
        return
    end

    -- Armed and verified. The row is written NOW rather than at the terminal state,
    -- so a capture taken from a run that hung mid-send still contains the attempt
    -- that hung; confirmSend amends it in place.
    traceAttempt(mail, "armed", nil, quiet)
    D.mails = D.mails + 1
    do
            local mail = S.queue[S.idx]
            if Mail.StepMode() then
                S.awaitingClick = true
                local total = #S.queue
                local sendNext = ns:Wrap("brand", "Send Next")
                if (tonumber(mail.money) or 0) > 0 then
                    say(("mail %d/%d ready: %s to %s. Click %s.")
                        :format(S.idx, total, GetCoinTextureString and GetCoinTextureString(mail.money) or (mail.money .. "c"), mail.recipient, sendNext))
                elseif mail.unitLabel then
                    say(("mail %d/%d ready: %d %s to %s. Click %s.")
                        :format(S.idx, total, S.pendingUnits, mail.unitLabel, mail.recipient, sendNext))
                else
                    say(("mail %d/%d ready: %d item(s) to %s. Click %s.")
                        :format(S.idx, total, S.pendingCount, mail.recipient, sendNext))
                end
                notifyPanel()
                return
            end
            fireCurrent()
    end
end

local function onAckTimeout(token)
    if token ~= S.token or not S.active then return end
    local who = (S.queue and S.queue[S.idx] and S.queue[S.idx].recipient) or "?"
    releaseFlight()
    say(("no answer from the server within %ds on the mail to %s. It may or may not have gone — check your bags and Blizzard's returned mail.")
        :format(ACK_TIMEOUT, tostring(who)))
    abort("the server did not answer")
end

local function onEvidenceTimeout(token)
    if token ~= S.token or not S.active then return end
    local who = (S.queue and S.queue[S.idx] and S.queue[S.idx].recipient) or "?"
    releaseFlight()
    say(("the mail to %s was acknowledged but nothing left your bags or purse within %ds — stopping so nothing is sent twice.")
        :format(tostring(who), EVIDENCE_TIMEOUT))
    abort("the send could not be confirmed")
end

-- Send the currently armed mail.
function fireCurrent()
    local mail = S.queue and S.queue[S.idx]
    if not mail then return end
    if S.inFlight then return end          -- STRICTLY one mail in flight
    if not sendFrameReady() then
        abort("mailbox is no longer open")
        return
    end
    S.awaitingClick = false
    S.inFlight, S.acked = true, false
    S.token    = S.token + 1
    local token = S.token
    S.evidence = snapshotEvidence(mail)
    holdSendButton()
    S.ackTimer = newTimer(ACK_TIMEOUT, function() onAckTimeout(token) end)
    notifyPanel()
    SendMail(mail.recipient, mail.subject or ns.MAIL_SUBJECT, "")
end

-- Step mode: the panel's Send-Next button click.
function Mail.ContinueClick()
    if not (S.active and S.awaitingClick) then return end
    fireCurrent()
end

-- Terminal SUCCESS: the ack AND the evidence are both in.
local function confirmSend()
    local mail = S.queue and S.queue[S.idx]
    local units, count, gold = S.pendingUnits or 0, S.pendingCount or 0, S.pendingGold or 0
    -- Amend this attempt's trace row in place: it was "armed", it is now "sent".
    if S.traceEntry then S.traceEntry.verdict = "sent"; S.traceEntry = nil end
    releaseFlight()

    S.sentMails = S.sentMails + 1
    S.sentItems = S.sentItems + count
    S.sentUnits = S.sentUnits + units
    S.sentGold  = S.sentGold  + gold
    S.pendingCount, S.pendingUnits, S.pendingGold = 0, 0, 0

    -- THE LEDGER, and only here. Not on an attempt, not on an ack, not on a
    -- "probably fine" — on the one path where the mail was acknowledged AND the
    -- goods verifiably left. A mail recorded that did not go is a character this
    -- addon will refuse to top up for the next thirty days.
    if mail and ns.Ledger and mail.itemID and units > 0 then
        ns:SafeCall(function() ns.Ledger.Record(mail.recipient, mail.itemID, units) end)
    end

    if mail then
        local total = S.queue and #S.queue or 0
        if units > 0 and mail.unitLabel then
            say(("sent %d/%d: %d %s to %s."):format(S.sentMails, total, units, mail.unitLabel, mail.recipient))
        elseif gold > 0 then
            say(("sent %d/%d: %s to %s."):format(S.sentMails, total,
                GetCoinTextureString and GetCoinTextureString(gold) or (gold .. "c"), mail.recipient))
        else
            say(("sent %d/%d: %d item(s) to %s."):format(S.sentMails, total, count, mail.recipient))
        end
    end
    notifyPanel()
    advance()
end

-- Terminal FAILURE before the ack. One retry, counted exactly once, then skip.
local function failSend(reason)
    local mail = S.queue and S.queue[S.idx]
    local acked = S.acked
    if S.traceEntry then
        S.traceEntry.verdict = "failed"
        S.traceEntry.why = ns.Trace and ns.Trace.Str(reason, 160) or nil
        S.traceEntry = nil
    end
    releaseFlight()
    if not S.active then return end

    if acked then
        -- Past the ack the mail may already be gone; a second attempt could
        -- double-send, so this stops the run rather than retrying.
        say(("%s (after the server had already answered) — stopping so nothing is sent twice."):format(reason))
        abort("could not confirm the last mail")
        return
    end

    -- A send that did not go leaves its attachments staged. Take them off the form
    -- FIRST, so the settle wait below covers their return to the bags and the next
    -- attempt measures a "before" that already includes them. Measuring across a
    -- form that is still holding the last attempt's goods reads a delta of zero.
    if sendFrameReady() then clearForm() end
    S.pendingCount, S.pendingUnits, S.pendingGold = 0, 0, 0

    S.attempts = S.attempts + 1
    -- Both re-entries below wait for the bags to settle as well as for the failure
    -- spacing: a failed send hands its attachments back, and re-attaching while
    -- they are still in mid-air is the same race that emptied the owner's forms.
    if S.attempts <= RETRY_BUDGET then
        say(("%s — retrying %s once."):format(reason, tostring(mail and mail.recipient)))
        newTimer(FAILURE_SPACING, thisRun(function() awaitSettlement(armCurrent) end))
        return
    end
    noteSkip(mail and mail.recipient, reason)
    newTimer(FAILURE_SPACING, thisRun(function()
        S.idx = S.idx + 1
        S.attempts = 0
        awaitSettlement(armCurrent)
    end))
end

-- ── Confirm popup (StaticPopup — its Accept is the ONE user interaction) ───────

-- Begin a confirmed run. Called ONLY from the confirm popup's Accept so the
-- confirm gate cannot be bypassed.
local function beginConfirmed(queue, opts)
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

    opts = (type(opts) == "table") and opts or {}
    S.onFinish = (type(opts.onFinish) == "function") and opts.onFinish or nil
    S.rebuild  = (type(opts.rebuild)  == "function") and opts.rebuild  or nil
    S.check    = (type(opts.check)    == "function") and opts.check    or nil

    -- RE-DERIVE THE QUEUE FROM COMMITTED STATE AT RUN START. The preview was drawn
    -- from a snapshot; between raising it and accepting it, a mail may have landed,
    -- an earlier interrupted run may have already posted half of this one, or the
    -- bags may have moved. Whatever the caller can re-derive, it re-derives now.
    if S.rebuild then
        local rebuilt = S.rebuild()
        if type(rebuilt) == "table" then
            if #rebuilt == 0 then
                say("nothing left to send — it is already on its way.")
                S.onFinish, S.rebuild, S.check = nil, nil, nil
                return
            end
            queue = rebuilt
        end
    end

    S.active, S.queue, S.idx = true, queue, 1
    S.sentMails, S.sentItems, S.sentGold, S.sentUnits = 0, 0, 0, 0
    S.awaitingClick, S.attempts, S.stopping = false, 0, false
    S.skipped = nil

    armCurrent()
    notifyPanel()
end

StaticPopupDialogs["DASEEKI_CONDUIT_SEND_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = CANCEL,
    OnAccept = function(_, data)
        if data and data.queue then beginConfirmed(data.queue, data) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true,
    preferredIndex = 3,  -- avoid taint from the default StaticPopup pool
}

-- Build the dry-run summary text for the popup from a summary table.
local function summaryText(summary, mailCount, skipped)
    local lines = {}
    -- Neutral facts stay calm bright cream (attention inversion §5); no alarm color on a count.
    lines[#lines + 1] = ("Send %s mail(s)?"):format(ns:Wrap("text", mailCount))
    lines[#lines + 1] = ""
    if summary.itemCount > 0 then
        lines[#lines + 1] = ("Items:  %s"):format(ns:Wrap("text", summary.itemCount))
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
            lines[#lines + 1] = ("%s  <-  %s  (%d mail)"):format(ns:Wrap("text", name), table.concat(parts, " + "), r.mails)
        end
    end
    if skipped and #skipped > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = ns:Wrap("muted", ("%d rule(s) skipped (nothing to send / bad recipient)."):format(#skipped))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ns:Wrap("muted", Mail.StepMode()
        and "One mail per click (step mode is on in settings)."
        or  "Accept once and the whole batch sends itself. Stop is on the panel.")
    return table.concat(lines, "\n")
end

-- ── Public entry points (called by the panel) ────────────────────────────────

-- The gate every run passes, whoever built the queue.
local function readyToSend()
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
    -- The whole pacing contract is timers: the ack ceiling, the evidence ceiling,
    -- the failure spacing and the Send-button hold. Without a timer service there is
    -- no safe way to run unattended, so we refuse rather than send blind.
    local T = _G.C_Timer
    if not (T and (T.NewTimer or T.After)) then
        say("this client offers no timer service — cannot run a batch safely.")
        return false, "no timers"
    end
    return true
end

-- Run an ALREADY-BUILT queue behind the same mandatory confirm popup, with the
-- caller's own dry-run text as the popup body. This is the seam a feature uses to
-- reach the send engine — the confirm gate, the hands-free pacing, the units guard,
-- the mailbox-close abort and the failure handling all come with it, and none of
-- them may be reimplemented anywhere else.
--
--   opts = { onFinish = function(stats) end,   -- stats: mails/items/units/gold
--            rebuild  = function() return queue end,     -- re-derive at run start
--            check    = function(mail) return ok, why end }  -- re-check per mail
--
-- Returns true if a popup was shown, false + reason otherwise.
function Mail.RunQueue(queue, text, opts)
    local ok, why = readyToSend()
    if not ok then return false, why end
    if type(queue) ~= "table" or #queue == 0 then
        say("nothing to send.")
        return false, "empty"
    end
    opts = (type(opts) == "table") and opts or {}
    StaticPopup_Show("DASEEKI_CONDUIT_SEND_CONFIRM", text or "Send?", nil,
        { queue = queue, onFinish = opts.onFinish, rebuild = opts.rebuild, check = opts.check })
    return true
end

-- Start a run for a specific list of rules (single rule, or all enabled).
function Mail.RunForRules(rules)
    local okReady, whyReady = readyToSend()
    if not okReady then return false, whyReady end

    local me = UnitName and UnitName("player") or ""
    local money = GetMoney and GetMoney() or 0
    local build = function()
        return Rules.BuildMailQueue(rules, {
            me = me, money = (GetMoney and GetMoney()) or money,
            maxAttach = ns.MAX_ATTACH, postageBuffer = ns.POSTAGE_BUFFER,
            subject = ns.MAIL_SUBJECT,
        })
    end
    local queue, summary, skipped = build()

    if #queue == 0 then
        local reason = (skipped and #skipped > 0) and skipped[1].reason or "no matching items or gold to send"
        say("nothing to send — " .. reason .. ".")
        return false, "empty"
    end

    -- The dialog's text is "%s"; StaticPopup_Show substitutes arg1 into it.
    local text = summaryText(summary, #queue, skipped)
    StaticPopup_Show("DASEEKI_CONDUIT_SEND_CONFIRM", text, nil,
        { queue = queue, rebuild = function() return (build()) end })
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

-- Evidence arrived (or might have). Both event families funnel here; the check is
-- idempotent, so being asked twice costs one comparison.
local function pollEvidence()
    if not (S.active and S.inFlight and S.acked) then return end
    local verdict = evidenceSatisfied(S.evidence)
    if verdict == true then
        confirmSend()
    elseif verdict == false then
        failSend("the mail was acknowledged but the goods did not move")
    end
end

-- THE ACK. MAIL_SUCCESS, not MAIL_SEND_SUCCESS — see the header.
ns:RegisterEvent("MAIL_SUCCESS", function()
    if not (S.active and S.inFlight) then return end
    if S.acked then return end                 -- a duplicate ack is not a second mail
    S.acked = true
    S.ackTimer = cancel(S.ackTimer)
    local token = S.token
    S.evTimer = newTimer(EVIDENCE_TIMEOUT, function() onEvidenceTimeout(token) end)
    -- The evidence may already be true by the time the ack lands.
    pollEvidence()
end)

ns:RegisterEvent("PLAYER_MONEY", pollEvidence)
ns:RegisterEvent("BAG_UPDATE", pollEvidence)

-- BAG_UPDATE_DELAYED does double duty: it is Blizzard's "that burst of bag changes
-- is over", which is both the evidence signal for an item mail and the signal that
-- it is finally safe to attach the next one. ITEM_LOCK_CHANGED catches the case
-- where the last thing to settle is a lock rather than a count.
ns:RegisterEvent("BAG_UPDATE_DELAYED", function(...)
    pollEvidence(...)
    onBagsMaybeSettled()
end)
ns:RegisterEvent("ITEM_LOCK_CHANGED", function() onBagsMaybeSettled() end)

ns:RegisterEvent("MAIL_FAILED", function()
    if not (S.active and S.inFlight) then return end
    failSend("the server refused the mail (check the recipient name and your gold)")
end)

-- The mailbox went away (MAIL_CLOSED, or the mail window hidden by any other
-- route — core.lua's teardown coordinator funnels every one of them here).
ns:RegisterMailboxCloser(function()
    -- A confirm popup is an offer to send AT THIS MAILBOX, against the bag and
    -- wallet snapshot taken when it was raised. Once the mailbox is gone that
    -- snapshot is stale, so the popup dies with it.
    if StaticPopup_Hide then StaticPopup_Hide("DASEEKI_CONDUIT_SEND_CONFIRM") end
    -- Mid-batch: HARD ABORT, and it actually returns. Not a warning followed by a
    -- send into a closed mailbox. The mailbox is closed, so skip the form cleanup —
    -- see abort()'s mailboxGone note.
    if S.active then abort("mailbox closed", true) end
end)

ns:RegisterEvent("UI_ERROR_MESSAGE", function(_, arg1, arg2)
    if not S.active then return end
    local msg = (type(arg2) == "string" and arg2) or (type(arg1) == "string" and arg1) or nil
    if msg and ABORT_ERRORS[msg] then
        if S.inFlight then failSend(msg) else abort(msg) end
    end
end)
