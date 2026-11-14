#!/usr/bin/env bash
# Compare (by default) or apply (with --apply) a reporulez ORG-LEVEL ruleset.
#
# Usage: apply-org.sh <org> [org-baseline|org-default-protection|org-staging|org-ci-must-pass|org-no-delete-dev-main] [--apply] [--allow-weakening] [--allow-bypass-removal]
#
# DRY RUN BY DEFAULT. Without --apply this script makes no write call: it
# reads the live org ruleset of the preset's name, normalises both sides the
# same way, and prints the difference (or "no difference"). Writing anything
# -- a PUT to replace a live ruleset, or a POST to create a missing one --
# requires an explicit --apply.
#
# Exit codes (no others: an unexpected internal failure is reported as 2):
#   0   no difference, or --apply wrote the preset successfully
#   1   dry run, and a difference exists (printed above)
#   2   refused or failed: usage error, invalid preset, a live read that
#       failed or returned nothing usable (including a body of more than
#       one JSON document), a live name that matches the preset's only by
#       case or spacing, more than one live ruleset of that name, a change
#       --apply alone may not make, or the write itself failed
#
# What --apply writes on its own: only a change it can show makes protection
# strictly tighter, or the create of a ruleset no live ruleset is named like.
# "Named like" folds ASCII case, spaces, hyphens and underscores; look-alike
# characters from other scripts (a Cyrillic "о", a Unicode hyphen, a
# zero-width space) are not detected, so such a name is created alongside.
# Every difference is classified, field by field, into one of three kinds,
# and printed with its kind:
#
#   tightens        enforcement raised (disabled < evaluate < active); a ref
#                   or repository include entry added, or an exclude entry
#                   removed; a rule of a known type added; a higher approval
#                   count; a pull_request boolean switched on; a merge method
#                   removed; a required status check added; strict status
#                   checks switched on, or do_not_enforce_on_create off.
#   weakens         everything else, including any field, condition, rule
#                   type, parameter or bypass mode this script has no rule
#                   for -- the guard fails closed. A key present on one
#                   side and absent on the other, or present on both with
#                   different JSON types (null included), weakens: absence
#                   is never read as an empty list, 0, false or {}. Adding
#                   a bypass actor in any mode, or widening one's mode
#                   (pull_request < always < exempt), weakens. Needs
#                   --allow-weakening.
#   removes bypass  a live bypass actor removed, or its mode narrowed. That
#                   tightens the rules but can lock out automation that
#                   relies on the bypass. Needs --allow-bypass-removal.
#
# The two flags are independent: each permits only its own kind.
#
# The presets under rulesets/org-*.json are captured from the live org
# rulesets, so applying one to today's organisation should change nothing.
# One part could not be checked from a repository-level read: an org
# ruleset's repository condition. The presets say `repository_name: ~ALL`;
# the first dry run by an org owner shows whether live says the same. A
# preset that drifts from live shows up here as a difference, never as a
# silent overwrite.
#
#   org-baseline (the default): PR required, no force-push, no deletion, on
#     `~DEFAULT_BRANCH` and `refs/heads/main`. Merge, squash and rebase all
#     allowed.
#
#   org-default-protection: production protection on `~DEFAULT_BRANCH` and
#     `refs/heads/main`. Linear history, squash-only, 1 approving review,
#     code-owner review, thread resolution, stale reviews dismissed on push.
#
#   org-staging: PR required and no deletion on `refs/heads/dev`. No approval
#     floor. Every bypass actor is in `pull_request` mode: they can merge
#     past the rule through a pull request, not push straight to `dev`.
#
#   org-ci-must-pass (ruleset name "CI must pass"): a status check named `ci`
#     is required on `~DEFAULT_BRANCH` and `refs/heads/dev`.
#
#   org-no-delete-dev-main (ruleset name "no-delete-dev-main"): deletion of
#     `refs/heads/dev` and `refs/heads/main` blocked, with no bypass at all.
#
# WHY the `main`-side rulesets target BOTH `~DEFAULT_BRANCH` AND
# `refs/heads/main` (reporulez#71): a repo CAN still have its default branch
# flipped to something else, and `~DEFAULT_BRANCH` alone would then move
# production protection onto whatever is now default, protecting nothing
# named `main`. The explicit `refs/heads/main` entry keeps `main` protected
# during that window. It does not fix a flipped default branch -- that is a
# repo setting outside any ruleset's reach. See docs/branch-policy.md.
#
# Org-level and repo-level rulesets LAYER -- GitHub evaluates every ruleset
# that targets a branch and a write must satisfy all of them. This script
# never touches per-repo rulesets applied by bin/apply.sh, does not PATCH
# per-repo settings, and does not create `dev` branches (see
# bin/ensure-dev-branch.sh).
#
# Requires the `gh` CLI authenticated with the `admin:org` scope (reading org
# rulesets needs it, even for a dry run) and `jq`.

