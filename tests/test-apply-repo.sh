#!/usr/bin/env bash
# Regression suite for bin/apply.sh: a dry run by default for every write
# it makes, one comparison shared with bin/apply-org.sh, and no write at all
# when a live read is unusable or the ruleset change is one --apply alone may
# not make.
#
# No case here talks to GitHub. Each case puts a fake `gh` first on PATH that
# records every API call (method and path) to a log and answers only what the
# case scripted. A case asserts on three things: the exit code, the printed
# lines, and the recorded calls -- so "nothing was written" is a fact read
# from the log, not a claim. The repository in every fixture is
# example-org/example-repo.
#
# Usage: tests/test-apply-repo.sh
# Exit: 0 if every case passes, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLY_ORG="$REPO_ROOT/bin/apply-org.sh"

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
BODY_N=0
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
    BODY_N=$((BODY_N + 1))
    file="body-$BODY_N.json"
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
# bin/apply.sh
# ========================================================================

APPLY="$REPO_ROOT/bin/apply.sh"
APPLY_ORG="$REPO_ROOT/bin/apply-org.sh"
LIB="$REPO_ROOT/bin/ruleset-compare.sh"
R="example-org/example-repo"
RS="repos/$R"
CONTENTS="$RS/contents/.github/dependabot.yml"
EVERY_FLAG=(--apply --allow-weakening --allow-bypass-removal)

BASELINE="$REPO_ROOT/rulesets/baseline.json"

# the repository as GitHub returns it, with every canonical setting in place
SETTINGS_OK='{"id":1,"full_name":"example-org/example-repo","allow_auto_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
SETTINGS_STALE="$(jq -c '.allow_merge_commit = true | .delete_branch_on_merge = false' <<< "$SETTINGS_OK")"

# as_live <preset-file> [jq-edit]: the preset as GitHub returns it, with the
# read-only fields an apply never sends, and an optional edit applied.
as_live() {
  jq -c "(. + {id: 111, node_id: \"RRS_x\", source_type: \"Repository\", source: \"example-org/example-repo\",
          created_at: \"2026-01-01T00:00:00Z\", updated_at: \"2026-01-01T00:00:00Z\"})
         | ${2:-.}" "$1"
}

# the bypass list of a hand-extended live ruleset: more than the preset's one
FOUR_ACTORS='.bypass_actors += [{"actor_id":3951953,"actor_type":"Integration","bypass_mode":"always"},{"actor_id":null,"actor_type":"OrganizationAdmin","bypass_mode":"always"},{"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"}]'

# script_live <variant> [live-edit] [settings-json]: every read answers; live
# has one ruleset 'reporulez-default' (id 111) as the preset with an optional
# edit; every write succeeds.
script_live() {
  local f="$REPO_ROOT/rulesets/$1.json"
  respond GET "$RS" 0 "${3:-$SETTINGS_OK}"
  respond GET "$RS/rulesets" 0 '[{"id":111,"name":"reporulez-default"}]'
  respond GET "$RS/rulesets/111" 0 "$(as_live "$f" "${2:-.}")"
  respond PATCH "$RS" 0 '{}'
  respond PUT "$RS/rulesets/111" 0 '{}'
  respond POST "$RS/rulesets" 0 '{}'
  respond PUT "$CONTENTS" 0 '{}'
}

# rebuild <method> <path> <exit> <body|-> [stderr]: replace one scripted answer
# (the fake answers with the first line that matches).
rebuild() {
  awk -F'\t' -v m="$1" -v p="$2" '!($1 == m && $2 == p)' "$FAKE_GH_RESPONSES" > "$FAKE_GH_RESPONSES.n"
  mv "$FAKE_GH_RESPONSES.n" "$FAKE_GH_RESPONSES"
  respond "$@"
}

# contents_of <template>: the contents-API body for a file holding that template
contents_of() {
  jq -cn --arg c "$(base64 < "$REPO_ROOT/templates/dependabot/$1.yml")" \
    '{path: ".github/dependabot.yml", sha: "abc123", encoding: "base64", content: $c}'
}

