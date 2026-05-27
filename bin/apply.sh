#!/usr/bin/env bash
# Apply the reporulez default ruleset + repo settings to a target repository.
#
# Usage: apply.sh <owner/repo> [copilot|external|clud-bug-logmind] \
#                              [--human-review] \
#                              [--bypass-admin | --no-bypass-admin] \
#                              [--extra-check 'CONTEXT NAME']...
#
# Defaults: copilot variant, no human review required (AI auto-mode). Bypass
# actors default OFF for copilot/external and ON for clud-bug-logmind (its
# self-mod use case practically always needs the Repository admin bypass —
# see --bypass-admin docs below). Override per-variant default with
# --bypass-admin (force on) or --no-bypass-admin (force off).
#
# The clud-bug-logmind variant extends external with a required_status_checks
# rule for the canonical contexts shipped by both tools (clud-bug-review,
# check-derived-docs, check-decisions, check-links) and strict_required_status_checks_policy: true
# so branches must be up to date — load-bearing for logmind's per-PR
# derived-file conflict-free property.
#
# --bypass-admin pre-populates bypass_actors with "Repository admin" (RepositoryRole
# id=5, bypass_mode=always). On clud-bug-logmind this is the DEFAULT (use
# --no-bypass-admin to opt out) because clud-bug's review action 401s on
# PRs that edit its own workflow files (self-mod guard), so the required
# clud-bug-review check fails and merge deadlocks. The bypass lets an admin
# merge those self-mod PRs without disabling the whole ruleset. On copilot
# and external variants the default is OFF — opt in with --bypass-admin
# only if you also have a self-mod ceremony to support.
#
# --extra-check 'CONTEXT NAME' is repeatable and adds project-specific status
# check contexts (e.g. pytest matrix slots) to the ruleset's required_status_checks
# list at apply time. Lets a single apply.sh call match a project's actual CI
# without forking the variant JSON. Requires the chosen variant to ship a
# required_status_checks rule — works with clud-bug-logmind; errors out cleanly
# on copilot/external (which deliberately don't ship that rule).

set -euo pipefail

RAW_BASE="${REPORULEZ_RAW_BASE:-https://raw.githubusercontent.com/thrillmade/reporulez/main}"
RULESET_NAME="reporulez-default"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }
warn() { echo "!!  $*" >&2; }

usage() {
  sed -n '2,35p' "$0" | sed 's/^# //; s/^#//'
}

[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

REPO="$1"; shift
VARIANT="copilot"
HUMAN_REVIEW="false"
BYPASS_ADMIN=""  # sentinel: empty = use per-variant default; "true"/"false" = explicit
EXTRA_CHECKS=()  # parallel array of context names; preserves order

while [[ $# -gt 0 ]]; do
  case "$1" in
    copilot|external|clud-bug-logmind) VARIANT="$1"; shift ;;
    --human-review) HUMAN_REVIEW="true"; shift ;;
    --bypass-admin) BYPASS_ADMIN="true"; shift ;;
    --no-bypass-admin) BYPASS_ADMIN="false"; shift ;;
    --extra-check)
      [[ $# -ge 2 ]] || die "--extra-check requires a CONTEXT NAME argument"
      EXTRA_CHECKS+=("$2"); shift 2 ;;
    --extra-check=*)
      EXTRA_CHECKS+=("${1#--extra-check=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Per-variant default for BYPASS_ADMIN when caller didn't pass the flag.
# clud-bug-logmind defaults ON because the variant's self-mod use case
# (clud-bug's claude-code-action 401s on PRs editing its own workflow
# files) practically always needs the Repository admin bypass — without
# it, every self-mod PR deadlocks. copilot/external default OFF because
# they don't have a self-mod ceremony built in. Explicit --bypass-admin
# or --no-bypass-admin always wins over the default.
if [[ -z "$BYPASS_ADMIN" ]]; then
  case "$VARIANT" in
    clud-bug-logmind) BYPASS_ADMIN="true" ;;
    *)                BYPASS_ADMIN="false" ;;
  esac
