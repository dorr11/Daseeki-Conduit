--[[
    Daseeki Conduit — staging.lua

    PRE-SPLIT STAGING: make the exact stacks IN THE BAGS, before the mail form is
    ever touched.

    ── The proof this file exists for ────────────────────────────────────────────

    Three rounds of field failure were spent on theories about locks, about async
    counts, and about which return of GetSendMailItem carries a stack size. Every
    one of those was a real defect and every one of them is still fixed. None of
    them was the thing that kept the boons at home.

    The attach trace shipped in 1.2.2 settled it from one capture. Every attempt in
    the owner's run was identical:

        draw { bag = 4, slot = 1, pre = 10, locked = false, want = 7,
               exact = true, path = "split", cursor = true, click = true,
               post = 10, formSlot = 1 }
        raw  { "Chronoboon Displacer", "184937", "133879", "10", "1" }

    One attachment. Holding TEN. On an unlocked slot, on quiet bags, having asked
    for SEVEN. The owner saw the same thing with his own eyes: "the mail populated
    full stacks each time."

    So: **C_Container.SplitContainerItem(bag, slot, n) followed by
    ClickSendMailItemButton delivers the WHOLE STACK to the send form on this
    client.** That — not a lock, not a race, not a measurement — was the original
    20-boon over-attach in 1.2.0 and every refusal since. The guard has been right
    every single time; the thing it was guarding was broken.

    Two facts sit either side of it, and together they are the whole design:
      * WHOLE-stack attachment through the same click path works. Every incident
        successfully attached full stacks — that is precisely what went wrong.
      * BAG-TO-BAG splitting works. The owner splits stacks by hand every day.

    ── Therefore ────────────────────────────────────────────────────────────────

    Never split onto the mail form. To send seven out of a stack of ten:

      1. STAGE (here). Split seven off in the BAGS and drop it into an empty bag
         slot, so a discrete stack of exactly seven exists. Wait for the client to
         agree it exists, and verify the count.
      2. ATTACH (mail.lua). Pick that whole stack up and click it onto the form —
         the proven path, with no partial for the client to reinterpret.

    Staging is planned across the WHOLE RUN up front: one pass, one settlement wait,
    and then the mail loop attaches ready-made stacks. Per-mail staging still exists
    as the fallback for a run that outgrew its empty bag slots part-way through, but
    the common case pays the waiting once rather than once per mail.

    ── The refusals this file may produce, and why they are refusals ─────────────

    An exact draw that cannot be prepared is NOT rounded up to a whole stack. It is
    reported and skipped. Leaving boons in your bags is recoverable; posting ten of
    them to a character who needed three is not. Two honest stops live here:

      * no empty bag slot to stage into  -> say so, name how many are needed;
      * the client will not split bag-to-bag either -> say so ONCE, stop staging
        for the rest of the run, and tell the owner the manual way round
        ("put a stack of exactly N in your bags and run again").

    ── Purity ───────────────────────────────────────────────────────────────────
    Everything above the LIVE WRAPPERS bar is a function of its arguments alone.
    Plan() is where the arithmetic lives and it is what the harness mutation-drives;
    the live half is a sequencer with no decisions of its own.
--]]

local ADDON, ns = ...

local Staging = {}
ns.Staging = Staging

-- Ceilings (seconds). A wait that can hang is worse than a wait that gives up, and
-- every step re-checks the world after it resumes.
Staging.CURSOR_CEILING = 1.5   -- the split reaching the cursor (the FIRST rung)
Staging.PLACE_CEILING  = 1.5   -- the cursor reaching the destination slot
Staging.VERIFY_CEILING = 3.0   -- the client agreeing the new stack exists

-- THE CURSOR LADDER (CDT-3). A ceiling that expires is a measurement of SLOWNESS,
-- never a proof of REFUSAL, so each attempt after one expires waits longer than the
-- last. Bounded on purpose: three rungs, then the ladder stops widening.
Staging.CURSOR_LADDER = { 1.5, 4.0, 8.0 }

-- How many consecutive attempts must produce REFUSAL EVIDENCE (see runJob) before
-- the sticky verdict is written. A client that genuinely will not split fails the
-- same way every time; a world-server hiccup does not repeat itself three times
-- across three widening ceilings.
Staging.STRIKES_TO_BLOCK = 3

