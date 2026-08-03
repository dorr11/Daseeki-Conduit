# Changelog

## 1.0.0 — 2026-08-03

First public release. Daseeki Conduit fills in the Send Mail form for you, so
shipping herbs to your alchemist or gold to the bank alt stops being a chore you
do by hand fifty times a week.

- **Mail rules.** Set a rule once — "all herbs go to Alchemyalt", "everything on
  this list goes to Bankalt", "anything above 50g goes to Bankalt" — and Conduit
  applies it with one click when you open a mailbox. Item rules match by category
  or by an explicit list you pick; gold rules keep a floor you nominate and never
  spend you down past the postage. Rules can be toggled on and off individually,
  and disabled per character if one alt should be left alone.
- **The mailbox panel.** Open any mailbox and a compact panel docks beside it,
  listing your rules with a Send button each plus Run All. Every send shows you
  exactly what is about to go and to whom before anything leaves — nothing is
  mailed without you confirming it first. Multi-mail batches step one click at a
  time so you can stop halfway.
- **Send Consumes, moved here from Daseeki Raid Prep.** Mail your raid-prep
  consumables to a raidmate or an alt in one action. If you had Raid Prep's bank
  recipient and item picks configured, they migrate into Conduit rules on first
  load — one rule per faction, automatically, without touching Raid Prep's own
  saved data and without overwriting any rule you already made here.
- **Auto-friend recipients** (on by default). WoW throws the "this person is not
  on your friends list, are you sure?" confirmation at every mail you send to a
  stranger — including your own bank alt. Conduit adds each recipient you
  configure to the current character's friends list once, and the popup stops
  interrupting you. Once only: unfriend somebody on purpose and Conduit leaves
  them unfriended and never brings it up again. Recipients on another realm or
  the other faction are skipped quietly, and a full friends list gets one
  explanatory line rather than a screen of failures. `/conduit debug friends`
  shows you the decision for every recipient on the character you are on.
- **Cross-account recipients.** With Daseeki Nexus installed, a recipient you set
  up on one account is auto-friended by your characters on every account in the
  mesh, so the bank alt you configured months ago on the other account just works.
  Without Nexus, auto-friending stays local to this account.
- **Settings live in the Daseeki hub.** `/conduit` opens the Conduit section of
  the shared Daseeki Core options window — rule editor, recipients, and the
  auto-friend toggle in one place, in whichever theme you have the suite set to.

Requires **Daseeki Core**. **Daseeki Nexus** is optional and only extends
auto-friending across your linked accounts.
