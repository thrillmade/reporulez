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
# CHECK_UNDER_TEST lets a red run point the suite at an older copy of the
# script; normal runs use the real one.
CHECK="${CHECK_UNDER_TEST:-$REPO_ROOT/bin/check-dependabot-target.sh}"
FIXTURES="$SCRIPT_DIR/fixtures/dependabot"

PASS=0
FAIL=0
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# A stub `gh` for the one test case below that exercises --all mode
# (`gh auth status` + org enumeration). Deliberately NOT a live API call:
# this repo's real `gh` session (an authenticated dev machine) and a bare
# CI runner (no `gh auth login` state at all -- test.yml exports no
# GH_TOKEN for this step) hit DIFFERENT failure paths for the same "org
# with zero repos" scenario -- one gets "examined zero repos" from a
# successful-but-empty enumeration, the other dies earlier at "gh not
# authenticated". Both are legitimately exit 2 (the guard the case is
# testing -- "examines nothing must not exit 0" -- holds either way), but
# asserting one specific message made the test depend on which
# environment it ran in. Found for real: this exact test passed locally
# (authenticated gh) and FAILED on GitHub Actions CI for
# thrillmade/reporulez#73 (output: "gh not authenticated") until this
# stub replaced the live call. The stub makes "auth succeeds, enumeration
# returns zero repos" the ONLY path exercised, in every environment.
cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then
  exit 0
fi
if [[ "$1" == "api" ]]; then
  exit 0   # success, empty output -- zero repos enumerated
fi
echo "unexpected stub gh invocation: $*" >&2
exit 9
EOF
chmod +x "$STUB_DIR/gh"

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

PATH="$STUB_DIR:$PATH" assert_case "--all against an org with zero (reachable) repos errors (exit 2), not a silent pass" 2 \
  "examined zero repos" \
  "$CHECK" --all "thrillmade-org-that-does-not-exist-in-this-test-namespace"

assert_case "--all requires an owner argument" 2 \
  "-" \
  "$CHECK" --all

# --- --all --quiet with MULTIPLE repos: the exact regression clud-bug's
# review of thrillmade/reporulez#73 caught for real -----------------------
#
# The original version of this suite never exercised --all against more
# than zero repos, so it never caught this: `FINDINGS="$(check_one ...)"`
# forks a subshell for the command substitution, and an earlier
# implementation set a "verdict" GLOBAL VARIABLE from inside check_one --
# which is lost the instant that subshell exits. Live consequence,
# reproduced and confirmed before the fix: `--all --quiet` against an org
# where EVERY repo was 100% compliant still exited 1, unconditionally,
# every single run -- because the caller's read of the verdict was always
# stale/empty, never "clean". Fixed by having check_one return its
# verdict via its own exit status instead (which DOES survive $(...) --
# `$?` after `x="$(f)"` reflects f's real exit code regardless of what
# f assigned to variables inside the subshell). These two cases pin
# exactly that: one all-clean multi-repo run (must exit 0), one mixed run
# where --quiet must print ONLY the non-compliant repo.

MULTI_STUB="$STUB_DIR/multi-repo-gh"
mkdir -p "$MULTI_STUB"
cat > "$MULTI_STUB/gh" <<'GHSTUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == --paginate ]]; then
  # $REPO_LIST is exported by the test case below, one repo per line.
  printf '%s\n' "$REPO_LIST"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  # repos/<repo>/contents/.github/dependabot.yml --jq .content
  case "$2" in
    *repo-bad*) printf 'version: 2\nupdates:\n  - package-ecosystem: "npm"\n' | base64 ;;
    *) printf 'version: 2\nupdates:\n  - package-ecosystem: "npm"\n    target-branch: "dev"\n' | base64 ;;
  esac
  exit 0
fi
echo "unexpected stub gh invocation: $*" >&2
exit 9
GHSTUB
chmod +x "$MULTI_STUB/gh"

REPO_LIST="thrillmade/all-clean-1
thrillmade/all-clean-2" \
PATH="$MULTI_STUB:$PATH" assert_case "--all --quiet, every repo compliant: exit 0 (was: always exited 1 before the fix)" 0 \
  "all 2 repo(s) target" \
  "$CHECK" --all thrillmade --quiet

REPO_LIST="thrillmade/repo-clean
thrillmade/repo-bad" \
PATH="$MULTI_STUB:$PATH" assert_case "--all --quiet, mixed compliance: exit 1, only the bad repo's finding prints" 1 \
  "thrillmade/repo-bad" \
  "$CHECK" --all thrillmade --quiet

