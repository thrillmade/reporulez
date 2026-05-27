#!/usr/bin/env bash
# Audit the canonical repo settings that apply.sh installs, across one
# or more target repositories. Read-only — never mutates anything.
#
# Usage: audit.sh <owner/repo>...
#        audit.sh --all <owner>
#
# Modes:
#   <owner/repo>...   Audit each named repo. Useful from CI or for spot-
#                     checking a few repos.
#   --all <owner>     Enumerate every repo under <owner> and audit
#                     each. Filters out archived repos. Useful as an
#                     org-wide drift check.
#
# What it checks (everything `apply.sh` sets via `gh api PATCH repos/`):
#   - allow_auto_merge:        true
#   - allow_squash_merge:      true
#   - allow_merge_commit:      false
#   - allow_rebase_merge:      false
#   - delete_branch_on_merge:  true
#   - squash_merge_commit_title:   PR_TITLE
#   - squash_merge_commit_message: PR_BODY
#
# Output: one row per repo per setting, ✓ for match / ✗ for drift, with
# a final summary. Exit code 0 when all repos match; 1 when any drift
# is detected (suitable for CI gate).
#
# Remediation: drift on any setting → re-run apply.sh on that repo with
# the appropriate variant. See `apply.sh --help`.

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }

usage() {
  sed -n '2,29p' "$0" | sed 's/^# //; s/^#//'
}

# Expected values for each canonical setting. Pairs: KEY EXPECTED.
# Order matters only for display.
EXPECTED_SETTINGS=(
  "allow_auto_merge"             "true"
  "allow_squash_merge"           "true"
  "allow_merge_commit"           "false"
  "allow_rebase_merge"           "false"
  "delete_branch_on_merge"       "true"
  "squash_merge_commit_title"    "PR_TITLE"
  "squash_merge_commit_message"  "PR_BODY"
)

# Track drift globally so the exit code reflects it.
DRIFT_FOUND=0

audit_one() {
  local repo="$1"
  echo
  echo "── $repo ──"

  local json
  json="$(gh api "repos/$repo" 2>&1)" || {
    echo "  ✗ failed to GET repos/$repo (not found, no access, or rate-limited)"
    DRIFT_FOUND=1
    return
  }

  local i=0
  local n=${#EXPECTED_SETTINGS[@]}
  while [[ $i -lt $n ]]; do
    local key="${EXPECTED_SETTINGS[$i]}"
    local expected="${EXPECTED_SETTINGS[$((i+1))]}"
    # `jq -r` returns "null" for missing keys; treat as drift.
    local actual
    actual="$(printf '%s' "$json" | jq -r --arg k "$key" '.[$k]')"

    if [[ "$actual" == "$expected" ]]; then
      printf '  ✓ %-32s = %s\n' "$key" "$actual"
    else
      printf '  ✗ %-32s = %s (expected: %s)\n' "$key" "$actual" "$expected"
      DRIFT_FOUND=1
    fi
    i=$((i+2))
  done
}

# Argument parsing.
[[ $# -ge 1 ]] || { usage; exit 1; }

REPOS=()
case "$1" in
  -h|--help)
    usage; exit 0 ;;
  --all)
    [[ $# -ge 2 ]] || die "--all requires an owner argument (e.g. --all thrillmade)"
    OWNER="$2"; shift 2
    [[ $# -eq 0 ]] || die "--all takes one owner argument; got extra: $*"
    info "Enumerating non-archived repos under $OWNER"
    # Pull every repo, filter out archived. jq `-c` keeps one per line
    # for the while-read loop.
    while read -r REPO; do
      REPOS+=("$REPO")
    done < <(gh api --paginate "orgs/$OWNER/repos?per_page=100" \
              --jq '.[] | select(.archived == false) | .full_name')
    [[ ${#REPOS[@]} -gt 0 ]] || die "no non-archived repos found under $OWNER"
    ;;
  *)
    # Positional repos. Verify each is in owner/repo form before any API call.
    for arg in "$@"; do
      [[ "$arg" == */* ]] || die "repo must be in owner/repo form, got: $arg"
      REPOS+=("$arg")
    done
    ;;
esac

command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
command -v jq >/dev/null || die "jq not found (brew install jq)"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

info "Auditing ${#REPOS[@]} repo(s) for canonical reporulez settings"

for repo in "${REPOS[@]}"; do
  audit_one "$repo"
done

echo
if [[ "$DRIFT_FOUND" -eq 0 ]]; then
  echo "✓ no drift detected across ${#REPOS[@]} repo(s)."
  exit 0
else
  echo "✗ drift detected. Remediation: re-run \`apply.sh <owner/repo> <variant>\` on each drifted repo."
  exit 1
fi
