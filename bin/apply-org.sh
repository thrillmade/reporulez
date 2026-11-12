#!/usr/bin/env bash
# Compare (by default) or apply (with --apply) a reporulez ORG-LEVEL ruleset.
#
# Usage: apply-org.sh <org> [org-baseline|org-default-protection|org-staging|org-ci-must-pass] [--apply] [--allow-loosening]
#
# DRY RUN BY DEFAULT. Without --apply this script makes no write call: it
# reads the live org ruleset of the preset's name, normalises both sides the
# same way, and prints the difference (or "no difference"). Writing anything
# -- a PUT to replace a live ruleset, or a POST to create a missing one --
# requires an explicit --apply.
#
# Exit codes:
#   0   no difference, or --apply wrote the preset successfully
#   1   dry run, and a difference exists (printed above)
#   2   refused or failed: usage error, invalid preset, the live read failed,
#       more than one live ruleset has that name, --apply would loosen a
#       live ruleset without --allow-loosening, or the write itself failed
#
# What --apply refuses without --allow-loosening, compared against live:
#   - removing a bypass actor that is live
#   - changing a bypass actor's mode from `pull_request` to `always`
#   - removing a ref target from conditions.ref_name.include
#   - removing a rule type
# Each refusal names its reason.
#
# The presets under rulesets/org-*.json are captured from the live org
# rulesets, so applying any of them to today's organisation changes nothing.
# A preset that drifts from live shows up here as a difference, never as a
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

set -euo pipefail

RAW_BASE="${REPORULEZ_RAW_BASE:-https://raw.githubusercontent.com/thrillmade/reporulez/main}"

die() { echo "error: $*" >&2; exit 2; }
refuse() { echo "refused: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }

usage() {
  sed -n '2,4p' "$0" | sed 's/^# //; s/^#//'
}

ORG_VARIANTS=(org-baseline org-default-protection org-staging org-ci-must-pass)

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

ORG="$1"; shift
VARIANT="org-baseline"
APPLY="false"
ALLOW_LOOSENING="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    org-baseline|org-default-protection|org-staging|org-ci-must-pass) VARIANT="$1"; shift ;;
    --apply) APPLY="true"; shift ;;
    --allow-loosening) ALLOW_LOOSENING="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (variants: ${ORG_VARIANTS[*]})" ;;
  esac
done

