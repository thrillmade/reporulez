#!/usr/bin/env bash
# Regression suite for the write paths of bin/apply-org.sh and
# bin/ensure-dev-branch.sh, and for bin/audit.sh's failed-read handling.
#
# No case here talks to GitHub. Each case puts a fake `gh` first on PATH that
# records every API call (method and path) to a log and answers only what the
# case scripted. A case asserts on three things: the exit code, the printed
# lines, and the recorded calls -- so "the dry run made no write call" is a
# fact read from the log, not a claim.
#
# Usage: tests/test-org-scripts.sh
# Exit: 0 if every case passes, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLY_ORG="$REPO_ROOT/bin/apply-org.sh"
ENSURE_DEV="$REPO_ROOT/bin/ensure-dev-branch.sh"
AUDIT="$REPO_ROOT/bin/audit.sh"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the fake gh ---------------------------------------------------------
#
# Responses live in a tab-separated file, one per line:
#   METHOD <TAB> PATH <TAB> EXIT <TAB> BODY-FILE <TAB> STDERR
# A call with no scripted response fails with a status that is NOT 404, so an
# unscripted read can never be mistaken for "missing".
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
[[ "${1:-}" == "auth" ]] && exit 0
[[ "${1:-}" == "api" ]] || { echo "fake gh: unsupported command: $*" >&2; exit 99; }
shift
method="GET"; path=""; jqexpr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method|-X) method="$2"; shift 2 ;;
    --jq|-q) jqexpr="$2"; shift 2 ;;
    --input|-f|-F|-H) shift 2 ;;
    --paginate|--silent) shift ;;
    -*) echo "fake gh: unsupported flag: $1" >&2; exit 99 ;;
    *) path="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$path" >> "$FAKE_GH_LOG"
line="$(awk -F'\t' -v m="$method" -v p="$path" '$1 == m && $2 == p { print; exit }' "$FAKE_GH_RESPONSES")"
if [[ -z "$line" ]]; then
  echo "gh: fake: no response scripted for $method $path (HTTP 599)" >&2
  exit 1
fi
IFS=$'\t' read -r _ _ code body err <<< "$line"
if [[ "$code" -ne 0 ]]; then
  [[ -n "$err" ]] && echo "$err" >&2
  exit "$code"
fi
if [[ "$body" != "-" ]]; then
  if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" "$FAKE_GH_DIR/$body"; else cat "$FAKE_GH_DIR/$body"; fi
fi
exit 0
FAKE_GH
chmod +x "$WORK/bin/gh"

CASE_N=0
# new_case: a fresh response table and call log for the next case.
new_case() {
  CASE_N=$((CASE_N + 1))
  export FAKE_GH_DIR="$WORK/case-$CASE_N"
  mkdir -p "$FAKE_GH_DIR"
  export FAKE_GH_RESPONSES="$FAKE_GH_DIR/responses.tsv"
  export FAKE_GH_LOG="$FAKE_GH_DIR/calls.log"
  : > "$FAKE_GH_RESPONSES"
  : > "$FAKE_GH_LOG"
}

# respond <method> <path> <exit> <json-body|-> [stderr]
respond() {
  local method="$1" path="$2" code="$3" body="$4" err="${5:-}"
  local file="-"
  if [[ "$body" != "-" ]]; then
    file="body-$(wc -l < "$FAKE_GH_RESPONSES" | tr -d ' ').json"
    printf '%s\n' "$body" > "$FAKE_GH_DIR/$file"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$method" "$path" "$code" "$file" "$err" >> "$FAKE_GH_RESPONSES"
}

# run <cmd...>: runs with the fake gh first on PATH; sets OUT and CODE.
run() {
  OUT="$(PATH="$WORK/bin:$PATH" "$@" 2>&1)"
  CODE=$?
}

