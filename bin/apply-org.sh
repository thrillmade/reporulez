#!/usr/bin/env bash
# Apply a reporulez ORG-LEVEL ruleset to an entire GitHub organization.
#
# Usage: apply-org.sh <org> [org-baseline|org-default-protection|org-staging]
#
# Protects a branch across EVERY repo in the org — including repos created
# in the future — with one ruleset, instead of running bin/apply.sh once per
# repo. Three variants today, matching reporulez#71's two-tier branch model
# (`main` = default = production, `dev` = staging, everywhere):
#
#   org-baseline (the default): a minimal structural floor on the default
#     branch (PR required, no force-push, no default-branch deletion).
#     Deliberately permissive — omits linear-history and squash-only so a
#     repo that genuinely wants merge commits isn't broken org-wide.
#
#   org-default-protection: production protection on the default branch AND
#     `refs/heads/main` explicitly (not just `~DEFAULT_BRANCH` — see below
#     for why both). Linear history, squash-only, 1 required approval,
#     code-owner review, thread resolution.
#
#   org-staging: protection on `refs/heads/dev` specifically. No approval
#     floor (agents may merge when green after review, per reporulez#71
#     ruling 2); force-push is allowed (dev is squash-promoted to main and
#     synced back, so its history isn't linear-history-gated the way main
#     is), deletion is still blocked.
#
# All three carry an OrganizationAdmin bypass baked in -- not RepositoryRole
# "admin" (id=5): a repo created by "including future repos" has no
# per-repo Admin grant to match against yet, and GitHub documents
# OrganizationAdmin as provably covering every org owner on every repo,
# present and future, unconditionally. See each rulesets/org-*.json's own
# bypass_actors and README's "Org-level baseline" section for the full
# reasoning, including why bin/validate-ruleset.sh's
# bypass-defeats-deletion-restriction check warns (not blocks) on this shape.
#
# WHY org-default-protection's ref_name targets BOTH `~DEFAULT_BRANCH` AND
# `refs/heads/main` explicitly (reporulez#71): the org's hard rule is "main
# is the default branch and production, on every repo" — but a repo CAN
# still have its default branch flipped to something else (accidentally or
# otherwise), and `~DEFAULT_BRANCH` alone would then silently move
# production protection onto whatever branch is now default, protecting
# nothing named `main`. The explicit `refs/heads/main` entry keeps `main`
# protected even during that misconfigured window, so the gap surfaces as
# "dev is ALSO getting production rules" (loud, breaks agent auto-merge)
# rather than "main quietly lost its protection" (silent). It does not fix
# a flipped default branch — that is a repo setting outside any ruleset's
# reach; a human must flip it back. See docs/branch-policy.md.
#
# Org-level and repo-level rulesets LAYER — GitHub evaluates every ruleset
# that targets a branch and a write must satisfy all of them. This script
# therefore never touches, replaces, or overrides per-repo rulesets applied
# by bin/apply.sh; it adds an org-wide floor beneath them. Tighten
# individual repos with bin/apply.sh <owner/repo> <variant>.
#
# Unlike bin/apply.sh, this script does NOT PATCH per-repo settings
# (auto-merge, squash-only, delete-on-merge), and it does NOT create the
# `dev` branch a repo is missing — see bin/ensure-dev-branch.sh for that.
# Those are repo-scoped and have no org-level ruleset equivalent.
#
# Requires the `gh` CLI authenticated with the `admin:org` scope (managing
# org rulesets needs it — see the preflight below) and `jq`.

set -euo pipefail

RAW_BASE="${REPORULEZ_RAW_BASE:-https://raw.githubusercontent.com/thrillmade/reporulez/main}"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }
warn() { echo "!!  $*" >&2; }

usage() {
  sed -n '2,4p' "$0" | sed 's/^# //; s/^#//'
}

ORG_VARIANTS=(org-baseline org-default-protection org-staging)