-- Session-cumulative diagnostics, in memory only (/conduit debug boons prints them).
local D = {
    planned      = 0,   -- part-stacks the planner asked for
    splits       = 0,   -- splits attempted
    staged       = 0,   -- ...that produced a verified stack of the right size
    reusedExact  = 0,   -- mails served by a stack that was ALREADY the right size
    noFreeSlot   = 0,   -- staging blocked for want of an empty bag slot
    splitRefused = 0,   -- the client would not split bag-to-bag (source untouched)
    splitSlow    = 0,   -- the split WAS happening, just not inside the ceiling
    placeFailed  = 0,   -- the split reached the cursor but not the slot
    verifyFailed = 0,   -- the staged slot did not hold what was asked for
    passes       = 0,   -- staging passes run
}
function Staging.Diagnostics() return D end
function Staging.ResetDiagnostics() for k in pairs(D) do D[k] = 0 end end

-- ── THE STICKY VERDICT, AND WHY IT IS NO LONGER A TIMEOUT (CDT-3) ────────────
--
-- Until 1.2.4 one expired 1.5s cursor ceiling latched `blocked` for the whole
-- session: every later exact-quantity mail was short-circuited with
-- BLOCKED_ADVICE — "this client will not split stacks" — which on a client that
-- splits perfectly well is simply FALSE. One loading-screen stutter, one busy
-- capital at raid-invite time, and the entire boon replenishment feature was off
-- until /reload, telling the owner a lie about his client on the way out.
--
-- A timeout is not evidence. Three things replace it:
--
--   1. THE LADDER. Every expired ceiling widens the next attempt's ceiling
--      (CURSOR_LADDER). The per-mail fallback in mail.lua re-attempts what the
--      up-front pass could not prepare, so a slow frame costs one wait and then
--      recovers inside the same run.
--   2. THE CLASSIFICATION. At the ceiling, the SOURCE SLOT is read. A split that
--      is merely late has already taken its units out of the source; a client that
--      did nothing at all leaves the source untouched. Only the untouched case is
--      refusal EVIDENCE and only it may strike.
--   3. THE STRIKES. STRIKES_TO_BLOCK consecutive evidence-bearing failures before
--      the verdict. Any success anywhere resets the count and the ladder.
--
-- A missing API is different in kind and still latches at once: C_Container with
-- no SplitContainerItem is a fact about the client, not a measurement of it.
--
-- And the latch has a RELEASE PATH now, which is what made it dangerous: Unblock()
-- had zero live callers and only /reload cleared it. It is cleared on MAIL_SHOW
-- (a new mailbox visit is a new chance to be wrong about this) and by
-- `/conduit debug boons unblock`.
local blocked   = false
local blockWhy  = nil     -- "refused" | "api"  — the verdict SAYS which it was
local strikes   = 0       -- consecutive refusal-evidence failures
local rung      = 1       -- index into CURSOR_LADDER for the next attempt

function Staging.IsBlocked() return blocked end
function Staging.BlockedReason() return blockWhy end
function Staging.Strikes() return strikes end

-- The ceiling the NEXT split attempt gets.
function Staging.CursorCeiling()
    local L = Staging.CURSOR_LADDER
    local r = rung
    if r < 1 then r = 1 end
    if r > #L then r = #L end
    return L[r] or Staging.CURSOR_CEILING
end

-- Widen for the next attempt, bounded by the end of the ladder.
local function widen()
    if rung < #Staging.CURSOR_LADDER then rung = rung + 1 end
end

-- A split that worked is proof the client splits. Forget every strike.
--
-- The LADDER is deliberately not wound back in: a client that needed 4s once will
-- need it again, and collapsing to the fast rung after every success makes every
-- single mail pay a wasted ceiling before the wait that works. It only ever widens,
-- it is bounded at the last rung, and Unblock() (MAIL_SHOW, or the debug command)
-- resets it — so it is re-learned every mailbox visit rather than latched for the
-- session. That is the Class 5 discipline: a calibration with a release path.
local function splitSucceeded()
    strikes = 0
end

function Staging.Unblock()
    blocked, blockWhy, strikes, rung = false, nil, 0, 1
end

Staging.BLOCKED_ADVICE =
    "this client will not split stacks for the mail — put a stack of exactly the amount you want in your bags and run again."
