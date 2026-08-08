--[[
    Daseeki Conduit — boons.lua

    CHRONOBOON REPLENISHMENT: one click at the mailbox tops every level-60
    character in the mesh back up to a full pocket of Chronoboon Displacers.

    The shape of the problem, and therefore the shape of this file:

      * ONE character does the sending. Boons live in the bank alt's bags; the
        rest of the roster is somewhere else entirely. So a SOURCE is designated
        once (an account-wide setting, picked off the same Nexus roster the rule
        editor's Alt dropdown uses) and the button only arms on that character.

      * WHO NEEDS WHAT comes from Nexus's inventory graph, not from the game.
        There is no way to ask the server what an offline alt is carrying. Nexus
        already keeps `inventory.owners[key].data.itemCounts`, so the plan is
        arithmetic over a snapshot: need = 10 - what the snapshot says they hold.

      * THAT SNAPSHOT LAGS. A character last seen three days ago may have burned
        every boon since. This file therefore never hides the data's age: every
        target line in the confirm preview carries how old its count is, and a
        character with no inventory data at all says so in as many words. The
        preview IS the safety net — nothing is sent without reading it.

      * THE SOURCE CAN ONLY SEND WHAT IS IN ITS BAGS. The bank is unreachable
        from a mailbox, so stock is counted live off C_Container and never off
        the mesh. When stock cannot cover the total need, targets are filled in
        DESCENDING-NEED order — the character on zero is worth more than the
        character on nine — and the shortfall is stated plainly in the preview
        and again in the completion line.

    ── The two judgement calls on unknown data ───────────────────────────────────
    network.lua's standing doctrine is "unknown is not a conflict": an alt whose
    faction no graph records is still offered, because a missing field is not
    evidence. That doctrine is kept HERE for faction and broken for LEVEL, and
    the reason is what a wrong guess costs:

      * unknown FACTION, guessed wrong -> the mail bounces back to you. Nothing
        is lost but a round trip, and every character in a personal mesh is
        overwhelmingly likely to be reachable. So an unknown faction is INCLUDED.
      * unknown LEVEL, guessed wrong  -> ten boons sit forever on a level-12
        bank mule. Boons are scarce and the loss is not recoverable by waiting.
        So an unknown level is EXCLUDED — and NAMED in the preview, because a
        character silently missing from the plan is the other way to lose.

    ── Purity ────────────────────────────────────────────────────────────────────
    Everything above the LIVE WRAPPERS bar is pure: no WoW API at call time, every
    input injected. The plan builder in particular is the piece the self-test
    harness mutation-tests, so it must stay a function of its arguments alone.

    Clean-room: the Chronoboon Displacer's item id was read from OUR OWN
    Daseeki-Nexus tracker.lua (CHRONOBOON_ITEMS). No third-party source was opened.
--]]

local ADDON, ns = ...

local Boons = {}
ns.Boons = Boons

-- ════════════════════════════════════════════════════════════════════════════
--  Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Chronoboon Displacer (Classic Era). Same id Daseeki-Nexus tracks the boon
-- cooldown and the boon aura with (tracker.lua CHRONOBOON_ITEMS = { 184937,
-- 184938 }). 184938 is the SUPERCHARGED variant — a transient state of a boon
-- that already left the stack, never a thing you stock or mail — so it is
-- deliberately not part of the count or the send.
Boons.ITEM_ID   = 184937
Boons.ITEM_NAME = "Chronoboon Displacer"

-- A full pocket. The owner's number, and the item's stack size.
Boons.TARGET = 10

-- Only a raiding character is worth stocking.
Boons.MIN_LEVEL = 60

-- ════════════════════════════════════════════════════════════════════════════
--  PURE helpers
-- ════════════════════════════════════════════════════════════════════════════

-- The name part of "Name" or "Name-Realm", folded. "" for anything unusable —
-- and "" never compares equal to a real name, which is what makes an absent
-- source read as "no source" rather than as "matches everybody".
local function baseLower(name)
    if type(name) ~= "string" then return "" end
    local base = name:match("^([^-]+)") or name
    base = base:match("^%s*(.-)%s*$")
    return base:lower()
end

-- "Alliance"/"Horde", or nil. Anything we cannot compare reads as UNKNOWN.
local function faction(v)
    if v == "Alliance" or v == "Horde" then return v end
    return nil
end

-- A whole non-negative count from anything.
local function count(v)
    local n = tonumber(v)
    if not n or n ~= n or n < 0 then return 0 end   -- n ~= n catches NaN
    return math.floor(n)
end

-- How many of `itemID` a roster entry's Nexus snapshot says the character holds.
-- No snapshot at all is 0 — which is exactly what makes an unknown character
-- read as "needs a full ten", per the owner's rule. The AGE is what tells the
-- difference between a real zero and no data, and the preview always shows it.
local function held(entry, itemID)
    if type(entry) ~= "table" then return 0 end
    if ns.Network and ns.Network.ItemCount then
        return ns.Network.ItemCount(entry, itemID)
    end
    if type(entry.counts) ~= "table" then return 0 end
    return count(entry.counts[itemID])
end

-- Data age as a short human span. Pure; `secs` is already a difference.
--   nil / negative-ish  -> nil   (the caller prints "no inventory data")
function Boons.FormatAge(secs)
    local n = tonumber(secs)
    if not n then return nil end
    if n < 0 then n = 0 end
    if n < 90 then return "just now" end
    if n < 3600 then return ("%dm"):format(math.floor(n / 60)) end
    if n < 172800 then return ("%dh"):format(math.floor(n / 3600)) end
    return ("%dd"):format(math.floor(n / 86400))
end

-- Is there any mesh inventory data at all to plan from? One owner carrying an
-- itemCounts map is enough; none at all means Nexus is absent, disabled, or has
-- never scanned, and the feature degrades to a hint rather than to a plan that
-- would hand every character a full ten on no evidence whatsoever.
function Boons.MeshReady(entries)
    if type(entries) ~= "table" then return false end
    for _, e in ipairs(entries) do
        if type(e) == "table" and type(e.counts) == "table" then return true end
    end
    return false
end

-- ════════════════════════════════════════════════════════════════════════════
--  THE PLAN BUILDER  (pure; the mutation-tested core)
-- ════════════════════════════════════════════════════════════════════════════

-- Turn a Nexus roster + a live bag stock into the exact list of mails to send.
--
--   entries : Network.CollectAlts-shaped rows, each optionally carrying
--             { level = <number>, counts = { [itemID] = n }, countsAt = <epoch> }
--   opts    = { source   = "Bankalt",   -- base name; never a target of itself
--               faction  = "Alliance",  -- the SOURCE's faction, not the viewer's
--               stock    = 23,          -- sendable units in the source's BAGS
--               target   = 10, minLevel = 60, itemID = 184937,
--               inFlight = { ["erro"] = 1 },  -- already posted, not yet arrived
--               now      = <epoch> }    -- for the age column; nil = no ages
--
-- IN-FLIGHT IS OWNED. Cross-account mail takes an hour to land, so for that hour
-- the mesh snapshot still shows the count from BEFORE the top-up. Counting what the
-- outbound ledger (ledger.lua) says is already on its way as though it had arrived
-- is what stops an interrupted run from posting the same boons twice when it is
-- re-run — the plan simply no longer asks for them.
--
-- Returns a plan:
--   { targets = { { name, realm, class, faction, level, have, inTransit, need,
--                   send, partial, age, ageText }, ... },   -- in SEND order
--     skipped = { { name, kind, reason }, ... },      -- kind: source/faction/
--                                                    -- level/unknownLevel/stocked
--     counts  = { source=, faction=, level=, unknownLevel=, stocked= },
--     stock, totalNeed, totalSend, shortfall, remaining, target, itemID }
--
-- ORDER IS THE RATIONING RULE: descending need, name as the tiebreak so the same
-- mesh always plans the same way. Stock is then walked down that list, which is
-- what puts the character on zero ahead of the character on nine when there is
-- not enough to go round. A target the stock cannot reach stays in the list with
-- send = 0 rather than vanishing — an omission is not a report.
function Boons.BuildPlan(entries, opts)
    opts = (type(opts) == "table") and opts or {}

    local target   = tonumber(opts.target)   or Boons.TARGET
    local minLevel = tonumber(opts.minLevel) or Boons.MIN_LEVEL
    local itemID   = tonumber(opts.itemID)   or Boons.ITEM_ID
    local stock    = count(opts.stock)
    local now      = tonumber(opts.now)
    local srcName  = baseLower(opts.source)
    local srcSide  = faction(opts.faction)
    local inFlight = (type(opts.inFlight) == "table") and opts.inFlight or {}

    local plan = {
        targets = {}, skipped = {},
        counts  = { source = 0, faction = 0, level = 0, unknownLevel = 0, stocked = 0 },
        stock   = stock, totalNeed = 0, totalSend = 0, shortfall = 0, remaining = stock,
        target  = target, minLevel = minLevel, itemID = itemID, source = opts.source,
    }

    local function skip(name, kind, reason)
        plan.skipped[#plan.skipped + 1] = { name = name, kind = kind, reason = reason }
        plan.counts[kind] = (plan.counts[kind] or 0) + 1
    end

    for _, e in ipairs((type(entries) == "table") and entries or {}) do
        if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
            local lower = baseLower(e.name)
            local lvl   = tonumber(e.level)
            local side  = faction(e.faction)

            if lower == srcName then
                -- The source never mails itself; its own bags ARE the stock.
                skip(e.name, "source", "the sending character")
            elseif srcSide and side and side ~= srcSide then
                skip(e.name, "faction", "other faction")
            elseif not lvl or lvl <= 0 then
                skip(e.name, "unknownLevel", "level unknown")
            elseif lvl < minLevel then
                skip(e.name, "level", ("level %d"):format(math.floor(lvl)))
            else
                local have    = held(e, itemID)
                local transit = count(inFlight[lower])
                local owned   = have + transit
                local need    = target - owned
                if need <= 0 then
                    -- A character whose pocket is only full because of a mail still
                    -- in the post says so, in as many words: "has 9, 1 in transit"
                    -- is the difference between a plan that is finished and a plan
                    -- that is about to send a second copy.
                    skip(e.name, "stocked",
                         (transit > 0) and ("has %d, %d in transit"):format(have, transit)
                                        or  ("has %d"):format(have))
                else
                    local at  = tonumber(e.countsAt)
                    local age = (now and at) and (now - at) or nil
                    plan.targets[#plan.targets + 1] = {
                        name = e.name, realm = e.realm, class = e.class,
                        faction = side, level = lvl,
                        have = have, inTransit = transit, need = need, send = 0,
                        age = age, ageText = Boons.FormatAge(age),
                        hasData = (type(e.counts) == "table") or nil,
                    }
                    plan.totalNeed = plan.totalNeed + need
                end
            end
        end
    end

    table.sort(plan.targets, function(a, b)
        if a.need ~= b.need then return a.need > b.need end
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)

    local remaining = stock
    for _, t in ipairs(plan.targets) do
        local give = t.need
        if give > remaining then give = remaining end
        if give < 0 then give = 0 end
        t.send = give
        t.partial = (give > 0 and give < t.need) or nil
        remaining = remaining - give
        plan.totalSend = plan.totalSend + give
    end
    plan.remaining  = remaining
    plan.shortfall  = plan.totalNeed - plan.totalSend
    plan.mailCount  = 0
    for _, t in ipairs(plan.targets) do
        if t.send > 0 then plan.mailCount = plan.mailCount + 1 end
    end
    return plan
end

-- ════════════════════════════════════════════════════════════════════════════
--  STOCK + QUEUE  (pure)
-- ════════════════════════════════════════════════════════════════════════════

-- Sendable units across an array of { itemID, count } slot descriptors.
function Boons.CountStock(stacks, itemID)
    local total = 0
    for _, s in ipairs((type(stacks) == "table") and stacks or {}) do
        if type(s) == "table" and (itemID == nil or s.itemID == nil or s.itemID == itemID) then
            total = total + count(s.count)
        end
    end
    return total
end

-- Turn the plan into mail.lua's queue shape: ONE mail per funded target, its
-- attachments drawn out of the source's real bag slots in bag order.
--
-- Each attachment is { bag, slot, itemID, count, exact = true }. `exact` is what
-- makes a partial send possible at all — it tells mail.lua to SPLIT the stack to
-- `count` instead of picking the whole thing up (see attachMail), and a top-up is
-- the one job that has a reason to leave boons behind in the slot. A draw is never
-- larger than what that slot still has UNCLAIMED by an earlier mail in this same
-- queue, because the pool below decrements as it goes; two mails may still
-- legitimately share one slot, the second simply asks for what the first left.
function Boons.BuildQueue(plan, stacks, opts)
    opts = (type(opts) == "table") and opts or {}
    local itemID    = (plan and tonumber(plan.itemID)) or Boons.ITEM_ID
    local maxAttach = tonumber(opts.maxAttach) or 12
    if maxAttach < 1 then maxAttach = 1 end
    local subject   = opts.subject or "Daseeki Conduit"
    local unitLabel = opts.unitLabel or Boons.ITEM_NAME

    local pool = {}
    for _, s in ipairs((type(stacks) == "table") and stacks or {}) do
        if type(s) == "table" then
            local left = count(s.count)
            if left > 0 and (s.itemID == nil or s.itemID == itemID) then
                pool[#pool + 1] = { bag = s.bag, slot = s.slot, itemID = itemID, left = left }
            end
        end
    end

    local queue = {}
    for _, t in ipairs((plan and plan.targets) or {}) do
        local want, draws, units = count(t.send), {}, 0
        for _, p in ipairs(pool) do
            if want <= 0 or #draws >= maxAttach then break end
            if p.left > 0 then
                local take = p.left
                if take > want then take = want end
                draws[#draws + 1] = { bag = p.bag, slot = p.slot, itemID = itemID,
                                      count = take, exact = true }
                p.left = p.left - take
                want   = want - take
                units  = units + take
            end
        end
        if #draws > 0 then
            queue[#queue + 1] = {
                recipient = t.name, subject = subject, stacks = draws,
                units = units, unitLabel = unitLabel,
                -- `units` is the engine's SEND GUARD (mail.lua verifyAttach refuses
                -- to send a form that does not hold exactly this many), and
                -- `itemID` is what the outbound ledger records on a confirmed send.
                itemID = itemID,
                -- THE DELIVERY BASELINE (CDT-2). What the plan saw this recipient
                -- holding when it decided to mail them. The ledger retires the
                -- entry on a snapshot that has RISEN by `units` from here — an
                -- absolute count proves nothing, because qty is itself derived
                -- from `have` and the two collide for anyone half-stocked.
                -- tonumber, NOT count(): a target with no readable holding must
                -- record NO baseline, and count() would fabricate a zero — which is
                -- the most dangerous baseline there is (every snapshot beats it).
                base = tonumber(t.have),
            }
        end
    end
    return queue
end

-- ════════════════════════════════════════════════════════════════════════════
--  THE ARMING MATRIX  (pure)
-- ════════════════════════════════════════════════════════════════════════════

-- What the panel's boon row should be, given everything that decides it.
--
--   ctx = { source =, me =, mailbox = <bool>, mesh = <bool>,
--           disabled = <bool>, active = <bool> }
--
-- Returns state, hint where state is one of:
--   "off"        no source designated  -> the row is not drawn at all. The
--                feature is opt-in, so a panel nobody configured looks exactly
--                like it did before this feature existed.
--   "elsewhere"  this is not the source -> a muted hint naming who sends.
--   "nomesh"     no Nexus inventory data to plan from -> a muted hint.
--   "nomailbox"  no mailbox open        -> the button, greyed.
--   "disabled"   Conduit off here       -> the button, greyed.
--   "busy"       a send is in flight    -> the button, greyed.
--   "armed"      go.
--
-- Order is deliberate: WHO you are is decided before WHAT data exists, because
-- "Poonyx sends the boons" is the useful sentence on the other nine characters,
-- and a Nexus complaint there would be noise about a machine they do not drive.
function Boons.ButtonState(ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    local src = (type(ctx.source) == "string") and ctx.source:match("^%s*(.-)%s*$") or ""
    if src == "" then return "off", nil end

    if baseLower(ctx.me) ~= baseLower(src) then
        return "elsewhere", ("Boon replenishment sends from %s."):format(src)
    end
    if not ctx.mesh then
        return "nomesh", "Boon replenishment needs Daseeki Nexus inventory data."
    end
    if not ctx.mailbox then return "nomailbox", nil end
    if ctx.disabled then return "disabled", nil end
    if ctx.active then return "busy", nil end
    return "armed", nil
end

-- Does this state draw a clickable button (as opposed to a hint line, or nothing)?
function Boons.StateShowsButton(state)
    return state == "armed" or state == "nomailbox"
        or state == "disabled" or state == "busy"
end

-- WHY a drawn button will not fire, in the user's own words.
--
-- A greyed button is mute: it says "Replenish Boons", refuses the click, and never
-- says which of the three gates is shut — which is exactly the report that opened
-- this fix ("the button is greyed and the panel says Ready"). The tooltip asks
-- THIS function, and the panel passes it the SAME state string it drew the alpha
-- from, so the sentence and the greying can never disagree; a second derivation
-- from the live world could (and did) drift.
--
-- nil means "nothing to explain": either the row is armed, or the state draws no
-- button at all ("off" draws nothing; "elsewhere"/"nomesh" already speak through
-- the hint line, which is a fuller sentence than a tooltip footnote).
function Boons.StateReason(state)
    if state == "nomailbox" then return "Open a mailbox to send." end
    if state == "disabled"  then return "Conduit is disabled on this character." end
    if state == "busy"      then return "A send is already running." end
    return nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  THE CONFIRM PREVIEW  (pure text; every colour degrades to plain)
-- ════════════════════════════════════════════════════════════════════════════

local function ageBit(t)
    if t.ageText then return "seen " .. t.ageText .. " ago" end
    return "no inventory data"
end

-- "has 3" / "has 3, 2 in transit" — the held count, and what is already in the post
-- to that character. Never hidden: a number the reader cannot see is a number they
-- cannot correct, and "in transit" is the whole reason a target is asking for less.
local function haveBit(t)
    if (t.inTransit or 0) > 0 then
        return ("has %d, %d in transit"):format(t.have, t.inTransit)
    end
    return ("has %d"):format(t.have)
end

-- The dry-run block the send-confirm popup shows. Nothing sends until this has
-- been read and accepted, so it lists EVERY target and every amount, states the
-- rationing rule when it is about to bite, and never leaves the age of a count
-- off a line.
function Boons.PreviewText(plan, opts)
    opts = (type(opts) == "table") and opts or {}
    local wrap = opts.wrap or function(_, text) return tostring(text) end
    local lines = {}

    lines[#lines + 1] = ("Top up %s to %s each?")
        :format(wrap("text", Boons.ITEM_NAME), wrap("text", plan.target))
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("In bags: %s   Sending: %s in %s mail(s)")
        :format(wrap("text", plan.stock), wrap("text", plan.totalSend), wrap("text", plan.mailCount))

    if plan.shortfall > 0 then
        lines[#lines + 1] = wrap("danger",
            ("%d short of the %d needed — biggest need is filled first.")
                :format(plan.shortfall, plan.totalNeed))
    end

    lines[#lines + 1] = ""
    for _, t in ipairs(plan.targets) do
        local name = wrap("text", t.name)
        if t.send >= t.need then
            lines[#lines + 1] = ("%s  <-  %d   (%s, %s)")
                :format(name, t.send, haveBit(t), ageBit(t))
        elseif t.send > 0 then
            lines[#lines + 1] = ("%s  <-  %d of %d   (%s, %s)")
                :format(name, t.send, t.need, haveBit(t), ageBit(t))
        else
            lines[#lines + 1] = wrap("muted",
                ("%s  <-  none of %d   (%s, %s)"):format(t.name, t.need, haveBit(t), ageBit(t)))
        end
    end

    -- Characters left out BECAUSE something is already on its way to them. This is
    -- the line that stops a re-run after an interruption looking like a bug: the
    -- boons are not missing, they are in the post.
    do
        local transit = {}
        for _, s in ipairs(plan.skipped) do
            if s.kind == "stocked" and tostring(s.reason):find("in transit", 1, true) then
                transit[#transit + 1] = ("%s (%s — nothing to send)"):format(s.name, s.reason)
            end
        end
        if #transit > 0 then
            table.sort(transit)
            lines[#lines + 1] = ""
            lines[#lines + 1] = wrap("muted", "Already on its way: " .. table.concat(transit, ", "))
        end
    end

    local c = plan.counts
    if c.unknownLevel > 0 then
        local names = {}
        for _, s in ipairs(plan.skipped) do
            if s.kind == "unknownLevel" then names[#names + 1] = s.name end
        end
        table.sort(names)
        lines[#lines + 1] = ""
        lines[#lines + 1] = wrap("muted",
            ("Left out, level not known yet: %s"):format(table.concat(names, ", ")))
    end
    local quiet = c.stocked + c.level + c.faction
    if quiet > 0 then
        if c.unknownLevel == 0 then lines[#lines + 1] = "" end
        lines[#lines + 1] = wrap("muted",
            ("%d skipped (already stocked / under %d / other faction)."):format(quiet, plan.minLevel or 60))
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = wrap("muted", "Counts come from Daseeki Nexus and include the bank.")
    return table.concat(lines, "\n")
end

-- The one-line completion report, given what actually went out.
function Boons.FinishLine(plan, stats)
    stats = (type(stats) == "table") and stats or {}
    local units = count(stats.units)
    local mails = count(stats.mails)
    local base  = ("boons — sent %d to %d character(s)."):format(units, mails)
    if plan and count(plan.shortfall) > 0 then
        base = base .. (" Still %d short of a full pocket everywhere — restock and run again.")
            :format(plan.shortfall)
    end
    return base
end

-- ════════════════════════════════════════════════════════════════════════════
--  LIVE WRAPPERS  (in-game only; everything above stays pure)
-- ════════════════════════════════════════════════════════════════════════════

-- The designated source, account-wide. nil when the feature was never set up.
function Boons.GetSource()
    local db = ns.db
    if not (db and type(db.settings) == "table") then return nil end
    local v = db.settings.boonSource
    if type(v) ~= "string" then return nil end
    v = v:match("^%s*(.-)%s*$")
    if v == "" then return nil end
    return v
end

function Boons.SetSource(name)
    local db = ns.db
    if not db then return end
    db.settings = db.settings or {}
    if type(name) ~= "string" or name:match("^%s*(.-)%s*$") == "" then
        db.settings.boonSource = nil
    else
        db.settings.boonSource = name:match("^%s*(.-)%s*$")
    end
end

-- The same-realm roster, INCLUDING the logged-in character (a source picker must
-- be able to name the character you are configuring it from).
local function roster()
    if not (ns.Network and ns.Network.GetRoster) then return {} end
    return ns.Network.GetRoster()
end

-- Mailable boon stacks in THIS character's bags, in bag order. One scanner, in
-- rules.lua, because the send engine re-derives its draws from the SAME scan
-- immediately before each attach — two scanners would be two answers.
function Boons.ScanStacks(itemID)
    itemID = itemID or Boons.ITEM_ID
    local R = ns.Rules
    if not (R and R.ScanStacksForItem) then return {} end
    return R.ScanStacksForItem(itemID)
end

-- What the mesh has SEEN of each character's boon count, and when. This is the
-- evidence the outbound ledger retires entries against: a snapshot taken AFTER a
-- send, showing at least what we posted, means the mail arrived.
function Boons.MeshSnapshot(entries, itemID)
    itemID = itemID or Boons.ITEM_ID
    local out = {}
    for _, e in ipairs((type(entries) == "table") and entries or {}) do
        if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
            out[baseLower(e.name)] = { count = held(e, itemID), at = tonumber(e.countsAt) }
        end
    end
    return out
end

-- The live plan: mesh roster + the outbound ledger + this character's bags.
-- Returns plan, stacks.
--
-- The ledger is SWEPT first, so anything the mesh has already confirmed delivered
-- stops being counted as in-flight before it can suppress a top-up that is really
-- due. Sweep, then read: in that order, or a delivered mail keeps a character off
-- the list for thirty days.
function Boons.Plan()
    local entries = roster()
    local src     = Boons.GetSource() or (UnitName and UnitName("player")) or ""
    local srcRow  = ns.Network and ns.Network.FindEntry and ns.Network.FindEntry(entries, src) or nil
    local side    = (srcRow and srcRow.faction)
        or (UnitFactionGroup and UnitFactionGroup("player")) or nil
    local stacks  = Boons.ScanStacks()
    local now     = (time and time()) or nil

    local inFlight = nil
    if ns.Ledger then
        ns.Ledger.Sweep(Boons.MeshSnapshot(entries, Boons.ITEM_ID), now)
        inFlight = ns.Ledger.InFlight(ns.Ledger.Entries(), Boons.ITEM_ID, now)
    end

    local plan = Boons.BuildPlan(entries, {
        source  = src, faction = side,
        stock   = Boons.CountStock(stacks, Boons.ITEM_ID),
        target  = Boons.TARGET, minLevel = Boons.MIN_LEVEL, itemID = Boons.ITEM_ID,
        inFlight = inFlight,
        now     = now,
    })
    return plan, stacks
end

-- The panel's state for the boon row, from the live world.
function Boons.State()
    return Boons.ButtonState({
        source   = Boons.GetSource(),
        me       = UnitName and UnitName("player") or nil,
        mailbox  = (_G.MailFrame and _G.MailFrame:IsShown()) and true or false,
        mesh     = Boons.MeshReady(roster()),
        disabled = ns:IsCharDisabled(),
        active   = ns.Mail and ns.Mail.IsActive() or false,
    })
end

-- The button's click. Builds the plan, builds the queue, and hands both to the
-- EXISTING send engine — same confirm-before-send popup, same one-mail-per-click
-- stepping, same mailbox-close abort, same MAIL_FAILED handling. There is no
-- second mail path in this addon and this feature does not add one.
function Boons.Run()
    if not (ns.Mail and ns.Mail.RunQueue) then return false end

    local state = Boons.State()
    if state ~= "armed" then
        if state == "elsewhere" then
            ns:Print(("boons are sent from %s."):format(Boons.GetSource() or "?"))
        elseif state == "nomesh" then
            ns:Print("no Daseeki Nexus inventory data — cannot tell who needs boons.")
        elseif state == "off" then
            ns:Print("no boon source set — pick one in /conduit settings.")
        end
        return false
    end

    local plan, stacks = Boons.Plan()
    if plan.stock <= 0 then
        ns:Print(("no %s in your bags."):format(Boons.ITEM_NAME))
        return false
    end
    if #plan.targets == 0 then
        ns:Print("every level-60 character in the mesh already has a full pocket of boons.")
        return false
    end

    local queue = Boons.BuildQueue(plan, stacks, {
        maxAttach = ns.MAX_ATTACH, subject = ns.MAIL_SUBJECT,
    })
    if #queue == 0 then
        ns:Print("nothing to send — the boons moved out of your bags.")
        return false
    end

    local text = Boons.PreviewText(plan, { wrap = function(tok, s) return ns:Wrap(tok, s) end })

    -- IDEMPOTENCE BY CONSTRUCTION, not by memory. The engine is handed two ways to
    -- re-ask the same question it was handed a preview of:
    --
    --   rebuild — re-derive the WHOLE queue at run start, from the mesh + the
    --             outbound ledger + the bags as they are at that moment. A run
    --             interrupted at 2 of 8 and started again plans the remaining six,
    --             because the two that went are now in the ledger and the plan no
    --             longer asks for them.
    --   check   — re-ask for ONE target immediately before its attachments are
    --             picked up, which catches anything that changed DURING the run.
    --
    -- Neither remembers where a previous run got to. They do not have to.
    local function derive()
        local p, s = Boons.Plan()
        return Boons.BuildQueue(p, s, { maxAttach = ns.MAX_ATTACH, subject = ns.MAIL_SUBJECT }), p
    end

    return ns.Mail.RunQueue(queue, text, {
        onFinish = function(stats) ns:Print(Boons.FinishLine(plan, stats)) end,
        rebuild  = function()
            local q, p = derive()
            plan = p            -- the completion line reports the plan that RAN
            return q
        end,
        check = function(mail)
            local p = Boons.Plan()
            for _, t in ipairs(p.targets) do
                if baseLower(t.name) == baseLower(mail.recipient) then
                    if t.need >= (tonumber(mail.units) or 0) then return true end
                    return false, ("only needs %d now"):format(t.need)
                end
            end
            return false, "already topped up (or on its way)"
        end,
    })
end

-- ── /conduit debug boons ─────────────────────────────────────────────────────
--
-- What the planner currently believes, and WHY — the plan, and the outbound ledger
-- with ages, which is the piece a user cannot otherwise see and the one that
-- silently suppresses top-ups while it holds an entry.
function Boons.Debug(arg)
    local sub = (type(arg) == "string") and arg:lower() or ""
    if sub:match("^clear") then
        local n = ns.Ledger and ns.Ledger.Clear() or 0
        ns:Print(("outbound ledger cleared (%d entr%s dropped)."):format(n, n == 1 and "y" or "ies"))
        return
    end
    -- THE RELEASE PATH for staging's sticky verdict (CDT-3). It used to have none
    -- at all: one expired ceiling turned exact-quantity mailing off for the session
    -- and only /reload brought it back.
    if sub:match("^unblock") then
        local was, why = ns.Staging and ns.Staging.IsBlocked(), ns.Staging and ns.Staging.BlockedReason()
        if ns.Staging and ns.Staging.Unblock then ns.Staging.Unblock() end
        ns:Print(was
            and ("stack splitting re-armed (it was held off because %s).")
                :format(why == "api" and "this client has no split call"
                                     or  "the client refused the split three times running")
            or  "stack splitting was not held off — nothing to clear.")
        return
    end
    if sub:match("^tracec") or sub:match("^clear%s*trace") then
        local n = ns.Trace and ns.Trace.Clear() or 0
        ns:Print(("attach trace cleared (%d entr%s dropped)."):format(n, n == 1 and "y" or "ies"))
        return
    end

    -- THE BUILD, FIRST AND ALWAYS. Two rounds of field diagnosis were spent on
    -- theories that assumed the running code was the code we had just written. One
    -- glance at this line settles that before anything else is discussed.
    ns:Print(("build %s (version %s)"):format(tostring(ns.BUILD), tostring(ns.VERSION)))

    local src = Boons.GetSource()
    ns:Print(("boon source: %s"):format(src or "not set"))
    local entries = roster()
    ns:Print(("mesh rows: %d   mesh data: %s"):format(#entries, Boons.MeshReady(entries) and "yes" or "no"))

    local now = (time and time()) or 0
    if ns.Ledger then
        local rows = ns.Ledger.Describe(ns.Ledger.Entries(), now, Boons.FormatAge)
        if #rows == 0 then
            ns:Print("outbound ledger: empty (nothing in the post).")
        else
            ns:Print(("outbound ledger (%d in transit; /conduit debug boons clear to drop):"):format(#rows))
            for _, line in ipairs(rows) do ns:Print("  " .. line) end
        end
    end

    local plan = Boons.Plan()
    ns:Print(("plan: %d target(s), %d to send, stock %d, shortfall %d")
        :format(#plan.targets, plan.totalSend, plan.stock, plan.shortfall))
    for _, t in ipairs(plan.targets) do
        ns:Print(("  %s  <-  %d of %d  (has %d%s)")
            :format(t.name, t.send, t.need, t.have,
                    (t.inTransit or 0) > 0 and (", " .. t.inTransit .. " in transit") or ""))
    end

    -- ATTACH DIAGNOSTICS. What the client actually did to the bags while the last
    -- run was arming its mails. The live 1.2.0 failure — every mail refusing with
    -- "the form holds 0" — was undiagnosable from chat, and these are the numbers
    -- that would have named it in one line. Session-cumulative.
    if ns.Mail and ns.Mail.Diagnostics then
        local d = ns.Mail.Diagnostics()
        ns:Print(("attach: %d mail(s) armed, %d re-drawn from a fresh scan, %d stale coordinate(s)")
            :format(d.mails, d.redrawn, d.staleCoords))
        ns:Print(("  whole-stack pickups: %d delivered, %d via the legacy call, %d came away empty")
            :format(d.pickups, d.pickupFellBack, d.pickupFailed))
        ns:Print(("  draws refused: %d (%d on a locked slot, %d not a whole stack)   settle waits: %d (%d hit the ceiling)")
            :format(d.drawsRefused, d.lockedSlots, d.partialRefused, d.settleWaits, d.settleTimeouts))
        local cal = ns.Mail._FormCalibration and ns.Mail._FormCalibration()
        ns:Print(("  form counts: %s   disagreed with the stack picked up: %d   unreadable: %d   re-learned: %d")
            :format(cal and ("read from return #" .. cal) or "not calibrated yet",
                    d.formBagDisagree, d.formUnreadable, d.decalibrations))
        -- THE ONE LINE THAT NAMES THE 1.2.3 CLIENT BEHAVIOUR. A non-zero count here
        -- says the bags do not shrink while an attachment sits on the form, which is
        -- why the bag subtraction is no longer the send guard's authority.
        ns:Print(("  attaches where the bags did not move: %d (this client keeps them until the mail goes)")
            :format(d.bagsRetained))
    end

    -- PRE-SPLIT STAGING. Exact amounts are made in the bags before anything is
    -- attached; this is where a run that could not prepare one says why.
    if ns.Staging and ns.Staging.Diagnostics then
        local s = ns.Staging.Diagnostics()
        ns:Print(("staging: %d pass(es), %d split(s) asked, %d staged, %d served by stacks that were already exact")
            :format(s.passes, s.splits, s.staged, s.reusedExact))
        ns:Print(("  refused: %d no empty bag slot, %d client would not split, %d too slow to split, %d not placed, %d failed verification")
            :format(s.noFreeSlot, s.splitRefused, s.splitSlow, s.placeFailed, s.verifyFailed))
        -- SLOW AND REFUSED ARE DIFFERENT WORDS HERE, on purpose: the old line said
        -- "BLOCKED for this session" off a single expired ceiling, which is the
        -- falsehood CDT-3 is about.
        ns:Print(("  split ceiling: %.1fs next attempt   strikes: %d of %d%s")
            :format(ns.Staging.CursorCeiling(), ns.Staging.Strikes(),
                    ns.Staging.STRIKES_TO_BLOCK,
                    ns.Staging.IsBlocked()
                        and ("   [HELD OFF — " .. tostring(ns.Staging.BlockedReason())
                             .. "; /conduit debug boons unblock to re-arm]")
                        or ""))
    end

    -- THE TRACE. One line here; the detail lives in SavedVariables
    -- (DaseekiConduitDB.attachTrace) where it can be read after the fact.
    if ns.Trace then
        ns:Print("  " .. ns.Trace.Summary(ns.Trace.Ring(false), ns.Trace.CAP))
        ns:Print("  (full per-draw detail is saved to DaseekiConduitDB.attachTrace —"
            .. " /reload or log out to flush it, then send the file.)")
    end
end

return Boons
