# reporulez

Drop-in GitHub repository rulesets tuned for AI-driven development.

The goal: let an AI agent branch → push → open a PR → wait for checks → merge, without
bypassing safety.

**What the ruleset alone enforces (always on):** PRs are required (no direct pushes to
the default branch), force pushes and default-branch deletions are blocked, linear history
required, squash-only merges, stale reviews dismissed on push, last-push approval required,
**any** review thread that gets created must be resolved before merge.

**What it does *not* enforce until you configure more:** that a review actually happens,
and that CI checks pass. The `copilot` variant adds GitHub Copilot auto-review (advisory
comments) so threads get created on every PR. The `external` variant assumes you've
installed a non-Copilot AI reviewer App that does the same — without one, the
thread-resolution gate has nothing to gate on. Status checks: the ruleset deliberately
**does not include a `required_status_checks` rule** (GitHub's API rejects that rule
with an empty list, and we can't know your CI workflow names). Add it yourself after
install via the GitHub UI. Until you do (and until your AI reviewer is installed for the
`external` variant), the structural rules above are the only merge gates, and an empty
PR can be self-merged.

The `--human-review` flag layers on a required human approval if you want a person in the
loop as well.

## Quickstart

```sh
# Default: Copilot auto-review enabled, no human approval required (full AI auto-mode).
curl -fsSL https://raw.githubusercontent.com/thrillmot/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo

# With a human-in-the-loop approval gate:
curl -fsSL https://raw.githubusercontent.com/thrillmot/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo copilot --human-review

# If you already use a non-Copilot AI reviewer (Claude Code Review, CodeRabbit, Cursor, …):
curl -fsSL https://raw.githubusercontent.com/thrillmot/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo external

# Full clud-bug + logmind stack (canonical 4 contexts ship in the variant)
# plus your project's pytest matrix as extra required checks:
curl -fsSL https://raw.githubusercontent.com/thrillmot/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo clud-bug-logmind \
      --extra-check 'pytest (ubuntu-latest / py3.10)' \
      --extra-check 'pytest (ubuntu-latest / py3.12)'
```

`--extra-check 'CONTEXT NAME'` is repeatable and appends project-specific status
check contexts to the variant's `required_status_checks` list at apply time. Lets
a single command match a project's actual CI without forking the variant JSON.
Only works against variants that ship `required_status_checks` (currently
`clud-bug-logmind`); errors cleanly on `copilot`/`external` since they deliberately
omit that rule.

Requires the [`gh`](https://cli.github.com) CLI authenticated against the target repo, and `jq`.

## Variants

| Variant | Copilot auto-review | Required status checks | Use when |
|---|---|---|---|
| `copilot` (default) | enabled via the `copilot_code_review` ruleset rule | none — add manually after install | You want GitHub's built-in reviewer to comment on every PR. |
| `external` | not included | none — add manually after install | You've installed a non-Copilot AI reviewer GitHub App that already comments on every PR — e.g. [**clud-bug**](https://github.com/thrillmot/clud-bug) (Claude-powered, project-aware, one-command install), CodeRabbit, Cursor, or Anthropic's Claude Code Review App. |
| `clud-bug-logmind` | not included | `clud-bug-review`, `check-derived-docs`, `check-decisions`, `check-links` — **strict** (branches must be up to date) | Canonical bundle for repos with **both** [**clud-bug**](https://github.com/thrillmot/clud-bug) and [**logmind**](https://logmind.dev) installed. Extends `external` with the four well-known check contexts both tools ship + strict-mode so logmind v0.2's derived-file conflict-free property stays sound. |

> 💡 Pairs nicely with [**clud-bug**](https://github.com/thrillmot/clud-bug): a one-command (`npx clud-bug init`) install of a Claude PR-review GitHub Action that auto-discovers project-aware review skills from [skills.sh](https://skills.sh) and resolves its own review threads when issues are fixed — which is exactly what the `required_review_thread_resolution` gate in this ruleset is designed to lean on. This repo itself uses clud-bug; see PR #2 / #3 for live review examples.

All three variants share the structural rules: PR required, force push and deletion blocked,
linear history, squash-only merges, dismiss stale reviews, all threads must resolve.
The `copilot` and `external` variants **deliberately omit** a `required_status_checks` rule
(GitHub's API rejects an empty list, and we can't know your CI workflow names) — add the
rule with your contexts manually after install. The `clud-bug-logmind` variant skips that
manual step because we *do* know the canonical contexts when both tools are installed.

> **Note on `clud-bug-logmind`'s strict mode:** `strict_required_status_checks_policy: true`
> in this variant is load-bearing for logmind v0.2's per-PR derived-file model (`docs/timeline.md`
> regenerated on every PR). Without rebase-before-merge, two concurrent PRs can each pass
> `check-derived-docs` independently and then deadlock on conflicting regens at merge time.
> If logmind ever changes that model (e.g. v0.3 auto-merges `timeline.md`), revisit whether
> strict mode is still required here.

`require_last_push_approval` defaults to `false`. It would deadlock merges in 0-approval
mode (`require_last_push_approval: true` + `required_approving_review_count: 0` means
"the last push must be approved by a non-pusher, but no one is required to approve" —
GitHub blocks merge forever). `--human-review` flips both fields together (count → 1,
last-push-approval → true) so the human approver requirement and the non-pusher
requirement stay consistent.

### Human approval flag

`--human-review` patches `required_approving_review_count` from `0` to `1`. Approvals
must come from a **human** — both GitHub Copilot code review and Anthropic's Claude
Code Review GitHub App submit *Comment* reviews only, never *Approve*, so they cannot
satisfy this count. (Bots that *can* approve, like CodeRabbit's auto-approve, do.)

## What gets configured

The installer applies two things:

1. **A repository ruleset** (`reporulez-default`) targeting the default branch:
   - PR required, with last-push approval, thread resolution, stale-review dismissal
   - Block default-branch deletion
   - Block force pushes
   - Require linear history
   - Allowed merge methods: `squash`
   - (copilot variant only) Copilot code review on every push, not on drafts

   The ruleset deliberately **does not include a `required_status_checks` rule**.
   GitHub's API rejects that rule with an empty list, and we can't know your CI
   workflow names — you add the rule yourself after install (see step 1 below).
2. **Repository settings** that rulesets can't control:
   - Auto-merge enabled
   - Squash-only merging
   - Delete head branch on merge
   - Squash commit title = PR title, message = PR body

The script is idempotent — running it twice updates the existing ruleset instead of creating a duplicate.

## After install — manual steps

1. **Add a `Require status checks to pass` rule** with your CI workflow names.
   - **`copilot` / `external` variants:** the ruleset ships without this rule
     (GitHub's API rejects an empty list, and we can't know your workflow names).
     Add it via Settings → Rules → Rulesets → `reporulez-default` → "Require
     status checks to pass".
   - **`clud-bug-logmind` variant: skip this step.** The ruleset already ships
     this rule with the four canonical contexts (`clud-bug-review`,
     `check-derived-docs`, `check-decisions`, `check-links`) and strict mode on.
     Editing the rule manually here will clobber those contexts.
2. **Drop in templates** if you want:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/thrillmot/reporulez/main/templates/CODEOWNERS \
     -o .github/CODEOWNERS
   curl -fsSL https://raw.githubusercontent.com/thrillmot/reporulez/main/templates/pull_request_template.md \
     -o .github/pull_request_template.md
   ```
3. **Verify entitlement / app install:**
   - `copilot` variant: the repo must have Copilot code review available (Pro / Pro+ / Business).
   - `external` variant: an AI reviewer GitHub App must be installed and configured.
   - `clud-bug-logmind` variant: **both** [clud-bug](https://github.com/thrillmot/clud-bug)
     **and** [logmind](https://logmind.dev) must be installed on the target repo
     (run `npx clud-bug init` and `logmind init --all-agents --install-hook`).
     The shipped `required_status_checks` rule pins four contexts that come from
     those tools' workflows; if either tool is missing, those checks will never
     report and every PR will block forever (`strict_required_status_checks_policy: true`).

## Upgrading logmind

After bumping the logmind CLI, re-run `logmind init` to refresh the shipped
workflow templates:

```sh
pipx install --force logmind     # or: pip install --upgrade logmind
logmind init                     # idempotent refresh in v0.2.1+ — rewrites
                                 # workflow templates in place, leaves
                                 # docs/ and .logmind/ untouched
```

For clud-bug, see [thrillmot/clud-bug](https://github.com/thrillmot/clud-bug)'s
README for the current upgrade flow.

## Hand-import without the script

If you don't want to run a shell script (e.g. inside CI), import the JSON directly:

```sh
gh api --method POST repos/owner/repo/rulesets \
  --input rulesets/copilot.json
```

To require a human approval in this path, edit the JSON's `required_approving_review_count` to `1` first.

## Out of scope (for now)

- Org-level rulesets (use repo-level for now; org-level lives at a different API path)
- Tag protection
- Push rulesets (file paths, file sizes, etc.)
- Required signed commits — high friction for AI agents without signing keys
- Environment / deployment protection rules

## License

MIT — see [LICENSE](LICENSE).
