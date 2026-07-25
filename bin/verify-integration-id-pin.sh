#!/usr/bin/env bash
# Z6 forged-name-check verification harness.
#
# Proves (or disproves) the un-forgeability claim behind the integration_id
# pin added to the `clud-bug-review` entry in rulesets/clud-bug.json and
# rulesets/skdd.json: that a required_status_checks entry pinned with
# "integration_id": 3944857 (the clud-bug[bot] GitHub App's own ID) can only
# be satisfied by a check/status posted by that App -- NOT by a context-name
# match from any other token (PAT, default GITHUB_TOKEN, another App).
#
# STATUS: NOT RUN as part of the PR that ships this script. Running it for
# real requires APPLYING a ruleset to a repository, which the Z6 build
# ruling forbids doing to any live repo right now: the org-wide
# required_status_checks rule (org-default-protection, id 16898453) was
# deliberately removed org-wide on 2026-07-24 because neither clud-bug nor
# logmind is ready to be a merge gate yet -- they come back once BOTH have
# launched. This script exists so that whoever flips that switch back on
# can immediately run the exact proof instead of re-deriving it. Use it by
# hand, later, against a disposable SCRATCH repo -- never against a repo
# anyone depends on.
#
# What the two phases prove:
#   1. FORGE:    a plain token (whatever `gh` is authenticated as -- a PAT,
#                a workflow's default GITHUB_TOKEN, anything that is NOT
#                the clud-bug App) posts a commit status named
#                "clud-bug-review" with state=success against a commit
#                covered by the integration_id-pinned rule.
#                EXPECTATION: the ruleset does NOT count it. The PR's
#                mergeStateStatus stays blocked even though a
#                "clud-bug-review" context shows green in the checks list --
#                because GitHub's ruleset evaluation requires that specific
#                context to come from App 3944857, and this one didn't.
#   2. GENUINE:  the real clud-bug GitHub App (installed on the scratch
#                repo, running its normal review workflow) posts its own
#                clud-bug-review check on the same PR.
#                EXPECTATION: the SAME rule now considers the requirement
#                satisfied (mergeStateStatus flips to clean, modulo any
#                other unmet rules).
#
# This script never creates, PATCHes, or PUTs a ruleset itself -- applying
# rulesets/clud-bug.json (or skdd.json) to the scratch repo is a separate,
# explicit, one-time manual step. See `plan` output for the exact command.
#
# Usage:
#   verify-integration-id-pin.sh plan  <owner/repo>
#   verify-integration-id-pin.sh check <owner/repo> <sha-or-pr-number>
#   verify-integration-id-pin.sh forge <owner/repo> <sha> --confirm-scratch-repo=<owner/repo>
#
# Subcommands:
#   plan   Read-only. Prints the full manual runbook (ruleset apply command,
#          how to trigger the genuine clud-bug review, how to interpret
#          results). Makes no API calls. Safe to run anytime, anywhere --
#          this is the only subcommand exercised by the repo's own checks.
#
#   check  Read-only. Prints the combined status for a commit (or, if given
#          a PR number, the PR's mergeStateStatus + statusCheckRollup) so
#          you can compare before/after each phase below.
#
#   forge  MUTATES the target repo: posts a fake "clud-bug-review" success
#          status via `gh api repos/<repo>/statuses/<sha>` using whatever
#          identity `gh` is currently authenticated as. Requires
#          --confirm-scratch-repo=<owner/repo> that exactly matches the
#          first positional argument -- a deliberate footgun guard so this
#          can't fire against the wrong repo by a typo or a copy-pasted
#          command. Refuses to run without it.
#
# There is no `genuine` subcommand: you cannot fake being the clud-bug App
# from this script (App identity isn't something a PAT can assume). To
# exercise the genuine side, install the real clud-bug App on the scratch
# repo (`npx clud-bug init`) and open a real PR so its workflow posts the
# check itself, then re-run `check` and compare.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }

usage() {
  sed -n '2,58p' "$0" | sed 's/^# //; s/^#//'
}

CLUD_BUG_INTEGRATION_ID=3944857

[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

SUBCOMMAND="$1"; shift

command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
command -v jq >/dev/null || die "jq not found (brew install jq)"

case "$SUBCOMMAND" in

plan)
  [[ $# -ge 1 ]] || die "usage: $0 plan <owner/repo>"
  REPO="$1"
  cat <<EOF
Z6 forged-name-check runbook for $REPO
=======================================

This repo must be a disposable SCRATCH repo. Do not point this at anything
that matters -- phase 1 below intentionally posts a fake passing check.

0) One-time setup on the scratch repo:
   - Apply the integration_id-pinned ruleset (manual, one-time -- this
     script does not do it for you):
       gh api --method POST repos/$REPO/rulesets \\
         --input rulesets/clud-bug.json
   - Open a PR on $REPO so there is a commit/PR to test against.
   - Note the PR's head SHA: gh pr view <n> --repo $REPO --json headRefOid -q .headRefOid

1) FORGE phase (proves a name-only forgery is rejected):
     $0 forge $REPO <sha> --confirm-scratch-repo=$REPO
   Then:
     $0 check $REPO <pr-number>
   Expected result: statusCheckRollup shows a green "clud-bug-review" entry,
   but mergeStateStatus is still NOT clean (blocked) -- the ruleset ignored
   the forged report because it didn't come from App $CLUD_BUG_INTEGRATION_ID.

