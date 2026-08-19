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
    `/conduit transit clear` cover the case without guessing.

    ── THE STALE BASELINE, AND WHY CDT-2's FIX STRANDED SHALK (CDT-5) ───────────
    The delta above is only as good as the baseline it measures from, and 1.2.4
    took that baseline from THE SAME LAGGING SNAPSHOT THE PLAN WAS BUILT FROM. If
    the snapshot OVER-states what the recipient holds, `base + qty` names a total
    the recipient can never reach after delivery, and the entry becomes
    UNPROVABLE BY CONSTRUCTION — it rides the full 30 days suppressing every
    top-up, exactly the starvation the ledger exists to avoid in the other
    direction.

    This is not a corner. A top-up is posted PRECISELY to characters the snapshot
    shows running low, and the reason they are running low is that they burn boons
    — so "the snapshot over-states" is the ORDINARY case, not the exception.

    The owner's live save (1.2.5, 2026-08-17) is the worked example:

      Shalk's row said 5. The planner posted 5 (base = 5, target 10). Shalk had
      ACTUALLY burned down to 1 — a scan stamped 155 seconds BEFORE the send says
      so in the sender's own mesh. Shalk received the 5 and now holds 6. The proof
      demanded 10. Six is all there will ever be, so the row sat "in transit" for
      46 hours and had 28 more days to go.

    THE FIX IS A SECOND CLOCK. Nexus's inventory payload carries its own `ts` —
    when the remote client actually SCANNED — while the row wrapper's `updatedAt`
    only says when THIS client last took delivery of the row. The two are not the
    same thing and 1.2.4 used the wrong one:

      * RE-BASELINE (Rule 1). A count whose SCAN time is at or before the send is,
        by construction, a PRE-DELIVERY holding. It is a better baseline than the
        planner's guess and it is not a guess at all. Adopted downwards only —
        raising the bar can only strand an entry, never save one. Shalk's base
        drops 5 -> 1 and 6 >= 1 + 5 retires the row the moment the mesh catches up.
      * THE PROOF NOW RUNS ON THE SCAN CLOCK (Rule 2). `updatedAt` moving is not
        the recipient being seen — the owner's save has Shalk's row RE-STAMPED 211
        seconds after the send while carrying a payload scanned 155 seconds
        BEFORE it. Testing `updatedAt > ts` opened the delivery gate on pre-send
        data, which is the CDT-2 double-send hazard let back in through the other
        door. The scan clock shuts it.

    ── PRESUMED RECEIVED: retiring a proof that will never arrive (CDT-5) ───────
    Some entries can never be proved either way. The recipient spent the boons
    before we ever saw a pre-send scan; the mail bounced; the row predates any
    baseline at all. Waiting 30 days for those is not caution, it is a stuck
    addon — the owner's save carries six of them, thirteen days old, one of them
    suppressing top-ups for a character the mesh plainly shows at a FULL TEN.

    So an entry retires as PRESUMED RECEIVED when all of these hold:

      * it is older than PRESUMED_AFTER (24h), and
      * the recipient has been HEARD FROM — a scan of theirs taken at or after the
        delivery deadline (send + DELIVERY_FLOOR). Silence is never evidence: a
        recipient nobody has seen keeps their entry.

    and NEVER before DELIVERY_FLOOR (1h), which is Blizzard's worst-case delay for
    mail between unconnected accounts. Same-account mail is instant; an hour is
    the ceiling, so an hour is the floor here, asserted separately from
    PRESUMED_AFTER so a mis-tuned constant can never bypass it.

    WHY 24 HOURS AND NOT THREE. Nexus folds MAIL ATTACHMENTS INTO itemCounts, but
    only after the recipient opens a mailbox — `parts.mail` is a cache of the last
    inbox visit. So a recipient who logs in, raids, and never walks to a mailbox
    produces a perfectly fresh scan that legitimately does NOT show the goods, and
    retiring on that would re-send a mail that is sitting unopened. Three hours
    sits squarely inside one raid night; a day does not. The residual is stated
    rather than hidden: a recipient who ignores their mailbox for a full day can
    still be double-mailed once. That is the price of not stranding them for a
    month, and `/conduit transit` shows every row and its age so the owner can see
    it coming.

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

