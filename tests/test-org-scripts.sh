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
PROTECTION="$REPO_ROOT/rulesets/org-default-protection.json"
CI_MUST_PASS="$REPO_ROOT/rulesets/org-ci-must-pass.json"
LIST_ONE='[{"id":111,"name":"org-staging"},{"id":222,"name":"org-baseline"}]'
EVERY_FLAG=(--apply --allow-weakening --allow-bypass-removal)

# as_live <preset-file> [jq-edit]: the preset as GitHub returns it, with the
# read-only fields an apply never sends, and an optional edit applied.
as_live() {
  jq -c "(. + {id: 111, node_id: \"RRS_x\", source_type: \"Organization\", source: \"acme\",
          created_at: \"2026-01-01T00:00:00Z\", updated_at: \"2026-01-01T00:00:00Z\"})
         | ${2:-.}" "$1"
}

# sandbox <variant> <jq-edit>: a copy of bin/ and rulesets/ for this case in
# which the preset for <variant> carries the edit. Prints the copy's
# apply-org.sh. Used where the PRESET must differ from what is live.
sandbox() {
  local dir="$FAKE_GH_DIR/sandbox"
  mkdir -p "$dir"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/rulesets" "$dir/"
  jq "$2" "$REPO_ROOT/rulesets/$1.json" > "$dir/rulesets/$1.json"
  echo "$dir/bin/apply-org.sh"
}

# script_live <variant> [live-edit]: live has one ruleset of the preset's
# name (id 111), as the preset with an optional edit; PUT and POST succeed.
script_live() {
  local f="$REPO_ROOT/rulesets/$1.json" name
  name="$(jq -r .name "$f")"
  respond GET orgs/acme/rulesets 0 "$(jq -cn --arg n "$name" '[{id: 111, name: $n}]')"
  respond GET orgs/acme/rulesets/111 0 "$(as_live "$f" "${2:-.}")"
  respond PUT orgs/acme/rulesets/111 0 '{}'
  respond POST orgs/acme/rulesets 0 '{}'
}

# Every shipped org preset compared with itself-as-live is "no difference":
# the normaliser drops only what an apply never sends.
for f in "$REPO_ROOT"/rulesets/org-*.json; do
  variant="$(basename "$f" .json)"
  new_case; script_live "$variant"
  run "$APPLY_ORG" acme "$variant"
  expect_exit "apply-org $variant: preset vs identical live exits 0" 0
  expect_out "apply-org $variant: says no difference" "no difference"
  expect_writes "apply-org $variant: no write call" 0
done

# There are five org presets, and apply-org.sh accepts each by name.
ORG_PRESET_COUNT="$(ls "$REPO_ROOT"/rulesets/org-*.json | wc -l | tr -d ' ')"
[[ "$ORG_PRESET_COUNT" -eq 5 ]]; record "five org presets ship" $(( $? == 0 )) "found $ORG_PRESET_COUNT"

# Dry run with a difference: exit 1, prints it and its kind, writes nothing.
new_case; script_live org-staging '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = 1'
run "$APPLY_ORG" acme org-staging
expect_exit "apply-org dry run with a difference exits 1" 1
expect_out "apply-org dry run prints the difference header" "difference: live ruleset 'org-staging' (id=111)"
expect_out "apply-org dry run prints the live side of the changed line" '-        "required_approving_review_count": 1'
expect_out "apply-org dry run prints the preset side of the changed line" '+        "required_approving_review_count": 0'
expect_out "apply-org dry run names the kind of change" "weakens: would change pull_request.required_approving_review_count from 1 to 0"
expect_out "apply-org dry run says which flag --apply would need" "--apply would refuse this without --allow-weakening."
expect_writes "apply-org dry run makes no write call" 0

# --- what --apply alone may write: changes that only tighten ---------------
#
# Each row: <variant> <live edit> <the tightens line>. The preset is the
# shipped one; live is made looser, so the preset tightens it.
TIGHTENINGS=(
  "org-default-protection%.enforcement = \"evaluate\"%raises enforcement from evaluate to active"
  "org-default-protection%.enforcement = \"disabled\"%raises enforcement from disabled to active"
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.required_approving_review_count) = 0%raises pull_request.required_approving_review_count from 0 to 1"
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.require_code_owner_review) = false%turns pull_request.require_code_owner_review on"
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.allowed_merge_methods) += [\"merge\"]%removes merge from pull_request.allowed_merge_methods"
  "org-default-protection%.rules |= map(select(.type != \"required_linear_history\"))%adds rule required_linear_history"
  "org-default-protection%.conditions.ref_name.include -= [\"refs/heads/main\"]%adds refs/heads/main to conditions.ref_name.include"
  "org-default-protection%.conditions.ref_name.exclude += [\"refs/heads/old\"]%removes refs/heads/old from conditions.ref_name.exclude"
  "org-default-protection%.conditions.repository_name.exclude += [\"some-repo\"]%removes some-repo from conditions.repository_name.exclude"
  "org-ci-must-pass%.rules[0].parameters.required_status_checks = []%adds required status check ci"
  "org-ci-must-pass%.rules[0].parameters.do_not_enforce_on_create = true%turns required_status_checks.do_not_enforce_on_create off"
)
for row in "${TIGHTENINGS[@]}"; do
  IFS='%' read -r variant edit want <<< "$row"
  new_case; script_live "$variant" "$edit"
  run "$APPLY_ORG" acme "$variant" --apply
  expect_exit "apply-org --apply alone, tightening ($want), exits 0" 0
  expect_out "apply-org --apply alone names the tightening ($want)" "tightens: $want"
  expect_call "apply-org --apply alone, tightening ($want), PUTs" "PUT orgs/acme/rulesets/111"
  expect_writes "apply-org --apply alone, tightening ($want), writes once" 1
  expect_no_out "apply-org --apply alone, tightening ($want), refuses nothing" "refused:"