-- Said INSTEAD of the verdict while a timeout is still just a timeout. It names
-- slowness as slowness, because that is all that has been observed.
Staging.SLOW_ADVICE =
    "the client did not finish splitting a stack in time — the run will try again with a longer wait."

-- One line for whatever the staging pass came back with. Pure, so the harness can
-- drive every reason without a mailbox.
function Staging.Advice(why, isBlocked)
    if why == "api" then return Staging.BLOCKED_ADVICE end
    if isBlocked then return Staging.BLOCKED_ADVICE end
    if why == "blocked" then return Staging.BLOCKED_ADVICE end
    if why == "slowsplit" then return Staging.SLOW_ADVICE end
    if why == "split" then
        -- Refusal evidence, but not yet enough of it to say so out loud.
        return Staging.SLOW_ADVICE
    end
    return nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE — THE STAGING PLAN
-- ════════════════════════════════════════════════════════════════════════════

local function whole(v)
    local n = tonumber(v)
    if not n or n ~= n or n < 0 then return 0 end
    return math.floor(n)
end

-- Turn a mail queue into the list of exact quantities staging has to serve.
-- Only mails that name an ITEM and a UNIT COUNT are exact draws; a rule-based
-- "send my herbs" mail takes whole stacks by definition and needs nothing here.
function Staging.Wants(queue)
    local out = {}
    for i, m in ipairs((type(queue) == "table") and queue or {}) do
        if type(m) == "table" and m.itemID and tonumber(m.units) then
            local n = whole(m.units)
            if n > 0 then
                out[#out + 1] = { key = i, itemID = tonumber(m.itemID), count = n,
                                  to = m.recipient }
            end
        end
    end
    return out
end

