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
# Two severities, ERROR and WARNING — see "What it checks" below for which
# check is which, and why. Exit codes (mirrors bin/audit.sh's
# die()-uses-2 convention, so a caller can tell "the ruleset is invalid"
# apart from "I couldn't even check it"):
#   0   no ERROR-severity violation found. Any WARNING-severity violation
#       still prints above the summary line, prefixed "⚠ [<check>] " — a
#       warning is advisory and never blocks an apply.
#   1   one or more ERROR-severity violations found (printed to stdout, one
#       per line, prefixed "✗ [<check>] "). Warnings, if any, print too but
#       are not what tripped this exit code.
#   2   usage/input error — missing argument, file not found, unreadable
#       stdin, or the input is not valid JSON. NEVER exits 0 on an input it
#       could not read: a validator that cannot find its input errors, it
#       does not silently pass the thing it never looked at.
#
# What it checks, and why these two-plus-one and not more:
#
#   Two severities. ERROR (prefixed "✗") makes the ruleset invalid — exit
#   1, and apply.sh/apply-org.sh refuse to apply. WARNING (prefixed "⚠") is
#   printed but never fails validation — exit 0, apply proceeds. A check is
#   ERROR when what it flags is a genuine SPEC violation or a forgeable
#   security gap. It is WARNING when what it flags is a design choice worth
#   surfacing even though the ruleset already conforms to every SPEC
#   requirement this script checks — see bypass-defeats-deletion-restriction
#   below for why that is the one check at this level today.
#
#   integration-id-pin (SPEC section 6.3., ERROR) A required check is a bare
#     name; any identity that can post a check of that name satisfies it,
#     and GitHub resolves a required check by the LATEST report for that
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
#   admin-bypass-required (SPEC section 6.6., ERROR) "The ruleset MUST carry
#     a bypass held by repository administrators ... an incident fix cannot
#     wait for one." A ruleset with an empty bypass_actors blocks its own
#     repair. Checked unconditionally, for every ruleset this script is
#     pointed at.
#
#   bypass-defeats-deletion-restriction (WARNING; not a SPEC-2 citation —
#     this repo's own rule) written after a live incident on 2026-08-14: an
#     org ruleset on thrillmade/agent-skills was Active, targeted `dev`, and
#     had "Restrict deletions" checked — and `dev` was deleted anyway. The
#     live ruleset (read via `gh api repos/thrillmade/agent-skills
#     /rulesets/<id>`, read-only) carried `OrganizationAdmin`,
#     `RepositoryRole` actor_id=2, `RepositoryRole` actor_id=5, and one
#     `Integration`, all `bypass_mode: always`.
#
#     THIS CHECK'S ORIGINAL CLAIM WAS FALSE (reporulez PR #69 panel, pass
#     2, after the ERROR-severity version had already shipped): it fired
#     whenever a `deletion` rule's bypass_actors granted an always-bypass to
#     `OrganizationAdmin`, on the claim that doing so "protects nobody who
#     could otherwise have deleted the branch." Deleting a branch requires
#     WRITE access, not admin — "If you have write access in a repository,
#     you can delete branches that are associated with closed or merged
#     pull requests"
#     (https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/deleting-and-restoring-branches-in-a-pull-request),
#     and the REST API's `DELETE /repos/{owner}/{repo}/git/refs/{ref}`
#     requires only `Contents` repository permission `write`, not admin
#     (https://docs.github.com/en/rest/git/refs?apiVersion=2022-11-28#delete-a-reference).
#     A ruleset's own `allow_deletions` field is documented the same way:
#     "Allows deletion of the protected branch by anyone with write access
#     to the repository." So an admin-only bypass (`RepositoryRole` `admin`
#     id=5, and/or `OrganizationAdmin`) still restricts every real Write-
#     or Maintain-role holder who is not ALSO admin-level — it protects
#     someone, and "protects nobody" was wrong. Independently confirmed on
#     `thrillmade/protocol`: a live collaborator with `role_name=write`,
#     `admin=false`, org membership `role=member` (not owner) is restricted
#     by a `deletion` rule whose bypass is admin-only, matched by none of
#     that repo's bypass entries.
#
#     WHY THIS IS STILL WORTH FLAGGING, JUST NOT AS AN ERROR: protocol SPEC
#     section 6.6 requires "The ruleset MUST carry a bypass held by
#     repository administrators," unconditionally — so every SPEC-6.6-
#     conformant ruleset that also restricts deletion necessarily carries an
#     admin-level entry on its bypass list. Flagging that shape as ERROR
#     made this a hard pre-apply gate that fired on every conformant
#     ruleset it was pointed at — a gate that fires on every valid input is
#     not a gate. What IS genuinely worth surfacing, at WARNING: an
#     `OrganizationAdmin` always-bypass excuses every organization owner —
#     GitHub gives every org owner admin access to every repository the org
#     owns, unconditionally
#     (https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization)
#     — a population nobody administers per-repository, unlike
#     `RepositoryRole` `admin` (id=5), which is scoped to whoever holds
#     THIS repo's own Admin role. SPEC 6.6's own rationale for requiring the
#     bypass — "a change to a gate's own workflow cannot pass the gate it
#     changes, and an incident fix cannot wait for one" — is about a gate
#     blocking the fix to itself. Restoring an accidentally deleted branch
#     is not editing a gate's workflow, so that rationale does not obviously
#     require extending the bypass's reach to every org owner specifically
#     for a `deletion` rule. This script says so and leaves the choice to
#     the ruleset author; it does not refuse the apply over it.
#
#     STILL NARROWER THAN THE INCIDENT'S FULL BYPASS LIST, same as before
#     the severity change: GitHub does not publish a stable, complete
#     mapping of role name to numeric `actor_id` for ruleset bypass actors —
#     only `RepositoryRole` `admin = 5` is corroborated (this repo's own
#     README; GitHub CLI issue cli/cli#13388; the third-party `nskit`
#     Python client's `RepositoryRole` enum, which encodes only `admin = 5`
#     for exactly this reason and calls guessing the rest "inventing an
#     integration contract"). The incident ruleset's `RepositoryRole`
#     actor_id=2 and its `Integration` entry are neither `RepositoryRole`
#     `admin` (id=5) nor `OrganizationAdmin` — the only two actor shapes
#     this script can prove are admin-level — and this check does NOT flag
#     them at any severity: it only looks at whether `OrganizationAdmin` is
#     present. A `RepositoryRole` id that isn't 5, a `Team`, or an
#     `Integration` could each resolve to someone with only write- or
#     maintain-level access — the population a `deletion` rule exists to
#     restrict — and none of that is checked here. That is a real, open
#     gap, not a silent limitation: flagging it is deliberate; closing it
#     needs GitHub to document those actor shapes' effective permission, or
#     a second incident to ground a narrower rule, matching the "ground
#     extensions in an incident" discipline this check was written under.
#
#     `RepositoryRole` `admin` (id=5) alone (no `OrganizationAdmin`) is not
#     flagged at all, not even as a warning — that is an ASSUMPTION, not a
#     citation, stated plainly so it can be checked: it assumes ruleset
#     bypass matching for `RepositoryRole` uses a user's ASSIGNED repo
#     role, not their EFFECTIVE permission (which for an org owner is
#     always "admin" on every repo, per the citation above, regardless of
#     any assignment). GitHub does not document which of the two it uses.
#     If it turns out to be effective permission — via GitHub documenting
#     it, or a second incident — this assumption is wrong and
#     `RepositoryRole` `admin` alone should warn too; revisit then, not
#     preemptively.
#
#     This script flags the divergence for a `deletion` rule specifically,
#     matching the incident; it does not generalize to `non_fast_forward`
#     or `update` without a second incident to ground that extension.
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
  sed -n '2,42p' "$0" | sed 's/^# //; s/^#//'
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
  # integration-id-pin (SPEC section 6.3, ERROR): every clud-bug-review entry
  # in every required_status_checks rule must pin the clud-bug[bot] App id.
  ( (.rules // [])[]
    | select(.type == "required_status_checks")
    | (.parameters.required_status_checks // [])[]
    | select(.context == "clud-bug-review")
    | if (.integration_id // null) == null then
        { rule: "integration-id-pin", severity: "error",
          message: "required_status_checks entry \"clud-bug-review\" has no integration_id -- SPEC section 6.3 requires pinning a required check to its producer identity (the clud-bug[bot] App id, \($clud_bug_id)); an unpinned context can be satisfied by any token with statuses:write." }
      elif .integration_id != $clud_bug_id then
        { rule: "integration-id-pin", severity: "error",
          message: "required_status_checks entry \"clud-bug-review\" pins integration_id=\(.integration_id), expected \($clud_bug_id) (the clud-bug[bot] App id) -- SPEC section 6.3." }
      else empty
      end
  ),

  # admin-bypass-required (SPEC section 6.6, ERROR): the ruleset must carry a
  # bypass a repository administrator can actually use.
  ( if admin_bypass_present then empty
    else
      { rule: "admin-bypass-required", severity: "error",
        message: "bypass_actors carries no repository-administrator bypass (RepositoryRole actor_id=5 \"admin\", or OrganizationAdmin, bypass_mode=\"always\") -- SPEC section 6.6: the ruleset MUST carry a bypass held by repository administrators, because the first thing a broken gate blocks is the change that would fix it." }
    end
  ),

  # bypass-defeats-deletion-restriction (WARNING; this repo's own rule --
  # see the header comment for the incident that grounds it, the citations
  # for why the check's original "protects nobody" claim was false, and the
  # stated assumption -- not a citation -- for why RepositoryRole admin
  # (id=5) alone is not flagged even as a warning). Advisory, not an error:
  # SPEC section 6.6 requires every ruleset to carry an admin bypass, so
  # every conformant ruleset with a deletion rule has exactly this shape.
  ( if ((.rules // []) | any(.type == "deletion"))
       and role_bypass_present("OrganizationAdmin"; null)
    then
      { rule: "bypass-defeats-deletion-restriction", severity: "warning",
        message: "a \"deletion\" rule is present and bypass_actors grants an always-bypass to OrganizationAdmin -- this is advisory, not a defect. Deleting a branch requires only write access, not admin (https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/deleting-and-restoring-branches-in-a-pull-request), so this bypass does not, on its own, let every non-admin contributor with write or maintain access delete the branch this rule restricts -- they remain restricted, whether or not OrganizationAdmin is also on the list. What IS worth reconsidering: OrganizationAdmin grants every organization owner an unconditional bypass, a population nobody administers per-repository, unlike RepositoryRole \"admin\" (id=5), which is scoped to whoever holds this specific repo's own Admin role. Protocol SPEC section 6.6 requires every ruleset carry an admin bypass so a gate cannot block the fix to its own workflow -- but restoring an accidentally deleted branch is not editing a gate's workflow, so that rationale does not obviously require extending the bypass's reach to every org owner specifically for a deletion rule. Consider RepositoryRole \"admin\" (id=5) alone if repo-scoped is what you want; this check does not require the change." }
    else empty
    end
  )
]
JQ_PROGRAM

VIOLATIONS_JSON="$(echo "$RULESET_JSON" \
  | jq -c --argjson clud_bug_id "$CLUD_BUG_INTEGRATION_ID" -f "$JQ_PROGRAM")" \
  || die "$SOURCE_LABEL: validation logic failed (this is a bug in validate-ruleset.sh, not in the ruleset -- please report it)"

ERROR_COUNT="$(echo "$VIOLATIONS_JSON" | jq '[.[] | select(.severity == "error")] | length')"
WARNING_COUNT="$(echo "$VIOLATIONS_JSON" | jq '[.[] | select(.severity == "warning")] | length')"

# Print every violation regardless of severity or exit code -- a warning is
# not a reason to hide it, only a reason not to block on it.
echo "$VIOLATIONS_JSON" \
  | jq -r '.[] | (if .severity == "warning" then "⚠" else "✗" end) + " [\(.rule)] \(.message)"'

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  echo "$ERROR_COUNT violation(s) found in $SOURCE_LABEL."
  exit 1
fi

if [[ "$WARNING_COUNT" -gt 0 ]]; then
  echo "✓ $SOURCE_LABEL is valid — no blocking violations found ($WARNING_COUNT warning(s) above)."
else
  echo "✓ $SOURCE_LABEL is valid — no violations found."
fi
exit 0