done

# --- what --apply alone refuses: anything that may weaken -------------------
#
# Each row, %-separated: <variant> <PRESET edit> <the refusal line>. Live is the shipped
# preset; the preset copy in a sandbox is made looser. Every row is refused
# with --apply alone, refused with --allow-bypass-removal (the other flag),
# and records no write call either way.
WEAKENINGS=(
  "org-default-protection%.enforcement = \"evaluate\"%would change enforcement from active to evaluate"
  "org-default-protection%.enforcement = \"disabled\"%would change enforcement from active to disabled"
  "org-default-protection%.target = \"tag\"%would change target from \"branch\" to \"tag\""
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.required_approving_review_count) = 0%would change pull_request.required_approving_review_count from 1 to 0"
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.require_code_owner_review) = false%would change pull_request.require_code_owner_review from true to false"
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.required_review_thread_resolution) = false%would change pull_request.required_review_thread_resolution from true to false"
  "org-ci-must-pass%.rules[0].parameters.required_status_checks = [{\"context\": \"other\"}]%would remove or change required status check ci"
  "org-ci-must-pass%.rules[0].parameters.do_not_enforce_on_create = true%would change required_status_checks.do_not_enforce_on_create from false to true"
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.allowed_merge_methods) = [\"merge\", \"squash\", \"rebase\"]%would add merge to pull_request.allowed_merge_methods"
  "org-default-protection%.conditions.ref_name.exclude = [\"refs/heads/main\"]%would add refs/heads/main to conditions.ref_name.exclude"
  "org-default-protection%.conditions.repository_name.include = [\"one-repo\"]%would remove ~ALL from conditions.repository_name.include"
  "org-default-protection%.conditions.repository_name.exclude = [\"~ALL\"]%would add ~ALL to conditions.repository_name.exclude"
  "org-default-protection%.rules |= map(select(.type != \"required_linear_history\"))%would remove rule required_linear_history"
  "org-ci-must-pass%.bypass_actors += [{\"actor_id\": 42, \"actor_type\": \"Team\", \"bypass_mode\": \"always\"}]%would add bypass actor Team/42 in mode always"
  "org-staging%.bypass_actors += [{\"actor_id\": 42, \"actor_type\": \"Team\", \"bypass_mode\": \"pull_request\"}]%would add bypass actor Team/42 in mode pull_request"
  "org-staging%.bypass_actors += [{\"actor_id\": 42, \"actor_type\": \"Team\", \"bypass_mode\": \"exempt\"}]%would add bypass actor Team/42 in mode exempt"
  "org-staging%(.bypass_actors[] | select(.actor_type == \"Integration\") | .bypass_mode) = \"exempt\"%would widen bypass actor Integration/3951953 mode from pull_request to exempt"
  "org-staging%(.bypass_actors[] | select(.actor_type == \"Integration\") | .bypass_mode) = \"always\"%would widen bypass actor Integration/3951953 mode from pull_request to always"
  "org-baseline%(.bypass_actors[] | select(.actor_id == 2) | .bypass_mode) = \"exempt\"%would widen bypass actor RepositoryRole/2 mode from always to exempt"
  "org-default-protection%(.rules[] | select(.type == \"pull_request\") | .parameters.some_future_parameter) = true%would change pull_request.some_future_parameter from (absent) to true"
  "org-default-protection%.conditions.repository_property = {\"include\": [], \"exclude\": []}%would change conditions.repository_property from (absent) to {\"exclude\":[],\"include\":[]}"
  "org-default-protection%.rules += [{\"type\": \"some_future_rule\"}]%would add rule some_future_rule (no rule for this rule type)"
  "org-default-protection%(.rules[] | select(.type == \"deletion\")) += {\"parameters\": {\"x\": 1}}%would change deletion.parameters from (absent) to {\"x\":1}"
)
for row in "${WEAKENINGS[@]}"; do
  IFS='%' read -r variant edit want <<< "$row"
  new_case; script_live "$variant"
  script="$(sandbox "$variant" "$edit")"
  run "$script" acme "$variant" --apply
  expect_exit "apply-org --apply alone, weakening ($want), exits 2" 2
  expect_out "apply-org --apply alone names the weakening ($want)" "refused: weakens: $want"
  expect_out "apply-org --apply alone, weakening ($want), names the flag" "pass: --allow-weakening"
  run "$script" acme "$variant" --apply --allow-bypass-removal
  expect_exit "apply-org --allow-bypass-removal does not permit a weakening ($want)" 2
  expect_writes "apply-org weakening ($want) makes no write call" 0
done

