--[[
    Daseeki Conduit — friends.lua

    AUTO-FRIEND MAIL RECIPIENTS.

    Blizzard's Send Mail window only raises the "are you sure?" confirmation for a
    recipient who is NOT on your friends list. Every recipient you configure here is
    a character you own, so the confirmation is pure friction: this module adds each
    configured recipient to the current character's friends list once, and the popup
    stops appearing for them.

    ── The recipient DIRECTORY ───────────────────────────────────────────────────
    Rules live in DaseekiConduitDB (account-wide), but a rule only carries a bare
    recipient NAME — not the realm or faction that name belongs to. Friending needs
    both: friends must be same-realm and same-faction. So every time a character
    logs in we stamp its rules' recipients into an account-wide DIRECTORY, attributing
    each one with the realm + faction of the character that configured it. That
    attribution is sound by construction: a rule that mails to X was set up on a
    character that CAN mail X, and Classic mail is same-realm, same-faction only.

      db.friendDir = { [key] = { name = "Bankalt", realm = "whitemane",
                                 faction = "Alliance", ts = <epoch> } }
      key = "<lowercased base name>-<lowercased space-stripped realm>"

    The directory is ADDITIVE and never pruned: deleting a rule does not un-friend
    anyone, and first attribution wins (a name is unique per realm across both
    factions, so it can never be legitimately re-attributed).

    ── The per-character MARKER ──────────────────────────────────────────────────
      db.friended = { [charKey] = { [dirKey] = true } }

    Set the first time a character acts on a recipient — whether we added them or
    found them already on the list. A user who later removes that friend has made a
    deliberate choice, and the marker means we never silently re-add them and never
    nag about it again. The marker is the ONLY thing that makes this safe to run on
    every login.

    ── WHY THE FRIENDS LIST MUST BE CONFIRMED FIRST (CDT-1) ──────────────────────
    The friends list is SERVER-SIDE. For the first seconds after login
    C_FriendList.GetNumFriends() answers 0 — not "you have no friends" but "the
    client has not been told yet", and nothing in the API distinguishes the two.

    Until 1.2.4 PLAYER_LOGIN armed a 10-second BACKSTOP that ran the pass anyway,
    confirmed or not. Against an unanswered list, every existing friend read as a
    stranger, so "already a friend" never fired and each became an ADD; numFriends
    read 0 so the cap gate never fired either and the whole directory was run at a
    list that might already be full. Worst of all, every step MARKED — into
    SavedVariables — and the marker is consulted before anything else. Recipients
    that dark pass failed to add were therefore never friended again, on any
    character, across every future session. One dark pass, permanent damage.

    So, taking the discipline from Daseeki-Nexus's mesh-friends module (which
    solved this after Conduit and got it right):

        the pass NEVER runs, and NOT ONE marker byte is written, until we have
        ASKED (C_FriendList.ShowFriends) and a FRIENDLIST_UPDATE has come back to
        us AFTERWARDS.

    In place of the backstop there is a bounded re-ASK ladder (REQUEST_AT). If the
    list never confirms, this character does nothing this session and asks again at
    the next login. Doing nothing is always recoverable; a wrong marker is not.

    ── The SEEN record, and the one-shot heal ────────────────────────────────────
      db.friendSeen = { [charKey] = { [dirKey] = <epoch> } }

    A marker on its own cannot tell "our add never landed" from "the owner removed
    them on purpose" — both look like `marked, and not on the list`. Nexus solved
    that with a confirmation step, and this is the same idea in an additive key: a
    recipient is recorded as SEEN the first time a CONFIRMED pass finds them
    actually on the friends list. From then on:

        marked + seen + absent   -> the owner removed them. Permanent. Never touched.
        marked + not seen        -> we marked them, but never once saw them arrive.

    Pre-1.2.4 saves have no seen records at all, so the ambiguity above is real for
    them and cannot be resolved by any amount of cleverness after the fact. The
    house one-shot pattern applies (name an impossible state, fix it once behind a
    marker, say one line): at the first confirmed pass on an unstamped save,
    `db.friendHealGen` is stamped and every marked recipient is classified against
    the confirmed list — those present are SEEDED as seen (sound: they demonstrably
    are friends), and those absent are listed in `db.friendAmbiguous[charKey]` and
    named in ONE chat line.

    Nothing is re-added automatically. The never-re-add doctrine is sacred and the
    ambiguous half is genuinely undecidable, so the only actor who can resolve it is
    the owner: `/conduit friends reheal` clears the markers on that listed set —
    and nothing else — so the ordinary pass adds each of them exactly once. It is
    ADDITIVE by construction: it can only ever cause an AddFriend, never a removal,
    and it can only ever touch names the heal put on that list.

    ── Everything above the runtime section is PURE ──────────────────────────────
    Canonicalisation, collection, directory stamping, the merge, and the whole skip
    matrix take their world (who I am, which realm, which faction, who is already a
    friend, how full the list is) as an injected context, so selftest.lua exercises
    them headless under a bare Lua VM. No WoW API is touched at call time.
--]]