fi

[[ "$REPO" == */* ]] || die "repo must be in owner/repo form, got: $REPO"
command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
command -v jq >/dev/null || die "jq not found (brew install jq)"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

# Load the ruleset JSON. Use the local file if running from a checkout, else fetch.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JSON="$SCRIPT_DIR/../rulesets/${VARIANT}.json"
if [[ -f "$LOCAL_JSON" ]]; then
  RULESET_JSON="$(cat "$LOCAL_JSON")"
  info "Using local ruleset: $LOCAL_JSON"
else
  URL="$RAW_BASE/rulesets/${VARIANT}.json"
  info "Fetching ruleset: $URL"
  RULESET_JSON="$(curl -fsSL "$URL")" || die "failed to fetch $URL"
fi

# Patch the pull_request rule if --human-review:
# - required_approving_review_count: 0 -> 1
# - require_last_push_approval: false -> true (last pusher's commits need a non-pusher
#   approval; only meaningful when an approval is actually required)
if [[ "$HUMAN_REVIEW" == "true" ]]; then
  info "Patching pull_request rule for human review (count=1, last_push_approval=true)"
  # Precondition: a pull_request rule must exist, otherwise the patch silently no-ops.
  echo "$RULESET_JSON" | jq -e '.rules | any(.type == "pull_request")' >/dev/null \
    || die "--human-review requested but ruleset has no pull_request rule"
  RULESET_JSON="$(echo "$RULESET_JSON" | jq '
    (.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = 1
    | (.rules[] | select(.type == "pull_request") | .parameters.require_last_push_approval) = true
  ')"
fi

# Patch bypass_actors if --bypass-admin: Repository admin role (id=5) gets
# bypass_mode=always. Lets repo admins merge PRs that legitimately can't
# satisfy every required check (e.g. clud-bug self-mod PRs where the
# clud-bug-review action 401s by design on its own workflow edits) without
# disabling the ruleset globally.
if [[ "$BYPASS_ADMIN" == "true" ]]; then
  info "Patching bypass_actors: Repository admin (RepositoryRole id=5, bypass_mode=always)"
  # Append + dedupe rather than replace, so any bypass_actors entries that a
  # future variant ships (or that the user added manually) survive. Identity
  # is the (actor_type, actor_id) pair — actor_id is scoped per actor_type.
  RULESET_JSON="$(echo "$RULESET_JSON" | jq '
    .bypass_actors |= (
      . + [{ actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always" }]
      | unique_by([.actor_type, .actor_id])
    )
  ')"
fi

# Patch required_status_checks with each --extra-check value. Lets a single
# apply.sh call add project-specific contexts (e.g. pytest matrix slots) without
# forking the variant JSON. The variant must already ship a required_status_checks
# rule (currently only clud-bug-logmind does); other variants deliberately omit
# that rule because GitHub's API rejects an empty checks list.
if [[ ${#EXTRA_CHECKS[@]} -gt 0 ]]; then
  echo "$RULESET_JSON" | jq -e '.rules | any(.type == "required_status_checks")' >/dev/null \
    || die "--extra-check requires a variant that ships required_status_checks (use clud-bug-logmind, or skip --extra-check and add the rule manually in the UI)"
  for ctx in "${EXTRA_CHECKS[@]}"; do
    info "Adding required status check context: $ctx"
    RULESET_JSON="$(echo "$RULESET_JSON" | CTX="$ctx" jq '
      (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
        |= (. + [{"context": env.CTX}] | unique_by(.context))
    ')"
  done
fi

# 1. Tune repo-level settings that rulesets cannot control.
info "Configuring repo settings on $REPO (auto-merge, squash-only, delete-on-merge)"
gh api --method PATCH "repos/$REPO" --silent \
  -F allow_auto_merge=true \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=PR_BODY \
  || die "failed to PATCH repo settings on $REPO (free private repos can't auto-merge or delete-on-merge — make the repo public or upgrade to GitHub Pro)"

# 2. Apply ruleset. If one with the same name exists, PATCH it. Otherwise POST.
RULESETS_JSON="$(gh api --paginate "repos/$REPO/rulesets")" \
  || die "failed to list existing rulesets on $REPO"
EXISTING_ID="$(echo "$RULESETS_JSON" \
  | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id' \
  | head -n1)"

TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT
echo "$RULESET_JSON" > "$TMP_JSON"

if [[ -n "$EXISTING_ID" ]]; then
  info "Updating existing ruleset id=$EXISTING_ID"
  gh api --method PUT "repos/$REPO/rulesets/$EXISTING_ID" --input "$TMP_JSON" --silent \
    || die "failed to update ruleset $EXISTING_ID on $REPO"
else
  info "Creating new ruleset"
  gh api --method POST "repos/$REPO/rulesets" --input "$TMP_JSON" --silent \
    || die "failed to create ruleset on $REPO (rulesets require a public repo or GitHub Pro for private repos)"
fi

# 3. Follow-up checklist (cannot be done safely or automatically).
cat >&2 <<EOF

OK. Ruleset '$RULESET_NAME' applied to $REPO (variant: $VARIANT, human review: $HUMAN_REVIEW, bypass admin: $BYPASS_ADMIN).

Next steps you should do manually:
EOF

if [[ "$VARIANT" == "clud-bug-logmind" ]]; then
  # The clud-bug-logmind variant already ships required_status_checks with the
  # four canonical contexts, so the manual "add a status-checks rule" step is
  # skipped here. The most important caveat for this variant is below.
  cat >&2 <<EOF
  1. (Optional) Drop in templates/CODEOWNERS and templates/pull_request_template.md.
  2. Confirm BOTH clud-bug AND logmind are installed on this repo. The ruleset's
     required_status_checks rule pins four contexts (clud-bug-review,
     check-derived-docs, check-decisions, check-links) that come from those
     tools' workflows. If either tool is missing, those checks will never
     report on PRs and every PR will block forever (strict_required_status_checks_policy
     is on). Install with:
       npx clud-bug init
       logmind init --all-agents --install-hook
EOF
  if [[ "$BYPASS_ADMIN" != "true" ]]; then
    cat >&2 <<EOF
  3. You opted OUT of admin bypass via --no-bypass-admin. Heads up: clud-bug's
     review action refuses (401) to review PRs that edit its own workflow files,
     so the required clud-bug-review check fails and merge deadlocks on self-mod
     PRs (e.g. version bumps of clud-bug itself). Without the bypass you'll need
     to either disable the ruleset for those merges or hand-PATCH bypass_actors.
     If you change your mind, re-run with --bypass-admin (now the default for
     this variant):
       ./bin/apply.sh $REPO clud-bug-logmind --bypass-admin
EOF
  fi
else
  cat >&2 <<EOF
  1. Add a 'Require status checks to pass' rule with your CI workflow names via
     Settings -> Rules -> Rulesets -> '$RULESET_NAME' -> Require status checks to pass.
     (The ruleset ships without this rule because GitHub's API rejects an empty list.)
  2. (Optional) Drop in templates/CODEOWNERS and templates/pull_request_template.md.
EOF
  if [[ "$VARIANT" == "copilot" ]]; then
    cat >&2 <<EOF
  3. Confirm Copilot code review is licensed for this repo (Pro/Pro+/Business).
     The copilot_code_review rule is inert without entitlement.
EOF
  else
    cat >&2 <<EOF
  3. Confirm a non-Copilot AI reviewer GitHub App is installed (e.g. Anthropic's
     Claude Code Review, CodeRabbit, Cursor) and configured to comment on every PR.
     Without one, the thread-resolution gate has nothing to gate on.
EOF
  fi
fi
