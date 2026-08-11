# Changelog

## 1.2.5 — 2026-08-11

- **A long mail run can no longer stack the game up on itself.** The game does not
  always finish an action before telling everyone that it happened: for some calls it
  hands out the news from inside the call, so every addon listening reacts while the
  original action is still half-done. Conduit's send loop starts the next mail the
  moment the last one lands, so on a client that behaves that way an eight-mail boon
  run could end up with eight mails' worth of work piled on top of each other, and a
  forty-mail run with forty. That is exactly how another Daseeki addon crashed live
  this week. Conduit now steps off that pile: when it is woken from inside one of its
  own calls it starts the next mail on a fresh, clean footing instead of on top of the
  last one. Every mail still goes out, in the same order, one at a time. And if
  something ever nests deeper than the engine knows how to handle, it now stops and
  says so — naming the build — rather than sending from a place it does not
  understand.

- **The outbound ledger's stamp is now proved to land before the next mail leaves.**
  The ledger is what stops an interrupted run posting the same boons twice when you
  run it again. It has always been written the moment a mail is confirmed, before the
  next one is armed; that ordering is now pinned by a test that reads the ledger from
  *inside* the send of the following mail, under the harsher event timing above.

- **Auto-friend can no longer be knocked out for the rest of the session.** While a
  friend-adding pass is running, a flag stops a second pass starting on top of it. If
  anything went wrong mid-pass, that flag stayed up and auto-friend quietly did
  nothing more until you reloaded. The flag now always comes back down, and the error
  is still reported.

## 1.2.4 — 2026-08-08

- **The one-time Raid Prep import is no longer spent on a login that imported
  nothing.** Conduit imports your Raid Prep "Send Consumes" settings once, the first
  time it sees them. It used to count "I saw Raid Prep's data" as having done the
  import — even when there was nothing there to import yet. If you had built your
  Raid Prep class checklists but not yet set a bank character to mail to, that first
  Conduit login produced no rules and marked the job done anyway. Setting the
  recipient afterwards then imported nothing, ever, with no message and no way to ask
  for it again. Conduit now marks the import done only when it has actually created a
  rule, so whichever order you set things up in, the import is still waiting for you.

- **The alt picker could spell the same alt differently between logins.** When two
  of your accounts — or two records inside one — knew a character under different
  capitalisation ("Bankalt" and "bankalt"), which spelling the picker offered, and
  therefore which spelling went onto the mail form, depended on the order the saved
  table happened to hand its entries over. That order is not stable, so the same
  alt could be addressed one way today and another way tomorrow, and the class
  colour on its row could change with it. The picker now reads the roster in a
  fixed order, so the same alt always resolves to the same name and the same
  colour. Nothing about which alts are offered changes.

- **Auto-friend no longer runs before the game has told it who your friends are.**
  Your friends list lives on the server. For the first seconds after you log in the
  game answers "you have no friends" — not because you have none, but because it has
  not been told yet, and nothing distinguishes the two answers. Conduit used to wait
  ten seconds and then go ahead regardless. On a slow login that meant it read your
  list as empty, decided every mail recipient was a stranger, fired off a burst of
  friend requests for people already on your list, and — worst of all — wrote each
  one down as "handled" in your saved settings. Recipients it failed to add that way
  were never friended again, on that character, in any future session.

  Conduit now *asks* for the list and waits for the game to answer, re-asking at five,
  fifteen and thirty seconds. If the answer never comes, it does nothing at all this
  session and tries again next login. Nothing is decided, nothing is added, and not
  one "handled" mark is written against a list it has not actually seen.

- **And it can now tell "you unfriended them" apart from "our request never landed".**
  It records when it has actually *seen* a recipient on your confirmed list. A
  recipient you remove after that is a deliberate choice and is never re-added — the
  rule that has always applied, now with the evidence to back it.

- **A one-time check on the marks the old behaviour left behind.** On each
  character's first proper pass, Conduit compares its existing "handled" marks
  against your real friends list. Anyone marked and present is confirmed. Anyone
  marked, absent, and never once seen there is genuinely undecidable — either the old
  dark pass stranded them, or you removed them on purpose — so Conduit names them in
  a single line and does nothing. If they were not your doing, `/conduit friends
  reheal` re-checks that exact set and adds each of them once. It only ever adds, it
  never removes anyone, and it is spent after one use.

