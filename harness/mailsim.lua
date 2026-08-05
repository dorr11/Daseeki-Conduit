-- =====================================================================
-- Daseeki-Conduit harness — CLASSIC ERA MAILBOX SIMULATOR
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
--     through GetSendMailItem's fourth return, a money field, and a detach that
--     puts the stack back in the bags — because attaching takes the item OUT of
--     the bag, which is exactly why the send engine's evidence check has to count
--     bags plus form rather than bags alone;
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
            return { itemID = s.itemID, stackCount = s.count, isBound = s.isBound and true or false }
        end,
        PickupContainerItem = function(bag, slot)
            local b = sim.bags[bag]; local s = b and b[slot]
            if sim.cursor then
                if not s then b[slot] = sim.cursor; sim.cursor = nil
                else b[slot], sim.cursor = sim.cursor, s end
                return
            end
            if not s then return end
            sim.cursor = { itemID = s.itemID, count = s.count }
            b[slot] = nil
        end,
        SplitContainerItem = function(bag, slot, n)
            local b = sim.bags[bag]; local s = b and b[slot]
            if not s or sim.cursor then return end
            -- Attach poisoning: a client that hands back a different amount than
            -- was asked for is the whole reason the engine verifies the form.
            if sim.poison then n = sim.poison(bag, slot, n, s.count) or n end
            if n >= s.count then
                sim.cursor = { itemID = s.itemID, count = s.count }; b[slot] = nil
            else
                sim.cursor = { itemID = s.itemID, count = n }; s.count = s.count - n
            end
        end,
    }
    -- A client with no partial-stack API at all. This is the condition the pre-fix
    -- attach had a whole-stack fallback for, and the fallback was the bug.
    if sim.noSplit then G.C_Container.SplitContainerItem = nil end

    G.C_Item = { GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, 0, 0 end }
    G.NUM_BAG_SLOTS = 4
    G.ATTACHMENTS_MAX_SEND = sim.MAXATT

    G.CursorHasItem = function() return sim.cursor ~= nil end
    G.ClearCursor = function()
        if sim.cursor then sim:returnToBags(sim.cursor); sim.cursor = nil end
    end

    G.GetSendMailItem = function(i)
        local a = sim.attach[i]
        if not a then return nil end
        return "Item" .. a.itemID, a.itemID, nil, a.count, 1
    end
    G.ClickSendMailItemButton = function(i, clear)
        if not sim.mailboxOpen then error("mailbox closed: ClickSendMailItemButton") end
        if clear then
            local a = sim.attach[i]
            if a then sim.attach[i] = nil; sim:returnToBags(a) end
            return
        end
        if sim.cursor then
            local old = sim.attach[i]
            sim.attach[i] = sim.cursor
            sim.cursor = old
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
                for i = 1, sim.MAXATT do sim.attach[i] = nil end
                sim.wallet = sim.wallet - (rec.money or 0) - 30
                sim.money = 0
            end
            sim:Fire("MAIL_SUCCESS")
            sim:Fire("MAIL_SEND_SUCCESS")
            if mode ~= "noevidence" then
                sim:Fire("PLAYER_MONEY")
                sim:Fire("BAG_UPDATE_DELAYED")
            end
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
        if a then self.attach[i] = nil; self:returnToBags(a) end
    end
    if self.cursor then self:returnToBags(self.cursor); self.cursor = nil end
    self.money = 0
    if _G.SendMailNameEditBox then _G.SendMailNameEditBox:SetText("") end
    if _G.SendMailSubjectEditBox then _G.SendMailSubjectEditBox:SetText("") end
    self.mailboxOpen = false
    ns:MailboxOpened()
    ns:CloseWithMailbox("MAIL_CLOSED")
end

return M
