--[[
    Daseeki Conduit — trace.lua

    THE ATTACH TRACE: a persisted ring of the last N attach ATTEMPTS, written to
    SavedVariables so a failure can be read out of the WTF file instead of guessed
    at from three chat lines.

    Why this exists, in the owner's words: "do we need to enable some sort of log to
    catch the issue so we dont continue to iterate on ghost fixes?" Yes. Two rounds
    of field failure were diagnosed from a refusal message that says only what the
    engine CONCLUDED ("the form holds 0"), never what it OBSERVED. Both rounds
    produced a plausible theory, a fix, and an identical failure. That is the
    signature of debugging without evidence.

    Modelled on Daseeki-Bags' sortLog (DaseekiBags2DB.sortLog), which cracked the
    Bags sort failure from a single SavedVariables read.

    ── WHAT ONE ENTRY IS ────────────────────────────────────────────────────────
    One ATTEMPT to attach one mail — not one run, and not one send. A mail that is
    refused and retried produces TWO entries, because the whole question is what was
    different the second time.

    Each entry records what was SEEN, not what was decided:
      * the build stamp, so a stale-code run is self-evident (this is the direct
        answer to the ghost-fix problem: if the trace says 1.2.1 and the fix shipped
        in 1.2.2, the run never had the fix in it);
      * per draw: the bag slot, what the slot held BEFORE, whether it was locked,
        how much was wanted, which API path was taken, whether the cursor received
        anything, whether the click was issued, what the slot held AFTER;
      * THE RAW RETURNS of GetSendMailItem for every occupied send slot, every
        position, stringified and truncated. That single field settles the shape of
        an API the 11509 catalog does not document, permanently and from one capture;
      * both measurements (form and bag delta) and the calibration state at the
        moment of the read;
      * the verdict and, when refused, the reason.

    ── SHAPE RULES ──────────────────────────────────────────────────────────────
    Entries are plain data: numbers, booleans, short strings, and ONE level of
    nesting (the draws array, and each draw's raw-returns array). No functions, no
    upvalues, no cycles — a SavedVariables dump of this must be readable by anything
    that can read a Lua table literal.

    Every string is truncated and every array is capped, because this lives in the
    player's saved variables forever and an unbounded log is a bug, not a feature.

    ── PURITY ───────────────────────────────────────────────────────────────────
    Everything above the LIVE WRAPPERS bar is a function of its arguments alone.
--]]

local ADDON, ns = ...

local Trace = {}
ns.Trace = Trace

-- Caps. All of them enforced on write, none of them advisory.
Trace.CAP        = 40    -- attach attempts retained
Trace.MAX_DRAWS  = 12    -- a mail cannot carry more than this many attachments
Trace.MAX_RAW    = 8     -- return positions recorded per form read
Trace.MAX_STR    = 48    -- characters per stringified value
Trace.MAX_REASON = 160   -- characters of refusal reason

-- ════════════════════════════════════════════════════════════════════════════
--  PURE
-- ════════════════════════════════════════════════════════════════════════════

-- Anything -> a short, safe, printable string. Tables become their type rather
-- than their address, so a trace never carries a value that changes between reads.
function Trace.Str(v, cap)
    cap = tonumber(cap) or Trace.MAX_STR
    local s
    local t = type(v)
    if v == nil then return nil end
    if t == "string" then s = v
    elseif t == "number" or t == "boolean" then s = tostring(v)
    else s = "<" .. t .. ">" end
    if #s > cap then s = s:sub(1, cap - 1) .. "~" end
    return s
end

local function num(v)
    local n = tonumber(v)
    if not n or n ~= n then return nil end
    return n
end

local function bool(v) if v == nil then return nil end return v and true or false end

-- One draw record, normalised and capped.
function Trace.NewDraw(d)
    d = (type(d) == "table") and d or {}
    local raw
    if type(d.raw) == "table" then
        raw = {}
        for i = 1, math.min(#d.raw, Trace.MAX_RAW) do
            raw[i] = Trace.Str(d.raw[i])
        end
        -- An all-empty raw array carries no information; drop it.
        if next(raw) == nil then raw = nil end
    end
    return {
        bag      = num(d.bag),
        slot     = num(d.slot),
        pre      = num(d.pre),          -- units in the slot before we touched it
        locked   = bool(d.locked),
        want     = num(d.want),
        exact    = bool(d.exact),
        path     = Trace.Str(d.path),    -- "split" | "legacy" | "pickup" | "skip"
        outcome  = Trace.Str(d.outcome), -- "delivered" | "async" | "nothing" | ...
        cursor   = bool(d.cursor),       -- did anything reach the cursor?
        click    = bool(d.click),        -- was ClickSendMailItemButton issued?
        post     = num(d.post),          -- units left in the slot after the click
        formSlot = num(d.formSlot),      -- which attachment slot it went to
        viaForm  = num(d.viaForm),       -- units the FORM reported
        viaBag   = num(d.viaBag),        -- units the BAG says left the slot
        cal      = num(d.cal),           -- calibration index at read time
        raw      = raw,                  -- RAW GetSendMailItem returns
    }
end

-- One attempt record, normalised and capped. Never trusts its input.
function Trace.NewEntry(e)
    e = (type(e) == "table") and e or {}
    local draws
    if type(e.draws) == "table" then
        draws = {}
        for i = 1, math.min(#e.draws, Trace.MAX_DRAWS) do
            draws[i] = Trace.NewDraw(e.draws[i])
        end
    end
    return {
        ts       = num(e.ts),
        build    = Trace.Str(e.build),
        run      = num(e.run),
        idx      = num(e.idx),           -- position in the queue
        to       = Trace.Str(e.to),
        planned  = num(e.planned),
        label    = Trace.Str(e.label),
        itemID   = num(e.itemID),
        quiet    = bool(e.quiet),        -- were the bags settled when we armed?
        redrawn  = bool(e.redrawn),      -- were the draws re-derived here?
        draws    = draws,
        units    = num(e.units),         -- units the attach believes it staged
        count    = num(e.count),         -- attachments staged
        formSum  = num(e.formSum),       -- what the FORM totalled, if readable
        cal      = num(e.cal),           -- calibration index at verify time
        verdict  = Trace.Str(e.verdict), -- "sent" | "refused" | "skipped" | "armed"
        why      = Trace.Str(e.why, Trace.MAX_REASON),
    }
end

-- Append to a ring, enforcing the cap. Returns the stored entry.
--
-- A WHILE loop, not one remove: a cap lowered between builds must converge on the
-- first append rather than leaking one stale entry per mail forever.
function Trace.Append(ring, e, cap)
    if type(ring) ~= "table" then return nil end
    cap = tonumber(cap) or Trace.CAP
    if cap < 1 then cap = 1 end
    local stored = Trace.NewEntry(e)
    ring[#ring + 1] = stored
    while #ring > cap do table.remove(ring, 1) end
    return stored
end

-- Newest-first COPY for a reader. The live table is never handed out.
function Trace.Records(ring)
    local out = {}
    if type(ring) ~= "table" then return out end
    for i = #ring, 1, -1 do
        if type(ring[i]) == "table" then out[#out + 1] = ring[i] end
    end
    return out
end

-- One line summarising the ring, for /conduit debug boons.
function Trace.Summary(ring, cap)
    local recs = Trace.Records(ring)
    if #recs == 0 then return "attach trace: empty" end
    local verdicts, seen = {}, {}
    for i = 1, math.min(#recs, 6) do
        local v = recs[i].verdict or "?"
        verdicts[#verdicts + 1] = v
        seen[v] = (seen[v] or 0) + 1
    end
    return ("attach trace: %d/%d entries; newest first: %s")
        :format(#recs, tonumber(cap) or Trace.CAP, table.concat(verdicts, ", "))
end

-- ════════════════════════════════════════════════════════════════════════════
--  LIVE WRAPPERS
-- ════════════════════════════════════════════════════════════════════════════

-- The saved ring. ADDITIVE: a new top-level key that core.lua's ensureKeys creates
-- on an existing save without touching anything else and without a schema bump.
function Trace.Ring(create)
    local db = ns.db
    if type(db) ~= "table" then return nil end
    if type(db.attachTrace) ~= "table" then
        if not create then return nil end
        db.attachTrace = {}
    end
    return db.attachTrace
end

function Trace.Record(e)
    local ring = Trace.Ring(true)
    if not ring then return nil end
    e = (type(e) == "table") and e or {}
    if e.ts == nil then e.ts = (time and time()) or 0 end
    if e.build == nil then e.build = ns.BUILD end
    return Trace.Append(ring, e, Trace.CAP)
end

function Trace.Clear()
    local ring = Trace.Ring(false)
    if not ring then return 0 end
    local n = #ring
    -- IN PLACE: the SavedVariables table identity survives a clear.
    for i = n, 1, -1 do ring[i] = nil end
    return n
end

return Trace