# The case above only asserts repo-bad's line IS present (assert_case's
# single-pattern contract). The bug this pins specifically also printed
# the CLEAN repo's ✓ line in --quiet mode (every repo, every run, since
# the stale verdict was never "clean") -- assert separately that it does
# NOT.
QUIET_MIXED_OUTPUT="$(REPO_LIST="thrillmade/repo-clean
thrillmade/repo-bad" PATH="$MULTI_STUB:$PATH" "$CHECK" --all thrillmade --quiet 2>&1)"
if grep -qF "repo-clean" <<< "$QUIET_MIXED_OUTPUT"; then
  echo "FAIL: --all --quiet mixed compliance -- repo-clean's ✓ line leaked into quiet output (should be suppressed)"
  echo "  output: $QUIET_MIXED_OUTPUT"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
fi

# --- "a pass needs positive proof": a crash is never a tick -------------
# Found by review of reporulez#73: the Python side crashing (a traceback
# exits 1 with no PARSE_ERROR line) read as zero violations and printed a
# green tick. Each case below crashes or silences the interpreter in a
# different way; every one must be exit 2 "could not examine".

assert_case "ValueError from the YAML library (not YAMLError) beside a violating entry: exit 2, no tick" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/yaml-library-valueerror.yml"

VALUEERROR_OUT="$("$CHECK" "$FIXTURES/yaml-library-valueerror.yml" 2>&1)"
if grep -q '✓' <<< "$VALUEERROR_OUT"; then
  echo "FAIL: ValueError fixture printed a green tick"
  echo "  output: $VALUEERROR_OUT"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
fi

assert_case "invalid UTF-8 bytes: exit 2, no tick" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/invalid-utf8.yml"

# A killed interpreter: fake python3 that prints nothing and exits 137. It
# must still answer `import yaml` (the startup probe) so the run reaches
# the check itself.
KILLED_DIR="$STUB_DIR/killed-python"
mkdir -p "$KILLED_DIR"
cat > "$KILLED_DIR/python3" <<'PYSTUB'
#!/usr/bin/env bash
if [[ "$1" == "-c" ]]; then exit 0; fi
exit 137
PYSTUB
chmod +x "$KILLED_DIR/python3"
PATH="$KILLED_DIR:$PATH" assert_case "interpreter killed (exit 137, no output): exit 2, not a tick" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"

# Exit 0 but no RESULT line, and exit 0 with a garbled one: also not a pass.
SILENT_DIR="$STUB_DIR/silent-python"
mkdir -p "$SILENT_DIR"
cat > "$SILENT_DIR/python3" <<'PYSTUB'
#!/usr/bin/env bash
if [[ "$1" == "-c" ]]; then exit 0; fi
echo "${FAKE_PY_OUT:-}"
exit 0
PYSTUB
chmod +x "$SILENT_DIR/python3"
PATH="$SILENT_DIR:$PATH" FAKE_PY_OUT="" assert_case "exit 0 with no result line: exit 2, not a tick" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"
PATH="$SILENT_DIR:$PATH" FAKE_PY_OUT="RESULT: checked=lots violations=0" assert_case "exit 0 with an unparseable result line: exit 2, not a tick" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"

# Each guard on the RESULT line, pinned on its own: a fake python3 that
# prints FAKE_PY_OUT (backslash escapes expanded) and exits FAKE_PY_RC.
SCRIPTED_DIR="$STUB_DIR/scripted-python"
mkdir -p "$SCRIPTED_DIR"
cat > "$SCRIPTED_DIR/python3" <<'PYSTUB'
#!/usr/bin/env bash
if [[ "$1" == "-c" ]]; then exit 0; fi
printf '%b\n' "${FAKE_PY_OUT:-}"
exit "${FAKE_PY_RC:-0}"
PYSTUB
chmod +x "$SCRIPTED_DIR/python3"
PATH="$SCRIPTED_DIR:$PATH" FAKE_PY_RC=1 FAKE_PY_OUT="RESULT: checked=1 violations=0" assert_case "well-formed clean result line but non-zero exit: exit 2, not a tick" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"
PATH="$SCRIPTED_DIR:$PATH" FAKE_PY_OUT="RESULT: checked=1 violations=0\nRESULT: checked=1 violations=0" assert_case "two result lines: exit 2, not a tick" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"
PATH="$SCRIPTED_DIR:$PATH" FAKE_PY_OUT="VIOLATION: a\nVIOLATION: b\nRESULT: checked=2 violations=1" assert_case "more violation lines than the count says: exit 2" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"
PATH="$SCRIPTED_DIR:$PATH" FAKE_PY_OUT="VIOLATION: a\nRESULT: checked=2 violations=0" assert_case "fewer violation lines than the count says (count 0, one line): exit 2" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"
PATH="$SCRIPTED_DIR:$PATH" FAKE_PY_OUT="VIOLATION: a\\nVIOLATION: b\\nRESULT: checked=1 violations=2" assert_case "violations count (matching the lines printed) larger than entries checked: exit 2" 2 \
  "could not examine" \
  "$CHECK" "$FIXTURES/all-target-dev.yml"

