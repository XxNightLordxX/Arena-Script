# Before we delete anything

**For:** John Allday
**About:** stripping Crimson Arena down for production
**Status:** nothing has been deleted yet. This is the list of things I am
sure about, the list of things I am not, and how I am proving that nothing
important goes missing.

---

## The test I am applying

Your words: *does this need to be in there, and would someone who does not
know how to code need this information.*

That answers most of it cleanly:

* A person who does not write code **opens `config.lua`** and nothing else.
  So `config.lua` keeps its explanations — rewritten short, in plain words,
  saying what a setting does and what you may write in it.
* A person who does not write code **never opens `server/match.lua`**. So
  the commentary in the code files goes.
* Nothing in the resource folder is read by the game except the code itself.
  Comments and tests cost the server nothing at runtime — they are for
  people, and if no person is going to read them, they are just weight.

---

## What I am doing without asking

| # | Action | Why I am sure |
|---|---|---|
| 1 | Delete the whole `tests/` folder (77 spec files) | The game never loads it. It is not shipped, not required, and every version of it stays in the repository's history for ever. |
| 2 | Delete `.luacheckrc` | It configures a code checker used only while developing. |
| 3 | Remove every comment from `client/`, `server/`, `shared/`, `html/` | A non-coder never opens these files. |
| 4 | Rewrite `config.lua`'s comments to operator language | Currently 2,241 lines of comment around 689 lines of settings — 76% of the file. Most of it explains *why a decision was made*, which is a developer's question, not yours. |
| 5 | Keep `README.md`, `DEPLOYMENT.md`, `STREAMING.md`, `LICENSE.md` | These are the operator's documentation. Written for you, not for a developer. |
| 6 | Keep `locales/en.json` | Every sentence a player is shown. Deleting it would break the resource. |
| 7 | Confirm nothing anywhere credits anybody but you | Already true — I checked the whole tree and every commit. It becomes a standing check so it stays true. |

---

## How I prove nothing was lost — four independent checks

Any one of these could be wrong on its own. The point of having four is that
they are wrong in **different** ways, so a mistake that slips past one is
caught by another. All four must pass before anything is committed.

### 1. The Lua code is provably identical

Every `.lua` file is compiled before and after, with all debug information
stripped, and the resulting machine instructions are compared byte for byte.

*Why this is strong:* stripping debug information throws away line numbers
and formatting. What is left is only what the machine will actually run.
Deleting a comment cannot change it. Deleting a single character of real
code always does.

*Tool:* `tools/verify_lua_identical.sh`

### 2. The panel's code is provably identical

`app.js`, `style.css` and `index.html` are read as a stream of tokens —
names, numbers, text, punctuation — and the two streams are compared.

*Why this is strong:* the reader that produces the token stream is written
**separately** from the thing that removes the comments, and it works out
where a comment ends by itself. If the remover ever ate a line of real code,
the two streams stop matching and it says exactly where.

*Tool:* `tools/verify_web_identical.py`

### 3. Nothing the server depends on went missing

A list is taken before and after of everything the outside world can touch:
every function, every export other resources call, every event, every
command, every line of player-facing text, every setting name, and every
element the panel looks up. The two lists are compared line by line.

*Why this is strong:* it is written in your terms, not in code terms. A
failure reads *"this setting is gone"*, not *"a checksum changed"*, and the
number it counts is only ever compared against itself — a run before and a run
after, on the same tree. **Against the code as it ships today it is 994
entries** (`python3 tools/inventory.py Crimson-Arena | wc -l`, run against
this commit). It was 972 when this paragraph was written and 983 at the strip
below; the surface has grown since, which is what those three numbers are
saying. What matters is that a before and an after of the same change agree,
not that any of them is a round number.

*Tool:* `tools/inventory.py`

### 4. The tests are run against the stripped code — before they are deleted

The order matters. Comments come out first, the full suite runs against the
stripped resource, and **only then** are the tests removed. So the code that
ships has been proven working by the very tests being retired, rather than
by the ones that existed before the change.

*Tool:* the existing `tests/run.sh` — 77 spec files, roughly five minutes.
(**77 is the count, and it is the most there ever were.** This document said
96 in four places; no commit in the history has ever carried more than 77
`*_spec.lua` files. Corrected rather than left, because the number is the
only thing telling you whether the folder you are about to delete is the
whole suite.)

### All four, run for real — before anything was deleted

I copied the resource to a scratch folder, stripped the comments out of the
copy, and ran the four checks against it. Nothing in your repository was
touched. Results:

