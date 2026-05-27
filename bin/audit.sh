#!/usr/bin/env bash
# Audit the canonical repo settings that apply.sh installs, across one
# or more target repositories. Read-only — never mutates anything.
#
# Drift is INFORMATIONAL by default — the audit surfaces divergences
# from the reporulez canonical settings but always exits 0. Repos may
# legitimately diverge (e.g. tokenomics with auto-merge disabled
# during active doc work). The audit is a starting point for noticing;
# the human decides whether each drift is intentional or stale.
#
# Use --strict to flip the policy: exit 1 on any drift, suitable for a
# scheduled CI gate that fails when any repo drifts.
#
# Usage: audit.sh <owner/repo>...
#        audit.sh --all <owner>
#        audit.sh [--strict] [--quiet] <repos...|--all owner>
#
# Modes:
#   <owner/repo>...   Audit each named repo. Useful from CI or for spot-
#                     checking a few repos.
#   --all <owner>     Enumerate every repo under <owner> and audit
#                     each. Filters out archived repos. Useful as an
#                     org-wide drift check.
#
# Flags:
#   --strict          Exit 1 when any drift is detected (default exit 0).
#   --quiet           Only print drift rows (skip the ✓ matches).
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
# a final summary.
#
# Remediation when drift is unintentional: re-run apply.sh on that repo
# with the appropriate variant. See `apply.sh --help`.

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }

usage() {
  sed -n '2,42p' "$0" | sed 's/^# //; s/^#//'
}

# Defaults — flipped by --strict / --quiet flags below.
STRICT="false"
QUIET="false"

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
  local repo_has_drift=0
  local lines=()

  local json
  json="$(gh api "repos/$repo" 2>&1)" || {
    echo
    echo "── $repo ──"
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
      lines+=("$(printf '  ✓ %-32s = %s' "$key" "$actual")")
    else
      lines+=("$(printf '  ✗ %-32s = %s (expected: %s)' "$key" "$actual" "$expected")")
      repo_has_drift=1
      DRIFT_FOUND=1
    fi
    i=$((i+2))
  done

  # In --quiet mode, only print this repo's section if there's drift.
  if [[ "$QUIET" == "true" && "$repo_has_drift" -eq 0 ]]; then
    return
  fi

  echo
  echo "── $repo ──"
  for line in "${lines[@]}"; do
    # In --quiet, only print the ✗ lines.
    if [[ "$QUIET" == "true" && "$line" != *"✗"* ]]; then
      continue
    fi
    echo "$line"
  done
}

# Argument parsing. Flags can appear before or after positional repos.
[[ $# -ge 1 ]] || { usage; exit 1; }

REPOS=()
USE_ALL_OWNER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    --strict) STRICT="true"; shift ;;
    --quiet)  QUIET="true";  shift ;;
    --all)
      [[ $# -ge 2 ]] || die "--all requires an owner argument (e.g. --all thrillmade)"
      # Guard against `--all --quiet thrillmade`: the next arg must NOT
      # be another flag. Without this check, --all would silently
      # swallow the next flag as the owner name.
      case "$2" in
        --*) die "--all requires an owner argument; got flag '$2' instead. Put '$2' before or after the --all <owner> pair." ;;
      esac
      USE_ALL_OWNER="$2"; shift 2 ;;
    *)
      # Positional repo. Verify owner/repo form before any API call.
      [[ "$1" == */* ]] || die "repo must be in owner/repo form, got: $1"
      REPOS+=("$1"); shift ;;
  esac
done

if [[ -n "$USE_ALL_OWNER" ]]; then
  [[ ${#REPOS[@]} -eq 0 ]] || die "--all is mutually exclusive with positional repos"
  info "Enumerating non-archived repos under $USE_ALL_OWNER"
  while read -r REPO; do
    REPOS+=("$REPO")
  done < <(gh api --paginate "orgs/$USE_ALL_OWNER/repos?per_page=100" \
            --jq '.[] | select(.archived == false) | .full_name')
  [[ ${#REPOS[@]} -gt 0 ]] || die "no non-archived repos found under $USE_ALL_OWNER"
fi

[[ ${#REPOS[@]} -gt 0 ]] || { usage; exit 1; }

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
fi

# Drift was detected. Default behavior is informational — repos may
# legitimately diverge. Use --strict to make this an error suitable
# for a CI gate.
if [[ "$STRICT" == "true" ]]; then
  echo "✗ drift detected (--strict). Remediation: re-run \`apply.sh <owner/repo> <variant>\` on each drifted repo whose drift is unintentional."
  exit 1
else
  echo "ℹ drift detected. This is INFORMATIONAL — repos may legitimately diverge. Use --strict to make this exit 1 (suitable for CI gate). Remediation when unintentional: re-run \`apply.sh <owner/repo> <variant>\`."
  exit 0
fi
