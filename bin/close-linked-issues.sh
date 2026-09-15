#!/usr/bin/env bash
# Close every issue a merged PR's body says it closes (reporulez#71 ask C).
#
# The logic half of .github/workflows/close-linked-issues.yml -- pulled
# into its own script, like bin/extract-closed-issues.sh, specifically so
# it is unit-testable (tests/test-close-linked-issues.sh) rather than
# living only as an untested block of workflow YAML. This script shells
# out to `gh` by plain $PATH lookup, so tests inject a stub `gh` ahead of
# it on PATH instead of hitting the real API -- see the test file for the
# stub contract.
#
# Usage:
#   close-linked-issues.sh --repo <owner/repo> --pr-number <N> \
#     --merge-sha <sha> --base-branch <branch> [--dry-run] \
#     [--summary-file <path>] < pr-body.txt
#
# Env:
#   GH_TOKEN            Token for same-repo `gh` calls. Required unless
#                        --dry-run.
#   CROSS_REPO_TOKEN     Optional token for cross-repo `gh` calls. If
#                        unset/empty, every cross-repo reference found is
#                        reported NOT CLOSED and counts as a failure --
#                        see "Design decisions" in the calling workflow's
#                        header comment for why silence is not an option
#                        here.
#
# --summary-file, if given, gets a GitHub-Step-Summary-flavored markdown
# table appended (matches $GITHUB_STEP_SUMMARY's contract: append, don't
# overwrite). Always prints a shorter human log to stdout regardless.
#
# Exit 0: no linked issues found (the common case -- most merged PRs
#         don't close anything), OR every linked issue was closed or was
#         already closed.
# Exit 1: at least one linked issue could not be closed -- a real `gh`
#         failure (permission, not found, rate-limit), or a cross-repo
#         reference with no CROSS_REPO_TOKEN configured. This job runs
#         AFTER the PR already merged, so failing it blocks nothing --
#         but it keeps the run red and visible instead of silently
#         closing fewer issues than the PR body asked for.
# Exit 2: usage error, or extract-closed-issues.sh itself failed --
#         mirrors this repo's die()-uses-2 convention.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT="$SCRIPT_DIR/extract-closed-issues.sh"

die() { echo "error: $*" >&2; exit 2; }

usage() {
  sed -n '2,26p' "$0" | sed 's/^# //; s/^#//'
}

