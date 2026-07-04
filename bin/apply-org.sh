#!/usr/bin/env bash
# Apply a reporulez ORG-LEVEL ruleset to an entire GitHub organization.
#
# Usage: apply-org.sh <org> [org-baseline]
#
# Protects the default branch of EVERY repo in the org — including repos
# created in the future — with one ruleset, instead of running bin/apply.sh
# once per repo. The only variant today is `org-baseline` (the default): a
# minimal structural floor (PR required, no force-push, no default-branch
# deletion) that applies org-wide with an OrganizationAdmin bypass baked in.
#
# Org-level and repo-level rulesets LAYER — GitHub evaluates every ruleset
# that targets a branch and a write must satisfy all of them. This script
# therefore never touches, replaces, or overrides per-repo rulesets applied
# by bin/apply.sh; it adds an org-wide floor beneath them. Because it is a
# floor, org-baseline is deliberately permissive where the per-repo variants
# are opinionated (it omits linear-history and squash-only so a repo that
# genuinely wants merge commits isn't broken org-wide) — tighten individual
# repos with bin/apply.sh <owner/repo> <variant>.
#
# Unlike bin/apply.sh, this script does NOT PATCH per-repo settings
# (auto-merge, squash-only, delete-on-merge). Those are repo-scoped and have
# no org-level equivalent — run bin/apply.sh per repo for them.
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

[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

ORG="$1"; shift
VARIANT="org-baseline"

while [[ $# -gt 0 ]]; do
  case "$1" in
    org-baseline) VARIANT="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (usage: apply-org.sh <org> [org-baseline])" ;;
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

cleanup() { [[ -n "${TMP_JSON:-}" ]] && rm -f "$TMP_JSON" || true; }
trap cleanup EXIT
TMP_JSON="$(mktemp)"
echo "$RULESET_JSON" > "$TMP_JSON"

if [[ -n "$EXISTING_ID" ]]; then
  info "Updating existing org ruleset '$RULESET_NAME' (id=$EXISTING_ID) on $ORG"
  gh api --method PUT "orgs/$ORG/rulesets/$EXISTING_ID" --input "$TMP_JSON" --silent \
    || die "failed to update org ruleset $EXISTING_ID on $ORG"
else
  info "Creating new org ruleset '$RULESET_NAME' on $ORG"
  gh api --method POST "orgs/$ORG/rulesets" --input "$TMP_JSON" --silent \
    || die "failed to create org ruleset on $ORG"
fi

cat >&2 <<EOF

OK. Org ruleset '$RULESET_NAME' applied to org '$ORG' (variant: $VARIANT).

What this does:
  - Protects the default branch of EVERY repo in '$ORG', including future repos.
  - PRs required (no direct default-branch pushes), force pushes blocked,
    default-branch deletion blocked.
  - OrganizationAdmin can bypass (bypass_mode=always) to unstick edge cases
    without disabling the ruleset.

Notes:
  - This LAYERS with any per-repo rulesets from bin/apply.sh — it never
    overrides them. A write must satisfy the org floor AND the repo ruleset.
  - Tighten individual repos (required status checks, linear history,
    squash-only, human approval) with:
      ./bin/apply.sh <owner/repo> <baseline|clud-bug|skdd|public-guard>
EOF
