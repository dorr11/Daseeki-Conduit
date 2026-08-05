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
- **Auto-friend mail recipients** — Blizzard only asks you to confirm mail to
  someone who is not on your friends list, so Conduit adds each configured
  recipient to the current character's friends list once and the popup stops
  appearing for your own alts. Added at most once per character: unfriend one by
  hand and it stays unfriended. Other-realm and cross-faction recipients are
  skipped silently; a full friends list gets one explanatory line. With
  **Daseeki-Nexus** installed the recipient list travels the mesh, so a bank alt
  configured on one account is friended by characters on every account.
- **Chronoboon replenishment** (needs **Daseeki-Nexus**) — nominate one character
  as the boon source; at a mailbox on that character one button tops every
  level-60 character in the mesh up to 10 Chronoboon Displacers, one mail each,
  exactly the amount each is short. The confirm screen shows every character, the
  amount, what they were last known to hold and **how old that count is**. When
  bags cannot cover everybody the biggest need is filled first and the shortfall
  is stated before you accept and again when the run ends. Counts come from Nexus
  and include the bank.

## Usage

- Open a mailbox → the **Conduit** panel appears beside it.
- Configure rules in the Daseeki hub: `/conduit settings` (or `/cdt`).
- `/conduit debug selftest` runs the built-in rule/batch/gold self-tests.
- `/conduit debug friends` shows what auto-friend would do on this character.

## Requires

- **Daseeki-Core** (shared hub + UI toolkit).
- Optional: **Daseeki-Nexus** — enriches the recipient picker with your alt
  registry, and carries the auto-friend recipient list across accounts over the
  shared `Daseeki.Sync` namespace store. Conduit works fully standalone without
  it (auto-friending then stays local to this account).

## Development

- `harness/run-selftests.cmd` runs the headless gates under real Lua 5.1: parse
  every file the `.toc` lists, the clean-room firewall, the shipped pure
  self-test suites, SavedVariables additivity, an end-to-end auto-friend
  drive against a stubbed friends list, and a MUTATION TEST of the boon plan
  builder (twelve one-operator mutants, all of which must be killed by the
  suites). Exit 0 = all pass.
