# The org branch policy

Source of truth: [reporulez#71](https://github.com/thrillmade/reporulez/issues/71). This
document is what the presets in `rulesets/org-*.json` and `bin/apply-org.sh` /
`bin/ensure-dev-branch.sh` implement — read it before changing any of them, and update it in
the same PR if the policy itself changes. The ruling is the owner's; the mechanism is this repo's.

## The ruling (verbatim from reporulez#71)

1. **`main` is the default branch and production, on every repo.** Protected by
   `org-baseline` + `org-default-protection` (target `~DEFAULT_BRANCH` and `refs/heads/main`):
   linear history, squash-only, an approval floor, a human merges. **Never flip the default
   branch to `dev`** — see [Why the default branch never flips](#why-the-default-branch-never-flips).
2. **`dev` is the staging/integration branch, on every repo.** Protected by `org-staging`
   (`refs/heads/dev`): no approval floor, agents may merge when green after review;
   auto-merge allowed. CI is required on `dev` by its own ruleset, `CI must pass`, not by
   `org-staging`.
3. **Everything targets `dev`** — humans, agents, bots, dependabot. `dev → main` is a single
   squash promotion PR with its own review, merged by a human, only when a batch is done or
   something on `main` is actively wrong.
4. **Sync `main → dev` immediately after every promotion.** Squash promotions break ancestry;
   synced at once the merge is trivial, left for weeks it is a conflict lane
   (thrillmade/clud-bug#328: 16 files after 3 weeks).
5. **Exceptions that must target `main`** (because GitHub reads them only from the default
   branch): `.github/dependabot.yml`, workflows that run on a schedule or on `main` events,
   release PRs.
6. **Issue closing:** `Closes #N` only fires on the default branch, so a fix merged to `dev` is
   closed by hand with the PR + SHA and "reaches main at the next promotion" — until an
   org-wide workflow does it (tracked: reporulez#71 ask C).

## Why the default branch never flips

The production rulesets (`org-baseline`, `org-default-protection`) key their `ref_name`
condition on `~DEFAULT_BRANCH`. That token is resolved by GitHub at evaluation time against
whatever the repo's *current* default branch is — it is not a fixed pointer to `main`.

If a repo's default branch is ever set to `dev` — by hand, by a migration script, by a tool
that assumes "default" means "where day-to-day work happens" — `~DEFAULT_BRANCH` silently
re-resolves. Two things break at once, one loud and one silent:

- **Loud:** `org-default-protection` now ALSO applies to `dev`, stacking its 1-approval /
  linear-history / squash-only rules on top of `org-staging`'s 0-approval rules. A merge to
  `dev` now needs an approving review, unless the merging actor holds an `always` bypass on
  `org-default-protection` (see [Who can get past the rules](#who-can-get-past-the-rules)).
  This is usually how the misconfiguration gets noticed.
- **Silent, if `org-default-protection` targeted `~DEFAULT_BRANCH` alone:** `main` would lose
  its `~DEFAULT_BRANCH`-keyed protection the moment it stopped being default. Nobody would
  notice until an unreviewed push landed in production.

`org-default-protection`'s `ref_name.include` is `["~DEFAULT_BRANCH", "refs/heads/main"]` —
**both**, not `~DEFAULT_BRANCH` alone — specifically so the silent failure can't happen.
`main` stays protected no matter what the default branch is set to. This converts an
unrecoverable silent gap into a recoverable loud one: dev getting over-protected is annoying
and immediately visible; main losing protection is neither.

**This is not hypothetical.** The reporulez#71 org-wide audit (2026-09-15) found
one private repository with its default branch already set to `dev` — `dev` there was
carrying `org-default-protection`'s full production ruleset (1 approval, squash-only, linear
history) in addition to `org-staging`, exactly the "loud" failure described above. `main` on
that repo was unaffected, because of the explicit `refs/heads/main` entry.

**No ruleset, and no script in this repo, fixes a flipped default branch.** A repository's
default branch is a repo *setting* (`PATCH /repos/{owner}/{repo}` `default_branch`), not
something any ruleset condition can set. `bin/ensure-dev-branch.sh` detects and warns on this
condition (`default_branch != main`) on every repo it checks, but deliberately does not
"fix" it by flipping the setting back — that is a human decision with real blast radius
(every open PR's base, every clone's checkout, every script that assumes "default" means
"main" downstream of this repo), consistent with reporulez#71's own instruction that this is
measurement plus a human call, never an automated live edit. See the tracking issue on the
affected repo for the specific case found during the 2026-09-15 audit.

## What "org-wide" means in practice

The org runs five **organization-level** rulesets, covering every repo in the org including
ones created later:

| Ruleset | Targets | What it does |
|---|---|---|
| `org-baseline` | `~DEFAULT_BRANCH`, `refs/heads/main` | PR required, force-push and deletion blocked. |
| `org-default-protection` | `~DEFAULT_BRANCH`, `refs/heads/main` | Production: 1 approval, code-owner review, thread resolution, stale reviews dismissed, squash-only, linear history, force-push and deletion blocked. |
| `org-staging` | `refs/heads/dev` | PR required with no approval floor, deletion blocked. |
| `CI must pass` | `~DEFAULT_BRANCH`, `refs/heads/dev` | The `ci` status check must pass. |
| `no-delete-dev-main` | `refs/heads/dev`, `refs/heads/main` | Deletion blocked, with no bypass. |

All five have presets under `rulesets/` (`org-baseline.json`,
`org-default-protection.json`, `org-staging.json`, `org-ci-must-pass.json`,
`org-no-delete-dev-main.json`), captured from live. One part could not be checked from a
repository-level read: each org ruleset's repository condition. The presets say
`repository_name: ~ALL`; the first dry run by an org owner shows whether live says the same.
`no-delete-dev-main` carries no bypass actor, which `bin/validate-ruleset.sh` accepts only
because its one rule is `deletion` — a rule that blocks no commit, push or merge. The
exemption holds only for that well-formed shape: `rules` a non-empty list whose every entry has
`type` exactly `deletion`.

`bin/apply-org.sh <org> <variant>` is a **dry run by default**: it prints the difference
between a preset and the live ruleset of that name, labels each difference *tightens*,
*weakens* or *removes bypass*, and writes nothing. With `--apply` alone it writes only a
difference that is all *tightens*, or creates a ruleset when no live ruleset is named like it.
A *weakens* — anything it cannot show is tighter, including any field it has no rule for and
any key present on one side but absent or of another JSON type on the other — needs
`--allow-weakening`. Removing a live bypass actor or narrowing its mode needs
`--allow-bypass-removal`, because it can lock out automation that relies on the bypass. Each
flag permits only its own kind. It also refuses two live rulesets of one name, a live name that
matches only by ASCII case, spaces, hyphens or underscores (look-alike characters from other
scripts are not detected), and a live read that failed or returned nothing usable. Exit codes:
`0` no difference or applied, `1` a difference exists (dry run), `2` refused or failed.
It needs the `admin:org` scope and org-owner membership; see
[Org-level rulesets](../README.md#org-level-rulesets) in the README for the full list and the
commands.

### Who can get past the rules

Each ruleset's bypass list is in its preset. Two bypass modes are in use:

- **`always`** — the actor can push or merge past the rule directly. `org-baseline` and
  `org-default-protection` give this to org owners, the repository write and admin roles,
  and one GitHub App; `CI must pass` gives it to org owners.
- **`pull_request`** — the actor can merge a pull request past the rule's requirements, but
  cannot push past it. `org-staging` gives this to the same four actors.

So a merge to `main` does not always need a human approval: an actor with an `always` bypass
on the production rulesets can merge without one.

### The `dev` branch itself

The rulesets do **not** require a repo to have a `dev` branch — `org-staging` targets the
literal ref `refs/heads/dev`, and a ruleset targeting a ref that doesn't exist yet on a given
repo has nothing to protect there until the branch is created. `bin/ensure-dev-branch.sh`
creates the missing `dev` branch (from the current default branch's HEAD, additive only, never
touching an existing `dev`). It is also a **dry run by default** and creates only with
`--apply`. It skips archived repos and forks (unless `--include-forks`), treats only a `404` on
`branches/dev` as missing, and exits non-zero when any repo failed or could not be read.

## What's still manual

- **Ask B (reporulez#71):** a check that fails when a repo's `.github/dependabot.yml` lacks
  `target-branch: "dev"` on every `updates` entry. Not built yet.
- **Ask C:** a reusable "close linked issues when a PR merges into `dev`" workflow, so ruling 6
  stops being manual. Not built yet.
- **Bot PR bases outside this repo's control** (ask E): a bot that opens PRs against a fixed
  base branch (e.g. a GitHub Action hardcoding `base: main`) is a setting in *that* repo's own
  workflow file, not a ruleset — reporulez can't reach it. File an issue on the affected repo
  asking for the base to change to `dev`, same as any other exception to ruling 3.