# expect_order <name> <writes>: the write calls, in order, comma-joined
expect_order() {
  local got
  got="$(grep -vE '^GET ' "$FAKE_GH_LOG" | paste -sd ',' -)"
  [[ "$got" == "$2" ]]; record "$1" $(( $? == 0 )) "expected writes '$2', recorded '$got'"
}

# --- control: every preset against itself-as-live is no difference --------------
for v in baseline clud-bug skdd public-guard; do
  for mode in "--dry" "--apply"; do
    new_case; script_live "$v"
    flag=(); [[ "$mode" == "--apply" ]] && flag=(--apply)
    run "$APPLY" "$R" "$v" ${flag[@]+"${flag[@]}"}
    expect_exit "apply $v $mode: identical live exits 0" 0
    expect_out "apply $v $mode: ruleset says no difference" "no difference: preset '$v' matches live ruleset"
    expect_out "apply $v $mode: settings say no difference" "no difference: repo settings"
    expect_writes "apply $v $mode: identical live writes nothing" 0
  done
done

# --- dry run: live carries more bypass actors than the preset -------------------
new_case; script_live baseline "$FOUR_ACTORS" "$SETTINGS_STALE"
respond GET "$CONTENTS" 0 "$(contents_of typescript)"
run "$APPLY" "$R" baseline --with-dependabot=python
expect_exit "dry run with a difference exits 1" 1
expect_out "dry run names a setting that differs" "allow_merge_commit: live true, would set false"
expect_out "dry run says the file would be replaced" "would REPLACE it (content differs)"
expect_out "dry run names the removed Integration actor" "removes bypass: would remove live bypass actor Integration/3951953 (mode always)"
expect_out "dry run names the removed organisation admin" "removes bypass: would remove live bypass actor OrganizationAdmin/- (mode always)"
expect_out "dry run names the removed role" "removes bypass: would remove live bypass actor RepositoryRole/2 (mode always)"
expect_out "dry run says which flag --apply would need" "--apply would refuse this without --allow-bypass-removal."
expect_out "dry run says nothing was written" "dry run: nothing written."
expect_writes "dry run makes no write call (settings, file or ruleset)" 0

# --- --apply alone on that repo: refused, and nothing is written, not even the settings
new_case; script_live baseline "$FOUR_ACTORS" "$SETTINGS_STALE"
respond GET "$CONTENTS" 1 - "gh: Not Found (HTTP 404)"
run "$APPLY" "$R" baseline --with-dependabot=python --apply
expect_exit "--apply alone with extra live bypass actors exits 2" 2
expect_out "--apply alone names the refusal" "refused: removes bypass: would remove live bypass actor Integration/3951953"
expect_out "--apply alone names the flag that would permit it" "pass: --allow-bypass-removal"
expect_writes "--apply alone writes nothing: not settings, not the file, not the ruleset" 0

# --allow-weakening permits only weakening: the bypass removal is still refused
new_case; script_live baseline "$FOUR_ACTORS" "$SETTINGS_STALE"
run "$APPLY" "$R" baseline --apply --allow-weakening
expect_exit "--allow-weakening does not permit a bypass removal" 2
expect_writes "--allow-weakening alone writes nothing" 0

# --allow-bypass-removal permits it: settings, then the ruleset
new_case; script_live baseline "$FOUR_ACTORS" "$SETTINGS_STALE"
run "$APPLY" "$R" baseline --apply --allow-bypass-removal
expect_exit "--apply --allow-bypass-removal writes and exits 0" 0
expect_order "writes happen in order: settings then ruleset" "PATCH $RS,PUT $RS/rulesets/111"

