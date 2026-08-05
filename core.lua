--[[
    Daseeki Conduit — core.lua
    Namespace, SavedVariables (schema-versioned), character key, slash routing,
    self-test registry, and the init/login lifecycle.

    Purpose: ESO-style character logistics at the mailbox. Rule-based mail
    automation (materials routing + gold-over-threshold) replacing manual
    alt-shuffling. Standalone addon; optional Daseeki-Nexus integration for the
    alt registry (soft-guarded, no-ops cleanly when absent).

    Every send passes through a MANDATORY confirm-before-send dry-run popup —
    the SavedVariables safety culture applied to mail: nothing leaves without an
    explicit Accept.
--]]

local ADDON, ns = ...

ns.ADDON    = ADDON
ns.DISPLAY  = "Daseeki Conduit"
ns.VERSION  = "1.1.0"
ns.CHAT_TAG_TEXT = "Daseeki Conduit"
-- Static fallback used only when Daseeki Core (DaseekiUI) is absent; when present the
-- chat tag derives from the live "brand" token (Field Ledger rollout, BRAND_SPEC §2).
ns.CHAT_TAG = "|cff4fc3f7Daseeki Conduit|r"

-- Schema version for DaseekiConduitDB. Bump + add a migration branch below on any
-- breaking shape change; a mismatch we can't migrate resets to defaults (with a
-- one-line notice) rather than risking a corrupt read.
ns.SCHEMA = 1

-- Mail constants. ATTACHMENTS_MAX_SEND is a FrameXML constant (12 in Classic Era);
-- fall back defensively so a client that omits it still batches correctly.
ns.MAX_ATTACH = 12            -- resolved against ATTACHMENTS_MAX_SEND at login
-- Postage safety buffer for gold rules: never let a gold send drop the wallet
-- below keepAmount + this buffer. Design calls for a 30s (30 silver) buffer, an
-- order of magnitude over the real 30c flat postage, so a gold rule can never
-- leave you unable to pay for the mail it is riding on.
ns.POSTAGE_BUFFER = 30 * 100  -- copper (30 silver)
ns.POSTAGE_PER_MAIL = 30      -- copper — flat Classic postage per mail (cost estimate)

ns.MAIL_SUBJECT = "Daseeki Conduit"

----------------------------------------------------------------------
-- Small utilities
----------------------------------------------------------------------

-- Token → "|cffRRGGBB" escape prefix for chat / StaticPopup strings, where a real
-- FontObject can't be assigned. Reads the live theme so spans track SetTheme. Returns
-- nil when Core is absent (headless self-test harness), so callers fall back to plain
-- text and never error. (Field Ledger rollout: eliminates hardcoded |cff literals.)
function ns:Hex(token)
    local UI = _G.DaseekiUI
    if not (UI and UI.Color) then return nil end
    local r, g, b = UI.Color(token)
    local function b255(v) return math.max(0, math.min(255, math.floor((v or 0) * 255 + 0.5))) end
    return ("|cff%02x%02x%02x"):format(b255(r), b255(g), b255(b))
end

-- Wrap `text` in a token color for chat/popup strings; plain text if Core is absent.
function ns:Wrap(token, text)
    local h = ns:Hex(token)
    if not h then return tostring(text) end
    return h .. tostring(text) .. "|r"
end

-- Brand-tinted chat tag (falls back to the static cyan tag when Core is unavailable).
local function chatTag()
    local h = ns.Hex and ns:Hex("brand")
    if h then return h .. ns.CHAT_TAG_TEXT .. "|r" end
    return ns.CHAT_TAG
end

function ns:Print(...)
    print(chatTag() .. ":", ...)
end

-- Surface errors to the real handler (style-guide standing rule: layout/runtime
-- errors must surface, never be pcall-swallowed silently).
function ns:SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
    return ok, err
end

-- Stable per-character key ("Name-Realm"). Used by the per-character disable map.
function ns:CharKey()
    local name = UnitName and UnitName("player") or "?"
    local realm = GetRealmName and GetRealmName() or "?"
    return name .. "-" .. realm
end

-- Is Conduit disabled on the current character?
function ns:IsCharDisabled()
    local db = DaseekiConduitDB
    return db and db.disabledChars and db.disabledChars[ns:CharKey()] and true or false
end

function ns:SetCharDisabled(on)
    local db = DaseekiConduitDB
    if not db then return end
    db.disabledChars = db.disabledChars or {}
    db.disabledChars[ns:CharKey()] = on and true or nil
end

----------------------------------------------------------------------
-- Event dispatch (single shared frame fans out to subscribed handlers)
----------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "DaseekiConduitEventFrame")
ns.eventFrame = eventFrame
local eventHandlers = {}   -- event -> array of handler fns