# --- --all: a failed or partial listing is not a clean audit -------------
PARTIAL_DIR="$STUB_DIR/partial-listing-gh"
mkdir -p "$PARTIAL_DIR"
cat > "$PARTIAL_DIR/gh" <<'GHSTUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == --paginate ]]; then
  echo "thrillmade/first-page-repo"   # one page arrived, then the API failed
  exit 1
fi
if [[ "$1" == "api" ]]; then
  printf 'version: 2\nupdates:\n  - package-ecosystem: "npm"\n    target-branch: "dev"\n' | base64
  exit 0
fi
exit 9
GHSTUB
chmod +x "$PARTIAL_DIR/gh"
PATH="$PARTIAL_DIR:$PATH" assert_case "--all with a partial listing (gh fails after one page): exit 2, says so, no clean audit" 2 \
  "listing its repositories failed" \
  "$CHECK" --all thrillmade

# --- the reusable workflow's own YAML ------------------------------------
# No workflow runner here, so parse the file and pin the properties that
# review found broken: (1) the checkout identifies THIS file's repository
# through the `job` context -- inside a called workflow the `github`
# context is the CALLER's, so github.workflow_ref names the caller's
# workflow and (on a pull request) a refs/pull/N/merge ref that does not
# exist here; (2) no `inputs.*` is interpolated into a `run:` block.
WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-target-check.yml"
WF_RESULT="$(python3 - "$WORKFLOW" <<'PYEOF'
import re, sys, yaml
path = sys.argv[1]
raw = open(path).read()
doc = yaml.safe_load(raw)
steps = doc["jobs"]["check"]["steps"]
problems = []
checkouts = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
if len(checkouts) != 1:
    problems.append(f"expected exactly one checkout step, found {len(checkouts)}")
else:
    w = checkouts[0].get("with", {})
    if w.get("repository") != "${{ job.workflow_repository }}":
        problems.append(f"checkout repository is {w.get('repository')!r}, want job.workflow_repository")
    if w.get("ref") != "${{ job.workflow_sha }}":
        problems.append(f"checkout ref is {w.get('ref')!r}, want job.workflow_sha")
# Fail-closed guard: a step BEFORE the checkout takes both values via env:
# (not interpolated into run:) and emits ::error:: for an empty one.
idx = {id(s): i for i, s in enumerate(steps)}
guards = [s for s in steps if "job.workflow_repository" in str(s.get("env", {})) and "run" in s]
if len(guards) != 1:
    problems.append(f"expected exactly one guard step with job.workflow_* in env:, found {len(guards)}")
else:
    g = guards[0]
    genv = g.get("env", {})
    if "${{ job.workflow_sha }}" not in genv.values() or "${{ job.workflow_repository }}" not in genv.values():
        problems.append("guard step env: must take both job.workflow_repository and job.workflow_sha")
    if "${{" in g["run"]:
        problems.append("guard step interpolates ${{ }} inside run: (must use env:)")
    if "::error::" not in g["run"] or "exit 1" not in g["run"]:
        problems.append("guard step does not emit ::error:: and exit 1")
    for name in genv:
        if f'-z "${name}"' not in g["run"]:
            problems.append(f"guard step does not test {name} for empty")
    if len(checkouts) == 1 and idx[id(g)] > idx[id(checkouts[0])]:
        problems.append("guard step comes after the checkout")
# Executable text only (not comments, which may explain what NOT to use).
exec_text = yaml.safe_dump(doc)
if "github.workflow_ref" in exec_text or "GITHUB_WORKFLOW_REF" in exec_text:
    problems.append("github.workflow_ref is back (it is the caller's ref inside a called workflow)")
for s in steps:
    run = s.get("run")
    if run and re.search(r"\$\{\{\s*inputs\.", run):
        problems.append(f"step {s.get('name')!r} interpolates inputs.* into run:")
print("\n".join(problems) if problems else "OK")
PYEOF
)"
if [[ "$WF_RESULT" == "OK" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: dependabot-target-check.yml -- $WF_RESULT"
  FAIL=$((FAIL + 1))
fi

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