-- THE FLOOR. Blizzard's worst-case mail delay: an hour, between characters on
-- unconnected accounts. Same-account mail is instant, so an hour is the ceiling
-- of the real delay and therefore the floor of anything this file is allowed to
-- call "not in the post any more". NOTHING retires younger than this — not the
-- presumption, not a witness, not a tuning mistake.
Ledger.DELIVERY_FLOOR = 60 * 60

-- THE PRESUMPTION. Older than this, with a post-delivery sighting of the
-- recipient and still no proof, and the entry retires as presumed received. See
-- the CDT-5 note in the header for why this is a day and not three hours: Nexus
-- only folds mail into itemCounts once the recipient opens a mailbox, so a fresh
-- scan from someone who has not been to one is not evidence of anything, and a
-- raid night is shorter than a day.
Ledger.PRESUMED_AFTER = 24 * 60 * 60

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
--
-- `baseAt` is WHEN THAT BASELINE WAS TRUE — the scan clock of the snapshot `base`
-- was read from, not the moment we took delivery of the row. It is what lets a
-- later, NEWER pre-send scan replace a baseline the planner got wrong (CDT-5);
-- without it a re-baseline cannot tell a better reading from an older one. Also
-- optional, and for the same reason: an undated baseline is "we do not know when",
-- which Reconcile handles more conservatively rather than pretending.
function Ledger.Add(entries, target, itemID, qty, ts, base, baseAt)
    if type(entries) ~= "table" then return nil end
    local b = num(base)
    if b then b = math.floor(b) end
    if b and b < 0 then b = 0 end
    local e = { target = target, itemID = num(itemID), qty = math.floor(num(qty) or 0),
                ts = num(ts), base = b, baseAt = b and num(baseAt) or nil }
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
--   returns { [key] = qty }, total, { [key] = <age of the OLDEST row, seconds> }
-- Entries past the TTL are ignored (they are cleared separately; a plan must not
-- wait for a sweep to stop believing in a month-old mail).
--
-- THE AGES ARE THE THIRD RETURN, not a reshaping of the first, so every existing
-- caller is untouched. They exist because "5 in transit" and "5 in transit (46h)"
-- are different sentences: the first reads as a mail on its way, the second reads
-- as a mail that should have landed two days ago, and only one of them tells the
-- owner to look. Oldest wins — the stalest row in a pile is the one worth naming.
function Ledger.InFlight(entries, itemID, now, ttl)
    local out, total, ages = {}, 0, {}
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
                if now then
                    local age = now - e.ts
                    if age < 0 then age = 0 end
                    if ages[k] == nil or age > ages[k] then ages[k] = age end
                end
            end
        end
    end
    return out, total, ages
end

-- The scan clock of a snapshot: WHEN THE COUNT WAS TRUE, not when we took delivery
-- of the row that carries it. `at` is the fallback for a caller that only has one
-- clock (and for every pre-CDT-5 test row), which makes the two identical in that
-- case and changes nothing for them.
local function scanOf(m)
    if type(m) ~= "table" then return nil end
    return num(m.scanAt) or num(m.at)
end