local ADDON, ns = ...

local Friends = {}
ns.Friends = Friends

-- Schema of the directory entries we write (and of the payload syncbridge.lua ships).
Friends.DIR_SCHEMA = 1

-- The one-shot heal's generation stamp. A save carrying this number has already
-- been asked the pre-1.2.4 marker question and is never asked again.
Friends.HEAL_GEN = 1

-- Classic Era's friends-list cap. Read from the client's own MAX_FRIENDS when it
-- exposes one; this is only the fallback for a client that does not.
Friends.FRIEND_CAP_FALLBACK = 100

-- Remote directories delivered by peers over the Daseeki.Sync "conduit" namespace,
-- keyed by the publishing account's owner key. Deliberately NOT saved: the Nexus
-- namespace store is the system of record and replays everything it holds at every
-- login, so persisting a second copy here would only let a stale one survive Nexus
-- being uninstalled.
Friends.remote = {}

-- ════════════════════════════════════════════════════════════════════════════
--  PURE LOGIC  (self-test targets — no WoW API here)
-- ════════════════════════════════════════════════════════════════════════════

local function trim(s)
    return (tostring(s or "")):match("^%s*(.-)%s*$")
end

-- Realms are compared space-stripped and case-folded ("Blood Sail Buccaneers" and
-- "BloodsailBuccaneers" are the same realm). Returns "" for nothing.
function Friends.NormalizeRealm(realm)
    return (trim(realm):gsub("%s+", "")):lower()
end

-- "Name" or "Name-Realm" -> base, realm (realm nil when the name carries none).
function Friends.SplitRecipient(recipient)
    local s = trim(recipient)
    local base, realm = s:match("^([^%-]+)%-(.+)$")
    if base then return trim(base), trim(realm) end
    return s, nil
end

-- The canonical directory key for a recipient. An explicit "-Realm" in the typed
-- name wins over the stamping character's realm. nil for an empty name.
function Friends.CanonicalKey(recipient, defaultRealm)
    local base, realm = Friends.SplitRecipient(recipient)
    if base == "" then return nil end
    return base:lower() .. "-" .. Friends.NormalizeRealm(realm or defaultRealm)
end

-- One directory entry for a typed recipient, attributed with the stamping
-- character's realm/faction (ctx = { realm =, faction = }). nil for an empty name.
function Friends.MakeEntry(recipient, ctx)
    ctx = ctx or {}
    local base, realm = Friends.SplitRecipient(recipient)
    if base == "" then return nil end
    return {
        name    = base,                                        -- as typed (case preserved)
        realm   = Friends.NormalizeRealm(realm or ctx.realm),
        faction = ctx.faction,
    }
end

-- Every valid recipient named by a rule list, as key -> entry.
--
-- DISABLED rules are included on purpose: a recipient you have configured is a
-- recipient whether or not that particular rule is switched on today, and the
-- friending is harmless either way. Rules whose recipient fails Conduit's own
-- recipient gate (empty / malformed / self) are excluded — the same gate that
-- refuses to mail them.
function Friends.CollectFromRules(rules, ctx)
    ctx = ctx or {}
    local out = {}
    local R = ns.Rules
    for _, rule in ipairs(rules or {}) do
        local recipient = rule and rule.recipient
        if type(recipient) == "string" and trim(recipient) ~= "" then
            local ok = true
            if R and R.ValidateRecipient then
                ok = R.ValidateRecipient(recipient, ctx.me)
            end
            if ok then
                local key   = Friends.CanonicalKey(recipient, ctx.realm)
                local entry = Friends.MakeEntry(recipient, ctx)
                if key and entry then out[key] = entry end
            end
        end
    end
    return out
