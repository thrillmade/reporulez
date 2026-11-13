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
  for f in "${TMP_JSON:-}" "${VALIDATOR_TMP:-}" "${LIVE_NORM:-}" "${PRESET_NORM:-}" "${CLASSIFY_JQ:-}"; do
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

# The preset is exactly one JSON object with a non-empty string name. A
# second document after the first would be sent but never compared.
printf '%s' "$RULESET_JSON" | jq -se 'length == 1 and (.[0] | type == "object" and (.name | type) == "string" and .name != "")' >/dev/null 2>&1 \
  || die "preset '$VARIANT' is not one JSON object with a top-level string .name"

# The ruleset name comes from the JSON itself, not the variant: "CI must pass"
# is not a file name, and the lookup below must match what is live.
RULESET_NAME="$(printf '%s' "$RULESET_JSON" | jq -r '.name')"

# The comparison below covers exactly these six fields, and the whole preset
# is what gets sent. A preset carrying any other field would send something
# never compared, so it is refused.
EXTRA_FIELDS="$(echo "$RULESET_JSON" | jq -r 'keys - ["name","target","enforcement","conditions","rules","bypass_actors"] | join(", ")')"
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
PR_BAD="$(echo "$RULESET_JSON" | jq -r '
  [.rules[]? | select(type == "object" and .type == "pull_request") | .parameters? | select(type == "object")
   | (if has("allowed_merge_methods") and ((.allowed_merge_methods | type) != "array" or (.allowed_merge_methods | length) == 0)
        then "pull_request.allowed_merge_methods must be a non-empty list" else empty end),
     (if has("required_approving_review_count")
         and ((.required_approving_review_count | type) != "number"
              or .required_approving_review_count != (.required_approving_review_count | floor)
              or .required_approving_review_count < 0 or .required_approving_review_count > 10)
        then "pull_request.required_approving_review_count must be an integer from 0 to 10" else empty end)
  ] | join("; ")')" || die "could not check the preset's pull_request values"
[[ -z "$PR_BAD" ]] || refuse "invalid preset '$RULESET_NAME': $PR_BAD"

# Read live. A failed read is a refusal, never "nothing is live" -- treating
# it as absent would turn a permission error into a create. A read that
# exits 0 but returns nothing usable (an empty body, null, an object where a
# list belongs) is a failed read too.
if ! RULESETS_JSON="$(gh api --paginate "orgs/$ORG/rulesets" 2>/dev/null)"; then
  refuse "could not read the live rulesets for org '$ORG' (the gh token may be missing the admin:org scope -- gh auth refresh -h github.com -s admin:org -- or you are not an owner of '$ORG')"
fi
# --paginate may emit one JSON array per page; slurp them into one list.
LIVE_LIST="$(printf '%s' "$RULESETS_JSON" | jq -cse '
  select(length > 0 and all(.[]; type == "array"))
  | add
  | select(all(.[]; type == "object" and (.id | type) == "number" and (.name | type) == "string"))' 2>/dev/null)" \
  || refuse "could not read the live rulesets for org '$ORG': the response was not a list of rulesets (empty, null, or malformed)"

# A live name that equals the preset's once case, spaces, hyphens and
# underscores are ignored, but is not identical, is refused: --apply would
# otherwise create a near-duplicate beside it.
NEAR_NAMES="$(printf '%s' "$LIVE_LIST" | jq -r --arg name "$RULESET_NAME" '
  def fold: ascii_downcase | gsub("[\\s_-]+"; "");
  .[] | select(.name != $name and (.name | fold) == ($name | fold)) | "\(.name) (id=\(.id))"')"
if [[ -n "$NEAR_NAMES" ]]; then
  refuse "live ruleset(s) in '$ORG' named like '$RULESET_NAME' but not identically: $(echo "$NEAR_NAMES" | paste -sd ';' -) -- rename one so the names match exactly"
fi

MATCHING_IDS="$(printf '%s' "$LIVE_LIST" | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id')"
MATCH_COUNT=0
[[ -z "$MATCHING_IDS" ]] || MATCH_COUNT="$(printf '%s\n' "$MATCHING_IDS" | wc -l | tr -d ' ')"

if [[ "$MATCH_COUNT" -gt 1 ]]; then
  refuse "$MATCH_COUNT live rulesets in '$ORG' are named '$RULESET_NAME' (ids: $(echo $MATCHING_IDS)) -- cannot tell which one this preset describes"
fi