# a weakening (the preset adds an actor live lacks) needs --allow-weakening, not the other flag
new_case; script_live baseline '.bypass_actors = []'
run "$APPLY" "$R" baseline --apply --allow-bypass-removal
expect_exit "--allow-bypass-removal does not permit a weakening" 2
expect_out "the weakening is named" "refused: weakens: would add bypass actor RepositoryRole/5 in mode always"
expect_writes "a refused weakening writes nothing" 0
new_case; script_live baseline '.bypass_actors = []'
run "$APPLY" "$R" baseline --apply --allow-weakening
expect_exit "--allow-weakening permits adding a bypass actor" 0
expect_call "--allow-weakening writes the ruleset" "PUT $RS/rulesets/111"

# a provable tightening is written by --apply alone
new_case; script_live baseline '.rules |= map(select(.type != "required_linear_history"))'
run "$APPLY" "$R" baseline
expect_exit "dry run of a tightening exits 1" 1
expect_out "the tightening is labelled" "tightens: adds rule required_linear_history"
expect_writes "dry run of a tightening writes nothing" 0
new_case; script_live baseline '.rules |= map(select(.type != "required_linear_history"))'
run "$APPLY" "$R" baseline --apply
expect_exit "--apply alone writes a provable tightening" 0
expect_call "--apply alone replaces the ruleset by id" "PUT $RS/rulesets/111"

# --human-review raises the approval count: a tightening
new_case; script_live baseline
run "$APPLY" "$R" baseline --human-review --apply
expect_exit "--human-review on a live baseline is a tightening, written by --apply alone" 0
expect_out "--human-review is labelled tightens" "tightens: raises pull_request.required_approving_review_count from 0 to 1"

# a preset that would LOWER the live approval count is a weakening, not a tightening
new_case; script_live baseline '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = 1'
run "$APPLY" "$R" baseline
expect_exit "dry run of a lowered approval count exits 1" 1
expect_out "a lowered approval count is labelled weakens" "weakens: would change pull_request.required_approving_review_count from 1 to 0"
expect_no_out "a lowered approval count is not labelled tightens" "tightens: raises pull_request.required_approving_review_count"
new_case; script_live baseline '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = 1'
run "$APPLY" "$R" baseline --apply
expect_exit "--apply alone refuses a lowered approval count" 2
expect_out "the refusal names the weakening" "refused: weakens: would change pull_request.required_approving_review_count from 1 to 0"
expect_out "the refusal names the flag" "--allow-weakening"
expect_writes "--apply alone records no write for a lowered approval count" 0

# --- absence is never a value ----------------------------------------------------
for edit in 'del(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count)' \
            '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = null' \
            '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = "0"' \
            '.conditions.ref_name.include = null' \
            '.conditions.ref_name |= del(.exclude)'; do
  new_case; script_live baseline "$edit" "$SETTINGS_STALE"
  run "$APPLY" "$R" baseline --apply --allow-bypass-removal
  expect_exit "absent/null/retyped live key ($edit) is refused by --apply alone" 2
  expect_out "absent/null/retyped live key ($edit) is named as weakens" "weakens: "
  expect_writes "absent/null/retyped live key ($edit) writes nothing" 0
done

# --- an unusable live read: exit 2, no write of any kind ---------------------------
# Settings differ and the dependabot file is absent, and every flag is passed, so
# a write that came before the failing read would show in the log.
unusable() {   # <name> <scripting to replace one read>
  new_case; script_live baseline "$FOUR_ACTORS" "$SETTINGS_STALE"
  respond GET "$CONTENTS" 1 - "gh: Not Found (HTTP 404)"
  eval "$2"
  run "$APPLY" "$R" baseline --with-dependabot=python "${EVERY_FLAG[@]}"
  expect_exit "unusable read ($1) exits 2" 2
  expect_writes "unusable read ($1) writes nothing, not even the writes that come first" 0
}
# control: with no read replaced, the same harness writes and exits 0
new_case; script_live baseline "$FOUR_ACTORS" "$SETTINGS_STALE"
respond GET "$CONTENTS" 1 - "gh: Not Found (HTTP 404)"
run "$APPLY" "$R" baseline --with-dependabot=python "${EVERY_FLAG[@]}"
expect_exit "control: with every read usable the same run exits 0" 0
expect_order "control: with every read usable all three writes happen" "PATCH $RS,PUT $CONTENTS,PUT $RS/rulesets/111"
OTHER_REPO='{"id":1,"full_name":"example-org/someone-else","allow_auto_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
for body in '' 'null' '[]' '"x"' "$OTHER_REPO" '{"id":1,"full_name":"example-org/example-repo"}' "$SETTINGS_OK $SETTINGS_OK"; do
  unusable "settings body '${body:0:40}'" "rebuild GET '$RS' 0 '$body'"
