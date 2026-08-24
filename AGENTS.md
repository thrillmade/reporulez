# AGENTS.md

This is the canonical instruction file for AI coding agents working in this
repository. Tools that understand `AGENTS.md` (Cursor, Codex, Windsurf,
Claude Code, Cline, Continue, Aider, ...) read this file directly. Per-tool
files like `CLAUDE.md` or `.cursorrules` are stubs that point here so the
guidance lives in one place.

<!-- logmind-start -->
<!-- logmind-block-version: v7-pointer -->
## Decision logging — `logmind log` is the commit primitive

**`logmind log` replaces `git add` + `git commit` + `git push` for any change that carries a decision** — do not run those git commands directly.

```bash
logmind log "summary" -r "why" -a "alternative" -i "implication"
```

This project uses [logmind](https://logmind.dev). What counts as a decision, branch routing, `--stage scoped` for unrelated WIP, `logmind doctor`, and the required-reading list ([`docs/timeline.md`](docs/timeline.md), [`docs/decisions.md`](docs/decisions.md), [`docs/file-structure.md`](docs/file-structure.md), `docs/decisions-branches/<branch>.md`) all live in the **`logmind` agent skill** at https://github.com/thrillmade/agent-skills/tree/main/skills/logmind.
<!-- logmind-end -->

## Project Overview

`reporulez` ships opinionated GitHub **repository rulesets** for AI-driven
development. The installer (`bin/apply.sh`) tunes target-repo settings
(auto-merge, squash-only, delete-on-merge) and POSTs a ruleset that requires
PRs, blocks force pushes and default-branch deletions, enforces thread
resolution, and layers on a review gate depending on variant. Four variants
— `baseline` (structural floor only), `clud-bug` (adds the `clud-bug-review`
required status check), `skdd` (adds the full clud-bug + logmind toolchain
check set), and `public-guard` (adds a required human code-owner approval)
— plus a `--human-review` flag. `bin/apply-org.sh` applies a fifth,
org-level-only variant, `org-baseline`, across an entire org in one call.
See `README.md` for the full design.

This repo itself uses the `baseline` variant (the direct rename target of the
old `external` variant this line used to name — see #63): clud-bug is the AI
reviewer (now delivered via the `clud-bug[bot]` GitHub App installed at the
thrillmade org — no per-repo workflow, so no required-check rule is needed
here), logmind enforces decision logging, and CI gates every PR on
`check-decisions` and `check-links` (all currently passing).

## Development Commands

```bash
# Validate ruleset JSON
jq . rulesets/*.json

# Syntax-check the installer
bash -n bin/apply.sh

# Apply rulesets to a target repo (dogfood / end-to-end test)
./bin/apply.sh <owner/repo> [baseline|clud-bug|skdd|public-guard] [--human-review]

# Apply the org-level floor across an entire org
./bin/apply-org.sh <org> [org-baseline]

# Validate a ruleset's required fields before it is ever applied
./bin/validate-ruleset.sh rulesets/skdd.json

# The validator's own regression guard — run it before you push
bash tests/test-validate-ruleset.sh
```

`tests/test-validate-ruleset.sh` covers `bin/validate-ruleset.sh` and nothing
else. The installers are still validated end-to-end by hand: apply against a
throwaway repo and inspect via the GitHub UI / API. No count or duration is
quoted here on purpose — run it and read the output.

## The `dev` branch

reporulez follows the same convention as every other thrillmade repo: **work
lands on `dev` first and reaches `main` in batches.** This is the
organisation's rule, not this repo's, and adopting it here is not a local
decision — the absence of a `dev` branch before 2026-08-24 was an omission,
not a deliberate single-branch design.

**Branch from `dev`, and open the pull request into `dev`.** The forge default
base is `main`, so set it by hand.

**Into `dev`: an independent adversarial review.** A different agent than the
one that wrote the change — a fresh context window on the same agent is not a
different agent.

**Into `main`: a person.** An agent reports the batch ready and hands off.

## Contributor Setup

After cloning, contributors should:

1. **Install logmind** locally (CLI tool used to log decisions):
   ```bash
   brew install thrillmade/tap/logmind   # macOS + Linux; or: curl -fsSL https://logmind.dev/install.sh | bash
   logmind install-hook   # .git/hooks/pre-commit
   ```
   The same enforcement runs on every PR via `.github/workflows/check-decisions.yml`
   (shipped by logmind itself), so skipping the local hook only delays the failure —
   it still blocks merge.

2. **When CI flags `docs/timeline.md` as stale,** regenerate it locally and push:
   ```bash
   logmind timeline --write docs/timeline.md
   git add docs/timeline.md
   git commit -m "regen: docs/timeline.md"
   git push
   ```
   `docs/timeline.md` is a derived file — auto-regenerated chronological overview
   across all branches. The `check-derived-docs` workflow (`.github/workflows/regen-timeline.yml`)
   fails fast when it's stale. Running `logmind timeline --write` locally before
   pushing avoids the red CI run.

<!-- clud-bug-start -->
<!-- clud-bug-block-version: v2 -->
## clud-bug — Claude PR review

This repo uses [clud-bug](https://cludbug.dev) for automatic PR reviews.
Full collaboration rules — fix-push flow, skill structure, comment format,
strict-mode mechanics, workflow-edit constraint — live in the bundled
[`clud-bug-collaboration` skill](.claude/skills/clud-bug-collaboration/SKILL.md).
Read that skill before pushing fixes addressing prior review threads.

Strict mode is **on** in this repo (workflow check fails on critical findings). Toggle via `.claude/skills/.clud-bug.json`
(read from PR **base ref**, so PRs can't disable strict-mode on themselves).

For agent invocations of the `clud-bug` CLI, prefer `CLUD_BUG_QUIET=1`
(or pass `--quiet`) — suppresses progress chatter and emits a single
`ok <key-value>` summary line per command.

_Installed at clud-bug v0.7.0-rc.20._
<!-- clud-bug-end -->
