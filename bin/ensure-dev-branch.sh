#!/usr/bin/env bash
# Ensure a `dev` branch exists on one or more repos — the other half of the
# org-staging ruleset (reporulez#71 ruling 2: "`dev` is the staging/
# integration branch, on every repo"). `org-staging` (rulesets/org-staging.json,
# applied via bin/apply-org.sh <org> org-staging) targets `refs/heads/dev`
# on every repo in the org, but a ruleset only protects a ref that exists —
# it does not create one. This script is the tool half of "a repo missing
# `dev` ... is corrected by the tool rather than by hand."
#
# Usage: ensure-dev-branch.sh <owner/repo>...
#        ensure-dev-branch.sh --all <owner> [--dry-run] [--strict]
#
# Modes:
#   <owner/repo>...   Ensure `dev` exists on each named repo.
#   --all <owner>     Enumerate every non-archived repo under <owner> and
#                     ensure `dev` on each.
#
# Flags:
#   --dry-run   Report what would be created; create nothing.
#   --strict    Exit 1 if any repo still lacks `dev` (or has its default
#               branch set to something other than `main`) after the run —
#               suitable for a CI gate. Default: always exit 0 (informational).
#
# What it does, per repo:
#   1. GETs the repo's default_branch. If it is not `main`, WARNS loudly and
#      does NOT attempt a fix — flipping a repo's default branch is a repo
#      setting, not a ref this script creates, and doing it silently is
#      exactly the failure mode docs/branch-policy.md exists to prevent
#      (reporulez#71: production rulesets key on `~DEFAULT_BRANCH`; flipping
#      it moves them onto whatever is now default). A human decides that
#      one, not this script.
#   2. Checks whether `refs/heads/dev` already exists.
#      - If it does: left untouched. This script never force-updates or
#        resets an existing `dev` — it only fills the gap of a MISSING one,
#        never overwrites real staging work.
#      - If it does not (and not --dry-run): creates `refs/heads/dev`
#        pointing at the default branch's current HEAD commit, via
#        `POST /repos/{owner}/{repo}/git/refs`. This is additive only — it
#        cannot lose data, at worst it creates a branch identical to
#        wherever the default branch already was.
#
# Idempotent: safe to re-run. A repo that already has `dev` is a no-op.
#
# Requires the `gh` CLI authenticated with `repo` scope (or `public_repo`
# for public-only) and `jq`.

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }
warn() { echo "!!  $*" >&2; }

usage() {
  sed -n '2,26p' "$0" | sed 's/^# //; s/^#//'
}

DRY_RUN="false"
STRICT="false"
REPOS=()
USE_ALL_OWNER=""

[[ $# -ge 1 ]] || { usage; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --strict)  STRICT="true";  shift ;;
    --all)
      [[ $# -ge 2 ]] || die "--all requires an owner argument (e.g. --all thrillmade)"
      case "$2" in
        --*) die "--all requires an owner argument; got flag '$2' instead." ;;
      esac
      USE_ALL_OWNER="$2"; shift 2 ;;
    *)
      [[ "$1" == */* ]] || die "repo must be in owner/repo form, got: $1"
      REPOS+=("$1"); shift ;;
  esac
done

command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
command -v jq >/dev/null || die "jq not found (brew install jq)"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

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

CREATED=0
ALREADY_OK=0
WOULD_CREATE=0
DEFAULT_BRANCH_DRIFT=0

info "Checking ${#REPOS[@]} repo(s) for a \`dev\` branch"

for REPO in "${REPOS[@]}"; do
  REPO_JSON="$(gh api "repos/$REPO" 2>/dev/null)" || { warn "$REPO: could not read repo (skipping)"; continue; }
  DEFAULT_BRANCH="$(echo "$REPO_JSON" | jq -r '.default_branch')"

  if [[ "$DEFAULT_BRANCH" != "main" ]]; then
    warn "$REPO: default branch is '$DEFAULT_BRANCH', not 'main' — reporulez#71's production" \
         "rulesets key on ~DEFAULT_BRANCH + refs/heads/main explicitly, so main stays protected," \
         "but $DEFAULT_BRANCH now ALSO gets production rules layered on top of org-staging." \
         "NOT auto-fixed: flipping a repo's default branch is a human decision (docs/branch-policy.md)."
    DEFAULT_BRANCH_DRIFT=$((DEFAULT_BRANCH_DRIFT + 1))
  fi

  if gh api "repos/$REPO/branches/dev" >/dev/null 2>&1; then
    echo "✓ $REPO: dev already exists"
    ALREADY_OK=$((ALREADY_OK + 1))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "would-create $REPO: dev (from $DEFAULT_BRANCH)"
    WOULD_CREATE=$((WOULD_CREATE + 1))
    continue
  fi

  HEAD_SHA="$(gh api "repos/$REPO/git/ref/heads/$DEFAULT_BRANCH" --jq '.object.sha' 2>/dev/null)" \
    || { warn "$REPO: could not read HEAD of '$DEFAULT_BRANCH' (skipping dev creation)"; continue; }
  [[ -n "$HEAD_SHA" && "$HEAD_SHA" != "null" ]] \
    || { warn "$REPO: empty HEAD sha for '$DEFAULT_BRANCH' (skipping dev creation)"; continue; }

  if gh api --method POST "repos/$REPO/git/refs" \
       -f ref="refs/heads/dev" -f sha="$HEAD_SHA" --silent 2>/dev/null; then
    echo "+ $REPO: created dev (from $DEFAULT_BRANCH @ ${HEAD_SHA:0:7})"
    CREATED=$((CREATED + 1))
  else
    warn "$REPO: failed to create dev (check repo permissions)"
  fi
done

echo >&2
info "Summary: ${ALREADY_OK} already had dev, ${CREATED} created, ${WOULD_CREATE} would-create (dry-run), ${DEFAULT_BRANCH_DRIFT} repo(s) with default branch != main"

if [[ "$STRICT" == "true" ]]; then
  STILL_MISSING=$((WOULD_CREATE))
  [[ "$DEFAULT_BRANCH_DRIFT" -eq 0 && "$STILL_MISSING" -eq 0 ]] || exit 1
fi

exit 0
