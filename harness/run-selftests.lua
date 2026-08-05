-- =====================================================================
-- Daseeki-Conduit headless self-test harness (REAL Lua 5.1)
--
-- Follows the Daseeki suite harness pattern (see Daseeki-Buff-Tracker/harness):
-- stub the minimal WoW API, load the REAL addon files under a real Lua
-- interpreter, drive the REAL code, exit non-zero on any failure.
--
-- Conduit already owns a self-test REGISTRY (core.lua ns:RegisterSelfTest, driven
-- in game by /conduit debug selftest), so this harness does not reimplement any
-- assertion: it loads the shipped suites and RUNS them, then adds the gates that
-- only make sense outside the game (parse, firewall, SavedVariables additivity,
-- and an end-to-end auto-friend drive against a stubbed C_FriendList).
--
-- Gates:
--   0        TOC PARSE   loadfile (parse only) every .lua the .toc lists.
--   FW       FIREWALL    no third-party addon identifier in the repo's text.
--   SUITES   the shipped pure suites (rules / batches / gold / recipients /
--            mail queue / Raid-Prep migration / auto-friend / sync bridge /
--            Nexus alt names).
--   SV       InitDB adds the auto-friend keys to a PRE-EXISTING save without
--            touching rules, and without a schema bump (additive-only).
--   FRIEND   the REAL Friends.RunPass against a stubbed C_FriendList:
--            adds once, marks, never re-adds — including after the user
--            deliberately unfriends — and stops cleanly at the list cap.
--   MUT      MUTATION TEST of the boon plan builder: twelve one-operator
--            mutants of boons.lua, every one of which must be killed by the
--            checks. A survivor is a rule the suite only appears to cover.
--
-- Usage:  lua5.1 run-selftests.lua [CONDUIT_DIR]   (exit 0 = ALL PASS)
-- =====================================================================

local realprint = print   -- kept before the addon's print is swallowed below

local HARNESS_DIR = (arg[0]:match("^(.*)[\\/][^\\/]+$")) or "."
local function slash(p) return (p:gsub("\\", "/")) end
HARNESS_DIR = slash(HARNESS_DIR)
local DIR = slash(arg[1] or (HARNESS_DIR .. "/.."))
local function P(rel) return DIR .. "/" .. rel end

local TOC_FILE   = "Daseeki-Conduit.toc"
local ADDON_NAME = "Daseeki-Conduit"

local FAILS = 0
local function fail(m) FAILS = FAILS + 1; realprint("  FAIL  " .. m) end
local function ok(m)   realprint("  ok    " .. m) end
local function ck(cond, m) if cond then ok(m) else fail(m) end end

local function readFile(path)
    local fh = io.open(path, "r"); if not fh then return nil end
    local s = fh:read("*a"); fh:close(); return s
end

