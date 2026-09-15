#!/usr/bin/env bash
# Fixture-driven regression suite for bin/close-linked-issues.sh
# (reporulez#71, ask C).
#
# Same harness shape as this repo's other test-*.sh files. The script
# under test shells out to `gh` by plain $PATH lookup -- this suite
# builds a fake `gh` (a bash script written per-test-case into a temp
# dir, prepended to PATH) that answers `gh api .../issues/N --jq .state`
# and `gh issue close N --repo R --comment C` however the test case
# needs, so the whole close-or-fail-or-already-closed decision tree is
# exercised without ever touching the real GitHub API.
#
# Usage: tests/test-close-linked-issues.sh
# Exit: 0 if every case matches its expected exit code and output, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLOSE="$REPO_ROOT/bin/close-linked-issues.sh"

PASS=0
FAIL=0
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# write_gh_stub <script-body> -- writes $STUB_DIR/gh with the given body
# (a bash case-style dispatcher, see call sites for the contract) and
# puts $STUB_DIR at the FRONT of PATH so it's found before any real `gh`.
write_gh_stub() {
  cat > "$STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
$1
EOF
  chmod +x "$STUB_DIR/gh"
  export PATH="$STUB_DIR:$PATH"
}

# assert_case <name> <expected_exit> <summary_pattern|-> <stdout_pattern|-> -- <cmd...>
# Runs the command, checks exit code, greps stdout+stderr for
# <stdout_pattern>, and (if a summary file was produced) greps it for
# <summary_pattern>. "-" skips that check.
assert_case() {
  local name="$1" expected_exit="$2" summary_pattern="$3" stdout_pattern="$4"
  shift 4
  local summary_file output exit_code
  summary_file="$(mktemp)"
  output="$("$@" --summary-file "$summary_file" 2>&1)"
  exit_code=$?

  local ok=1
  if [[ "$exit_code" -ne "$expected_exit" ]]; then
    ok=0
    echo "FAIL: $name -- expected exit $expected_exit, got $exit_code"
    echo "  output: $output"
  fi
  if [[ "$stdout_pattern" != "-" ]] && ! grep -qF -- "$stdout_pattern" <<< "$output"; then
    ok=0
    echo "FAIL: $name -- stdout/stderr did not contain: $stdout_pattern"
    echo "  output: $output"
  fi
  if [[ "$summary_pattern" != "-" ]] && ! grep -qF -- "$summary_pattern" "$summary_file"; then
    ok=0
    echo "FAIL: $name -- summary file did not contain: $summary_pattern"
    echo "  summary: $(cat "$summary_file")"
  fi

  rm -f "$summary_file"
  if [[ "$ok" -eq 1 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

COMMON_ARGS=(--repo thrillmade/reporulez --pr-number 99 --merge-sha deadbeef --base-branch dev)

# --- no linked issues: exit 0, not an error -----------------------------

write_gh_stub 'echo "gh should not be called for this test" >&2; exit 9'
GH_TOKEN=x assert_case "PR body with no closing keywords: exit 0, gh never invoked" 0 \
  "No closing-keyword" "No linked issues found" \
  bash -c "echo 'just a docs fix, nothing to close' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- same-repo: open issue gets closed -----------------------------------

write_gh_stub '
case "$1 $2" in
  "api repos/thrillmade/reporulez/issues/12")
    echo "open" ;;
  *) ;;
esac
if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "closed #$3"
  exit 0
fi
'
GH_TOKEN=x assert_case "open same-repo issue gets closed" 0 \
  "✓ closed" "closed #12" \
  bash -c "echo 'Closes #12' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- same-repo: already-closed issue is a no-op, not a failure -----------

write_gh_stub '
if [[ "$1" == "api" ]]; then
  echo "closed"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "SHOULD NOT BE CALLED: attempted to close an already-closed issue" >&2
  exit 1
fi
'
GH_TOKEN=x assert_case "already-closed issue: no action, not a failure" 0 \
  "already closed" "already closed" \
  bash -c "echo 'Fixes #7' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- same-repo: gh api read failure is a real failure ---------------------

write_gh_stub '
if [[ "$1" == "api" ]]; then
  echo "HTTP 403: Forbidden" >&2
  exit 1
fi
'
GH_TOKEN=x assert_case "gh api failure (permission/not-found) fails the job, not silently" 1 \
  "FAILED" "error:" \
  bash -c "echo 'Closes #3' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- a stray stderr warning alongside a successful `gh api` call must not
# pollute the compared state value (clud-bug PR #74 review, minor
# finding): stdout (the --jq '.state' value) and stderr are now captured
# SEPARATELY. Scenario chosen to actually distinguish the two
# implementations (an earlier version of this test used an "open" issue,
# which happened to behave the same either way and so proved nothing --
# caught by mutation-testing the fix: reverting the stdout/stderr
# separation to a merged 2>&1 left this repo's suite fully green,
# 11/11, an unpinned fix). An ALREADY-CLOSED issue is the case that
# actually differs: merge stderr noise onto a "closed" stdout value and
# it stops comparing equal to "closed" exactly, so close_one wrongly
# falls through and attempts to re-close an issue that's already closed.

write_gh_stub '
if [[ "$1" == "api" ]]; then
  echo "gh: a harmless warning on stderr" >&2
  echo "closed"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "SHOULD NOT BE CALLED: attempted to re-close an already-closed issue" >&2
  exit 1
fi
'
GH_TOKEN=x assert_case "stderr warning alongside a 'closed' state does not defeat the already-closed check" 0 \
  "already closed" "already closed" \
  bash -c "echo 'Closes #3' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- same-repo: gh issue close failure is a real failure -------------------

write_gh_stub '
if [[ "$1" == "api" ]]; then
  echo "open"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "HTTP 403: Resource not accessible by integration" >&2
  exit 1
fi
'
GH_TOKEN=x assert_case "gh issue close failure fails the job" 1 \
  "FAILED" "error: failed to close" \
  bash -c "echo 'Closes #3' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- dry-run: never calls gh issue close, always exits 0 -------------------

write_gh_stub '
if [[ "$1" == "api" ]]; then
  echo "open"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "SHOULD NOT BE CALLED under --dry-run" >&2
  exit 1
fi
'
GH_TOKEN=x assert_case "--dry-run reports what would close, never closes anything" 0 \
  "dry-run, not attempted" "[dry-run] would close" \
  bash -c "echo 'Closes #3' | \"$CLOSE\" \"\${@}\" --dry-run" _ "${COMMON_ARGS[@]}"

# --- cross-repo: no CROSS_REPO_TOKEN configured -> counted as a failure,
# never a silent skip (the design decision the workflow's header comment
# and reporulez#71 both call out explicitly) -----------------------------

write_gh_stub 'echo "gh should not be called: no cross-repo-token configured" >&2; exit 9'
GH_TOKEN=x assert_case "cross-repo reference with no CROSS_REPO_TOKEN fails loudly, not silently" 1 \
  "NOT CLOSED (no cross-repo-token" "no CROSS_REPO_TOKEN is configured" \
  bash -c "echo 'Fixes thrillmade/other#5' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- cross-repo: WITH a token configured, closes exactly like same-repo --

write_gh_stub '
if [[ "$1" == "api" ]]; then
  echo "open"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "closed"
  exit 0
fi
'
GH_TOKEN=x CROSS_REPO_TOKEN=y assert_case "cross-repo reference WITH a token configured closes normally" 0 \
  "✓ closed" "closed" \
  bash -c "echo 'Fixes thrillmade/other#5' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- mixed: one same-repo succeeds, one cross-repo has no token -- overall
# job must still fail (the good outcome does not mask the bad one) --------

write_gh_stub '
if [[ "$1" == "api" ]]; then
  echo "open"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "close" ]]; then
  echo "closed"
  exit 0
fi
'
GH_TOKEN=x assert_case "one success + one unconfigured-cross-repo: job still fails overall" 1 \
  "NOT CLOSED" "error:" \
  bash -c "echo 'Closes #1. Also fixes thrillmade/other#2' | \"$CLOSE\" \"\${@}\"" _ "${COMMON_ARGS[@]}"

# --- usage errors: exit 2 -------------------------------------------------

write_gh_stub 'exit 9'
GH_TOKEN=x assert_case "--repo is required" 2 \
  "-" "--repo is required" \
  bash -c "echo 'Closes #1' | \"$CLOSE\" --pr-number 1 --merge-sha x --base-branch dev"

echo
echo "$PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