record() {
  local name="$1" ok="$2" why="$3"
  if [[ "$ok" -eq 1 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name -- $why"
    echo "  output: $OUT"
    echo "  calls:  $(tr '\n' ';' < "$FAKE_GH_LOG")"
  fi
}

expect_exit() { [[ "$CODE" -eq "$2" ]]; record "$1" $(( $? == 0 )) "expected exit $2, got $CODE"; }
expect_out() { grep -qF -- "$2" <<< "$OUT"; record "$1" $(( $? == 0 )) "output did not contain: $2"; }
expect_no_out() { ! grep -qF -- "$2" <<< "$OUT"; record "$1" $(( $? == 0 )) "output contained: $2"; }
expect_call() { grep -qxF -- "$2" "$FAKE_GH_LOG"; record "$1" $(( $? == 0 )) "no recorded call: $2"; }
expect_no_call() { ! grep -qxF -- "$2" "$FAKE_GH_LOG"; record "$1" $(( $? == 0 )) "unexpected recorded call: $2"; }
writes() { grep -cvE '^GET ' "$FAKE_GH_LOG" || true; }
expect_writes() { local n; n="$(writes)"; [[ "$n" -eq "$2" ]]; record "$1" $(( $? == 0 )) "expected $2 write call(s), recorded $n"; }

# ========================================================================
# bin/apply-org.sh
# ========================================================================

STAGING="$REPO_ROOT/rulesets/org-staging.json"
BASELINE="$REPO_ROOT/rulesets/org-baseline.json"
LIST_ONE='[{"id":111,"name":"org-staging"},{"id":222,"name":"org-baseline"}]'

# as_live <preset-file> [jq-edit]: the preset as GitHub returns it, with the
# read-only fields an apply never sends, and an optional edit applied.
as_live() {
  jq -c "(. + {id: 111, node_id: \"RRS_x\", source_type: \"Organization\", source: \"acme\",
          created_at: \"2026-01-01T00:00:00Z\", updated_at: \"2026-01-01T00:00:00Z\"})
         | ${2:-.}" "$1"
}

# Every shipped org preset compared with itself-as-live is "no difference":
# the normaliser drops only what an apply never sends.
for f in "$REPO_ROOT"/rulesets/org-*.json; do
  variant="$(basename "$f" .json)"
  name="$(jq -r .name "$f")"
  new_case
  respond GET orgs/acme/rulesets 0 "$(jq -cn --arg n "$name" '[{id: 111, name: $n}]')"
  respond GET orgs/acme/rulesets/111 0 "$(as_live "$f")"
  run "$APPLY_ORG" acme "$variant"
  expect_exit "apply-org $variant: preset vs identical live exits 0" 0
  expect_out "apply-org $variant: says no difference" "no difference"
  expect_writes "apply-org $variant: no write call" 0
done

# Dry run with a difference: exit 1, prints it, writes nothing.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING" '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = 1')"
run "$APPLY_ORG" acme org-staging
expect_exit "apply-org dry run with a difference exits 1" 1
expect_out "apply-org dry run prints the difference header" "difference: live ruleset 'org-staging' (id=111)"
expect_out "apply-org dry run prints the live side of the changed line" '-        "required_approving_review_count": 1'
expect_out "apply-org dry run prints the preset side of the changed line" '+        "required_approving_review_count": 0'
expect_writes "apply-org dry run makes no write call" 0

# Dry run where --apply would refuse: says so, still writes nothing.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING" '.bypass_actors += [{actor_id: 42, actor_type: "Team", bypass_mode: "pull_request"}]')"
run "$APPLY_ORG" acme org-staging
expect_exit "apply-org dry run of a loosening preset exits 1" 1
expect_out "apply-org dry run warns that --apply would refuse" "would remove live bypass actor Team/42"
expect_writes "apply-org dry run of a loosening preset makes no write call" 0

# --apply on a preset that would remove a live bypass actor: refused, no write.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING" '.bypass_actors += [{actor_id: 42, actor_type: "Team", bypass_mode: "pull_request"}]')"
respond PUT orgs/acme/rulesets/111 0 '{}'
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply removing a live bypass actor exits 2" 2
expect_out "apply-org --apply names the removed bypass actor" "refused: would remove live bypass actor Team/42"
expect_writes "apply-org --apply removing a live bypass actor makes no write call" 0

# --apply --allow-loosening on the same: exactly one PUT, to the right id.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING" '.bypass_actors += [{actor_id: 42, actor_type: "Team", bypass_mode: "pull_request"}]')"
respond PUT orgs/acme/rulesets/111 0 '{}'
run "$APPLY_ORG" acme org-staging --apply --allow-loosening
expect_exit "apply-org --apply --allow-loosening exits 0" 0
expect_writes "apply-org --apply --allow-loosening makes exactly one write call" 1
expect_call "apply-org --apply --allow-loosening PUTs the live ruleset's id" "PUT orgs/acme/rulesets/111"
expect_out "apply-org --apply --allow-loosening reports what it applied" "applied: preset 'org-staging' to live ruleset 'org-staging' (id=111)"

# --apply on a difference that loosens nothing (the preset ADDS a bypass
# actor live lacks): writes without --allow-loosening.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING" '.bypass_actors |= map(select(.actor_type != "Integration"))')"
respond PUT orgs/acme/rulesets/111 0 '{}'
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply with a non-loosening difference exits 0" 0
expect_call "apply-org --apply with a non-loosening difference PUTs" "PUT orgs/acme/rulesets/111"
expect_writes "apply-org --apply with a non-loosening difference writes once" 1

# --apply with no difference writes nothing.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING")"
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply with no difference exits 0" 0
expect_writes "apply-org --apply with no difference makes no write call" 0

# --apply that would change a bypass mode from pull_request to always.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/222 0 "$(as_live "$BASELINE" '.id = 222 | .bypass_actors |= map(.bypass_mode = "pull_request")')"
run "$APPLY_ORG" acme org-baseline --apply
expect_exit "apply-org --apply weakening pull_request to always exits 2" 2
expect_out "apply-org --apply names the weakened bypass mode" "refused: would change bypass actor RepositoryRole/5 from pull_request to always"
expect_writes "apply-org --apply weakening a bypass mode makes no write call" 0

# --apply that would remove a ref target.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING" '.conditions.ref_name.include += ["refs/heads/release"]')"
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply removing a ref target exits 2" 2
expect_out "apply-org --apply names the removed ref target" "refused: would remove ref target refs/heads/release"
expect_writes "apply-org --apply removing a ref target makes no write call" 0

# --apply that would remove a rule.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING" '.rules += [{type: "non_fast_forward"}]')"
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply removing a rule exits 2" 2
expect_out "apply-org --apply names the removed rule" "refused: would remove rule non_fast_forward"
expect_writes "apply-org --apply removing a rule makes no write call" 0

# Two live rulesets with one name: refused, before any detail read or write.
new_case
respond GET orgs/acme/rulesets 0 '[{"id":111,"name":"org-staging"},{"id":333,"name":"org-staging"}]'
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING")"
respond PUT orgs/acme/rulesets/111 0 '{}'
run "$APPLY_ORG" acme org-staging --apply --allow-loosening
expect_exit "apply-org with two live rulesets of one name exits 2" 2
expect_out "apply-org with two live rulesets of one name says so" "2 live rulesets in 'acme' are named 'org-staging'"
expect_writes "apply-org with two live rulesets of one name makes no write call" 0

# A failed live list read: refused, never treated as "nothing is live".
new_case
respond GET orgs/acme/rulesets 1 - "gh: Not Found (HTTP 404)"
respond POST orgs/acme/rulesets 0 '{}'
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org with a failed live list read exits 2" 2
expect_out "apply-org with a failed live list read says it could not read" "could not read the live rulesets for org 'acme'"
expect_writes "apply-org with a failed live list read makes no write call" 0

# A failed live detail read: refused.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 1 - "gh: Server Error (HTTP 500)"
respond PUT orgs/acme/rulesets/111 0 '{}'
run "$APPLY_ORG" acme org-staging --apply --allow-loosening
expect_exit "apply-org with a failed live detail read exits 2" 2
expect_out "apply-org with a failed live detail read says so" "could not read live ruleset 'org-staging' (id=111)"
expect_writes "apply-org with a failed live detail read makes no write call" 0

# No live ruleset of that name: the dry run reports a create and writes
# nothing; --apply POSTs once.
new_case
respond GET orgs/acme/rulesets 0 '[{"id":222,"name":"org-baseline"}]'
respond POST orgs/acme/rulesets 0 '{}'
run "$APPLY_ORG" acme org-staging
expect_exit "apply-org dry run of a missing ruleset exits 1" 1
expect_out "apply-org dry run of a missing ruleset says --apply would create it" "--apply would CREATE it"
expect_writes "apply-org dry run of a missing ruleset makes no write call" 0
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply of a missing ruleset exits 0" 0
expect_call "apply-org --apply of a missing ruleset POSTs to the org" "POST orgs/acme/rulesets"
expect_writes "apply-org --apply of a missing ruleset writes exactly once" 1

# ========================================================================
# bin/ensure-dev-branch.sh
# ========================================================================

repo_json() { jq -cn --arg b "${2:-main}" --argjson a "${3:-false}" --argjson f "${4:-false}" \
  --arg n "$1" '{full_name: $n, default_branch: $b, archived: $a, fork: $f}'; }

# A table covering every per-repo outcome.
script_mixed_org() {
  respond GET repos/acme/has-dev 0 "$(repo_json acme/has-dev)"
  respond GET repos/acme/has-dev/branches/dev 0 '{"name":"dev"}'
  respond GET repos/acme/no-dev 0 "$(repo_json acme/no-dev)"
  respond GET repos/acme/no-dev/branches/dev 1 - "gh: Branch not found (HTTP 404)"
  respond GET repos/acme/no-dev/git/ref/heads/main 0 '{"object":{"sha":"abc1234def"}}'
  respond POST repos/acme/no-dev/git/refs 0 '{}'
  respond GET repos/acme/dev-read-fails 0 "$(repo_json acme/dev-read-fails)"
  respond GET repos/acme/dev-read-fails/branches/dev 1 - "gh: Server Error (HTTP 500)"
  respond POST repos/acme/dev-read-fails/git/refs 0 '{}'
  respond GET repos/acme/old 0 "$(repo_json acme/old main true false)"
  respond GET repos/acme/old/branches/dev 1 - "gh: Branch not found (HTTP 404)"
  respond GET repos/acme/forked 0 "$(repo_json acme/forked main false true)"
  respond GET repos/acme/forked/branches/dev 1 - "gh: Branch not found (HTTP 404)"
  respond GET repos/acme/forked/git/ref/heads/main 0 '{"object":{"sha":"fff0000aaa"}}'
  respond POST repos/acme/forked/git/refs 0 '{}'
  respond GET repos/acme/unreadable 1 - "gh: Server Error (HTTP 502)"
}
MIXED=(acme/has-dev acme/no-dev acme/dev-read-fails acme/old acme/forked acme/unreadable)

new_case; script_mixed_org
run "$ENSURE_DEV" "${MIXED[@]}"
expect_writes "ensure-dev dry run makes no write call" 0
expect_out "ensure-dev dry run prints all five counts" "Summary: 0 created, 1 already-present, 1 would-create, 2 skipped, 2 failed"
expect_out "ensure-dev reports a failed dev read as could-not-read, not missing" "✗ acme/dev-read-fails: could not read branches/dev (not treated as missing)"
expect_no_out "ensure-dev never reports a failed dev read as would-create" "would-create acme/dev-read-fails"
expect_out "ensure-dev skips archived repos" "- acme/old: skipped (archived)"
expect_out "ensure-dev skips forks by default" "- acme/forked: skipped (fork"
expect_exit "ensure-dev dry run with failures exits 2" 2

new_case; script_mixed_org
run "$ENSURE_DEV" "${MIXED[@]}" --apply
expect_call "ensure-dev --apply creates dev where it was a 404" "POST repos/acme/no-dev/git/refs"
expect_no_call "ensure-dev --apply does not create dev where the read failed" "POST repos/acme/dev-read-fails/git/refs"
expect_no_call "ensure-dev --apply does not create dev on a skipped fork" "POST repos/acme/forked/git/refs"
expect_writes "ensure-dev --apply writes exactly once" 1
expect_out "ensure-dev --apply counts the create" "Summary: 1 created, 1 already-present, 0 would-create, 2 skipped, 2 failed"
expect_exit "ensure-dev --apply with failures exits 2" 2

# Forks are checked with --include-forks.
new_case; script_mixed_org
run "$ENSURE_DEV" acme/forked --apply --include-forks
expect_call "ensure-dev --include-forks creates dev on a fork" "POST repos/acme/forked/git/refs"
expect_exit "ensure-dev --include-forks with a clean create exits 0" 0

# Every create fails: counted, and the exit is non-zero with or without --strict.
new_case
respond GET repos/acme/no-dev 0 "$(repo_json acme/no-dev)"
respond GET repos/acme/no-dev/branches/dev 1 - "gh: Branch not found (HTTP 404)"
respond GET repos/acme/no-dev/git/ref/heads/main 0 '{"object":{"sha":"abc1234def"}}'
respond POST repos/acme/no-dev/git/refs 1 - "gh: Resource not accessible by integration (HTTP 403)"
run "$ENSURE_DEV" acme/no-dev --apply --strict
expect_out "ensure-dev counts a failed create as failed" "Summary: 0 created, 0 already-present, 0 would-create, 0 skipped, 1 failed"
expect_exit "ensure-dev --apply --strict with a failed create exits non-zero (2)" 2
run "$ENSURE_DEV" acme/no-dev --apply
expect_exit "ensure-dev --apply with a failed create exits non-zero (2) without --strict too" 2

# Clean runs: 0, and --strict fails only when a repo still lacks dev.
new_case
respond GET repos/acme/has-dev 0 "$(repo_json acme/has-dev)"
respond GET repos/acme/has-dev/branches/dev 0 '{"name":"dev"}'
respond GET repos/acme/no-dev 0 "$(repo_json acme/no-dev)"
respond GET repos/acme/no-dev/branches/dev 1 - "gh: Branch not found (HTTP 404)"
run "$ENSURE_DEV" acme/has-dev acme/no-dev
expect_exit "ensure-dev dry run with no failures exits 0" 0
run "$ENSURE_DEV" acme/has-dev acme/no-dev --strict
expect_exit "ensure-dev --strict exits 1 when a repo still lacks dev" 1
run "$ENSURE_DEV" acme/has-dev --strict
expect_exit "ensure-dev --strict exits 0 when every repo has dev" 0

# --all: enumerates, then skips per repo; a failed listing is exit 2.
new_case; script_mixed_org
respond GET 'orgs/acme/repos?per_page=100' 0 '[{"full_name":"acme/has-dev"},{"full_name":"acme/old"},{"full_name":"acme/forked"}]'
run "$ENSURE_DEV" --all acme
expect_out "ensure-dev --all skips archived and forks it enumerated" "Summary: 0 created, 1 already-present, 0 would-create, 2 skipped, 0 failed"
expect_exit "ensure-dev --all with no failures exits 0" 0
new_case
respond GET 'orgs/acme/repos?per_page=100' 1 - "gh: Server Error (HTTP 500)"
run "$ENSURE_DEV" --all acme
expect_exit "ensure-dev --all with a failed listing exits 2" 2
expect_out "ensure-dev --all with a failed listing says so" "could not list repos under acme"

# The default-branch warning says what is true for that branch.
new_case
respond GET repos/acme/trunk 0 "$(repo_json acme/trunk trunk)"
respond GET repos/acme/trunk/branches/dev 0 '{"name":"dev"}'
respond GET repos/acme/devdefault 0 "$(repo_json acme/devdefault dev)"
respond GET repos/acme/devdefault/branches/dev 0 '{"name":"dev"}'
run "$ENSURE_DEV" acme/trunk
expect_out "ensure-dev warns that a non-main default branch gets production rules" "'trunk' ALSO gets production rules"
expect_no_out "ensure-dev does not claim org-staging applies to a default branch that is not dev" "org-staging"
run "$ENSURE_DEV" acme/devdefault
expect_out "ensure-dev warns that a dev default branch stacks on org-staging" "on top of org-staging"
expect_writes "ensure-dev never writes on a default-branch warning" 0

# ========================================================================
# bin/audit.sh
# ========================================================================

GOOD_SETTINGS='{"allow_auto_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'

# Control: the fixture really does produce "no drift" when every read works.
new_case
respond GET repos/acme/fine 0 "$GOOD_SETTINGS"
run "$AUDIT" acme/fine
expect_exit "audit with a readable, conformant repo exits 0 (control)" 0
expect_out "audit with a readable, conformant repo says no drift (control)" "no drift detected"

new_case
respond GET repos/acme/fine 0 "$GOOD_SETTINGS"
respond GET repos/acme/broken 1 - "gh: Server Error (HTTP 500)"
run "$AUDIT" acme/fine acme/broken
expect_exit "audit with a failed repo read exits 2" 2
expect_out "audit with a failed repo read says could not audit" "could not audit"
expect_no_out "audit with a failed repo read never says no drift" "no drift"

new_case
respond GET repos/acme/fine 0 "$GOOD_SETTINGS"
respond GET 'repos/acme/fine/rulesets?includes_parents=true' 1 - "gh: Server Error (HTTP 500)"
run "$AUDIT" acme/fine --include-ruleset
expect_exit "audit with a failed ruleset listing exits 2" 2
expect_no_out "audit with a failed ruleset listing never says no drift" "no drift"

new_case
respond GET 'orgs/acme/repos?per_page=100' 1 - "gh: Server Error (HTTP 500)"
run "$AUDIT" --all acme
expect_exit "audit --all with a failed listing exits 2" 2
expect_out "audit --all with a failed listing says could not audit" "could not audit"
expect_writes "audit never writes" 0

echo
echo "$PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