| check | result |
|---|---|
| 1. Lua instructions | **PASS** — 18 files, 0 changed |
| 2. Panel tokens | **PASS** — 3 files, 0 changed |
| 3. Dependency surface | **PASS** — 983 entries before, 983 after, 0 lost. *(983 is what the tree held on the day of the strip; it is 994 today. The check is a before against an after of the same change, so the count moving since does not weaken the result above.)* |
| 4. Tests against stripped code | 76 of 77 spec files pass — see below |

**Run again, on the real strip.** The table above is the first dry run, which
removed *every* comment. Re-run against the strip you actually chose — the
one that keeps warning blocks — checks 1, 2 and 3 pass identically, and check
4 comes back **76 of 77 with a different single failure**: `configmap_spec`,
because `config.lua` carries a line-numbered map of itself at the top and
stripping moves those lines. That map is regenerated as part of the strip and
the spec passes again.

`unrestorable_spec` — the one failure in the table above, the test that
asserts a particular comment still exists — **now passes**, because the
warning-block rule kept the comment it guards. That is the clearest evidence
I have that the rule is drawing the line in the right place.

**Check 1 was wrong, and running it is how I found out.** My first version
compared the compiled files byte for byte. That reports a difference for a
*pure comment removal*, because Lua records the line range each function was
defined over and removing a comment above it moves those lines. A check that
cries wolf is not a check. It now compares the instructions with the line
numbers taken out, and I confirmed it still catches a real change (`a + 1`
changed to `a + 2` produces a different result).

**Check 4's one failure is worth your attention.** `unrestorable_spec.lua`
fails on the stripped copy — not because any code broke, but because that
test asserts a **comment still exists** in `client/dispatch.lua`. Its own
words:

> *"The rule above is only enforceable if the reasoning survives next to it.
> A test that fails with no explanation in the file it guards is a test
> somebody deletes."*

So the codebase itself already decided, at least once, that a particular
comment was load-bearing enough to guard with a test. That is direct
evidence for Doubt 1 below rather than my opinion of it.

### And the thing behind all four

Every version of every file stays in the repository's history. Nothing is
ever truly gone: any file, at any point in time, can be brought back with one
command. The four checks above are about catching a mistake *before* it
ships; the history is what makes even a missed one recoverable.

---

## What I am NOT sure about — please decide

> **DECIDED.** You said: *do all your recommendations in before we delete
> md.* So every option marked **recommended** below is what was built. The
> six doubts are left as they were written, each with a note underneath
> saying what actually happened. One of them did not land where I said it
> would, and that note says so.


### Doubt 1 — the warnings inside the code (my biggest one)

There are about **609 comment lines** outside `config.lua` that are not
explanations at all. They are warnings aimed at whoever edits the file next,
and each one exists because something specific went wrong once.

Three real examples, shortened:

> *"The money rule and the leaderboard rule disagree ON PURPOSE, and that is
> the thing to keep in mind before tidying either of them into the other."*

> *"1 IntersectWorld, 2 IntersectVehicles, 16 IntersectObjects. Not 4 (peds)
> and not 8 (ragdolls)"* — the wrong value here shipped once, under a comment
> that claimed the opposite.

> *"This does not go through oxDid, which treats a nil return as success —
> a reasonable rule elsewhere and the wrong one here. The cost of being wrong
> in this direction is a loud log line. The cost of being wrong in the other
> direction is somebody's belongings."*

**Cost of removing them:** you, or anyone you hire later, can undo a fix
without knowing there was one. Several of these mark bugs that took a long
time to find.

**Cost of keeping them:** roughly 609 lines in files a non-coder will never
open. They do not affect the running server at all.

**My recommendation:** keep them, and delete everything else. It is about 3%
of the current commentary and it is the only part that protects the work.

- [ ] Remove them too — I want the code files completely bare
- [x] **Keep them** — done
- [ ] Keep them, but move them out into a separate `NOTES.md` instead

**How that is enforced, since "keep the warnings" is not something a text
search can do.** `tools/strip_prod.py` treats a *run of comment lines* as one
unit and keeps or drops the whole run on whether anything in it warns. That
matters: a warning is usually one sentence inside a paragraph, and keeping
that sentence while deleting the six lines around it leaves a fragment worse
than either answer.

### Doubt 2 — `REFERENCE.md`

A 646-line map of the codebase: every file, every function, what each one
does. Written for a developer.