# Normalise both sides the same way: keep only what an apply sends, drop the
# actor_id GitHub ignores for OrganizationAdmin, and sort every array (rule,
# bypass, ref and merge-method order carry no meaning). A field absent on
# one side stays absent: nothing here fills in a default, so a missing key
# can never compare equal to null, [], {}, 0 or false.
NORMALISE='
  with_entries(select(.key as $k | ["name","target","enforcement","conditions","rules","bypass_actors"] | index($k)))
  | if (.bypass_actors | type) == "array"
    then .bypass_actors |= map(if type == "object" and .actor_type == "OrganizationAdmin" then .actor_id = null else . end)
    else . end
  | walk(if type == "array" then sort else . end)'

PRESET_NORM="$(mktemp)"
echo "$RULESET_JSON" | jq -S "$NORMALISE" > "$PRESET_NORM"

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
printf '%s' "$LIVE_JSON" | jq -se --argjson id "$LIVE_ID" --arg name "$RULESET_NAME" '
  length == 1 and (.[0]
  | type == "object" and .id == $id and .name == $name
  and (.target | type) == "string" and (.enforcement | type) == "string"
  and (.conditions | type) == "object"
  and (.rules | type) == "array"
  and all(.rules[]; type == "object" and (.type | type) == "string")
  and (.bypass_actors | type) == "array"
  and all(.bypass_actors[]; type == "object" and (.actor_type | type) == "string" and (.bypass_mode | type) == "string"))' \
  >/dev/null 2>&1 \
  || refuse "could not read live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG': the response was not that ruleset (empty, null, malformed, or missing a field the comparison needs)"
LIVE_NORM="$(mktemp)"
printf '%s' "$LIVE_JSON" | jq -S "$NORMALISE" > "$LIVE_NORM"

if cmp -s "$LIVE_NORM" "$PRESET_NORM"; then
  echo "no difference: preset '$VARIANT' matches live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
  finish 0
fi

echo "difference: live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG' vs preset '$VARIANT' (- live, + preset):"
diff -u "$LIVE_NORM" "$PRESET_NORM" | tail -n +3 || true

# Classify every difference as tightens / weakens / removes bypass, one
# line each: "<kind><TAB><what>". Every comparator goes through
# each_difference, which walks the UNION of keys on both sides: a field it
# has no rule for is reported as weakens, never skipped, and a key absent
# on one side or of a different JSON type is weakens before any rule runs.
CLASSIFY_JQ="$(mktemp)"
cat > "$CLASSIFY_JQ" <<'JQ_PROGRAM'
def t(m): "tightens\t" + m;
def w(m): "weakens\t" + m;
def b(m): "removes bypass\t" + m;
def keyset($a; $b): [$a, $b] | map(keys) | add | unique;
def missing_from($a; $b): [$a[] | . as $x | select(any($b[]; . == $x) | not)];
def shown($o; $k): if $o | has($k) then $o[$k] | tojson else "(absent)" end;
# An actor's identity. An absent actor_id is its own identity, never null.
def akey: "\(.actor_type)/\(if has("actor_id") | not then "(absent)" elif .actor_id == null then "-" else .actor_id | tojson end)";
def mode_rank: if type == "string" then {"pull_request": 1, "always": 2, "exempt": 3}[.] else null end;
def enf_rank: if type == "string" then {"disabled": 0, "evaluate": 1, "active": 2}[.] else null end;
def add_rule_types: ["creation", "update", "deletion", "non_fast_forward", "required_linear_history",
  "required_signatures", "pull_request", "required_status_checks", "required_deployments"];
def pr_booleans: ["dismiss_stale_reviews_on_push", "require_code_owner_review", "require_last_push_approval",
  "required_review_thread_resolution", "require_extra_approval_for_unattributed_changes"];

# The one door every comparator goes through. For each key on either side:
# present on both with the same value is no difference. Absent on one side,
# or present with a different JSON type (null included), is weakens: absence
# is never read as an empty list, zero, false or {}, so it can never pass
# for "everything removed". Only a same-typed, non-equal pair reaches f, as
# {k, path, l, p}.
def each_difference($prefix; $l; $p; f):
  keyset($l; $p)[] as $k
  | "\($prefix)\($k)" as $path
  | if ($l | has($k)) and ($p | has($k)) and $l[$k] == $p[$k] then empty
    elif ($l | has($k) | not) or ($p | has($k) | not) or ($l[$k] | type) != ($p[$k] | type)
      then w("would change \($path) from \(shown($l; $k)) to \(shown($p; $k)) (absent on one side, or a different JSON type: no rule can show that tightens)")
    else {k: $k, path: $path, l: $l[$k], p: $p[$k]} | f end;

