#!/usr/bin/env bash
# Fixture-driven regression suite for bin/validate-ruleset.sh (reporulez#68).
#
# This repo ships no test framework (AGENTS.md: "There is no test suite" —
# `test.yml` lints syntax, it does not exercise behavior). This script fills
# that gap for validate-ruleset.sh specifically: it is the acceptance test
# the mutation pass in the PR description runs against, and it is the thing
# `.github/workflows/test.yml` now invokes so a future regression breaks CI,
# not just a human's local run.
#
# Usage: tests/test-validate-ruleset.sh
# Exit: 0 if every case matches its expected exit code and output, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$REPO_ROOT/bin/validate-ruleset.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

# assert_case <name> <expected_exit> <grep_pattern|-> -- <cmd...>
# Runs the command, checks the exit code, and (if a pattern was given)
# greps combined stdout+stderr for it. Never lets a failing `bin/*.sh`
# under `set -e` kill this runner: `|| true` on the capture.
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

# --- valid inputs: exit 0, no violation lines --------------------------

assert_case "valid-full fixture passes" 0 \
  "is valid" \
  "$VALIDATOR" "$FIXTURES/valid-full.json"

assert_case "repo admin bypass without OrganizationAdmin, no deletion rule, is not flagged" 0 \
  "is valid" \
  "$VALIDATOR" "$FIXTURES/partial-role-bypass-safe.json"
# partial-role-bypass-safe.json HAS a deletion rule (RepositoryRole admin
# only, no OrganizationAdmin) -- see the bypass-defeats-deletion-restriction
# section below for why that combination is still safe under this check.

# Every SHIPPED ruleset must itself pass the validator (reporulez PR #69,
# panel finding 1). Before this loop, only org-baseline.json had an explicit
# case here -- baseline.json / clud-bug.json / public-guard.json / skdd.json
# were never exercised. That gap is exactly how admin-bypass-required shipped
# in the same PR as three rulesets that fail it outright: apply.sh's own
# flagless Quickstart default (baseline) POSTs rulesets/baseline.json's
# bypass_actors unmodified, and nothing here would have caught the
# collision. Loop over every file under rulesets/ rather than naming them,
# so a FUTURE variant added without a qualifying admin bypass fails this
# test too, not just the ones that exist today.
for f in "$REPO_ROOT"/rulesets/*.json; do
  assert_case "$(basename "$f") (shipped ruleset) passes the validator" 0 \
    "is valid" \
    "$VALIDATOR" "$f"
done

assert_case "stdin mode ('-') works" 0 \
  "is valid" \
  bash -c "cat '$FIXTURES/valid-full.json' | '$VALIDATOR' -"

# --- integration-id-pin (SPEC section 6.3) ------------------------------

assert_case "missing integration_id on clud-bug-review is flagged" 1 \
  "[integration-id-pin]" \
  "$VALIDATOR" "$FIXTURES/missing-integration-id.json"

assert_case "wrong integration_id on clud-bug-review is flagged" 1 \
  "expected 3944857" \
  "$VALIDATOR" "$FIXTURES/wrong-integration-id.json"

assert_case "real skdd.json (has the correct pin) does not trip integration-id-pin" 0 \
  "is valid" \
  "$VALIDATOR" "$REPO_ROOT/rulesets/skdd.json"
# skdd.json ships a correctly-pinned clud-bug-review context AND (as of the
# admin-bypass-required fix below) a baked-in Repository admin bypass, so
# it's fully valid standalone -- not just "doesn't trip integration-id-pin
# while still failing something else". The case above (missing/wrong pin)
# asserts the check fires when it should; this asserts the real shipped file
# doesn't false-positive on it.

# --- admin-bypass-required (SPEC section 6.6) ---------------------------

assert_case "empty bypass_actors is flagged" 1 \
  "[admin-bypass-required]" \
  "$VALIDATOR" "$FIXTURES/missing-bypass.json"

assert_case "omitted bypass_actors key is flagged (not a jq crash)" 1 \
  "[admin-bypass-required]" \
  "$VALIDATOR" "$FIXTURES/no-bypass-actors-key.json"

# --- bypass-defeats-deletion-restriction (this repo's own rule) --------
#
# bypass-defeats-deletion.json is not a hypothetical: its bypass_actors and
# rules are copied field-for-field from the LIVE `org-staging` ruleset on
# thrillmade/agent-skills (read via `gh api repos/thrillmade/agent-skills
# /rulesets/<id>`, read-only, while building this check) -- the actual
# incident this rule exists for. This is the control test the task asked
# for: a known-non-zero case, not just a hand-built fixture the check was
# fitted to.

assert_case "bypass covering repo admin + OrganizationAdmin defeats deletion rule (real incident shape)" 1 \
  "[bypass-defeats-deletion-restriction]" \
  "$VALIDATOR" "$FIXTURES/bypass-defeats-deletion.json"

assert_case "deletion rule with only admin bypass is not flagged" 0 \
  "is valid" \
  "$VALIDATOR" "$FIXTURES/valid-full.json"

# reporulez PR #69 panel finding 3: the check used to require BOTH
# RepositoryRole admin AND OrganizationAdmin before firing, which under-fired
# -- an OrganizationAdmin-only always-bypass on a deletion rule passed clean,
# and that was this repo's OWN shipped rulesets/org-baseline.json. GitHub
# gives every org owner admin access to every repo in the org unconditionally
# (cited in the script's header comment), so OrganizationAdmin alone is
# already enough; RepositoryRole admin no longer needs to co-occur.

assert_case "OrganizationAdmin bypass ALONE (no RepositoryRole admin) defeats a deletion rule" 1 \
  "[bypass-defeats-deletion-restriction]" \
  "$VALIDATOR" "$FIXTURES/orgadmin-only-defeats-deletion.json"
# This is the exact shape rulesets/org-baseline.json shipped with before
# this PR's fix (see the loop above, which now passes because org-baseline.json
# was switched to a RepositoryRole admin bypass instead).

assert_case "OrganizationAdmin bypass without a deletion rule at all is not flagged" 0 \
  "is valid" \
  "$VALIDATOR" "$FIXTURES/orgadmin-no-deletion-rule-safe.json"
# Control for the "and a deletion rule is present" half of the condition --
# without this case, a mutation that drops the deletion-rule check entirely
# (firing on OrganizationAdmin alone regardless of rules) would go
# undetected.

# --- multiple violations at once ----------------------------------------

assert_case "multiple violations are all reported, count line is correct" 1 \
  "2 violation(s) found" \
  "$VALIDATOR" "$FIXTURES/multi-violation.json"

# --- input errors: exit 2, never 0 (bar: "must ERROR, not pass") -------

assert_case "nonexistent file path errors (exit 2), not a silent pass" 2 \
  "-" \
  "$VALIDATOR" "$FIXTURES/does-not-exist.json"

assert_case "malformed JSON errors (exit 2), not a silent pass" 2 \
  "not valid JSON" \
  "$VALIDATOR" "$FIXTURES/malformed.json"

assert_case "empty stdin errors (exit 2), not a silent pass" 2 \
  "-" \
  bash -c "printf '' | '$VALIDATOR' -"

assert_case "no arguments at all errors (exit 2), not a silent pass" 2 \
  "-" \
  "$VALIDATOR"

echo
echo "$PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