- **The outbound ledger no longer mistakes a well-stocked alt for a delivered mail.**
  Conduit remembers what it has put in the post so an interrupted run cannot post the
  same boons twice. It used to retire an entry when a later look at the recipient
  showed at least as many boons as the mail carried — which, for anyone already
  holding half a stack, was true the moment they logged in, an hour before the mail
  could possibly arrive. The entry cleared, the top-up looked due again, and a second
  batch went out. Every send now records what that character was holding when the
  mail was built, and the entry only clears when the count has actually *risen* by
  what was sent. Entries written by older builds carry no such record, so they clear
  on the thirty-day mail expiry instead; `/conduit debug boons` names them.

- **One slow moment no longer convinces Conduit your game cannot split stacks.**
  A single stack-split that took longer than a second and a half used to turn off
  exact-quantity mailing for the whole session and tell you "this client will not
  split stacks for the mail" — which was simply untrue on a client that splits fine
  and merely stuttered. Only a `/reload` undid it. A timeout is now read as what it
  is: slowness. Conduit waits longer on the next attempt, and only says your game
  refuses to split after three attempts in a row where the stack demonstrably never
  moved. Opening a mailbox clears the verdict, and `/conduit debug boons unblock`
  clears it on demand.

## 1.2.3 — 2026-08-05

- **Found it. The game was attaching whole stacks, and never said so.** The log you
  sent back settled three rounds of guessing in one read. Every attempt in it was
  identical: Conduit asked the game to split *seven* boons out of a stack of ten
  onto the mail — an unlocked slot, still bags, nothing racing — and the mail came
  back holding **ten**. Exactly what you described watching happen: "the mail
  populated full stacks each time."

  That single behaviour is the whole saga. It is the original over-attach (a
  seven-boon top-up that arrived as two full stacks), and it is every refusal since:
  the safety net was doing its job perfectly, refusing a mail that did not match its
  plan, over and over, on a plan the game could not be made to honour.

  **Conduit no longer asks the mail form to split anything.** It makes the exact
  amount in your *bags* first — where splitting works, the same way you do it by
  hand — and then attaches that stack whole. Whole stacks are the one thing this
  client has always got right; every incident attached them faithfully.

- **One preparation pass, not one per mail.** Everything a run needs is split up
  front in a single sweep, so the mails themselves go straight out afterwards. An
  eight-mail run now posts its last mail in seconds rather than grinding through a
  three-second wait per mail on the way to a refusal.

  Preparation is also skipped entirely where it is not needed: a stack that is
  already the right size is used as it is, and so is any set of stacks that simply
  adds up (a four and a three make a seven, no splitting required).

- **Your bags will look slightly rearranged afterwards, and the run says so.** The
  leftovers from a split stay in your bags as their own stacks — still yours, just
  in new slots. The completion line now mentions it rather than leaving you to
  notice.

- **It stops honestly when it cannot prepare an amount**, and always tells you the
  way round:
    - no empty bag slot to split into → it says so, and which mails it could not
      prepare;
    - the game refusing to split in your bags either → it stops the whole run once,
      with "put a stack of exactly N in your bags and run again", instead of asking
      once per mail and never posting anything.
  In every case the boons stay in your bags. Nothing that was not planned is ever
  attached, and nothing is ever rounded up to a full stack to make a mail go.

- **The send guard now watches the thing that is actually being sent.** The previous
  build judged a mail by how much had left your bags — and your log proves the bags
  do not move at all while an attachment is sitting on the form. That witness read
  zero however much had landed, which is why eight perfectly good mails were refused
  and your outbox came back empty. Conduit now checks what it picked up and what the
  mail form reports (whose shape your log also settled once and for all), and treats
  a bag total that has not moved as "still in your bags" rather than as "nothing
  happened". The guarantee is unchanged and if anything stricter: nothing is sent
  unless what is on the form is exactly what the preview promised.

- **The log covers the new half too.** Every preparation attempt is recorded in the
  same place as the attaches — which slot it split, how much, where it put it,
  whether it landed — so if the bag-to-bag split ever misbehaves the way the
  mail-form one did, the next capture names it immediately instead of costing
  another round.

- **The mails go out.** Two rounds of fixes did not stop boon mails being refused
  with "the form holds 0", and the reason both rounds missed it is worth stating
  plainly: the engine was asking the game a question it had not finished answering.

  After putting items on the Send Mail form, the engine re-read the bag slot it had
  just taken them from, one statement later, to check how many had moved. **This
  client does not update bag counts that quickly** — it defers them to its next bag
  event, the same way it defers releasing the slot locks. So the re-read returned
  the number from *before* the split, the engine concluded that nothing had moved,
  and it refused a mail whose items were sitting correctly on the form. Instantly,
  every mail, first mail included, on perfectly still bags. An entire run confirmed
  nothing.

  The measurement now waits for your bags to agree before it judges anything, and
  asks about the whole mail at once instead of one slot at a time. Nothing is sent
  until what actually left your bags matches what the preview promised — the
  guarantee is unchanged, it is simply no longer being checked against a number the
  game had not written yet.