end

-- Merge freshly collected entries into the account directory (in place).
--
-- FIRST ATTRIBUTION WINS: an entry that already carries a realm/faction is never
-- re-attributed, only FILLED IN where it is missing. Character names are unique per
-- realm across both factions, so a second, different attribution for the same key
-- can only ever be wrong. Returns changed(bool), added(number).
function Friends.StampDirectory(dir, entries, ts)
    if type(dir) ~= "table" then return false, 0 end
    local changed, added = false, 0
    for key, e in pairs(entries or {}) do
        if type(key) == "string" and type(e) == "table" then
            local cur = dir[key]
            if not cur then
                dir[key] = { name = e.name, realm = e.realm, faction = e.faction, ts = ts }
                changed, added = true, added + 1
            else
                if cur.faction == nil and e.faction ~= nil then
                    cur.faction = e.faction
                    changed = true
                end
                if (cur.realm == nil or cur.realm == "") and e.realm and e.realm ~= "" then
                    cur.realm = e.realm
                    changed = true
                end
                -- Cosmetic: adopt the newest spelling of the same name (case only).
                if type(e.name) == "string" and e.name ~= "" and cur.name ~= e.name
                    and type(cur.name) == "string" and cur.name:lower() == e.name:lower() then
                    cur.name = e.name
                end
            end
        end
    end
    return changed, added
end

