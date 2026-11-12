#!/usr/bin/env bash
# Ensure a `dev` branch exists on one or more repos — the other half of the
# org-staging ruleset (reporulez#71 ruling 2: "`dev` is the staging/
# integration branch, on every repo"). `org-staging` targets `refs/heads/dev`
# on every repo in the org, but a ruleset only protects a ref that exists —
# it does not create one.
#
# Usage: ensure-dev-branch.sh <owner/repo>... [--apply] [--strict] [--include-forks]
#        ensure-dev-branch.sh --all <owner> [--apply] [--strict] [--include-forks]
#
# DRY RUN BY DEFAULT: without --apply nothing is created, and the run reports
# which repos would get a `dev` branch.
#
# Modes:
#   <owner/repo>...   Check each named repo.
#   --all <owner>     Check every repo in the org <owner>.
#
# Flags:
#   --apply          Create `dev` where it is missing. Without it, nothing is written.
#   --dry-run        The default; accepted so older invocations keep working.
#   --include-forks  Also check forks (skipped by default). Archived repos are always skipped.
#   --strict         Also exit 1 when any checked repo still lacks `dev` after
#                    the run, or has a default branch other than `main`.
#
# Exit codes: 0 every repo was read and nothing failed; 1 --strict and a repo
# still lacks `dev` or has a non-`main` default branch; 2 a usage error, or
# any repo that failed or could not be read.
#
# What it does, per repo:
#   1. Reads the repo. Archived repos, and forks unless --include-forks, are
#      skipped. A repo that cannot be read counts as failed.
#   2. If the default branch is not `main`, warns and does NOT fix it —
#      flipping a default branch is a human decision (docs/branch-policy.md).
#   3. Reads `branches/dev`. Present: left untouched. 404: missing. Any other
#      failure: counted as failed ("could not read"), never treated as missing.
#   4. Missing and --apply: creates `refs/heads/dev` at the default branch's
#      current HEAD via `POST /repos/{owner}/{repo}/git/refs`. Additive only.
#
# Never changes a default branch, never force-updates or deletes a branch.
# Prints five counts at the end: created, already-present, would-create,
# skipped, failed.
#
# Requires the `gh` CLI authenticated with `repo` scope (or `public_repo`
# for public-only) and `jq`.

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }
warn() { echo "!!  $*" >&2; }

usage() {
  sed -n '2,27p' "$0" | sed 's/^# //; s/^#//'
}

APPLY="false"
DRY_RUN_FLAG="false"
STRICT="false"
INCLUDE_FORKS="false"
REPOS=()
USE_ALL_OWNER=""