# --- absence is never a value -----------------------------------------------
#
# For every key the tightening rules read, on each side in turn: the key
# removed, set to null, and given another JSON type. Each is a difference no
# rule can show tightens, so --apply alone exits 2, prints a weakens line
# naming the key, and writes nothing. (The reviewer's case: a preset with no
# allowed_merge_methods on a squash-only live ruleset was "tightens: removes
# squash" and PUT.)
#
# Each row, ;-separated: <variant> ; <jq path> ; <a value of another type> ;
# <text the weakens line carries> ; <live side: "weakens", or "unread" where
# the live detail read itself refuses that shape> ; <preset side: "weakens",
# or "invalid" where the validator refuses the retyped shape first>.
PRP='(.rules[] | select(.type == "pull_request") | .parameters)'
RSC='(.rules[] | select(.type == "required_status_checks") | .parameters)'
INTEGRATION='(.bypass_actors[] | select(.actor_type == "Integration"))'
ABSENCE=(
  "org-default-protection;.enforcement;2;enforcement;unread;weakens"
  "org-default-protection;.target;1;target;unread;weakens"
  "org-default-protection;.conditions;[];conditions;unread;weakens"
  "org-default-protection;.conditions.ref_name;[];conditions.ref_name;weakens;weakens"
  "org-default-protection;.conditions.ref_name.include;\"~DEFAULT_BRANCH\";conditions.ref_name.include;weakens;weakens"
  "org-default-protection;.conditions.ref_name.exclude;{};conditions.ref_name.exclude;weakens;weakens"
  "org-default-protection;.conditions.repository_name;[];conditions.repository_name;weakens;weakens"
  "org-default-protection;.conditions.repository_name.include;\"~ALL\";conditions.repository_name.include;weakens;weakens"
  "org-default-protection;.conditions.repository_name.exclude;{};conditions.repository_name.exclude;weakens;weakens"
  "org-default-protection;.rules;{};rules;unread;weakens"
  "org-default-protection;$PRP;[];pull_request.parameters;weakens;weakens"
  "org-default-protection;$PRP.required_approving_review_count;\"1\";pull_request.required_approving_review_count;weakens;badvalue"
  "org-default-protection;$PRP.dismiss_stale_reviews_on_push;\"true\";pull_request.dismiss_stale_reviews_on_push;weakens;weakens"
  "org-default-protection;$PRP.require_code_owner_review;1;pull_request.require_code_owner_review;weakens;weakens"
  "org-default-protection;$PRP.require_last_push_approval;0;pull_request.require_last_push_approval;weakens;weakens"
  "org-default-protection;$PRP.required_review_thread_resolution;[];pull_request.required_review_thread_resolution;weakens;weakens"
  "org-default-protection;$PRP.require_extra_approval_for_unattributed_changes;{};pull_request.require_extra_approval_for_unattributed_changes;weakens;weakens"
  "org-default-protection;$PRP.allowed_merge_methods;\"squash\";pull_request.allowed_merge_methods;weakens;badvalue"
  "org-ci-must-pass;$RSC;[];required_status_checks.parameters;weakens;invalid"
  "org-ci-must-pass;$RSC.strict_required_status_checks_policy;\"false\";required_status_checks.strict_required_status_checks_policy;weakens;weakens"
  "org-ci-must-pass;$RSC.do_not_enforce_on_create;0;required_status_checks.do_not_enforce_on_create;weakens;weakens"
  "org-ci-must-pass;$RSC.required_status_checks;{};required_status_checks.required_status_checks;weakens;weakens"
  "org-no-delete-dev-main;.bypass_actors;{};bypass_actors;unread;weakens"
  "org-staging;$INTEGRATION.bypass_mode;1;bypass actor Integration/3951953 bypass_mode;unread;weakens"
  "org-staging;$INTEGRATION.actor_id;\"3951953\";bypass actor Integration/;weakens;weakens"
)
# expect_weakens <name> <text>: a "weakens:" line that carries <text>.
expect_weakens() {
  grep -F "weakens: " <<< "$OUT" | grep -qF -- "$2"
  record "$1" $(( $? == 0 )) "no weakens line carrying: $2"
}
for row in "${ABSENCE[@]}"; do
  IFS=';' read -r variant path other label live_kind preset_kind <<< "$row"
  for how in removed null retyped; do
    case "$how" in
      removed) edit="del($path)" ;;
      null)    edit="$path = null" ;;
      retyped) edit="$path = $other" ;;
    esac
    # Preset side: live is the shipped preset, the preset copy is edited.
    new_case; script_live "$variant"
    script="$(sandbox "$variant" "$edit")"
    run "$script" acme "$variant" --apply
    expect_exit "apply-org preset $label $how: --apply alone exits 2" 2
    expect_writes "apply-org preset $label $how: no write call" 0
    expect_no_out "apply-org preset $label $how: never applied" "applied:"
    if [[ "$how" == retyped && "$preset_kind" == invalid ]]; then
      expect_out "apply-org preset $label $how: refused by the validator" "failed validation"
    elif [[ "$preset_kind" == badvalue && "$how" != removed ]]; then
      # Present but impossible (null, a string): an invalid preset, before any comparison.
      expect_out "apply-org preset $label $how: refused as an invalid preset" "refused: invalid preset"
      expect_out "apply-org preset $label $how: names the field" "$label"
    else
      expect_weakens "apply-org preset $label $how: weakens" "$label"
    fi
    # Live side: the preset is shipped, live is edited.
    new_case; script_live "$variant" "$edit"
    run "$APPLY_ORG" acme "$variant" --apply
    expect_exit "apply-org live $label $how: --apply alone exits 2" 2
    expect_writes "apply-org live $label $how: no write call" 0
    if [[ "$live_kind" == unread ]]; then
      expect_out "apply-org live $label $how: a failed read" "could not read live ruleset"
    else
      expect_weakens "apply-org live $label $how: weakens" "$label"
    fi
  done
done

# Absent on one side, null on the other: jq reads both as null, so this is
# the one pair a plain equality check would call "no difference".
new_case; script_live org-default-protection "$PRP.allowed_merge_methods = null"
script="$(sandbox org-default-protection "del($PRP.allowed_merge_methods)")"
run "$script" acme org-default-protection --apply
expect_exit "apply-org live null vs preset absent: --apply alone exits 2" 2
expect_out "apply-org live null vs preset absent: named as weakens" "refused: weakens: would change pull_request.allowed_merge_methods from null to (absent)"
expect_writes "apply-org live null vs preset absent: no write call" 0

# The reviewer's exact case, by name: no "tightens: removes squash".
new_case; script_live org-default-protection
script="$(sandbox org-default-protection "del($PRP.allowed_merge_methods)")"
run "$script" acme org-default-protection
expect_exit "apply-org dry run, preset without allowed_merge_methods, exits 1" 1
expect_no_out "apply-org never calls a missing allowed_merge_methods a removal" "tightens: removes squash"
expect_out "apply-org says --apply would refuse a missing allowed_merge_methods" "--apply would refuse this without --allow-weakening."

