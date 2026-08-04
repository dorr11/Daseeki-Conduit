# Changelog

## Unreleased

- **Close the mail window and Conduit closes with it.** The panel now goes away the
  moment the mail window does, however it went — walking away from the mailbox,
  pressing Escape, the mail window's own close button, or another window taking its
  place. If you were part-way through a multi-mail batch when the mailbox closed,
  the run stops cleanly and tells you how many mails already went, and a
  confirm-before-send prompt still waiting on screen is dismissed with it, so a
  "Yes" can never fire a send that was planned at a mailbox you have already left.

- **The rule editor's Alt picker now shows your characters properly.** With Daseeki
  Nexus installed, the "Alt" dropdown beside Recipient lists the characters on this
  realm that Nexus knows about, each in its class colour, so setting up a rule is a
  click instead of remembering how you spelled a bank alt three months ago. You can
  still type any name you like into Recipient — the picker only saves typing, it
  never limits who a rule can mail.
- Changed: the picker no longer hides characters on the **other faction**. Rules are
  shared by every character on your account, so a rule you write on your Alliance
  main is one your Horde characters use too — hiding their recipients at the moment
  you are writing the rule was the wrong call. Other-faction characters are listed
  with a faction tag instead, and auto-friend keeps quietly skipping them on the
  characters where they cannot be mailed, exactly as before. Characters on another
  realm are still left out: a plain name only ever reaches your own realm.

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
