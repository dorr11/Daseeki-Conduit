# Changelog

## [Unreleased] — v1.0.0
### Added
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