**Keeping it** costs nothing and helps anyone who ever works on this.
**Deleting it** removes a file that is now unverifiable — the test that kept
it honest is one of the tests being deleted, so from that moment on it can
quietly drift out of date and mislead.

- [ ] Delete it
- [x] **Keep it, with a line saying it is a snapshot and may drift** — done
- [ ] Keep it and I will maintain it

### Doubt 3 — one line at the top of each code file

Something like `-- Crimson Arena: the match itself. Rounds, kills, endings.`

Nine words per file. Not for the game — for whoever opens the folder and
wants to know which file does what.

- [x] **Yes, keep a one-line header on each file** — done
- [ ] No, strip them completely bare

They are written out by hand in `tools/strip_all.sh`, one per file, because
no rule derived from a filename can say what a file is for.

### Doubt 4 — `config.weapons.lua`

1,137 lines listing every weapon on your server, generated from your own
`ox_inventory` weapons file. Its header explains **how it was generated and
how to regenerate it when you add a weapon**.

That is operator information, not developer information — but it sits in a
file that looks like code.

- [x] **Keep that header** — done. `config.weapons.lua` lost 22 lines out of
      1,137; the regeneration instructions survived intact.
- [ ] Strip it like the rest

### Doubt 5 — `fxmanifest.lua`

110 comment lines in the file FiveM itself reads. Some explain load order,
which matters if you ever add a file.

- [x] **Cut it right down to a few practical lines** — done, 167 lines to 85.
      Rewritten by hand rather than stripped, because what is practical here
      (load order, why oxmysql is deliberately absent, why there is no
      `stream/` folder) is not what a warning-matching rule would have kept.
- [ ] Strip it completely
- [ ] Leave it as it is

### Doubt 6 — how far `config.lua` should go

Currently every setting has a paragraph. My plan is: one or two plain
sentences saying what it does and what you may write, and nothing about why
it was chosen or what it used to be.

Example of the change:

**Now — 14 lines:**
> *LIVES PER PLAYER. 1 = eliminated on the first death… Three changes how a
> round feels more than any other number here: a single unlucky opening
> exchange no longer ends somebody's match… ONLY 'last_standing' SPENDS
> THEM. Both of the other win conditions end on a COUNT… Set a plain number
> here instead — `lives = 3` — to fix it for every match…*

**After — 4 lines:**
> *How many times a player can die before they are out. Only used when the
> win condition is "last one standing" — the other two never eliminate
> anybody. Write a plain number instead of the block to fix it for everyone.*

That would take `config.lua` from roughly 3,117 lines to about 1,100.

- [x] **That is the right level** — done, but it landed at **2,396 lines,
      not 1,100**, and you should know why before you decide it is wrong.
      *(2,396 was the count on the day. It is **2,457** now, and every line
      of the growth is comment — no setting was added or removed. Most of it
      is corrections: two notes had to go in because the shorter version was
      actively wrong, an empty `adminGroups` locking you out rather than
      letting everyone in, and `outsideTicks = 0` reading as the harshest
      possible setting rather than as off.)*
- [ ] Go shorter still — one sentence each
- [ ] Keep more than that

**Where the estimate went wrong.** 1,100 was measured against a *full* strip
of `config.lua` — every comment gone. What you chose in Doubt 1 is the
opposite of that for anything carrying a warning, and `config.lua` is where
most of the warnings live: don't put valuables in `neverStash`, keep the two
bet ceilings level, `default` must be one of the `options`, a boundary must
contain its own floor. Those are the paragraphs an operator most needs and
the ones a shorter file would have lost.

So the rewrite did what Doubt 6 describes — every setting now says what it
does and what you may write, and the history of why a number changed is
gone — and the warnings stayed. Of its 2,457 lines, 191 are blank and about seven
hundred are settings; the rest is that.

If you want it shorter, the next thing to cut is the warnings, and that is
Doubt 1 again rather than this one. Say the word and I will do it — but I
would be cutting the part I recommended keeping.

**One thing about this file is proven rather than claimed.** Its compiled
instructions were compared before and after, and the only difference in the
whole file is the bet ceiling in decision 6 of `EXPLOITS-YOUR-CALL.md` —
50,000 to 25,000, which was a deliberate change. Nothing else about how the
arena behaves moved by so much as a constant.

---

## What I need from you

Tick a box in each of the six sections above, or just tell me *"defaults"*
and I will take every option marked **recommended**.

Nothing is deleted until you say so.