done
unusable "settings read fails" "rebuild GET '$RS' 1 - 'gh: boom (HTTP 500)'"
for body in '' 'null' '{}' '[{"id":"x","name":"reporulez-default"}]' '[{"id":111,"name":"reporulez-default"}] [{"id":111,"name":"reporulez-default"}]'; do
  unusable "list body '${body:0:30}'" "rebuild GET '$RS/rulesets' 0 '$body'"
done
unusable "list read fails" "rebuild GET '$RS/rulesets' 1 - 'gh: boom (HTTP 500)'"
D="$(as_live "$BASELINE")"
for body in '' 'null' '[]' '{}' "$(jq -c '.id = 999' <<< "$D")" "$(jq -c '.name = "other"' <<< "$D")" "$(jq -c 'del(.bypass_actors)' <<< "$D")" \
            "$(jq -c '.bypass_actors = null' <<< "$D")" "$D $D"; do
  unusable "detail body '${body:0:30}'" "rebuild GET '$RS/rulesets/111' 0 '$body'"
done
unusable "detail read fails" "rebuild GET '$RS/rulesets/111' 1 - 'gh: boom (HTTP 500)'"
unusable "contents read fails (not a 404)" "rebuild GET '$CONTENTS' 1 - 'gh: boom (HTTP 500)'"
unusable "contents body is null" "rebuild GET '$CONTENTS' 0 'null'"
unusable "contents body is another file" "rebuild GET '$CONTENTS' 0 '{\"path\":\"x\",\"sha\":\"a\",\"encoding\":\"base64\",\"content\":\"\"}'"

# two live rulesets of the preset's name, or a near-name: refused, nothing written
new_case; script_live baseline "." "$SETTINGS_STALE"
rebuild GET "$RS/rulesets" 0 '[{"id":111,"name":"reporulez-default"},{"id":112,"name":"reporulez-default"}]'
run "$APPLY" "$R" baseline "${EVERY_FLAG[@]}"
expect_exit "two live rulesets of the name exits 2" 2
expect_writes "two live rulesets of the name writes nothing" 0
new_case; script_live baseline "." "$SETTINGS_STALE"
rebuild GET "$RS/rulesets" 0 '[{"id":111,"name":"Reporulez Default"}]'
run "$APPLY" "$R" baseline "${EVERY_FLAG[@]}"
expect_exit "a near-name live ruleset exits 2" 2
expect_writes "a near-name live ruleset writes nothing" 0

# --- the dependabot file ---------------------------------------------------------
new_case; script_live baseline
respond GET "$CONTENTS" 1 - "gh: Not Found (HTTP 404)"
run "$APPLY" "$R" baseline --with-dependabot=python
expect_exit "dry run: an absent file is a difference" 1
expect_out "dry run: an absent file would be CREATED" "would CREATE it from template 'python'"
expect_writes "dry run: an absent file is not written" 0
new_case; script_live baseline "." "$SETTINGS_STALE"
respond GET "$CONTENTS" 1 - "gh: Not Found (HTTP 404)"
run "$APPLY" "$R" baseline --with-dependabot=python --apply
expect_exit "--apply creates the file" 0
expect_order "--apply writes the settings and the file, and leaves an identical ruleset alone" "PATCH $RS,PUT $CONTENTS"
new_case; script_live baseline
respond GET "$CONTENTS" 0 "$(contents_of python)"
run "$APPLY" "$R" baseline --with-dependabot=python --apply
expect_exit "a file that matches the template is no difference" 0
expect_out "a matching file says so" "no difference: .github/dependabot.yml"
expect_writes "a matching file is not written" 0
new_case; script_live baseline
respond GET "$CONTENTS" 0 "$(contents_of typescript)"
run "$APPLY" "$R" baseline --with-dependabot=python --apply
expect_exit "--apply replaces a differing file" 0
expect_order "--apply replaces only the file when nothing else differs" "PUT $CONTENTS"