2) GENUINE phase (proves the real App satisfies it):
   - Install the real clud-bug App on $REPO: npx clud-bug init
   - Push a commit (or re-trigger) so clud-bug's own workflow posts its
     real clud-bug-review check on the PR.
   Then:
     $0 check $REPO <pr-number>
   Expected result: mergeStateStatus flips to clean (assuming no other
   rules are outstanding) -- the same rule now accepts the check because it
   came from App $CLUD_BUG_INTEGRATION_ID.

3) Compare the two 'check' outputs and record the result. If FORGE ever
   shows mergeStateStatus=clean, the integration_id pin has failed and Z6
   is broken -- treat that as a critical bug, not a config typo.

Static evidence (verified against GitHub's live docs, not against a real
repo -- see PR description for the exact quotes and source URLs):
  - required_status_checks[].integration_id is documented as restricting
    the required check to a specific GitHub App: "If the status is set by
    any other person or integration, merging won't be allowed."
  - GitHub's combined-status resolution is latest-report-per-context:
    the Commit Statuses API states the combined state is "success if the
    latest status for all contexts is success" -- i.e. a later forged
    report for the same context would visually overwrite an earlier
    genuine one in the naive (unpinned) case, which is exactly the attack
    integration_id closes.
EOF
  ;;

check)
  [[ $# -ge 2 ]] || die "usage: $0 check <owner/repo> <sha-or-pr-number>"
  REPO="$1"; REF="$2"
  if [[ "$REF" =~ ^[0-9]+$ ]]; then
    info "Reading PR #$REF mergeability + status rollup on $REPO"
    gh pr view "$REF" --repo "$REPO" \
      --json number,headRefOid,mergeStateStatus,mergeable,statusCheckRollup \
      | jq '{number, headRefOid, mergeStateStatus, mergeable, statusCheckRollup: [.statusCheckRollup[] | {name: (.name // .context), state: (.conclusion // .state), app: .checkSuite.app.name}]}'
  else
    info "Reading combined status for $REPO@$REF"
    gh api "repos/$REPO/commits/$REF/status" \
      | jq '{state, statuses: [.statuses[] | {context, state, creator: .creator.login}]}'
    info "Reading check-runs (App identity) for $REPO@$REF"
    gh api "repos/$REPO/commits/$REF/check-runs" \
      | jq '{check_runs: [.check_runs[] | {name, status, conclusion, app_id: .app.id, app_name: .app.name}]}'
  fi
  ;;

forge)
  [[ $# -ge 2 ]] || die "usage: $0 forge <owner/repo> <sha> --confirm-scratch-repo=<owner/repo>"
  REPO="$1"; SHA="$2"; shift 2
  CONFIRM=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --confirm-scratch-repo=*) CONFIRM="${1#--confirm-scratch-repo=}"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ -n "$CONFIRM" ]] || die "refusing to run: pass --confirm-scratch-repo=$REPO to acknowledge this posts a real (forged) status to a real repo"
  [[ "$CONFIRM" == "$REPO" ]] || die "--confirm-scratch-repo='$CONFIRM' does not match target repo '$REPO' -- aborting"

  WHOAMI="$(gh api user -q .login 2>/dev/null || echo '<unknown, likely a non-user token>')"
  info "Posting FORGED clud-bug-review status to $REPO@$SHA as '$WHOAMI' (NOT the clud-bug App, id=$CLUD_BUG_INTEGRATION_ID)"
  gh api --method POST "repos/$REPO/statuses/$SHA" \
    -f state=success \
    -f context=clud-bug-review \
    -f description="FORGED for Z6 verification -- posted by $WHOAMI, not the clud-bug App" \
    --silent \
    || die "failed to POST forged status to $REPO@$SHA"
  info "Forged status posted. Now run: $0 check $REPO <pr-number-for-$SHA>"
  info "Expect: statusCheckRollup shows clud-bug-review=success, but mergeStateStatus is still blocked (integration_id pin rejects this report)."
  ;;

*)
  die "unknown subcommand: $SUBCOMMAND (expected: plan, check, forge)"
  ;;
esac