-- The view the friending pass reads: our own directory over every peer's.
--
-- LOCAL ALWAYS WINS. Our own attribution came from a character on this account that
-- demonstrably mails that name; a peer's is second-hand. Peers are folded in owner
-- key order so the result is deterministic whatever order pairs() hands them back.
function Friends.MergeDirectories(localDir, remoteByOwner)
    local out = {}
    local owners = {}
    for ownerKey in pairs(remoteByOwner or {}) do
        if type(ownerKey) == "string" then owners[#owners + 1] = ownerKey end
    end
    table.sort(owners)
    for _, ownerKey in ipairs(owners) do
        for key, e in pairs(remoteByOwner[ownerKey] or {}) do
            if type(key) == "string" and type(e) == "table" and out[key] == nil then
                out[key] = e
            end
        end
    end
    for key, e in pairs(localDir or {}) do
        if type(key) == "string" and type(e) == "table" then out[key] = e end
    end
    return out
end

----------------------------------------------------------------------
-- THE SKIP MATRIX
--
-- ctx = {
--   enabled       = <bool>,   -- the "Auto-friend mail recipients" setting
--   listConfirmed = <bool>,   -- a FRIENDLIST_UPDATE has answered our request
--   me            = "Name",   -- this character (base name)
--   realm         = "realm",  -- normalized
--   faction       = "Alliance"|"Horde"|nil,
--   friends       = { [lowercased base name] = true },   -- the live friends list
--   marked        = { [dirKey] = true },                 -- this character's markers
--   numFriends    = <n>,
--   maxFriends    = <cap>,
-- }
--
-- Returns action, reason:
--   "add"   add them, mark, and say so once.
--   "mark"  they are on the list right now: record the marker so a later deliberate
--           unfriend is never undone by us, and record that we SAW them, which is
--           what makes that later removal recognisable as deliberate.
--   "cap"   the list is full — one chat line, no marker (a freed slot retries).
--   "skip"  do nothing at all.
--
-- ORDER MATTERS. "already on the friends list" is asked BEFORE "already handled
-- here", which is the reverse of the pre-1.2.4 order. A marked recipient who is on
-- the list has to keep re-answering "mark", because that answer is the only place
-- the SEEN record gets written — and without it a failed add and a deliberate
-- unfriend stay indistinguishable forever. Realm and faction still come first:
-- friendSet() is keyed by base name alone, so a same-named character on another
-- realm must never be mistaken for the entry in hand.
----------------------------------------------------------------------
function Friends.Decide(key, entry, ctx, numFriends)
    ctx = ctx or {}
    numFriends = numFriends or ctx.numFriends or 0

    if not ctx.enabled then return "skip", "auto-friend is off" end
    if type(key) ~= "string" or key == "" then return "skip", "malformed key" end
    if type(entry) ~= "table" then return "skip", "malformed entry" end

    local base = type(entry.name) == "string" and (entry.name:match("^([^%-]+)") or entry.name) or ""
    base = trim(base)
    if base == "" then return "skip", "malformed name" end

    -- Never friend ourselves (and never mark it, so the entry stays clean).
    if base:lower() == trim(ctx.me):lower() then return "skip", "this character" end

    -- Friends must be same-realm. An unknown realm on either side is not evidence
    -- of a mismatch, so it passes through to the attempt.
    local er = Friends.NormalizeRealm(entry.realm)
    local mr = Friends.NormalizeRealm(ctx.realm)
    if er ~= "" and mr ~= "" and er ~= mr then return "skip", "other realm" end

    -- Friends must be same-faction. Unknown faction (a recipient migrated from Raid
    -- Prep that no character has stamped yet) falls through and is attempted: the
    -- server simply refuses a cross-faction name, and the marker below stops us
    -- from ever trying that one again.
    if entry.faction and ctx.faction and entry.faction ~= ctx.faction then
        return "skip", "other faction"
    end

    -- ON THE LIST RIGHT NOW. Answered every pass, marked or not: this is where the
    -- SEEN record comes from, and a seen record is what makes a later disappearance
    -- readable as the owner's own choice rather than a failed add.
    if ctx.friends and ctx.friends[base:lower()] then return "mark", "already a friend" end

    -- Already handled here once — including a friend the user has since removed.
    if ctx.marked and ctx.marked[key] then return "skip", "already handled here" end

    if numFriends >= (ctx.maxFriends or Friends.FRIEND_CAP_FALLBACK) then
        return "cap", "friends list is full"
    end

    return "add", nil
end

-- The whole pass, decided in one deterministic sweep. Each planned add consumes a
-- friends-list slot, so a batch that would run past the cap stops at exactly the
-- right entry instead of firing doomed AddFriend calls.
--
-- Returns plan, refusal:
--   plan    an ordered array of { key, entry, action, reason }
--   refusal a string when the whole pass was refused, and the plan is empty
--
-- THE REFUSAL GATE LIVES HERE, in the pure layer, so the harness can prove it
-- without a client: an unconfirmed friends list is not diffable, and nothing below
-- this line — not one marker byte — may be decided against one.
function Friends.Plan(dir, ctx)
    ctx = ctx or {}
    if not ctx.enabled       then return {}, "auto-friend is off" end
    if not ctx.listConfirmed then return {}, "friends list not confirmed yet" end

    local keys = {}
    for key in pairs(dir or {}) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)

    local plan = {}
    local n = (ctx and ctx.numFriends) or 0
    for _, key in ipairs(keys) do
        local entry = dir[key]
        local action, reason = Friends.Decide(key, entry, ctx, n)
        plan[#plan + 1] = { key = key, entry = entry, action = action, reason = reason }
        if action == "add" then n = n + 1 end
    end
    return plan
end

----------------------------------------------------------------------
-- THE ONE-SHOT HEAL, PURE HALF.
--
-- Sort this character's existing markers against a CONFIRMED friends list into
-- the only two answers the evidence supports:
--
--   present    marked AND on the list. Whatever wrote the marker, it is right, and
--              a SEEN record can be seeded for it soundly.
--   ambiguous  marked, NOT on the list, and never once seen there. Either a dark
--              pass marked an add that never landed, or the owner removed them on
--              purpose — and nothing in the save can tell which.
--
-- Anything marked, absent AND previously seen is neither: that IS the owner's
-- deliberate removal, recognised, and it is never returned by this function at
-- all. Deterministic order, so the chat line and the reheal set never depend on
-- pairs().
----------------------------------------------------------------------
function Friends.ClassifyMarkers(markers, seen, dir, ctx)
    local present, ambiguous = {}, {}
    local friends = (type(ctx) == "table" and ctx.friends) or {}
    local keys = {}
    for key, v in pairs((type(markers) == "table") and markers or {}) do
        if type(key) == "string" and key ~= "" and v then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local entry = (type(dir) == "table") and dir[key] or nil
        local name  = (type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "")
            and entry.name or (key:match("^([^%-]+)") or key)
        local base = (name:match("^([^%-]+)") or name):lower()
        if friends[base] then
            present[#present + 1] = key
        elseif not (type(seen) == "table" and seen[key]) then
            ambiguous[#ambiguous + 1] = key
        end
    end
    return present, ambiguous
end

-- ════════════════════════════════════════════════════════════════════════════
--  STORE ACCESS  (SavedVariables — every key additive, schema unchanged)
-- ════════════════════════════════════════════════════════════════════════════

-- The setting. ABSENT MEANS ON: the feature ships enabled, and every save written
-- before the key existed must read as enabled too.
function Friends.IsEnabled()
    local db = ns.db
    if not (db and db.settings) then return true end
    return db.settings.autoFriend ~= false
end

function Friends.SetEnabled(on)
    local db = ns.db
    if not db then return end
    db.settings = db.settings or {}
    db.settings.autoFriend = on and true or false
end

function Friends.Directory()
    local db = ns.db
    if not db then return {} end
    db.friendDir = db.friendDir or {}
    return db.friendDir
end

-- This character's "already handled" markers.
function Friends.Markers()
    local db = ns.db
    if not db then return {} end
    db.friended = db.friended or {}
    local key = ns:CharKey()
    db.friended[key] = db.friended[key] or {}
    return db.friended[key]
end

-- This character's "and we SAW them on a confirmed list" records. A new top-level
-- key, filled in by core.lua's ensureKeys like every other: additive, no reshape,
-- no schema bump. Nexus reads db.friended and never this, so its read is untouched.
function Friends.Seen()
    local db = ns.db
    if not db then return {} end
    db.friendSeen = db.friendSeen or {}
    local key = ns:CharKey()
    db.friendSeen[key] = db.friendSeen[key] or {}
    return db.friendSeen[key]
end

-- The pre-1.2.4 markers the one-shot heal could not adjudicate, kept so the owner
-- can act on them later rather than only in the second the chat line went past.
function Friends.Ambiguous()
    local db = ns.db
    if not db then return {} end
    db.friendAmbiguous = db.friendAmbiguous or {}
    local key = ns:CharKey()
    db.friendAmbiguous[key] = db.friendAmbiguous[key] or {}
    return db.friendAmbiguous[key]
end

-- The one-shot heal's stamp, per character (the markers it adjudicates are).
function Friends.HealGen()
    local db = ns.db
    if not db or type(db.friendHealGen) ~= "table" then return 0 end
    return tonumber(db.friendHealGen[ns:CharKey()]) or 0
end

function Friends.StampHeal()
    local db = ns.db
    if not db then return false end
    if type(db.friendHealGen) ~= "table" then db.friendHealGen = {} end
    local key = ns:CharKey()
    if tonumber(db.friendHealGen[key]) == Friends.HEAL_GEN then return false end
    db.friendHealGen[key] = Friends.HEAL_GEN
    return true
end

-- Monotonic revision of our directory, persisted so a peer that already holds
-- revision N never re-applies it after a /reload.
function Friends.Rev()
    local db = ns.db
    return (db and tonumber(db.friendDirRev)) or 1
end

function Friends.BumpRev()
    local db = ns.db
    if not db then return end
    db.friendDirRev = (tonumber(db.friendDirRev) or 0) + 1
end

-- ════════════════════════════════════════════════════════════════════════════
--  RUNTIME  (in-game only)
-- ════════════════════════════════════════════════════════════════════════════

Friends._listConfirmed = false   -- a FRIENDLIST_UPDATE has answered our request
Friends._requested     = false   -- we have called ShowFriends this session

-- Public read of the refusal gate. Anything that wants to know whether the list
-- is real or dark asks here rather than keeping a second copy of the answer.
function Friends.ListConfirmed()
    return Friends._listConfirmed and true or false
end

-- Who we are right now, for stamping and deciding.
function Friends.LiveContext()
    local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
    if faction ~= "Alliance" and faction ~= "Horde" then faction = nil end
    local base = ns.Rules and ns.Rules.BaseName(UnitName and UnitName("player") or "")
        or (UnitName and UnitName("player")) or ""
    return {
        me      = base,
        realm   = Friends.NormalizeRealm(GetRealmName and GetRealmName() or ""),
        faction = faction,
    }
end

-- The live friends list as { [lowercased base name] = true }, plus its size.
-- Returns nil when the API is unavailable (the caller then does nothing at all).
local function friendSet()
    local C = C_FriendList
    if not (C and C.GetNumFriends and C.GetFriendInfoByIndex) then return nil, 0 end
    local set = {}
    local n = C.GetNumFriends() or 0
    for i = 1, n do
        local info = C.GetFriendInfoByIndex(i)
        local nm = info and info.name
        if type(nm) == "string" and nm ~= "" then
            set[(nm:match("^([^%-]+)") or nm):lower()] = true
        end
    end
    return set, n
end
Friends._FriendSet = friendSet

local function friendCap()
    return tonumber(_G.MAX_FRIENDS) or Friends.FRIEND_CAP_FALLBACK
end

-- Stamp this character's rule recipients into the account directory and, when that
-- changed anything, bump the revision and hand the new payload to the mesh.
function Friends.Refresh()
    local db = ns.db
    if not db then return false end
    local ctx     = Friends.LiveContext()
    local entries = Friends.CollectFromRules(db.rules, ctx)
    local changed = Friends.StampDirectory(Friends.Directory(), entries, (time and time()) or 0)
    if changed then
        Friends.BumpRev()
        if ns.SyncBridge and ns.SyncBridge.Publish then ns:SafeCall(ns.SyncBridge.Publish) end
    end
    return changed
end

-- A peer's directory landed (syncbridge.lua -> Daseeki.Sync onRemote).
function Friends.SetRemote(ownerKey, recipients)
    if type(ownerKey) ~= "string" or ownerKey == "" then return end
    Friends.remote[ownerKey] = recipients or nil
    Friends._passDone = false
    Friends.SchedulePass(1)
end

-- ── The pass ──────────────────────────────────────────────────────────────────

-- THE ONE-SHOT HEAL, LIVE HALF. Runs at the FIRST confirmed pass on a save that
-- has not been stamped, and never again. Stamps whether or not anything needed
-- healing, so a fresh install cannot drift into a late false heal later.
--
-- It writes SEEN records and a list. It never adds, never removes, and never
-- clears a marker: the ambiguous half is undecidable and only the owner may
-- resolve it, through Friends.Reheal.
local function healLegacyMarkers(ctx, dir)
    local db = ns.db
    if not db then return end
    if Friends.HealGen() == Friends.HEAL_GEN then return end

    local markers = Friends.Markers()
    local seen    = Friends.Seen()
    local present, ambiguous = Friends.ClassifyMarkers(markers, seen, dir, ctx)

    local now = (time and time()) or 0
    for _, key in ipairs(present) do
        if not seen[key] then seen[key] = now end
    end

    local list = Friends.Ambiguous()
    for i = #list, 1, -1 do list[i] = nil end
    for i, key in ipairs(ambiguous) do list[i] = key end

    Friends.StampHeal()

    if #ambiguous > 0 then
        local names = {}
        for _, key in ipairs(ambiguous) do
            local e = dir and dir[key]
            names[#names + 1] = (type(e) == "table" and e.name) or key
        end
        ns:Print(("%d mail recipient%s marked as handled by a build that could read the friends list before the server answered, and %s not on your list now: %s. If you did not remove %s yourself, run /conduit friends reheal.")
            :format(#ambiguous, #ambiguous == 1 and " was" or "s were",
                    #ambiguous == 1 and "is" or "are",
                    ns:Wrap("text", table.concat(names, ", ")),
                    #ambiguous == 1 and "them" or "them"))
    end
end

function Friends.RunPass()
    local db = ns.db
    if not db then return end
    if Friends._running then return end
    if not Friends.IsEnabled() then return end

    -- THE REFUSAL GATE (CDT-1). An unconfirmed friends list is not a list, it is
    -- an unanswered question, and NOTHING below this line — not one AddFriend, not
    -- one marker byte — may run against one. There is no backstop that proceeds
    -- anyway; the re-ASK ladder below is what replaced it.
    if not Friends._listConfirmed then return end

    local C = C_FriendList
    if not (C and C.AddFriend) then return end
    local set, n = friendSet()
    if not set then return end

    local live = Friends.LiveContext()
    local cap  = friendCap()
    local ctx  = {
        enabled       = true,
        listConfirmed = true,
        me            = live.me,
        realm         = live.realm,
        faction       = live.faction,
        friends       = set,
        marked        = Friends.Markers(),
        numFriends    = n,
        maxFriends    = cap,
    }

    Friends._running = true
    local dir  = Friends.MergeDirectories(Friends.Directory(), Friends.remote)

    -- Before the first plan of the first confirmed pass, and once per save.
    ns:SafeCall(healLegacyMarkers, ctx, dir)

    local seen = Friends.Seen()
    local plan = Friends.Plan(dir, ctx)

    local now = (time and time()) or 0
    local added, capped = {}, nil
    for _, step in ipairs(plan) do
        if step.action == "add" then
            ns:SafeCall(C.AddFriend, step.entry.name)
            ctx.marked[step.key] = true
            added[#added + 1] = step.entry.name
        elseif step.action == "mark" then
            -- ON THE LIST, WITH OUR KNOWLEDGE. Both facts are written: the marker
            -- (never re-add) and the sighting (so a later disappearance is
            -- readable as the owner's own choice and not a failed add).
            ctx.marked[step.key] = true
            if not seen[step.key] then seen[step.key] = now end
        elseif step.action == "cap" and not capped then
            capped = step.entry.name
        end
    end
    Friends._running  = false
    Friends._passDone = true

    -- ONE FOLLOW-UP after a pass that added anybody, so the adds we just made are
    -- SEEN on the next confirmed read and stop being ambiguous. A pass that adds
    -- nothing schedules nothing, so this terminates after exactly one round.
    if #added > 0 then
        Friends._passDone = false
        Friends.SchedulePass(2)
    end

    if #added == 1 then
        ns:Print(("added %s to your friends list — mail to them now sends without Blizzard's confirmation.")
            :format(ns:Wrap("text", added[1])))
    elseif #added > 1 then
        ns:Print(("added %d mail recipients to your friends list (%s) — mail to them now sends without Blizzard's confirmation.")
            :format(#added, ns:Wrap("text", table.concat(added, ", "))))
    end
    if capped then
        ns:Print(("your friends list is full (%d) — %s was not added, so mail to them still asks for confirmation.")
            :format(cap, capped))
    end
end

-- Debounced pass. One timer at a time; the first request wins the slot.
function Friends.SchedulePass(delay)
    if Friends._scheduled then return end
    Friends._scheduled = true
    if C_Timer and C_Timer.After then
        C_Timer.After(delay or 0.5, function()
            Friends._scheduled = false
            ns:SafeCall(Friends.RunPass)
        end)
    else
        Friends._scheduled = false
        ns:SafeCall(Friends.RunPass)
    end
end

-- Options calls this the moment a rule's recipient changes, so a bank alt added
-- mid-session is friended without waiting for the next login.
function Friends.OnRecipientChanged()
    ns:SafeCall(Friends.Refresh)
    Friends._passDone = false
    Friends.SchedulePass(1)
end

-- ── The one-shot heal's owner-facing half ────────────────────────────────────
--
-- ADDITIONS ONLY, AND ONLY WHERE THE SAVE ITSELF CANNOT DECIDE. This clears the
-- markers on the exact set the heal listed — pre-1.2.4 markers on recipients that
-- are not on the friends list and were never once seen there — so the ordinary
-- pass adds each of them exactly once and re-marks them. It removes no friend, it
-- touches nothing the heal did not list, and the list is emptied as it goes, so
-- running it twice does nothing the second time.
--
-- It exists because the alternative is worse in both directions: doing this
-- automatically would silently undo deliberate unfriends, and doing nothing at all
-- leaves recipients a dark pass failed to add permanently stranded.
function Friends.Reheal()
    local list = Friends.Ambiguous()
    if #list == 0 then
        ns:Print("nothing to re-check — no recipient is waiting on this.")
        return 0
    end
    local markers = Friends.Markers()
    local dir     = Friends.MergeDirectories(Friends.Directory(), Friends.remote)
    local names, n = {}, 0
    for _, key in ipairs(list) do
        if type(key) == "string" and markers[key] then
            markers[key] = nil
            n = n + 1
            local e = dir[key]
            names[#names + 1] = (type(e) == "table" and e.name) or key
        end
    end
    for i = #list, 1, -1 do list[i] = nil end
    if n == 0 then
        ns:Print("nothing to re-check — those markers are already gone.")
        return 0
    end
    ns:Print(("re-checking %d recipient(s) (%s) — they will be added once if they are not already on your list.")
        :format(n, ns:Wrap("text", table.concat(names, ", "))))
    Friends._passDone = false
    Friends.SchedulePass(0.5)
    return n
end

-- ── Diagnostics (/conduit debug friends) ──────────────────────────────────────

function Friends.Debug()
    ns:Print(("auto-friend: %s"):format(Friends.IsEnabled() and "ON" or "off"))
    ns:Print("  friends list: " .. (Friends._listConfirmed and "confirmed"
        or (Friends._requested and "requested, waiting for FRIENDLIST_UPDATE"
                                or "not requested yet")))
    local bridge = ns.SyncBridge
    if bridge then
        local _, why = bridge.Sync()
        ns:Print("  cross-account: " .. (bridge.Registered() and
            ("publishing + reading the \"" .. bridge.KEY .. "\" namespace") or
            ("local only — " .. tostring(why))))
    end
    local set, n = friendSet()
    ns:Print(("  entries: %s of %d"):format(set and tostring(n) or "unavailable", friendCap()))

    local waiting = Friends.Ambiguous()
    if #waiting > 0 then
        ns:Print(("  %d recipient(s) marked by a pre-1.2.4 dark pass and not on your list — /conduit friends reheal")
            :format(#waiting))
    end

    local live = Friends.LiveContext()
    local ctx = {
        enabled = Friends.IsEnabled(), listConfirmed = Friends.ListConfirmed(),
        me = live.me, realm = live.realm, faction = live.faction,
        friends = set or {}, marked = Friends.Markers(), numFriends = n, maxFriends = friendCap(),
    }
    local plan, refusal = Friends.Plan(Friends.MergeDirectories(Friends.Directory(), Friends.remote), ctx)
    if refusal then
        ns:Print("  the pass would do nothing right now — " .. refusal)
        return
    end
    if #plan == 0 then
        ns:Print("  no recipients known yet — set a recipient on a rule.")
        return
    end
    for _, step in ipairs(plan) do
        local e = step.entry
        ns:Print(("  %s (%s/%s) -> %s%s"):format(
            tostring(e.name), tostring(e.realm ~= "" and e.realm or "?"),
            tostring(e.faction or "?"), step.action,
            step.reason and (" — " .. step.reason) or ""))
    end
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

-- THE BOUNDED RE-ASK LADDER, in place of the 10s proceed-anyway backstop.
--
-- ShowFriends asks the server for the list; FRIENDLIST_UPDATE is the answer. Only
-- an update that arrives AFTER our request counts as confirmation, so an early
-- event fired for some other reason cannot green-light a dark list. We ask again
-- at each rung until we are answered, and then we stop asking. If no answer ever
-- comes, this character does nothing this session — deliberately, and recoverably.
Friends.REQUEST_AT = { 5, 15, 30 }   -- seconds after login; bounded, then we stop

function Friends.RequestList()
    local C = C_FriendList
    if not (C and C.ShowFriends) then return end
    Friends._requested = true
    ns:SafeCall(C.ShowFriends)
end

ns:RegisterEvent("PLAYER_LOGIN", function()
    -- migrate.lua also runs at PLAYER_LOGIN and may append imported rules; the
    -- directory is stamped again by the recipient-changed hook it fires, and in any
    -- case re-stamped on the next login. Handler order is not relied upon.
    ns:SafeCall(Friends.Refresh)

    if ns.SyncBridge and ns.SyncBridge.Login then ns:SafeCall(ns.SyncBridge.Login) end

    Friends._listConfirmed = false
    Friends._requested     = false
    Friends._passDone      = false

    Friends.RequestList()
    for _, at in ipairs(Friends.REQUEST_AT) do
        if C_Timer and C_Timer.After then
            C_Timer.After(at, function()
                if Friends._listConfirmed then return end
                ns:SafeCall(Friends.RequestList)
            end)
        end
    end
end)

ns:RegisterEvent("FRIENDLIST_UPDATE", function()
    -- NOT AN ANSWER TO US (YET). An update that pre-dates our request tells us
    -- nothing about whether the list we would read is the server's or the client's
    -- empty placeholder.
    if not Friends._requested then return end
    Friends._listConfirmed = true
    -- Fires again for our own AddFriend calls; _passDone keeps that from looping.
    if Friends._passDone then return end
    Friends.SchedulePass(0.5)
end)
