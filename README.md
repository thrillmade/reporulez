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
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo

# With a human-in-the-loop approval gate:
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo copilot --human-review

# If you already use a non-Copilot AI reviewer (Claude Code Review, CodeRabbit, Cursor, …):
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo external

# Full clud-bug + logmind stack (canonical 4 contexts ship in the variant;
# Repository admin bypass for clud-bug self-mod PRs is ON BY DEFAULT for
# this variant), plus your project's pytest matrix as extra required checks:
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
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

`--bypass-admin` adds the **Repository admin** role to `bypass_actors`. **Default
ON for `clud-bug-logmind`** (the self-mod use case practically always needs it);
default OFF for `copilot`/`external`. Override the per-variant default with
`--no-bypass-admin` to force off, or `--bypass-admin` to force on. See
[Admin bypass flag](#admin-bypass-flag) below for the rationale.

Requires the [`gh`](https://cli.github.com) CLI authenticated against the target repo, and `jq`.

## Variants

| Variant | Copilot auto-review | Required status checks | Use when |
|---|---|---|---|
| `copilot` (default) | enabled via the `copilot_code_review` ruleset rule | none — add manually after install | You want GitHub's built-in reviewer to comment on every PR. |
| `external` | not included | none — add manually after install | You've installed a non-Copilot AI reviewer GitHub App that already comments on every PR — e.g. [**clud-bug**](https://github.com/thrillmade/clud-bug) (Claude-powered, project-aware, one-command install), CodeRabbit, Cursor, or Anthropic's Claude Code Review App. |
| `clud-bug-logmind` | not included | `clud-bug-review`, `check-derived-docs`, `check-decisions`, `check-links` — **strict** (branches must be up to date) | Canonical bundle for repos with **both** [**clud-bug**](https://github.com/thrillmade/clud-bug) and [**logmind**](https://logmind.dev) installed. Extends `external` with the four well-known check contexts both tools ship + strict-mode so logmind v0.2's derived-file conflict-free property stays sound. |

> 💡 Pairs nicely with [**clud-bug**](https://github.com/thrillmade/clud-bug): a one-command (`npx clud-bug init`) install of a Claude PR-review GitHub Action that auto-discovers project-aware review skills from [skills.sh](https://skills.sh) and resolves its own review threads when issues are fixed — which is exactly what the `required_review_thread_resolution` gate in this ruleset is designed to lean on. This repo itself uses clud-bug; see PR #2 / #3 for live review examples.

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

The default `required_approving_review_count: 0` is intentional for AI-driven flows:
the merge gate is the **thread-resolution + status-check** combination, not an approval
count. An AI reviewer (clud-bug, Claude Code Review, Copilot, CodeRabbit) creates
review threads that must be resolved, plus the required status checks must be green
— there's no count to satisfy because no approvals were ever required to begin with.
Pass `--human-review` only if you want to layer a human approver on top.

### Admin bypass flag

`--bypass-admin` pre-populates `bypass_actors` with the **Repository admin** role
(`actor_type: RepositoryRole`, `actor_id: 5`, `bypass_mode: always`).

**Per-variant default:**
- `clud-bug-logmind` → **ON by default** (the variant's self-mod use case practically
  always needs the bypass — without it every routine clud-bug self-mod deadlocks).
  Use `--no-bypass-admin` to opt out.
- `copilot`, `external` → **OFF by default** (no built-in self-mod use case).
  Pass `--bypass-admin` to opt in.

**Why it matters for clud-bug:** `clud-bug`'s reviewer action (`anthropics/claude-code-action`)
deliberately refuses (HTTP 401) to review pull requests that modify its own workflow
files under `.github/workflows/clud-bug-*.yml`. This is a self-mod guard — without it,
a malicious PR could rewrite the reviewer to rubber-stamp itself. The cost is that
*legitimate* self-mod PRs (e.g. routine `npx clud-bug upgrade` version bumps) also
fail the required `clud-bug-review` check and deadlock against `required_status_checks`.

Three ways out:
1. **`--bypass-admin` (default ON for `clud-bug-logmind`):** a repo admin can merge
   the stuck PR via "Bypass branch protections" without touching the ruleset.
2. **Hand-PATCH `bypass_actors` mid-merge** via `gh api --method PUT repos/$REPO/rulesets/$ID`
   — works once, but every fresh install needs the same manual setup.
3. **Toggle `enforcement: disabled` globally**, merge, re-enable — opens a real
   policy-gap window where the ruleset doesn't protect *anything*.

The flag works with any variant; we made it the default ONLY for `clud-bug-logmind`
because that's the variant whose required-checks list is opinionated about clud-bug
specifically, and clud-bug's self-mod ceremony is a normal recurring flow there.

**Org repos:** the `RepositoryRole` admin role exists on both personal and org-managed
repos, so `--bypass-admin` works in both contexts. Org owners on an org-managed repo
already inherit admin access to the repo and can use the same bypass. If you want a
*separate* org-administrator bypass entry (`actor_type: OrganizationAdmin`, `actor_id: 1`),
add it manually after install — including it by default would 404 on personal repos.

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
   curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/templates/CODEOWNERS \
     -o .github/CODEOWNERS
   curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/templates/pull_request_template.md \
     -o .github/pull_request_template.md
   ```

   **Dependabot templates** under `templates/dependabot/` cover the realistic
   shapes thrillmade-org repos land on. Pick one and curl it into
   `.github/dependabot.yml`:

   | Template | Ecosystems | Use when |
   |---|---|---|
   | `python.yml` | pip + github-actions | Python projects (pyproject.toml / requirements.txt at repo root). |
   | `typescript.yml` | npm + github-actions | TS/JS projects (package.json at repo root; duplicate the npm entry per workspace for a monorepo). |
   | `github-actions-only.yml` | github-actions only | Repos with no runtime package manifest — shell-script repos, docs-only repos, config-only repos. (reporulez itself ships this one.) |

   All three use a weekly Monday cadence with an `open-pull-requests-limit` of
   5 per ecosystem. Edit the file after curling if you need a different cadence,
   subdirectory, or label set.

   ```sh
   # Pick the one that matches your repo:
   curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/templates/dependabot/python.yml \
     -o .github/dependabot.yml
   ```

   Or skip the curl: `apply.sh` will write the chosen template directly to the
   target repo if you pass `--with-dependabot=<ecosystem>` on the same invocation:

   ```sh
   ./bin/apply.sh owner/repo clud-bug-logmind --with-dependabot=python
   ```

   Idempotent — re-running with the same flag is a no-op when the file is
   already current. Silently overwrites a different existing
   `.github/dependabot.yml` (consistent with how `--extra-check` and the
   other flags overwrite the ruleset on re-apply).

   > **Known limitation** (ecosystem switch on re-apply, copilot/external
   > only): switching the `--with-dependabot=<eco>` value on a repo
   > that already has the ruleset applied will fail the contents PUT
   > because the existing ruleset's `pull_request` rule blocks direct
   > default-branch writes. The `--bypass-admin` flag does **not** help
   > here — it only mutates the in-memory ruleset JSON that step 3
   > applies; it does not patch the existing ruleset that step 2's
   > PUT runs against. The actual prerequisite is that the target
   > repo's *existing* ruleset already contains Repository admin in
   > `bypass_actors`. For `clud-bug-logmind` that's the variant
   > default, so first-time AND ecosystem-switching applies both
   > work. For `copilot`/`external`, only first-apply and idempotent
   > re-apply work without manual intervention; ecosystem-switching
   > requires either temporarily editing the existing ruleset on
   > GitHub (Settings → Rules → Rulesets → `reporulez-default` →
   > add Repository admin to `Bypass list`) or temporarily deleting
   > the existing ruleset before re-applying.
3. **Verify entitlement / app install:**
   - `copilot` variant: the repo must have Copilot code review available (Pro / Pro+ / Business).
   - `external` variant: an AI reviewer GitHub App must be installed and configured.
   - `clud-bug-logmind` variant: **both** [clud-bug](https://github.com/thrillmade/clud-bug)
     **and** [logmind](https://logmind.dev) must be installed on the target repo
     (run `npx clud-bug init` and `logmind init --all-agents --install-hook`).
     The shipped `required_status_checks` rule pins four contexts that come from
     those tools' workflows; if either tool is missing, those checks will never
     report and every PR will block forever (`strict_required_status_checks_policy: true`).

## Auditing drift across repos

Once `apply.sh` has run on a repo, its canonical settings (auto-merge,
squash-only, delete-on-merge, etc.) can still be flipped from the
GitHub UI or via a direct `gh api PATCH`. `bin/audit.sh` is a
read-only drift detector that surfaces those flips without touching
anything:

```sh
# Audit one or a few repos:
./bin/audit.sh thrillmade/logmind thrillmade/clud-bug

# Audit every non-archived repo under an org:
./bin/audit.sh --all thrillmade

# Quieter: only print rows that drifted, hide ✓ matches
./bin/audit.sh --all thrillmade --quiet

# CI-gate mode: exit 1 when ANY drift detected
./bin/audit.sh --all thrillmade --strict
```

Each repo's seven canonical settings (the same ones `apply.sh`
PATCHes) are checked against the expected values. Output: one ✓ or ✗
per setting per repo, with a final summary.

**Drift is INFORMATIONAL by default** — the audit always exits 0,
because repos may legitimately diverge (e.g. a docs repo with
auto-merge disabled during active editing, or a repo running a
different merge policy on purpose). The script surfaces divergence;
the human decides whether each instance is intentional or stale.

Use `--strict` to flip the policy when you do want an enforcement
gate (e.g. a scheduled CI workflow that fails on any drift).

**Remediation when drift is unintentional**: re-run `apply.sh <repo>
<variant>` to reset everything to the canonical values. `apply.sh` is
idempotent, so a re-apply is safe.

## Upgrading logmind

After bumping the logmind CLI, re-run `logmind init` to refresh the shipped
workflow templates:

```sh
pipx install --force logmind     # or: pip install --upgrade logmind
logmind init                     # idempotent refresh in v0.2.1+ — rewrites
                                 # workflow templates in place, leaves
                                 # docs/ and .logmind/ untouched
```

For clud-bug, see [thrillmade/clud-bug](https://github.com/thrillmade/clud-bug)'s
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
