--[[
    Daseeki Conduit — syncbridge.lua

    CROSS-ACCOUNT recipient directory, over the Daseeki.Sync namespace store.

    The owner's ask is "friend the bank alt on ALL characters in the mesh" — which
    spans accounts, and Conduit's SavedVariables do not. Daseeki-Nexus publishes the
    suite-wide namespace store for exactly this: `Daseeki.Sync` (syncns.lua), a
    mesh-transported, revision-gated, owner-keyed key/value store that any suite
    addon may register a namespace on.

    ── Why a guarded probe and not a dependency ──────────────────────────────────
    Daseeki.Sync is created on the shared global `Daseeki` table at Nexus LOAD time,
    and Conduit's .toc already carries `## OptionalDeps: Daseeki-Nexus` — a LOAD-ORDER
    statement, not a dependency: when Nexus is installed the client loads it first, so
    the store exists before our PLAYER_LOGIN runs. When it is absent, every function
    here type-guards to a clean no-op and Conduit is exactly what it was: local-only
    auto-friending on this account. This is the same shape as the Bags 2.0 -> Nexus
    Inventory bridge (Daseeki-Bags2-beta/nexus.lua).

    ── Why a NEW namespace is safe for peers running an older build ──────────────
    Verified against Daseeki-Nexus syncns.lua (the "attune" namespace's contract
    notes, and Sync.ApplyInbound / Sync._DeliverOne / Sync.DeliverRemote):
      * Mesh.HandleNSPayload -> Sync.ApplyInbound STORES any namespace key it is
        handed, registered or not; _DeliverOne then finds no spec and returns. A peer
        without this Conduit build therefore CACHES our payload and errors on nothing.
      * Because it cached it, Sync.OnLogin -> DeliverRemote replays that payload to
        the consumer the moment that peer does update. No re-sync, no protocol bump.
      * Mesh.DiffNamespaceHashes iterates the REMOTE hash map, so an old peer still
        pulls "conduit" from us and a new peer gets whatever an old peer relayed.
    Everything is rev-gated, so a replay can never overwrite fresher data.

    ── The payload ───────────────────────────────────────────────────────────────
      key       "conduit"
      ownerKey  the DEFAULT (this Nexus account id). The directory is ACCOUNT data —
                one payload covering every character on the account — not per
                character, so there is one rev to gate instead of N.
      rev       Conduit's own persisted db.friendDirRev, so a /reload never re-sends
                a revision a peer already applied.
      payload   { v = 1, ts = <epoch>, recipients = { [canonicalKey] =
                    { name = "Bankalt", realm = "whitemane", faction = "Alliance" } } }

    Consumer side: every entry is re-sanitised on arrival and merged behind our own
    (friends.lua MergeDirectories), then run through the same skip matrix — so a peer
    can contribute a recipient but can never make us friend someone on another realm,
    another faction, or one this character has already deliberately unfriended.

    Clean-room: the Daseeki.Sync surface above was read from our own Daseeki-Nexus
    repo. No third-party addon source was opened.
--]]

local ADDON, ns = ...

local Bridge = {}
ns.SyncBridge = Bridge

Bridge.KEY             = "conduit"
Bridge.PAYLOAD_VERSION = 1
Bridge.MIN_SYNC        = 2          -- Daseeki.Sync v2 introduced provider namespaces

-- ════════════════════════════════════════════════════════════════════════════
--  PRESENCE PROBE  (pure; `G` is injectable for the harness)
-- ════════════════════════════════════════════════════════════════════════════

-- The Daseeki.Sync v2 store, or nil + a human reason. Every step is a type guard.
function Bridge.Sync(G)
    G = G or _G
    if type(G) ~= "table" then return nil, "no global table" end
    local D = G.Daseeki
    if type(D) ~= "table" then
        return nil, "Daseeki Nexus is not installed (no Daseeki namespace)"
    end
    local S = D.Sync
    if type(S) ~= "table" then
        return nil, "the Daseeki namespace carries no Sync store"
    end
    if type(S.RegisterNamespace) ~= "function"
        or type(S.MarkDirty) ~= "function"
        or type(S.DeliverRemote) ~= "function" then
        return nil, "the Daseeki.Sync store predates the namespace API"
    end
    local v = tonumber(S.VERSION) or 0
    if v < Bridge.MIN_SYNC then
        return nil, ("Daseeki.Sync is v%d; the namespace store needs v%d"):format(v, Bridge.MIN_SYNC)
    end
    return S
