#!/usr/bin/env bash
# Check that every `updates` entry in a dependabot.yml targets the org
# staging branch (default: "dev"), not the default branch.
#
# reporulez#71 (asks B): dependabot config is per-repo and GitHub reads
# `.github/dependabot.yml` ONLY from the default branch -- there is no
# org-level dependabot setting. A repo whose dependabot.yml omits
# `target-branch` (or sets it to the default branch) keeps opening
# dependency-bump PRs against production forever, drifting `main` ahead of
# `dev` -- this happened for real: clud-bug#328 was a 16-file conflict lane
# after `main` drifted 22 commits ahead of `dev` in three weeks. Fixed by
# hand in thrillmade/clud-bug#340 and the same fix in a private sibling repository (both
# added `target-branch: "dev"` to every `updates` entry) -- this script is
# what would have caught it before either repo drifted, and is the
# regression guard against it drifting again.
#
# WHAT THIS CHECKS, AND WHEN IT CAN CATCH A REGRESSION: it audits the
# dependabot.yml that is on the repository's DEFAULT branch right now (the
# only copy GitHub reads), not the diff of a pull request. So it cannot
# block the pull request that introduces a bad config -- that PR's file is
# not on the default branch yet. It catches the defect after the merge
# (a push to the default branch, a scheduled run, or the next pull request
# anywhere in the repo), and it catches drift nobody made through a PR.
#
# THE GUARD THAT MATTERS (reporulez#71's own words, "the recurring defect
# class here"): a check that finds no dependabot.yml, cannot parse one, crashes
# while parsing one, or examines zero repos MUST NOT exit 0. A run that examined nothing must
# never read as a pass. This script's exit-code taxonomy exists entirely to
# make that true -- see "Exit codes" below, and
# tests/test-check-dependabot-target.sh's "input errors" section, which
# pins it.
#
# Usage:
#   check-dependabot-target.sh <path-to-dependabot.yml>
#   check-dependabot-target.sh -                    # read YAML from stdin
#   check-dependabot-target.sh --repo <owner/repo>  # fetch from that repo's
#                                                    # default branch via gh
#   check-dependabot-target.sh --all <owner>        # every non-archived repo
#                                                    # under <owner>
#
# Flags:
#   --target <branch>  Branch every `updates` entry must target. Default: dev.
#   --quiet             In --all mode, print only non-compliant repos.
#
# Exit codes -- deliberately mirrors bin/validate-ruleset.sh's taxonomy (a
# single-target check: 0 clean / 1 real violation / 2 couldn't even check),
# blended with bin/audit.sh's for --all (a many-repo scan folds each repo's
# outcome into one aggregate, continuing past per-repo failures rather than
# aborting the whole run on the first one):
#
#   Single-target mode (<path> / stdin / --repo):
#     0   dependabot.yml exists, parsed, has >=1 `updates` entry, every
#         entry's target-branch matches --target.
#     1   dependabot.yml exists and parsed, but at least one `updates`
#         entry is missing target-branch or targets the wrong branch. A
#         file with three entries where only two carry the key exits 1,
#         not 0 -- every entry is checked, not just whether any is right.
#     2   couldn't even check: file/repo not found, YAML failed to parse,
#         `updates` key present but empty/absent (nothing to check is NOT
#         the same as nothing wrong), the Python checker crashed or printed
#         no well-formed `RESULT: checked=N violations=V` line, or a usage
#         error. NEVER 0 -- an
#         input this script could not read is not a passing input.
#
#   --all <owner> mode:
#     0   at least one repo was examined, and every examined repo is
#         single-target-clean.
#     1   at least one repo was examined, and at least one repo is
#         non-compliant -- folds EVERY single-target outcome that isn't a
#         clean pass (missing file, unparseable YAML, wrong/missing
#         target-branch) into this one bucket, the same way bin/audit.sh
#         continues past a per-repo GET failure instead of aborting the
#         scan. The scan itself still ran; what it found is the failure.
#     2   the scan itself could not run: enumerating <owner>'s repos
#         failed (including a partial listing), or returned zero repos. Examining zero repos must not
#         exit 0 (reporulez#71) -- it must not exit 1 either, since 1 in
#         this script means "repos were examined and found wanting";
#         reporting a real violation for repos never looked at would be
#         its own kind of lie. 2 says plainly: the audit did not happen.
#
# KNOWN LIMIT: the shell drops NUL bytes when it reads a file, so a config
# containing NUL bytes reaches the parser with them stripped and can pass
# here even though GitHub itself would reject the original file.

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }

