-- =====================================================================
-- Daseeki-Conduit harness — CLASSIC ERA MAILBOX SIMULATOR
--
-- ── THE DEFAULT PROFILE IS THE OWNER'S CLIENT, NOT THE SPEC ──────────────────
--
-- Every headless build before 1.2.3 passed while the live one failed, and the
-- reason is that this file modelled a mailbox that behaves the way the API
-- documentation implies. The owner's attach trace (build 1.2.2+attach-trace.1)
-- settled what his 11509 client actually does, and the two behaviours below are now
-- the DEFAULT here, because a simulator that is kinder than reality is not a gate:
--
--   formWholeStack  Splitting a stack and clicking it onto the Send Mail form
--                   attaches the WHOLE STACK. Asked for 7 out of 10, the form comes
--                   back holding 10. Deterministic, unlocked slot, quiet bags.
--                   (`raw` in the capture: name, itemID, texture, "10", quality.)
--   retainBags      An attachment does NOT leave the bags. The stack stays visible
--                   in its slot until the mail is actually SENT, so a bag
--                   subtraction across an attach measures ZERO however much landed
--                   on the form. That is why the owner's every mail read "0 left
--                   your bags" and why his outbox was empty after a whole run.
--
-- Bag-to-bag splitting is NOT affected by either: it works, here and in the field
-- (the owner splits stacks by hand every day), which is the entire premise of the
-- pre-split staging strategy.
--
-- Pass `formWholeStack = false` / `retainBags = false` for the SPEC-behaving client,
-- which is kept as a secondary profile so a regression can be told apart from a
-- client difference.
--
-- mail.lua is the one file the old harness could not load: it is nothing BUT live
-- API. That is also where the send bugs live, so this stands the API up in plain
-- Lua and lets the REAL engine drive it:
--
--   * bag containers with real stacks, a real cursor, and pickup/split semantics
--     (picking up empties the slot; splitting leaves the remainder behind;
--     returning an item merges into a partial stack of the same item, which is how
--     the live client behaves and how a "stale" bag slot comes back to life);
--   * the Send Mail form: twelve attachment slots that report their stack COUNT
--     through GetSendMailItem's fourth return (the position the owner's capture
--     settled), a money field, and a detach that gives the stack back — which under
--     the default `retainBags` profile means simply forgetting the reservation,
--     because the stack never left the bag in the first place;
--   * a SendMail that consumes the form and answers on a VIRTUAL CLOCK, so every
--     timeout, retry delay and repeating ticker in the engine can be driven
--     deterministically and instantly;
--   * Blizzard's habit of re-enabling its own Send button mid-send.
--
-- Nothing here is shipped: the .toc does not list it.
-- =====================================================================

local M = {}
M.__index = M

local STACK_MAX = 10   -- Chronoboon Displacer; the only stackable in these fixtures