# A present value that cannot exist is an invalid preset, not a tightening:
# refused before any call, naming the field.
for case in \
  "$PRP.allowed_merge_methods = []%allowed_merge_methods" \
  "$PRP.required_approving_review_count = 1.5%required_approving_review_count" \
  "$PRP.required_approving_review_count = 11%required_approving_review_count" \
  "$PRP.required_approving_review_count = -1%required_approving_review_count" \
  "$PRP.required_approving_review_count = \"2\"%required_approving_review_count"; do
  edit="${case%%%*}"; field="${case##*%}"
  new_case; script_live org-default-protection
  script="$(sandbox org-default-protection "$edit")"
  run "$script" acme org-default-protection "${EVERY_FLAG[@]}"
  expect_exit "apply-org invalid preset '$edit' exits 2" 2
  expect_out "apply-org invalid preset '$edit' names $field" "refused: invalid preset"
  expect_out "apply-org invalid preset '$edit' names the field" "pull_request.$field"
  expect_no_out "apply-org invalid preset '$edit' is never called a tightening" "tightens"
  expect_writes "apply-org invalid preset '$edit': no write" 0
  [[ ! -s "$FAKE_GH_LOG" ]]; record "apply-org invalid preset '$edit': no call at all" $(( $? == 0 )) "calls: $(tr '\n' ';' < "$FAKE_GH_LOG")"
done

# A preset that is not exactly one JSON object is refused before any call.
new_case; script_live org-staging
dir="$FAKE_GH_DIR/sandbox"; mkdir -p "$dir"; cp -R "$REPO_ROOT/bin" "$REPO_ROOT/rulesets" "$dir/"
cat "$STAGING" "$STAGING" > "$dir/rulesets/org-staging.json"
run "$dir/bin/apply-org.sh" acme org-staging "${EVERY_FLAG[@]}"
expect_exit "apply-org with a two-document preset exits 2" 2
expect_out "apply-org with a two-document preset says so" "is not one JSON object"
calls="$(wc -l < "$FAKE_GH_LOG" | tr -d ' ')"
[[ "$calls" -eq 0 ]]; record "apply-org with a two-document preset makes no API call" $(( $? == 0 )) "recorded $calls call(s)"

# A preset field the comparison does not cover is refused before any call.
new_case; script_live org-staging
script="$(sandbox org-staging '. + {some_future_field: true}')"
run "$script" acme org-staging "${EVERY_FLAG[@]}"
expect_exit "apply-org with an uncompared preset field exits 2" 2
expect_out "apply-org names the uncompared preset field" "carries field(s) this script does not compare: some_future_field"
expect_writes "apply-org with an uncompared preset field makes no write call" 0

# --allow-weakening permits a weakening, and only that.
new_case; script_live org-default-protection
script="$(sandbox org-default-protection '.enforcement = "evaluate"')"
run "$script" acme org-default-protection --apply --allow-weakening
expect_exit "apply-org --apply --allow-weakening on a weakening exits 0" 0
expect_call "apply-org --apply --allow-weakening PUTs the live ruleset's id" "PUT orgs/acme/rulesets/111"
expect_writes "apply-org --apply --allow-weakening writes once" 1
expect_out "apply-org --apply --allow-weakening reports what it applied" "applied: preset 'org-default-protection' to live ruleset 'org-default-protection' (id=111)"

# Live pull_request mode, preset always: a widening, refused.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/222 0 "$(as_live "$BASELINE" '.id = 222 | .bypass_actors |= map(.bypass_mode = "pull_request")')"
run "$APPLY_ORG" acme org-baseline --apply
expect_exit "apply-org --apply widening pull_request to always exits 2" 2
expect_out "apply-org --apply names the widened bypass mode" "refused: weakens: would widen bypass actor RepositoryRole/5 mode from pull_request to always"
expect_writes "apply-org --apply widening a bypass mode makes no write call" 0

# Live has a ref target the preset lacks.
new_case; script_live org-staging '.conditions.ref_name.include += ["refs/heads/release"]'
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply removing a ref target exits 2" 2
expect_out "apply-org --apply names the removed ref target" "refused: weakens: would remove refs/heads/release from conditions.ref_name.include"
expect_writes "apply-org --apply removing a ref target makes no write call" 0

# Live has strict status checks the preset turns off.
new_case; script_live org-ci-must-pass '.rules[0].parameters.strict_required_status_checks_policy = true'
run "$APPLY_ORG" acme org-ci-must-pass --apply
expect_exit "apply-org --apply turning strict status checks off exits 2" 2
expect_out "apply-org --apply names strict status checks turned off" "refused: weakens: would change required_status_checks.strict_required_status_checks_policy from true to false"
expect_writes "apply-org --apply turning strict status checks off makes no write call" 0

# A difference no comparator names (here a duplicated include entry, which
# leaves nothing missing on either side) is weakens, never fine.
new_case; script_live org-staging '.conditions.ref_name.include += ["refs/heads/dev"]'
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply with an unclassifiable difference exits 2" 2
expect_out "apply-org --apply names an unclassifiable difference as weakens" "refused: weakens: a difference this script could not classify"
expect_writes "apply-org --apply with an unclassifiable difference makes no write call" 0

# --- removing or narrowing a live bypass: its own kind, its own flag --------