# Two arrays, already the same type: the preset may add entries (coverage grows), never drop one.
def grow_only($path; $l; $p):
  (missing_from($l; $p)[] | w("would remove \(.) from \($path)")),
  (missing_from($p; $l)[] | t("adds \(.) to \($path)"));
# Two arrays: the preset may drop entries (exclusions, allowances), never add one.
def shrink_only($path; $l; $p):
  (missing_from($p; $l)[] | w("would add \(.) to \($path)")),
  (missing_from($l; $p)[] | t("removes \(.) from \($path)"));
def bool_on($path; $l; $p):
  if $l == false and $p == true then t("turns \($path) on")
  else w("would change \($path) from \($l) to \($p)") end;
def bool_off($path; $l; $p):
  if $l == true and $p == false then t("turns \($path) off")
  else w("would change \($path) from \($l) to \($p)") end;

def target_condition($name; $l; $p):
  each_difference("conditions.\($name)."; $l; $p;
    if .k == "include" and (.l | type) == "array" then grow_only(.path; .l; .p)
    elif .k == "exclude" and (.l | type) == "array" then shrink_only(.path; .l; .p)
    else w("would change \(.path) (no rule for this field)") end);

def conditions($l; $p):
  each_difference("conditions."; $l; $p;
    if (.k == "ref_name" or .k == "repository_name") and (.l | type) == "object"
      then target_condition(.k; .l; .p)
    else w("would change \(.path) (no rule for this condition)") end);

def pull_request_params($l; $p):
  each_difference("pull_request."; $l; $p;
    if .k == "required_approving_review_count" and (.l | type) == "number" then
      if .p > .l then t("raises \(.path) from \(.l) to \(.p)")
      else w("would change \(.path) from \(.l) to \(.p)") end
    elif (.k as $k | any(pr_booleans[]; . == $k)) and (.l | type) == "boolean" then bool_on(.path; .l; .p)
    elif .k == "allowed_merge_methods" and (.l | type) == "array" then shrink_only(.path; .l; .p)
    else w("would change \(.path) (no rule for this parameter)") end);

def check_name: if type == "object" and has("context") then .context else tojson end;
def status_check_params($l; $p):
  each_difference("required_status_checks."; $l; $p;
    if .k == "strict_required_status_checks_policy" and (.l | type) == "boolean" then bool_on(.path; .l; .p)
    elif .k == "do_not_enforce_on_create" and (.l | type) == "boolean" then bool_off(.path; .l; .p)
    elif .k == "required_status_checks" and (.l | type) == "array" then
      (missing_from(.l; .p)[] | w("would remove or change required status check \(check_name)")),
      (missing_from(.p; .l)[] | t("adds required status check \(check_name)"))
    else w("would change \(.path) (no rule for this parameter)") end);

def rule_shape: all(.[]; type == "object" and (.type | type) == "string");
def rules($l; $p):
  if ($l | rule_shape | not) or ($p | rule_shape | not)
  then w("would change rules (a rule that is not an object with a string type: no rule for this shape)")
  elif ($l | map(.type) | unique | length) != ($l | length) or ($p | map(.type) | unique | length) != ($p | length)
  then w("a rule type appears more than once (no rule for comparing that)")
  else
    ( $l[] as $lr
      | ([$p[] | select(.type == $lr.type)] | first) as $pr
      | if $pr == null then w("would remove rule \($lr.type)")
        else each_difference("\($lr.type)."; $lr; $pr;
          if .k == "parameters" and (.l | type) == "object" then
            if $lr.type == "pull_request" then pull_request_params(.l; .p)
            elif $lr.type == "required_status_checks" then status_check_params(.l; .p)
            else w("would change \(.path) (no rule for this rule type)") end
          else w("would change \(.path) (no rule for this field)") end)
        end ),
    ( $p[] | .type as $t
      | select(any($l[]; .type == $t) | not)
      | if any(add_rule_types[]; . == $t) then t("adds rule \($t)")
        else w("would add rule \($t) (no rule for this rule type)") end )
  end;

