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
ns.VERSION  = "0.1.0"
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
-- SavedVariables (schema-versioned)
----------------------------------------------------------------------

local function defaultDB()
    return {
        schema        = ns.SCHEMA,
        rules         = {},   -- array of rule tables (see rules.lua for shape)
        settings      = {},   -- reserved for future global settings
        disabledChars = {},   -- [charKey] = true
        nextRuleId    = 1,    -- monotonic id source for stable rule ids
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
    ns:Print("  /conduit help            - this list")
end

local function dispatch(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "settings" or cmd == "config" or cmd == "options" or cmd == "opt" then
        if _G.DaseekiSuite and DaseekiSuite.Open then
            DaseekiSuite:Open("conduit")
        else
            ns:Print("the Daseeki hub (Daseeki Core) is not available.")
        end
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
