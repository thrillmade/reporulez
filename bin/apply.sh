#!/usr/bin/env bash
# Compare (by default) or apply (with --apply) the reporulez default ruleset,
# repo settings and (optionally) dependabot config on a target repository.
#
# Usage: apply.sh <owner/repo> [baseline|clud-bug|skdd|public-guard] \
#                              [--apply] [--allow-weakening] [--allow-bypass-removal] \
#                              [--human-review] \
#                              [--bypass-admin | --no-bypass-admin] \
#                              [--extra-check 'CONTEXT NAME']... \
#                              [--with-dependabot=<ecosystem>]
#
# DRY RUN BY DEFAULT, for every write this script makes. Without --apply it
# makes no write call: it reads the live repo settings, the live
# .github/dependabot.yml (with --with-dependabot) and the live ruleset
# named 'reporulez-default', prints what each write would change, and writes
# nothing. Re-running it without --apply is always safe.
#
#   settings      each of the seven canonical keys whose live value differs
#   dependabot    whether the file would be created or replaced (content
#                 differs), or already matches the template
#   ruleset       the same labelled differences as bin/apply-org.sh: every
#                 difference is classified tightens, weakens or removes
#                 bypass (one implementation, bin/ruleset-compare.sh)
#
# Exit codes (no others: an unexpected internal failure is reported as 2):
#   0   no difference, or --apply wrote what was needed
#   1   dry run, and a difference exists (printed above)
#   2   refused or failed: usage error, invalid preset, a live read that
#       failed or returned nothing usable (including a body of more than one
#       JSON document, or a different repository or ruleset than asked for),
#       a live name that matches the preset's only by case or spacing, more
#       than one live ruleset of that name, a ruleset change --apply alone
#       may not make, or a write that failed
#
# ORDER, so nothing is half-applied: every read comes first -- repo
# settings, the dependabot file, the ruleset list and the ruleset -- and
# every refusal is decided from them before the first write. An unusable
# read, or a ruleset change that needs a flag, is exit 2 with nothing
# written. Only then, in this order: repo settings, the dependabot file,
# the ruleset. A write that itself fails stops the run and names what was
# already written; that is the one way to end half-applied.
#
# What --apply writes to the ruleset on its own: only a change it can show
# makes protection strictly tighter, or the create of a ruleset no live
# ruleset is named like. A weakening needs --allow-weakening; removing a
# live bypass actor, or narrowing its mode, needs --allow-bypass-removal.
# The two flags are independent: each permits only its own kind. An absent
# key, null, or a different JSON type is never read as a value (it weakens).
# The kinds are defined in the header of bin/apply-org.sh. The settings and
# the dependabot file are not classified: --apply writes them to the values
# above.
#
# The checked-in presets carry ONE bypass actor (Repository admin). A live
# ruleset extended by hand carries more, so a plain --apply on it is
# refused for removing them. Read the dry run, then decide.
#
# Known limit: a change made to the live ruleset between this script's read
# and its write is not detected.
#
# Defaults: baseline variant, no human review required (AI auto-mode). Every
# repo-level variant (baseline/clud-bug/public-guard/skdd) now SHIPS the
# Repository admin bypass in its rulesets/*.json — protocol SPEC section 6.6
# makes that bypass unconditional ("a change to a gate's own workflow cannot
# pass the gate it changes, and an incident fix cannot wait for one"), and
# bin/validate-ruleset.sh enforces it on every apply regardless of variant.
# --bypass-admin is therefore an idempotent no-op against the shipped
# default (kept for forked/hand-edited rulesets that don't carry it yet);
# --no-bypass-admin actively strips it — see the flag's own comment below
# for what that does to the pre-apply validation.
#
# The skdd variant extends baseline with a required_status_checks
# rule for the canonical contexts shipped by both tools (clud-bug-review,
# check-derived-docs, check-decisions, check-links) and strict_required_status_checks_policy: true
# so branches must be up to date — load-bearing for logmind's per-PR
# derived-file conflict-free property.
#
# --bypass-admin pre-populates bypass_actors with "Repository admin" (RepositoryRole
# id=5, bypass_mode=always) — idempotent, since every shipped variant's JSON
# already carries this entry (SPEC section 6.6 makes it unconditional, not
# just an skdd self-mod convenience: a gate that blocks its own repair is
# the exact failure the bypass exists to prevent, on every variant, not only
# the one with a self-mod ceremony). --no-bypass-admin strips it explicitly.
# Doing so on any of these variants leaves bypass_actors with no qualifying
# admin bypass at all, so the pre-apply validate-ruleset.sh call below will
# refuse the apply outright (admin-bypass-required, unconditionally) — that
# is SPEC section 6.6 doing its job, not a bug here. Pass --no-bypass-admin
# only if you intend to add a different qualifying bypass yourself before
# applying (e.g. hand-editing the ruleset afterward is not this script's
# job).
#
# --extra-check 'CONTEXT NAME' is repeatable and adds project-specific status
# check contexts (e.g. pytest matrix slots) to the ruleset's required_status_checks
# list at apply time. Lets a single apply.sh call match a project's actual CI
# without forking the variant JSON. Requires the chosen variant to ship a
# required_status_checks rule — works with skdd; errors out cleanly
# on baseline/public-guard (which deliberately don't ship that rule).
#
# --with-dependabot=<ecosystem> writes the matching templates/dependabot/<eco>.yml
# template to the target repo's .github/dependabot.yml in the same apply.sh call.
# Allowed values: python, typescript, github-actions-only. Idempotent — a file
# that already matches the template is not written. With --apply it replaces
# a differing existing file; the dry run says so first. Omit the flag to leave
# .github/dependabot.yml untouched.
# Templates land at templates/dependabot/ via reporulez PR #15.

