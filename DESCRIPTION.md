# CurseForge Description — Daseeki Conduit

<!-- Canonical CurseForge project description. Update here first, then paste to
     https://www.curseforge.com/wow/addons/daseeki-conduit (project 1638368).
     Last synced: 2026-08-11 (v1.2.5). -->

Daseeki Conduit is the Daseeki suite's mail automation addon for WoW Classic Era. Define rules once — "herbs go to my alchemist, gold above 50g goes to the bank alt" — and Conduit fills the Send Mail form for you at any mailbox.

## Features
- **Mail rules**: route items by category or name, and gold above a floor, to named recipients — applied with one click when you open the mailbox
- **Hands-free batches**: review the preview, accept once, and the whole run sends itself — one mail at a time, each confirmed by the server before the next goes out, with a live progress line and a Stop button. Nothing is ever sent unless what is on the form matches what the preview promised. (Prefer to drive each mail yourself? One setting puts the per-click mode back.)
- **Send Consumes** (moved here from Daseeki Raid Prep): mail your raid-prep consumables to a raidmate or alt in one action; your existing Raid Prep recipients migrate automatically
- **Chronoboon replenishment** (requires Daseeki Nexus): nominate a boon-source character, and one button at the mailbox tops every level-60 character across your linked accounts back up to ten Chronoboon Displacers — each mail sized to exactly what that character is missing, with a full preview (including how fresh each character's counts are) before anything sends. Mail already in the post counts as delivered, so a run you interrupted and started again sends only the remainder
- **Auto-friend recipients**: characters on your account (and across your accounts, with Daseeki Nexus) automatically friend your configured recipients, so the Blizzard "unknown recipient" mail confirmation never interrupts you — and a recipient you deliberately unfriend is never re-added
- Rules can be toggled individually; everything lives in the Daseeki hub

## Chat Commands
- `/conduit` — open the Conduit section in the Daseeki hub
- `/conduit debug friends` — show the auto-friend decision per recipient
- `/conduit debug boons` — show the boon plan and everything currently in the post (add `clear` to empty it)

## Requires
- **Daseeki Core** (required) — the suite's shared UI foundation
- Optional: Daseeki Nexus — extends auto-friending across your linked accounts

DISCLAIMER: I originally developed these addons for my own personal use, and am listing them on CurseForge to allow some friends to test/report bugs. The 'Daseeki' suite of addons is still very much a WIP, so please keep that in mind when downloading.