REPO=""
PR_NUMBER=""
MERGE_SHA=""
BASE_BRANCH=""
DRY_RUN="false"
SUMMARY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)         [[ $# -ge 2 ]] || die "--repo requires a value"; REPO="$2"; shift 2 ;;
    --pr-number)    [[ $# -ge 2 ]] || die "--pr-number requires a value"; PR_NUMBER="$2"; shift 2 ;;
    --merge-sha)    [[ $# -ge 2 ]] || die "--merge-sha requires a value"; MERGE_SHA="$2"; shift 2 ;;
    --base-branch)  [[ $# -ge 2 ]] || die "--base-branch requires a value"; BASE_BRANCH="$2"; shift 2 ;;
    --summary-file) [[ $# -ge 2 ]] || die "--summary-file requires a value"; SUMMARY_FILE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN="true"; shift ;;
    *) die "unrecognized argument: $1" ;;
  esac
done

[[ -n "$REPO" ]] || die "--repo is required"
[[ -x "$EXTRACT" || -r "$EXTRACT" ]] || die "extract-closed-issues.sh not found next to this script ($EXTRACT)"
command -v jq >/dev/null || die "jq not found"
command -v gh >/dev/null || die "gh CLI not found on PATH"

summary() {
  [[ -n "$SUMMARY_FILE" ]] && printf '%s\n' "$*" >> "$SUMMARY_FILE"
}

BODY_TEXT="$(cat)" || die "failed to read PR body from stdin"

FOUND_JSON="$(printf '%s' "$BODY_TEXT" | bash "$EXTRACT" --repo "$REPO")"
EXTRACT_RC=$?
if [[ "$EXTRACT_RC" -ne 0 ]]; then
  echo "error: extract-closed-issues.sh failed (exit $EXTRACT_RC) -- treating as a failure, not a silent no-op." >&2
  summary "## close linked issues: FAILED"
  summary "extract-closed-issues.sh exited $EXTRACT_RC on this PR's body."
  exit 2
fi

SAME_REPO_COUNT="$(jq '.same_repo | length' <<< "$FOUND_JSON")"
CROSS_REPO_COUNT="$(jq '.cross_repo | length' <<< "$FOUND_JSON")"

summary "## close linked issues (PR #$PR_NUMBER -> $BASE_BRANCH)"

if [[ "$SAME_REPO_COUNT" -eq 0 && "$CROSS_REPO_COUNT" -eq 0 ]]; then
  summary "No closing-keyword issue references found in the PR body."
  echo "No linked issues found."
  exit 0
fi

summary "| Issue | Repo | Action | Result |"
summary "|---|---|---|---|"

ANY_FAILURE=0
COMMENT_BODY="Closed by #${PR_NUMBER} (merged ${MERGE_SHA}) into \`${BASE_BRANCH}\`. Promotes to \`main\` at the next dev→main squash promotion."

# close_one <repo> <number> <token> -- shared by both loops below. Prints
# one summary row; returns 0 for clean/idempotent outcomes, 1 for a real
# failure. `cmd && rc=0 || rc=$?` (not a bare trailing `$?` check) so a
# future edit that inserts a command between the capture and the check
# can't silently clobber which exit status is being read.
close_one() {
  local repo="$1" num="$2" token="$3"
  local state rc
  state="$(GH_TOKEN="$token" gh api "repos/$repo/issues/$num" --jq '.state' 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "error: could not read repos/$repo/issues/$num: $state" >&2
    summary "| #$num | $repo | close | ✗ FAILED (could not read issue: permission denied, not found, or rate-limited) |"
    return 1
  fi
  if [[ "$state" == "closed" ]]; then
    echo "#$num ($repo) already closed -- no action."
    summary "| #$num | $repo | close | already closed (no action) |"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would close #$num ($repo)"
    summary "| #$num | $repo | close | (dry-run, not attempted) |"
    return 0
  fi
  local close_err
  close_err="$(GH_TOKEN="$token" gh issue close "$num" --repo "$repo" --comment "$COMMENT_BODY" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "closed #$num ($repo)"
    summary "| #$num | $repo | close | ✓ closed |"
    return 0
  else
    echo "error: failed to close $repo#$num: $close_err" >&2
    summary "| #$num | $repo | close | ✗ FAILED ($close_err) |"
    return 1
  fi
}

# `< <(...)` process substitution, not `cmd | while read`, deliberately --
# a piped while-loop runs its body in a subshell, and ANY_FAILURE set
# inside it would never reach the exit-code check below. Process
# substitution keeps the loop body in THIS shell.
while IFS= read -r num; do
  [[ -n "$num" ]] || continue
  close_one "$REPO" "$num" "${GH_TOKEN:-}" || ANY_FAILURE=1
done < <(jq -r '.same_repo[]' <<< "$FOUND_JSON")

while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  repo="$(jq -r '.repo' <<< "$row")"
  num="$(jq -r '.number' <<< "$row")"
  if [[ -z "${CROSS_REPO_TOKEN:-}" ]]; then
    echo "error: PR body references $repo#$num but no CROSS_REPO_TOKEN is configured -- NOT closed." >&2
    summary "| #$num | $repo | close | ✗ NOT CLOSED (no cross-repo-token configured) |"
    ANY_FAILURE=1
    continue
  fi
  close_one "$repo" "$num" "$CROSS_REPO_TOKEN" || ANY_FAILURE=1
done < <(jq -c '.cross_repo[]' <<< "$FOUND_JSON")

if [[ "$ANY_FAILURE" -ne 0 ]]; then
  summary "One or more issues were not closed. See the ✗ rows above."
  exit 1
fi
summary "All linked issues closed."
exit 0