function ns:RegisterEvent(event, handler)
    local list = eventHandlers[event]
    if not list then
        list = {}
        eventHandlers[event] = list
        eventFrame:RegisterEvent(event)
    end
    list[#list + 1] = handler
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok then geterrorhandler()(err) end
    end
end)

----------------------------------------------------------------------
-- Mailbox teardown coordinator
--
-- EVERYTHING Conduit puts on screen at a mailbox belongs to that mailbox: the
-- rule panel, an in-flight send batch, and the confirm popup guarding a send.
-- When the mail window goes, all three go — walking away from the mailbox,
-- Escape, the mail window's own close button, or another UI panel taking its
-- slot are all the same event as far as Conduit is concerned.
--
-- Modules register a closer here rather than each racing its own MAIL_CLOSED
-- handler, which buys three things a pile of independent handlers cannot:
--   * ONE ORDER. Closers run in load order (mail.lua's batch abort before
--     panel.lua's hide), so teardown is deterministic instead of registration-
--     order luck.
--   * ONCE PER VISIT. Several signals feed this (MAIL_CLOSED and MailFrame's
--     OnHide, which fire in either order); the second one in a visit is a no-op.
--   * ISOLATION. A closer that errors is surfaced to the error handler and the
--     remaining closers still run, so one bad module can never strand the panel
--     on screen.
----------------------------------------------------------------------

-- Split into two pure pieces (the latch and the fan-out) which CloseWithMailbox
-- composes, so the self-tests can exercise each without firing the LIVE closers —
-- running /conduit debug selftest at an open mailbox must never tear the panel down.

local mailboxClosers = {}
ns.mailboxOpen = false

-- Register fn(reason) to run when the mailbox goes away. Load order is run order.
function ns:RegisterMailboxCloser(fn)
    if type(fn) ~= "function" then return end
    mailboxClosers[#mailboxClosers + 1] = fn
end

-- Arm the teardown. Called on MAIL_SHOW, and by Panel.Show so that re-opening the
-- panel with /conduit show at an already-open mailbox re-arms it too.
function ns:MailboxOpened()
    ns.mailboxOpen = true
end

-- The latch. Consumes the armed state, returning true exactly ONCE per arming, so
-- the several signals that mean "the mailbox is gone" (MAIL_CLOSED and MailFrame's
-- OnHide, which arrive in either order) collapse into a single teardown.
function ns:ConsumeMailboxOpen()
    if not ns.mailboxOpen then return false end
    ns.mailboxOpen = false
    return true
end

-- The fan-out. Runs every closer in order, isolating each: a closer that errors is
-- reported through onError and the REST STILL RUN, so one bad module can never
-- strand the panel on screen. Returns how many closers ran.
function ns.RunClosers(closers, reason, onError)
    if type(closers) ~= "table" then return 0 end
    local n = 0
    for i = 1, #closers do
        local ok, err = pcall(closers[i], reason)
        n = n + 1
        if not ok and onError then onError(err) end
    end
    return n
end

-- Tear down everything that belongs to the mailbox. Returns true if this call did
-- the work, false if the mailbox was already torn down (a duplicate signal).
function ns:CloseWithMailbox(reason)
    if not ns:ConsumeMailboxOpen() then return false end
    ns.RunClosers(mailboxClosers, reason, geterrorhandler())
    return true
end

----------------------------------------------------------------------
-- Mailbox VISIBILITY fan-out (the other half of the coordinator)
--
-- MAIL_SHOW is not "the mail window is on screen": it is the server telling the
-- client a mailbox was opened, and FrameXML shows MailFrame from its OWN handler
-- for the same event. Two frames, one event, no defined order — so a Conduit
-- handler that reads MailFrame:IsShown() can legitimately be asked the question
-- one beat before the answer becomes true.
--
-- That is a real bug, not a theoretical one: the panel's boon row is drawn from
-- Boons.State(), which reads MailFrame:IsShown(), and MAIL_SHOW was the only thing
-- that ever refreshed it. Land on the wrong side of the coin flip and the row
-- freezes at "nomailbox" — a greyed Replenish Boons button at a wide-open mailbox,
-- for the whole visit.
--
-- The fix is to stop inferring visibility from an event and to observe it: hook
-- MailFrame's OnShow, which fires when the frame is ACTUALLY shown, and re-run the
-- registered refreshers. Refreshers are idempotent redraws, so unlike the closers
-- there is NO latch here — every OnShow re-asks, and asking twice costs a redraw.
----------------------------------------------------------------------

local mailboxRefreshers = {}

-- Register fn(reason) to run whenever the mail window becomes visible. The handler
-- must be an idempotent redraw: it can and will run more than once per visit.
function ns:RegisterMailboxRefresher(fn)
    if type(fn) ~= "function" then return end
    mailboxRefreshers[#mailboxRefreshers + 1] = fn
end

-- The fan-out, reusing the closers' isolation contract: one refresher that errors
-- is surfaced and the rest still run, so a broken redraw cannot strand the panel
-- showing a stale answer.
function ns:MailboxShown(reason)
    return ns.RunClosers(mailboxRefreshers, reason, geterrorhandler())
end

-- The install-once guard for a frame we do not own.
--
-- Lifted out of hookMailFrame so the self-tests can prove idempotence against a
-- stand-in: a HookScript CANNOT be undone, so a test that hooked the real
-- MailFrame would leave that hook on the player's UI forever.
--
-- Returns true from the FIRST call that finds a hookable target and installs every
-- script; every later call with the same `state` table is a no-op returning false.
-- Scripts are an ORDERED array of {event, handler} — pairs() order is undefined and
-- installation order is observable.
function ns.HookOnce(state, target, scripts)
    if type(state) ~= "table" or state.hooked then return false end
    if type(target) ~= "table" or type(target.HookScript) ~= "function" then return false end
    state.hooked = true
    for _, pair in ipairs(scripts or {}) do
        target:HookScript(pair[1], pair[2])
    end
    return true
end

-- MailFrame's OnHide is the earliest and broadest "the mail window is gone"
-- signal: MAIL_CLOSED only arrives after CloseMail() round-trips to the server,
-- and an addon can hide MailFrame outright. FrameXML's own OnHide calls
-- CloseMail(), so a hidden MailFrame always means a closed mailbox. Its OnShow is
-- the matching "the mail window is HERE" signal (see the fan-out above). Both are
-- hooked lazily on the first MAIL_SHOW (MailFrame certainly exists by then) and
-- exactly once; HookScript never displaces FrameXML's handlers.
--
-- The lazy install is safe on either side of the MAIL_SHOW coin flip. If FrameXML
-- shows MailFrame BEFORE our handler runs, the hook misses that first OnShow — but
-- MailFrame is already visible by then, so the panel's own refresh reads it
-- correctly with no help. If our handler runs FIRST, the hook is installed before
-- the frame is shown and catches the OnShow that follows.
local mailFrameHook = {}
local function hookMailFrame()
    return ns.HookOnce(mailFrameHook, _G.MailFrame, {
        { "OnHide", function()
            ns:SafeCall(function() ns:CloseWithMailbox("mail window closed") end)
        end },
        { "OnShow", function()
            ns:SafeCall(function() ns:MailboxShown("mail window shown") end)
        end },
    })
end

ns:RegisterEvent("MAIL_SHOW", function()
    ns:MailboxOpened()
    hookMailFrame()
end)

ns:RegisterEvent("MAIL_CLOSED", function()
    ns:CloseWithMailbox("MAIL_CLOSED")
end)

----------------------------------------------------------------------
-- SavedVariables (schema-versioned)
----------------------------------------------------------------------

local function defaultDB()
    return {
        schema        = ns.SCHEMA,
        rules         = {},   -- array of rule tables (see rules.lua for shape)
        settings      = {},   -- global settings (settings.autoFriend — friends.lua)
        disabledChars = {},   -- [charKey] = true
        nextRuleId    = 1,    -- monotonic id source for stable rule ids

        -- Auto-friend (friends.lua). Purely ADDITIVE keys: ensureKeys creates them on
        -- an existing save without touching anything else, so no schema bump is due.
        friendDir     = {},   -- [canonicalKey] = { name, realm, faction, ts }
        friendDirRev  = 1,    -- monotonic revision of friendDir (cross-account gating)
        friended      = {},   -- [charKey] = { [canonicalKey] = true }
    }
end

-- Fill any missing top-level keys without clobbering user data.
local function ensureKeys(db)
    local def = defaultDB()
    for k, v in pairs(def) do
        if db[k] == nil then db[k] = v end
    end
end

function ns:InitDB()
    if type(DaseekiConduitDB) ~= "table" then
        DaseekiConduitDB = defaultDB()
    else
        local db = DaseekiConduitDB
        if db.schema == nil then
            -- Pre-schema (or hand-made) table: adopt current shape, keep any rules.
            db.schema = ns.SCHEMA
        elseif db.schema ~= ns.SCHEMA then
            -- No forward migrations defined yet. If a future build lowers into here,
            -- add branches by version. Until then, an unknown schema is reset (data
            -- from a newer build we can't understand is safer replaced than misread).
            if db.schema > ns.SCHEMA then
                ns:Print("settings are from a newer version (schema " .. tostring(db.schema)
                    .. "); resetting to defaults for safety.")
                DaseekiConduitDB = defaultDB()
                db = DaseekiConduitDB
            end
            db.schema = ns.SCHEMA
        end
        ensureKeys(db)
    end
    ns.db = DaseekiConduitDB
    return ns.db
end

----------------------------------------------------------------------
-- Self-test registry (pure-Lua suites; run via /cdt debug selftest)
----------------------------------------------------------------------

local selfTests = {}   -- ordered { name, fn(verbose) -> ok }

function ns:RegisterSelfTest(name, fn)
    selfTests[#selfTests + 1] = { name = name, fn = fn }
end

function ns:RunSelfTests(verbose)
    local allPass = true
    for i = 1, #selfTests do
        if verbose then ns:Print("selftest: " .. selfTests[i].name) end
        local ok = selfTests[i].fn(verbose)
        allPass = allPass and ok
    end
    if verbose then
        ns:Print(allPass and "selftest: ALL SUITES PASS" or "selftest: FAILURES ABOVE")
    end
    return allPass
end

----------------------------------------------------------------------
-- Slash routing: /conduit and /cdt
----------------------------------------------------------------------

local function printHelp()
    ns:Print("commands:")
    ns:Print("  /conduit                 - open the mailbox panel help / hub settings")
    ns:Print("  /conduit show            - re-open the mailbox panel (while a mailbox is open)")
    ns:Print("  /conduit settings        - open the Daseeki hub to Conduit settings")
    ns:Print("  /conduit disable         - disable Conduit on this character")
    ns:Print("  /conduit enable          - re-enable Conduit on this character")
    ns:Print("  /conduit debug selftest  - run rule/batch/gold self-tests")
    ns:Print("  /conduit debug friends   - what auto-friend would do on this character")
    ns:Print("  /conduit help            - this list")
end

-- "Open Conduit's settings" — ONE definition, because there is now more than one
-- door to it: /conduit, /conduit settings, and the panel header's gear glyph. A
-- second copy in panel.lua would be a second thing to keep in step with the hub.
function ns:OpenSettings()
    if _G.DaseekiSuite and DaseekiSuite.Open then
        DaseekiSuite:Open("conduit")
        return true
    end
    ns:Print("the Daseeki hub (Daseeki Core) is not available.")
    return false
end

local function dispatch(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "settings" or cmd == "config" or cmd == "options" or cmd == "opt" then
        ns:OpenSettings()
    elseif cmd == "disable" then
        ns:SetCharDisabled(true)
        ns:Print("disabled on this character. Rules will not send here until re-enabled.")
        if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
    elseif cmd == "enable" then
        ns:SetCharDisabled(false)
        ns:Print("enabled on this character.")
        if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
    elseif cmd == "show" then
        if _G.MailFrame and _G.MailFrame:IsShown() and ns.Panel and ns.Panel.Show then
            ns.Panel.Show()
        else
            ns:Print("open a mailbox first — the Conduit panel docks beside it.")
        end
    elseif cmd == "debug" then
        local sub = (rest or ""):match("^(%S*)")
        sub = (sub or ""):lower()
        if sub == "selftest" or sub == "" then
            ns:RunSelfTests(true)
        elseif sub == "friends" then
            if ns.Friends and ns.Friends.Debug then ns:SafeCall(ns.Friends.Debug) end
        else
            ns:Print("unknown debug command: " .. sub)
        end
    elseif cmd == "help" then
        printHelp()
    else
        printHelp()
    end
end

SLASH_DASEEKICONDUIT1 = "/conduit"
SLASH_DASEEKICONDUIT2 = "/cdt"
SlashCmdList["DASEEKICONDUIT"] = dispatch

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

ns.state = { loaded = false, loggedIn = false }

ns:RegisterEvent("ADDON_LOADED", function(_, loaded)
    if loaded ~= ADDON then return end
    ns:InitDB()
    -- Resolve the mail attachment cap now that FrameXML constants are available.
    if type(ATTACHMENTS_MAX_SEND) == "number" and ATTACHMENTS_MAX_SEND > 0 then
        ns.MAX_ATTACH = ATTACHMENTS_MAX_SEND
    end
    ns.state.loaded = true
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    ns.state.loggedIn = true
    -- Register options into the Daseeki hub (options.lua owns the builder).
    if ns.Options and ns.Options.Register then
        ns.Options.Register()
    end
end)