[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

ORG="$1"; shift
VARIANT="org-baseline"

while [[ $# -gt 0 ]]; do
  case "$1" in
    org-baseline|org-default-protection|org-staging) VARIANT="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (usage: apply-org.sh <org> [${ORG_VARIANTS[*]// /|}])" ;;
  esac
done

# <org> is a single path segment — reject owner/repo form so a caller who
# fat-fingers a repo slug fails fast instead of hitting a confusing 404.
[[ "$ORG" != */* ]] || die "expected a bare org name, got '$ORG' (looks like owner/repo — use bin/apply.sh for a single repo)"
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

# Derive the ruleset name from the JSON itself (source of truth) rather than
# hardcoding it — org variants use their own name (e.g. "org-baseline"), and
# this keeps the find-by-name lookup below correct for any future variant.
RULESET_NAME="$(echo "$RULESET_JSON" | jq -r '.name')"
[[ -n "$RULESET_NAME" && "$RULESET_NAME" != "null" ]] || die "ruleset JSON is missing a top-level .name"

# Preflight + list in one call. Managing org rulesets requires the admin:org
# scope; without it `gh api orgs/<org>/rulesets` returns 403. This same GET
# also drives the create-vs-update decision below, so a single call both gates
# on the scope and fetches the existing rulesets.
if ! RULESETS_JSON="$(gh api --paginate "orgs/$ORG/rulesets" 2>/dev/null)"; then
  die "could not list rulesets for org '$ORG'. This usually means your gh token is
       missing the admin:org scope (required to read/write org rulesets), or you are
       not an owner of '$ORG'. Grant the scope with:
         gh auth refresh -h github.com -s admin:org
       then re-run this command."
fi

# Create-if-absent (POST) / update-if-present (PUT), keyed on the ruleset name.
# Idempotent: re-running updates the existing org ruleset instead of creating a
# duplicate — same contract as bin/apply.sh at the repo level.
EXISTING_ID="$(echo "$RULESETS_JSON" \
  | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id' \
  | head -n1)"

cleanup() {
  [[ -n "${TMP_JSON:-}" ]] && rm -f "$TMP_JSON" || true
  [[ -n "${VALIDATOR_TMP:-}" ]] && rm -f "$VALIDATOR_TMP" || true
}
trap cleanup EXIT
TMP_JSON="$(mktemp)"
echo "$RULESET_JSON" > "$TMP_JSON"

# Validate before this ruleset changes branch protection on EVERY
# repository in the org at once -- reporulez#68's entire point. Same
# local-checkout-or-fetch fallback as the ruleset JSON itself.
VALIDATOR="$SCRIPT_DIR/validate-ruleset.sh"
if [[ ! -f "$VALIDATOR" ]]; then
  VALIDATOR_TMP="$(mktemp)"
  VALIDATOR="$VALIDATOR_TMP"
  curl -fsSL "$RAW_BASE/bin/validate-ruleset.sh" -o "$VALIDATOR" \
    || die "failed to fetch validator: $RAW_BASE/bin/validate-ruleset.sh"
fi
info "Validating org ruleset against required fields before applying to '$ORG'"
echo "$RULESET_JSON" | bash "$VALIDATOR" - \
  || die "ruleset failed pre-apply validation (see above) — refusing to apply an invalid ruleset org-wide to '$ORG'"

if [[ -n "$EXISTING_ID" ]]; then
  info "Updating existing org ruleset '$RULESET_NAME' (id=$EXISTING_ID) on $ORG"
  gh api --method PUT "orgs/$ORG/rulesets/$EXISTING_ID" --input "$TMP_JSON" --silent \
    || die "failed to update org ruleset $EXISTING_ID on $ORG"
else
  info "Creating new org ruleset '$RULESET_NAME' on $ORG"
  gh api --method POST "orgs/$ORG/rulesets" --input "$TMP_JSON" --silent \
    || die "failed to create org ruleset on $ORG"
fi

case "$VARIANT" in
  org-baseline)
    WHAT_THIS_DOES="  - Protects the default branch of EVERY repo in '$ORG', including future repos.
  - PRs required (no direct default-branch pushes), force pushes blocked,
    default-branch deletion blocked." ;;
  org-default-protection)
    WHAT_THIS_DOES="  - Production-protects \`~DEFAULT_BRANCH\` AND \`refs/heads/main\` explicitly
    on EVERY repo in '$ORG' (the explicit main entry is why this keeps
    protecting main even if a repo's default branch is ever flipped —
    see this script's header comment).
  - Linear history required, squash-only merges, 1 approving review,
    code-owner review, review-thread resolution required." ;;
  org-staging)
    WHAT_THIS_DOES="  - Protects \`refs/heads/dev\` on EVERY repo in '$ORG' where that branch
    exists (a repo without a \`dev\` branch is unaffected until one is
    created — see bin/ensure-dev-branch.sh to close that gap).
  - No approval floor (agents may merge when green, per reporulez#71
    ruling 2); merge/squash/rebase all allowed; dev-branch deletion
    blocked." ;;
esac

cat >&2 <<EOF

OK. Org ruleset '$RULESET_NAME' applied to org '$ORG' (variant: $VARIANT).

What this does:
$WHAT_THIS_DOES
  - Any organization owner (OrganizationAdmin, bypass_mode=always) can
    bypass on any repo this ruleset covers, including one created after
    this ran, to unstick an edge case there without disabling the ruleset.
    bin/validate-ruleset.sh's bypass-defeats-deletion-restriction check
    notes this as a WARNING, not a block -- see README's "Org-level
    baseline" section for why that bypass, not a per-repo one, is the
    right default here.

Notes:
  - This LAYERS with any per-repo rulesets from bin/apply.sh — it never
    overrides them. A write must satisfy every ruleset that targets it.
  - Tighten individual repos (required status checks, linear history,
    squash-only, human approval) with:
      ./bin/apply.sh <owner/repo> <baseline|clud-bug|skdd|public-guard>
  - Full policy model (main/dev, why the default branch must never flip):
    docs/branch-policy.md
EOF
