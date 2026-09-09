#!/usr/bin/env bash
# Crimson Arena: nobody but the owner is credited, anywhere.
#
# BEFORE-WE-DELETE.md item 7 promised this would "become a standing check so it
# stays true". This is that check. Run it before every commit. Exit 0 = clean.
#
# Four parts, because they fail in four different ways: a name can arrive in a
# shipped file, in a commit message, in the author/committer fields, or in a
# trailer -- and a trailer does not show up in a scan of the message body.
set -uo pipefail
cd "$(dirname "$0")/.."

OWNER_NAME="John Allday"
OWNER_MAIL="jlwood17190665@gmail.com"
ALT_NAME="XxNightLordxX"                       # the owner's own GitHub account
ALT_MAIL="johnathon19066541895@gmail.com"
OWNER='John Allday|jlwood17190665|XxNightLordxX|johnathon19066541895'

# Names of tools and assistants. None of these may appear as an author.
PAT='claude|anthropic|copilot|chatgpt|openai|gpt-4|assisted by|written by an ai|\bai assistant\b'

# TWO DELIBERATE EXEMPTIONS, both agreed with the owner:
#   1. The branch name contains one of these words. It is pre-existing, it is
#      not repository content, and it cannot be changed without orphaning the
#      pull request. Occurrences are erased before matching, not whitelisted by
#      filename, so a real mention on the same line is still caught.
#   2. A Co-Authored-By naming the OWNER is not a second author. Twenty-one
#      commits carry one. Rewriting 334 commits to drop them would cost more
#      than it buys; a FOREIGN name in one is the thing that must never appear,
#      and part 4 tests exactly that.
BRANCH='claude/fivem-qbox-arena-script-vmoiqt'

fail=0
say() { printf '%s\n' "$*"; }
scrub() { sed "s|$BRANCH||g"; }

say "== 1. working tree =="
hits=$(grep -rniE "$PAT" --exclude-dir=.git --exclude=verify_credit.sh . 2>/dev/null | scrub | grep -iE "$PAT")
if [ -n "$hits" ]; then say "FAIL - shipped files mention somebody else:"; say "$hits"; fail=1
else say "PASS - no file credits anyone but the owner"; fi

say ""
say "== 2. commit messages =="
hits=$(git log --all --format='%B' 2>/dev/null | scrub \
       | grep -viE "^(co-authored-by|signed-off-by).*($OWNER)" | grep -niE "$PAT")
if [ -n "$hits" ]; then say "FAIL - a commit message mentions somebody else:"; say "$hits"; fail=1
else say "PASS - $(git rev-list --all --count) commit messages, none credit anyone but the owner"; fi

say ""
say "== 3. authorship =="
bad=$(git log --all --format='%an <%ae>|%cn <%ce>' 2>/dev/null | grep -vE "($OWNER)" )
if [ -n "$bad" ]; then say "FAIL - a commit is authored or committed by somebody else:"; say "$bad"; fail=1
else say "PASS - every commit is authored and committed by the owner"; fi

say ""
say "== 4. trailers =="
foreign=$(git log --all --format='%B' 2>/dev/null \
          | grep -iE '^(co-authored-by|signed-off-by|on-behalf-of|reviewed-by)' \
          | grep -viE "($OWNER)")
if [ -n "$foreign" ]; then say "FAIL - a trailer credits somebody who is not the owner:"; say "$foreign"; fail=1
else
    n=$(git log --all --format='%B' 2>/dev/null | grep -ciE '^co-authored-by')
    say "PASS - no trailer credits anyone but the owner ($n self-credit trailers, harmless)"
fi

say ""
[ "$fail" -eq 0 ] && say "ALL CLEAR - the work is credited to $OWNER_NAME and nobody else." \
                  || say "NOT CLEAR - fix the failures above before committing."
exit $fail
