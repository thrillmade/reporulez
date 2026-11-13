# reporulez

Drop-in GitHub repository rulesets tuned for AI-driven development.

> Ship the **org-wide `main`=production / `dev`=staging policy** (reporulez#71)? See
> [docs/branch-policy.md](docs/branch-policy.md) for the ruling and
> [Org-level rulesets](#org-level-rulesets) below for the org rulesets and
> `bin/ensure-dev-branch.sh` that apply it.

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

`apply.sh` is a **dry run by default**: without `--apply` it prints what it would change on
`owner/repo` and writes nothing (see [`apply.sh`: dry run by default](#applysh-dry-run-by-default)).
Read the output, then add `--apply`.

```sh
# Dry run (the default): what would the baseline change? Writes nothing.
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo

# The structural baseline (PR required, no force-push/deletion, linear, squash-only):
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo --apply

# clud-bug review gate (requires the clud-bug-review status check):
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo clud-bug --apply

# Public repo with outside contributors — require a HUMAN code-owner approval:
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo public-guard --apply

# Full clud-bug + logmind stack (canonical 4 contexts ship in the variant),
# plus your project's pytest matrix as extra required checks:
curl -fsSL https://raw.githubusercontent.com/thrillmade/reporulez/main/bin/apply.sh \
  | bash -s -- owner/repo skdd --apply \
      --extra-check 'pytest (ubuntu-latest / py3.10)' \
      --extra-check 'pytest (ubuntu-latest / py3.12)'
```

`--extra-check 'CONTEXT NAME'` is repeatable and appends project-specific status
check contexts to the variant's `required_status_checks` list at apply time. Lets
a single command match a project's actual CI without forking the variant JSON.
Only works against variants that ship `required_status_checks`
(`skdd`, `clud-bug`); errors cleanly on `baseline`/`public-guard` since they deliberately
omit that rule.

Every variant above ships `bypass_actors` pre-populated with the **Repository
admin** role — unconditionally, not just for `skdd`. `--bypass-admin` is an
idempotent no-op against that default; `--no-bypass-admin` strips it, and
doing so will make `apply.sh`'s own pre-apply validation refuse the run (see
[Admin bypass flag](#admin-bypass-flag) below for why, and what to do instead).

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

**Every variant ships this bypass by default now** — `baseline`, `clud-bug`,
`public-guard`, and `skdd` alike. That used to be true only for `skdd`, on the
reasoning that the other three "don't have a self-mod ceremony built in." That
reasoning was backwards: [protocol SPEC section 6.6](https://github.com/thrillmade/protocol)
requires the admin bypass **unconditionally** — "the ruleset MUST carry a bypass
held by repository administrators... a change to a gate's own workflow cannot
pass the gate it changes, and an incident fix cannot wait for one." A ruleset
with *no* self-mod ceremony needs the bypass *more*, not less, because there is
no other legal path past a gate that is blocking its own fix. `rulesets/*.json`
now bake the bypass in directly (not just at apply time), so a bare `apply.sh
owner/repo --apply` with no other flags — the Quickstart default — ships a conformant
ruleset, and so does pointing `bin/validate-ruleset.sh` straight at any of
`rulesets/*.json`.

- `--bypass-admin` is therefore an **idempotent no-op** against the shipped
  default (it dedupes rather than duplicating). Still useful against a forked
  or hand-edited ruleset that doesn't carry the bypass yet.
- `--no-bypass-admin` **strips it explicitly**. Doing so on any of these
  variants leaves `bypass_actors` with no qualifying admin bypass at all, so
  `apply.sh`'s own pre-apply `validate-ruleset.sh` call refuses the run —
  admin-bypass-required is unconditional, so there is no flag combination that
  gets you a conformant ruleset without it. Pass `--no-bypass-admin` only if
  you plan to supply a different qualifying bypass yourself (e.g. an
  `OrganizationAdmin` entry) before applying.

**Why it matters for clud-bug specifically:** `clud-bug`'s reviewer action
(`anthropics/claude-code-action`) deliberately refuses (HTTP 401) to review pull
requests that modify its own workflow files under `.github/workflows/clud-bug-*.yml`.
This is a self-mod guard — without it, a malicious PR could rewrite the reviewer
to rubber-stamp itself. The cost is that *legitimate* self-mod PRs (e.g. routine
`npx clud-bug upgrade` version bumps) also fail the required `clud-bug-review`
check and deadlock against `required_status_checks`. This is the sharpest example
of SPEC 6.6's general point, not a special case of it — `skdd` and `clud-bug`
just make the deadlock visible sooner because they ship `required_status_checks`.

Three ways out of a deadlocked self-mod PR:
1. **The admin bypass (on by default on every variant):** a repo admin can merge
   the stuck PR via "Bypass branch protections" without touching the ruleset.
2. **Hand-PATCH `bypass_actors` mid-merge** via `gh api --method PUT repos/$REPO/rulesets/$ID`
   — works once, but every fresh install needs the same manual setup.
3. **Toggle `enforcement: disabled` globally**, merge, re-enable — opens a real
   policy-gap window where the ruleset doesn't protect *anything*.

**Org repos:** the `RepositoryRole` admin role exists on both personal and org-managed
repos, so `--bypass-admin` works in both contexts. Whether it *also* covers an org owner who
holds no explicit Admin role on this specific repo is not something GitHub documents (see
[Validating a ruleset before it applies](#validating-a-ruleset-before-it-applies) for the same
open question, and why `bin/validate-ruleset.sh` assumes the narrower reading). If you want an
org owner covered unconditionally, add a *separate* org-administrator bypass entry
(`actor_type: OrganizationAdmin`, `actor_id: 1`) manually after install — including it by
default would 404 on personal repos. Doing so on a ruleset that also carries a `deletion` rule
(which every variant here does) trips `bypass-defeats-deletion-restriction`, but only as a
WARNING, not a refusal: deleting a branch requires write access, not admin, so the bypass
doesn't excuse anyone below admin-level — it just also excuses every org owner, unconditionally,
which is worth knowing, not worth blocking. See [Validating a ruleset before it applies]
(#validating-a-ruleset-before-it-applies) for the full reasoning.

### `apply.sh`: dry run by default

```sh
./bin/apply.sh owner/repo skdd --with-dependabot=python           # dry run: print each change, write nothing
./bin/apply.sh owner/repo skdd --with-dependabot=python --apply   # write what is needed
```

`apply.sh` makes three kinds of write, and a dry run (no `--apply`) makes none of them. It
reads the live repo settings, the live `.github/dependabot.yml` (with `--with-dependabot`)
and the live `reporulez-default` ruleset, then prints:

- **settings** — each of the seven managed keys whose live value differs from what `apply.sh`
  sets;
- **dependabot file** — whether it would be created or replaced (its content differs from the
  template), or already matches;
- **ruleset** — the same labelled differences as `apply-org.sh` (*tightens*, *weakens*,
  *removes bypass*, defined under [`bin/apply-org.sh`](#binapply-orgsh-dry-run-by-default)).
  Both scripts use one comparison, `bin/ruleset-compare.sh`.

**The checked-in presets carry one bypass actor** (Repository admin). A live ruleset that was
extended by hand carries more, so applying a preset to it removes the extras. With `--apply`
alone that is refused. A *weakens* needs `--allow-weakening`; removing a live bypass actor or
narrowing its mode needs `--allow-bypass-removal`; each flag permits only its own kind, and an
absent key, `null` or a different JSON type is never read as a value. Read the dry run, then
decide: there is no flag that makes a blind re-run safe.

**Order: every read and every refusal comes before the first write.** Every read comes first: settings, the dependabot file,
the ruleset list and the ruleset. Every refusal is decided from those reads before the first
write. A read that failed or returned nothing usable (an empty body, `null`, the wrong shape,
more than one JSON document, a different repository or ruleset than asked for), two live
rulesets of the name, a near-name, or a ruleset change that needs a flag you did not pass is
exit `2` with nothing written. Only then does it write: settings, the dependabot file, the
ruleset. A write that itself fails stops the run and names what was already written, so a failed write can leave earlier writes in place.
Exit codes: `0` no difference or applied, `1` a difference exists (dry run), `2` refused or
failed. A change made to the live ruleset between the read and the write is not detected.

The flags `--human-review`, `--bypass-admin`, `--no-bypass-admin`, `--extra-check` and
`--with-dependabot` keep working; a `--human-review` or `--extra-check` is a *tightens* on a
live ruleset that lacks it, and `--no-bypass-admin` is still refused by the validator.

## Org-level rulesets

Everything above is **repo-level** — one `apply.sh` run per repository. The org itself runs
**organization-level** rulesets, which apply to the repositories their repository condition
names, including ones created later. Five were active on 2026-11-12, read from one repository
with `gh api 'repos/thrillmade/reporulez/rulesets?includes_parents=true'` (the entries whose
`source_type` is `Organization`); which repositories each one covers was not read, because
that needs the `admin:org` scope. Each has a preset under `rulesets/` that `bin/apply-org.sh`
compares with, and can apply to, the live org:

| Ruleset (preset) | Targets | What it does |
|---|---|---|
| `org-baseline` (`org-baseline.json`) | `~DEFAULT_BRANCH`, `refs/heads/main` | PR required, force-push blocked, deletion blocked. Merge, squash and rebase allowed. |
| `org-default-protection` (`org-default-protection.json`) | `~DEFAULT_BRANCH`, `refs/heads/main` | Production: 1 approving review, code-owner review, thread resolution, stale reviews dismissed on push, squash-only, linear history, force-push and deletion blocked. |
| `org-staging` (`org-staging.json`) | `refs/heads/dev` | PR required with no approval floor, any merge method, deletion blocked. Force-push is not blocked. |
| `CI must pass` (`org-ci-must-pass.json`) | `~DEFAULT_BRANCH`, `refs/heads/dev` | A status check named exactly `ci` must pass. |
| `no-delete-dev-main` (`org-no-delete-dev-main.json`) | `refs/heads/dev`, `refs/heads/main` | Deletion blocked, with no bypass at all. |

`no-delete-dev-main` carries no bypass actor. `bin/validate-ruleset.sh` accepts that only
because its one rule is `deletion`, which blocks no commit, push or merge; see
`admin-bypass-required` under [Validating a ruleset before it
applies](#validating-a-ruleset-before-it-applies).

**Who can get past these rules.** The production-side rulesets (`org-baseline`,
`org-default-protection`) list org owners, the repository write and admin roles, and one
GitHub App as bypass actors in `always` mode: they can push or merge past the rule directly.
`org-staging` lists the same actors in `pull_request` mode: they can merge a pull request past
its requirements, but cannot push straight to `dev`. `CI must pass` lets org owners bypass it,
always. So not every merge to `main` needs a human approval: an actor on a bypass list can
merge without one. Each preset's `bypass_actors` is the exact list.

### `bin/apply-org.sh`: dry run by default

```sh
./bin/apply-org.sh your-org org-staging            # dry run: print the difference, write nothing
./bin/apply-org.sh your-org org-staging --apply    # replace (or create) the live ruleset
```

Variants: `org-baseline` (the default), `org-default-protection`, `org-staging`,
`org-ci-must-pass`, `org-no-delete-dev-main`. Without `--apply` the script makes no write
call: it reads the live org ruleset with the preset's name, normalises both sides the same way
and prints the difference, or `no difference`. Writing — a `PUT` to replace the live ruleset,
or a `POST` when none of that name exists — needs `--apply`.

Every difference is printed with its kind:

- **tightens** — enforcement raised (`disabled` < `evaluate` < `active`); a ref or repository
  `include` entry added, or an `exclude` entry removed; a rule of a known type added; a higher
  approval count; a `pull_request` review requirement switched on; a merge method removed; a
  required status check added; strict status checks switched on, or `do_not_enforce_on_create`
  switched off.
- **weakens** — everything else. That includes adding a bypass actor in any mode, widening a
  bypass mode (`pull_request` < `always` < `exempt`), and any field, condition, rule type,
  parameter or mode the script has no rule for: the check fails closed.
- **removes bypass** — a live bypass actor removed, or its mode narrowed. That tightens the
  rules, but can lock out automation that relies on the bypass.

A key present on one side and absent on the other, or present on both with a different JSON
type (`null` included), is a *weakens*: a missing value is never read as an empty list, `0`,
`false` or `{}`, so a preset that simply lacks `allowed_merge_methods` is never "removes every
merge method".

Two present values cannot exist on a real ruleset and are refused as an invalid preset before
anything is compared: an empty `allowed_merge_methods` (no way to merge at all), and a required
approval count that is not a whole number from 0 to 10.

`--apply` on its own writes only a difference that is all *tightens*, or creates a ruleset
when no live ruleset is named like it. A *weakens* needs `--allow-weakening`;
a *removes bypass* needs `--allow-bypass-removal`. The two flags are independent: each permits
only its own kind. `--apply` also refuses, naming the reason, when:

- more than one live ruleset has that name, or a live ruleset's name matches the preset's only
  once case, spaces, hyphens and underscores are ignored (it would otherwise create a
  near-duplicate beside it). The check folds ASCII case, spaces, hyphens and underscores; look-alike
  characters from other scripts are not detected;
- a live read failed or returned nothing usable — an empty body, `null`, the wrong shape, more
  than one JSON document, or a ruleset missing a field the comparison needs. A failed read is
  never treated as "nothing is live".

Exit codes: `0` no difference or applied, `1` a difference exists (dry run), `2` refused or
failed — including two variants on one command line, an unknown argument, and any unexpected
internal failure. The presets are captured from the live org rulesets, so a dry run against
the org today should print `no difference`. One part could not be checked from a
repository-level read: an org ruleset's repository condition. The presets say
`repository_name: ~ALL`; the first dry run by an org owner shows whether live says the same.

**It LAYERS with repo-level rulesets — it never overrides them.** GitHub evaluates *every*
ruleset that targets a branch, and a write must satisfy **all** of them. `apply-org.sh` does not
touch rulesets applied by `apply.sh`, and does not PATCH per-repo settings like auto-merge /
squash-only / delete-on-merge — use `apply.sh` per repo for those (dry run first).

**Requires the `admin:org` scope**, even for a dry run — reading org rulesets needs it:

```sh
gh auth refresh -h github.com -s admin:org
```

> **Why `OrganizationAdmin` is on every bypass list, given most of these rulesets carry a
> `deletion` rule:** `bin/validate-ruleset.sh`'s `bypass-defeats-deletion-restriction` check
> flags an `OrganizationAdmin` always-bypass on a deletion rule, but only as a WARNING.
> Deleting a branch requires only write access, not admin (see [Validating a ruleset before it
> applies](#validating-a-ruleset-before-it-applies)), so this bypass does not excuse anyone below
> admin-level. `OrganizationAdmin` is the one bypass GitHub documents as covering every org
> owner on every repo, present and future, which is what a ruleset that must hold on a repo
> nobody has configured yet needs.

### `bin/ensure-dev-branch.sh`: dry run by default

`org-staging` targets the literal ref `refs/heads/dev`, so it protects nothing on a repo that
has no `dev` branch. `bin/ensure-dev-branch.sh` closes that gap:

```sh
./bin/ensure-dev-branch.sh --all your-org            # dry run: report what would be created
./bin/ensure-dev-branch.sh --all your-org --apply    # create dev where it is missing
```

Without `--apply` nothing is written. A missing `dev` is a `404` on `branches/dev`; any other
failed read is reported as "could not read" and never treated as missing. Archived repos are
skipped, and forks unless `--include-forks`. With `--apply` it creates `dev` at the default
branch's current HEAD; it never changes a default branch, never touches an existing `dev`, and
never deletes. It prints five counts — created, already-present, would-create, skipped, failed —
and exits `2` when any repo failed or could not be read; `--strict` also exits `1` when a repo
still lacks `dev` or has a default branch other than `main`.

#### Why the org policy never flips the default branch

The production rulesets key on `~DEFAULT_BRANCH`. If a repo's default branch is ever flipped
to `dev` — by hand, by mistake, by a script that assumes "default branch" means "where work
happens" — `~DEFAULT_BRANCH` re-resolves to `dev`, and **every production rule
(`org-default-protection`'s approval / code-owner / linear-history / squash-only) now ALSO
applies to `dev`**, stacking on top of `org-staging`'s own rules. The practical break: a merge
to `dev` now needs an approving review unless the merging actor holds an always-bypass on
`org-default-protection`. Meanwhile `main` — no longer the default — would have silently lost
its `~DEFAULT_BRANCH`-keyed protection entirely, if the production rulesets targeted only
`~DEFAULT_BRANCH`. The explicit `refs/heads/main` entry in their `ref_name.include` is what
prevents that second, silent failure: `main` stays protected no matter what the default branch
is set to, so a flipped default fails loud instead of failing silent.

This is a real, observed failure mode, not a hypothetical: reporulez#71's org-wide audit found
one private repository with its default branch set to `dev`, `org-default-protection`
consequently double-protecting `dev` there, and no ruleset-level fix available — flipping a
repo's default branch is a repo *setting*, not a ruleset, and no ruleset can repair it. **The
fix is a human flipping the default branch back to `main`.** No script in this repo does that
automatically, and none should — see `docs/branch-policy.md` for the full policy and this
incident.

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

A second run is a comparison, not a blind replace: with no difference it writes nothing; otherwise it prints the differences (a dry run unless you pass `--apply`), writes only provable tightenings with `--apply` alone, and refuses a weakening or a bypass removal unless you pass `--allow-weakening` or `--allow-bypass-removal`. It replaces the ruleset by id, so it never creates a duplicate.

When `bin/ruleset-compare.sh` is not beside the script (the `curl | bash` path), `apply.sh` and `apply-org.sh` fetch it from the same base URL as the presets and the validator (`REPORULEZ_RAW_BASE`, default the `main` branch of this repository), and refuse with exit `2`, before any `gh` call, if the fetch fails, the file is empty, or the file does not define the library's entry point (an error page, for example). The check is the presence of that one function, not a signature or a hash: a file that defines it but is otherwise wrong is not detected. The fetched library is trusted exactly as far as the presets and the validator fetched from that base URL.

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

   Without `--apply` this prints whether the file would be created or replaced and
   writes nothing. With `--apply`, re-running with the same flag is a no-op when the
   file is already current; a different existing `.github/dependabot.yml` is replaced,
   and the dry run says so first. The file write is not one of the ruleset's
   *tightens / weakens / removes bypass* kinds and needs no extra flag.

   > **Known limitation, now narrower** (ecosystem switch on re-apply):
   > switching the `--with-dependabot=<eco>` value on a repo that already has
   > the ruleset applied will fail the contents PUT because the existing
   > ruleset's `pull_request` rule blocks direct default-branch writes. The
   > `--bypass-admin` flag does **not** help here — it only mutates the
   > in-memory ruleset JSON that step 3 applies; it does not patch the
   > existing ruleset that step 2's PUT runs against. The actual prerequisite
   > is that the target repo's *existing* ruleset already contains Repository
   > admin in `bypass_actors`. Since every variant now ships that bypass by
   > default (see [Admin bypass flag](#admin-bypass-flag)), this works out of
   > the box for `baseline`/`clud-bug`/`public-guard`/`skdd` alike, as long as
   > the repo's existing ruleset was applied with a version of `apply.sh`
   > from this change or later (or with an explicit `--bypass-admin`) and was
   > not applied with `--no-bypass-admin`. If the *existing* ruleset predates
   > this change (or was explicitly applied with `--no-bypass-admin`) and has
   > an empty `bypass_actors`, ecosystem-switching still requires either
   > temporarily editing the existing ruleset on GitHub (Settings → Rules →
   > Rulesets → `reporulez-default` → add Repository admin to `Bypass list`)
   > or temporarily deleting the existing ruleset before re-applying.
3. **Verify entitlement / app install:**
   - `clud-bug` variant: [clud-bug](https://github.com/thrillmade/clud-bug) must be installed —
     the `clud-bug-review` check comes from its workflow; without it, PRs block forever under strict mode.
   - `skdd` variant: **both** [clud-bug](https://github.com/thrillmade/clud-bug)
     **and** [logmind](https://logmind.dev) must be installed on the target repo
     (run `npx clud-bug init` and `logmind init --all-agents --install-hook`).
     The shipped `required_status_checks` rule pins four contexts that come from
     those tools' workflows; if either tool is missing, those checks will never
     report and every PR will block forever (`strict_required_status_checks_policy: true`).

## Validating a ruleset before it applies

Nothing checked a ruleset's *contents* before it was POST/PUT to a repository
or an entire org — only its JSON syntax. An invalid or incomplete ruleset
applied org-wide changes branch protection on every repository at once,
silently ([reporulez#68](https://github.com/thrillmade/reporulez/issues/68)).

`bin/validate-ruleset.sh` closes that gap. `apply.sh` and `apply-org.sh` run
it on the FINAL ruleset JSON — after every `--bypass-admin` / `--extra-check`
/ `--human-review` patch — right before the POST/PUT, and refuse to apply on
any violation, before either script has made a single mutating call.
`audit.sh --include-ruleset` runs it read-only against every already-applied
ruleset it fetches, so a hand-edit made after `apply.sh` ran (in the GitHub
UI, say) is caught too — not just what reporulez itself would have shipped.

It is also a standalone tool: point it at any ruleset JSON and it checks the
same fields, with no reporulez-specific assumptions.

```sh
./bin/validate-ruleset.sh rulesets/skdd.json
echo "$RULESET_JSON" | ./bin/validate-ruleset.sh -
gh api repos/owner/repo/rulesets/12345 | ./bin/validate-ruleset.sh -
```

Two severities. **ERROR** (`✗`) makes the ruleset invalid and blocks apply.sh
/ apply-org.sh. **WARNING** (`⚠`) prints but never blocks — it flags a
design choice worth reconsidering on a ruleset that already conforms to
every SPEC requirement this script checks.

What it checks:

- **`integration-id-pin`** (ERROR) — every `clud-bug-review` required check
  must pin `integration_id: 3944857` (the clud-bug[bot] App's own id). An
  unpinned check is forgeable by any token with `statuses:write`.
- **`admin-bypass-required`** (ERROR) — `bypass_actors` must carry a bypass
  a repository administrator can actually use (`RepositoryRole` `admin`
  id=5, or `OrganizationAdmin`), in `bypass_mode` `always` or
  `pull_request`. `pull_request` still lets the admin get past the rule
  through a pull request, so it is not a lock-out; any other mode does not
  count. A ruleset with no bypass at all blocks its own repair. One
  exception: a ruleset whose every rule is `deletion` needs no bypass, since
  forbidding a branch's deletion blocks no commit, push or merge. Any other
  rule alongside it, `non_fast_forward` included, and the check applies.
- **`bypass-defeats-deletion-restriction`** (WARNING) — a `deletion` rule
  whose `bypass_actors` grants an always-bypass to `OrganizationAdmin` is
  worth a second look, not a refusal. Deleting a branch requires only write
  access, not admin, so this bypass does **not** "protect nobody" — an
  earlier version of this check claimed exactly that, which GitHub's own
  docs refute (an admin-only bypass still restricts every real
  Write-/Maintain-role holder). What *is* true: `OrganizationAdmin` excuses
  every organization owner unconditionally — a population nobody
  administers per-repository, unlike `RepositoryRole` `admin` (id=5), which
  is scoped to whoever holds *this* repo's own Admin role. SPEC section 6.6
  requires every ruleset carry an admin bypass so a gate can't block the
  fix to its own workflow; restoring a deleted branch isn't editing a
  gate's workflow, so that rationale doesn't obviously require the
  org-wide reach specifically for a `deletion` rule. Written after a live
  incident: an org ruleset on `thrillmade/agent-skills` was `Active`,
  targeted `dev`, and had "Restrict deletions" checked, and `dev` was
  deleted anyway — via bypass entries this check still does *not* flag at
  any severity (an unrecognized `RepositoryRole` id, a `Team`, or an
  `Integration` entry, none provably admin-level; see the script's own header
  for that open gap). `RepositoryRole` `admin` alone (no
  `OrganizationAdmin`) is not flagged at all, not even as a warning — a
  stated assumption, not a citation (GitHub doesn't document whether
  ruleset bypass matching for `RepositoryRole` uses a user's assigned role
  or their effective permission, which for an org owner is always
  "admin"). See the script's own header comment for the full account, the
  citations, and what would falsify the `RepositoryRole` assumption.

Exit codes: `0` no ERROR-severity violation (any WARNING still prints), `1`
one or more ERROR-severity violations (printed, one per line — exit 1 never
comes without at least one), `2` usage/input error (bad path, unreadable
stdin, not valid JSON, or not exactly one JSON object) or any unexpected
failure — a ruleset this script could not read is never reported as passing.

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

Whether `required_status_checks` or `bypass_actors` CONTENT matches a
particular variant's expected value is intentionally not checked here —
too variant-specific to flag generically. It also runs
[`bin/validate-ruleset.sh`](bin/validate-ruleset.sh) (reporulez#68) read-only
against each active ruleset's live JSON, which checks field validity that
holds regardless of variant: every `clud-bug-review` required check is
pinned to the correct App id, an admin bypass exists at all, and a
`deletion` rule's own bypass list doesn't cover every admin-level actor
capable of performing the deletion it restricts. `apply.sh` and
`apply-org.sh` run the same script as a hard gate before every POST/PUT —
see [Validating a ruleset before it applies](#validating-a-ruleset-before-it-applies).

**Limitation**: `--all <owner>` uses `GET orgs/<owner>/repos`, which
404s on personal accounts. Works for any GitHub org. For personal
accounts, pass explicit positional `<user>/<repo>` arguments.

**A failed read is never "no drift".** A repo, ruleset listing or ruleset
detail the API would not return is reported as "could not audit", and the
run exits 2 whatever `--strict` says. So is a field validation without a
verdict: the validator's result counts only when it is exit 0, or exit 1
with at least one `✗ [<check>]` line.

Exit codes: `0` no drift, or drift without `--strict`; `1` drift with
`--strict`; `2` could not audit, or a usage error.

**Drift is INFORMATIONAL by default** — the audit exits 0 on drift,
because repos may legitimately diverge (e.g. a docs repo with
auto-merge disabled during active editing, or a repo running a
different merge policy on purpose). The script surfaces divergence;
the human decides whether each instance is intentional or stale.

Use `--strict` to flip the policy when you do want an enforcement
gate (e.g. a scheduled CI workflow that fails on any drift).

**Remediation when drift is unintentional**: dry-run `apply.sh <repo> <variant>`
first and read what it would change. It resets the settings to the canonical
values; for the ruleset it refuses, without the flags above, to remove or
weaken anything live carries. A plain re-run is not a blind reset: it is a
comparison.

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

- Org-level *variants* that mirror the repo-level `clud-bug`/`skdd`/`public-guard` opinions — the org presets cover the two-tier main/dev model and one required `ci` check (see [Org-level rulesets](#org-level-rulesets)); per-tool required checks at org level are not built
- Tag protection
- Push rulesets (file paths, file sizes, etc.)
- Required signed commits — high friction for AI agents without signing keys
- Environment / deployment protection rules

## License

MIT — see [LICENSE](LICENSE).
