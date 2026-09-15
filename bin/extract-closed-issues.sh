#!/usr/bin/env bash
# Extract issue-closing references from a PR body (reporulez#71 ask C).
#
# GitHub's own `Closes #N` auto-close only fires when the PR carrying it
# is merged into the DEFAULT branch. reporulez#71 puts everything on
# `dev` first, so nothing closes the linked issue until the next `dev ->
# main` promotion -- convention 6 says close it by hand today; this
# script is the parsing half of the workflow
# (.github/workflows/close-linked-issues.yml) that stops that being
# manual.
#
# Usage:
#   extract-closed-issues.sh --repo <owner/repo> < pr-body.txt
#   extract-closed-issues.sh --repo <owner/repo> <path-to-pr-body-file>
#
# --repo is the PR's OWN owner/repo. It decides whether an EXPLICIT
# "owner/repo#N" reference that happens to name the PR's own repo is
# reported as same-repo (rather than cross-repo) -- see the JSON shape
# below.
#
# Prints one line of JSON to stdout:
#   {"same_repo": [1, 5], "cross_repo": [{"repo": "other/thing", "number": 9}]}
# same_repo is a sorted, deduplicated list of issue numbers in the PR's
# own repo. cross_repo is a sorted, deduplicated list of {repo, number}
# for every reference to another repo's issue. Exit 0 always for a
# readable body (including an empty one -- zero linked issues is a
# normal, common outcome for a PR, not an error); exit 2 for a usage
# error or an unreadable input, matching this repo's die()-uses-2
# convention (bin/validate-ruleset.sh, bin/check-dependabot-target.sh) --
# NEVER a silent empty result on an input this script could not read.
#
# Recognized forms, each requiring a closing keyword immediately before
# the reference (case-insensitive; an optional ":" or "-" between keyword
# and reference is tolerated, e.g. "Closes: #12" or "Fixes - #12"):
#   close, closes, closed / fix, fixes, fixed / resolve, resolves, resolved
# followed by:
#   #123                                        (same repo as --repo)
#   owner/repo#123                              (explicit repo)
#   https://github.com/owner/repo/issues/123    (full URL)
#
# Deliberate scope limits, not oversights:
#   - Only the reference DIRECTLY after a keyword counts. "Closes #1, #2"
#     closes only #1 -- GitHub's own linking does not chain a bare #N
#     after a keyword-qualified one into an additional close-trigger, and
#     guessing that a comma-separated #2 was meant to close too is
#     exactly the kind of silent-widening this script should not do on
#     its own authority.
#   - Only the PR body is read, not the title or commit messages.
#     GitHub's real auto-close is driven by the PR body (or, for a direct
#     push to the default branch, commit messages) -- there is no "commit
#     messages of a squash-merged PR" case here since this script never
#     sees git history, only the PR body text the workflow hands it.
#   - Text inside fenced code blocks (``` ... ```) is stripped before
#     matching, so a PR body that SHOWS "Closes #12" as a formatted
#     example of the convention (e.g. in a doc-only PR) does not itself
#     trigger a close.
#   - A reference wrapped in inline code (`#12`, single backticks) does
#     NOT count as a close, even though the surrounding text isn't
#     stripped. This is an ASSUMPTION, not a citation (unlike the fenced-
#     block behavior above, which is this script's own deliberate choice
#     either way): whether GitHub's PR-body renderer autolinks an issue
#     reference inside a single-backtick code span is not verified here.
#     The conservative reading was picked deliberately -- under-closing
#     is recoverable by hand, over-closing on an unconfirmed rendering
#     assumption is not. Revisit if GitHub documents the actual behavior,
#     or if this causes a real miss.

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }

usage() {
  sed -n '2,17p' "$0" | sed 's/^# //; s/^#//'
}

REPO=""
BODY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires an owner/repo argument"
      REPO="$2"; shift 2 ;;
    *)
      [[ -z "$BODY_FILE" ]] || die "unexpected extra argument: $1"
      BODY_FILE="$1"; shift ;;
  esac
done

command -v python3 >/dev/null || die "python3 not found"

if [[ -n "$BODY_FILE" ]]; then
  [[ -f "$BODY_FILE" ]] || die "no such file: $BODY_FILE"
  BODY_TEXT="$(cat "$BODY_FILE")" || die "failed to read $BODY_FILE"
else
  BODY_TEXT="$(cat)" || die "failed to read PR body from stdin"
fi

PY_PROGRAM="$(mktemp)"
trap 'rm -f "$PY_PROGRAM"' EXIT

cat > "$PY_PROGRAM" <<'PYEOF'
import json, re, sys

own_repo = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
body = sys.stdin.read()

KEYWORD = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
REPO_RE = r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"
REF = (
    rf"(?:(?P<repo>{REPO_RE})#(?P<num>\d+)"
    rf"|#(?P<num2>\d+)"
    rf"|https?://github\.com/(?P<urlrepo>{REPO_RE})/issues/(?P<num3>\d+))"
)
PATTERN = re.compile(rf"\b{KEYWORD}\b\s*[:\-]?\s*{REF}", re.IGNORECASE)
FENCE = re.compile(r"```.*?```", re.DOTALL)

stripped = FENCE.sub("", body)

same_repo = set()
cross_repo = set()

for m in PATTERN.finditer(stripped):
    if m.group("repo"):
        repo, num = m.group("repo"), int(m.group("num"))
    elif m.group("urlrepo"):
        repo, num = m.group("urlrepo"), int(m.group("num3"))
    else:
        repo, num = None, int(m.group("num2"))

    if repo is None or (own_repo is not None and repo.lower() == own_repo.lower()):
        same_repo.add(num)
    else:
        cross_repo.add((repo, num))

print(json.dumps({
    "same_repo": sorted(same_repo),
    "cross_repo": [
        {"repo": r, "number": n}
        for r, n in sorted(cross_repo, key=lambda t: (t[0].lower(), t[1]))
    ],
}))
PYEOF

printf '%s' "$BODY_TEXT" | python3 "$PY_PROGRAM" "$REPO"
