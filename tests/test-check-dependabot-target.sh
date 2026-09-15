#!/usr/bin/env bash
# Fixture-driven regression suite for bin/check-dependabot-target.sh
# (reporulez#71, ask B).
#
# Same harness shape as tests/test-validate-ruleset.sh (reporulez#68): this
# repo ships no test framework, so this script IS the acceptance test the
# PR's red-before-green pass runs against, and it is what
# .github/workflows/test.yml invokes so a future regression breaks CI, not
# just a human's local run.
#
# Usage: tests/test-check-dependabot-target.sh
# Exit: 0 if every case matches its expected exit code and output, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$REPO_ROOT/bin/check-dependabot-target.sh"
FIXTURES="$SCRIPT_DIR/fixtures/dependabot"

PASS=0
FAIL=0

# assert_case <name> <expected_exit> <grep_pattern|-> -- <cmd...>
# Same contract as test-validate-ruleset.sh's helper: runs the command,
# checks the exit code, and (if a pattern was given) greps combined
# stdout+stderr for it.
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

  if [[ "$ok" -eq 1 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

# --- clean inputs: exit 0 --------------------------------------------

assert_case "all entries targeting dev passes" 0 \
  "all updates entries target" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"

assert_case "stdin mode ('-') works" 0 \
  "all updates entries target" \
  bash -c "cat '$FIXTURES/all-target-dev.yml' | '$CHECK' -"

assert_case "real reporulez file WOULD pass once fixed the same way clud-bug#340 fixed it" 0 \
  "all updates entries target" \
  "$CHECK" "$FIXTURES/real-reporulez-fixed.yml"

# --- the exact defect class reporulez#71 names: partial compliance ----

assert_case "3 entries, only 2 carry target-branch: dev -- must fail, not pass" 1 \
  "target-branch=(absent), want 'dev'" \
  "$CHECK" "$FIXTURES/missing-target-on-one-of-three.yml"

assert_case "target-branch present but wrong value is flagged, not just absence" 1 \
  "target-branch='main', want 'dev'" \
  "$CHECK" "$FIXTURES/wrong-target-branch.yml"

# --- control test: reporulez's OWN live dependabot.yml, copied verbatim
# from origin/main the day this check was built (see the fixture's header
# comment for provenance) -- a known-real violation, not a fixture the
# check was fitted to. ------------------------------------------------

assert_case "reporulez's own live dependabot.yml (as of writing) fails this check" 1 \
  "package-ecosystem='github-actions' target-branch=(absent)" \
  "$CHECK" "$FIXTURES/real-reporulez-missing-target.yml"

# --- "examines nothing must not exit 0" (reporulez#71's own words) ----
# Three shapes of "found nothing to examine", each its own fixture so a
# mutation handling only one shape is still caught by the others.

assert_case "no 'updates' key at all errors (exit 2), not a silent pass" 2 \
  "nothing to check" \
  "$CHECK" "$FIXTURES/no-updates-key.yml"

assert_case "'updates: []' (empty list) errors (exit 2), not a silent pass" 2 \
  "nothing to check" \
  "$CHECK" "$FIXTURES/empty-updates-list.yml"

assert_case "malformed YAML errors (exit 2), not a silent pass" 2 \
  "could not parse" \
  "$CHECK" "$FIXTURES/malformed.yml"

assert_case "valid YAML that isn't a mapping errors (exit 2), not a silent pass" 2 \
  "not a mapping" \
  "$CHECK" "$FIXTURES/not-a-mapping.yml"

assert_case "nonexistent file path errors (exit 2), not a silent pass" 2 \
  "no such file" \
  "$CHECK" "$FIXTURES/does-not-exist.yml"

assert_case "no arguments at all errors (exit 2), not a silent pass" 2 \
  "-" \
  "$CHECK"

# --- --all mode: "examines zero repos must not exit 0" ----------------
# A bogus/nonexistent org is the deliberately-broken fixture for this
# guard (no local file shape can exercise it -- enumeration is a live API
# call by design, same as bin/audit.sh's --all).

assert_case "--all against an org with zero (reachable) repos errors (exit 2), not a silent pass" 2 \
  "examined zero repos" \
  "$CHECK" --all "thrillmade-org-that-does-not-exist-in-this-test-namespace"

assert_case "--all requires an owner argument" 2 \
  "-" \
  "$CHECK" --all

# --- --target lets the required branch be overridden -------------------

assert_case "--target overrides the required branch name" 0 \
  "all updates entries target \"main\"" \
  bash -c "cat '$FIXTURES/wrong-target-branch.yml' | '$CHECK' --target main -"
# wrong-target-branch.yml's one entry targets "main" -- with --target main
# instead of the default "dev", that becomes the correct value, proving
# the flag actually changes what's required rather than just being parsed
# and ignored.

# --- argument validation -----------------------------------------------

assert_case "--repo requires owner/repo form" 2 \
  "owner/repo form" \
  "$CHECK" --repo not-a-valid-repo-slug

assert_case "--repo and a path are mutually exclusive" 2 \
  "mutually exclusive" \
  "$CHECK" --repo thrillmade/reporulez "$FIXTURES/all-target-dev.yml"

echo
echo "$PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