# Live has a bypass actor the preset lacks.
REMOVE_ACTOR='.bypass_actors += [{actor_id: 42, actor_type: "Team", bypass_mode: "pull_request"}]'
new_case; script_live org-staging "$REMOVE_ACTOR"
run "$APPLY_ORG" acme org-staging
expect_exit "apply-org dry run removing a live bypass actor exits 1" 1
expect_out "apply-org dry run names the bypass removal" "removes bypass: would remove live bypass actor Team/42 (mode pull_request)"
expect_out "apply-org dry run says --apply needs --allow-bypass-removal" "--apply would refuse this without --allow-bypass-removal."
expect_writes "apply-org dry run removing a bypass actor makes no write call" 0
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply removing a live bypass actor exits 2" 2
expect_out "apply-org --apply refuses the bypass removal under its own name" "refused: removes bypass: would remove live bypass actor Team/42 (mode pull_request) (automation that relies on this bypass may be locked out)"
expect_no_out "apply-org does not call a bypass removal a weakening" "refused: weakens:"
run "$APPLY_ORG" acme org-staging --apply --allow-weakening
expect_exit "apply-org --allow-weakening does not permit a bypass removal" 2
expect_writes "apply-org bypass removal without its flag makes no write call" 0
run "$APPLY_ORG" acme org-staging --apply --allow-bypass-removal
expect_exit "apply-org --apply --allow-bypass-removal exits 0" 0
expect_call "apply-org --apply --allow-bypass-removal PUTs the live ruleset's id" "PUT orgs/acme/rulesets/111"
expect_writes "apply-org --apply --allow-bypass-removal writes once" 1

# Live always, preset pull_request: narrowing a bypass mode.
new_case; script_live org-staging '(.bypass_actors[] | select(.actor_type == "Integration") | .bypass_mode) = "always"'
run "$APPLY_ORG" acme org-staging --apply --allow-weakening
expect_exit "apply-org --apply narrowing a bypass mode exits 2, even with --allow-weakening" 2
expect_out "apply-org --apply names the narrowed bypass mode" "refused: removes bypass: would narrow bypass actor Integration/3951953 mode from always to pull_request"
expect_writes "apply-org narrowing a bypass mode without its flag makes no write call" 0
run "$APPLY_ORG" acme org-staging --apply --allow-bypass-removal
expect_exit "apply-org --apply --allow-bypass-removal narrowing a bypass mode exits 0" 0
expect_writes "apply-org --apply --allow-bypass-removal narrowing a bypass mode writes once" 1

# Both kinds at once need both flags.
new_case; script_live org-staging "$REMOVE_ACTOR"
script="$(sandbox org-staging '.enforcement = "evaluate"')"
run "$script" acme org-staging --apply --allow-weakening
expect_exit "apply-org with both kinds and only --allow-weakening exits 2" 2
expect_out "apply-org with both kinds and only --allow-weakening names the bypass removal" "refused: removes bypass: would remove live bypass actor Team/42"
expect_no_out "apply-org with both kinds does not re-refuse what --allow-weakening permits" "refused: weakens:"
run "$script" acme org-staging --apply --allow-bypass-removal
expect_exit "apply-org with both kinds and only --allow-bypass-removal exits 2" 2
expect_out "apply-org with both kinds and only --allow-bypass-removal names the weakening" "refused: weakens: would change enforcement from active to evaluate"
expect_writes "apply-org with both kinds and one flag makes no write call" 0
run "$script" acme org-staging "${EVERY_FLAG[@]}"
expect_exit "apply-org with both kinds and both flags exits 0" 0
expect_writes "apply-org with both kinds and both flags writes once" 1

# --apply with no difference writes nothing.
new_case; script_live org-staging
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org --apply with no difference exits 0" 0
expect_writes "apply-org --apply with no difference makes no write call" 0

# --- names: duplicates and near-duplicates ---------------------------------

# Two live rulesets with one name: refused, before any detail read or write.
new_case
respond GET orgs/acme/rulesets 0 '[{"id":111,"name":"org-staging"},{"id":333,"name":"org-staging"}]'
respond GET orgs/acme/rulesets/111 0 "$(as_live "$STAGING")"
respond PUT orgs/acme/rulesets/111 0 '{}'
run "$APPLY_ORG" acme org-staging "${EVERY_FLAG[@]}"
expect_exit "apply-org with two live rulesets of one name exits 2" 2
expect_out "apply-org with two live rulesets of one name says so" "2 live rulesets in 'acme' are named 'org-staging'"
expect_writes "apply-org with two live rulesets of one name makes no write call" 0

# A live name that differs only by case or spacing: refused, never a create
# beside it.
for near in 'Org-Staging' 'org staging' 'org_staging' ' org-staging'; do
  new_case
  respond GET orgs/acme/rulesets 0 "$(jq -cn --arg n "$near" '[{id: 111, name: $n}]')"
  respond POST orgs/acme/rulesets 0 '{}'
  run "$APPLY_ORG" acme org-staging "${EVERY_FLAG[@]}"
  expect_exit "apply-org with a live '$near' exits 2" 2
  expect_out "apply-org with a live '$near' names it" "named like 'org-staging' but not identically: $near (id=111)"
  expect_writes "apply-org with a live '$near' makes no write call" 0
done
new_case
respond GET orgs/acme/rulesets 0 '[{"id":111,"name":"ci-must-pass"}]'
respond POST orgs/acme/rulesets 0 '{}'
run "$APPLY_ORG" acme org-ci-must-pass --apply
expect_exit "apply-org with a live 'ci-must-pass' for 'CI must pass' exits 2" 2
expect_writes "apply-org with a live 'ci-must-pass' makes no write call" 0

# The stated limit of the near-name check: it folds ASCII case, spaces,
# hyphens and underscores only, so a look-alike from another script (here a
# Cyrillic "о") is not detected and --apply creates beside it. Pinned so the
# header and README sentence that states this limit change with the code.
new_case
respond GET orgs/acme/rulesets 0 '[{"id":111,"name":"оrg-staging"}]'
respond POST orgs/acme/rulesets 0 '{}'
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org with a Cyrillic look-alike live name creates (the stated limit)" 0
expect_call "apply-org with a Cyrillic look-alike live name POSTs (the stated limit)" "POST orgs/acme/rulesets"

