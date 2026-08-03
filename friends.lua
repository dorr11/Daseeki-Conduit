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
--   enabled    = <bool>,   -- the "Auto-friend mail recipients" setting
--   me         = "Name",   -- this character (base name)
--   realm      = "realm",  -- normalized
--   faction    = "Alliance"|"Horde"|nil,
--   friends    = { [lowercased base name] = true },   -- the live friends list
--   marked     = { [dirKey] = true },                 -- this character's markers
--   numFriends = <n>,
--   maxFriends = <cap>,
-- }
--
-- Returns action, reason:
--   "add"   add them, mark, and say so once.
--   "mark"  nothing to do in game, but record the marker so a later deliberate
--           unfriend is never undone by us.
--   "cap"   the list is full — one chat line, no marker (a freed slot retries).
--   "skip"  do nothing at all.
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

    -- Already handled here once — including a friend the user has since removed.
    if ctx.marked and ctx.marked[key] then return "skip", "already handled here" end

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

    if ctx.friends and ctx.friends[base:lower()] then return "mark", "already a friend" end

    if numFriends >= (ctx.maxFriends or Friends.FRIEND_CAP_FALLBACK) then
        return "cap", "friends list is full"
    end

    return "add", nil
end

-- The whole pass, decided in one deterministic sweep. Each planned add consumes a
-- friends-list slot, so a batch that would run past the cap stops at exactly the
-- right entry instead of firing doomed AddFriend calls.
-- Returns an ordered array of { key, entry, action, reason }.
function Friends.Plan(dir, ctx)
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

function Friends.RunPass()
    local db = ns.db
    if not db then return end
    if Friends._running then return end
    if not Friends.IsEnabled() then return end

    local C = C_FriendList
    if not (C and C.AddFriend) then return end
    local set, n = friendSet()
    if not set then return end

    local live = Friends.LiveContext()
    local cap  = friendCap()
    local ctx  = {
        enabled    = true,
        me         = live.me,
        realm      = live.realm,
        faction    = live.faction,
        friends    = set,
        marked     = Friends.Markers(),
        numFriends = n,
        maxFriends = cap,
    }

    Friends._running = true
    local dir  = Friends.MergeDirectories(Friends.Directory(), Friends.remote)
    local plan = Friends.Plan(dir, ctx)

    local added, capped = {}, nil
    for _, step in ipairs(plan) do
        if step.action == "add" then
            ns:SafeCall(C.AddFriend, step.entry.name)
            ctx.marked[step.key] = true
            added[#added + 1] = step.entry.name
        elseif step.action == "mark" then
            ctx.marked[step.key] = true
        elseif step.action == "cap" and not capped then
            capped = step.entry.name
        end
    end
    Friends._running  = false
    Friends._passDone = true

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

-- ── Diagnostics (/conduit debug friends) ──────────────────────────────────────

function Friends.Debug()
    ns:Print(("auto-friend: %s"):format(Friends.IsEnabled() and "ON" or "off"))
    local bridge = ns.SyncBridge
    if bridge then
        local _, why = bridge.Sync()
        ns:Print("  cross-account: " .. (bridge.Registered() and
            ("publishing + reading the \"" .. bridge.KEY .. "\" namespace") or
            ("local only — " .. tostring(why))))
    end
    local set, n = friendSet()
    ns:Print(("  friends list: %s of %d"):format(set and tostring(n) or "unavailable", friendCap()))

    local live = Friends.LiveContext()
    local ctx = {
        enabled = Friends.IsEnabled(), me = live.me, realm = live.realm, faction = live.faction,
        friends = set or {}, marked = Friends.Markers(), numFriends = n, maxFriends = friendCap(),
    }
    local plan = Friends.Plan(Friends.MergeDirectories(Friends.Directory(), Friends.remote), ctx)
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

ns:RegisterEvent("PLAYER_LOGIN", function()
    -- migrate.lua also runs at PLAYER_LOGIN and may append imported rules; the
    -- directory is stamped again by the recipient-changed hook it fires, and in any
    -- case re-stamped on the next login. Handler order is not relied upon.
    ns:SafeCall(Friends.Refresh)

    if ns.SyncBridge and ns.SyncBridge.Login then ns:SafeCall(ns.SyncBridge.Login) end

    -- The friends list is server-side: at login GetNumFriends can still read 0 until
    -- the client receives it. Ask for it, and run the pass off FRIENDLIST_UPDATE.
    if C_FriendList and C_FriendList.ShowFriends then
        ns:SafeCall(C_FriendList.ShowFriends)
    end
    -- Backstop for a client that never fires the event: run anyway after 10s.
    if C_Timer and C_Timer.After then
        C_Timer.After(10, function()
            if not Friends._passDone then ns:SafeCall(Friends.RunPass) end
        end)
    end
end)

ns:RegisterEvent("FRIENDLIST_UPDATE", function()
    -- Fires again for our own AddFriend calls; _passDone keeps that from looping.
    if Friends._passDone then return end
    Friends.SchedulePass(0.5)
end)