[[ $# -ge 1 ]] || { usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --apply)         APPLY="true";         shift ;;
    --dry-run)       DRY_RUN_FLAG="true";  shift ;;
    --strict)        STRICT="true";        shift ;;
    --include-forks) INCLUDE_FORKS="true"; shift ;;
    --all)
      [[ $# -ge 2 ]] || die "--all requires an owner argument (e.g. --all your-org)"
      case "$2" in
        --*) die "--all requires an owner argument; got flag '$2' instead." ;;
      esac
      USE_ALL_OWNER="$2"; shift 2 ;;
    --*) die "unknown flag: $1" ;;
    *)
      [[ "$1" == */* ]] || die "repo must be in owner/repo form, got: $1"
      REPOS+=("$1"); shift ;;
  esac
done

[[ "$APPLY" == "true" && "$DRY_RUN_FLAG" == "true" ]] && die "--apply and --dry-run contradict each other"

command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
command -v jq >/dev/null || die "jq not found (brew install jq)"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

if [[ -n "$USE_ALL_OWNER" ]]; then
  [[ ${#REPOS[@]} -eq 0 ]] || die "--all is mutually exclusive with positional repos"
  info "Enumerating repos under $USE_ALL_OWNER"
  LISTING="$(gh api --paginate "orgs/$USE_ALL_OWNER/repos?per_page=100" --jq '.[] | .full_name' 2>/dev/null)" \
    || die "could not list repos under $USE_ALL_OWNER"
  while IFS= read -r REPO; do
    [[ -n "$REPO" ]] && REPOS+=("$REPO")
  done <<< "$LISTING"
  [[ ${#REPOS[@]} -gt 0 ]] || die "no repos found under $USE_ALL_OWNER"
fi

[[ ${#REPOS[@]} -gt 0 ]] || { usage >&2; exit 2; }

CREATED=0
ALREADY_PRESENT=0
WOULD_CREATE=0
SKIPPED=0
FAILED=0
DEFAULT_BRANCH_DRIFT=0

if [[ "$APPLY" == "true" ]]; then
  info "Checking ${#REPOS[@]} repo(s) for a \`dev\` branch (--apply: missing ones will be created)"
else
  info "Checking ${#REPOS[@]} repo(s) for a \`dev\` branch (dry run: nothing will be created)"
fi

for REPO in "${REPOS[@]}"; do
  if ! REPO_JSON="$(gh api "repos/$REPO" 2>/dev/null)"; then
    echo "✗ $REPO: could not read repo"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [[ "$(echo "$REPO_JSON" | jq -r '.archived')" == "true" ]]; then
    echo "- $REPO: skipped (archived)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if [[ "$(echo "$REPO_JSON" | jq -r '.fork')" == "true" && "$INCLUDE_FORKS" != "true" ]]; then
    echo "- $REPO: skipped (fork; pass --include-forks to check it)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  DEFAULT_BRANCH="$(echo "$REPO_JSON" | jq -r '.default_branch')"
  if [[ "$DEFAULT_BRANCH" != "main" ]]; then
    if [[ "$DEFAULT_BRANCH" == "dev" ]]; then
      warn "$REPO: default branch is 'dev', not 'main'. The production rulesets target" \
           "~DEFAULT_BRANCH and refs/heads/main, so main keeps its protection and dev ALSO" \
           "gets production rules (approval, code-owner review, squash-only, linear history)" \
           "on top of org-staging. NOT auto-fixed: flipping a default branch is a human decision (docs/branch-policy.md)."
    else
      warn "$REPO: default branch is '$DEFAULT_BRANCH', not 'main'. The production rulesets target" \
           "~DEFAULT_BRANCH and refs/heads/main, so main keeps its protection and '$DEFAULT_BRANCH'" \
           "ALSO gets production rules (approval, code-owner review, squash-only, linear history)." \
           "NOT auto-fixed: flipping a default branch is a human decision (docs/branch-policy.md)."
    fi
    DEFAULT_BRANCH_DRIFT=$((DEFAULT_BRANCH_DRIFT + 1))
  fi

  # Only a 404 means "no dev branch". Any other failure (rate limit, 5xx,
  # permission) is a read we could not make -- never a reason to create.
  if DEV_ERR="$(gh api "repos/$REPO/branches/dev" 2>&1 >/dev/null)"; then
    echo "✓ $REPO: dev already present"
    ALREADY_PRESENT=$((ALREADY_PRESENT + 1))
    continue
  fi
  if [[ "$DEV_ERR" != *"(HTTP 404)"* ]]; then
    echo "✗ $REPO: could not read branches/dev (not treated as missing): ${DEV_ERR//$'\n'/ }"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [[ "$APPLY" != "true" ]]; then
    echo "would-create $REPO: dev (from $DEFAULT_BRANCH)"
    WOULD_CREATE=$((WOULD_CREATE + 1))
    continue
  fi

  if ! HEAD_SHA="$(gh api "repos/$REPO/git/ref/heads/$DEFAULT_BRANCH" --jq '.object.sha' 2>/dev/null)" \
     || [[ -z "$HEAD_SHA" || "$HEAD_SHA" == "null" ]]; then
    echo "✗ $REPO: could not read HEAD of '$DEFAULT_BRANCH' (dev not created)"
    FAILED=$((FAILED + 1))
    continue
  fi

  if gh api --method POST "repos/$REPO/git/refs" \
       -f ref="refs/heads/dev" -f sha="$HEAD_SHA" --silent 2>/dev/null; then
    echo "+ $REPO: created dev (from $DEFAULT_BRANCH @ ${HEAD_SHA:0:7})"
    CREATED=$((CREATED + 1))
  else
    echo "✗ $REPO: failed to create dev (check repo permissions)"
    FAILED=$((FAILED + 1))
  fi
done

echo
echo "Summary: ${CREATED} created, ${ALREADY_PRESENT} already-present, ${WOULD_CREATE} would-create, ${SKIPPED} skipped, ${FAILED} failed"
[[ "$DEFAULT_BRANCH_DRIFT" -eq 0 ]] || echo "${DEFAULT_BRANCH_DRIFT} repo(s) have a default branch other than main"

if [[ "$FAILED" -gt 0 ]]; then
  echo "✗ ${FAILED} repo(s) failed or could not be read."
  exit 2
fi

if [[ "$STRICT" == "true" ]] && [[ "$WOULD_CREATE" -gt 0 || "$DEFAULT_BRANCH_DRIFT" -gt 0 ]]; then
  echo "✗ --strict: ${WOULD_CREATE} repo(s) still lack dev, ${DEFAULT_BRANCH_DRIFT} have a default branch other than main."
  exit 1
fi

exit 0