-- Retire what has been accounted for.
--
--   mesh = { [key] = { count  = <units the snapshot shows>,
--                      at     = <when this client last took delivery of the row>,
--                      scanAt = <when the remote client actually SCANNED>  } }
--
-- FOUR RULES, IN THIS ORDER. Each is stated in full in the header; here is what
-- the code does:
--
--   0 EXPIRED     older than the TTL. Blizzard's own mail expiry — opened or
--                 returned, either way not in the post.
--   1 RE-BASELINE (not a retirement) a count whose SCAN time is at or before the
--                 send is a PRE-DELIVERY holding, and therefore a better baseline
--                 than the planner's lagging guess. CDT-5: this is what unsticks a
--                 row whose recorded baseline names a total the recipient can
--                 never reach.
--   2 DELIVERED   a scan taken AFTER the send shows the count risen by what we
--                 posted, measured from the baseline. The SCAN clock, never the
--                 delivery clock — a row re-stamped after the send while carrying
--                 pre-send data must not open this gate (that is CDT-2 through
--                 the other door).
--   3 PRESUMED    older than PRESUMED_AFTER, the recipient sighted at or after the
--                 delivery deadline, and still no proof. Never younger than
--                 DELIVERY_FLOOR, asserted here and not merely implied.
--
-- Silence is never evidence: a recipient nobody has seen keeps their entry until
-- the TTL, whatever its age.
--
-- Returns kept, retired, rebased — three arrays. The caller swaps `kept` in. THE
-- REBASE MUTATES THE ENTRY IN PLACE (entries are persisted by reference, and a
-- baseline correction that did not stick would have to be re-derived on every
-- sweep); `rebased` is how that mutation is made visible rather than silent.
function Ledger.Reconcile(entries, mesh, now, ttl)
    local kept, retired, rebased = {}, {}, {}
    ttl  = num(ttl, Ledger.TTL)
    now  = num(now)
    mesh = (type(mesh) == "table") and mesh or {}
    for _, e in ipairs((type(entries) == "table") and entries or {}) do
        if not Ledger.IsValid(e) then
            retired[#retired + 1] = { entry = e, why = "malformed" }
        else
            local why = nil
            local m   = mesh[Ledger.Key(e.target)]
            local sAt = scanOf(m)
            local cnt = num(m and m.count, 0)

            -- ── 1. RE-BASELINE ───────────────────────────────────────────────
            -- A count that was true BEFORE the mail could have arrived. Which
            -- pre-send reading wins depends on what we know about the one we hold:
            --   * no baseline at all -> take it; a legacy row gets an evidence path
            --     it never had, and this is an observation, not the invention the
            --     1.2.4 header ruled out.
            --   * a DATED baseline   -> the NEWER pre-send scan wins outright.
            --   * an UNDATED one     -> downward only. We cannot tell a better
            --     reading from an older one, and only the downward move can
            --     unstick a row; raising the bar can never do anything but strand.
            if sAt and sAt <= e.ts then
                local take
                if not Ledger.HasBaseline(e) then take = true
                elseif num(e.baseAt)          then take = (sAt > num(e.baseAt))
                else                               take = (cnt < num(e.base))
                end
                if take then
                    local from = num(e.base)
                    e.base, e.baseAt = math.floor(cnt), sAt
                    if from ~= e.base then
                        -- Stamped on the ROW, not just returned: a correction that
                        -- only lived in a return value would vanish at the next
                        -- /reload, and `/conduit transit` could not tell the owner
                        -- that the number their planner acted on has since moved.
                        e.baseWas  = e.baseWas or from
                        e.rebases  = (num(e.rebases, 0)) + 1
                        rebased[#rebased + 1] = { entry = e, from = from, to = e.base }
                    end
                end
            end

            if now and (now - e.ts) > ttl then
                why = "expired"
            elseif Ledger.HasBaseline(e) and sAt and sAt > e.ts
                   and cnt >= (num(e.base) + e.qty) then
                -- ── 2. DELIVERED ─────────────────────────────────────────────
                why = "delivered"
            elseif now then
                -- ── 3. PRESUMED RECEIVED ─────────────────────────────────────
                -- THE FLOOR IS ITS OWN TEST. PRESUMED_AFTER is expected to be the
                -- larger of the two, but a floor that is only implied by another
                -- constant is a floor one edit away from not existing.
                local age = now - e.ts
                if age >= Ledger.DELIVERY_FLOOR and age >= Ledger.PRESUMED_AFTER
                   and sAt and sAt >= (e.ts + Ledger.DELIVERY_FLOOR) then
                    why = "presumed"
                end
            end

            if why then retired[#retired + 1] = { entry = e, why = why }
            else kept[#kept + 1] = e end
        end
    end
    return kept, retired, rebased
end

-- The plain-English sentence for a retirement reason, for the line that tells the
-- owner an entry went away. A retirement the user cannot see is the same shape of
-- problem as an entry they cannot clear.
function Ledger.WhyText(why)
    if why == "delivered" then return "the mesh saw it arrive" end
    if why == "presumed"  then return "presumed received, clear lost" end
    if why == "expired"   then return "past Blizzard's 30-day mail expiry" end
    if why == "malformed" then return "the row was unusable" end
    return tostring(why)
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
        -- A row that cannot be proved deserves to say so rather than look stuck.
        -- Since CDT-5 there are two of those and they are not the same thing: a
        -- row with no baseline is waiting for a pre-send scan to give it one, and
        -- a row that has aged past the presumption is waiting on the RECIPIENT
        -- being seen at all. Naming which tells the owner whether to wait or to
        -- reach for `/conduit transit clear`.
        local note
        if not Ledger.HasBaseline(e) then
            note = "no baseline yet — waiting for a pre-send count of theirs"
        elseif num(e.baseWas) then
            note = ("had %d, corrected from %d"):format(num(e.base), num(e.baseWas))
        else
            note = ("had %d"):format(num(e.base))
        end
        if age and age >= Ledger.PRESUMED_AFTER then
            note = note .. "; past the presumption — the recipient has not been seen since"
        elseif age and age < Ledger.DELIVERY_FLOOR then
            note = note .. "; still inside the delivery window"
        end
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
function Ledger.Record(target, itemID, qty, ts, base, baseAt)
    local e = Ledger.Add(Ledger.Entries(), target, itemID, qty, ts or Ledger.Now(), base, baseAt)
    return e
end

-- Sweep against a mesh snapshot map. Returns how many entries were retired.
--
-- A PRESUMED retirement SAYS SO. Every other exit is either proved (the mesh saw
-- the goods) or a calendar fact (30 days), but the presumption is this file
-- deciding on a bounded guess that a clear was lost, and a guess that removes the
-- only thing standing between the owner and a second mail has to be spoken aloud.
-- It can print at most once per entry — the entry is gone the moment it does.
function Ledger.Sweep(mesh, now)
    local db = ns.db
    if not db then return 0 end
    local kept, retired, rebased =
        Ledger.Reconcile(Ledger.Entries(), mesh, now or Ledger.Now())
    db.outbox = kept
    for _, r in ipairs(retired) do
        if r.why == "presumed" and ns.Print then
            ns:Print(("in-transit row retired — %s x%d to %s: %s.")
                :format(tostring(r.entry.itemID), r.entry.qty, tostring(r.entry.target),
                        Ledger.WhyText(r.why)))
        end
    end
    -- A baseline correction is NOT printed. It fires on ordinary mesh catch-up and
    -- chat is not the place for it — but it is not silent either: Reconcile stamps
    -- the correction onto the row itself, so it survives into SavedVariables and
    -- `/conduit transit` says which rows have been corrected and from what.
    return #retired, #rebased
end

function Ledger.Clear()
    local db = ns.db
    local n = #Ledger.Entries()
    if db then db.outbox = {} end
    return n
end

-- Drop every row for ONE character. Returns how many went, and their units, so the
-- caller can print what it did rather than a bare count — "cleared 1 row (5 units)
-- for Shalk" is a receipt; "cleared" is a hope.
--
-- THE MANUAL VERB EXISTS BECAUSE THE AUTOMATIC ONES CAN ALL STALL. Every rule
-- above needs the mesh to deliver something: a pre-send count to re-baseline from,
-- a post-send count to prove delivery, a sighting to license the presumption. When
-- the relay between accounts is down, none of them arrive and the ledger is
-- correct-but-stuck. This is the owner's way out that depends on nothing.
function Ledger.ClearFor(name)
    local db = ns.db
    if not db then return 0, 0 end
    local want = Ledger.Key(name)
    if want == "" then return 0, 0 end
    local kept, gone, units = {}, 0, 0
    for _, e in ipairs(Ledger.Entries()) do
        if Ledger.IsValid(e) and Ledger.Key(e.target) == want then
            gone  = gone + 1
            units = units + e.qty
        else
            kept[#kept + 1] = e
        end
    end
    db.outbox = kept
    return gone, units
end

return Ledger