# ALLOW_WEAKENING and ALLOW_BYPASS_REMOVAL are read by bin/ruleset-compare.sh (rc_gate).
# shellcheck disable=SC2034
set -euo pipefail

RAW_BASE="${REPORULEZ_RAW_BASE:-https://raw.githubusercontent.com/thrillmade/reporulez/main}"

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

ORG_VARIANTS=(org-baseline org-default-protection org-staging org-ci-must-pass org-no-delete-dev-main)

cleanup() {
  local rc=$?
  for f in "${TMP_JSON:-}" "${VALIDATOR_TMP:-}" "${LIVE_NORM:-}" "${PRESET_NORM:-}" "${COMPARE_TMP:-}"; do
    [[ -n "$f" ]] && rm -f "$f"
  done
  if [[ "$rc" -ne 0 && "$rc" -ne 2 && -z "$DELIBERATE_EXIT" ]]; then
    echo "error: unexpected failure (exit $rc) -- treated as a failed run" >&2
    exit 2
  fi
  return 0
}
trap cleanup EXIT

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; finish 0 ;; esac

ORG="$1"; shift
VARIANT=""
APPLY="false"
ALLOW_WEAKENING="false"
ALLOW_BYPASS_REMOVAL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    org-baseline|org-default-protection|org-staging|org-ci-must-pass|org-no-delete-dev-main)
      # Two variants is a mistake, not "the last one wins".
      [[ -z "$VARIANT" ]] || die "two variants given ('$VARIANT' and '$1') -- name one"
      VARIANT="$1"; shift ;;
    --apply) APPLY="true"; shift ;;
    --allow-weakening) ALLOW_WEAKENING="true"; shift ;;
    --allow-bypass-removal) ALLOW_BYPASS_REMOVAL="true"; shift ;;
    -h|--help) usage; finish 0 ;;
    *) die "unknown argument: $1 (variants: ${ORG_VARIANTS[*]})" ;;
  esac
done
VARIANT="${VARIANT:-org-baseline}"