# --- reads that fail, or return nothing usable -----------------------------

# A failed list read: refused, never treated as "nothing is live".
new_case
respond GET orgs/acme/rulesets 1 - "gh: Not Found (HTTP 404)"
respond POST orgs/acme/rulesets 0 '{}'
run "$APPLY_ORG" acme org-staging --apply
expect_exit "apply-org with a failed live list read exits 2" 2
expect_out "apply-org with a failed live list read says it could not read" "could not read the live rulesets for org 'acme'"
expect_writes "apply-org with a failed live list read makes no write call" 0

# A list read that exits 0 with nothing usable: the same.
for body in '' 'null' '{}' '{"id":111,"name":"org-staging"}' 'not json' '[{"id":"111","name":"org-staging"}]'; do
  new_case
  respond GET orgs/acme/rulesets 0 "$body"
  respond POST orgs/acme/rulesets 0 '{}'
  run "$APPLY_ORG" acme org-staging "${EVERY_FLAG[@]}"
  expect_exit "apply-org with list body '$body' exits 2" 2
  expect_out "apply-org with list body '$body' says it could not read" "could not read the live rulesets for org 'acme'"
  expect_writes "apply-org with list body '$body' makes no write call" 0
done

# A failed live detail read: refused.
new_case
respond GET orgs/acme/rulesets 0 "$LIST_ONE"
respond GET orgs/acme/rulesets/111 1 - "gh: Server Error (HTTP 500)"
respond PUT orgs/acme/rulesets/111 0 '{}'
run "$APPLY_ORG" acme org-staging "${EVERY_FLAG[@]}"
expect_exit "apply-org with a failed live detail read exits 2" 2
expect_out "apply-org with a failed live detail read says so" "could not read live ruleset 'org-staging' (id=111)"
expect_writes "apply-org with a failed live detail read makes no write call" 0

# A detail read that exits 0 with nothing usable: the same. A missing
# bypass_actors is not "no bypass" (GitHub omits it for a non-admin caller).
# Two JSON documents in one body is a failed read too, whichever comes first:
# only one could ever be compared.
for body in '' 'null' '{}' '[]' 'not json' \
    "$(as_live "$STAGING" '.enforcement = "evaluate"')"$'\n'"$(as_live "$STAGING")" \
    "$(as_live "$STAGING")"$'\n'"$(as_live "$STAGING")" \
    "$(as_live "$STAGING" '.id = 999')" \
    "$(as_live "$STAGING" 'del(.bypass_actors)')" \
    "$(as_live "$STAGING" 'del(.conditions)')" \
    "$(as_live "$STAGING" '.rules = [1]')"; do
  new_case
  respond GET orgs/acme/rulesets 0 "$LIST_ONE"
  respond GET orgs/acme/rulesets/111 0 "$body"
  respond PUT orgs/acme/rulesets/111 0 '{}'
  run "$APPLY_ORG" acme org-staging "${EVERY_FLAG[@]}"
  expect_exit "apply-org with detail body '${body:0:40}' exits 2" 2
  expect_out "apply-org with detail body '${body:0:40}' says it could not read" "could not read live ruleset 'org-staging' (id=111)"
  expect_writes "apply-org with detail body '${body:0:40}' makes no write call" 0
done

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

# --- arguments and exit codes ---------------------------------------------

new_case; script_live org-staging
run "$APPLY_ORG" acme org-staging org-baseline --apply
expect_exit "apply-org with two variants exits 2" 2
expect_out "apply-org with two variants names both" "two variants given ('org-staging' and 'org-baseline')"
calls="$(grep -c '^GET orgs\|^PUT\|^POST' "$FAKE_GH_LOG" || true)"
[[ "$calls" -eq 0 ]]; record "apply-org with two variants makes no API call" $(( $? == 0 )) "recorded $calls call(s)"

for bad in --allow-loosening --aply -apply --apply=true; do
  new_case; script_live org-staging
  run "$APPLY_ORG" acme org-staging "$bad"
  expect_exit "apply-org with unknown argument '$bad' exits 2" 2
  expect_writes "apply-org with unknown argument '$bad' makes no write call" 0
done

new_case; script_live org-staging
run "$APPLY_ORG" --apply acme org-staging
expect_exit "apply-org with a flag where the org belongs exits 2" 2
expect_writes "apply-org with a flag where the org belongs makes no write call" 0

# An unexpected internal failure (here: mktemp fails, which under `set -e`
# would exit 1, the "difference exists" code) is reported as 2.
mkdir -p "$WORK/badbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/badbin/mktemp"; chmod +x "$WORK/badbin/mktemp"
new_case; script_live org-staging
OUT="$(PATH="$WORK/badbin:$WORK/bin:$PATH" "$APPLY_ORG" acme org-staging --apply 2>&1)"; CODE=$?
expect_exit "apply-org with an unexpected internal failure exits 2, never 1" 2
expect_out "apply-org with an unexpected internal failure says so" "unexpected failure (exit 1)"
expect_writes "apply-org with an unexpected internal failure makes no write call" 0

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

