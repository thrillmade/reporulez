# The org branch policy

Source of truth: [reporulez#71](https://github.com/thrillmade/reporulez/issues/71). This
document is what the presets in `rulesets/org-*.json` and `bin/apply-org.sh` /
`bin/ensure-dev-branch.sh` implement — read it before changing any of them, and update it in
the same PR if the policy itself changes. The ruling is the CEO's; the mechanism is this repo's.

## The ruling (verbatim from reporulez#71)

1. **`main` is the default branch and production, on every repo.** Protected by
   `org-baseline` + `org-default-protection` (target `~DEFAULT_BRANCH` and `refs/heads/main`):
   linear history, squash-only, an approval floor, a human merges. **Never flip the default
   branch to `dev`** — see [Why the default branch never flips](#why-the-default-branch-never-flips).
2. **`dev` is the staging/integration branch, on every repo.** Protected by `org-staging`
   (`refs/heads/dev`): CI required, no approval floor, agents may merge when green after
   review; auto-merge allowed.
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
  linear-history / squash-only rules on top of `org-staging`'s 0-approval rules. Agents can no
  longer auto-merge to `dev` — every merge there now needs a human approval. This is usually
  how the misconfiguration gets noticed.
- **Silent, if `org-default-protection` targeted `~DEFAULT_BRANCH` alone:** `main` would lose
  its `~DEFAULT_BRANCH`-keyed protection the moment it stopped being default. Nobody would
  notice until an unreviewed push landed in production.

`org-default-protection`'s `ref_name.include` is `["~DEFAULT_BRANCH", "refs/heads/main"]` —
**both**, not `~DEFAULT_BRANCH` alone — specifically so the silent failure can't happen.
`main` stays protected no matter what the default branch is set to. This converts an
unrecoverable silent gap into a recoverable loud one: dev getting over-protected is annoying
and immediately visible; main losing protection is neither.

**This is not hypothetical.** The reporulez#71 org-wide audit (2026-09-15) found
`thrillmade/arlyn-delivery` with its default branch already set to `dev` — `dev` there was
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

`org-baseline`, `org-default-protection`, and `org-staging` are **organization-level**
rulesets (`repository_name: ~ALL`) — applied once, via `bin/apply-org.sh <org> <variant>`,
covering every repo in the org including ones created after the ruleset was applied. They
require the `admin:org` scope and org-owner membership; see
[Org-level baseline](../README.md#org-level-baseline) in the README for the exact commands.

They do **not** require a repo to have a `dev` branch to be "applied" — `org-staging` targets
the literal ref `refs/heads/dev`, and a ruleset targeting a ref that doesn't exist yet on a
given repo simply has nothing to protect there until the branch is created. That's what
`bin/ensure-dev-branch.sh` is for: creating the missing `dev` branch (from the current default
branch's HEAD, additive only, never touching an existing `dev`) is the other half of "every
repo gets dev + org-staging" — the ruleset is already there org-wide; the branch is the
per-repo gap.

## What's still manual

- **Ask B (reporulez#71):** a check that fails when a repo's `.github/dependabot.yml` lacks
  `target-branch: "dev"` on every `updates` entry. Not built yet.
- **Ask C:** a reusable "close linked issues when a PR merges into `dev`" workflow, so ruling 6
  stops being manual. Not built yet.
- **Bot PR bases outside this repo's control** (ask E): a bot that opens PRs against a fixed
  base branch (e.g. a GitHub Action hardcoding `base: main`) is a setting in *that* repo's own
  workflow file, not a ruleset — reporulez can't reach it. File an issue on the affected repo
  asking for the base to change to `dev`, same as any other exception to ruling 3.