-- THE PLAN. Given the stacks that exist, the exact amounts wanted (in send order)
-- and the empty slots available, decide what has to be split and what is already
-- fine as it stands.
--
--   stacks : { { bag, slot, itemID, count, locked }, ... }   (one item id)
--   wants  : { { key, count }, ... }                          (send order)
--   free   : { { bag, slot }, ... }                           (empty bag slots)
--   opts   = { maxAttach = 12 }
--
-- Returns
--   { rows = { { key, want, ready, reuse, parts = { {bag,slot,count} },
--                job = <the split, if any>, why }, ... },
--     jobs = { { key, bag, slot, count, destBag, destSlot, itemID }, ... },
--     freeAvailable, freeUsed, freeShort, ready, blockedRows }
--
-- THE RULES, in the order they are tried, and the reason for each:
--
--   1. A stack that is ALREADY exactly the size wanted is used as it is. No split,
--      no empty slot, no wait — and this is the case a player who keeps tidy bags
--      hits every time. It generalises: any set of whole stacks that ADDS UP to the
--      amount is equally good (4 + 3 for a seven), and costs nothing either.
--   2. Otherwise take the whole stacks that fit under the amount first, and split
--      only the remainder. Consuming partial stacks before breaking a full one is
--      what keeps the number of splits — and the number of odd leftovers rattling
--      around the bags afterwards — down.
--   3. The stack that gets split is the SMALLEST one bigger than the remainder, for
--      the same reason: break the nearly-right stack, not a pristine ten.
--
-- Every split costs one empty bag slot, and the slots are handed out in order, so a
-- run with three free slots and five splits to make stages the FIRST three mails
-- and says so — a partial pass in send order is more use than an all-or-nothing
-- refusal, and the mails it could not prepare are re-planned per-mail later, by
-- which time the sent mails have freed their slots up again.
function Staging.Plan(stacks, wants, free, opts)
    opts = (type(opts) == "table") and opts or {}
    local maxAttach = tonumber(opts.maxAttach) or 12
    if maxAttach < 2 then maxAttach = 2 end   -- one part + one staged stack, minimum

    local pool = {}
    for _, s in ipairs((type(stacks) == "table") and stacks or {}) do
        local c = whole(s.count)
        if c > 0 and not s.locked then
            pool[#pool + 1] = { bag = s.bag, slot = s.slot, itemID = s.itemID,
                                count = c, claimed = false }
        end
    end

    local slots = {}
    for _, f in ipairs((type(free) == "table") and free or {}) do
        if type(f) == "table" and f.bag ~= nil and f.slot ~= nil then
            slots[#slots + 1] = { bag = f.bag, slot = f.slot }
        end
    end

    local plan = { rows = {}, jobs = {}, freeAvailable = #slots, freeUsed = 0,
                   freeShort = 0, ready = 0, blockedRows = 0 }
    local nextFree = 1

    local function unclaimed()
        local out = {}
        for _, p in ipairs(pool) do if not p.claimed then out[#out + 1] = p end end
        return out
    end

    for _, w in ipairs((type(wants) == "table") and wants or {}) do
        local want = whole(w.count)
        local row  = { key = w.key, want = want, to = w.to, ready = false }
        plan.rows[#plan.rows + 1] = row

        if want < 1 then
            row.ready, row.reuse = true, true
        else
            -- (1) whole stacks that already add up. Costs nothing at all.
            local draws, _, picked = ns.Rules.ComposeWhole(unclaimed(), want, maxAttach)
            if draws then
                for _, p in ipairs(picked) do p.claimed = true end
                row.ready, row.reuse, row.parts = true, true, draws
            else
                -- (2) take what fits, (3) split the remainder off the smallest
                --     stack that can cover it.
                local avail = unclaimed()
                table.sort(avail, function(a, b)
                    if a.count ~= b.count then return a.count > b.count end
                    if a.bag   ~= b.bag   then return a.bag   < b.bag   end
                    return a.slot < b.slot
                end)
                local taken, remaining = {}, want
                for _, p in ipairs(avail) do
                    if remaining <= 0 or #taken >= (maxAttach - 1) then break end
                    if p.count <= remaining then
                        taken[#taken + 1] = p
                        remaining = remaining - p.count
                    end
                end

                -- `avail` is sorted BIGGEST first, so walking it backwards visits
                -- the stacks smallest first and the FIRST match is the smallest
                -- stack that can cover the remainder. Break the nearly-right stack,
                -- not a pristine ten.
                local src
                for i = #avail, 1, -1 do
                    local p = avail[i]
                    if p.count > remaining then
                        local isTaken = false
                        for _, t in ipairs(taken) do if t == p then isTaken = true end end
                        if not isTaken then src = p; break end
                    end
                end

                if remaining <= 0 then
                    -- ComposeWhole should have found this; belt and braces.
                    for _, p in ipairs(taken) do p.claimed = true end
                    row.ready, row.reuse, row.parts = true, true, taken
                elseif not src then
                    row.why = "short"
                    plan.blockedRows = plan.blockedRows + 1
                elseif nextFree > #slots then
                    row.why = "nofree"
                    plan.freeShort = plan.freeShort + 1
                    plan.blockedRows = plan.blockedRows + 1
                else
                    local dest = slots[nextFree]
                    nextFree = nextFree + 1
                    plan.freeUsed = plan.freeUsed + 1
                    for _, p in ipairs(taken) do p.claimed = true end
                    local job = { key = w.key, bag = src.bag, slot = src.slot,
                                  count = remaining, itemID = src.itemID,
                                  destBag = dest.bag, destSlot = dest.slot }
                    plan.jobs[#plan.jobs + 1] = job
                    -- The source keeps its remainder and stays in the pool; the new
                    -- stack joins it already spoken for.
                    src.count = src.count - remaining
                    if src.count <= 0 then src.claimed = true end
                    pool[#pool + 1] = { bag = dest.bag, slot = dest.slot, itemID = src.itemID,
                                        count = remaining, claimed = true }
                    local parts = {}
                    for _, t in ipairs(taken) do
                        parts[#parts + 1] = { bag = t.bag, slot = t.slot, count = t.count }
                    end
                    parts[#parts + 1] = { bag = dest.bag, slot = dest.slot,
                                          count = remaining, staged = true }
                    row.ready, row.parts, row.job = true, parts, job
                end
            end
        end
        if row.ready then plan.ready = plan.ready + 1 end
    end
    return plan
end

-- One line for the run summary when staging rearranged the bags. Pure.
-- Silence when nothing was split: a report about nothing having happened is noise.
function Staging.Note(splits)
    local n = whole(splits)
    if n < 1 then return nil end
    return ("%d stack%s split in your bags to make the exact amounts — the leftovers are still yours, just in new slots.")
        :format(n, n == 1 and " was" or "s were")
end

-- ════════════════════════════════════════════════════════════════════════════
--  LIVE WRAPPERS
-- ════════════════════════════════════════════════════════════════════════════

-- Trace rows go to the SAME ring the attach uses, because the question a capture
-- has to answer — "why did this mail not go out?" — spans both halves.
local function record(entry)
    if not (ns.Trace and ns.Trace.Record) then return nil end
    local ok, stored = pcall(ns.Trace.Record, entry)
    return ok and stored or nil
end

local function cursorHas()
    return (CursorHasItem and CursorHasItem()) and true or false
end

-- The world is holding still enough to start another split: nothing on the cursor,
-- no bag slot mid-operation. Deliberately NOT mail.lua's bagsQuiet — that one
-- ClearCursor()s whatever it finds, which is right between mails and catastrophic
-- in the middle of a staging step, where the thing on the cursor is the split.
local function stageQuiet()
    if cursorHas() then return false end
    if ns.Rules.AnySlotLocked and ns.Rules.AnySlotLocked() then return false end
    return true
end
Staging._StageQuiet = stageQuiet   -- harness seam

-- Run ONE split, bag to bag, and report honestly.
--
-- Sequenced rather than fired-and-forgotten because each step's outcome decides the
-- next: a split that has not reached the cursor yet must be WAITED for and never
-- asked again (asking again takes a second helping), and a cursor that never
-- arrives is a client that will not do this at all.
--
--   draw = the trace row for this job, filled as we go.
local function runJob(job, await, draws, done)
    local C = C_Container
    local td = { bag = job.bag, slot = job.slot, want = job.count,
                 exact = true, path = "stage", destBag = job.destBag,
                 destSlot = job.destSlot }
    draws[#draws + 1] = td

    local info = ns.Rules.SlotInfo(job.bag, job.slot)
    td.pre    = info and tonumber(info.count) or 0
    td.locked = info and info.isLocked or false

    local function stop(outcome, ok, why)
        td.outcome = outcome
        local after = ns.Rules.SlotInfo(job.destBag, job.destSlot)
        td.post = after and tonumber(after.count) or 0
        done(ok, why)
    end

    if not (C and C.SplitContainerItem and C.PickupContainerItem) then
        return stop("no-api", false, "api")
    end
    if not info or info.itemID ~= job.itemID then
        return stop("stale-source", false, "stale")
    end
    if info.isLocked then
        return stop("locked-source", false, "stale")
    end
    if (tonumber(info.count) or 0) <= job.count then
        -- The stack shrank under us; splitting `count` off it would empty it, which
        -- is a whole-stack move dressed up as a split. Re-plan instead.
        return stop("source-too-small", false, "stale")
    end
    if not ns.Rules.SlotEmpty(job.destBag, job.destSlot) then
        return stop("dest-occupied", false, "dest")
    end

    D.splits = D.splits + 1
    C.SplitContainerItem(job.bag, job.slot, job.count)

    await(cursorHas, function()
        if not cursorHas() then
            -- NOTHING REACHED THE CURSOR INSIDE THE CEILING. That is one fact, and
            -- it has two very different causes. Read the SOURCE to tell them apart:
            --
            --   * the source still holds what it held  -> the client did nothing
            --     with the call. Refusal EVIDENCE; it may strike.
            --   * the source has given its units up    -> the split is real and
            --     merely late. Not evidence of anything except a slow frame, and
            --     the ceiling widens for the next attempt.
            --
            -- A source slot that has VANISHED or changed item is also "moved": the
            -- units left, whatever happened to them afterwards.
            local after = ns.Rules.SlotInfo(job.bag, job.slot)
            local nowCount = after and tonumber(after.count) or nil
            local moved = (after == nil)
                or (after.itemID ~= job.itemID)
                or (nowCount ~= nil and td.pre ~= nil and nowCount < td.pre)
            td.srcAfter = nowCount
            if moved then
                D.splitSlow = D.splitSlow + 1
                widen()
                return stop("slow-cursor", false, "slowsplit")
            end
            D.splitRefused = D.splitRefused + 1
            widen()
            return stop("no-cursor", false, "split")
        end
        td.cursor = true
        splitSucceeded()
        if not ns.Rules.SlotEmpty(job.destBag, job.destSlot) then
            ClearCursor()
            return stop("dest-taken", false, "dest")
        end
        C.PickupContainerItem(job.destBag, job.destSlot)
        await(function() return not cursorHas() end, function()
            if cursorHas() then
                ClearCursor()
                D.placeFailed = D.placeFailed + 1
                return stop("not-placed", false, "place")
            end
            td.placed = true
            stop("placed", true)
        end, Staging.PLACE_CEILING)
    end, Staging.CursorCeiling())
end

-- Did every job land? Checked against the DESTINATION slots on settled state — the
-- only evidence that matters is a stack of the right size sitting where it should.
local function jobsVerified(jobs)
    for _, j in ipairs(jobs) do
        local info = ns.Rules.SlotInfo(j.destBag, j.destSlot)
        if not (info and info.itemID == j.itemID
                and (tonumber(info.count) or 0) == j.count) then
            return false
        end
    end
    return true
end
Staging._JobsVerified = jobsVerified   -- harness seam

-- Execute a list of split jobs, in order, and call done(ok, why, staged).
--
--   await(pred, fn, ceiling)  injected by mail.lua — the SAME condition-waiter the
--                             send engine uses, so staging and arming cannot drift
--                             apart on what "settled" means.
--
-- A job that fails stops the pass: the plan behind it assumed the earlier stacks
-- exist, and pressing on would stage against arithmetic that is no longer true.
function Staging.Execute(jobs, await, done)
    local draws = {}
    local i, failWhy = 0, nil
    D.passes = D.passes + 1

    -- THE ONE PLACE THE VERDICT IS WRITTEN. Kept in a single function so there is
    -- exactly one answer to "what latched this?" — the old code set `blocked = true`
    -- from two places on two different conditions, which is how a timeout came to
    -- masquerade as a proof in the first place.
    local function adjudicate(why)
        if why == "api" then
            -- Not a measurement. The call is not on this client at all.
            blocked, blockWhy = true, "api"
            return
        end
        if why == "split" then
            strikes = strikes + 1
            if strikes >= Staging.STRIKES_TO_BLOCK then
                blocked, blockWhy = true, "refused"
            end
            return
        end
        -- "slowsplit", "verify", "dest", "place", "stale", "short": none of these
        -- say anything about whether the client can split. They never latch, and a
        -- slow split is positive evidence that it CAN, so it clears the strikes.
        if why == "slowsplit" then strikes = 0 end
    end

    local function finish(ok)
        -- ONE verification wait for the whole pass. The client writes container
        -- counts on its own schedule; the pass is not done until it agrees.
        await(function() return stageQuiet() and jobsVerified(jobs) end, function()
            local verified = jobsVerified(jobs)
            if ok and not verified then
                D.verifyFailed = D.verifyFailed + 1
                failWhy = failWhy or "verify"
            end
            local good = ok and verified
            if good then
                D.staged = D.staged + #jobs
                splitSucceeded()
            end
            record({ stage = true, draws = draws, count = #jobs,
                     verdict = good and "staged" or "stage-failed",
                     why = good and nil or (failWhy or "verify"),
                     strikes = (not good) and strikes or nil,
                     blocked = blocked or nil })
            done(good, failWhy or (verified and nil or "verify"))
        end, Staging.VERIFY_CEILING)
    end

    local function step()
        i = i + 1
        if i > #jobs then return finish(true) end
        -- Between jobs, let the world settle: the previous split locked the slots it
        -- touched, and a locked slot refuses the next split in silence.
        await(stageQuiet, function()
            runJob(jobs[i], await, draws, function(ok, why)
                if not ok then
                    failWhy = why
                    adjudicate(why)
                    return finish(false)
                end
                step()
            end)
        end, Staging.CursorCeiling())
    end

    if #jobs == 0 then
        return done(true, nil)
    end
    if blocked then
        record({ stage = true, count = #jobs, verdict = "stage-failed", why = "blocked" })
        return done(false, "blocked")
    end
    -- A SPLIT THAT ARRIVED AFTER WE GAVE UP ON IT. The ladder means a ceiling can
    -- expire on a split that is merely late, and the stack it was carrying then
    -- lands on the cursor with nobody waiting for it. Put it back before starting:
    -- a busy cursor makes stageQuiet false, which would burn the next (wider)
    -- ceiling and then read the untouched source as a REFUSAL — the very
    -- misclassification this whole change exists to remove. Safe here and nowhere
    -- else: between passes the cursor is never ours mid-step.
    if cursorHas() and ClearCursor then ClearCursor() end
    step()
end

-- Plan and run a staging pass for a whole QUEUE. Calls done(summary).
--
--   summary = { jobs = n, ok = <bool>, why = <string|nil>, freeShort = n,
--               reused = n, blockedRows = n }
--
-- The free slots are counted ONCE and handed out across every item id in the queue,
-- because they are one shared resource however many different things are being
-- mailed.
function Staging.PrepareQueue(queue, await, done, opts)
    opts = (type(opts) == "table") and opts or {}
    local summary = { jobs = 0, ok = true, freeShort = 0, reused = 0, blockedRows = 0 }
    local wants = Staging.Wants(queue)
    if #wants == 0 then return done(summary) end

    local free = ns.Rules.FreeBagSlots and ns.Rules.FreeBagSlots() or {}
    local used = 0
    local jobs = {}

    -- Group by item id, in first-appearance order.
    local order, byItem = {}, {}
    for _, w in ipairs(wants) do
        if not byItem[w.itemID] then byItem[w.itemID] = {}; order[#order + 1] = w.itemID end
        local l = byItem[w.itemID]
        l[#l + 1] = w
    end

    for _, itemID in ipairs(order) do
        local stacks = ns.Rules.ScanStacksForItem(itemID)
        local remainingFree = {}
        for i = used + 1, #free do remainingFree[#remainingFree + 1] = free[i] end
        local plan = Staging.Plan(stacks, byItem[itemID], remainingFree,
                                  { maxAttach = opts.maxAttach or ns.MAX_ATTACH })
        used = used + plan.freeUsed
        summary.freeShort   = summary.freeShort + plan.freeShort
        summary.blockedRows = summary.blockedRows + plan.blockedRows
        for _, r in ipairs(plan.rows) do if r.reuse then summary.reused = summary.reused + 1 end end
        for _, j in ipairs(plan.jobs) do jobs[#jobs + 1] = j end
    end

    D.planned = D.planned + #jobs
    D.reusedExact = D.reusedExact + summary.reused
    if summary.freeShort > 0 then D.noFreeSlot = D.noFreeSlot + summary.freeShort end
    summary.jobs = #jobs
    if #jobs == 0 then return done(summary) end

    Staging.Execute(jobs, await, function(ok, why)
        summary.ok, summary.why = ok, why
        done(summary)
    end)
end

-- Plan and run a staging pass for ONE mail — the fallback when the up-front pass
-- ran out of empty slots, or when the plan changed under the run. Calls
-- done(ok, why).
function Staging.PrepareOne(itemID, units, await, done, opts)
    opts = (type(opts) == "table") and opts or {}
    if blocked then return done(false, "blocked") end
    local stacks = ns.Rules.ScanStacksForItem(itemID)
    local free   = ns.Rules.FreeBagSlots and ns.Rules.FreeBagSlots(4) or {}
    local plan   = Staging.Plan(stacks, { { key = 1, itemID = itemID, count = units } },
                                free, { maxAttach = opts.maxAttach or ns.MAX_ATTACH })
    D.planned = D.planned + #plan.jobs
    if plan.freeShort > 0 then D.noFreeSlot = D.noFreeSlot + plan.freeShort end
    local row = plan.rows[1]
    if not (row and row.ready) then
        return done(false, (row and row.why) or "short")
    end
    if #plan.jobs == 0 then
        D.reusedExact = D.reusedExact + 1
        return done(true, nil)          -- already exactly right in the bags
    end
    Staging.Execute(plan.jobs, await, done)
end

-- ── THE RELEASE PATH ─────────────────────────────────────────────────────────
--
-- The sticky verdict's real defect was never only that a timeout could set it: it
-- was that NOTHING could clear it. Unblock() existed with zero live callers and
-- only /reload got the feature back.
--
-- A new mailbox visit is the natural release. Whatever the client was doing during
-- the last one — a loading screen, a zone full of raiders, a world-server hiccup —
-- is over, and the cost of being wrong here is one bounded ladder, paid once,
-- against a feature that is otherwise dead for the session. The other door is
-- `/conduit debug boons unblock`, for a user who has just fixed something and does
-- not want to close and re-open the mailbox to prove it.
if ns.RegisterEvent then
    ns:RegisterEvent("MAIL_SHOW", function() Staging.Unblock() end)
end

return Staging
