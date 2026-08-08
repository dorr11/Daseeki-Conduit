--[[
    Daseeki Conduit — ledger.lua

    THE OUTBOUND LEDGER: what this account has already put in the post, and has
    not yet seen arrive.

    Why it exists. Cross-account mail takes an hour to land, and the mesh count a
    plan is built from is a SNAPSHOT of what a character was last seen holding. So
    for a whole hour after a boon top-up, every planner in the suite still believes
    the recipient has what they had before the mail — and a run that was
    interrupted at "2 of 8", re-run five minutes later, would cheerfully post the
    first two mails a second time. The owner's rule is blunt and correct: an
    interrupted or errored run must never over-mail on re-run.

    The fix is the one the mass-mail behavioural spec calls the single highest-value
    design choice (§10.7): DERIVE THE QUEUE FROM COMMITTED STATE, never materialise
    it once and trust it. Here the committed state is three things added together —
    what the mesh says a character holds, what this ledger says is still in transit
    to them, and what is actually in the sender's bags. Re-deriving from that at run
    start, and re-checking it per mail before anything is attached, makes a resumed
    run send the remainder BY CONSTRUCTION rather than by remembering where it got to.

    ── What goes in ─────────────────────────────────────────────────────────────
    ONE ENTRY PER CONFIRMED SEND, never per attempt. "Confirmed" means the send
    engine reached a terminal SUCCESS with its evidence signal (mail.lua §terminal:
    the ack plus the attachments actually leaving the bags). The spec flags the
    observed addon for recording on every path it merely FLAGGED as success —
    including the two where the client said "sent" but nothing could be verified —
    and notes that this over-records and permanently strands the recipient. We
    record later and less, deliberately.

    ── What comes out ───────────────────────────────────────────────────────────
    Two ways an entry dies, and no third:

      * EVIDENCE. The mesh produces a snapshot of that character taken AFTER the
        send, and its count has RISEN BY WHAT WE POSTED relative to the baseline we
        recorded at send time. The mail landed and was seen; the entry has done its
        job.
      * TIME. A 30-day backstop, which is Blizzard's own mail expiry: after that the
        mail is either opened or returned, and either way it is no longer in flight.

    ── THE BASELINE, AND WHY AN ABSOLUTE COUNT IS NOT EVIDENCE (CDT-2) ──────────
    Until 1.2.4 the evidence test was `cnt >= e.qty`: the recipient's ABSOLUTE
    holding against the QUANTITY POSTED. That is not a delivery proof, it is a
    coincidence. Boons.BuildPlan sets qty = 10 - have, so `cnt >= qty` reduces to
    `have >= 10 - have`: ANY recipient already holding five or more retired the
    entry the moment any later snapshot arrived, whether or not the mail had moved.

      Bankalt posts 2 boons to a character holding 8. That character logs in ten
      minutes later; Nexus scans their bags and stamps countsAt — still 8, because
      cross-account mail takes an hour. The old test saw `at > e.ts` and `8 >= 2`
      and called it delivered. inFlight emptied, need became 2, and the button
      posted two MORE. Twelve boons for a ten-boon target, from the very ledger
      that exists to stop exactly that.

    So every entry now records `base` — the holding the planner SAW for that
    recipient at the moment the mail was confirmed (boons.lua's `t.have`, which is
    the mesh snapshot the plan was built from). Delivery is a DELTA:

        cnt >= e.base + e.qty      -- the count rose by at least what we posted

    Two honest consequences, both of which fail towards keeping the entry rather
    than dropping it, because a retained entry only delays a top-up while a dropped
    one over-mails:

      * A recipient who SPENDS boons between the send and the delivery may never
        reach base + qty. That entry rides to the TTL. Under-mailing for a while is
        recoverable; the double-send is not.
      * An entry written by a build older than 1.2.4 carries NO baseline, and no
        baseline means no delta and therefore no proof. Those entries retire on the
        TTL alone (`/conduit debug boons` names them, and `...clear` drops them).
        There is no way to invent a baseline after the fact that is not a guess.

    Bounced-mail auto-detection is deliberately OUT of scope — a returned mail is
    indistinguishable at the API from one never sent, and the TTL plus the manual
    `/conduit debug boons clear` cover the case without guessing.

    ── Purity ───────────────────────────────────────────────────────────────────
    Everything above the LIVE WRAPPERS bar is a function of its arguments alone, so
    the self-test harness can drive the whole rule set row by row.
--]]

