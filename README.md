# reporulez

Drop-in GitHub repository rulesets tuned for AI-driven development.

The goal: let an AI agent branch → push → open a PR → wait for checks → merge, without
bypassing safety.

**What the ruleset alone enforces (always on):** PRs are required (no direct pushes to
the default branch), force pushes and default-branch deletions are blocked, linear history
required, squash-only merges, stale reviews dismissed on push, and
**any** review thread that gets created must be resolved before merge.

**What it does *not* enforce until you pick a variant:** that a review actually happens,
and that CI checks pass. The `baseline` variant is the structural floor only. The
`clud-bug` variant adds the `clud-bug-review` required status check. The `skdd` variant
adds the full thrillmade-toolchain check set (clud-bug + logmind). The `public-guard`
variant adds a required **human** code-owner approval for repos with outside contributors.
With `baseline` alone, the structural rules above are the only merge gates, and an empty
PR can be self-merged — layer a variant (or add a `required_status_checks` rule in the UI)
to gate on an actual review.

The `--human-review` flag layers on a required human approval if you want a person in the
loop as well.

## Quickstart

```sh
# Default: the structural baseline (PR required, no force-push/deletion, linear, squash-only).
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo

# clud-bug review gate (requires the clud-bug-review status check):
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo clud-bug

# Public repo with outside contributors — require a HUMAN code-owner approval:
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo public-guard

# Full clud-bug + logmind stack (canonical 4 contexts ship in the variant;
# Repository admin bypass for clud-bug self-mod PRs is ON BY DEFAULT for
# this variant), plus your project's pytest matrix as extra required checks:
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo skdd \
      --extra-check 'pytest (ubuntu-latest / py3.10)' \
      --extra-check 'pytest (ubuntu-latest / py3.12)'
```

`--extra-check 'CONTEXT NAME'` is repeatable and appends project-specific status
check contexts to the variant's `required_status_checks` list at apply time. Lets
a single command match a project's actual CI without forking the variant JSON.
Only works against variants that ship `required_status_checks`
(`skdd`, `clud-bug`); errors cleanly on `baseline`/`public-guard` since they deliberately
omit that rule.