# --include-ruleset with two active rulesets. Ruleset 7 carries all four
# required rule types and an admin bypass, so on its own it is clean.
# script_two_rulesets [exit body stderr]: how the read of ruleset 8 answers
# (default: a readable org-staging).
script_two_rulesets() {
  respond GET repos/acme/fine 0 "$GOOD_SETTINGS"
  respond GET 'repos/acme/fine/rulesets?includes_parents=true' 0 '[{"id":7,"enforcement":"active"},{"id":8,"enforcement":"active"}]'
  respond GET repos/acme/fine/rulesets/7 0 "$(jq -c '. + {id: 7}' "$PROTECTION")"
  if [[ $# -gt 0 ]]; then
    respond GET repos/acme/fine/rulesets/8 "$1" "$2" "${3:-}"
  else
    respond GET repos/acme/fine/rulesets/8 0 "$(jq -c '. + {id: 8}' "$STAGING")"
  fi
}
# audit_sandbox <validator-body|->: a copy of bin/audit.sh whose sibling
# validator is the given script, or absent with "-". Prints the copy's path.
audit_sandbox() {
  local dir="$FAKE_GH_DIR/audit-sandbox"
  mkdir -p "$dir/bin"
  cp "$AUDIT" "$dir/bin/audit.sh"
  [[ "$1" == "-" ]] || printf '%s\n' "$1" > "$dir/bin/validate-ruleset.sh"
  echo "$dir/bin/audit.sh"
}

# Control: both readable, the real validator runs -> no drift.
new_case; script_two_rulesets
run "$AUDIT" acme/fine --include-ruleset
expect_exit "audit --include-ruleset with every read working exits 0 (control)" 0
expect_out "audit --include-ruleset with every read working says no drift (control)" "no drift detected"

# One ruleset detail read fails: could not audit, never no drift.
new_case; script_two_rulesets 1 - "gh: Server Error (HTTP 500)"
run "$AUDIT" acme/fine --include-ruleset
expect_exit "audit with a failed ruleset detail read exits 2" 2
expect_out "audit with a failed ruleset detail read names the ruleset" "could not audit: GET failed for ruleset id(s): 8"
expect_no_out "audit with a failed ruleset detail read never says no drift" "no drift"

# A detail or a listing read that exits 0 with nothing usable: the same.
for body in '' 'null' '{}' '[]' 'not json'; do
  new_case; script_two_rulesets 0 "$body"
  run "$AUDIT" acme/fine --include-ruleset
  expect_exit "audit with ruleset detail body '$body' exits 2" 2
  expect_out "audit with ruleset detail body '$body' names the ruleset it could not read" "could not audit: GET failed for ruleset id(s): 8"
  expect_no_out "audit with ruleset detail body '$body' never says no drift" "no drift"
  [[ "$body" == "[]" ]] && continue   # an empty list is a real answer, covered as drift elsewhere
  new_case
  respond GET repos/acme/fine 0 "$GOOD_SETTINGS"
  respond GET 'repos/acme/fine/rulesets?includes_parents=true' 0 "$body"
  run "$AUDIT" acme/fine --include-ruleset
  expect_exit "audit with ruleset listing body '$body' exits 2" 2
  expect_out "audit with ruleset listing body '$body' says could not audit" "could not audit"
  expect_no_out "audit with ruleset listing body '$body' never says no drift" "no drift"
done

# A repo read that exits 0 with nothing usable.
for body in '' 'null' 'not json'; do
  new_case
  respond GET repos/acme/fine 0 "$body"
  run "$AUDIT" acme/fine
  expect_exit "audit with repo body '$body' exits 2" 2
  expect_out "audit with repo body '$body' says could not audit" "could not audit"
done

# More than one JSON document, or a 200 error object, is not a read: could
# not audit, never no drift -- even under --strict.
BADRS="$(jq -c '. + {id: 8, bypass_actors: []}' "$REPO_ROOT/tests/fixtures/missing-bypass.json")"
DECOY="$(jq -c '. + {id: 8}' "$PROTECTION")"
ERR_OBJ='{"message":"Not Found","status":"404"}'
for body in "$BADRS"$'\n'"$BADRS" "$DECOY"$'\n'"$BADRS" "$ERR_OBJ"; do
  new_case; script_two_rulesets 0 "$body"
  run "$AUDIT" --include-ruleset --strict acme/fine
  expect_exit "audit --strict with ruleset detail body '${body:0:40}...' exits 2" 2
  expect_out "audit with that ruleset detail body says could not audit" "could not audit: GET failed for ruleset id(s): 8"
  expect_no_out "audit with that ruleset detail body never says no drift" "no drift"
done
for body in "$GOOD_SETTINGS"$'\n'"$GOOD_SETTINGS" "$ERR_OBJ"; do
  new_case
  respond GET repos/acme/fine 0 "$body"
  run "$AUDIT" --strict acme/fine
  expect_exit "audit --strict with repo body '${body:0:40}...' exits 2" 2
  expect_out "audit with that repo body says could not audit" "could not audit"
  expect_no_out "audit with that repo body never reports drift rows" "allow_auto_merge = null"
  expect_no_out "audit with that repo body never says no drift" "no drift"
done
new_case
respond GET repos/acme/fine 0 "$GOOD_SETTINGS"
respond GET 'repos/acme/fine/rulesets?includes_parents=true' 0 "$ERR_OBJ"
run "$AUDIT" --include-ruleset --strict acme/fine
expect_exit "audit --strict with a ruleset listing that is an error object exits 2" 2
expect_out "audit with a ruleset listing that is an error object says could not audit" "could not audit"
expect_no_out "audit with a ruleset listing that is an error object never says no drift" "no drift"

# The validator exits 2 (could not run): could not audit, never no drift.
new_case; script_two_rulesets
script="$(audit_sandbox $'#!/usr/bin/env bash\necho "validator: could not run" >&2\nexit 2')"
run "$script" acme/fine --include-ruleset
expect_exit "audit with a validator that exits 2 exits 2" 2
expect_out "audit with a validator that exits 2 says it could not run field validation" "could not run field validation"
expect_no_out "audit with a validator that exits 2 never says no drift" "no drift"

# The validator's result is a verdict only when it is exit 0, or exit 1
# with at least one "✗ [<check>] " line. Anything else -- exit 1 with no
# output, exit 1 with only a non-violation line, exit 1 with only a warning,
# exit 3 -- is a validation that did not run.
for vbody in $'exit 1' $'echo "something went wrong"\nexit 1' \
    $'echo "⚠ [bypass-defeats-deletion-restriction] advisory"\nexit 1' \
    $'echo "✗ [admin-bypass-required] x"\nexit 3'; do
  new_case; script_two_rulesets
  script="$(audit_sandbox $'#!/usr/bin/env bash\n'"$vbody")"
  run "$script" acme/fine --include-ruleset --strict
  expect_exit "audit --strict with a validator that does '${vbody//$'\n'/; }' exits 2" 2
  expect_out "audit with a validator that does '${vbody//$'\n'/; }' says it could not run field validation" "could not run field validation"
  expect_no_out "audit with a validator that does '${vbody//$'\n'/; }' never says no violations" "no violations"
  expect_no_out "audit with a validator that does '${vbody//$'\n'/; }' never says no drift" "no drift"
done
# Control: exit 1 with a real violation line is drift, not could-not-audit.
new_case; script_two_rulesets
script="$(audit_sandbox $'#!/usr/bin/env bash\necho "✗ [admin-bypass-required] no admin bypass"\nexit 1')"
run "$script" acme/fine --include-ruleset --strict
expect_exit "audit --strict with a validator reporting a violation exits 1 (control)" 1
expect_out "audit with a validator reporting a violation shows it (control)" "✗ [admin-bypass-required] no admin bypass"
expect_no_out "audit with a validator reporting a violation is not could-not-audit (control)" "could not audit"

# The reviewer's case end to end: the real validator, a ruleset with a real
# violation, and a mktemp that fails. Before, the validator exited 1 silently
# and audit printed "no drift" with exit 0 under --strict.
new_case
respond GET repos/acme/fine 0 "$GOOD_SETTINGS"
respond GET 'repos/acme/fine/rulesets?includes_parents=true' 0 '[{"id":7,"enforcement":"active"}]'
respond GET repos/acme/fine/rulesets/7 0 "$(jq -c '. + {id: 7, bypass_actors: []}' "$PROTECTION")"
OUT="$(PATH="$WORK/badbin:$WORK/bin:$PATH" "$AUDIT" acme/fine --include-ruleset --strict 2>&1)"; CODE=$?
expect_exit "audit --strict when the validator cannot make a temp file exits 2" 2
expect_out "audit when the validator cannot make a temp file says could not run field validation" "could not run field validation"
expect_no_out "audit when the validator cannot make a temp file never says no drift" "no drift"

# No validator at all: could not audit, never "no violations".
new_case; script_two_rulesets
script="$(audit_sandbox -)"
run "$script" acme/fine --include-ruleset
expect_exit "audit with no validator exits 2" 2
expect_out "audit with no validator says it could not run field validation" "could not run field validation"
expect_no_out "audit with no validator never says no violations" "no violations"
expect_no_out "audit with no validator never says no drift" "no drift"

# An unexpected internal failure (a ruleset whose rules jq cannot read) is
# reported as could not audit, exit 2 -- not jq's raw exit code.
new_case; script_two_rulesets 0 '{"id":8,"rules":[1]}'
run "$AUDIT" acme/fine --include-ruleset
expect_exit "audit with an unexpected internal failure exits 2" 2
expect_out "audit with an unexpected internal failure says could not audit" "could not audit: unexpected failure"
expect_writes "audit never writes (extended cases)" 0

# ensure-dev: a repo read that exits 0 with nothing usable is a failed repo,
# and the run still prints its summary and exits 2.
for body in '' 'null' 'not json'; do
  new_case
  respond GET repos/acme/odd 0 "$body"
  run "$ENSURE_DEV" acme/odd --apply
  expect_exit "ensure-dev with repo body '$body' exits 2" 2
  expect_out "ensure-dev with repo body '$body' counts it failed" "Summary: 0 created, 0 already-present, 0 would-create, 0 skipped, 1 failed"
  expect_writes "ensure-dev with repo body '$body' makes no write call" 0
done

# ensure-dev: an unexpected internal failure (here a jq that crashes on the
# default-branch read) exits 2, not jq's raw code.
mkdir -p "$WORK/badjq"
REAL_JQ="$(command -v jq)"
cat > "$WORK/badjq/jq" <<BADJQ
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == ".default_branch" ]] && exit 5; done
exec "$REAL_JQ" "\$@"
BADJQ
chmod +x "$WORK/badjq/jq"
new_case
respond GET repos/acme/has-dev 0 "$(repo_json acme/has-dev)"
OUT="$(PATH="$WORK/badjq:$WORK/bin:$PATH" "$ENSURE_DEV" acme/has-dev 2>&1)"; CODE=$?
expect_exit "ensure-dev with an unexpected internal failure exits 2" 2
expect_out "ensure-dev with an unexpected internal failure says so" "unexpected failure (exit 5)"

# ========================================================================
# --help prints the whole usage text, not a fixed line range of it
# ========================================================================

new_case
run "$APPLY_ORG" --help
expect_exit "apply-org --help exits 0" 0
for want in "org-no-delete-dev-main" "DRY RUN BY DEFAULT" "Exit codes" "--allow-weakening" \
    "--allow-bypass-removal" "The two flags are independent" "look-alike" \
    "Requires the \`gh\` CLI authenticated with the \`admin:org\` scope"; do
  expect_out "apply-org --help carries '$want'" "$want"
done
run "$AUDIT" --help
expect_exit "audit --help exits 0" 0
for want in "Exit codes" "could not audit" "Opt-in because it adds 2 API calls per repo." \
    "--apply (and the flag it names, if it refuses). See \`apply.sh --help\`."; do
  expect_out "audit --help carries '$want'" "$want"
done
run "$AUDIT"
expect_exit "audit with no arguments is a usage error, exit 2" 2
expect_writes "--help and usage errors make no call" 0

echo
echo "$PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