- **A log you can send me.** Following the owner's ask — "do we need to enable some
  sort of log to catch the issue so we dont continue to iterate on ghost fixes?" —
  Conduit now records the last 40 attach attempts to its saved variables: which bag
  slots it drew from, what each held, whether they were locked, which game call it
  used and what came back, what the form reported (every value, so the shape of an
  undocumented call is settled once and for all), what the bags said, and the
  verdict with its reason. **Every entry is stamped with the build that produced
  it**, so a run on stale code is obvious at a glance instead of costing a round of
  theories. `/conduit debug boons` prints the build and a one-line summary; the
  detail lives in the saved-variables file.

- **The engine stops trusting a guess it cannot check.** The position of the stack
  count in the game's send-slot read is undocumented on this client, so Conduit
  infers it. That inference can now be *wrong* — when it disagrees with the bag
  arithmetic it is discarded and re-learned, rather than being allowed to overrule
  the arithmetic. Previously one bad inference, made once, would quietly refuse
  every mail for the rest of the session.

- **An attach that comes away empty is retried, not skipped.** It used to be
  dropped on the spot, which is precisely wrong for a mail that attached nothing
  only because the bags had not caught up yet.

- **Mails stopped arriving empty.** The first live hands-free boon run refused its
  whole tail: "Daseeki's mail should carry 3 Chronoboon Displacer but the form
  holds 0", and the same for the two after it, all inside one second. The safety
  net worked exactly as intended — nothing was over-mailed and every boon stayed in
  the bags — but nothing was *sent* either.

  The cause was speed. Hands-free starts the next mail the instant the last one is
  confirmed, and at that moment the game has not finished putting the bags down:
  the slots are still locked, and a locked slot makes the game's own "split this
  stack" call do nothing at all — no error, no explanation. So the attach came away
  empty-handed and the guard, correctly, refused to send an empty mail. The retry
  half a second later did not wait for anything either, so it hit the same locked
  bags and produced the same refusal.

  Three changes, so this cannot come back in another disguise:
  - **The run now waits for your bags to stop moving before it attaches anything.**
    It watches for the game's own "that's the last of the bag changes" signal, and
    gives up waiting after one second so a quiet client can never hang the run.
    Step mode waits too — clicking fast hits the identical race.
  - **Where the items come from is worked out fresh for every single mail.** The
    plan decides *how many* a character gets; it no longer decides *which bag slot
    they come out of*, because those coordinates go stale the moment anything moves
    — and in a batch, something moves after every mail.
  - **A split that the game half-completes is never re-asked.** If the stack left
    the slot but has not reached the cursor yet, asking again would take a second
    helping; the engine now recognises that state, takes nothing, and lets the
    settle-and-retry do its job.

- **`/conduit debug boons` now shows what the client actually did.** The failure
  above was invisible from chat — every mail simply said "the form holds 0". The
  debug view now reports mails armed, draws re-derived, stale coordinates, splits
  asked for versus delivered versus refused, draws blocked by a locked slot, how
  often the run waited for the bags and how often that wait timed out. If something
  like this happens again it will be one line to capture rather than a mystery.

- **The send guard now has the last word from the form itself.** As well as
  checking what the attach believes it staged, the engine sums what the Send Mail
  form actually reports across its slots and refuses if that disagrees with the
  plan. (The game does not document how it reports that number on this client, so
  the engine works it out from a landing it can independently verify rather than
  guessing.)

## 1.2.0 — merged 2026-08-05, superseded before release

- **A boon mail can no longer carry more than it was planned to.** A live run
  planned seven Chronoboon Displacers for one character and put **two whole stacks
  of ten** on the Send Mail form — twenty boons, sixty copper of postage, and
  nothing in the addon noticing. The attach worked out how many it wanted, called
  the game's split-or-pickup, checked only that the attachment slot was no longer
  empty, and then wrote down the number it had *asked* for. It never asked the form
  what had actually landed. Worse, the same code deliberately fell back to picking
  up the **whole stack** whenever it could not split — so a seven-unit top-up drawn
  across two slots quietly became twenty.

  The attach now reads the amount back off the form and puts anything that is not
  exactly what was asked for straight back in the bag. There is no rounding up: a
  top-up that cannot be split exactly sends nothing rather than sending a whole
  stack. And on top of that, **nothing is sent at all until what the form holds
  matches what the plan says** — if they ever disagree the mail is refused in plain
  language and the run moves on. Leaving boons behind is a nuisance; posting ten of
  them to the wrong character is not.

