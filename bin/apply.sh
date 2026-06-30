#!/usr/bin/env bash
# Apply the reporulez default ruleset + repo settings to a target repository.
#
# Usage: apply.sh <owner/repo> [copilot|external|skdd] \
#                              [--human-review] \
#                              [--bypass-admin | --no-bypass-admin] \
#                              [--extra-check 'CONTEXT NAME']... \
#                              [--with-dependabot=<ecosystem>]
#
# Defaults: copilot variant, no human review required (AI auto-mode). Bypass
# actors default OFF for copilot/external and ON for skdd (its
# self-mod use case practically always needs the Repository admin bypass —
# see --bypass-admin docs below). Override per-variant default with
# --bypass-admin (force on) or --no-bypass-admin (force off).
#
# The skdd variant extends external with a required_status_checks
# rule for the canonical contexts shipped by both tools (clud-bug-review,
# check-derived-docs, check-decisions, check-links) and strict_required_status_checks_policy: true
# so branches must be up to date — load-bearing for logmind's per-PR
# derived-file conflict-free property.
#
# --bypass-admin pre-populates bypass_actors with "Repository admin" (RepositoryRole
# id=5, bypass_mode=always). On skdd this is the DEFAULT (use
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
# required_status_checks rule — works with skdd; errors out cleanly
# on copilot/external (which deliberately don't ship that rule).
#
# --with-dependabot=<ecosystem> writes the matching templates/dependabot/<eco>.yml
# template to the target repo's .github/dependabot.yml in the same apply.sh call.
# Replaces the prior two-step install (apply.sh then a separate curl). Allowed
# values: python, typescript, github-actions-only. Idempotent — re-running
# with the same flag does NOT create a duplicate commit when the file is
# already current. Silently overwrites any existing dependabot.yml at the
# target path (consistent with how other flags overwrite the ruleset on
# re-apply). Omit the flag to keep the prior behaviour (no .github/dependabot.yml
# touched). Templates land at templates/dependabot/ via reporulez PR #15.

set -euo pipefail

RAW_BASE="${REPORULEZ_RAW_BASE:-https://raw.githubusercontent.com/thrillmade/reporulez/main}"
RULESET_NAME="reporulez-default"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }
warn() { echo "!!  $*" >&2; }

usage() {
  sed -n '2,44p' "$0" | sed 's/^# //; s/^#//'
}

# Whitelist for --with-dependabot. Used both for input validation and to
# build the human-readable error message when an unknown value is passed.
VALID_DEPENDABOT_ECOSYSTEMS=(python typescript github-actions-only)
is_valid_dependabot_eco() {
  local v
  for v in "${VALID_DEPENDABOT_ECOSYSTEMS[@]}"; do
    [[ "$v" == "$1" ]] && return 0
  done
  return 1
}

