#!/usr/bin/env bash
# Fixture-driven regression suite for bin/extract-closed-issues.sh
# (reporulez#71, ask C).
#
# Same harness shape as tests/test-validate-ruleset.sh and
# tests/test-check-dependabot-target.sh: this repo ships no test
# framework, so this script IS the acceptance test the PR's red-before-
# green pass runs against, and it is what .github/workflows/test.yml
# invokes so a future regression breaks CI, not just a human's local run.
#
# Usage: tests/test-extract-closed-issues.sh
# Exit: 0 if every case matches its expected exit code and output, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTRACT="$REPO_ROOT/bin/extract-closed-issues.sh"

PASS=0
FAIL=0

# assert_json <name> <expected_exit> <pr-body> <expected_json>
# Feeds <pr-body> to the script on stdin with --repo thrillmade/reporulez,
# and does an EXACT string comparison against <expected_json> (the script
# emits one deterministic, sorted JSON line, so exact-match is the right
# assertion here, not a substring grep like the other suites use).
assert_json() {
  local name="$1" expected_exit="$2" body="$3" expected="$4"
  local output exit_code
  output="$(printf '%s' "$body" | "$EXTRACT" --repo thrillmade/reporulez 2>&1)"
  exit_code=$?

  local ok=1
  if [[ "$exit_code" -ne "$expected_exit" ]]; then
    ok=0
    echo "FAIL: $name -- expected exit $expected_exit, got $exit_code"
    echo "  output: $output"
  elif [[ "$expected" != "-" && "$output" != "$expected" ]]; then
    ok=0
    echo "FAIL: $name"
    echo "  expected: $expected"
    echo "  got:      $output"
  fi

  if [[ "$ok" -eq 1 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

# --- same-repo, single keyword forms ------------------------------------

assert_json "closes #N" 0 \
  "This PR closes #12." \
  '{"same_repo": [12], "cross_repo": []}'

assert_json "close #N (no s)" 0 \
  "Should close #4 once merged." \
  '{"same_repo": [4], "cross_repo": []}'

assert_json "closed #N (past tense)" 0 \
  "Closed #4 in this change." \
  '{"same_repo": [4], "cross_repo": []}'

assert_json "fix / fixes / fixed all recognized" 0 \
  "fix #1. Also fixes #2 and this fixed #3 previously." \
  '{"same_repo": [1, 2, 3], "cross_repo": []}'

assert_json "resolve / resolves / resolved all recognized" 0 \
  "resolve #1, resolves #2, resolved #3" \
  '{"same_repo": [1, 2, 3], "cross_repo": []}'

assert_json "case-insensitive keyword" 0 \
  "CLOSES #7" \
  '{"same_repo": [7], "cross_repo": []}'

assert_json "colon after keyword tolerated" 0 \
  "Closes: #8" \
  '{"same_repo": [8], "cross_repo": []}'

assert_json "dash after keyword tolerated" 0 \
  "Fixes - #9" \
  '{"same_repo": [9], "cross_repo": []}'

# --- cross-repo forms ----------------------------------------------------

assert_json "owner/repo#N shorthand is cross-repo" 0 \
  "Fixes thrillmade/other-repo#5" \
  '{"same_repo": [], "cross_repo": [{"repo": "thrillmade/other-repo", "number": 5}]}'

assert_json "full github.com issue URL is cross-repo" 0 \
  "Resolved https://github.com/thrillmade/other-repo/issues/42" \
  '{"same_repo": [], "cross_repo": [{"repo": "thrillmade/other-repo", "number": 42}]}'

assert_json "explicit owner/repo#N naming THIS repo counts as same-repo, not cross-repo" 0 \
  "Closes thrillmade/reporulez#3" \
  '{"same_repo": [3], "cross_repo": []}'
# The --repo the script is invoked with in this suite is always
# thrillmade/reporulez -- an explicit self-reference must fold into
# same_repo so the caller doesn't need a special case for "cross-repo
# syntax that happens to mean this repo".

assert_json "explicit repo match is case-insensitive" 0 \
  "Closes ThrillMade/RepoRulez#3" \
  '{"same_repo": [3], "cross_repo": []}'

# --- must NOT trigger: bare mentions, no keyword -------------------------

assert_json "bare #N with no keyword is a mention, not a close" 0 \
  "See #12 for background; this PR does not close it." \
  '{"same_repo": [], "cross_repo": []}'

assert_json "empty PR body -> nothing found, exit 0 (not an error -- most PRs close nothing)" 0 \
  "" \
  '{"same_repo": [], "cross_repo": []}'

# --- must NOT trigger: only the FIRST reference after a keyword counts --

assert_json "comma-separated second reference after one keyword is NOT auto-included" 0 \
  "Closes #1, #2" \
  '{"same_repo": [1], "cross_repo": []}'
# Deliberate scope limit (see the script's own header comment): GitHub's
# real linking does not chain a bare #N after a keyword-qualified one into
# a second close-trigger, and this script does not guess that it should.

# --- must NOT trigger: fenced code blocks are stripped -------------------

assert_json "keyword+ref shown as a formatted example inside a code fence is ignored" 0 \
"$(printf 'Use this convention:\n```\nCloses #99\n```\nThe real one: fixes #7')" \
  '{"same_repo": [7], "cross_repo": []}'

assert_json "inline-code-wrapped reference does NOT count as a close (conservative, unverified-assumption case -- see script header)" 0 \
  'Closes `#12` (written with inline code formatting)' \
  '{"same_repo": [], "cross_repo": []}'

# --- dedup -----------------------------------------------------------------

assert_json "duplicate references to the same issue are deduplicated" 0 \
  "closes #5, also closes #5 again, and Closed #5" \
  '{"same_repo": [5], "cross_repo": []}'

assert_json "multiple cross-repo dupes across different keyword forms dedup too" 0 \
  "fixes thrillmade/x#1 and later resolved thrillmade/x#1" \
  '{"same_repo": [], "cross_repo": [{"repo": "thrillmade/x", "number": 1}]}'

# --- output is sorted, not insertion-order --------------------------------

assert_json "same_repo numbers are sorted ascending regardless of mention order" 0 \
  "closes #9, fixes #2, resolves #5" \
  '{"same_repo": [2, 5, 9], "cross_repo": []}'

# --- usage / input errors: exit 2, never a silent empty result -----------
# These don't go through assert_json (it hardcodes --repo) -- direct
# invocation instead, same shape as the other suites' assert_case.

assert_case() {
  local name="$1" expected_exit="$2" pattern="$3"
  shift 3
  local output exit_code
  output="$("$@" 2>&1)"
  exit_code=$?
  local ok=1
  if [[ "$exit_code" -ne "$expected_exit" ]]; then
    ok=0
    echo "FAIL: $name -- expected exit $expected_exit, got $exit_code"
    echo "  output: $output"
  fi
  if [[ "$pattern" != "-" ]] && ! grep -qF -- "$pattern" <<< "$output"; then
    ok=0
    echo "FAIL: $name -- output did not contain: $pattern"
    echo "  output: $output"
  fi
  if [[ "$ok" -eq 1 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

assert_case "--repo with no value errors (exit 2)" 2 \
  "requires an owner/repo argument" \
  "$EXTRACT" --repo

assert_case "nonexistent body-file path errors (exit 2), not a silent empty result" 2 \
  "no such file" \
  "$EXTRACT" --repo thrillmade/reporulez "$SCRIPT_DIR/fixtures/does-not-exist.txt"

echo
echo "$PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