def actor_shape: all(.[]; type == "object" and (.actor_type | type) == "string");
def bypass($l; $p):
  if ($l | actor_shape | not) or ($p | actor_shape | not)
  then w("would change bypass_actors (an actor that is not an object with a string actor_type: no rule for this shape)")
  elif ([$l[] | akey] | unique | length) != ($l | length) or ([$p[] | akey] | unique | length) != ($p | length)
  then w("a bypass actor appears more than once (no rule for comparing that)")
  else
    ( $l[] as $la | ($la | akey) as $k
      | ([$p[] | select(akey == $k)] | first) as $pa
      | if $pa == null then b("would remove live bypass actor \($k) (mode \($la.bypass_mode))")
        else each_difference("bypass actor \($k) "; $la; $pa;
          if .k == "bypass_mode" and (.l | type) == "string" then
            (.l | mode_rank) as $lr | (.p | mode_rank) as $pr
            | if $lr == null or $pr == null
                then w("would change bypass actor \($k) mode from \(.l) to \(.p) (no rule for this mode)")
              elif $pr > $lr then w("would widen bypass actor \($k) mode from \(.l) to \(.p)")
              else b("would narrow bypass actor \($k) mode from \(.l) to \(.p)") end
          else w("would change \(.path) (no rule for this field)") end)
        end ),
    ( $p[] | akey as $k
      | select(any($l[]; akey == $k) | not)
      | w("would add bypass actor \($k) in mode \(.bypass_mode)") )
  end;

$live[0] as $l | $preset[0] as $p
| each_difference(""; $l; $p;
    if .k == "enforcement" and (.l | type) == "string" then
      if (.l | enf_rank) != null and (.p | enf_rank) != null and (.p | enf_rank) > (.l | enf_rank)
      then t("raises enforcement from \(.l) to \(.p)")
      else w("would change enforcement from \(.l) to \(.p)") end
    elif .k == "conditions" and (.l | type) == "object" then conditions(.l; .p)
    elif .k == "rules" and (.l | type) == "array" then rules(.l; .p)
    elif .k == "bypass_actors" and (.l | type) == "array" then bypass(.l; .p)
    else w("would change \(.k) from \(.l | tojson) to \(.p | tojson)") end)
JQ_PROGRAM

CLASSIFIED="$(jq -rn --slurpfile live "$LIVE_NORM" --slurpfile preset "$PRESET_NORM" -f "$CLASSIFY_JQ")"
# Backstop: the files differ, so a classification that found nothing is a
# difference this script could not name -- weakens, not fine.
[[ -n "$CLASSIFIED" ]] || CLASSIFIED="$(printf 'weakens\ta difference this script could not classify')"

TIGHTENS="$(printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "tightens" { print $2 }')"
WEAKENS="$(printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "weakens" { print $2 }')"
REMOVES_BYPASS="$(printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "removes bypass" { print $2 }')"

[[ -z "$TIGHTENS" ]] || while IFS= read -r r; do echo "  tightens: $r"; done <<< "$TIGHTENS"
[[ -z "$WEAKENS" ]] || while IFS= read -r r; do echo "  weakens: $r"; done <<< "$WEAKENS"
[[ -z "$REMOVES_BYPASS" ]] || while IFS= read -r r; do echo "  removes bypass: $r (automation that relies on this bypass may be locked out)"; done <<< "$REMOVES_BYPASS"

if [[ "$APPLY" != "true" ]]; then
  [[ -z "$WEAKENS" ]] || echo "--apply would refuse this without --allow-weakening."
  [[ -z "$REMOVES_BYPASS" ]] || echo "--apply would refuse this without --allow-bypass-removal."
  echo "dry run: nothing written. Re-run with --apply to replace the live ruleset."
  finish 1
fi

BLOCKED=""
if [[ -n "$WEAKENS" && "$ALLOW_WEAKENING" != "true" ]]; then
  while IFS= read -r r; do echo "refused: weakens: $r" >&2; done <<< "$WEAKENS"
  BLOCKED="$BLOCKED --allow-weakening"
fi
if [[ -n "$REMOVES_BYPASS" && "$ALLOW_BYPASS_REMOVAL" != "true" ]]; then
  while IFS= read -r r; do echo "refused: removes bypass: $r (automation that relies on this bypass may be locked out)" >&2; done <<< "$REMOVES_BYPASS"
  BLOCKED="$BLOCKED --allow-bypass-removal"
fi
if [[ -n "$BLOCKED" ]]; then
  refuse "not replacing live ruleset '$RULESET_NAME' (id=$LIVE_ID); to apply the changes above anyway, pass:$BLOCKED"
fi

info "Replacing live org ruleset '$RULESET_NAME' (id=$LIVE_ID) on $ORG"
gh api --method PUT "orgs/$ORG/rulesets/$LIVE_ID" --input "$TMP_JSON" --silent \
  || die "failed to update org ruleset '$RULESET_NAME' (id=$LIVE_ID) on $ORG"
echo "applied: preset '$VARIANT' to live ruleset '$RULESET_NAME' (id=$LIVE_ID) on '$ORG'"
finish 0