# <org> is a single path segment -- reject owner/repo form so a caller who
# fat-fingers a repo slug fails fast instead of hitting a confusing 404.
[[ -n "$ORG" && "$ORG" != -* ]] || die "expected an org name first, got '$ORG'"
[[ "$ORG" != */* ]] || die "expected a bare org name, got '$ORG' (looks like owner/repo -- use bin/apply.sh for a single repo)"
command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
command -v jq >/dev/null || die "jq not found (brew install jq)"

# Load the ruleset JSON. Use the local file if running from a checkout, else fetch.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The comparison and the refusals live in one place, shared with bin/apply.sh.
COMPARE="$SCRIPT_DIR/ruleset-compare.sh"
if [[ ! -f "$COMPARE" ]]; then
  COMPARE_TMP="$(mktemp)"
  COMPARE="$COMPARE_TMP"
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

# The preset is exactly one JSON object with a non-empty string name. A
# second document after the first would be sent but never compared.
rc_preset_is_one_object "$RULESET_JSON" \
  || die "preset '$VARIANT' is not one JSON object with a top-level string .name"

# The ruleset name comes from the JSON itself, not the variant: "CI must pass"
# is not a file name, and the lookup below must match what is live.
RULESET_NAME="$(printf '%s' "$RULESET_JSON" | jq -r '.name')"

# The comparison below covers exactly these six fields, and the whole preset
# is what gets sent. A preset carrying any other field would send something
# never compared, so it is refused.
EXTRA_FIELDS="$(rc_extra_fields "$RULESET_JSON")"
[[ -z "$EXTRA_FIELDS" ]] || die "preset '$VARIANT' carries field(s) this script does not compare: $EXTRA_FIELDS"

TMP_JSON="$(mktemp)"
echo "$RULESET_JSON" > "$TMP_JSON"

# Validate before anything else (reporulez#68). An invalid preset is refused
# in a dry run too: there is no point diffing something that could never be
# applied.
VALIDATOR="$SCRIPT_DIR/validate-ruleset.sh"
if [[ ! -f "$VALIDATOR" ]]; then
  VALIDATOR_TMP="$(mktemp)"
  VALIDATOR="$VALIDATOR_TMP"
  curl -fsSL "$RAW_BASE/bin/validate-ruleset.sh" -o "$VALIDATOR" \
    || die "failed to fetch validator: $RAW_BASE/bin/validate-ruleset.sh"
fi
info "Validating '$RULESET_NAME' against required fields"
echo "$RULESET_JSON" | bash "$VALIDATOR" - >&2 \
  || refuse "ruleset '$RULESET_NAME' failed validation (see above)"

# Values that cannot exist are an invalid preset, not a "tightening": no way
# to merge at all, or an approval count GitHub has no such setting for.
PR_BAD="$(rc_pr_bad "$RULESET_JSON")" || die "could not check the preset's pull_request values"
[[ -z "$PR_BAD" ]] || refuse "invalid preset '$RULESET_NAME': $PR_BAD"

# Read live. A failed read is a refusal, never "nothing is live" -- treating
# it as absent would turn a permission error into a create. A read that
# exits 0 but returns nothing usable (an empty body, null, an object where a
# list belongs) is a failed read too.
if ! RULESETS_JSON="$(gh api --paginate "orgs/$ORG/rulesets" 2>/dev/null)"; then
  refuse "could not read the live rulesets for org '$ORG' (the gh token may be missing the admin:org scope -- gh auth refresh -h github.com -s admin:org -- or you are not an owner of '$ORG')"
fi
# --paginate may emit one JSON array per page; slurp them into one list.
LIVE_LIST="$(rc_live_list "$RULESETS_JSON")" \
  || refuse "could not read the live rulesets for org '$ORG': the response was not a list of rulesets (empty, null, or malformed)"

# A live name that equals the preset's once case, spaces, hyphens and
# underscores are ignored, but is not identical, is refused: --apply would
# otherwise create a near-duplicate beside it.
NEAR_NAMES="$(rc_near_names "$LIVE_LIST" "$RULESET_NAME")"
if [[ -n "$NEAR_NAMES" ]]; then
  refuse "live ruleset(s) in '$ORG' named like '$RULESET_NAME' but not identically: $(echo "$NEAR_NAMES" | paste -sd ';' -) -- rename one so the names match exactly"
fi

MATCHING_IDS="$(rc_matching_ids "$LIVE_LIST" "$RULESET_NAME")"
MATCH_COUNT=0
[[ -z "$MATCHING_IDS" ]] || MATCH_COUNT="$(printf '%s\n' "$MATCHING_IDS" | wc -l | tr -d ' ')"

if [[ "$MATCH_COUNT" -gt 1 ]]; then
  refuse "$MATCH_COUNT live rulesets in '$ORG' are named '$RULESET_NAME' (ids: $(echo $MATCHING_IDS)) -- cannot tell which one this preset describes"
fi

# Both sides are normalised the same way (bin/ruleset-compare.sh).
PRESET_NORM="$(mktemp)"
rc_normalise "$RULESET_JSON" > "$PRESET_NORM"

if [[ "$MATCH_COUNT" -eq 0 ]]; then
  if [[ "$APPLY" != "true" ]]; then
    echo "difference: no live ruleset named '$RULESET_NAME' in '$ORG'; --apply would CREATE it as:"
    cat "$PRESET_NORM"
    echo "dry run: nothing written."
    finish 1
  fi
  info "Creating org ruleset '$RULESET_NAME' on $ORG"
  gh api --method POST "orgs/$ORG/rulesets" --input "$TMP_JSON" --silent \
    || die "failed to create org ruleset '$RULESET_NAME' on $ORG"
  echo "created: org ruleset '$RULESET_NAME' on '$ORG'"
  finish 0
fi

LIVE_ID="$MATCHING_IDS"
LIVE_JSON="$(gh api "orgs/$ORG/rulesets/$LIVE_ID" 2>/dev/null)" \
  || refuse "could not read live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
# The detail read must be the ruleset asked for, with every field the
# comparison reads. A missing bypass_actors is not "no bypass": GitHub omits
# it for a caller who cannot administer the ruleset. The body is slurped, so
# a second JSON document behind the first is a failed read, not ignored.
rc_detail_ok "$LIVE_JSON" "$LIVE_ID" "$RULESET_NAME" \
  || refuse "could not read live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG': the response was not that ruleset (empty, null, malformed, or missing a field the comparison needs)"
LIVE_NORM="$(mktemp)"
rc_normalise "$LIVE_JSON" > "$LIVE_NORM"

if cmp -s "$LIVE_NORM" "$PRESET_NORM"; then
  echo "no difference: preset '$VARIANT' matches live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
  finish 0
fi

echo "difference: live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG' vs preset '$VARIANT' (- live, + preset):"
diff -u "$LIVE_NORM" "$PRESET_NORM" | tail -n +3 || true

# Classify every difference (bin/ruleset-compare.sh) and print each with its kind.
rc_classify "$LIVE_NORM" "$PRESET_NORM"
rc_print_kinds

if [[ "$APPLY" != "true" ]]; then
  rc_print_flag_notes
  echo "dry run: nothing written. Re-run with --apply to replace the live ruleset."
  finish 1
fi

rc_gate || refuse "not replacing live ruleset '$RULESET_NAME' (id=$LIVE_ID); to apply the changes above anyway, pass:$BLOCKED"

info "Replacing live org ruleset '$RULESET_NAME' (id=$LIVE_ID) on $ORG"
gh api --method PUT "orgs/$ORG/rulesets/$LIVE_ID" --input "$TMP_JSON" --silent \
  || die "failed to update org ruleset '$RULESET_NAME' (id=$LIVE_ID) on $ORG"
echo "applied: preset '$VARIANT' to live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
finish 0