end

function Bridge.Available(G)
    return Bridge.Sync(G) ~= nil
end

function Bridge.Registered()
    return Bridge._registered == true
end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE: payload build / parse
-- ════════════════════════════════════════════════════════════════════════════

-- Our directory -> the wire payload. Only well-formed entries ship; `ts` and the
-- version are the only extras, and both are additive-safe for a future reader.
function Bridge.BuildPayload(dir, ts)
    local out = { v = Bridge.PAYLOAD_VERSION, ts = tonumber(ts) or 0, recipients = {} }
    for key, e in pairs(dir or {}) do
        if type(key) == "string" and key ~= "" and type(e) == "table"
            and type(e.name) == "string" and e.name ~= "" then
            out.recipients[key] = { name = e.name, realm = e.realm, faction = e.faction }
        end
    end
    return out
end

-- A peer's payload -> a sanitised recipients map, or nil + a reason.
--
-- A payload stamped with a version NEWER than this build reads is refused outright
-- rather than guessed at: a future build may reshape an entry, and a misread faction
-- would mean friending across a faction line (which just fails) or, worse, silently
-- skipping a recipient the owner wanted friended.
function Bridge.ParsePayload(data)
    if type(data) ~= "table" then return nil, "payload is not a table" end
    local v = tonumber(data.v) or 0
    if v > Bridge.PAYLOAD_VERSION then
        return nil, ("payload v%d is newer than this build reads (v%d)"):format(v, Bridge.PAYLOAD_VERSION)
    end
    if type(data.recipients) ~= "table" then return nil, "payload carries no recipients map" end

    local out, n = {}, 0
    for key, e in pairs(data.recipients) do
        if type(key) == "string" and key ~= "" and type(e) == "table"
            and type(e.name) == "string" and e.name ~= "" then
            local faction = e.faction
            if faction ~= "Alliance" and faction ~= "Horde" then faction = nil end
            out[key] = {
                name    = e.name,
                realm   = type(e.realm) == "string" and e.realm or "",
                faction = faction,
            }
            n = n + 1
        end
    end
    return out, nil, n
end

-- ════════════════════════════════════════════════════════════════════════════
--  RUNTIME: the namespace provider/consumer
-- ════════════════════════════════════════════════════════════════════════════

function Bridge.Provide()
    local F = ns.Friends
    if not F then return nil end
    return Bridge.BuildPayload(F.Directory(), (time and time()) or 0)
end

function Bridge.Rev()
    local F = ns.Friends
    return (F and F.Rev()) or 1
end

function Bridge.OnRemote(ownerKey, data)
    if type(ownerKey) ~= "string" or ownerKey == "" then return end
    local recips, why = Bridge.ParsePayload(data)
    if not recips then
        Bridge._lastReject = why
        return
    end
    local F = ns.Friends
    if F and F.SetRemote then F.SetRemote(ownerKey, recips) end
end

-- Idempotent registration. Returns true when the namespace is live.
function Bridge.Register()
    if Bridge._registered then return true end
    local S, why = Bridge.Sync()
    if not S then
        Bridge._why = why
        return false
    end
    S.RegisterNamespace(Bridge.KEY, {
        provide  = function() return Bridge.Provide() end,
        rev      = function() return Bridge.Rev() end,
        onRemote = function(ownerKey, data) Bridge.OnRemote(ownerKey, data) end,
    })
    Bridge._registered = true
    Bridge._why = nil
    return true
end

-- Snapshot our directory into the store and hand it to the mesh.
function Bridge.Publish()
    if not Bridge.Register() then return false end
    local S = Bridge.Sync()
    if not S then return false end
    ns:SafeCall(S.MarkDirty, Bridge.KEY)
    return true
end

-- Replay every cached peer payload into OnRemote.
--
-- Nexus's own Sync.OnLogin does this for namespaces registered BEFORE it runs, and
-- our registration order against it is not guaranteed. DeliverRemote is idempotent,
-- so calling it ourselves makes the login path order-independent instead of relying
-- on which addon's login handler fires first.
function Bridge.PullCached()
    if not Bridge.Register() then return false end
    local S = Bridge.Sync()
    if not S then return false end
    ns:SafeCall(S.DeliverRemote, Bridge.KEY)
    return true
end

function Bridge.Login()
    if not Bridge.Register() then return false end
    Bridge.PullCached()
    Bridge.Publish()
    return true
end