# all three writes, in order, on a repo with nothing set up yet
new_case; script_live baseline
rebuild GET "$RS/rulesets" 0 '[{"id":9,"name":"unrelated"}]'
rebuild GET "$RS" 0 "$SETTINGS_STALE"
respond GET "$CONTENTS" 1 - "gh: Not Found (HTTP 404)"
run "$APPLY" "$R" baseline --with-dependabot=python
expect_exit "dry run on a bare repo exits 1" 1
expect_out "dry run on a bare repo would CREATE the ruleset" "no live ruleset named 'reporulez-default' on '$R'; --apply would CREATE it"
expect_writes "dry run on a bare repo writes nothing" 0
new_case; script_live baseline
rebuild GET "$RS/rulesets" 0 '[{"id":9,"name":"unrelated"}]'
rebuild GET "$RS" 0 "$SETTINGS_STALE"
respond GET "$CONTENTS" 1 - "gh: Not Found (HTTP 404)"
run "$APPLY" "$R" baseline --with-dependabot=python --apply
expect_exit "--apply on a bare repo exits 0" 0
expect_order "all three writes, in order: settings, file, ruleset" "PATCH $RS,PUT $CONTENTS,POST $RS/rulesets"

# a write that fails stops the run and says what was written before it
new_case; script_live baseline "." "$SETTINGS_STALE"
rebuild PATCH "$RS" 1 - "gh: boom (HTTP 500)"
run "$APPLY" "$R" baseline --apply
expect_exit "a failed settings write exits 2" 2
expect_out "a failed first write says nothing was written before it" "already written in this run: nothing"
expect_order "nothing more is written after a failed write" "PATCH $RS"

# --- arguments and exit codes -----------------------------------------------------
for bad in --allow-loosening --aply -apply --apply=true; do
  new_case; script_live baseline
  run "$APPLY" "$R" baseline "$bad"
  expect_exit "unknown argument '$bad' exits 2" 2
  expect_writes "unknown argument '$bad' writes nothing" 0
done
new_case; script_live baseline
run "$APPLY" not-a-repo
expect_exit "a repo without an owner exits 2" 2
run "$APPLY"
expect_exit "no arguments exits 2" 2
run "$APPLY" "$R" baseline --with-dependabot=ruby --apply
expect_exit "an unknown ecosystem exits 2" 2
run "$APPLY" "$R" baseline --no-bypass-admin --apply
expect_exit "--no-bypass-admin is still refused by the validator" 2
expect_writes "--no-bypass-admin writes nothing" 0
new_case; script_live skdd
run "$APPLY" "$R" skdd --extra-check 'pytest (ubuntu-latest / py3.12)' --apply
expect_exit "--extra-check adds a required check: a tightening --apply alone writes" 0
expect_out "--extra-check is labelled tightens" "tightens: adds required status check pytest (ubuntu-latest / py3.12)"
for alias in external clud-bug-logmind; do
  new_case
  if [[ "$alias" == "clud-bug-logmind" ]]; then script_live skdd; else script_live baseline; fi
  run "$APPLY" "$R" "$alias"
  expect_exit "deprecated alias '$alias' still works" 0
done