local ADDON, ns = ...

local Ledger = {}
ns.Ledger = Ledger

-- Blizzard's mail expiry. An entry older than this is not in flight any more,
-- whatever happened to it.
Ledger.TTL = 30 * 24 * 60 * 60

-- ════════════════════════════════════════════════════════════════════════════
--  PURE
-- ════════════════════════════════════════════════════════════════════════════

-- The name part of "Name" or "Name-Realm", folded. Matches boons.lua's key rule
-- so a ledger entry and a roster row for the same character always collide.
function Ledger.Key(name)
    if type(name) ~= "string" then return "" end
    local base = name:match("^([^-]+)") or name
    return (base:match("^%s*(.-)%s*$")):lower()
end

local function num(v, dflt)
    local n = tonumber(v)
    if not n or n ~= n then return dflt end
    return n
end

-- Is this a well-formed entry? Anything else is dropped on sight rather than
-- allowed to poison a plan with a nil quantity.
function Ledger.IsValid(e)
    return type(e) == "table"
        and type(e.target) == "string" and e.target ~= ""
        and num(e.itemID) ~= nil
        and (num(e.qty) or 0) > 0
        and num(e.ts) ~= nil
end

-- Append a confirmed send. Returns the new entry (callers persist by reference).
--
-- `base` is the recipient's holding as the PLANNER SAW IT when this mail was built
-- — the baseline the delivery delta is measured against. It is deliberately
-- OPTIONAL and deliberately never defaulted to 0: a missing baseline is "we do not
-- know", which Reconcile refuses to treat as evidence, and an invented zero would
-- turn every send into a false delivery proof on the next snapshot.
function Ledger.Add(entries, target, itemID, qty, ts, base)
    if type(entries) ~= "table" then return nil end
    local b = num(base)
    if b then b = math.floor(b) end
    if b and b < 0 then b = 0 end
    local e = { target = target, itemID = num(itemID), qty = math.floor(num(qty) or 0),
                ts = num(ts), base = b }
    if not Ledger.IsValid(e) then return nil end
    entries[#entries + 1] = e
    return e
end

-- Does this entry carry a baseline, and therefore a delivery proof at all?
-- Entries written before 1.2.4 do not; they retire on the TTL and nothing else.
function Ledger.HasBaseline(e)
    return type(e) == "table" and num(e.base) ~= nil
end

-- How much of `itemID` is in transit to each character right now.
--   returns { [key] = qty }, total
-- Entries past the TTL are ignored (they are cleared separately; a plan must not
-- wait for a sweep to stop believing in a month-old mail).
function Ledger.InFlight(entries, itemID, now, ttl)
    local out, total = {}, 0
    ttl = num(ttl, Ledger.TTL)
    itemID = num(itemID)
    now = num(now)
    for _, e in ipairs((type(entries) == "table") and entries or {}) do
        if Ledger.IsValid(e) and (itemID == nil or e.itemID == itemID) then
            local expired = (now ~= nil) and ((now - e.ts) > ttl) or false
            if not expired then
                local k = Ledger.Key(e.target)
                out[k] = (out[k] or 0) + e.qty
                total = total + e.qty
            end
        end
    end
    return out, total
end

-- Retire what has been accounted for.
--
--   mesh = { [key] = { count = <units the snapshot shows>, at = <epoch> } }
--
-- An entry is retired when the mesh has SEEN the character since the send AND the
-- count it saw has RISEN by at least what we posted, measured against the baseline
-- the entry recorded (the mail arrived and was opened into the bags/bank the
-- snapshot reads), or when the entry is older than the TTL.
--
-- An absolute count proves nothing on its own — see the CDT-2 note in the header.
-- An entry with no baseline has no delta to measure and therefore no evidence
-- path: it rides to the TTL.
--
-- Returns kept, retired — two arrays. The caller swaps `kept` in.
function Ledger.Reconcile(entries, mesh, now, ttl)
    local kept, retired = {}, {}
    ttl  = num(ttl, Ledger.TTL)
    now  = num(now)
    mesh = (type(mesh) == "table") and mesh or {}
    for _, e in ipairs((type(entries) == "table") and entries or {}) do
        if not Ledger.IsValid(e) then
            retired[#retired + 1] = { entry = e, why = "malformed" }
        else
            local why = nil
            if now and (now - e.ts) > ttl then
                why = "expired"
            else
                local m = mesh[Ledger.Key(e.target)]
                if type(m) == "table" and Ledger.HasBaseline(e) then
                    local at, cnt = num(m.at), num(m.count, 0)
                    -- THE DELTA, NOT THE ABSOLUTE. The snapshot must be newer than
                    -- the send AND show the count risen by what we posted.
                    if at and at > e.ts and cnt >= (num(e.base) + e.qty) then
                        why = "delivered"
                    end
                end
            end
            if why then retired[#retired + 1] = { entry = e, why = why }
            else kept[#kept + 1] = e end
        end
    end
    return kept, retired
end

-- Human-readable rows for /conduit debug boons, newest first.
--   fmtAge(secs) -> "2h" (boons.lua's FormatAge is passed in so one clock spells
--   every age in this addon the same way).
function Ledger.Describe(entries, now, fmtAge)
    local rows = {}
    for _, e in ipairs((type(entries) == "table") and entries or {}) do
        if Ledger.IsValid(e) then rows[#rows + 1] = e end
    end
    table.sort(rows, function(a, b)
        if a.ts ~= b.ts then return a.ts > b.ts end
        return tostring(a.target) < tostring(b.target)
    end)
    local out = {}
    for _, e in ipairs(rows) do
        local age = (num(now) and (num(now) - e.ts)) or nil
        local ageText = (fmtAge and age and fmtAge(age)) or nil
        -- A row with no baseline can never be proved delivered, and a user staring
        -- at a ledger that will not clear deserves to be told which rows those are
        -- rather than left to guess at a stuck addon.
        local note = Ledger.HasBaseline(e)
            and ("had %d"):format(num(e.base))
            or  "no baseline — clears at the 30-day expiry"
        out[#out + 1] = ("%s  <-  %d x %d   (sent %s ago, %s)")
            :format(e.target, e.qty, e.itemID, ageText or "?", note)
    end
    return out
end

-- ════════════════════════════════════════════════════════════════════════════
--  LIVE WRAPPERS
-- ════════════════════════════════════════════════════════════════════════════

-- The saved array. Created lazily and ADDITIVELY: `outbox` is a new top-level key
-- on an existing save, which core.lua's ensureKeys fills in without touching
-- anything else and without a schema bump (nothing was reshaped).
function Ledger.Entries()
    local db = ns.db
    if not db then return {} end
    if type(db.outbox) ~= "table" then db.outbox = {} end
    return db.outbox
end

function Ledger.Now()
    return (time and time()) or 0
end

-- Record a CONFIRMED send. Called by mail.lua from the terminal-success path and
-- from nowhere else — an attempt is not a send.
--
-- `base` comes off the queued mail (boons.lua stamps the planner's `have` on it).
-- A mail built without one records no baseline rather than a fabricated zero.
function Ledger.Record(target, itemID, qty, ts, base)
    local e = Ledger.Add(Ledger.Entries(), target, itemID, qty, ts or Ledger.Now(), base)
    return e
end

-- Sweep against a mesh snapshot map. Returns how many entries were retired.
function Ledger.Sweep(mesh, now)
    local db = ns.db
    if not db then return 0 end
    local kept, retired = Ledger.Reconcile(Ledger.Entries(), mesh, now or Ledger.Now())
    db.outbox = kept
    return #retired
end

function Ledger.Clear()
    local db = ns.db
    local n = #Ledger.Entries()
    if db then db.outbox = {} end
    return n
end

return Ledger