-- ── construction ──────────────────────────────────────────────────────────────
-- layout: { [bag] = { size = n, [slot] = { itemID =, count =, isBound = } } }
function M.New(layout, opts)
    opts = opts or {}
    local sim = setmetatable({
        bags = {}, cursor = nil, attach = {}, money = 0,
        wallet = opts.wallet or 10000000,
        sent = {}, chat = {},
        MAXATT = opts.maxAttach or 12,
        stackMax = opts.stackMax or STACK_MAX,
        mailboxOpen = true,
        -- virtual clock
        now = 0, timers = {}, seq = 0,
        -- server behaviour, per send index: "ok" | "fail" | "noack" | "noevidence"
        behaviour = opts.behaviour or function() return "ok" end,
        latency = opts.latency or 0.3,
        -- attach poisoning: return an override count for a requested split
        poison = opts.poison,
        noSplit = opts.noSplit,
        -- A client that HAS C_Container.SplitContainerItem and silently does nothing
        -- with it — the failure mode staging has to be able to give up on, because
        -- it looks exactly like a slow client until the ceiling expires.
        splitRefuses = opts.splitRefuses,
        splitAsync = opts.splitAsync,
        -- HOW LATE the async hand-over is. The default (0.05s) is the ordinary
        -- frame boundary; set it above Staging.CURSOR_LADDER[1] to model the world
        -- server hiccup / loading-screen stutter that used to latch
        -- "this client will not split stacks" for the whole session (CDT-3).
        splitDelay = opts.splitDelay or 0.05,
        formBadAfter = opts.formBadAfter,
        formBadValue = opts.formBadValue,
        formShape = opts.formShape,
        asyncCounts = opts.asyncCounts,
        attachClicks = 0,
        -- ASYNC BAG SETTLEMENT (the live 11509 behaviour that broke 1.2.0).
        -- With this on, a send does not update the bags in the same breath: the
        -- slots it touched are LOCKED, the counts are stale, and both only come
        -- right when the simulated BAG_UPDATE_DELAYED tick lands `settleDelay`
        -- later. A locked slot refuses SplitContainerItem silently, exactly as the
        -- client does.
        asyncBags = opts.asyncBags,
        -- THE PROVEN CLIENT, ON BY DEFAULT. See the header.
        formWholeStack = (opts.formWholeStack ~= false),
        retainBags     = (opts.retainBags ~= false),
        settleDelay = opts.settleDelay or 0.4,
        locks = {},          -- [bag] = { [slot] = true }
        pendingSettle = nil,
        events = {},
        buttonEnabled = true,
        disableCalls = 0, enableCalls = 0,
    }, M)
    for bag, b in pairs(layout or {}) do
        local nb = { size = b.size or 16 }
        for slot = 1, nb.size do
            local it = b[slot]
            if it then nb[slot] = { itemID = it.itemID, count = it.count, isBound = it.isBound } end
        end
        sim.bags[bag] = nb
    end
    return sim
end