# an unexpected internal failure (mktemp fails: under set -e that is exit 1,
# the "difference exists" code) is reported as 2
mkdir -p "$WORK/badbin"
cat > "$WORK/badbin/mktemp" <<'BADMKTEMP'
#!/usr/bin/env bash
# fails only for apply.sh itself, so the validator it runs first still works
if ps -o args= -p "$PPID" | grep -q 'apply\.sh'; then exit 1; fi
exec /usr/bin/mktemp "$@"
BADMKTEMP
chmod +x "$WORK/badbin/mktemp"
new_case; script_live baseline "$FOUR_ACTORS"
OUT="$(PATH="$WORK/badbin:$WORK/bin:$PATH" "$APPLY" "$R" baseline --apply 2>&1)"; CODE=$?
expect_exit "an unexpected internal failure exits 2, never 1" 2
expect_out "an unexpected internal failure says so" "unexpected failure (exit 1)"
expect_writes "an unexpected internal failure writes nothing" 0

# --help prints the whole usage text
new_case
run "$APPLY" --help
expect_exit "apply --help exits 0" 0
for want in "DRY RUN BY DEFAULT" "Exit codes" "--allow-weakening" "--allow-bypass-removal" "ORDER, so nothing is half-applied" "Known limit"; do
  expect_out "apply --help carries '$want'" "$want"
done

# --- one implementation ------------------------------------------------------------
# The comparison is defined once, in the library, and both scripts source it.
n="$(cat "$APPLY" "$APPLY_ORG" "$LIB" | grep -c 'def each_difference')"
[[ "$n" -eq 1 ]]; record "the comparison is defined exactly once" $(( $? == 0 )) "found $n definitions"
grep -q 'def each_difference' "$LIB"; record "the one definition is in bin/ruleset-compare.sh" $(( $? == 0 )) "not in the library"
for s in "$APPLY" "$APPLY_ORG"; do
  grep -q '^source "\$COMPARE"' "$s"; record "$(basename "$s") sources the library" $(( $? == 0 )) "no source line"
done

# --- the fetched library cannot be half-loaded ------------------------------------
# With bin/ruleset-compare.sh not beside the script, both scripts fetch it. A
# failed fetch, an empty file and an error page each end in exit 2 before ANY gh
# call (reads and `gh auth` included). A fake curl stands in for the network and
# a gh that logs every invocation proves the order.
mkdir -p "$WORK/fetchbin" "$WORK/solo/bin"
cat > "$WORK/fetchbin/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
case "${FAKE_CURL_MODE:-fail}" in
  fail) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
  empty) : > "$out"; exit 0 ;;
  html) printf '<!DOCTYPE html>\n<html><body>404: Not Found</body></html>\n' > "$out"; exit 0 ;;
esac
FAKECURL
cat > "$WORK/fetchbin/gh" <<'FAKEANYGH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ANY_GH_LOG"
exit 0
FAKEANYGH
chmod +x "$WORK/fetchbin/curl" "$WORK/fetchbin/gh"
cp "$APPLY" "$APPLY_ORG" "$WORK/solo/bin/"
for mode in fail empty html; do
  for pair in "apply.sh|$R" "apply-org.sh|example-org"; do
    script="${pair%%|*}"; arg="${pair#*|}"
    new_case
    export FAKE_ANY_GH_LOG="$FAKE_GH_DIR/any.log"; : > "$FAKE_ANY_GH_LOG"
    OUT="$(FAKE_CURL_MODE="$mode" PATH="$WORK/fetchbin:$PATH" "$WORK/solo/bin/$script" "$arg" 2>&1)"; CODE=$?
    expect_exit "$script: library fetch '$mode' exits 2" 2
    expect_out "$script: library fetch '$mode' says so" "ruleset-compare.sh"
    ok=0; [[ -s "$FAKE_ANY_GH_LOG" ]] && ok=1
    record "$script: library fetch '$mode' makes no gh call of any kind" $(( 1 - ok )) "gh was called: $(tr '\n' ';' < "$FAKE_ANY_GH_LOG")"
  done
done

echo
echo "$PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