- **One click sends the whole batch.** Conduit used to ask you to click "Send Next"
  for every single mail, on the belief that the game required a real button press
  per send. It does not — not on Classic Era. Accept the preview once and the run
  sends itself: one mail at a time, each one waiting for the server to confirm the
  last before the next goes out, with a live progress line and a **Stop** button on
  the panel for the whole run.

  Every mail is confirmed twice over — the server's acknowledgement, *and* the
  attachments or gold actually leaving — before the next one starts. If either
  answer fails to arrive within fifteen seconds the run stops with a report and
  hands everything back; it never wedges in a state that needs a UI reload. A mail
  that fails is retried once and then that recipient is skipped by name, so one bad
  address no longer costs you the other nine mails. Closing the mailbox mid-run
  stops it dead. If you would rather drive each mail yourself, **Settings ->
  Sending -> "One mail per click"** puts the old behaviour back.

- **An interrupted run no longer re-mails what it already sent.** Cross-realm and
  cross-account mail takes an hour to arrive, so for that hour Nexus still shows a
  character holding what they held *before* your top-up — which meant a run that
  stopped half-way and was started again would happily post the first few mails a
  second time. Conduit now keeps a record of what it has confirmed sending and
  treats it as already owned: the preview says "has 9, 1 in transit — nothing to
  send", and a run stopped at two of eight plans **six** when you come back, not
  eight. Entries clear themselves as soon as Nexus sees the boons arrive, and expire
  after thirty days regardless. `/conduit debug boons` shows the plan and everything
  currently in the post, with ages; `/conduit debug boons clear` empties it.

- **The Replenish Boons button works at the mailbox it was greyed out at.** Open a
  mailbox on your boon source and the button was as likely as not to sit greyed and
  unclickable for the whole visit, with the panel cheerfully reading "Ready." The
  panel was deciding whether a mailbox was open a beat before the game had finished
  opening it, and nothing ever asked again. It now watches the mail window itself
  rather than guessing from the event, so the button is armed whenever the mailbox
  actually is.

- **A greyed button now says why.** Hovering Replenish Boons when it will not fire
  tells you which gate is shut — no mailbox open, Conduit disabled on this
  character, or a send already running — instead of leaving you to guess at a
  button that just refuses.

- **A settings gear in the panel header, and both header icons in the suite's
  style.** The Conduit panel's ✕ was a plain letter X; it is now the same close
  glyph Nexus, Bags and Raid Prep wear, with a settings gear beside it that opens
  Conduit's page in the Daseeki hub — the same place `/conduit settings` goes. Both
  icons are the same size, aligned to the panel's right edge, and light up on hover
  exactly like their counterparts elsewhere in the suite.

## 1.1.0 — 2026-08-05

- **Chronoboon replenishment.** Nominate one character as your boon source, and at
  any mailbox on that character a single button tops every level-60 character in
  your Nexus mesh back up to ten Chronoboon Displacers. It works out who is short
  from the counts Nexus already keeps — one has three, one has nine, one has none,
  so seven, one and ten go out — and mails each of them exactly what they are
  missing, in one mail apiece.

  Nothing leaves without you seeing it first. The confirm screen lists every
  character, the amount going to each, what they were last known to be holding,
  and **how old that count is**, because a character you have not logged into for
  four days may have burned every boon since. A character Nexus has never seen the
  bags of says so in as many words rather than quietly reading as empty.

  If your bags cannot cover everybody, the character on zero is filled before the
  character on nine, the shortfall is stated on the confirm screen before you
  accept and again when the run finishes, and nobody is dropped from the list just
  because there was nothing left for them. Counts come from Nexus and include the
  bank, so a character with a drawer full of boons banked reads as stocked — the
  button's tooltip and the settings hint both say so.

  Set the source under **Chronoboon Replenishment** in `/conduit`; the picker lists
  your characters in their class colours, the same as the rule editor's Alt picker,
  and includes the character you are standing on. On every other character the
  panel simply says who does the sending. Without Daseeki Nexus, or before it has
  scanned anything, the feature says what it needs instead of guessing. Until you
  nominate a source, the panel looks exactly as it did before.

## 1.0.1 — 2026-08-04

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