-- ── virtual clock ─────────────────────────────────────────────────────────────
function M:schedule(sec, fn, interval)
    self.seq = self.seq + 1
    local t = { at = self.now + (sec or 0), fn = fn, interval = interval,
                cancelled = false, seq = self.seq }
    self.timers[#self.timers + 1] = t
    return t
end

-- Step the clock forward, firing everything due in time order. Timers scheduled by
-- a firing timer are picked up in the same advance, which is what lets one call
-- drive a whole multi-mail run.
function M:Advance(sec)
    local target = self.now + (sec or 0)
    while true do
        local best
        for _, t in ipairs(self.timers) do
            if not t.cancelled and t.at <= target then
                if not best or t.at < best.at or (t.at == best.at and t.seq < best.seq) then best = t end
            end
        end
        if not best then break end
        self.now = best.at
        if best.interval then best.at = best.at + best.interval else best.cancelled = true end
        best.fn()
    end
    self.now = target
end

function M:LiveTickers()
    local n = 0
    for _, t in ipairs(self.timers) do
        if not t.cancelled and t.interval then n = n + 1 end
    end
    return n
end

function M:LiveTimers()
    local n = 0
    for _, t in ipairs(self.timers) do if not t.cancelled then n = n + 1 end end
    return n
end

-- ── async bag settlement ──────────────────────────────────────────────────────
--
-- Lock every slot that currently holds `itemID` (the client locks what a pending
-- container/mail operation touches), and schedule the unlock plus the
-- BAG_UPDATE_DELAYED that says the burst is over.
function M:disturbBags(itemID)
    if not self.asyncBags then
        self:Fire("BAG_UPDATE_DELAYED")
        return
    end
    for bag = 0, 4 do
        local b = self.bags[bag]
        if b then
            for slot = 1, b.size do
                local s = b[slot]
                if s and (itemID == nil or s.itemID == itemID) then
                    self.locks[bag] = self.locks[bag] or {}
                    self.locks[bag][slot] = true
                end
            end
        end
    end
    if self.pendingSettle then self.pendingSettle.cancelled = true end
    self.pendingSettle = self:schedule(self.settleDelay, function()
        self.locks = {}
        self.pendingSettle = nil
        self:flushDeferred()          -- the counts land HERE, not at call time
        self:Fire("ITEM_LOCK_CHANGED")
        self:Fire("BAG_UPDATE_DELAYED")
    end)
end

function M:isLocked(bag, slot)
    return (self.locks[bag] and self.locks[bag][slot]) and true or false
end

-- ASYNC COUNTS. The profile that matters most, and the one every headless build
-- passed by accident: a client that hands the ITEMS over immediately (the cursor
-- fills, the attachment lands) but does not write the new bag COUNTS until its
-- next bag event. Anything that re-reads a slot one statement after taking from it
-- gets the PRE-split number back, and therefore measures that nothing moved.
--
-- The simulator used to apply container mutations synchronously inside the attach
-- call, which is precisely why a measurement bug of this shape could not fail here.
-- `bag`/`slot` name the ONE slot the operation touched. The client locks what it
-- is working on, not the whole inventory, so a second draw from a different slot in
-- the same mail is still serviceable — which is what makes multi-attachment mails
-- possible at all.
function M:deferBag(fn, bag, slot)
    if not self.asyncCounts then return fn() end
    self.deferred = self.deferred or {}
    self.deferred[#self.deferred + 1] = fn
    self:disturbSlot(bag, slot)
end

function M:disturbSlot(bag, slot)
    if bag and slot and self.asyncBags then
        self.locks[bag] = self.locks[bag] or {}
        self.locks[bag][slot] = true
    end
    if self.pendingSettle then self.pendingSettle.cancelled = true end
    self.pendingSettle = self:schedule(self.settleDelay, function()
        self.locks = {}
        self.pendingSettle = nil
        self:flushDeferred()
        self:Fire("ITEM_LOCK_CHANGED")
        self:Fire("BAG_UPDATE_DELAYED")
    end)
end

function M:flushDeferred()
    local d = self.deferred
    if not d then return end
    self.deferred = nil
    for i = 1, #d do d[i]() end
end

-- ── the cursor, and WHEN the bags actually change ─────────────────────────────
--
-- Taking something out of a slot puts it on the cursor NOW; the bag arithmetic that
-- goes with it is carried along as a pending COMMIT, because when it lands depends
-- on where the thing ends up:
--
--   into another BAG SLOT (staging's bag-to-bag split)  -> commit runs immediately
--                                                          (deferred by one tick if
--                                                          asyncCounts is on).
--   onto the MAIL FORM                                  -> with retainBags, the
--                                                          commit is HELD until the
--                                                          mail is sent. The stack
--                                                          stays visible in the bag,
--                                                          which is what makes a bag
--                                                          subtraction across an
--                                                          attach measure zero.
--   back to the BAGS (ClearCursor)                      -> the commit is DROPPED:
--                                                          nothing ever left, so
--                                                          nothing comes back.
--
-- Units are conserved on every path, which is what the harness's conservation
-- checks are for.
function M:takeToCursor(bag, slot, take)
    local b = self.bags[bag]
    local s = b and b[slot]
    if not s then return end
    local have = s.count
    if take > have then take = have end
    local apply = function()
        if b[slot] ~= s then return end
        s.count = s.count - take
        if s.count <= 0 then b[slot] = nil end
    end
    -- Clearing the whole source slot, whatever it holds by then. Used when the
    -- client swallows a partial split and attaches the WHOLE stack instead.
    local applyAll = function()
        if b[slot] ~= s then return end
        b[slot] = nil
    end
    self.cursor = { itemID = s.itemID, count = take,
                    srcBag = bag, srcSlot = slot, srcCount = have,
                    partial = (take < have),
                    commit = apply, commitAll = applyAll }
    if self.retainBags then
        -- The count does not move yet — only the lock does.
        self:disturbSlot(bag, slot)
    else
        self.cursor.commit = nil
        self:deferBag(apply, bag, slot)
    end
end

-- Run a held commit (if any) through the normal deferral machinery.
function M:commitCursor(c, bag, slot)
    if not (c and c.commit) then return end
    local fn = c.commit
    c.commit, c.commitAll = nil, nil
    self:deferBag(fn, bag or c.srcBag, slot or c.srcSlot)
end

-- ── bags ──────────────────────────────────────────────────────────────────────
function M:returnToBags(item)
    for bag = 0, 4 do
        local b = self.bags[bag]
        if b then
            for slot = 1, b.size do
                local s = b[slot]
                if s and s.itemID == item.itemID and s.count < self.stackMax then
                    local move = math.min(self.stackMax - s.count, item.count)
                    s.count = s.count + move
                    item.count = item.count - move
                    if item.count <= 0 then return true end
                end
            end
        end
    end
    for bag = 0, 4 do
        local b = self.bags[bag]
        if b then
            for slot = 1, b.size do
                if not b[slot] then
                    b[slot] = { itemID = item.itemID, count = item.count }
                    return true
                end
            end
        end
    end
    return false
end

function M:BagUnits(itemID)
    local n = 0
    for bag = 0, 4 do
        local b = self.bags[bag]
        if b then
            for slot = 1, b.size do
                local s = b[slot]
                if s and (itemID == nil or s.itemID == itemID) then n = n + s.count end
            end
        end
    end
    return n
end

function M:AttachedUnits()
    local n = 0
    for i = 1, self.MAXATT do if self.attach[i] then n = n + self.attach[i].count end end
    return n
end

function M:AttachedCount()
    local n = 0
    for i = 1, self.MAXATT do if self.attach[i] then n = n + 1 end end
    return n
end

function M:AttachDesc()
    local p = {}
    for i = 1, self.MAXATT do if self.attach[i] then p[#p + 1] = tostring(self.attach[i].count) end end
    return "[" .. table.concat(p, ",") .. "]"
end

-- ── events ────────────────────────────────────────────────────────────────────
function M:On(event, fn)
    self.events[event] = self.events[event] or {}
    local l = self.events[event]
    l[#l + 1] = fn
end

function M:Fire(event, ...)
    local l = self.events[event]
    if not l then return end
    for i = 1, #l do l[i](event, ...) end
end

-- ── install the WoW surface ───────────────────────────────────────────────────
function M:Install(G)
    local sim = self

    G.C_Container = {
        GetContainerNumSlots = function(bag) local b = sim.bags[bag]; return b and b.size or 0 end,
        GetContainerItemInfo = function(bag, slot)
            local b = sim.bags[bag]; local s = b and b[slot]
            if not s then return nil end
            return { itemID = s.itemID, stackCount = s.count,
                     isBound = s.isBound and true or false,
                     isLocked = sim:isLocked(bag, slot) }
        end,
        HasContainerItem = function(bag, slot)
            local b = sim.bags[bag]; return (b and b[slot]) and true or false
        end,
        GetContainerNumFreeSlots = function(bag)
            local b = sim.bags[bag]
            if not b then return 0, 0 end
            local n = 0
            for slot = 1, b.size do if not b[slot] then n = n + 1 end end
            return n, (sim.bagFamily and sim.bagFamily[bag]) or 0
        end,
        PickupContainerItem = function(bag, slot)
            local b = sim.bags[bag]; local s = b and b[slot]
            if sim:isLocked(bag, slot) then return end
            if sim.cursor then
                -- PLACING. This is staging's bag-to-bag move, and it is the moment
                -- the source's arithmetic finally lands.
                local c = sim.cursor
                if not s then
                    b[slot] = { itemID = c.itemID, count = c.count }
                    sim.cursor = nil
                    sim:commitCursor(c)
                    sim:disturbSlot(bag, slot)
                else
                    b[slot], sim.cursor = { itemID = c.itemID, count = c.count }, s
                    sim:commitCursor(c)
                end
                return
            end
            if not s then return end
            sim:takeToCursor(bag, slot, s.count)
        end,
        SplitContainerItem = function(bag, slot, n)
            local b = sim.bags[bag]; local s = b and b[slot]
            -- A LOCKED SLOT REFUSES SILENTLY. No error, no cursor, nothing — this
            -- one line is the whole live 1.2.0 failure.
            if sim:isLocked(bag, slot) then return end
            if sim.splitRefuses then return end
            -- A split that takes from the slot but hands the stack over a frame
            -- later. Asking again would take a second helping — which is the whole
            -- reason the engine has to tell this apart from a no-op.
            if sim.splitAsync then
                if not s or sim.cursor then return end
                local moved, id = n, s.itemID
                if n < s.count then s.count = s.count - n else moved = s.count; b[slot] = nil end
                sim:schedule(sim.splitDelay, function()
                    -- Handed over late. If the cursor is busy by then the client
                    -- puts it back rather than dropping it on the floor — nothing
                    -- may vanish, or the conservation check below means nothing.
                    if not sim.cursor then sim.cursor = { itemID = id, count = moved }
                    else sim:returnToBags({ itemID = id, count = moved }) end
                end)
                return
            end
            if not s or sim.cursor then return end
            -- Attach poisoning: a client that hands back a different amount than
            -- was asked for is the whole reason the engine verifies at all.
            if sim.poison then n = sim.poison(bag, slot, n, s.count) or n end
            sim:takeToCursor(bag, slot, n)
        end,
    }
    -- A client with no partial-stack API at all. This is the condition the pre-fix
    -- attach had a whole-stack fallback for, and the fallback was the bug.
    if sim.noSplit then G.C_Container.SplitContainerItem = nil end

    G.C_Item = { GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, 0, 0 end }
    G.NUM_BAG_SLOTS = 4
    G.ATTACHMENTS_MAX_SEND = sim.MAXATT

    G.CursorHasItem = function() return sim.cursor ~= nil end
    -- Putting something BACK in the bags is itself a container operation, so it
    -- sets them moving again. This is why a retry that does not wait can never
    -- recover: its own cleanup re-locks the slots it is about to draw from.
    G.ClearCursor = function()
        if sim.cursor then
            local c = sim.cursor
            sim.cursor = nil
            -- A HELD COMMIT means the bags never actually lost this: putting it
            -- "back" is simply forgetting the arithmetic. Anything else really did
            -- leave a slot and has to find a home again.
            if c.commit then c.commit, c.commitAll = nil, nil
            else sim:returnToBags(c) end
            sim:disturbBags(nil)
        end
    end

    -- The Send Mail form's read-back. Its return ORDER is undocumented on 11509, so
    -- the shape is configurable here — and `formBadAfter` models a client that
    -- reports the count honestly for the first N attachments and then stops (a
    -- stale or zero count), which is the profile that turns a once-learned
    -- calibration into a measurement of nothing.
    G.GetSendMailItem = function(i)
        local a = sim.attach[i]
        if not a then return nil end
        local count = a.count
        if sim.formBadAfter and (sim.attachClicks or 0) > sim.formBadAfter then
            count = sim.formBadValue or 0
        end
        if sim.formShape == "noID" then
            return "Item" .. a.itemID, 133879, count, 1       -- name, texture, count, quality
        end
        -- The owner's capture, exactly: name, itemID, texture, count, quality.
        --   { "Chronoboon Displacer", "184937", "133879", "10", "1" }
        return "Item" .. a.itemID, a.itemID, 133879, count, 1
    end
    G.ClickSendMailItemButton = function(i, clear)
        if not sim.mailboxOpen then error("mailbox closed: ClickSendMailItemButton") end
        if clear then
            local a = sim.attach[i]
            if a then
                sim.attach[i] = nil
                if a.commit then a.commit, a.commitAll = nil, nil   -- never left the bags
                else sim:returnToBags(a) end
                sim:disturbBags(nil)
            end
            return
        end
        if sim.cursor then
            local old = sim.attach[i]
            local c = sim.cursor
            -- THE PROVEN 11509 BEHAVIOUR. A PARTIAL stack clicked onto the send form
            -- takes the WHOLE stack with it — the owner asked for 7 out of 10 and
            -- the form came back holding 10, every time. The remainder is swallowed
            -- along with it, so the commit becomes "clear the source slot".
            if sim.formWholeStack and c.partial and c.srcCount then
                c.count  = c.srcCount
                c.commit = c.commitAll or c.commit
                if not sim.retainBags then
                    -- No retention: the slot empties on the usual deferred tick.
                    local fn = c.commit
                    c.commit, c.commitAll = nil, nil
                    sim:deferBag(fn, c.srcBag, c.srcSlot)
                end
                c.partial = false
            end
            sim.attach[i] = c
            sim.cursor = old
            sim.attachClicks = (sim.attachClicks or 0) + 1
        else
            local a = sim.attach[i]
            if a then sim.attach[i] = nil; sim.cursor = a end
        end
        sim:Fire("BAG_UPDATE")
    end
    G.SetSendMailMoney = function(c)
        if not sim.mailboxOpen then error("mailbox closed: SetSendMailMoney") end
        sim.money = c or 0
    end
    G.GetSendMailMoney = function() return sim.money end
    G.GetMoney = function() return sim.wallet end
    G.GetCoinTextureString = function(c) return tostring(c) .. "c" end

    local function editbox()
        local t = { _t = "" }
        function t:GetText() return self._t end
        function t:SetText(v) self._t = v or "" end
        return t
    end
    G.SendMailNameEditBox    = editbox()
    G.SendMailSubjectEditBox = editbox()
    G.SendMailBodyEditBox    = editbox()
    G.SendMailFrame = { IsShown = function() return sim.mailboxOpen end }
    G.MailFrame = { IsShown = function() return sim.mailboxOpen end, HookScript = function() end }

    -- Blizzard's Send button. Disable/Enable are counted so the harness can prove
    -- the 0.2s re-assert ticker exists and is released at the terminal state.
    G.SendMailMailButton = {
        Disable = function(self) sim.buttonEnabled = false; sim.disableCalls = sim.disableCalls + 1 end,
        Enable  = function(self) sim.buttonEnabled = true;  sim.enableCalls  = sim.enableCalls  + 1 end,
        IsEnabled = function() return sim.buttonEnabled end,
    }

    -- The virtual clock, as C_Timer.
    G.C_Timer = {
        After = function(sec, fn) sim:schedule(sec, fn) end,
        NewTimer = function(sec, fn)
            local t = sim:schedule(sec, fn)
            return { Cancel = function() t.cancelled = true end }
        end,
        NewTicker = function(sec, fn)
            local t = sim:schedule(sec, fn, sec)
            return { Cancel = function() t.cancelled = true end }
        end,
    }

    -- SendMail. Consumes the form (the client clears the attachment slots on a
    -- successful send), then answers on the clock according to `behaviour`.
    G.SendMail = function(recipient, subject, body)
        if not sim.mailboxOpen then error("mailbox closed: SendMail") end
        -- THE ONE-IN-FLIGHT INVARIANT, checked by the thing being mailed rather
        -- than by the thing doing the mailing: a second SendMail may not arrive
        -- while an earlier one is still unresolved.
        if (sim.unresolved or 0) > 0 then
            sim.violations = sim.violations or {}
            sim.violations[#sim.violations + 1] =
                ("SendMail to %s while %d earlier send(s) unresolved"):format(tostring(recipient), sim.unresolved)
        end
        sim.unresolved = (sim.unresolved or 0) + 1
        local idx = #sim.sent + 1
        local rec = {
            recipient = recipient, subject = subject,
            units = sim:AttachedUnits(), attachments = sim:AttachedCount(),
            desc = sim:AttachDesc(), money = sim.money, at = sim.now,
        }
        sim.sent[idx] = rec
        local mode = sim.behaviour(idx, rec) or "ok"
        rec.mode = mode

        -- Blizzard re-enables its own Send button on its internal frame updates
        -- while a send is in flight. If the engine does not re-assert the disable,
        -- this is what leaves it clickable mid-run.
        sim:schedule(0.05, function() sim.buttonEnabled = true end)

        if mode == "fail" then
            sim:schedule(sim.latency, function()
                sim.unresolved = sim.unresolved - 1
                sim:Fire("MAIL_FAILED")
            end)
            return
        end
        if mode == "noack" then return end     -- the server never answers

        -- The mail leaves: the form empties and the money goes.
        local consumed = rec.units
        sim:schedule(sim.latency, function()
            sim.unresolved = sim.unresolved - 1
            if mode ~= "noevidence" then
                for i = 1, sim.MAXATT do
                    local a = sim.attach[i]
                    -- THE MAIL GOES, SO NOW THE BAGS DO. On a retaining client this
                    -- is the ONLY moment an attached stack leaves the bags — which is
                    -- why the send engine's evidence check ("the form emptied and the
                    -- units did not come back") is the one that still works.
                    if a and a.commit then local fn = a.commit; a.commit = nil; fn() end
                    sim.attach[i] = nil
                end
                sim.wallet = sim.wallet - (rec.money or 0) - 30
                sim.money = 0
            end
            -- THE BAGS ARE PUT IN MOTION *BEFORE* THE SUCCESS IS ANNOUNCED. That
            -- ordering is the whole bug: the engine hears MAIL_SUCCESS while the
            -- containers are still locked, so anything it attaches in that window
            -- silently gets nothing.
            if mode ~= "noevidence" then sim:disturbBags(nil) end
            sim:Fire("MAIL_SUCCESS")
            if mode ~= "noevidence" then sim:Fire("PLAYER_MONEY") end
        end)
        rec.consumed = consumed
    end

    G.StaticPopupDialogs = G.StaticPopupDialogs or {}
    G.StaticPopup_Show = function(which, text, _, data)
        G.__POPUP = { which = which, text = text, data = data }
        return G.__POPUP
    end
    G.StaticPopup_Hide = function() G.__POPUP = nil end
    G.YES, G.CANCEL = "Yes", "Cancel"
end

-- Accept the pending confirm popup (the ONE user interaction a run needs).
function M:Accept(G)
    local p = G.__POPUP
    if not p then return false end
    G.StaticPopupDialogs["DASEEKI_CONDUIT_SEND_CONFIRM"].OnAccept(nil, p.data)
    return true
end

-- Close the mailbox mid-run, the way walking away does. The client returns
-- everything staged on the form to the player and empties it — which is exactly
-- why the engine's abort must NOT touch the (now mailbox-gated) form on this path.
function M:CloseMailbox(ns)
    for i = 1, self.MAXATT do
        local a = self.attach[i]
        if a then
            self.attach[i] = nil
            if a.commit then a.commit, a.commitAll = nil, nil   -- never left the bags
            else self:returnToBags(a) end
        end
    end
    if self.cursor then
        local c = self.cursor; self.cursor = nil
        if c.commit then c.commit, c.commitAll = nil, nil else self:returnToBags(c) end
    end
    self.money = 0
    if _G.SendMailNameEditBox then _G.SendMailNameEditBox:SetText("") end
    if _G.SendMailSubjectEditBox then _G.SendMailSubjectEditBox:SetText("") end
    self.mailboxOpen = false
    ns:MailboxOpened()
    ns:CloseWithMailbox("MAIL_CLOSED")
end

return M
