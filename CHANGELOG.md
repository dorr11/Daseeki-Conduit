# Changelog

## [Unreleased] — v1.0.0
### Added
- **A LICENSE file — Daseeki Conduit ships All Rights Reserved**, matching the
  rest of the suite, with the `## X-License` line to say so in the .toc.
- **Auto-friend mail recipients** (on by default). Blizzard only raises the
  "are you sure?" confirmation for mail to someone who is not on your friends
  list, so every recipient you configure is added to the current character's
  friends list once — and the popup stops appearing for your own bank alts.
  Each recipient is added at most once per character: unfriend one by hand and
  Conduit leaves it unfriended and never mentions it again. Recipients on
  another realm or the other faction are skipped silently, the current character
  is never friended, and a full friends list produces one explanatory line
  instead of a wall of failures. Toggle it under Conduit's settings
  ("Auto-friend mail recipients"); `/conduit debug friends` shows exactly what
  the pass would do on this character.
- **Cross-account recipients.** When Daseeki Nexus is installed, Conduit
  publishes its recipient directory on the shared `Daseeki.Sync` namespace store
  (namespace `conduit`), so a bank alt configured on one account is auto-friended
  by characters on every account in the mesh. The namespace is additive: peers
  running an older build cache the payload harmlessly and replay it the moment
  they update. Without Nexus, auto-friending simply stays local to this account.
- A headless self-test harness (`harness/run-selftests.cmd`) — parse gate,
  clean-room firewall, the shipped pure suites, an additive-SavedVariables gate,
  and an end-to-end auto-friend drive against a stubbed friends list.

### Fixed
- **The rule editor's "Alt" picker now actually appears.** Its Nexus probe looked
  for globals Daseeki Nexus has never published (`DaseekiNexus` / `DaseekiNetwork`
  and roster accessors on them), so the dropdown was permanently empty and the row
  permanently hidden. Conduit now reads the Nexus SavedVariables store directly —
  the character graph plus the inventory owners graph, unioned — the same read-only,
  type-guarded pattern the Bags 2.0 bridge uses. The picker offers same-realm
  characters only, never the current one, and drops an alt only when its record
  explicitly names the other faction (an unknown faction is still offered). Both
  areas are version-gated independently, and a missing or malformed Nexus store
  leaves the row hidden exactly as before.

### Changed
- SavedVariables gained `friendDir`, `friendDirRev`, and `friended`. All three
  are additive: an existing save gains them on load with rules, settings, and
  per-character disables untouched, and the schema version is unchanged.
- Absorbs Raid Prep's Send Consumes — settings migrate automatically. On first
  load, any per-faction bank recipient and hand-picked item selection you had in
  Daseeki Raid Prep become "Send Consumes" rules here (one rule per faction). The
  import runs once, is non-destructive to Raid Prep's saved data, and never
  overwrites rules you already have.

## 0.1.0
- Initial build: rule-based mail automation at the mailbox — item-category and
  explicit-list item rules, gold-over-threshold rules, a mandatory
  confirm-before-send dry-run popup, the mailbox panel (per-rule Send + Run All),
  and the Send Consumes preset. Optional Daseeki-Nexus alt-registry integration.