`--bypass-admin` adds the **Repository admin** role to `bypass_actors`. **Default
ON for `skdd`** (the self-mod use case practically always needs it);
default OFF for `baseline`/`clud-bug`/`public-guard`. Override the per-variant default with
`--no-bypass-admin` to force off, or `--bypass-admin` to force on. See
[Admin bypass flag](#admin-bypass-flag) below for the rationale.

Requires the [`gh`](https://cli.github.com) CLI authenticated against the target repo, and `jq`.

## Variants

| Variant | Required status checks | Human approval | Use when |
|---|---|---|---|
| `baseline` (default) | none — structural floor only | no | Any repo, public or private — the secure minimum (PR required, no force-push/deletion, linear, squash-only, threads must resolve). Layer checks/approval as needed. *(`external` is a deprecated alias for `baseline`.)* |
| `clud-bug` | `clud-bug-review` (pinned to App `3944857`) — **strict** | no | Repos that run [**clud-bug**](https://github.com/thrillmade/clud-bug) reviews and want the review to gate merges (but not logmind). |
| `skdd` | `clud-bug-review` (pinned to App `3944857`), `check-derived-docs`, `check-decisions`, `check-links` — **strict** | no | The **canonical [SkDD](https://github.com/thrillmade/protocol)-toolchain ruleset** (protocol SPEC §7) — thrillmade-toolchain repos ([**clud-bug**](https://github.com/thrillmade/clud-bug) / [**logmind**](https://logmind.dev) / protocol). Both tools must be installed. *(Renamed from `clud-bug-logmind`, still a deprecated alias.)* |
| `public-guard` | none (advisory checks don't count) | **yes — code-owner, 1 approval** | **Public** repos with outside contributors: an outsider's fork PR needs a **human** maintainer/code-owner approval. A bot review check is advisory and never substitutes. Requires a CODEOWNERS file. |

> The old `copilot` variant (GitHub's built-in reviewer) has been removed. An `agentic` variant — a scoped bot bypass for bot-merged internal PRs — is planned.

> 💡 Pairs nicely with [**clud-bug**](https://github.com/thrillmade/clud-bug): a one-command (`npx clud-bug init`) install of a Claude PR-review GitHub Action that auto-discovers project-aware review skills from [skills.sh](https://skills.sh) and resolves its own review threads when issues are fixed — which is exactly what the `required_review_thread_resolution` gate in this ruleset is designed to lean on. This repo itself uses clud-bug; see PR #2 / #3 for live review examples.

All variants share the structural rules: PR required, force push and deletion blocked,
linear history, squash-only merges, dismiss stale reviews, all threads must resolve.
The `baseline` and `public-guard` variants **deliberately omit** a `required_status_checks` rule
(GitHub's API rejects an empty list, and we can't know your CI workflow names) — add the
rule with your contexts manually after install. The `clud-bug` and `skdd` variants ship that
rule with the canonical contexts.

> **Un-forgeability (`integration_id` pin):** the `clud-bug-review` entry in both the
> `clud-bug` and `skdd` variants pins `"integration_id": 3944857` — the `clud-bug[bot]`
> GitHub App's own ID — in addition to the `context` name. Without it, `context` alone is
> forgeable: **any** token with `statuses:write` (a PAT, a workflow's default
> `GITHUB_TOKEN`, another app) can post a check named `clud-bug-review` and satisfy the
> gate, and because GitHub resolves a required status check by taking the latest
> report for that context/name, a forged report posted after the real one wins. Per
> GitHub's docs, once `integration_id` is set, "if the status is set by any other
> person or integration, merging won't be allowed" — only App `3944857` can satisfy
> that entry. `check-derived-docs`/`check-decisions`/`check-links` in `skdd` are
> deliberately left context-only: they're plain Actions workflow checks (no dedicated
> App id to pin). See [`bin/verify-integration-id-pin.sh`](bin/verify-integration-id-pin.sh)
> for the forged-vs-genuine verification harness and manual run instructions.

> **Note on `skdd`'s strict mode:** `strict_required_status_checks_policy: true`
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
- `skdd` → **ON by default** (the variant's self-mod use case practically
  always needs the bypass — without it every routine clud-bug self-mod deadlocks).
  Use `--no-bypass-admin` to opt out.
- `baseline`, `clud-bug`, `public-guard` → **OFF by default** (no built-in self-mod use case).
  Pass `--bypass-admin` to opt in.

**Why it matters for clud-bug:** `clud-bug`'s reviewer action (`anthropics/claude-code-action`)
deliberately refuses (HTTP 401) to review pull requests that modify its own workflow
files under `.github/workflows/clud-bug-*.yml`. This is a self-mod guard — without it,
a malicious PR could rewrite the reviewer to rubber-stamp itself. The cost is that
*legitimate* self-mod PRs (e.g. routine `npx clud-bug upgrade` version bumps) also
fail the required `clud-bug-review` check and deadlock against `required_status_checks`.

Three ways out:
1. **`--bypass-admin` (default ON for `skdd`):** a repo admin can merge
   the stuck PR via "Bypass branch protections" without touching the ruleset.
2. **Hand-PATCH `bypass_actors` mid-merge** via `gh api --method PUT repos/$REPO/rulesets/$ID`
   — works once, but every fresh install needs the same manual setup.
3. **Toggle `enforcement: disabled` globally**, merge, re-enable — opens a real
   policy-gap window where the ruleset doesn't protect *anything*.

The flag works with any variant; we made it the default ONLY for `skdd`
because that's the variant whose required-checks list is opinionated about clud-bug
specifically, and clud-bug's self-mod ceremony is a normal recurring flow there.

**Org repos:** the `RepositoryRole` admin role exists on both personal and org-managed
repos, so `--bypass-admin` works in both contexts. Org owners on an org-managed repo
already inherit admin access to the repo and can use the same bypass. If you want a
*separate* org-administrator bypass entry (`actor_type: OrganizationAdmin`, `actor_id: 1`),
add it manually after install — including it by default would 404 on personal repos.

## Org-level baseline

Everything above is **repo-level** — one `apply.sh` run per repository. To protect a
whole organization in one command, apply the **org-level baseline** instead:

```sh
# Protect the default branch of EVERY repo in the org (incl. future repos):
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply-org.sh \
  | bash -s -- your-org
```

`bin/apply-org.sh <org> [org-baseline]` creates (or idempotently updates) a single
**org-level ruleset** named `org-baseline` via `POST`/`PUT orgs/<org>/rulesets`. It targets
the default branch of **every repository in the org via `repository_name: ~ALL`** — including
repos created *after* you run it, so new repos are protected the moment they exist without a
per-repo follow-up.

**What it enforces (org-wide floor):** PRs required (no direct default-branch pushes), force
pushes blocked, default-branch deletion blocked. An **OrganizationAdmin** bypass
(`bypass_mode: always`) is baked in so an org owner can unstick an edge case without disabling
the ruleset. It is deliberately minimal — it omits the linear-history / squash-only / thread-
resolution opinions the per-repo variants carry, so it never breaks a repo that legitimately
wants merge commits. Tighten individual repos on top of it with `bin/apply.sh`.

**It LAYERS with repo-level rulesets — it never overrides them.** GitHub evaluates *every*
ruleset that targets a branch, and a write must satisfy **all** of them. So the org floor and
any per-repo `reporulez-default` ruleset stack: the repo ruleset can only add restrictions on
top of the org floor, never relax it. Running `apply-org.sh` does not touch, replace, or
weaken rulesets applied by `apply.sh`. (Unlike `apply.sh`, `apply-org.sh` also does **not**
PATCH per-repo settings like auto-merge / squash-only / delete-on-merge — those are
repo-scoped with no org-level equivalent; keep using `apply.sh` per repo for them.)

**Requires the `admin:org` scope.** Reading and writing org rulesets needs it — without it
`gh api orgs/<org>/rulesets` returns `403`, and the script fails fast with:

```sh
gh auth refresh -h github.com -s admin:org
```

You must be an **owner** of the org. Like `apply.sh`, the script is idempotent — re-running
updates the existing `org-baseline` ruleset instead of creating a duplicate.

## What gets configured

The installer applies two things:

1. **A repository ruleset** (`reporulez-default`) targeting the default branch:
   - PR required, with last-push approval, thread resolution, stale-review dismissal
   - Block default-branch deletion
   - Block force pushes
   - Require linear history
   - Allowed merge methods: `squash`

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
   - **`baseline` / `public-guard` variants:** the ruleset ships without this rule
     (GitHub's API rejects an empty list, and we can't know your workflow names).
     Add it via Settings → Rules → Rulesets → `reporulez-default` → "Require
     status checks to pass".
   - **`skdd` variant: skip this step.** The ruleset already ships
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
   ./bin/apply.sh owner/repo skdd --with-dependabot=python
   ```

   Idempotent — re-running with the same flag is a no-op when the file is
   already current. Silently overwrites a different existing
   `.github/dependabot.yml` (consistent with how `--extra-check` and the
   other flags overwrite the ruleset on re-apply).

   > **Known limitation** (ecosystem switch on re-apply, baseline/clud-bug/
   > public-guard only): switching the `--with-dependabot=<eco>` value on a repo
   > that already has the ruleset applied will fail the contents PUT
   > because the existing ruleset's `pull_request` rule blocks direct
   > default-branch writes. The `--bypass-admin` flag does **not** help
   > here — it only mutates the in-memory ruleset JSON that step 3
   > applies; it does not patch the existing ruleset that step 2's
   > PUT runs against. The actual prerequisite is that the target
   > repo's *existing* ruleset already contains Repository admin in
   > `bypass_actors`. For `skdd` that's the variant
   > default, so first-time AND ecosystem-switching applies both
   > work. For `baseline`/`clud-bug`/`public-guard`, only first-apply and idempotent
   > re-apply work without manual intervention; ecosystem-switching
   > requires either temporarily editing the existing ruleset on
   > GitHub (Settings → Rules → Rulesets → `reporulez-default` →
   > add Repository admin to `Bypass list`) or temporarily deleting
   > the existing ruleset before re-applying.
3. **Verify entitlement / app install:**
   - `clud-bug` variant: [clud-bug](https://github.com/thrillmade/clud-bug) must be installed —
     the `clud-bug-review` check comes from its workflow; without it, PRs block forever under strict mode.
   - `skdd` variant: **both** [clud-bug](https://github.com/thrillmade/clud-bug)
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

# Also check ruleset coverage (org or repo-level rulesets, with the
# structural rules every reporulez variant ships):
./bin/audit.sh --all thrillmade --include-ruleset

# Quieter: only print rows that drifted, hide ✓ matches
./bin/audit.sh --all thrillmade --quiet

# CI-gate mode: exit 1 when ANY drift detected
./bin/audit.sh --all thrillmade --strict
```

Each repo's seven canonical settings (the same ones `apply.sh`
PATCHes) are checked against the expected values. Output: one ✓ or ✗
per setting per repo, with a final summary.

**With `--include-ruleset`**, the audit also queries each repo's
active rulesets (org-level inherited or repo-level) and verifies the
structural rule types every reporulez variant ships:

- `deletion` rule (no default-branch deletion)
- `non_fast_forward` rule (no force-push to default)
- `required_linear_history` rule (squash-only merge history)
- `pull_request` rule (PRs required for default-branch writes)

Variant-specific bits (`required_status_checks` contents,
`bypass_actors` content) are intentionally
not checked — too variant-specific to flag generically.

**Limitation**: `--all <owner>` uses `GET orgs/<owner>/repos`, which
404s on personal accounts. Works for any GitHub org. For personal
accounts, pass explicit positional `<user>/<repo>` arguments.

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
brew upgrade thrillmade/tap/logmind   # or: curl -fsSL https://logmind.dev/install.sh | bash
logmind init                          # idempotent refresh in v0.2.1+ — rewrites
                                      # workflow templates in place, leaves
                                      # docs/ and .logmind/ untouched
```

For clud-bug, see [thrillmade/clud-bug](https://github.com/thrillmade/clud-bug)'s
README for the current upgrade flow.

## Hand-import without the script

If you don't want to run a shell script (e.g. inside CI), import the JSON directly:

```sh
gh api --method POST repos/owner/repo/rulesets \
  --input rulesets/baseline.json
```

To require a human approval in this path, edit the JSON's `required_approving_review_count` to `1` first.

## Out of scope (for now)

- Org-level *variants* beyond `org-baseline` (the org floor exists — see [Org-level baseline](#org-level-baseline); richer org variants that mirror `clud-bug`/`skdd`/`public-guard` are not built yet)
- Tag protection
- Push rulesets (file paths, file sizes, etc.)
- Required signed commits — high friction for AI agents without signing keys
- Environment / deployment protection rules

## License

MIT — see [LICENSE](LICENSE).
