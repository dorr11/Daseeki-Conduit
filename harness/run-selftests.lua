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
--            mail queue / Raid-Prep migration / auto-friend / sync bridge).
--   SV       InitDB adds the auto-friend keys to a PRE-EXISTING save without
--            touching rules, and without a schema bump (additive-only).
--   FRIEND   the REAL Friends.RunPass against a stubbed C_FriendList:
--            adds once, marks, never re-adds — including after the user
--            deliberately unfriends — and stops cleanly at the list cap.
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

local function chatFind(needle)
    for _, line in ipairs(CHAT) do if line:find(needle, 1, true) then return line end end
    return nil
end
local function chatClear() for i = #CHAT, 1, -1 do CHAT[i] = nil end end

----------------------------------------------------------------------
-- Load the REAL addon files into one shared namespace, in .toc order.
----------------------------------------------------------------------
local ns = {}
local LOAD = { "core.lua", "rules.lua", "migrate.lua", "friends.lua", "syncbridge.lua", "selftest.lua" }
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
    -- the two this feature owns.
    ck(chatFind("auto-friend:") ~= nil, "the auto-friend suite ran")
    ck(chatFind("sync-bridge:") ~= nil, "the sync-bridge suite ran")
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
realprint("############################################################")
realprint("# Daseeki-Conduit self-tests")
realprint("#   GATE 0      toc parse             : PASS")
realprint("#   GATE FW     clean-room firewall   : PASS")
realprint("#   GATE SUITES shipped pure suites   : PASS")
realprint("#   GATE SV     additive SavedVariables : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#   GATE FRIEND real auto-friend pass : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#")
realprint("#   RESULT: " .. (FAILS == 0 and "ALL PASS" or (FAILS .. " FAILURE(S) — RED")))
realprint("############################################################")
os.exit(FAILS == 0 and 0 or 1)
