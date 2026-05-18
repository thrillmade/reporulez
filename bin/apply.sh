#!/usr/bin/env bash
# Apply the reporulez default ruleset + repo settings to a target repository.
#
# Usage: apply.sh <owner/repo> [copilot|external|clud-bug-logmind] \
#                              [--human-review] \
#                              [--extra-check 'CONTEXT NAME']...
#
# Defaults: copilot variant, no human review required (AI auto-mode).
#
# The clud-bug-logmind variant extends external with a required_status_checks
# rule for the canonical contexts shipped by both tools (clud-bug-review,
# check-derived-docs, check-decisions, check-links) and strict_required_status_checks_policy: true
# so branches must be up to date — load-bearing for logmind's per-PR
# derived-file conflict-free property.
#
# --extra-check 'CONTEXT NAME' is repeatable and adds project-specific status
# check contexts (e.g. pytest matrix slots) to the ruleset's required_status_checks
# list at apply time. Lets a single apply.sh call match a project's actual CI
# without forking the variant JSON. Requires the chosen variant to ship a
# required_status_checks rule — works with clud-bug-logmind; errors out cleanly
# on copilot/external (which deliberately don't ship that rule).

set -euo pipefail

RAW_BASE="${REPORULEZ_RAW_BASE:-https://raw.githubusercontent.com/thrillmot/reporulez/main}"
RULESET_NAME="reporulez-default"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }
warn() { echo "!!  $*" >&2; }

usage() {
  sed -n '2,12p' "$0" | sed 's/^# //; s/^#//'
}

[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

REPO="$1"; shift
VARIANT="copilot"
HUMAN_REVIEW="false"
EXTRA_CHECKS=()  # parallel array of context names; preserves order

while [[ $# -gt 0 ]]; do
  case "$1" in
    copilot|external|clud-bug-logmind) VARIANT="$1"; shift ;;
    --human-review) HUMAN_REVIEW="true"; shift ;;
    --extra-check)
      [[ $# -ge 2 ]] || die "--extra-check requires a CONTEXT NAME argument"
      EXTRA_CHECKS+=("$2"); shift 2 ;;
    --extra-check=*)
      EXTRA_CHECKS+=("${1#--extra-check=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

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

OK. Ruleset '$RULESET_NAME' applied to $REPO (variant: $VARIANT, human review: $HUMAN_REVIEW).

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