----------------------------------------------------------------------
-- GATE 0: TOC PARSE
----------------------------------------------------------------------
local function readTocLuaFiles(tocPath)
    local fh = io.open(tocPath, "r"); if not fh then return nil end
    local out = {}
    for line in fh:lines() do
        line = line:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and line:lower():sub(-4) == ".lua" then
            out[#out + 1] = (line:gsub("\\", "/"))
        end
    end
    fh:close()
    return out
end

realprint("=== GATE 0: toc parse (loadfile every .lua in " .. TOC_FILE .. ") ===")
local TOC_LUA = readTocLuaFiles(P(TOC_FILE))
if not TOC_LUA or #TOC_LUA == 0 then realprint("  FAIL  cannot read .toc lua list"); os.exit(1) end
for _, rel in ipairs(TOC_LUA) do
    local chunk, err = loadfile(P(rel))
    if chunk then ok("parse " .. rel) else fail("parse " .. rel .. " -> " .. tostring(err)) end
end
if FAILS > 0 then realprint("=== GATE 0: FAIL (a file does not compile) ==="); os.exit(1) end
realprint("=== GATE 0: PASS ===\n")

----------------------------------------------------------------------
-- GATE FW: CLEAN-ROOM FIREWALL
--
-- Product identifiers of absorption-target / third-party addons (not generic
-- words). Conduit is an ORIGINAL Daseeki addon; the only other addons it may name
-- are Daseeki's own (Raid Prep, Nexus, Core), which are not on this list.
----------------------------------------------------------------------
local FORBIDDEN = {
    "portalmage", "totemtimers", "druidbar", "pallypower",
    "weakauras", "weakaurassaved", "aura_env",
    "shadownetwork", "novainstancetracker", "novaworldbuffs",
    "bigwigs", "elvui", "bartender4", "dominos",
    "postal", "tradeskillmaster", "altoholic", "baggins", "bagnon",
}
realprint("=== GATE FW: clean-room firewall ===")
local FW_FILES = { "CHANGELOG.md", "README.md", TOC_FILE }
for _, rel in ipairs(TOC_LUA) do FW_FILES[#FW_FILES + 1] = rel end
for _, rel in ipairs(FW_FILES) do
    local src = readFile(P(rel))
    if src then
        local lower = src:lower()
        local bad = {}
        for _, tok in ipairs(FORBIDDEN) do
            if lower:find(tok, 1, true) then bad[#bad + 1] = tok end
        end
        if #bad > 0 then fail(rel .. " contains: " .. table.concat(bad, ", ")) else ok(rel) end
    end
end
if FAILS > 0 then realprint("=== GATE FW: FAIL ==="); os.exit(1) end
realprint("=== GATE FW: PASS ===\n")

----------------------------------------------------------------------
-- Minimal WoW stub — only what the loaded files touch AT LOAD, plus the handful
-- the pure/driven paths read at call time. Deliberately NOT loaded here:
-- panel.lua / options.lua (DaseekiUI frame construction) and mail.lua (live mail
-- API); nothing they own is pure, and GATE 0 already proves they compile.
----------------------------------------------------------------------
local CHAT = {}
_G.print = function(...)                       -- capture the addon's chat output
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    CHAT[#CHAT + 1] = table.concat(parts, " ")
end
_G.geterrorhandler = function() return function(err) error(err, 0) end end
_G.CreateFrame = function()
    local f = {}
    function f:RegisterEvent() end
    function f:UnregisterEvent() end
    function f:SetScript(_, fn) self._onEvent = fn end
    function f:GetScript() return self._onEvent end
    return f
end
_G.SlashCmdList = {}
_G.UnitName          = function() return _G.__TESTNAME or "Hero" end
_G.GetRealmName      = function() return "Whitemane" end
_G.UnitFactionGroup  = function() return _G.__TESTFACTION or "Alliance" end
_G.strfind, _G.strmatch, _G.strsub, _G.format =
    string.find, string.match, string.sub, string.format
_G.__CLOCK = 1700000000
_G.time = function() return _G.__CLOCK end

local function chatFind(needle)
    for _, line in ipairs(CHAT) do if line:find(needle, 1, true) then return line end end
    return nil
end
local function chatClear() for i = #CHAT, 1, -1 do CHAT[i] = nil end end

----------------------------------------------------------------------
-- Load the REAL addon files into one shared namespace, in .toc order.
----------------------------------------------------------------------
local ns = {}
local LOAD = { "core.lua", "rules.lua", "migrate.lua", "network.lua", "ledger.lua",
               "boons.lua", "friends.lua", "syncbridge.lua", "selftest.lua" }
for _, rel in ipairs(LOAD) do
    local chunk, err = loadfile(P(rel))
    if not chunk then realprint("  FAIL  loadfile " .. rel .. " -> " .. tostring(err)); os.exit(2) end
    local good, rerr = pcall(chunk, ADDON_NAME, ns)
    if not good then realprint("  FAIL  executing " .. rel .. " -> " .. tostring(rerr)); os.exit(2) end
end

----------------------------------------------------------------------
-- GATE SUITES: run the shipped self-test registry (the same code
-- /conduit debug selftest runs in game).
----------------------------------------------------------------------
realprint("=== GATE SUITES: ns:RunSelfTests (the shipped pure suites) ===")
chatClear()
local suitesOk, suitesErr = pcall(function() return ns:RunSelfTests(true) end)
if not suitesOk then
    fail("RunSelfTests errored -> " .. tostring(suitesErr))
else
    for _, line in ipairs(CHAT) do
        if line:find("FAIL", 1, true) then realprint("  " .. line) end
    end
    ck(chatFind("ALL SUITES PASS") ~= nil, "every registered suite passes")
    -- A suite that silently fails to register would still report ALL PASS, so name
    -- the ones whose files this harness loads for their own sake.
    ck(chatFind("auto-friend:") ~= nil, "the auto-friend suite ran")
    ck(chatFind("sync-bridge:") ~= nil, "the sync-bridge suite ran")
    ck(chatFind("network:") ~= nil, "the network suite ran")
    ck(chatFind("mailbox-close:") ~= nil, "the mailbox-teardown suite ran")
    ck(chatFind("boon-plan:") ~= nil, "the boon plan-builder suite ran")
    ck(chatFind("boon-arming:") ~= nil, "the boon arming-matrix suite ran")
    ck(chatFind("boon-queue:") ~= nil, "the boon queue/preview suite ran")
    ck(chatFind("ledger:") ~= nil, "the outbound-ledger suite ran")
end

----------------------------------------------------------------------
-- The teardown coordinator's WIRING, which the pure suite cannot see: the panel
-- and the send engine must actually be ON the live closer list, or "the panel
-- closes with the mail window" is true only in the test. panel.lua / mail.lua are
-- not loadable here (DaseekiUI frames + live mail API), so assert the registration
-- calls exist in the shipped source instead — a regression that drops one back to
-- its own MAIL_CLOSED handler, or to none at all, fails here.
----------------------------------------------------------------------
do
    local function sourceHas(rel, needle, label)
        local src = readFile(P(rel))
        ck(src ~= nil and src:find(needle, 1, true) ~= nil, label)
    end
    sourceHas("panel.lua", "ns:RegisterMailboxCloser",
        "panel.lua registers a mailbox closer (the panel hides with the mail window)")
    sourceHas("mail.lua", "ns:RegisterMailboxCloser",
        "mail.lua registers a mailbox closer (the batch aborts with the mail window)")
    sourceHas("mail.lua", 'StaticPopup_Hide("DASEEKI_CONDUIT_SEND_CONFIRM")',
        "...and dismisses the send-confirm popup with it")
    -- Both MailFrame scripts now go in through the install-once guard rather than a
    -- bare mf:HookScript, so the pin follows them there (GATE HDR (d) checks the
    -- guard itself; the mailbox-close suite drives it for real).
    sourceHas("core.lua", '{ "OnHide", function()',
        "core.lua hooks MailFrame OnHide as well as MAIL_CLOSED")
    -- THERE IS ONE SEND PATH. Boon replenishment must ride mail.lua's confirm-first
    -- engine, not grow a second one; a regression that reaches for SendMail from
    -- boons.lua (or skips the confirm popup) fails right here.
    sourceHas("boons.lua", "ns.Mail.RunQueue",
        "boons.lua sends through the shared mail engine")
    do
        local src = readFile(P("boons.lua")) or ""
        ck(src:find("SendMail", 1, true) == nil,
           "...and never calls SendMail itself (the confirm gate cannot be routed around)")
        ck(src:find("StaticPopup_Show", 1, true) == nil,
           "...nor raises its own send popup")
    end
    sourceHas("mail.lua", "SplitContainerItem",
        "mail.lua can attach PART of a stack (a top-up to ten is not a whole stack)")

    -- The 1.2.0 contract, pinned where a later edit cannot quietly walk it back.
    -- GATE ATTACH and GATE RUN drive all of this for real; these are the one-line
    -- tripwires that say WHY a driven test would suddenly go red.
    do
        local m = readFile(P("mail.lua")) or ""
        ck(m:find("local function verifyAttach", 1, true) ~= nil,
           "mail.lua verifies the attach against the plan before every send")
        ck(m:find("local viaBag = have - left", 1, true) ~= nil,
           "...measuring what LEFT THE BAG SLOT, not what it hoped would land")
        ck(m:find("local viaForm = formCount(nextSlot)", 1, true) ~= nil,
           "...cross-checked against what the FORM itself reports")
        ck(m:find("slotAttached(nextSlot) and landed == want", 1, true) ~= nil,
           "...and a draw only counts when exactly the ask arrived")
        -- 1.2.1: the live failure was an attach racing the client's bag settlement.
        ck(m:find("local SETTLE_TIMEOUT   = 1.0", 1, true) ~= nil,
           "arming waits for the bags to settle, with a 1s ceiling")
        ck(m:find("awaitSettlement(armCurrent)", 1, true) ~= nil,
           "...before every re-arm, not just the first")
        ck(m:find("Rules.AnySlotLocked", 1, true) ~= nil,
           "...and a locked bag slot counts as 'still moving'")
        ck(m:find("Rules.DrawExact(live, mail.units, ns.MAX_ATTACH)", 1, true) ~= nil,
           "draws are re-derived from a fresh scan at arm time (coordinates go stale)")
        ck(m:find('return "async"', 1, true) ~= nil,
           "a split that took from the slot but not onto the cursor is never re-asked")
        -- The over-attach itself: a whole-stack pickup that then REWRITES the ask to
        -- match what it took. The clamp `if want > have then want = have end` is the
        -- opposite operation (down, never up) and is meant to be there.
        ck(m:find("C.PickupContainerItem(st.bag, st.slot)\n                        want = have", 1, true) == nil,
           "...and never rewrites the ask to match a whole stack it picked up (the over-attach)")
        ck(m:find("if want > have then want = have end", 1, true) ~= nil,
           "...while the ask is still clamped DOWN to what the slot really holds")
        ck(m:find('ns:RegisterEvent("MAIL_SUCCESS"', 1, true) ~= nil,
           "the send ack keys on MAIL_SUCCESS")
        ck(m:find('ns:RegisterEvent("MAIL_SEND_SUCCESS"', 1, true) == nil,
           "...and NOT on MAIL_SEND_SUCCESS (spec finding: it is the unreliable one)")
        ck(m:find("local ACK_TIMEOUT      = 15", 1, true) ~= nil, "15s ceiling on the ack")
        ck(m:find("local EVIDENCE_TIMEOUT = 15", 1, true) ~= nil, "15s ceiling on the evidence")
        ck(m:find("local FAILURE_SPACING  = 0.5", 1, true) ~= nil, "0.5s spacing after failures only")
        ck(m:find("local BUTTON_HOLD      = 0.2", 1, true) ~= nil,
           "0.2s repeating re-assert of Blizzard's Send button")
        ck(m:find("local RETRY_BUDGET     = 1", 1, true) ~= nil, "one retry per mail")
        ck(m:find("ns.Ledger.Record", 1, true) ~= nil, "a confirmed send writes the outbound ledger")
        local recAt = m:find("ns.Ledger.Record", 1, true)
        local confirmAt = m:find("local function confirmSend", 1, true)
        local failAt = m:find("local function failSend", 1, true)
        ck(recAt and confirmAt and failAt and recAt > confirmAt and recAt < failAt,
           "...from confirmSend and nowhere else (an attempt is not a send)")
    end
    do
        local b = readFile(P("boons.lua")) or ""
        ck(b:find("rebuild  = function()", 1, true) ~= nil,
           "boons.lua re-derives its queue at run start (idempotence by construction)")
        ck(b:find("check = function(mail)", 1, true) ~= nil,
           "...and re-checks each mail against live truth before it is attached")
    end
end
if FAILS > 0 then realprint("=== GATE SUITES: FAIL ==="); os.exit(1) end
realprint("=== GATE SUITES: PASS ===\n")

----------------------------------------------------------------------
-- GATE SV: the auto-friend keys are ADDITIVE.
--
-- A user sitting on a shipped v0.1.0 save must gain the new keys and lose
-- nothing — and the schema must NOT move, because nothing was reshaped.
----------------------------------------------------------------------
realprint("=== GATE SV: InitDB is additive on a pre-existing save ===")
chatClear()
_G.DaseekiConduitDB = {
    schema        = 1,
    rules         = { { id = 1, name = "Ore to Bank", enabled = true, kind = "items",
                        recipient = "Bankalt", filter = { mode = "category", classID = 7 } } },
    settings      = { __sentinel = true },
    disabledChars = { ["Someone-Whitemane"] = true },
    nextRuleId    = 2,
    migratedRaidPrep = true,
}
ns:InitDB()
local db = _G.DaseekiConduitDB
ck(db.schema == 1, "schema NOT bumped (the new keys are additive)")
ck(#db.rules == 1 and db.rules[1].recipient == "Bankalt", "existing rules preserved untouched")
ck(db.settings.__sentinel == true, "existing settings preserved")
ck(db.disabledChars["Someone-Whitemane"] == true, "per-character disables preserved")
ck(db.migratedRaidPrep == true, "the Raid Prep migration marker survives")
ck(type(db.friendDir) == "table", "friendDir created")
ck(db.friendDirRev == 1, "friendDirRev seeded")
ck(type(db.friended) == "table", "friended (per-character markers) created")
ck(type(db.outbox) == "table", "outbox (the 1.2.0 outbound ledger) created")
ck(#db.outbox == 0, "...empty, so an existing save starts with nothing in the post")
realprint("=== GATE SV: " .. (FAILS == 0 and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE FRIEND: drive the REAL Friends.RunPass against a stubbed C_FriendList.
----------------------------------------------------------------------
realprint("=== GATE FRIEND: real Friends.RunPass (add once, mark, never re-add) ===")
local F = ns.Friends

local FRIENDS, ADDED = {}, {}
_G.C_FriendList = {
    GetNumFriends        = function() return #FRIENDS end,
    GetFriendInfoByIndex = function(i) return FRIENDS[i] and { name = FRIENDS[i] } or nil end,
    AddFriend            = function(name) ADDED[#ADDED + 1] = name; FRIENDS[#FRIENDS + 1] = name end,
    ShowFriends          = function() end,
}
-- No C_Timer: SchedulePass then runs inline, which is exactly what we want here.

-- (a) settings default + the local-only path (no Nexus on this _G).
ck(F.IsEnabled() == true, "(a) auto-friend defaults ON (absent key reads as enabled)")
ck(ns.SyncBridge.Available() == false, "(a) no Nexus present -> the sync bridge is inactive")
ck(ns.SyncBridge.Publish() == false, "(a) ...and publishing is a clean no-op, not an error")

-- (b) first Refresh stamps the directory from this character's rules and bumps rev.
chatClear()
ck(F.Refresh() == true, "(b) first Refresh stamps the directory")
ck(db.friendDir["bankalt-whitemane"] ~= nil, "(b) the rule's recipient is in the directory")
ck(db.friendDir["bankalt-whitemane"].faction == "Alliance", "(b) attributed with this character's faction")
ck(db.friendDir["bankalt-whitemane"].realm == "whitemane", "(b) attributed with this character's realm")
ck(db.friendDirRev == 2, "(b) revision bumped for the mesh")
ck(F.Refresh() == false, "(b) a second Refresh changes nothing")
ck(db.friendDirRev == 2, "(b) ...and does not bump the revision")

-- (c) the pass adds the recipient exactly once and says so.
chatClear()
F.RunPass()
ck(#ADDED == 1 and ADDED[1] == "Bankalt", "(c) Bankalt added to the friends list")
ck(db.friended["Hero-Whitemane"]["bankalt-whitemane"] == true, "(c) per-character marker written")
ck(chatFind("without Blizzard's confirmation") ~= nil, "(c) one informative chat line")

-- (d) re-running is silent and adds nothing (already a friend + marked).
chatClear()
F.RunPass()
ck(#ADDED == 1, "(d) a second pass adds nothing")
ck(#CHAT == 0, "(d) ...and says nothing (no re-nag)")

-- (e) THE OWNER RULE: a deliberate unfriend is never undone.
chatClear()
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end     -- user removed them by hand
F.RunPass()
ck(#ADDED == 1, "(e) an unfriended recipient is NOT re-added (the marker is intent)")
ck(#CHAT == 0, "(e) ...and nothing is said about it")

-- (f) the current character is never friended, even when named by a rule.
chatClear()
db.rules[#db.rules + 1] = { id = 2, name = "Self", enabled = true, kind = "gold",
                            recipient = "Hero", keepCopper = 0 }
F.Refresh()
ck(db.friendDir["hero-whitemane"] == nil, "(f) the logged-in character never enters the directory")
F.RunPass()
ck(#ADDED == 1, "(f) ...and is never added")

-- (g) another character on the account: fresh markers, and it friends the recipient
--     the first character configured (account-wide directory, per-character marker).
chatClear()
_G.__TESTNAME = "Alt"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
F.RunPass()
ck(#ADDED == 2 and ADDED[2] == "Bankalt", "(g) a second character friends the same recipient")
ck(db.friended["Alt-Whitemane"]["bankalt-whitemane"] == true, "(g) its own marker is written")
ck(db.friended["Hero-Whitemane"]["bankalt-whitemane"] == true, "(g) the first character's marker is untouched")

-- (h) a HORDE character on the same account skips the Alliance recipient silently.
chatClear()
_G.__TESTNAME    = "Hordie"
_G.__TESTFACTION = "Horde"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
F.RunPass()
ck(#ADDED == 2, "(h) a cross-faction recipient is skipped")
ck(#CHAT == 0, "(h) ...silently")
ck(db.friended["Hordie-Whitemane"]["bankalt-whitemane"] == nil,
   "(h) ...and NOT marked, so a same-faction character can still act on it")

-- (i) the cap: one chat line, no add, no marker (a freed slot retries later).
chatClear()
_G.__TESTNAME    = "Capped"
_G.__TESTFACTION = "Alliance"
_G.MAX_FRIENDS   = 1
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
FRIENDS[1] = "Someoneelse"
F.RunPass()
ck(#ADDED == 2, "(i) nothing added once the list is full")
ck(chatFind("friends list is full") ~= nil, "(i) one chat line explains why")
ck(db.friended["Capped-Whitemane"]["bankalt-whitemane"] == nil,
   "(i) ...and no marker, so freeing a slot lets it retry")
_G.MAX_FRIENDS = nil

-- (j) the setting off is a hard stop.
chatClear()
_G.__TESTNAME = "OptedOut"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
F.SetEnabled(false)
ck(F.IsEnabled() == false, "(j) the toggle reads back off")
F.RunPass()
ck(#ADDED == 2, "(j) the pass does nothing while off")
ck(#CHAT == 0, "(j) ...and says nothing")
F.SetEnabled(true)

-- (k) a peer's directory reaches the pass through the sync bridge's consumer path.
chatClear()
_G.__TESTNAME = "Reader"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
ns.SyncBridge.OnRemote("account-b", { v = 1, recipients = {
    ["peerbank-whitemane"] = { name = "Peerbank", realm = "whitemane", faction = "Alliance" },
    ["farbank-faerlina"]   = { name = "Farbank",  realm = "faerlina",  faction = "Alliance" },
} })
F.RunPass()
local sawPeer = false
for _, n in ipairs(ADDED) do if n == "Peerbank" then sawPeer = true end end
ck(sawPeer, "(k) a peer account's recipient is friended here")
for _, n in ipairs(ADDED) do
    if n == "Farbank" then fail("(k) an other-realm peer recipient must never be added") end
end
ok("(k) an other-realm peer recipient is skipped")
ck(db.friendDir["peerbank-whitemane"] == nil,
   "(k) a peer's entry is never written into OUR saved directory")

-- (l) a peer payload from a newer build is refused rather than guessed at.
chatClear()
_G.__TESTNAME = "Reader2"
local beforeRemote = F.remote["account-c"]
ns.SyncBridge.OnRemote("account-c", { v = 99, recipients = {
    ["future-whitemane"] = { name = "Future", realm = "whitemane", faction = "Alliance" } } })
ck(F.remote["account-c"] == beforeRemote, "(l) a newer payload version is dropped")
ck(tostring(ns.SyncBridge._lastReject):find("newer") ~= nil, "(l) ...with a readable reason recorded")

realprint("=== GATE FRIEND: " .. (FAILS == 0 and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE MUT: MUTATION-TEST THE BOON PLAN BUILDER
--
-- The plan builder decides who receives ten scarce consumables and who receives
-- none, off a snapshot that is always a little out of date. "The suite is green"
-- is not evidence that the suite would NOTICE a broken builder, so this gate
-- proves it: each mutant below is boons.lua with one operator flipped, and every
-- one of them MUST be killed by the checks. A surviving mutant means a rule the
-- tests only appear to cover, and it fails the build.
--
-- The checks below deliberately duplicate the shipped suite's core assertions
-- rather than calling into it: the shipped suite prints through ns:Print and
-- reports pass/fail counts, whereas a mutation gate needs one boolean per mutant.
----------------------------------------------------------------------
realprint("=== GATE MUT: mutation-test the boon plan builder ===")
do
    local ITEM = 184937
    local function ch(name, level, have, extra)
        local e = { name = name, level = level }
        if have ~= nil then e.counts = { [ITEM] = have } end
        for k, v in pairs(extra or {}) do e[k] = v end
        return e
    end
    -- The load-bearing behaviour, as one boolean. Any error counts as a kill.
    local function planChecks(B)
        local function run()
            local function P(entries, over)
                local o = { source = "Bankalt", faction = "Alliance", stock = 999, itemID = ITEM }
                for k, v in pairs(over or {}) do o[k] = v end
                return B.BuildPlan(entries, o)
            end
            local function at(p, i) return p.targets[i] end
            local function order(p)
                local out = {}
                for _, x in ipairs(p.targets) do out[#out + 1] = x.name .. ":" .. x.send end
                return table.concat(out, ",")
            end

            -- the owner's example, verbatim
            local mesh = { ch("Poonyx", 60, 3), ch("Shalk", 60, 9), ch("Orn", 60, 0) }
            local p = P(mesh)
            if #p.targets ~= 3 then return false end
            if order(p) ~= "Orn:10,Poonyx:7,Shalk:1" then return false end
            if p.totalNeed ~= 18 or p.totalSend ~= 18 or p.shortfall ~= 0 then return false end

            -- rationing under a shortfall
            local s = P(mesh, { stock = 12 })
            if order(s) ~= "Orn:10,Poonyx:2,Shalk:0" then return false end
            if s.totalSend ~= 12 or s.shortfall ~= 6 or s.remaining ~= 0 then return false end

            -- filters
            -- Zerolevel is here on purpose: Nexus writes level 0 for "never
            -- captured", so 0 must land in unknownLevel and NOT in under-level.
            local f = P({ ch("Bankalt", 60, 0), ch("Lowbie", 30, 0), ch("Nolevel", nil, 0),
                          ch("Zerolevel", 0, 0),
                          ch("Hordie", 60, 0, { faction = "Horde" }), ch("Keep", 60, 0),
                          ch("Stocked", 60, 10) })
            if #f.targets ~= 1 or at(f, 1).name ~= "Keep" then return false end
            if f.counts.source ~= 1 or f.counts.level ~= 1 or f.counts.unknownLevel ~= 2
               or f.counts.faction ~= 1 or f.counts.stocked ~= 1 then return false end

            -- an absent count is a full ten
            local g = P({ ch("Ghost", 60, nil) })
            if #g.targets ~= 1 or at(g, 1).send ~= 10 or at(g, 1).have ~= 0 then return false end

            -- equal needs are ordered by name
            if order(P({ ch("zeta", 60, 4), ch("Alpha", 60, 4) })) ~= "Alpha:6,zeta:6" then return false end

            -- IN-FLIGHT IS OWNED. A top-up already in the post counts against the
            -- need, so a re-run cannot post it twice; and the row that is still
            -- short says how much is on its way.
            local tr = B.BuildPlan({ ch("Erro", 60, 9) },
                { source = "S", stock = 99, itemID = ITEM, inFlight = { erro = 1 } })
            if #tr.targets ~= 0 or tr.counts.stocked ~= 1 then return false end
            if not tostring(tr.skipped[1].reason):find("in transit", 1, true) then return false end
            local tr2 = B.BuildPlan({ ch("Erro", 60, 4) },
                { source = "S", stock = 99, itemID = ITEM, inFlight = { erro = 2 } })
            if #tr2.targets ~= 1 or at(tr2, 1).send ~= 4 or at(tr2, 1).inTransit ~= 2 then return false end

            -- ages
            if B.FormatAge(89) ~= "just now" or B.FormatAge(90) ~= "1m" then return false end
            if B.FormatAge(3600) ~= "1h" or B.FormatAge(172800) ~= "2d" then return false end
            local NOW = 1700000000
            local a = B.BuildPlan({ ch("Aged", 60, 1, { countsAt = NOW - 7200 }) },
                                  { source = "S", stock = 99, itemID = ITEM, now = NOW })
            if at(a, 1).ageText ~= "2h" then return false end
            return true
        end
        local okRun, res = pcall(run)
        return okRun and res == true
    end

    local SRC = readFile(P("boons.lua"))
    ck(SRC ~= nil, "boons.lua is readable")

    -- Sanity: the REAL builder must pass the very checks the mutants must fail.
    ck(planChecks(ns.Boons), "the shipped plan builder passes the mutation checks")

    -- name, exact source fragment, replacement. Each fragment must appear ONCE.
    local MUTANTS = {
        { "source filter inverted",      "if lower == srcName then",
                                         "if lower ~= srcName then" },
        { "faction filter inverted",     "side ~= srcSide then",
                                         "side == srcSide then" },
        { "unknown level admitted",      "elseif not lvl or lvl <= 0 then",
                                         "elseif not lvl or lvl < 0 then" },
        { "level boundary off by one",   "elseif lvl < minLevel then",
                                         "elseif lvl <= minLevel then" },
        { "need arithmetic flipped",     "local need    = target - owned",
                                         "local need    = target + owned" },
        -- In-flight is OWNED (ledger.lua): a top-up already in the post must count
        -- against the need, or a re-run after an interruption mails it all again.
        { "in-flight ignored",           "local owned   = have + transit",
                                         "local owned   = have + 0" },
        { "stocked boundary off by one", "if need <= 0 then",
                                         "if need < 0 then" },
        { "rationing order reversed",    "if a.need ~= b.need then return a.need > b.need end",
                                         "if a.need ~= b.need then return a.need < b.need end" },
        { "name tiebreak reversed",      "if la ~= lb then return la < lb end\n        return a.name < b.name",
                                         "if la ~= lb then return la > lb end\n        return a.name < b.name" },
        { "stock clamp removed",         "if give > remaining then give = remaining end",
                                         "if give > remaining then give = give end" },
        { "stock never consumed",        "remaining = remaining - give",
                                         "remaining = remaining - 0" },
        { "shortfall sign flipped",      "plan.shortfall  = plan.totalNeed - plan.totalSend",
                                         "plan.shortfall  = plan.totalSend - plan.totalNeed" },
        { "age threshold moved",         'if n < 90 then return "just now" end',
                                         'if n < 900 then return "just now" end' },
    }

    local survivors = 0
    for _, m in ipairs(MUTANTS) do
        local name, from, to = m[1], m[2], m[3]
        local head, tail = SRC:find(from, 1, true)
        if not head then
            fail("MUTANT '" .. name .. "': its source fragment no longer exists (stale mutation)")
        elseif SRC:find(from, tail + 1, true) then
            fail("MUTANT '" .. name .. "': fragment is not unique (the mutation is ambiguous)")
        else
            local mutated = SRC:sub(1, head - 1) .. to .. SRC:sub(tail + 1)
            local chunk, cerr = loadstring(mutated, "@mutant:" .. name)
            if not chunk then
                ok("MUTANT killed at compile: " .. name .. " (" .. tostring(cerr) .. ")")
            else
                local mutNs = { Network = ns.Network }
                local loaded = pcall(chunk, ADDON_NAME, mutNs)
                if not loaded or type(mutNs.Boons) ~= "table" then
                    ok("MUTANT killed at load: " .. name)
                elseif planChecks(mutNs.Boons) then
                    survivors = survivors + 1
                    fail("MUTANT SURVIVED: " .. name .. " — the checks do not cover this rule")
                else
                    ok("MUTANT killed: " .. name)
                end
            end
        end
    end
    ck(survivors == 0, "every mutant of the plan builder is killed")
end
realprint("=== GATE MUT: " .. (FAILS == 0 and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE HDR: the panel header's control cluster (gear + close).
--
-- Owner request: "can we add a settings icon next to the 'x' in conduit? update
-- the icons for both to match the suite". That is an APPEARANCE change, which a
-- headless harness cannot see — and panel.lua is deliberately never LOADED here
-- (it builds DaseekiUI frames; GATE 0 only proves it compiles). So this gate pins
-- the things that make the appearance true and that a later edit could silently
-- undo:
--
--   (a) THE ART IS OURS AND UNMODIFIED. icon-close/icon-gear are byte copies of
--       Daseeki-Nexus/textures — the same bytes Raid Prep and Bags 2.0 ship, which
--       is the whole point: the gear and the close mark are pixel-identical across
--       the suite. The digests below are the ones Raid Prep pins, independently
--       recomputed here. (A Nexus checkout is not reachable from a git worktree, so
--       the ORIGINAL cannot be diffed at test time — the digest is the portable
--       form of that diff.) Nothing is authored for this window: no glyph in the
--       cluster is new, so unlike Raid Prep's gavel there is no dev/ generator.
--
--   (b) THE HEADER USES THE GLYPH PATTERN, at the suite's metrics, with the tint
--       contract; and stock/text art survives ONLY as the no-Core fallback.
--
--   (c) THE GEAR IS THE SAME DOOR AS THE SLASH COMMAND — one ns:OpenSettings in
--       core.lua, called by both, so the hub target cannot drift between them.
----------------------------------------------------------------------
local HDR_BEFORE = FAILS
realprint("=== GATE HDR: header control cluster ===")
do
    local function readBinary(path)
        local fh = io.open(path, "rb"); if not fh then return nil end
        local s = fh:read("*a"); fh:close(); return s
    end

    -- djb2 over the whole file, kept in double-exact range (hash*33 + b < 2^53).
    local function digest(s)
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
        return h
    end

    -- 64x64 32bpp uncompressed true-colour, top-left origin => 18 + 64*64*4 bytes.
    -- The runtime tints the white mask with a theme token, so a paletted or 24bpp
    -- re-export would render wrong rather than merely different.
    local TGA_BYTES = 16402
    local GLYPHS = {
        { "icon-close.tga", 1198911579 },
        { "icon-gear.tga",  1303632799 },
    }
    for _, g in ipairs(GLYPHS) do
        local name, want = g[1], g[2]
        local raw = readBinary(P("art/" .. name))
        ck(raw ~= nil, "(a) art/" .. name .. " ships (copied from Daseeki-Nexus/textures)")
        if raw then
            ck(#raw == TGA_BYTES, "(a) " .. name .. " is a 64x64 32bpp TGA (" .. #raw .. " bytes)")
            ck(raw:byte(3) == 2 and raw:byte(17) == 32 and raw:byte(18) == 0x28,
               "(a) " .. name .. " header: uncompressed true-colour, 32bpp, top-left origin")
            ck(digest(raw) == want, "(a) " .. name .. " is byte-identical to the suite glyph")
        end
    end

    local src = readFile(P("panel.lua")) or ""

    -- The metrics ARE the parity: 22/2/8 is the Nexus dashboard button verbatim.
    ck(src:find("local ICONBTN    = 22", 1, true) ~= nil, "(b) 22px control button (suite parity)")
    ck(src:find("local ICON_INSET = 2", 1, true)  ~= nil, "(b) 2px glyph inset => 18x18 drawn")
    ck(src:find("local ICON_SPACE = 8", 1, true)  ~= nil, "(b) 8px gap between controls")
    ck(src:find('"Interface\\\\AddOns\\\\" .. tostring(ADDON) .. "\\\\art\\\\"', 1, true) ~= nil,
       "(b) art is loaded from the addon's OWN art/ directory")

    -- The pattern itself, and the tint contract it carries.
    ck(src:find("local function makeGlyphButton", 1, true) ~= nil, "(b) the glyph-button factory exists")
    ck(src:find("UI.FLAT_BACKDROP", 1, true) ~= nil,        "(b) the button is the suite FLAT_BACKDROP object")
    ck(src:find('UI.Color("borderLite")', 1, true) ~= nil,  "(b) borderLite edge, as Nexus/Bags/Raid Prep")
    ck(src:find('self._hot and hot or "muted"', 1, true) ~= nil,
       "(b) the GLYPH carries the hover: muted at rest, hot on enter")
    ck(src:find('hot = "danger"', 1, true) ~= nil, "(b) the close hovers danger (destructive affordance)")

    -- Both controls are built through the factory, on our own glyphs, and BOTH are
    -- the same size — the owner asked for icons that match each other, not merely
    -- icons that exist.
    for _, icon in ipairs({ "icon-close", "icon-gear" }) do
        ck(src:find('icon = "' .. icon .. '"', 1, true) ~= nil, "(b) the cluster draws " .. icon)
    end
    ck(src:find("b:SetSize(ICONBTN, ICONBTN)", 1, true) ~= nil,
       "(b) every control in the cluster is the SAME square (matching sizes)")

    -- The older-Core install must still get a working header, and stock/text art
    -- must live BELOW that marker — one drifting up into the themed path is the
    -- regression this round removes.
    ck(src:find("local function glyphCapable", 1, true) ~= nil,
       "(b) the themed path is guarded (an older Core has no FLAT_BACKDROP)")
    local markAt = src:find("NO-CORE FALLBACK", 1, true)
    ck(markAt ~= nil, "(b) the fallback branch is declared")
    if markAt then
        for _, stock in ipairs({ "Interface/Icons/", "Interface/Buttons/", 'cx:SetText("X")' }) do
            local at, bad = 0, false
            while true do
                at = src:find(stock, at + 1, true)
                if not at then break end
                if at < markAt then bad = true end
            end
            ck(not bad, "(b) stock/text art '" .. stock .. "' survives only below NO-CORE FALLBACK")
        end
    end

    -- (c) one door to the hub.
    local core = readFile(P("core.lua")) or ""
    ck(core:find("function ns:OpenSettings", 1, true) ~= nil,
       "(c) core.lua owns the single settings action")
    ck(core:find('DaseekiSuite:Open("conduit")', 1, true) ~= nil,
       "(c) ...which opens the hub's Conduit section")
    ck(src:find("ns:OpenSettings()", 1, true) ~= nil, "(c) the gear calls it")
    ck(src:find("DaseekiSuite", 1, true) == nil,
       "(c) the panel never re-derives the hub target itself")

    -- The refresh wiring this round adds, pinned where the harness can see it:
    -- panel.lua is not loaded, so its REGISTRATION is asserted textually while the
    -- guard and fan-out it depends on are driven for real in the mailbox-close suite.
    ck(src:find("ns:RegisterMailboxRefresher(", 1, true) ~= nil,
       "(d) the panel refreshes when the mail window actually becomes visible")
    ck(src:find('f:SetScript("OnShow"', 1, true) ~= nil,
       "(d) ...and whenever the panel itself is shown")
    ck(core:find('{ "OnShow", function()', 1, true) ~= nil,
       "(d) core.lua hooks MailFrame's OnShow, not just its OnHide")
    ck(core:find("ns.HookOnce(mailFrameHook, _G.MailFrame", 1, true) ~= nil,
       "(d) ...through the install-once guard (never hooked twice)")
end
local V_HDR = (FAILS == HDR_BEFORE)
realprint("=== GATE HDR: " .. (V_HDR and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- THE LIVE SEND ENGINE, DRIVEN HEADLESS
--
-- mail.lua was the one shipped file this harness could not touch: it is nothing
-- but live API, so every gate above could only assert things ABOUT it from its
-- source text. That is precisely where the over-attach lived. harness/mailsim.lua
-- now stands the mailbox up in plain Lua — bags, cursor, split/pickup, twelve
-- attachment slots that report their stack counts, a SendMail that answers on a
-- virtual clock — and the REAL engine drives it.
----------------------------------------------------------------------
local Sim = assert(loadfile(HARNESS_DIR .. "/mailsim.lua"))()
local ITEM = 184937

local ENGINE_FILES = { "rules.lua", "migrate.lua", "network.lua", "ledger.lua",
                       "boons.lua", "mail.lua" }

-- Load a FRESH addon namespace against `sim`, optionally with a patched mail.lua
-- (used to reconstruct the pre-fix engine for the red half of GATE ATTACH).
local function newEngine(sim, mailSrc)
    _G.DaseekiConduitDB = nil
    _G.__POPUP = nil
    sim:Install(_G)
    local n = {}
    assert(loadfile(P("core.lua")))(ADDON_NAME, n)
    n.RegisterEvent = function(_, ev, fn) sim:On(ev, fn) end
    for _, rel in ipairs(ENGINE_FILES) do
        local chunk
        if rel == "mail.lua" and mailSrc then
            chunk = assert(loadstring(mailSrc, "@patched-mail.lua"))
        else
            chunk = assert(loadfile(P(rel)))
        end
        chunk(ADDON_NAME, n)
    end
    n:InitDB()
    return n
end

-- A faithful mirror of boons.lua's Boons.Plan() + Boons.Run() wiring, with the
-- Nexus roster injected instead of scraped off _G (network.lua's own suite covers
-- the scrape). Everything else — the ledger sweep, the in-flight read, the plan,
-- the queue, the rebuild and the per-mail re-check — is the shipped code.
local function derive(n, entries)
    local stacks   = n.Boons.ScanStacks(ITEM)
    local now      = _G.time()
    n.Ledger.Sweep(n.Boons.MeshSnapshot(entries, ITEM), now)
    local inFlight = n.Ledger.InFlight(n.Ledger.Entries(), ITEM, now)
    local plan = n.Boons.BuildPlan(entries, {
        source = "Bankalt", faction = "Alliance",
        stock = n.Boons.CountStock(stacks, ITEM),
        target = 10, minLevel = 60, itemID = ITEM, inFlight = inFlight, now = now,
    })
    return n.Boons.BuildQueue(plan, stacks, { maxAttach = 12, subject = "Daseeki Conduit" }), plan
end

local function startRun(n, sim, entries, opts)
    opts = opts or {}
    local q = derive(n, entries)
    if #q == 0 then return 0 end
    local shown = n.Mail.RunQueue(q, "preview", {
        rebuild = (opts.noRebuild == nil) and function() return (derive(n, entries)) end or nil,
        check   = (opts.noCheck == nil) and function(mail)
            local _, p = derive(n, entries)
            for _, t in ipairs(p.targets) do
                if t.name:lower() == tostring(mail.recipient):lower() then
                    if t.need >= (tonumber(mail.units) or 0) then return true end
                    return false, ("only needs %d now"):format(t.need)
                end
            end
            return false, "already topped up (or on its way)"
        end or nil,
        onFinish = opts.onFinish,
    })
    if not shown then return 0 end
    sim:Accept(_G)
    return #q
end

local function bagsOf(stacks)
    local layout = { [0] = { size = 20 } }
    for i, c in ipairs(stacks) do layout[0][i] = { itemID = ITEM, count = c } end
    return layout
end

local function mesh(spec)
    local out = {}
    for _, row in ipairs(spec) do
        out[#out + 1] = { name = row[1], level = row[2] or 60,
                          counts = { [ITEM] = row[3] }, countsAt = row[4] or (_G.__CLOCK - 600) }
    end
    return out
end

----------------------------------------------------------------------
-- GATE ATTACH: THE OVER-ATTACH, REPRODUCED AND THEN KILLED TWICE OVER
--
-- The live report: a boon run reading "Sent 2/8" with the mail for Erro — planned
-- for SEVEN — sitting on the Send Mail form carrying TWO WHOLE STACKS OF TEN, and
-- 60 copper of postage confirming two attachments.
--
-- ROOT CAUSE, as reproduced below. The old attach decided how many units it
-- wanted, called split-or-pickup, checked only that the attachment slot had become
-- NON-EMPTY, and then asserted `units = units + want`. It never asked the form how
-- much had landed. And the same function contained an explicit `want = have` in the
-- branch taken whenever the split path was not used, which turns a PARTIAL draw
-- into a WHOLE-STACK pickup. A seven-unit top-up drawn across two slots therefore
-- put two whole stacks of ten on the form while the engine's own accounting still
-- read seven — so nothing downstream could notice, and SendMail fired on a form the
-- engine had never looked at.
--
-- THREE RUNS OF ONE FIXTURE:
--   RED    pre-fix attach + no guard          -> 20 units sent on a 7-unit plan
--   GREEN  shipped attach                     -> exactly 7, split across two slots
--   GREEN  pre-fix attach + the shipped guard -> refused, nothing sent
--
-- The fixture, and why it looks the way it does. Two full stacks of ten. Poonyx is
-- planned for NINE and drawn entirely from the first stack; Erro is planned for
-- SEVEN and therefore drawn across BOTH — one unit from what Poonyx left, six from
-- the second stack. Poonyx's mail then fails (a bad name, a full mailbox, a server
-- hiccup — the engine cannot tell them apart) and is skipped, so his nine never
-- leave the bags and BOTH of Erro's draw slots are still holding ten when his mail
-- is armed. That is the exact condition under which a partial draw that cannot be
-- split becomes a whole stack, and it is a completely ordinary thing to happen
-- part-way through a batch. `noSplit` on the simulator is the client condition; the
-- defect is that the engine had a whole-stack fallback for it at all.
----------------------------------------------------------------------
local ATTACH_BEFORE = FAILS
realprint("=== GATE ATTACH: the over-attach, reproduced then fixed ===")
do
    local MAIL_SRC = readFile(P("mail.lua"))
    ck(MAIL_SRC ~= nil, "mail.lua is readable")

    -- The pre-fix (1.2.0) engine, reconstructed from the shipped source by three
    -- edits: the whole-stack fallback when a partial draw will not split, the
    -- accounting that trusted the plan instead of the world, and the plan-time bag
    -- coordinates that 1.2.1 now re-derives.
    local LEGACY = {
        { [[    D.splitFailed = D.splitFailed + 1
    return "nothing"
end]],
          [[    D.splitFailed = D.splitFailed + 1
    if C and C.PickupContainerItem then
        C.PickupContainerItem(bag, slot)
        if CursorHasItem() then return "delivered" end
    end
    return "nothing"
end]] },
        { [[                        if slotAttached(nextSlot) and landed == want then
                            attached = nextSlot
                            units    = units + landed]],
          [[                        if slotAttached(nextSlot) then
                            attached = nextSlot
                            units    = units + want]] },
        { "            if mail.itemID and tonumber(mail.units) and Rules.ScanStacksForItem then",
          "            if false then" },
    }
    local NO_GUARD = { { "local okAttach, whyAttach = verifyAttach(mail)",
                         "local okAttach, whyAttach = true, nil" } }

    local function patch(src, edits)
        for _, e in ipairs(edits) do
            local head, tail = src:find(e[1], 1, true)
            if not head then return nil, "fragment missing: " .. e[1]:sub(1, 60) end
            if src:find(e[1], tail + 1, true) then return nil, "fragment not unique" end
            src = src:sub(1, head - 1) .. e[2] .. src:sub(tail + 1)
        end
        return src
    end

    local function bothEdits(src, a, b)
        local s, err = patch(src, a); if not s then return nil, err end
        return patch(s, b)
    end

    -- THE FIXTURE. Two stacks of ten. Poonyx needs 6 (already served by the run
    -- this one resumes, so the per-mail re-check skips it and leaves its slot
    -- untouched); Erro needs 7, drawn 4 from the first slot and 3 from the second.
    local ROSTER = { { "Poonyx", 60, 1 }, { "Erro", 60, 3 } }
    local function poonyxFails(_, rec) return rec.recipient == "Poonyx" and "fail" or "ok" end

    local function runFixture(mailSrc, opts)
        opts = opts or {}
        local sim = Sim.New(bagsOf({ 10, 10 }),
            { behaviour = poonyxFails, poison = opts.poison, noSplit = opts.noSplit })
        local n = newEngine(sim, mailSrc)
        chatClear()
        startRun(n, sim, mesh(ROSTER))
        sim:Advance(300)
        local erro
        for _, m in ipairs(sim.sent) do if m.recipient == "Erro" then erro = m end end
        return sim, n, erro
    end

    -- The fixture must actually produce the shape the report describes.
    do
        local sim = Sim.New(bagsOf({ 10, 10 }))
        local n = newEngine(sim, nil)
        local q = derive(n, mesh(ROSTER))
        local erro
        for _, m in ipairs(q) do if m.recipient == "Erro" then erro = m end end
        ck(erro ~= nil, "(fixture) the queue contains Erro's mail")
        ck(erro and erro.units == 7, "(fixture) ...planned for 7 units, as the owner saw")
        ck(erro and #erro.stacks == 2, "(fixture) ...drawn across TWO bag slots")
    end

    -- RED: the pre-fix attach with no guard puts 20 on the form and sends it.
    do
        local src, err = bothEdits(MAIL_SRC, LEGACY, NO_GUARD)
        ck(src ~= nil, "(red) the pre-fix engine can be reconstructed" .. (src and "" or (" — " .. tostring(err))))
        if src then
            local sim, _, erroSend = runFixture(src, { noSplit = true })
            ck(erroSend ~= nil, "(red) the pre-fix engine sent Erro's mail")
            ck(erroSend and erroSend.units == 20,
               "(red) ...carrying 20 units — the live defect, reproduced ("
               .. tostring(erroSend and erroSend.desc) .. ")")
            ck(erroSend and erroSend.attachments == 2,
               "(red) ...in TWO attachments (60c of postage, as the owner counted)")
        end
    end

    -- GREEN A: the shipped attach, on a client whose split works, sends exactly 7.
    do
        local sim, n, erroSend = runFixture(nil)
        ck(erroSend ~= nil, "(green) the shipped engine sends Erro's mail")
        ck(erroSend and erroSend.units == 7,
           "(green) ...carrying exactly 7 — the plan, not the stacks (" .. tostring(erroSend and erroSend.desc) .. ")")
        -- 1.2.1 re-derives the draws from a fresh scan at arm time, and DrawExact
        -- takes the largest bite each slot can give — so the seven now come out of
        -- one stack in ONE attachment instead of two. Fewer attachments is also
        -- less postage; the number that matters is still the seven.
        ck(erroSend and erroSend.attachments == 1,
           "(green) ...in a single attachment, drawn fresh rather than from stale coordinates")
        ck(sim:BagUnits(ITEM) == 13, "(green) 13 boons left in the bags (20 - 7)")
        ck(chatFind("skipping Poonyx") ~= nil, "(green) the failing recipient is skipped, not sent to")
    end

    -- GREEN B: even with the pre-fix ATTACH restored, the guard alone refuses.
    -- This is the defence-in-depth requirement: a poisoned attach never sends.
    do
        local src = patch(MAIL_SRC, LEGACY)
        ck(src ~= nil, "(guard) the pre-fix attach can be restored on its own")
        if src then
            local sim = runFixture(src, { noSplit = true })
            local overSent = false
            for _, m in ipairs(sim.sent) do if m.units > 7 then overSent = true end end
            ck(not overSent, "(guard) a poisoned attach is REFUSED — nothing over-planned is sent")
            ck(chatFind("not sending it") ~= nil, "(guard) ...and says so in plain language")
            ck(chatFind("holding 20") ~= nil,
               "(guard) ...naming what the form really had (the FORM total caught it, "
               .. "because the pre-fix accounting still claimed seven)")
            ck(sim:BagUnits(ITEM) == 20, "(guard) every boon is still in the bags")
        end
    end

    -- And the same guard against a client that hands back MORE than was asked for.
    do
        local sim = runFixture(nil, { poison = function(_, _, n) return n + 2 end })
        local over = false
        for _, m in ipairs(sim.sent) do if m.units > 7 then over = true end end
        ck(not over, "(guard) a split that over-delivers is refused too, not sent")
    end
end
local V_ATTACH = (FAILS == ATTACH_BEFORE)
realprint("=== GATE ATTACH: " .. (V_ATTACH and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE RUN: the hands-free runner's state machine, driven for real.
----------------------------------------------------------------------
local RUN_BEFORE = FAILS
realprint("=== GATE RUN: hands-free runner state machine ===")
do
    local FULL = mesh({ { "Aaa", 60, 0 }, { "Bbb", 60, 2 }, { "Ccc", 60, 5 } })

    -- (a) HAPPY PATH: one Accept, three mails, no further interaction.
    do
        local sim = Sim.New(bagsOf({ 10, 10, 10 }))
        local n = newEngine(sim, nil)
        chatClear()
        local queued = startRun(n, sim, FULL)
        ck(queued == 3, "(a) three mails queued from one preview")
        ck(n.Mail.IsActive(), "(a) the run starts on Accept alone")
        sim:Advance(120)
        ck(#sim.sent == 3, "(a) all three sent with no further clicks")
        ck(not n.Mail.IsActive(), "(a) the run finished and cleared itself")
        ck(#(sim.violations or {}) == 0, "(a) never two mails in flight at once")
        ck(sim.sent[1].units == 10 and sim.sent[2].units == 8 and sim.sent[3].units == 5,
           "(a) each mail carried exactly what the plan asked for")
        ck(chatFind("done — sent 3 mail(s)") ~= nil, "(a) one completion line")
    end

    -- (b) THE ACK NEVER COMES. The latch must CLEAR and the run stop with a report
    --     — the failure mode the behavioural spec flags as latch-until-reload.
    do
        local sim = Sim.New(bagsOf({ 10, 10, 10 }), {
            behaviour = function(i) return (i == 2) and "noack" or "ok" end })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, FULL)
        sim:Advance(5)
        ck(n.Mail.IsInFlight(), "(b) the second mail is in flight and unanswered")
        sim:Advance(20)
        ck(not n.Mail.IsInFlight(), "(b) after the 15s ceiling the in-flight latch is CLEAR")
        ck(not n.Mail.IsActive(), "(b) ...and the run has stopped rather than hanging")
        ck(chatFind("no answer from the server within 15s") ~= nil, "(b) with a report naming the bound")
        ck(#sim.sent == 2, "(b) nothing further was sent")
        ck(sim:LiveTickers() == 0, "(b) the Send-button ticker was released")
    end

    -- (c) THE ACK COMES BUT NOTHING MOVES. Second ceiling, same discipline.
    do
        local sim = Sim.New(bagsOf({ 10, 10, 10 }), {
            behaviour = function(i) return (i == 1) and "noevidence" or "ok" end })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, FULL)
        sim:Advance(5)
        ck(n.Mail.IsInFlight(), "(c) acknowledged, still waiting on the evidence")
        sim:Advance(20)
        ck(not n.Mail.IsInFlight(), "(c) the evidence ceiling clears the latch")
        ck(not n.Mail.IsActive(), "(c) ...and stops the run")
        ck(chatFind("nothing left your bags or purse within 15s") ~= nil,
           "(c) ...with a report a user can act on")
    end

    -- (d) RETRY THEN SKIP. One retry per mail, counted ONCE, then the recipient is
    --     skipped and the run CONTINUES — it does not abort the rest over one name.
    do
        local fails = 0
        local sim = Sim.New(bagsOf({ 10, 10, 10 }), {
            behaviour = function(i, rec)
                if rec.recipient == "Bbb" then fails = fails + 1; return "fail" end
                return "ok"
            end })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, FULL)
        sim:Advance(120)
        ck(fails == 2, "(d) the failing recipient was attempted exactly twice (one retry)")
        ck(chatFind("retrying Bbb once") ~= nil, "(d) ...and the retry is announced once")
        ck(chatFind("skipping Bbb") ~= nil, "(d) ...then skipped by name")
        local sentTo = {}
        for _, m in ipairs(sim.sent) do sentTo[m.recipient] = (sentTo[m.recipient] or 0) + 1 end
        ck(sentTo["Ccc"] == 1, "(d) the run CONTINUED to the recipient after the failure")
        ck(not n.Mail.IsActive(), "(d) and finished cleanly")
    end

    -- (e) MAILBOX CLOSED MID-RUN is a hard abort that actually returns.
    do
        local sim = Sim.New(bagsOf({ 10, 10, 10 }), { latency = 3 })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, FULL)
        sim:Advance(1)
        ck(n.Mail.IsActive(), "(e) the run is still going when the mailbox goes")
        local sentSoFar = #sim.sent
        sim:CloseMailbox(n)
        ck(not n.Mail.IsActive(), "(e) closing the mailbox stops the run at once")
        ck(not n.Mail.IsInFlight(), "(e) ...and clears the in-flight latch")
        ck(sim:LiveTickers() == 0, "(e) ...and releases the Send-button ticker")
        sim:Advance(120)
        ck(#sim.sent == sentSoFar, "(e) not one further mail is sent into a closed mailbox")
        ck(chatFind("mailbox closed") ~= nil, "(e) ...and it says so")
    end

    -- (f) THE SEND BUTTON. Blizzard re-enables its own; the 0.2s ticker must put it
    --     back for the life of the send, and be gone at the terminal state.
    do
        local sim = Sim.New(bagsOf({ 10 }), { latency = 2 })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, mesh({ { "Aaa", 60, 0 } }))
        sim:Advance(0.01)
        ck(sim.buttonEnabled == false, "(f) Blizzard's Send button is disabled for the send")
        ck(sim:LiveTickers() == 1, "(f) ...held down by exactly one repeating ticker")
        sim:Advance(0.06)             -- Blizzard re-enables it under us at 0.05s
        sim:Advance(0.25)             -- ...and the ticker takes it back
        ck(sim.buttonEnabled == false, "(f) a mid-send re-enable is re-asserted away")
        sim:Advance(120)
        ck(sim:LiveTickers() == 0, "(f) the ticker is cancelled at the terminal state")
        ck(sim.buttonEnabled == true, "(f) ...and the button is handed back")
        ck(sim:LiveTimers() == 0, "(f) no timer of any kind outlives the run")
    end

    -- (g) STEP MODE still works, and is not the default.
    do
        local sim = Sim.New(bagsOf({ 10, 10, 10 }))
        local n = newEngine(sim, nil)
        ck(n.Mail.StepMode() == false, "(g) hands-free is the default")
        n.Mail.SetStepMode(true)
        chatClear()
        startRun(n, sim, FULL)
        sim:Advance(120)
        ck(#sim.sent == 0, "(g) step mode sends nothing until you click")
        ck(n.Mail.IsAwaitingClick(), "(g) ...and says it is waiting")
        n.Mail.ContinueClick(); sim:Advance(5)
        ck(#sim.sent == 1, "(g) one click, one mail")
        n.Mail.ContinueClick(); sim:Advance(5)
        n.Mail.ContinueClick(); sim:Advance(5)
        ck(#sim.sent == 3, "(g) ...and the queue completes a click at a time")
        n.Mail.SetStepMode(false)
    end

    -- (i) A DEFERRED HOP BELONGS TO ITS RUN. The 0.5s failure spacing means an
    --     arm can be scheduled for a run that stops before it fires; if the next run
    --     inherited it, it would arm a mail out of the wrong queue.
    do
        local sim = Sim.New(bagsOf({ 10, 10, 10 }), {
            behaviour = function(_, rec) return rec.recipient == "Aaa" and "fail" or "ok" end })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, FULL)
        sim:Advance(0.4)                 -- MAIL_FAILED is in; the retry is pending
        ck(n.Mail.IsActive(), "(i) the run is alive with a retry scheduled")
        sim:CloseMailbox(n)
        ck(not n.Mail.IsActive(), "(i) ...and the mailbox closing kills it")
        sim.mailboxOpen = true
        chatClear()
        local queued = startRun(n, sim, FULL)
        sim:Advance(120)
        ck(queued == 3, "(i) a second run plans normally")
        ck(#(sim.violations or {}) == 0, "(i) ...and the stale hop never touches it")
        ck(not n.Mail.IsActive(), "(i) ...which then finishes cleanly")
    end

    -- (h) STOP means no further mails.
    do
        local sim = Sim.New(bagsOf({ 10, 10, 10 }), { latency = 2 })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, FULL)
        sim:Advance(0.01)
        n.Mail.Stop()
        sim:Advance(120)
        ck(#sim.sent == 1, "(h) Stop lets the mail already sent finish and sends no more")
        ck(not n.Mail.IsActive(), "(h) ...and the run ends")
    end
end
local V_RUN = (FAILS == RUN_BEFORE)
realprint("=== GATE RUN: " .. (V_RUN and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE SETTLE: THE LIVE FIELD FAILURE — an attach racing the client's bags.
--
-- Reported in-game at 12:04:38-39 (sub-second succession), hands-free boon run:
--   "Daseeki's mail should carry 3 Chronoboon Displacer but the form holds 0"
--   "skipping Daseeki — what would attach did not match the plan"
--   ...the same for Senche (3) and Zaan (2).
--
-- The send guard did its job — nothing was over-mailed and every boon stayed in
-- the bags — but the attach placed NOTHING on the form for every mail in the tail.
--
-- MECHANISM. Hands-free arms mail N+1 the instant mail N reaches its terminal
-- state. The client has not finished settling the bags at that point: the slots
-- involved are still LOCKED, and a locked slot makes C_Container.SplitContainerItem
-- a silent no-op — no error, no cursor, nothing. So the draw yields zero, the form
-- stays empty, and the guard refuses a mail that would have carried nothing. The
-- 1.2.0 retry then re-ran 0.5s later WITHOUT waiting for anything, hit the same
-- locked slots, and produced the identical refusal inside the same second, which is
-- exactly the shape of the owner's log.
--
-- Worth recording: the 1.2.0 theory that C_Container.SplitContainerItem might be
-- MISSING on 11509 is dead. The API catalog for build 1.15.9.68808 lists
-- C_Container.SplitContainerItem(containerIndex, slotIndex, amount) as present —
-- and lists no bare SplitContainerItem global at all. The function is there; it was
-- being called at a moment when it refuses.
--
-- The fixture below is the owner's tail verbatim: three mails of 3, 3 and 2 units,
-- behind one that succeeds (the send that puts the bags in motion).
----------------------------------------------------------------------
local SETTLE_BEFORE = FAILS
realprint("=== GATE SETTLE: the live attach-vs-bag-settlement race ===")
do
    local MAIL_SRC = readFile(P("mail.lua"))

    local function patch1(src, edits)
        for _, e in ipairs(edits) do
            local head, tail = src:find(e[1], 1, true)
            if not head then return nil, "fragment missing" end
            src = src:sub(1, head - 1) .. e[2] .. src:sub(tail + 1)
        end
        return src
    end

    -- The 1.2.0 arming: no settlement wait anywhere, and a retry that re-runs on a
    -- bare timer. Everything else (including the guard) stays exactly as shipped —
    -- which is the point: the guard was never the problem.
    local NO_SETTLE = {
        { "    awaitSettlement(armCurrent)\nend", "    armCurrent()\nend" },
        { [[                    newTimer(FAILURE_SPACING, thisRun(function()
                        awaitSettlement(armCurrent)
                    end))]],
          [[                    newTimer(FAILURE_SPACING, thisRun(armCurrent))]] },
    }

    -- Daseeki 3, Senche 3, Zaan 2 — behind Aaa, whose successful send is what sets
    -- the bags moving. One stack of ten and one of five covers 5+3+3+2 = 13.
    local TAIL = mesh({ { "Aaa", 60, 5 }, { "Daseeki", 60, 7 },
                        { "Senche", 60, 7 }, { "Zaan", 60, 8 } })

    local function liveRun(mailSrc, opts)
        opts = opts or {}
        local sim = Sim.New(bagsOf({ 10, 5 }), {
            asyncBags = true,
            settleDelay = opts.settleDelay or 0.6,   -- > the 0.5s failure spacing
            splitAsync = opts.splitAsync,
        })
        local n = newEngine(sim, mailSrc)
        chatClear()
        startRun(n, sim, TAIL)
        sim:Advance(300)
        local by = {}
        for _, m in ipairs(sim.sent) do by[m.recipient] = (by[m.recipient] or 0) + m.units end
        return sim, n, by
    end

    -- RED: the 1.2.0 arming, against a client whose bags settle asynchronously.
    do
        local src, err = patch1(MAIL_SRC, NO_SETTLE)
        ck(src ~= nil, "(red) the 1.2.0 arming can be reconstructed" .. (src and "" or (" — " .. tostring(err))))
        if src then
            local sim, n, by = liveRun(src)
            ck(by["Aaa"] == 5, "(red) the first mail goes out fine — the bags were still")
            ck(by["Daseeki"] == nil,
               "(red) ...and the very next one attaches NOTHING, exactly as reported")
            local lost = 0
            for _, who in ipairs({ "Daseeki", "Senche", "Zaan" }) do
                if by[who] == nil then lost = lost + 1 end
            end
            ck(lost >= 2, "(red) most of the tail is lost to the race (" .. lost .. " of 3)")
            ck(chatFind("but the form holds 0") ~= nil,
               "(red) ...refused with the owner's exact line")
            ck(chatFind("skipping Daseeki") ~= nil, "(red) ...and the recipient skipped by name")
            -- The guard is not on trial here; it did its job in the field and it
            -- does it here. Nothing over-sent, nothing lost: what did not go is
            -- still in the bags.
            local sent = 0
            for _, m in ipairs(sim.sent) do sent = sent + m.units end
            ck(sim:BagUnits(ITEM) + sent == 15,
               "(red) the guard held: every boon is either sent-as-planned or still in the bags")
        end
    end

    -- GREEN: the shipped 1.2.1 arming waits for the bags to stop moving.
    do
        local sim, n, by = liveRun(nil)
        ck(by["Aaa"] == 5 and by["Daseeki"] == 3 and by["Senche"] == 3 and by["Zaan"] == 2,
           "(green) all four mails go out, each carrying exactly its plan")
        ck(#sim.sent == 4, "(green) four mails, no retries needed")
        ck(chatFind("form holds 0") == nil, "(green) not one refusal")
        ck(sim:BagUnits(ITEM) == 2, "(green) 2 boons left in the bags (15 - 13)")
        local d = n.Mail.Diagnostics()
        ck(d.settleWaits >= 3, "(green) the engine waited for settlement between mails")
        ck(d.settleTimeouts == 0, "(green) ...and every wait was resolved by the event, not the ceiling")
        ck(d.redrawn >= 4, "(green) every mail's draws were re-derived from a fresh scan")
        ck(d.lockedSlots == 0, "(green) ...so no draw was ever attempted against a locked slot")
    end

    -- The ceiling is a safety valve, not a failure mode: even when settlement takes
    -- LONGER than the 1s bound, the run still completes — the attach refuses once
    -- and the retry (which waits again) gets there.
    do
        local sim, n, by = liveRun(nil, { settleDelay = 1.4 })
        ck(by["Daseeki"] == 3 and by["Senche"] == 3 and by["Zaan"] == 2,
           "(ceiling) a slow-settling client still delivers every mail correctly")
        ck(n.Mail.Diagnostics().settleTimeouts > 0, "(ceiling) ...having hit the 1s bound")
        ck(sim:BagUnits(ITEM) == 2, "(ceiling) and nothing was sent twice to make up for it")
    end

    -- A split that takes from the slot but hands the stack over a frame later must
    -- never be asked a second time — that would draw a second helping.
    do
        local sim, n, by = liveRun(nil, { splitAsync = true })
        local over = false
        for _, m in ipairs(sim.sent) do
            local want = ({ Aaa = 5, Daseeki = 3, Senche = 3, Zaan = 2 })[m.recipient]
            if want and m.units > want then over = true end
        end
        ck(not over, "(async split) no mail carries more than its plan")
        ck(n.Mail.Diagnostics().splitAsync > 0,
           "(async split) ...and the engine recognised the take-but-not-hand-over case")
        ck(not n.Mail.IsActive(),
           "(async split) ...and the run ends rather than hanging on a client that never delivers")
        local inHand = sim.cursor and sim.cursor.count or 0
        ck(sim:BagUnits(ITEM) + inHand + (function()
               local t = 0; for _, m in ipairs(sim.sent) do t = t + m.units end; return t
           end)() == 15, "(async split) not one boon was drawn twice or lost")
    end

    -- STEP MODE hits the same race (a fast clicker is a fast clicker), so it waits
    -- too: the arm after a send must not be ready until the bags are.
    do
        local sim = Sim.New(bagsOf({ 10, 5 }), { asyncBags = true, settleDelay = 0.6 })
        local n = newEngine(sim, nil)
        n.Mail.SetStepMode(true)
        chatClear()
        startRun(n, sim, TAIL)
        n.Mail.ContinueClick(); sim:Advance(0.35)
        ck(#sim.sent == 1, "(step) the first mail went")
        ck(not n.Mail.IsAwaitingClick(),
           "(step) the next mail is NOT offered while the bags are still moving")
        sim:Advance(1.0)
        ck(n.Mail.IsAwaitingClick(), "(step) ...and is offered once they have settled")
        n.Mail.ContinueClick(); sim:Advance(1.5)
        n.Mail.ContinueClick(); sim:Advance(1.5)
        n.Mail.ContinueClick(); sim:Advance(1.5)
        local by = {}
        for _, m in ipairs(sim.sent) do by[m.recipient] = m.units end
        ck(by["Daseeki"] == 3 and by["Senche"] == 3 and by["Zaan"] == 2,
           "(step) every stepped mail carries exactly its plan")
        n.Mail.SetStepMode(false)
    end

    -- The form's return shape is undocumented in the 11509 catalog, so the engine
    -- calibrates which return carries the stack count instead of assuming one.
    do
        local sim = Sim.New(bagsOf({ 10, 5 }), { asyncBags = true })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, TAIL)
        sim:Advance(300)
        ck(n.Mail._FormCalibration() ~= nil,
           "(form) the engine worked out which GetSendMailItem return is the count")
        ck(n.Mail.Diagnostics().formBagDisagree == 0,
           "(form) ...and it agrees with the bag subtraction on every draw")
    end
end
local V_SETTLE = (FAILS == SETTLE_BEFORE)
realprint("=== GATE SETTLE: " .. (V_SETTLE and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE LEDGER: the outbound ledger, row by row, and the owner's scenario.
----------------------------------------------------------------------
local LEDGER_BEFORE = FAILS
realprint("=== GATE LEDGER: outbound ledger rules ===")
do
    local L = ns.Ledger
    ck(L ~= nil, "ledger.lua loaded into the shared namespace")

    local NOW = 1700000000
    local DAY = 86400

    -- (a) the pure rules.
    do
        local e = {}
        L.Add(e, "Erro", ITEM, 7, NOW)
        L.Add(e, "erro-whitemane", ITEM, 2, NOW)
        L.Add(e, "Poonyx", ITEM, 3, NOW)
        ck(#e == 3, "(a) three entries appended")
        ck(L.Add(e, "", ITEM, 5, NOW) == nil and #e == 3, "(a) a nameless entry is refused")
        ck(L.Add(e, "Ghost", ITEM, 0, NOW) == nil and #e == 3, "(a) a zero-quantity entry is refused")
        local f = L.InFlight(e, ITEM, NOW)
        ck(f["erro"] == 9, "(a) realm-qualified and bare names fold to one character")
        ck(f["poonyx"] == 3, "(a) ...and other characters are kept apart")
        ck(L.InFlight(e, 99999, NOW)["erro"] == nil, "(a) another item is not counted")
    end

    -- (b) evidence retires an entry; a stale snapshot does not.
    do
        local e = {}
        L.Add(e, "Erro", ITEM, 7, NOW)
        local kept = L.Reconcile(e, { erro = { count = 10, at = NOW - 60 } }, NOW)
        ck(#kept == 1, "(b) a snapshot taken BEFORE the send proves nothing")
        kept = L.Reconcile(e, { erro = { count = 3, at = NOW + 60 } }, NOW + 60)
        ck(#kept == 1, "(b) a newer snapshot that does not show the goods proves nothing")
        local kept2, retired = L.Reconcile(e, { erro = { count = 10, at = NOW + 3700 } }, NOW + 3700)
        ck(#kept2 == 0 and retired[1].why == "delivered",
           "(b) a newer snapshot showing the quantity retires the entry")
    end

    -- (c) the TTL backstop.
    do
        local e = {}
        L.Add(e, "Erro", ITEM, 7, NOW)
        ck(#L.Reconcile(e, {}, NOW + 29 * DAY) == 1, "(c) 29 days: still in flight")
        local kept, retired = L.Reconcile(e, {}, NOW + 31 * DAY)
        ck(#kept == 0 and retired[1].why == "expired", "(c) 31 days: retired by the TTL")
        ck(L.InFlight(e, ITEM, NOW + 31 * DAY)["erro"] == nil,
           "(c) ...and an expired entry stops suppressing a top-up immediately")
    end

    -- (d) the plan subtracts what is in transit.
    do
        local p = ns.Boons.BuildPlan(
            { { name = "Erro", level = 60, counts = { [ITEM] = 9 }, countsAt = NOW } },
            { source = "Bankalt", faction = "Alliance", stock = 99, itemID = ITEM,
              inFlight = { erro = 1 }, now = NOW })
        ck(#p.targets == 0, "(d) has 9 with 1 in transit -> nothing to send")
        ck(tostring(p.skipped[1].reason) == "has 9, 1 in transit",
           "(d) ...and the preview says exactly that")
        local text = ns.Boons.PreviewText(ns.Boons.BuildPlan(
            { { name = "Erro", level = 60, counts = { [ITEM] = 9 }, countsAt = NOW },
              { name = "Orn",  level = 60, counts = { [ITEM] = 0 }, countsAt = NOW } },
            { source = "Bankalt", faction = "Alliance", stock = 99, itemID = ITEM,
              inFlight = { erro = 1 }, now = NOW }))
        ck(text:find("has 9, 1 in transit", 1, true) ~= nil,
           "(d) ...in the confirm preview, in as many words")
        ck(text:find("nothing to send", 1, true) ~= nil, "(d) ...and why it is not being sent")
    end

    -- (e) A CONFIRMED send persists; an ATTEMPT does not.
    do
        local sim = Sim.New(bagsOf({ 10 }))
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, mesh({ { "Erro", 60, 3 } }))
        sim:Advance(120)
        ck(#n.Ledger.Entries() == 1, "(e) a confirmed send writes one ledger row")
        ck(n.Ledger.Entries()[1].qty == 7 and n.Ledger.Entries()[1].target == "Erro",
           "(e) ...recording the recipient and the quantity")
    end
    do
        local sim = Sim.New(bagsOf({ 10 }), { behaviour = function() return "fail" end })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, mesh({ { "Erro", 60, 3 } }))
        sim:Advance(120)
        ck(#n.Ledger.Entries() == 0, "(e) a mail that FAILED writes nothing")
    end
    do
        local sim = Sim.New(bagsOf({ 10 }), { behaviour = function() return "noack" end })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, mesh({ { "Erro", 60, 3 } }))
        sim:Advance(120)
        ck(#n.Ledger.Entries() == 0, "(e) a mail that timed out un-acknowledged writes nothing")
    end
    do
        local sim = Sim.New(bagsOf({ 10 }), { behaviour = function() return "noevidence" end })
        local n = newEngine(sim, nil)
        chatClear()
        startRun(n, sim, mesh({ { "Erro", 60, 3 } }))
        sim:Advance(120)
        ck(#n.Ledger.Entries() == 0,
           "(e) an ACKNOWLEDGED mail whose goods never moved writes nothing either")
    end

    -- (f) THE OWNER'S SCENARIO, VERBATIM: eight targets, the run interrupted after
    --     two, then re-run. It must plan the remaining SIX and double-send nothing.
    do
        local roster = mesh({
            { "T1", 60, 0 }, { "T2", 60, 1 }, { "T3", 60, 2 }, { "T4", 60, 3 },
            { "T5", 60, 4 }, { "T6", 60, 5 }, { "T7", 60, 6 }, { "T8", 60, 7 },
        })
        local sim = Sim.New(bagsOf({ 10, 10, 10, 10, 10, 10 }))
        local n = newEngine(sim, nil)
        -- Step mode for the FIRST run only, so "interrupted at exactly 2 of 8" is
        -- deterministic rather than a race against the virtual clock. The ledger
        -- contract under test is identical either way: it is written at the terminal
        -- success, and nothing about it knows which mode fired the send.
        n.Mail.SetStepMode(true)
        chatClear()
        local queued = startRun(n, sim, roster)
        ck(queued == 8, "(f) the first run plans eight mails")
        n.Mail.ContinueClick(); sim:Advance(5)
        n.Mail.ContinueClick(); sim:Advance(5)
        -- ...and then the player walks away from the mailbox.
        sim:CloseMailbox(n)
        n.Mail.SetStepMode(false)
        ck(#sim.sent == 2, "(f) interrupted at 2 of 8")
        ck(#n.Ledger.Entries() == 2, "(f) two confirmed sends are in the ledger")

        -- Re-run at the mailbox. The mesh has NOT caught up (cross-account mail
        -- takes an hour), so ONLY the ledger can prevent the double-send.
        sim.mailboxOpen = true
        chatClear()
        local q2 = derive(n, roster)
        ck(#q2 == 6, "(f) the re-run plans SIX mails — the remainder, by construction")
        local names = {}
        for _, m in ipairs(q2) do names[m.recipient] = true end
        ck(not names["T1"] and not names["T2"], "(f) ...and neither of the two already sent")

        local before = {}
        for _, m in ipairs(sim.sent) do before[m.recipient] = (before[m.recipient] or 0) + m.units end
        startRun(n, sim, roster)
        sim:Advance(300)
        local after = {}
        for _, m in ipairs(sim.sent) do after[m.recipient] = (after[m.recipient] or 0) + m.units end
        ck(after["T1"] == before["T1"] and after["T2"] == before["T2"],
           "(f) NOT ONE extra boon went to the two that were already served")
        ck(#sim.sent == 8, "(f) eight mails in total across the two runs, not ten")
    end

    -- (g) evidence clearing end-to-end: the mesh catches up, the entry retires, and
    --     the character becomes eligible again if they genuinely spend the boons.
    do
        local sim = Sim.New(bagsOf({ 10, 10 }))
        local n = newEngine(sim, nil)
        local roster = mesh({ { "Erro", 60, 3 } })
        chatClear()
        startRun(n, sim, roster)
        sim:Advance(120)
        ck(#n.Ledger.Entries() == 1, "(g) one entry in flight")
        -- an hour later the mail lands and Nexus sees the full pocket
        _G.__CLOCK = _G.__CLOCK + 3700
        roster[1].counts[ITEM] = 10
        roster[1].countsAt = _G.__CLOCK
        derive(n, roster)
        ck(#n.Ledger.Entries() == 0, "(g) the delivery is seen and the entry retires")
        -- ...and after they burn them, a top-up is planned again
        roster[1].counts[ITEM] = 2
        roster[1].countsAt = _G.__CLOCK
        local q = derive(n, roster)
        ck(#q >= 1 and q[1].units == 8, "(g) a genuinely empty pocket is topped up again")
        _G.__CLOCK = 1700000000
    end

    -- (h) MUTATION-CHECK THE IN-FLIGHT LATCH. If the ledger stopped counting
    --     in-flight quantity, (f) would double-send — prove the suite would notice.
    do
        local src = readFile(P("ledger.lua"))
        local frag = "                out[k] = (out[k] or 0) + e.qty"
        local head, tail = src:find(frag, 1, true)
        ck(head ~= nil, "(h) the in-flight accumulator is where the mutation expects it")
        if head then
            local mutated = src:sub(1, head - 1) .. "                out[k] = (out[k] or 0) + 0" .. src:sub(tail + 1)
            local chunk = loadstring(mutated, "@mutant:ledger")
            local mutNs = {}
            if chunk then pcall(chunk, ADDON_NAME, mutNs) end
            local e = {}
            mutNs.Ledger.Add(e, "Erro", ITEM, 7, NOW)
            local f = mutNs.Ledger.InFlight(e, ITEM, NOW)
            ck((f["erro"] or 0) == 0, "(h) the mutant does stop counting (it is a real mutation)")
            local p = ns.Boons.BuildPlan(
                { { name = "Erro", level = 60, counts = { [ITEM] = 9 }, countsAt = NOW } },
                { source = "Bankalt", faction = "Alliance", stock = 99, itemID = ITEM,
                  inFlight = f, now = NOW })
            ck(#p.targets == 1, "(h) MUTANT KILLED: with in-flight lost, the plan re-sends")
        end
    end
end
local V_LEDGER = (FAILS == LEDGER_BEFORE)
realprint("=== GATE LEDGER: " .. (V_LEDGER and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
realprint("############################################################")
realprint("# Daseeki-Conduit self-tests")
realprint("#   GATE 0      toc parse             : PASS")
realprint("#   GATE FW     clean-room firewall   : PASS")
realprint("#   GATE SUITES shipped pure suites   : PASS")
realprint("#   GATE SV     additive SavedVariables : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#   GATE FRIEND real auto-friend pass : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#   GATE MUT    boon plan mutations  : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#   GATE HDR    header control cluster : " .. (V_HDR and "PASS" or "FAIL"))
realprint("#   GATE ATTACH over-attach repro+fix : " .. (V_ATTACH and "PASS" or "FAIL"))
realprint("#   GATE RUN    hands-free state machine : " .. (V_RUN and "PASS" or "FAIL"))
realprint("#   GATE SETTLE attach vs bag settlement : " .. (V_SETTLE and "PASS" or "FAIL"))
realprint("#   GATE LEDGER outbound ledger rules : " .. (V_LEDGER and "PASS" or "FAIL"))
realprint("#")
realprint("#   RESULT: " .. (FAILS == 0 and "ALL PASS" or (FAILS .. " FAILURE(S) — RED")))
realprint("############################################################")
os.exit(FAILS == 0 and 0 or 1)
