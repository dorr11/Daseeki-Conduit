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
  with per-rule **Send** buttons, a **Run All** button, a live progress line, and
  a **Stop** button for the duration of a run.
- **Mandatory confirm-before-send** — every run shows a dry-run summary (items,
  gold, mail count, per-recipient breakdown) and sends nothing until you accept.
- **Hands-free runs** — that one Accept is the only interaction a batch needs.
  Mails go out strictly one at a time; the next begins only when the previous one
  has been *confirmed twice over* — the server's `MAIL_SUCCESS`, and the goods
  themselves leaving (the money delta for a gold mail, the attachments leaving
  the bags for an item mail). 15s ceilings on each, after which the run stops
  with a report and clears its own state; 0.5s spacing after failures only; one
  retry per mail, then that recipient is skipped by name and the run continues.
  A settings toggle restores the old one-mail-per-click stepping.
- **Guards** — recipient validation, no self-send, soulbound/quest/unmailable
  exclusion, and the postage buffer. **Nothing is sent unless what the Send Mail
  form holds matches what the plan asked for**, so a mail can never carry more
  than it was planned to. Runs abort cleanly if the mailbox closes or a mail
  fails.
- **Settlement-aware attaching** — the client locks bag slots while a container or
  mail operation is in flight, and a locked slot makes `SplitContainerItem` a
  silent no-op. Arming therefore waits for `BAG_UPDATE_DELAYED` (1s ceiling) before
  touching anything, re-derives which slots the items come out of on every mail,
  and never re-asks a split the client has half-completed.
- **Outbound ledger** — every confirmed send is recorded, and mail still in the
  post counts as already delivered when the next plan is built. A boon run
  interrupted at two of eight plans only the remaining six when you come back.
  Entries retire as soon as Nexus sees the goods arrive, or after 30 days.
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
- `/conduit transit` lists every boon already in the post with the age of each;
  `/conduit transit clear <character|all>` drops rows that are plainly wrong. Rows
  retire by themselves when the mesh sees the boons land, when the recipient has
  been seen a day later with no sign of them, or at Blizzard's 30-day mail expiry.
- `/conduit debug selftest` runs the built-in rule/batch/gold self-tests.
- `/conduit debug friends` shows what auto-friend would do on this character.
- `/conduit debug boons` shows the boon plan, the outbound ledger with ages, and
  the attach diagnostics (splits asked/delivered/refused, locked slots, settle
  waits); `/conduit debug boons clear` empties the ledger.

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
  builder (thirteen one-operator mutants, all of which must be killed by the
  suites). Exit 0 = all pass.
- `harness/mailsim.lua` stands the Classic Era mailbox up in plain Lua — bags, a
  cursor, split/pickup semantics, twelve attachment slots that report their stack
  counts, a `SendMail` that answers on a **virtual clock** — so the live send
  engine can be driven headless. That is what lets three further gates exist:
  **GATE ATTACH** reproduces the 1.2.0 over-attach against the pre-fix engine
  (reconstructed from the shipped source by three edits) and then proves both the
  new attach and the new send guard kill it independently; **GATE RUN** drives the
  hands-free state machine through its success path, both timeouts,
  retry-then-skip, the mailbox-close abort, the one-in-flight invariant and the
  Send-button ticker's whole lifecycle; **GATE SETTLE** models ASYNCHRONOUS bag
  settlement (locked slots, counts that only land on the `BAG_UPDATE_DELAYED`
  tick, and a split that half-completes) and replays the live field failure — the
  1.2.0 arming loses most of the run's tail to the race, the shipped arming
  delivers every mail; **GATE LEDGER** walks the outbound ledger's rules row by row
  and replays the owner's over-mail scenario verbatim.