# <org> is a single path segment -- reject owner/repo form so a caller who
# fat-fingers a repo slug fails fast instead of hitting a confusing 404.
[[ "$ORG" != */* ]] || die "expected a bare org name, got '$ORG' (looks like owner/repo -- use bin/apply.sh for a single repo)"
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

# The ruleset name comes from the JSON itself, not the variant: "CI must pass"
# is not a file name, and the lookup below must match what is live.
RULESET_NAME="$(echo "$RULESET_JSON" | jq -r '.name')"
[[ -n "$RULESET_NAME" && "$RULESET_NAME" != "null" ]] || die "ruleset JSON is missing a top-level .name"

cleanup() {
  [[ -n "${TMP_JSON:-}" ]] && rm -f "$TMP_JSON" || true
  [[ -n "${VALIDATOR_TMP:-}" ]] && rm -f "$VALIDATOR_TMP" || true
  [[ -n "${LIVE_NORM:-}" ]] && rm -f "$LIVE_NORM" || true
  [[ -n "${PRESET_NORM:-}" ]] && rm -f "$PRESET_NORM" || true
}
trap cleanup EXIT
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

# Read live. A failed read is a refusal, never "nothing is live" -- treating
# it as absent would turn a permission error into a create.
if ! RULESETS_JSON="$(gh api --paginate "orgs/$ORG/rulesets" 2>/dev/null)"; then
  refuse "could not read the live rulesets for org '$ORG' (the gh token may be missing the admin:org scope -- gh auth refresh -h github.com -s admin:org -- or you are not an owner of '$ORG')"
fi

# --paginate may emit one JSON array per page; jq reads them as a stream.
MATCHING_IDS="$(echo "$RULESETS_JSON" | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id')" \
  || refuse "could not parse the live rulesets list for org '$ORG'"
MATCH_COUNT=0
[[ -z "$MATCHING_IDS" ]] || MATCH_COUNT="$(printf '%s\n' "$MATCHING_IDS" | wc -l | tr -d ' ')"

if [[ "$MATCH_COUNT" -gt 1 ]]; then
  refuse "$MATCH_COUNT live rulesets in '$ORG' are named '$RULESET_NAME' (ids: $(echo $MATCHING_IDS)) -- cannot tell which one this preset describes"
fi

# Normalise both sides the same way: keep only what an apply sends, drop the
# actor_id GitHub ignores for OrganizationAdmin, and sort every array (rule,
# bypass, ref and merge-method order carry no meaning).
NORMALISE='
  {name, target, enforcement,
   conditions: (.conditions // {}),
   rules: (.rules // []),
   bypass_actors: ((.bypass_actors // [])
     | map(if .actor_type == "OrganizationAdmin" then .actor_id = null else . end))}
  | walk(if type == "array" then sort else . end)'

PRESET_NORM="$(mktemp)"
echo "$RULESET_JSON" | jq -S "$NORMALISE" > "$PRESET_NORM"

if [[ "$MATCH_COUNT" -eq 0 ]]; then
  if [[ "$APPLY" != "true" ]]; then
    echo "difference: no live ruleset named '$RULESET_NAME' in '$ORG'; --apply would CREATE it as:"
    cat "$PRESET_NORM"
    echo "dry run: nothing written."
    exit 1
  fi
  info "Creating org ruleset '$RULESET_NAME' on $ORG"
  gh api --method POST "orgs/$ORG/rulesets" --input "$TMP_JSON" --silent \
    || die "failed to create org ruleset '$RULESET_NAME' on $ORG"
  echo "created: org ruleset '$RULESET_NAME' on '$ORG'"
  exit 0
fi

LIVE_ID="$MATCHING_IDS"
LIVE_JSON="$(gh api "orgs/$ORG/rulesets/$LIVE_ID" 2>/dev/null)" \
  || refuse "could not read live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
LIVE_NORM="$(mktemp)"
echo "$LIVE_JSON" | jq -S "$NORMALISE" > "$LIVE_NORM" \
  || refuse "could not parse live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"

if cmp -s "$LIVE_NORM" "$PRESET_NORM"; then
  echo "no difference: preset '$VARIANT' matches live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
  exit 0
fi

echo "difference: live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG' vs preset '$VARIANT' (- live, + preset):"
diff -u "$LIVE_NORM" "$PRESET_NORM" | tail -n +3 || true

# What the preset would loosen, one line per reason.
LOOSENING="$(jq -rn --slurpfile live "$LIVE_NORM" --slurpfile preset "$PRESET_NORM" '
  def key: "\(.actor_type)/\(.actor_id // "-")";
  $live[0] as $l | $preset[0] as $p
  | ( $l.bypass_actors[] | key as $k
      | select(any($p.bypass_actors[]; key == $k) | not)
      | "would remove live bypass actor \($k)" ),
    ( $l.bypass_actors[] as $la | $p.bypass_actors[]
      | select(key == ($la | key) and $la.bypass_mode == "pull_request" and .bypass_mode == "always")
      | "would change bypass actor \(key) from pull_request to always" ),
    ( ($l.conditions.ref_name.include // [])[] as $r
      | select(any(($p.conditions.ref_name.include // [])[]; . == $r) | not)
      | "would remove ref target \($r)" ),
    ( ($l.rules | map(.type) | unique)[] as $t
      | select(any($p.rules[]; .type == $t) | not)
      | "would remove rule \($t)" )
')"

if [[ "$APPLY" != "true" ]]; then
  if [[ -n "$LOOSENING" ]]; then
    echo "--apply would refuse this without --allow-loosening:"
    while IFS= read -r reason; do echo "  - $reason"; done <<< "$LOOSENING"
  fi
  echo "dry run: nothing written. Re-run with --apply to replace the live ruleset."
  exit 1
fi

if [[ -n "$LOOSENING" && "$ALLOW_LOOSENING" != "true" ]]; then
  while IFS= read -r reason; do echo "refused: $reason" >&2; done <<< "$LOOSENING"
  refuse "the preset would loosen live ruleset '$RULESET_NAME' (id=$LIVE_ID); pass --allow-loosening to apply it anyway"
fi

info "Replacing live org ruleset '$RULESET_NAME' (id=$LIVE_ID) on $ORG"
gh api --method PUT "orgs/$ORG/rulesets/$LIVE_ID" --input "$TMP_JSON" --silent \
  || die "failed to update org ruleset '$RULESET_NAME' (id=$LIVE_ID) on $ORG"
echo "applied: preset '$VARIANT' to live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
exit 0