[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

REPO="$1"; shift
VARIANT="copilot"
HUMAN_REVIEW="false"
BYPASS_ADMIN=""  # sentinel: empty = use per-variant default; "true"/"false" = explicit
EXTRA_CHECKS=()  # parallel array of context names; preserves order
WITH_DEPENDABOT=""  # empty = skip the dependabot.yml step (default); otherwise the ecosystem slug

while [[ $# -gt 0 ]]; do
  case "$1" in
    copilot|external|skdd) VARIANT="$1"; shift ;;
    clud-bug-logmind) VARIANT="skdd"; shift ;;  # deprecated alias → skdd (renamed: the canonical SkDD-toolchain bundle)
    --human-review) HUMAN_REVIEW="true"; shift ;;
    --bypass-admin) BYPASS_ADMIN="true"; shift ;;
    --no-bypass-admin) BYPASS_ADMIN="false"; shift ;;
    --extra-check)
      [[ $# -ge 2 ]] || die "--extra-check requires a CONTEXT NAME argument"
      EXTRA_CHECKS+=("$2"); shift 2 ;;
    --extra-check=*)
      EXTRA_CHECKS+=("${1#--extra-check=}"); shift ;;
    --with-dependabot)
      [[ $# -ge 2 ]] || die "--with-dependabot requires an ecosystem (one of: ${VALID_DEPENDABOT_ECOSYSTEMS[*]})"
      WITH_DEPENDABOT="$2"; shift 2 ;;
    --with-dependabot=*)
      WITH_DEPENDABOT="${1#--with-dependabot=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Validate --with-dependabot against the whitelist before any network call,
# so a typo (e.g. --with-dependabot=ruby) fails fast instead of after the
# ruleset PATCH succeeds and only the file-write step explodes mid-apply.
if [[ -n "$WITH_DEPENDABOT" ]]; then
  is_valid_dependabot_eco "$WITH_DEPENDABOT" \
    || die "--with-dependabot value '$WITH_DEPENDABOT' is not a known ecosystem. Valid values: ${VALID_DEPENDABOT_ECOSYSTEMS[*]}"
fi

# Per-variant default for BYPASS_ADMIN when caller didn't pass the flag.
# skdd defaults ON because the variant's self-mod use case
# (clud-bug's claude-code-action 401s on PRs editing its own workflow
# files) practically always needs the Repository admin bypass — without
# it, every self-mod PR deadlocks. copilot/external default OFF because
# they don't have a self-mod ceremony built in. Explicit --bypass-admin
# or --no-bypass-admin always wins over the default.
if [[ -z "$BYPASS_ADMIN" ]]; then
  case "$VARIANT" in
    skdd) BYPASS_ADMIN="true" ;;
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
# rule (currently only skdd does); other variants deliberately omit
# that rule because GitHub's API rejects an empty checks list.
if [[ ${#EXTRA_CHECKS[@]} -gt 0 ]]; then
  echo "$RULESET_JSON" | jq -e '.rules | any(.type == "required_status_checks")' >/dev/null \
    || die "--extra-check requires a variant that ships required_status_checks (use skdd, or skip --extra-check and add the rule manually in the UI)"
  for ctx in "${EXTRA_CHECKS[@]}"; do
    info "Adding required status check context: $ctx"
    RULESET_JSON="$(echo "$RULESET_JSON" | CTX="$ctx" jq '
      (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
        |= (. + [{"context": env.CTX}] | unique_by(.context))
    ')"
  done
fi

# Single temp-file registry + cleanup trap. Tracks every tempfile we
# create so a single EXIT trap reliably removes them all. Each step
# appends to CLEANUP_FILES before / after mktemp, never registering a
# fresh trap (the prior multi-trap pattern silently shadowed the
# earlier trap on re-set).
CLEANUP_FILES=()
cleanup() { [[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}" || true; }
trap cleanup EXIT

# 1. Tune repo-level settings that rulesets cannot control. Step 1 is
#    safe at any point — it doesn't write to the default branch.
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

# 2. If --with-dependabot was passed, write the matching template to the
#    target repo's .github/dependabot.yml VIA THE CONTENTS API.
#
#    Step ORDER matters for the common case: this runs BEFORE the
#    ruleset is applied (step 3) so the contents PUT doesn't bump into
#    the ruleset's pull_request rule on a FIRST apply (when no
#    ruleset exists yet). The skdd variant ships an admin
#    bypass that papers over this anyway, but copilot/external variants
#    default `bypass_actors: []` and would otherwise reject this write
#    once the ruleset is in force.
#
#    Idempotency property holds: re-running apply.sh with the same
#    flag does not produce a new commit when the file is already
#    current (GET-base64-compare-skip).
#
#    KNOWN LIMITATION (ecosystem switch on re-apply, copilot/external
#    only): if the target repo already has the ruleset AND the caller
#    passes a different --with-dependabot value than was last applied,
#    the PUT executes against a still-protected branch and dies. The
#    workaround is either (a) delete the existing dependabot.yml in
#    the target repo via the GitHub UI before re-applying, or (b)
#    re-apply with --bypass-admin so the admin role can write through
#    the rule. Most repos commit to one dependabot ecosystem and never
#    switch, so this surface is narrow — documented in the README.
if [[ -n "$WITH_DEPENDABOT" ]]; then
  TEMPLATE_LOCAL="$SCRIPT_DIR/../templates/dependabot/${WITH_DEPENDABOT}.yml"
  # Base64 directly from the source bytes — never go through a `$(...)`
  # command substitution into a shell variable, because bash strips ALL
  # trailing newlines from `$(...)` output. The templates end in `\n`
  # (POSIX text-file convention); without the byte-exact trailing
  # newline the base64 wouldn't match GitHub's stored copy, the
  # idempotency comparison below would never short-circuit, and every
  # re-run would create a needless commit. Pipe-to-base64 preserves
  # the trailing newline.
  if [[ -f "$TEMPLATE_LOCAL" ]]; then
    info "Using local dependabot template: $TEMPLATE_LOCAL"
    TEMPLATE_B64="$(base64 < "$TEMPLATE_LOCAL" | tr -d '\n')"
  else
    TEMPLATE_URL="$RAW_BASE/templates/dependabot/${WITH_DEPENDABOT}.yml"
    info "Fetching dependabot template: $TEMPLATE_URL"
    TEMPLATE_B64="$(curl -fsSL "$TEMPLATE_URL" | base64 | tr -d '\n')" \
      || die "failed to fetch $TEMPLATE_URL"
  fi

  # Check whether the target file already exists. The contents API returns
  # 404 when the path is absent (handled below as "create" — sha omitted).
  # `gh api ... || true` swallows the nonzero exit so we can branch on the
  # response body rather than the exit code.
  CONTENTS_GET="$(gh api "repos/$REPO/contents/.github/dependabot.yml" 2>/dev/null || true)"
  EXISTING_SHA="$(echo "$CONTENTS_GET" | jq -r '.sha // empty')"
  EXISTING_B64="$(echo "$CONTENTS_GET" | jq -r '.content // empty' | tr -d '\n')"

  if [[ -n "$EXISTING_SHA" ]] && [[ "$EXISTING_B64" == "$TEMPLATE_B64" ]]; then
    info "Target .github/dependabot.yml already matches template '$WITH_DEPENDABOT' — skipping (idempotent)"
  else
    PUT_INPUT="$(mktemp)"
    CLEANUP_FILES+=("$PUT_INPUT")
    MSG="chore: dependabot config from reporulez (ecosystem=${WITH_DEPENDABOT})"
    if [[ -n "$EXISTING_SHA" ]]; then
      jq -n --arg msg "$MSG" --arg c "$TEMPLATE_B64" --arg s "$EXISTING_SHA" \
        '{message: $msg, content: $c, sha: $s}' > "$PUT_INPUT"
      info "Updating .github/dependabot.yml on $REPO (sha=$EXISTING_SHA)"
    else
      jq -n --arg msg "$MSG" --arg c "$TEMPLATE_B64" \
        '{message: $msg, content: $c}' > "$PUT_INPUT"
      info "Creating .github/dependabot.yml on $REPO"
    fi
    gh api --method PUT "repos/$REPO/contents/.github/dependabot.yml" --input "$PUT_INPUT" --silent \
      || die "failed to PUT .github/dependabot.yml on $REPO"
  fi
fi

# 3. Apply ruleset. If one with the same name exists, PATCH it. Otherwise POST.
RULESETS_JSON="$(gh api --paginate "repos/$REPO/rulesets")" \
  || die "failed to list existing rulesets on $REPO"
EXISTING_ID="$(echo "$RULESETS_JSON" \
  | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id' \
  | head -n1)"

TMP_JSON="$(mktemp)"
CLEANUP_FILES+=("$TMP_JSON")
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

# 4. Follow-up checklist (cannot be done safely or automatically).
cat >&2 <<EOF

OK. Ruleset '$RULESET_NAME' applied to $REPO (variant: $VARIANT, human review: $HUMAN_REVIEW, bypass admin: $BYPASS_ADMIN, dependabot: ${WITH_DEPENDABOT:-none}).

Next steps you should do manually:
EOF

if [[ "$VARIANT" == "skdd" ]]; then
  # The skdd variant already ships required_status_checks with the
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
       ./bin/apply.sh $REPO skdd --bypass-admin
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