usage() {
  sed -n '2,44p' "$0" | sed 's/^# //; s/^#//'
}

TARGET_BRANCH="dev"
QUIET="false"
MODE=""
MODE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    --target)
      [[ $# -ge 2 ]] || die "--target requires a branch name argument"
      TARGET_BRANCH="$2"; shift 2 ;;
    --quiet)
      QUIET="true"; shift ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires an owner/repo argument"
      [[ -z "$MODE" ]] || die "--repo, --all, and a path are mutually exclusive"
      [[ "$2" == */* ]] || die "repo must be in owner/repo form, got: $2"
      MODE="repo"; MODE_ARG="$2"; shift 2 ;;
    --all)
      [[ $# -ge 2 ]] || die "--all requires an owner argument (e.g. --all thrillmade)"
      [[ -z "$MODE" ]] || die "--repo, --all, and a path are mutually exclusive"
      case "$2" in
        --*) die "--all requires an owner argument; got flag '$2' instead." ;;
      esac
      MODE="all"; MODE_ARG="$2"; shift 2 ;;
    *)
      [[ -z "$MODE" ]] || die "--repo, --all, and a path are mutually exclusive"
      MODE="path"; MODE_ARG="$1"; shift ;;
  esac
done

[[ -n "$MODE" ]] || { usage; exit 2; }

command -v jq >/dev/null || die "jq not found (brew install jq)"
command -v python3 >/dev/null || die "python3 not found"
python3 -c "import yaml" >/dev/null 2>&1 \
  || die "PyYAML not importable (pip install pyyaml)"

# The Python side of the parse-and-check logic lives in its own temp file
# for the same reason bin/validate-ruleset.sh keeps its jq program in one:
# no bash quote-escaping bleeding into the parsing logic. Reads the YAML
# text from stdin, the required target branch from argv[1]. Prints one
# line per `updates` entry that is missing or wrong, then exactly one
# summary line "RESULT: checked=<N> violations=<V>". Its documented exit
# codes are 0 (RESULT line printed) and 2 (PARSE_ERROR line printed);
# anything else -- a traceback, a killed interpreter, a missing RESULT
# line -- is a crash, and the bash caller treats a crash as "could not
# examine", never as clean. A pass needs positive proof, so the shell
# accepts a clean verdict only from a well-formed RESULT line.
PY_PROGRAM="$(mktemp)"
trap 'rm -f "$PY_PROGRAM"' EXIT

cat > "$PY_PROGRAM" <<'PYEOF'
import sys, yaml

want = sys.argv[1]
try:
    doc = yaml.safe_load(sys.stdin.read())
except yaml.YAMLError as e:
    print(f"PARSE_ERROR: {e}")
    sys.exit(2)

if doc is None:
    print("RESULT: checked=0 violations=0")
    sys.exit(0)
if not isinstance(doc, dict):
    print("PARSE_ERROR: top-level YAML is not a mapping")
    sys.exit(2)

updates = doc.get("updates")
if not updates:
    # Key absent, or present but an empty list -- either way there is
    # nothing to check. That is distinct from "nothing wrong": a
    # dependabot.yml with zero updates entries is itself suspicious for a
    # file that exists at all, and reporulez#71's own guard ("examines
    # nothing must not read as a pass") applies at this granularity too.
    print("RESULT: checked=0 violations=0")
    sys.exit(0)
if not isinstance(updates, list):
    print("PARSE_ERROR: 'updates' key is not a list")
    sys.exit(2)

violations = 0
for i, entry in enumerate(updates):
    if not isinstance(entry, dict):
        print(f"VIOLATION: updates[{i}] is not a mapping")
        violations += 1
        continue
    eco = entry.get("package-ecosystem", f"updates[{i}]")
    tb = entry.get("target-branch")
    if tb != want:
        got = "(absent)" if tb is None else repr(tb)
        print(f"VIOLATION: package-ecosystem={eco!r} target-branch={got}, want {want!r}")
        violations += 1

print(f"RESULT: checked={len(updates)} violations={violations}")
sys.exit(0)
PYEOF

# check_one <yaml-text> <label> -- runs the Python parser/checker against
# one dependabot.yml's text, prints its findings (prefixed with <label>) to
# STDOUT -- findings are the script's real output, same convention as
# bin/validate-ruleset.sh's violation lines and bin/audit.sh's ✓/✗ rows;
# only usage/narration goes to stderr (die/info). Returns its verdict via
# its own exit status:
#   0  clean       -- parsed, >=1 entries, all correct
#   1  violation   -- parsed, >=1 entries, >=1 wrong or missing
#   2  no-updates  -- parsed, but zero `updates` entries (nothing to check)
#   3  could-not-examine -- YAML did not parse, wasn't a mapping/list where
#      expected, or the Python side crashed / printed no valid result line
#
# NOT a global variable set from inside the function -- an earlier version
# used one (CHECK_VERDICT) on the reasoning that a numeric code "would
# collide with set -e", but that reasoning was wrong in a way clud-bug
# caught for real on thrillmade/reporulez#73: `--all --quiet` reported
# exit 1 EVEN WHEN EVERY REPO WAS 100% COMPLIANT, unconditionally, every
# run. Root cause: `FINDINGS="$(check_one ...)"` forks a subshell for the
# command substitution, so an assignment to CHECK_VERDICT made INSIDE
# check_one during that call never reaches the parent shell -- the
# caller's read of `$CHECK_VERDICT` afterward saw a stale or empty value,
# not the just-computed one. A function's own EXIT STATUS does not have
# this problem: `$?` immediately after `x="$(f)"` is f's real exit code,
# because that is a property of the command substitution itself, not a
# side effect made inside it. Callers use the standard
# `check_one ... && rc=0 || rc=$?` idiom (this file runs under `set -e`,
# so a bare nonzero return would otherwise abort the script) --
# see tests/test-check-dependabot-target.sh's "--all --quiet" cases,
# added specifically because the original suite never exercised --quiet
# with more than one repo and so never caught this.
check_one() {
  local yaml_text="$1" label="$2"
  local output rc errfile
  errfile="$(mktemp)"
  # `cmd && rc=0 || rc=$?` is the standard idiom for capturing a command's
  # real exit status under `set -e` without the nonzero case tripping
  # errexit before `rc=$?` runs -- exit 2 (parse error) is an EXPECTED
  # outcome here, not a bug to abort on. stderr goes to its own file so a
  # traceback can never be mistaken for a finding (or forge a RESULT line).
  output="$(printf '%s' "$yaml_text" | python3 "$PY_PROGRAM" "$TARGET_BRANCH" 2>"$errfile")" && rc=0 || rc=$?
  local errtext
  errtext="$(head -c 400 "$errfile" | tail -n 3 | tr '\n' ' ')"
  rm -f "$errfile"

  if [[ "$rc" -eq 2 ]] && grep -q '^PARSE_ERROR:' <<< "$output"; then
    echo "✗ $label: could not parse -- $(grep '^PARSE_ERROR:' <<< "$output" | head -1)"
    return 3
  fi

  # Positive proof or nothing: exit code 0 and exactly one well-formed
  # RESULT line, with a violation count that matches the VIOLATION lines
  # actually printed. A crash (any other exit code, a traceback, a killed
  # interpreter, unparseable output) is "could not examine" -- exit 2 at
  # the top level, never a tick.
  local nresult nviol_lines checked violations
  nresult="$(grep -c '^RESULT: ' <<< "$output" || true)"
  nviol_lines="$(grep -c '^VIOLATION: ' <<< "$output" || true)"
  if [[ "$rc" -ne 0 || "$nresult" -ne 1 ]] \
     || ! grep -qE '^RESULT: checked=[0-9]+ violations=[0-9]+$' <<< "$output"; then
    echo "✗ $label: could not examine -- checker crashed or produced no result line (exit $rc) ${errtext}"
    return 3
  fi
  checked="$(grep -E '^RESULT: ' <<< "$output" | sed -E 's/^RESULT: checked=([0-9]+) violations=([0-9]+)$/\1/')"
  violations="$(grep -E '^RESULT: ' <<< "$output" | sed -E 's/^RESULT: checked=([0-9]+) violations=([0-9]+)$/\2/')"
  if [[ "$violations" -gt "$checked" || "$violations" -ne "$nviol_lines" ]]; then
    echo "✗ $label: could not examine -- result line (checked=$checked violations=$violations) disagrees with the $nviol_lines violation line(s) printed"
    return 3
  fi

  # Nothing to check is not the same as nothing wrong (the existing rule
  # for a legitimately empty or absent `updates` list): exit 2.
  if [[ "$checked" -eq 0 ]]; then
    echo "✗ $label: dependabot.yml has no 'updates' entries -- nothing to check"
    return 2
  fi

  while IFS= read -r line; do
    [[ "$line" == VIOLATION:* ]] && echo "✗ $label: ${line#VIOLATION: }"
  done <<< "$output"

  if [[ "$violations" -eq 0 ]]; then
    echo "✓ $label: all updates entries target \"$TARGET_BRANCH\""
    return 0
  else
    return 1
  fi
}

fetch_repo_yaml() {
  # Fetches <repo>'s .github/dependabot.yml from its DEFAULT branch (the
  # only branch GitHub itself reads dependabot config from -- fetching any
  # other branch would check a copy GitHub never uses). Prints the decoded
  # YAML text to stdout. Returns 1 if the `gh api` call itself failed
  # (repo/file not found, no access, rate-limited); returns 0 with empty
  # stdout if the call succeeded but the file's content is genuinely
  # empty. Callers can and should tell these apart -- an earlier version
  # of this function funneled both through the same empty-stdout signal,
  # which clud-bug flagged (thrillmade/reporulez#73 review): a real fetch
  # failure and "dependabot.yml exists but is a 0-byte file" both died
  # with the same "could not fetch" message, misreporting the latter.
  # Both cases still correctly exit 2 either way (the guard this file
  # exists for holds regardless), so this was a message-accuracy issue,
  # not a correctness one -- fixed anyway since the distinction is cheap.
  local repo="$1"
  local content_b64 rc
  content_b64="$(gh api "repos/$repo/contents/.github/dependabot.yml" --jq '.content' 2>/dev/null)" && rc=0 || rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  printf '%s' "$content_b64" | tr -d '\n' | base64 -d 2>/dev/null
  return 0
}

case "$MODE" in
  path)
    if [[ "$MODE_ARG" == "-" ]]; then
      YAML_TEXT="$(cat)" || die "failed to read YAML from stdin"
      LABEL="<stdin>"
    else
      [[ -f "$MODE_ARG" ]] || die "no such file: $MODE_ARG"
      YAML_TEXT="$(cat "$MODE_ARG")" || die "failed to read $MODE_ARG"
      LABEL="$MODE_ARG"
    fi
    [[ -n "$YAML_TEXT" ]] || die "$LABEL is empty -- nothing to check"

    check_one "$YAML_TEXT" "$LABEL" && VERDICT_RC=0 || VERDICT_RC=$?
    case "$VERDICT_RC" in
      0) exit 0 ;;
      1) exit 1 ;;
      2|3) exit 2 ;;
      *) die "internal error: unrecognized verdict code '$VERDICT_RC'" ;;
    esac
    ;;

  repo)
    command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

    YAML_TEXT="$(fetch_repo_yaml "$MODE_ARG")" && FETCH_RC=0 || FETCH_RC=$?
    if [[ "$FETCH_RC" -ne 0 ]]; then
      die "could not fetch .github/dependabot.yml from $MODE_ARG's default branch (missing, no access, or rate-limited)"
    fi
    [[ -n "$YAML_TEXT" ]] || die "$MODE_ARG's .github/dependabot.yml was fetched successfully but is empty -- nothing to check"

    check_one "$YAML_TEXT" "$MODE_ARG" && VERDICT_RC=0 || VERDICT_RC=$?
    case "$VERDICT_RC" in
      0) exit 0 ;;
      1) exit 1 ;;
      2|3) exit 2 ;;
      *) die "internal error: unrecognized verdict code '$VERDICT_RC'" ;;
    esac
    ;;

  all)
    command -v gh >/dev/null || die "gh CLI not found (https://cli.github.com)"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

    info "Enumerating non-archived repos under $MODE_ARG"
    REPOS=()
    # Capture the listing before reading it: `|| true` inside a process
    # substitution swallowed a failed or partial listing, so half an org
    # read as a clean audit of all of it. A failed listing is "could not
    # examine" (exit 2), even if some pages arrived first.
    LIST_ERR="$(mktemp)"
    LISTING="$(gh api --paginate "orgs/$MODE_ARG/repos?per_page=100" \
              --jq '.[] | select(.archived == false) | .full_name' 2>"$LIST_ERR")" && LIST_RC=0 || LIST_RC=$?
    rm -f "$LIST_ERR"
    if [[ "$LIST_RC" -ne 0 ]]; then
      die "could not examine '$MODE_ARG': listing its repositories failed (gh exit $LIST_RC) -- a partial listing is not a clean audit, it is a failed one"
    fi
    while read -r REPO; do
      [[ -n "$REPO" ]] && REPOS+=("$REPO")
    done <<< "$LISTING"

    # The guard reporulez#71 exists for: enumeration failing outright and
    # enumeration succeeding-but-empty must both land here, not at exit 0.
    [[ ${#REPOS[@]} -gt 0 ]] || die "examined zero repos under '$MODE_ARG' (enumeration failed, or the org has no non-archived repos) -- this is not a clean audit, it is a failed one"

    info "Checking dependabot target-branch on ${#REPOS[@]} repo(s) (must be \"$TARGET_BRANCH\")"

    ANY_VIOLATION=0
    for repo in "${REPOS[@]}"; do
      YAML_TEXT="$(fetch_repo_yaml "$repo")" && FETCH_RC=0 || FETCH_RC=$?
      if [[ "$FETCH_RC" -ne 0 ]]; then
        echo "✗ $repo: no .github/dependabot.yml found on default branch (or repo/API error)"
        ANY_VIOLATION=1
        continue
      fi
      if [[ -z "$YAML_TEXT" ]]; then
        echo "✗ $repo: .github/dependabot.yml was fetched successfully but is empty -- nothing to check"
        ANY_VIOLATION=1
        continue
      fi
      if [[ "$QUIET" == "true" ]]; then
        FINDINGS="$(check_one "$YAML_TEXT" "$repo")" && VERDICT_RC=0 || VERDICT_RC=$?
        [[ "$VERDICT_RC" -eq 0 ]] || echo "$FINDINGS"
      else
        check_one "$YAML_TEXT" "$repo" && VERDICT_RC=0 || VERDICT_RC=$?
      fi
      [[ "$VERDICT_RC" -eq 0 ]] || ANY_VIOLATION=1
    done

    echo
    if [[ "$ANY_VIOLATION" -eq 0 ]]; then
      echo "✓ all ${#REPOS[@]} repo(s) target \"$TARGET_BRANCH\" on every dependabot updates entry."
      exit 0
    else
      echo "✗ non-compliant dependabot.yml found among ${#REPOS[@]} repo(s) audited (see ✗ lines above). Remediation: add \`target-branch: \"$TARGET_BRANCH\"\` to every entry under \`updates:\` -- PRs that edit .github/dependabot.yml must target the DEFAULT branch directly (GitHub reads dependabot config only from there), not dev. See thrillmade/clud-bug#340 for the shape."
      exit 1
    fi
    ;;
esac