# ALLOW_WEAKENING and ALLOW_BYPASS_REMOVAL are read by bin/ruleset-compare.sh (rc_gate).
# shellcheck disable=SC2034
set -euo pipefail

RAW_BASE="${REPORULEZ_RAW_BASE:-https://raw.githubusercontent.com/thrillmade/reporulez/main}"
RULESET_NAME="reporulez-default"

# Set right before every deliberate `exit 0` / `exit 1`. Any other non-zero
# exit -- a `set -e` failure in a pipeline, a jq crash -- is an unexpected
# failure, and the EXIT trap reports it as 2: a stray 1 must never read as
# "dry run found a difference".
DELIBERATE_EXIT=""
finish() { DELIBERATE_EXIT=1; exit "$1"; }
die() { echo "error: $*" >&2; exit 2; }
refuse() { echo "refused: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }

# The whole header comment, however long it grows: every line from 2 up to
# the first line that is not a comment.
usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
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

# Single temp-file registry + cleanup trap. Tracks every tempfile we
# create so a single EXIT trap reliably removes them all. Each step
# appends to CLEANUP_FILES before / after mktemp, never registering a
# fresh trap (the prior multi-trap pattern silently shadowed the
# earlier trap on re-set).
CLEANUP_FILES=()
cleanup() {
  local rc=$?
  if [[ ${#CLEANUP_FILES[@]} -gt 0 ]]; then rm -f "${CLEANUP_FILES[@]}"; fi
  if [[ "$rc" -ne 0 && "$rc" -ne 2 && -z "$DELIBERATE_EXIT" ]]; then
    echo "error: unexpected failure (exit $rc) -- treated as a failed run" >&2
    exit 2
  fi
  return 0
}
trap cleanup EXIT

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; finish 0 ;; esac

REPO="$1"; shift
VARIANT="baseline"
HUMAN_REVIEW="false"
BYPASS_ADMIN=""  # sentinel: empty = leave bypass_actors exactly as the variant JSON ships it (present, on every repo-level variant); "true" = ensure present (idempotent); "false" = strip explicitly
EXTRA_CHECKS=()  # parallel array of context names; preserves order
WITH_DEPENDABOT=""  # empty = skip the dependabot.yml step (default); otherwise the ecosystem slug
APPLY="false"
ALLOW_WEAKENING="false"
ALLOW_BYPASS_REMOVAL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    baseline|clud-bug|skdd|public-guard) VARIANT="$1"; shift ;;
    external) VARIANT="baseline"; shift ;;  # deprecated alias → baseline (renamed: the structural secure floor)
    clud-bug-logmind) VARIANT="skdd"; shift ;;  # deprecated alias → skdd (renamed: the canonical SkDD-toolchain bundle)
    --apply) APPLY="true"; shift ;;
    --allow-weakening) ALLOW_WEAKENING="true"; shift ;;
    --allow-bypass-removal) ALLOW_BYPASS_REMOVAL="true"; shift ;;
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
    -h|--help) usage; finish 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Validate --with-dependabot against the whitelist before any network call,
