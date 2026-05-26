## 2026-05-26 17:43 - Default --bypass-admin: ON for clud-bug-logmind variant (1H)

**Reasoning:** The clud-bug-logmind variant self-mod use case (clud-bugs claude-code-action 401s on PRs editing its own workflow files) practically always needs the Repository admin bypass. Without it every routine clud-bug self-mod ceremony deadlocks against the required clud-bug-review check. Opt-in flag (added in PR #11) meant every fresh install needed the same manual setup — verified empirically on clud-bug PR #58 era + every subsequent self-mod until PR #11 shipped the --bypass-admin flag. v0.5.16 of clud-bug + the polish round (clud-bug PRs #74, #75) hardened the surrounding stack; flipping this default closes out 1H from the v0.6 polish round. New --no-bypass-admin flag added for explicit opt-out (force OFF even for clud-bug-logmind).

**Alternatives considered:** Apply --bypass-admin to ALL variants by default. Rejected: copilot and external do not have a built-in self-mod ceremony so the bypass adds risk without value. Per-variant default keeps the principle of least privilege for variants that do not need it.

**Implications:**
- Re-applying clud-bug-logmind to a repo without prior bypass actors now ADDS Repository admin — additive, matches what users were almost certainly going to add manually. Existing repos with explicit --bypass-admin in their command see no change. Repos with explicit --no-bypass-admin also see no change. usage() sed range bumped 2,29 -> 2,35 to capture the expanded header docs. README usage example for clud-bug-logmind no longer shows --bypass-admin (its the default).

---
