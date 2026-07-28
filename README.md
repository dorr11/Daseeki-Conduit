# Daseeki Conduit

**Mail, gold & materials automation — rule-based sending at the mailbox.**

ESO-style character logistics for WoW Classic Era. Define rules once, then send
every matching material stack and your excess gold to your bank alts with one
click at any open mailbox — no more manual alt-shuffling.

## Features

- **Materials routing rules** — route items to a recipient by item *category*
  (Trade Goods and its subclasses, Consumables, Reagents, …) or by an explicit
  item list. Matching stacks are mailed in batches of 12 attachments.
- **Gold threshold rules** — "send everything over X gold" to a bank alt, with a
  30-silver postage buffer so a gold send can never leave you unable to pay for
  the mail it rides on.
- **Send Consumes preset** — a ready-made rule seeded with common raid/dungeon
  consumables.
- **Mailbox panel** — a compact panel beside the mail window lists your rules
  with per-rule **Send** buttons, a **Run All** button, and a live progress line.
- **Mandatory confirm-before-send** — every run shows a dry-run summary (items,
  gold, mail count, per-recipient breakdown) and sends nothing until you accept.
- **Guards** — recipient validation, no self-send, soulbound/quest/unmailable
  exclusion, and the postage buffer. Runs abort cleanly if the mailbox closes or
  a mail fails.
- **Per-character disable** — opt a character out without deleting rules.

## Usage

- Open a mailbox → the **Conduit** panel appears beside it.
- Configure rules in the Daseeki hub: `/conduit settings` (or `/cdt`).
- `/conduit debug selftest` runs the built-in rule/batch/gold self-tests.

## Requires

- **Daseeki-Core** (shared hub + UI toolkit).
- Optional: **Daseeki-Nexus** (alt registry) — enriches the recipient picker when
  present; Conduit works fully standalone without it.