# so a typo (e.g. --with-dependabot=ruby) fails fast.
if [[ -n "$WITH_DEPENDABOT" ]]; then
  is_valid_dependabot_eco "$WITH_DEPENDABOT" \
    || die "--with-dependabot value '$WITH_DEPENDABOT' is not a known ecosystem. Valid values: ${VALID_DEPENDABOT_ECOSYSTEMS[*]}"
fi

# No per-variant default switch anymore: every repo-level variant's JSON
# already ships the Repository admin bypass (SPEC section 6.6 makes it
# unconditional, not skdd-specific). BYPASS_ADMIN empty means "leave
# bypass_actors exactly as the variant shipped it" — neither flag block
# below runs, and the shipped default (present) stands.

[[ "$REPO" == */* && "$REPO" != -* ]] || die "repo must be in owner/repo form, got: $REPO"
command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
command -v jq >/dev/null || die "jq not found (brew install jq)"

# Load the ruleset JSON. Use the local file if running from a checkout, else fetch.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The comparison and the refusals live in one place, shared with bin/apply-org.sh.
COMPARE="$SCRIPT_DIR/ruleset-compare.sh"
if [[ ! -f "$COMPARE" ]]; then
  COMPARE="$(mktemp)"
  CLEANUP_FILES+=("$COMPARE")
  curl -fsSL "$RAW_BASE/bin/ruleset-compare.sh" -o "$COMPARE" \
    || die "failed to fetch $RAW_BASE/bin/ruleset-compare.sh"
  # A fetched copy must be the library itself: an empty file or an error page
  # is refused here, before it is sourced and before any gh call.
  [[ -s "$COMPARE" ]] && grep -q '^rc_gate()' "$COMPARE" \
    || die "fetched $RAW_BASE/bin/ruleset-compare.sh is not the comparison library (empty or not a script)"
fi
# shellcheck source=ruleset-compare.sh
source "$COMPARE"

# First gh call of the run: only after the library is loaded.
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

LOCAL_JSON="$SCRIPT_DIR/../rulesets/${VARIANT}.json"
if [[ -f "$LOCAL_JSON" ]]; then
  RULESET_JSON="$(cat "$LOCAL_JSON")"
  info "Using local ruleset: $LOCAL_JSON"
else
  URL="$RAW_BASE/rulesets/${VARIANT}.json"
  info "Fetching ruleset: $URL"
  RULESET_JSON="$(curl -fsSL "$URL")" || die "failed to fetch $URL"
fi

# The preset is exactly one JSON object with a non-empty string name.
rc_preset_is_one_object "$RULESET_JSON" \
  || die "preset '$VARIANT' is not one JSON object with a top-level string .name"

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

# Patch bypass_actors if --no-bypass-admin: strip the Repository admin role
# (id=5) entry explicitly, if present. Every repo-level variant ships this
# entry by default now, so this flag has real effect where it previously
# did not (baseline/clud-bug/public-guard used to ship bypass_actors:[]
# already, so "don't add it" and "remove it" were indistinguishable). The
# validate-ruleset.sh call below will refuse to apply the result unless a
# different qualifying bypass survives (see the flag's usage-comment above).
if [[ "$BYPASS_ADMIN" == "false" ]]; then
  info "Patching bypass_actors: removing Repository admin (RepositoryRole id=5, bypass_mode=always) if present"
  RULESET_JSON="$(echo "$RULESET_JSON" | jq '
    .bypass_actors |= [ .[] | select(.actor_type != "RepositoryRole" or .actor_id != 5) ]
  ')"
fi

# Patch required_status_checks with each --extra-check value. Lets a single
# apply.sh call add project-specific contexts (e.g. pytest matrix slots) without
# forking the variant JSON. The variant must already ship a required_status_checks
# rule (skdd and clud-bug do); other variants deliberately omit
# that rule because GitHub's API rejects an empty checks list.
if [[ ${#EXTRA_CHECKS[@]} -gt 0 ]]; then
  echo "$RULESET_JSON" | jq -e '.rules | any(.type == "required_status_checks")' >/dev/null \
    || die "--extra-check requires a variant that ships required_status_checks (use skdd or clud-bug, or skip --extra-check and add the rule manually in the UI)"
  for ctx in "${EXTRA_CHECKS[@]}"; do
    info "Adding required status check context: $ctx"
    RULESET_JSON="$(echo "$RULESET_JSON" | CTX="$ctx" jq '
      (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
        |= (. + [{"context": env.CTX}] | unique_by(.context))
    ')"
  done
fi

# The comparison covers exactly six fields, and the whole preset is what
# gets sent. A preset carrying any other field is refused.
EXTRA_FIELDS="$(rc_extra_fields "$RULESET_JSON")"
[[ -z "$EXTRA_FIELDS" ]] || die "preset '$VARIANT' carries field(s) this script does not compare: $EXTRA_FIELDS"
PR_BAD="$(rc_pr_bad "$RULESET_JSON")" || die "could not check the preset's pull_request values"
[[ -z "$PR_BAD" ]] || refuse "invalid preset '$VARIANT': $PR_BAD"

# Validate the FINAL ruleset JSON — after every --human-review /
# --bypass-admin / --extra-check patch above — before anything below reads or
# writes a thing. reporulez#68: nothing checked a ruleset's contents before
# it changed branch protection on a real repo; an invalid ruleset is refused
# in a dry run too. Same local-checkout-or-fetch fallback as the ruleset JSON.
VALIDATOR="$SCRIPT_DIR/validate-ruleset.sh"
if [[ ! -f "$VALIDATOR" ]]; then
  VALIDATOR="$(mktemp)"
  CLEANUP_FILES+=("$VALIDATOR")
  curl -fsSL "$RAW_BASE/bin/validate-ruleset.sh" -o "$VALIDATOR" \
    || die "failed to fetch validator: $RAW_BASE/bin/validate-ruleset.sh"
fi
info "Validating ruleset against required fields before reading $REPO"
echo "$RULESET_JSON" | bash "$VALIDATOR" - >&2 \
  || refuse "ruleset failed pre-apply validation (see above) — refusing to apply an invalid ruleset to $REPO"

TMP_JSON="$(mktemp)"
CLEANUP_FILES+=("$TMP_JSON")
echo "$RULESET_JSON" > "$TMP_JSON"
PRESET_NORM="$(mktemp)"
CLEANUP_FILES+=("$PRESET_NORM")
rc_normalise "$RULESET_JSON" > "$PRESET_NORM"

# ======================================================================
# READS. Nothing below this line until WRITES makes a write call. Every
# read that fails, or returns something unusable, is a refusal here -- so a
# later read failing can never leave an earlier write standing.
# ======================================================================

# 1. Repo settings. The seven keys this script manages, with the values it
#    sets. The read must be the repository asked for and carry every key
#    with the type it is compared as; a missing key (GitHub omits some for a
#    caller without admin) is an unusable read, never "false".
WANT_SETTINGS='{"allow_auto_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
REPO_JSON="$(gh api "repos/$REPO" 2>/dev/null)" \
  || refuse "could not read repo settings for '$REPO' (nothing was written)"
printf '%s' "$REPO_JSON" | jq -se --arg repo "$REPO" --argjson want "$WANT_SETTINGS" '
  length == 1 and (.[0] as $l
  | ($l | type) == "object" and ($l.full_name | type) == "string"
  and ($l.full_name | ascii_downcase) == ($repo | ascii_downcase)
  and all($want | to_entries[]; ($l[.key] | type) == (.value | type)))' >/dev/null 2>&1 \
  || refuse "could not read repo settings for '$REPO': the response was not that repository with all seven settings (empty, null, malformed, or missing a key the comparison needs) -- nothing was written"
SETTINGS_DIFF="$(printf '%s' "$REPO_JSON" | jq -r --argjson want "$WANT_SETTINGS" '
  . as $l | $want | to_entries[] | select($l[.key] != .value)
  | "  \(.key): live \($l[.key] | tojson), would set \(.value | tojson)"')"

# 2. The dependabot file, if asked for. Absent (HTTP 404) is a state; any
#    other failure, or a body that is not that one file, is a refusal.
FILE_STATE=""
if [[ -n "$WITH_DEPENDABOT" ]]; then
  TEMPLATE_LOCAL="$SCRIPT_DIR/../templates/dependabot/${WITH_DEPENDABOT}.yml"
  # Base64 directly from the source bytes — never go through a `$(...)`
  # command substitution into a shell variable, because bash strips ALL
  # trailing newlines from `$(...)` output. The templates end in `\n`
  # (POSIX text-file convention); without the byte-exact trailing
  # newline the base64 wouldn't match GitHub's stored copy, the
  # comparison below would never see "same", and every re-run would
  # report a difference. Pipe-to-base64 preserves the trailing newline.
  if [[ -f "$TEMPLATE_LOCAL" ]]; then
    info "Using local dependabot template: $TEMPLATE_LOCAL"
    TEMPLATE_B64="$(base64 < "$TEMPLATE_LOCAL" | tr -d '\n')"
  else
    TEMPLATE_URL="$RAW_BASE/templates/dependabot/${WITH_DEPENDABOT}.yml"
    info "Fetching dependabot template: $TEMPLATE_URL"
    TEMPLATE_B64="$(curl -fsSL "$TEMPLATE_URL" | base64 | tr -d '\n')" \
      || die "failed to fetch $TEMPLATE_URL"
  fi

  CONTENTS_ERR="$(mktemp)"
  CLEANUP_FILES+=("$CONTENTS_ERR")
  EXISTING_SHA=""
  if CONTENTS_GET="$(gh api "repos/$REPO/contents/.github/dependabot.yml" 2>"$CONTENTS_ERR")"; then
    printf '%s' "$CONTENTS_GET" | jq -se '
      length == 1 and (.[0] | type == "object" and .path == ".github/dependabot.yml"
      and (.sha | type) == "string" and .sha != ""
      and .encoding == "base64" and (.content | type) == "string")' >/dev/null 2>&1 \
      || refuse "could not read .github/dependabot.yml on '$REPO': the response was not that file (empty, null, malformed) -- nothing was written"
    EXISTING_SHA="$(printf '%s' "$CONTENTS_GET" | jq -r '.sha')"
    EXISTING_B64="$(printf '%s' "$CONTENTS_GET" | jq -r '.content' | tr -d '\n')"
    if [[ "$EXISTING_B64" == "$TEMPLATE_B64" ]]; then FILE_STATE="same"; else FILE_STATE="differs"; fi
  elif grep -q 'HTTP 404' "$CONTENTS_ERR"; then
    FILE_STATE="absent"
  else
    refuse "could not read .github/dependabot.yml on '$REPO' (not a 404) -- nothing was written"
  fi
fi

# 3. The ruleset. A failed read is a refusal, never "nothing is live" --
#    treating it as absent would turn a permission error into a create.
if ! RULESETS_JSON="$(gh api --paginate "repos/$REPO/rulesets" 2>/dev/null)"; then
  refuse "could not read the live rulesets for '$REPO' (nothing was written)"
fi
LIVE_LIST="$(rc_live_list "$RULESETS_JSON")" \
  || refuse "could not read the live rulesets for '$REPO': the response was not a list of rulesets (empty, null, or malformed) -- nothing was written"

NEAR_NAMES="$(rc_near_names "$LIVE_LIST" "$RULESET_NAME")"
if [[ -n "$NEAR_NAMES" ]]; then
  refuse "live ruleset(s) in '$REPO' named like '$RULESET_NAME' but not identically: $(echo "$NEAR_NAMES" | paste -sd ';' -) -- rename one so the names match exactly"
fi
MATCHING_IDS="$(rc_matching_ids "$LIVE_LIST" "$RULESET_NAME")"
MATCH_COUNT=0
[[ -z "$MATCHING_IDS" ]] || MATCH_COUNT="$(printf '%s\n' "$MATCHING_IDS" | wc -l | tr -d ' ')"
if [[ "$MATCH_COUNT" -gt 1 ]]; then
  refuse "$MATCH_COUNT live rulesets in '$REPO' are named '$RULESET_NAME' (ids: $(echo "$MATCHING_IDS" | paste -sd ' ' -)) -- cannot tell which one this preset describes"
fi

RULESET_STATE="absent"   # absent | same | differs
LIVE_ID=""
if [[ "$MATCH_COUNT" -eq 1 ]]; then
  LIVE_ID="$MATCHING_IDS"
  LIVE_JSON="$(gh api "repos/$REPO/rulesets/$LIVE_ID" 2>/dev/null)" \
    || refuse "could not read live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$REPO' (nothing was written)"
  rc_detail_ok "$LIVE_JSON" "$LIVE_ID" "$RULESET_NAME" \
    || refuse "could not read live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$REPO': the response was not that ruleset (empty, null, malformed, or missing a field the comparison needs) -- nothing was written"
  LIVE_NORM="$(mktemp)"
  CLEANUP_FILES+=("$LIVE_NORM")
  rc_normalise "$LIVE_JSON" > "$LIVE_NORM"
  if cmp -s "$LIVE_NORM" "$PRESET_NORM"; then RULESET_STATE="same"; else RULESET_STATE="differs"; fi
fi

# ======================================================================
# REPORT. What each write would change, from the reads above.
# ======================================================================
ANY_DIFFERENCE="false"

if [[ -n "$SETTINGS_DIFF" ]]; then
  ANY_DIFFERENCE="true"
  echo "difference: repo settings on '$REPO' (live vs what this script sets):"
  echo "$SETTINGS_DIFF"
else
  echo "no difference: repo settings on '$REPO' already match"
fi

case "$FILE_STATE" in
  absent)  ANY_DIFFERENCE="true"; echo "difference: .github/dependabot.yml does not exist on '$REPO'; --apply would CREATE it from template '$WITH_DEPENDABOT'" ;;
  differs) ANY_DIFFERENCE="true"; echo "difference: .github/dependabot.yml on '$REPO' differs from template '$WITH_DEPENDABOT'; --apply would REPLACE it (content differs)" ;;
  same)    echo "no difference: .github/dependabot.yml on '$REPO' matches template '$WITH_DEPENDABOT'" ;;
esac

case "$RULESET_STATE" in
  absent)
    ANY_DIFFERENCE="true"
    echo "difference: no live ruleset named '$RULESET_NAME' on '$REPO'; --apply would CREATE it as:"
    cat "$PRESET_NORM" ;;
  same)
    echo "no difference: preset '$VARIANT' matches live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$REPO'" ;;
  differs)
    ANY_DIFFERENCE="true"
    echo "difference: live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$REPO' vs preset '$VARIANT' (- live, + preset):"
    diff -u "$LIVE_NORM" "$PRESET_NORM" | tail -n +3 || true
    rc_classify "$LIVE_NORM" "$PRESET_NORM"
    rc_print_kinds ;;
esac

if [[ "$APPLY" != "true" ]]; then
  if [[ "$ANY_DIFFERENCE" != "true" ]]; then
    finish 0
  fi
  [[ "$RULESET_STATE" != "differs" ]] || rc_print_flag_notes
  echo "dry run: nothing written. Re-run with --apply to write the changes above."
  finish 1
fi

# Decide the ruleset refusal BEFORE the first write: a settings or file write
# must not stand when the ruleset write that follows would be refused.
if [[ "$RULESET_STATE" == "differs" ]]; then
  rc_gate || refuse "not replacing live ruleset '$RULESET_NAME' (id=$LIVE_ID); nothing was written (not the settings, not the dependabot file); to apply the changes above anyway, pass:$BLOCKED"
fi

# ======================================================================
# WRITES. In this order: settings, the dependabot file, the ruleset. The
# file goes before the ruleset so its contents PUT does not meet the
# ruleset's pull_request rule on a FIRST apply (no ruleset yet). A failed
# write stops the run and names what was already written.
# ======================================================================
WRITTEN=""
write_failed() { die "$1 -- already written in this run:${WRITTEN:- nothing}"; }

if [[ -n "$SETTINGS_DIFF" ]]; then
  info "Configuring repo settings on $REPO (auto-merge, squash-only, delete-on-merge)"
  gh api --method PATCH "repos/$REPO" --silent \
    -F allow_auto_merge=true \
    -F allow_squash_merge=true \
    -F allow_merge_commit=false \
    -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true \
    -f squash_merge_commit_title=PR_TITLE \
    -f squash_merge_commit_message=PR_BODY \
    || write_failed "failed to PATCH repo settings on $REPO (free private repos can't auto-merge or delete-on-merge — make the repo public or upgrade to GitHub Pro)"
  WRITTEN="$WRITTEN repo-settings"
  echo "applied: repo settings on '$REPO'"
fi

if [[ "$FILE_STATE" == "absent" || "$FILE_STATE" == "differs" ]]; then
  PUT_INPUT="$(mktemp)"
  CLEANUP_FILES+=("$PUT_INPUT")
  MSG="chore: dependabot config from reporulez (ecosystem=${WITH_DEPENDABOT})"
  if [[ "$FILE_STATE" == "differs" ]]; then
    jq -n --arg msg "$MSG" --arg c "$TEMPLATE_B64" --arg s "$EXISTING_SHA" \
      '{message: $msg, content: $c, sha: $s}' > "$PUT_INPUT"
    info "Updating .github/dependabot.yml on $REPO (sha=$EXISTING_SHA)"
  else
    jq -n --arg msg "$MSG" --arg c "$TEMPLATE_B64" \
      '{message: $msg, content: $c}' > "$PUT_INPUT"
    info "Creating .github/dependabot.yml on $REPO"
  fi
  gh api --method PUT "repos/$REPO/contents/.github/dependabot.yml" --input "$PUT_INPUT" --silent \
    || write_failed "failed to PUT .github/dependabot.yml on $REPO"
  WRITTEN="$WRITTEN dependabot.yml"
  echo "applied: .github/dependabot.yml on '$REPO' (template '$WITH_DEPENDABOT')"
fi

case "$RULESET_STATE" in
  differs)
    info "Replacing live ruleset '$RULESET_NAME' (id=$LIVE_ID) on $REPO"
    gh api --method PUT "repos/$REPO/rulesets/$LIVE_ID" --input "$TMP_JSON" --silent \
      || write_failed "failed to update ruleset $LIVE_ID on $REPO"
    echo "applied: preset '$VARIANT' to live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$REPO'" ;;
  absent)
    info "Creating new ruleset"
    gh api --method POST "repos/$REPO/rulesets" --input "$TMP_JSON" --silent \
      || write_failed "failed to create ruleset on $REPO (rulesets require a public repo or GitHub Pro for private repos)"
    echo "created: ruleset '$RULESET_NAME' on '$REPO'" ;;
esac

[[ "$ANY_DIFFERENCE" == "true" ]] || finish 0

# Follow-up checklist (cannot be done safely or automatically).
cat >&2 <<EOF

OK. Ruleset '$RULESET_NAME' applied to $REPO (variant: $VARIANT, human review: $HUMAN_REVIEW, bypass admin: ${BYPASS_ADMIN:-as shipped (present)}, dependabot: ${WITH_DEPENDABOT:-none}).

Next steps you should do manually:
EOF

case "$VARIANT" in
skdd)
  # skdd ships required_status_checks with the four canonical contexts, so the
  # manual "add a status-checks rule" step is skipped.
  #
  # No --no-bypass-admin caveat here: if this run reached step 4 at all, the
  # applied ruleset passed validate-ruleset.sh's admin-bypass-required check
  # (SPEC section 6.6, unconditional), so it carries a qualifying admin
  # bypass. A --no-bypass-admin run that stripped the only qualifying entry
  # would have been refused before step 1 ever ran (see --no-bypass-admin's
  # own usage comment above) — there is no reachable state here where the
  # bypass is absent.
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
  ;;
clud-bug)
  # clud-bug ships required_status_checks with just the clud-bug-review context.
  cat >&2 <<EOF
  1. (Optional) Drop in templates/CODEOWNERS and templates/pull_request_template.md.
  2. Confirm clud-bug is installed on this repo. The ruleset's required_status_checks
     rule pins the clud-bug-review context; if clud-bug is not installed the check
     never reports and every PR blocks forever (strict policy is on). Install with:
       npx clud-bug init
EOF
  ;;
public-guard)
  cat >&2 <<EOF
  1. REQUIRED: add a CODEOWNERS file (templates/CODEOWNERS) listing the human
     maintainers who may approve. This variant sets require_code_owner_review=true
     and required_approving_review_count=1 — the "an outsider's PR needs a HUMAN
     maintainer approval" gate — which only bites once CODEOWNERS exists.
  2. (Optional) Drop in templates/pull_request_template.md.
  3. A bot/App check (e.g. clud-bug-review) is ADVISORY here and does NOT satisfy the
     human approval. To ALSO require the clud-bug check, layer it at the org level or
     add a required_status_checks rule in the UI.
EOF
  ;;
*)
  cat >&2 <<EOF
  1. Add a 'Require status checks to pass' rule with your CI workflow names via
     Settings -> Rules -> Rulesets -> '$RULESET_NAME' -> Require status checks to pass.
     (The baseline ruleset ships without this rule because GitHub's API rejects an empty list.)
  2. (Optional) Drop in templates/CODEOWNERS and templates/pull_request_template.md.
  3. Confirm an AI reviewer GitHub App (e.g. clud-bug, CodeRabbit) is installed and
     configured to comment on every PR, so the thread-resolution gate has something to gate on.
EOF
  ;;
esac

finish 0
