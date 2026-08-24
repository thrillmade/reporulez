#!/usr/bin/env bash
# Validate a ruleset's required fields before it is applied anywhere.
#
# reporulez#68: nothing checked a ruleset's *contents* before POST/PUTing it
# to a repository or an entire org — only its JSON syntax (test.yml's
# `jq -e .`). An invalid or incomplete ruleset applied org-wide changes
# branch protection on every repository at once, silently. This script is
# the check that runs first.
#
# Standalone by design (SPEC section 6.1: "Canonical MUST itself satisfy
# every rule this document places on a ruleset ... A validator is how that
# stops being a claim"). Point it at ANY ruleset JSON — one of reporulez's
# own variants, a live-fetched ruleset from `gh api repos/<repo>/rulesets/<id>`,
# or protocol's own `rulesets/canonical-v1.json` — it has no
# reporulez-specific assumptions baked in beyond the checks below.
#
# bin/apply.sh and bin/apply-org.sh call this on the FINAL ruleset JSON
# (after every --bypass-admin / --extra-check / --human-review patch) right
# before the POST/PUT, and refuse to apply on any violation. bin/audit.sh
# --include-ruleset calls it read-only against every already-applied
# ruleset it fetches, so drift introduced by a hand-edit after apply.sh ran
# is caught too — not just what reporulez itself would have shipped.
#
# Usage:
#   validate-ruleset.sh <path-to-ruleset.json>
#   validate-ruleset.sh -             # read the ruleset JSON from stdin
#   echo "$RULESET_JSON" | validate-ruleset.sh -
#
# Exit codes (mirrors bin/audit.sh's die()-uses-2 convention, so a caller
# can tell "the ruleset is invalid" apart from "I couldn't even check it"):
#   0   ruleset is valid — no violations found
#   1   ruleset is invalid — one or more violations found (printed to
#       stdout, one per line, prefixed "✗ [<check>] ")
#   2   usage/input error — missing argument, file not found, unreadable
#       stdin, or the input is not valid JSON. NEVER exits 0 on an input it
#       could not read: a validator that cannot find its input errors, it
#       does not silently pass the thing it never looked at.
#
# What it checks, and why these two-plus-one and not more:
#
#   integration-id-pin (SPEC section 6.3.) A required check is a bare name;
#     any identity that can post a check of that name satisfies it, and
#     GitHub resolves a required check by the LATEST report for that
#     context — so an unpinned check is forgeable by a PAT, a workflow's
#     default GITHUB_TOKEN, or another App. `integration_id` pins the check
#     to the one identity allowed to post it. Today that applies to exactly
#     one context reporulez ships: `clud-bug-review`, produced by the
#     clud-bug[bot] GitHub App (id 3944857 — see
#     docs/decisions-branches/feat-z6-integration-id-pin.md and
#     bin/verify-integration-id-pin.sh for the forged-vs-genuine proof).
#     `check-derived-docs` / `check-decisions` / `check-links` are plain
#     Actions-workflow checks with no dedicated App id to pin — that was a
#     deliberate call (same decision doc), not an oversight, so this script
#     does not flag their absence of integration_id.
#
#   admin-bypass-required (SPEC section 6.6.) "The ruleset MUST carry a
#     bypass held by repository administrators ... an incident fix cannot
#     wait for one." A ruleset with an empty bypass_actors blocks its own
#     repair. Checked unconditionally, for every ruleset this script is
#     pointed at.
#
#   bypass-defeats-deletion-restriction (not a SPEC-2 citation — this
#     repo's own rule, written after a live incident on 2026-08-14: an org
#     ruleset on thrillmade/agent-skills was Active, targeted `dev`, and
#     had "Restrict deletions" checked — and `dev` was deleted anyway,
#     because bypass_actors' "Always allow" list already covered every
#     role able to delete it. A rule whose bypass list covers every role
#     able to perform the action it restricts protects nobody who could
#     have performed that action in the first place — its stated intent
#     and its actual effect diverge.
#
#     What this checks for is deliberately narrower than the incident's
#     full bypass list, and only names IDs that are actually verifiable.
#     GitHub does not publish a stable, complete mapping of role name to
#     numeric `actor_id` for ruleset bypass actors — only `RepositoryRole`
#     `admin = 5` is corroborated (this repo's own README; GitHub CLI
#     issue cli/cli#13388; the third-party `nskit` Python client's
#     `RepositoryRole` enum, which encodes only `admin = 5` for exactly
#     this reason and calls guessing the rest "inventing an integration
#     contract"). The live ruleset from the incident (read confirmed via
#     `gh api repos/thrillmade/agent-skills/rulesets/<id>`, read-only)
#     carries `OrganizationAdmin`, `RepositoryRole actor_id=2`,
#     `RepositoryRole actor_id=5`, and one `Integration`, all `always` —
#     `actor_id=2` is NOT reliably "Maintain," so this check does not
#     depend on it. It checks the two IDs that are verifiable:
#     `RepositoryRole` `admin` (id=5) — the repo's own top role — together
#     with `OrganizationAdmin`. Between those two, every person with
#     admin-level access to the repository is covered, however it was
#     granted, and that is already enough to make a `deletion` rule
#     protect nobody. This script flags that divergence for a `deletion`
#     rule specifically, matching the incident; it does not generalize to
#     `non_fast_forward` or `update` without a second incident to ground
#     that extension.
#
#   SPEC section 6.6's second clause — "the regenerating identity MUST
#     have one of its own [a bypass], distinct from every person's and
#     every other tool's" — is NOT checked here. It requires knowing, per
#     repository, whether a derived-document regenerator (e.g. logmind)
#     runs there at all; a ruleset's bypass_actors alone cannot say which
#     entry (if any) is that identity versus an ordinary admin. Flagging
#     this as a real gap rather than silently skipping it: see the PR/issue
#     this script shipped with for where that's tracked.
#
# What it deliberately does NOT check: filename/version agreement
# (reporulez issue #68's items 1-2 — ruled void, SPEC-2 section 7.1 gives
# canonical no version scheme of its own) and anything about WHICH repos a
# ruleset's conditions target (that's a deploy-time decision, not a
# field-validity one).

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }

usage() {
  sed -n '2,44p' "$0" | sed 's/^# //; s/^#//'
}

[[ $# -ge 1 ]] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

SOURCE="$1"

command -v jq >/dev/null || die "jq not found (brew install jq)"

if [[ "$SOURCE" == "-" ]]; then
  RULESET_JSON="$(cat)" || die "failed to read ruleset JSON from stdin"
  SOURCE_LABEL="<stdin>"
else
  [[ -f "$SOURCE" ]] || die "no such file: $SOURCE"
  RULESET_JSON="$(cat "$SOURCE")" || die "failed to read $SOURCE"
  SOURCE_LABEL="$SOURCE"
fi

[[ -n "$RULESET_JSON" ]] || die "$SOURCE_LABEL is empty -- nothing to validate"
echo "$RULESET_JSON" | jq -e . >/dev/null 2>&1 \
  || die "$SOURCE_LABEL is not valid JSON"

# The clud-bug[bot] GitHub App's own id. The one App-backed required check
# reporulez ships (clud-bug-review) must be pinned to exactly this, per
# integration-id-pin above.
CLUD_BUG_INTEGRATION_ID=3944857

# The jq program lives in its own temp file (not an inline --arg string) so
# none of the prose above needs bash quote-escaping. Quoted heredoc
# delimiter ('JQ_PROGRAM') disables all bash expansion in the body,
# including the literal $variable syntax jq itself needs.
JQ_PROGRAM="$(mktemp)"
trap 'rm -f "$JQ_PROGRAM"' EXIT

cat > "$JQ_PROGRAM" <<'JQ_PROGRAM'
def admin_bypass_present:
  (.bypass_actors // []) as $b
  | any($b[]; .bypass_mode == "always" and (
        (.actor_type == "RepositoryRole" and .actor_id == 5) or
        (.actor_type == "OrganizationAdmin")
      ));

def role_bypass_present(want_type; want_id):
  (.bypass_actors // []) as $b
  | any($b[]; .bypass_mode == "always" and .actor_type == want_type and
        (want_id == null or .actor_id == want_id));

[
  # integration-id-pin (SPEC section 6.3): every clud-bug-review entry in
  # every required_status_checks rule must pin the clud-bug[bot] App id.
  ( (.rules // [])[]
    | select(.type == "required_status_checks")
    | (.parameters.required_status_checks // [])[]
    | select(.context == "clud-bug-review")
    | if (.integration_id // null) == null then
        { rule: "integration-id-pin",
          message: "required_status_checks entry \"clud-bug-review\" has no integration_id -- SPEC section 6.3 requires pinning a required check to its producer identity (the clud-bug[bot] App id, \($clud_bug_id)); an unpinned context can be satisfied by any token with statuses:write." }
      elif .integration_id != $clud_bug_id then
        { rule: "integration-id-pin",
          message: "required_status_checks entry \"clud-bug-review\" pins integration_id=\(.integration_id), expected \($clud_bug_id) (the clud-bug[bot] App id) -- SPEC section 6.3." }
      else empty
      end
  ),

  # admin-bypass-required (SPEC section 6.6): the ruleset must carry a
  # bypass a repository administrator can actually use.
  ( if admin_bypass_present then empty
    else
      { rule: "admin-bypass-required",
        message: "bypass_actors carries no repository-administrator bypass (RepositoryRole actor_id=5 \"admin\", or OrganizationAdmin, bypass_mode=\"always\") -- SPEC section 6.6: the ruleset MUST carry a bypass held by repository administrators, because the first thing a broken gate blocks is the change that would fix it." }
    end
  ),

  # bypass-defeats-deletion-restriction (this repo's own rule -- see the
  # header comment for the incident that grounds it, and for why this
  # checks exactly RepositoryRole admin (id=5) + OrganizationAdmin and
  # nothing finer-grained). A deletion rule whose bypass list already
  # covers both the repo's own top role AND every org owner protects
  # nobody who could otherwise have deleted the branch.
  ( if ((.rules // []) | any(.type == "deletion"))
       and role_bypass_present("RepositoryRole"; 5)
       and role_bypass_present("OrganizationAdmin"; null)
    then
      { rule: "bypass-defeats-deletion-restriction",
        message: "a \"deletion\" rule is present but bypass_actors grants an always-bypass to BOTH RepositoryRole \"admin\" (id=5) AND OrganizationAdmin -- between them that is every person with admin-level access to this repository, whether granted directly or inherited from being an org owner. The rule's stated intent (\"restrict deletions\") and its actual effect (nobody with admin access is restricted) diverge. Narrow bypass_actors or drop the deletion rule; do not ship both." }
    else empty
    end
  )
]
JQ_PROGRAM

VIOLATIONS_JSON="$(echo "$RULESET_JSON" \
  | jq -c --argjson clud_bug_id "$CLUD_BUG_INTEGRATION_ID" -f "$JQ_PROGRAM")" \
  || die "$SOURCE_LABEL: validation logic failed (this is a bug in validate-ruleset.sh, not in the ruleset -- please report it)"

COUNT="$(echo "$VIOLATIONS_JSON" | jq 'length')"

if [[ "$COUNT" -eq 0 ]]; then
  echo "✓ $SOURCE_LABEL is valid — no violations found."
  exit 0
fi

echo "$VIOLATIONS_JSON" | jq -r '.[] | "✗ [\(.rule)] \(.message)"'
echo "$COUNT violation(s) found in $SOURCE_LABEL."
exit 1
