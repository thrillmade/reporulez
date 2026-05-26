## 2026-05-26 17:43 - Default --bypass-admin: ON for clud-bug-logmind variant (1H)

**Reasoning:** The clud-bug-logmind variant self-mod use case (clud-bugs claude-code-action 401s on PRs editing its own workflow files) practically always needs the Repository admin bypass. Without it every routine clud-bug self-mod ceremony deadlocks against the required clud-bug-review check. Opt-in flag (added in PR #11) meant every fresh install needed the same manual setup — verified empirically on clud-bug PR #58 era + every subsequent self-mod until PR #11 shipped the --bypass-admin flag. v0.5.16 of clud-bug + the polish round (clud-bug PRs #74, #75) hardened the surrounding stack; flipping this default closes out 1H from the v0.6 polish round. New --no-bypass-admin flag added for explicit opt-out (force OFF even for clud-bug-logmind).

**Alternatives considered:** Apply --bypass-admin to ALL variants by default. Rejected: copilot and external do not have a built-in self-mod ceremony so the bypass adds risk without value. Per-variant default keeps the principle of least privilege for variants that do not need it.

**Implications:**
- Re-applying clud-bug-logmind to a repo without prior bypass actors now ADDS Repository admin — additive, matches what users were almost certainly going to add manually. Existing repos with explicit --bypass-admin in their command see no change. Repos with explicit --no-bypass-admin also see no change. usage() sed range bumped 2,29 -> 2,35 to capture the expanded header docs. README usage example for clud-bug-logmind no longer shows --bypass-admin (its the default).

---
## 2026-05-26 17:49 - Address PR #13 bot feedback: reword post-install bypass message for --no-bypass-admin case

**Reasoning:** clud-bug-review on PR #13 flagged a non-blocking wording issue: the post-install message at apply.sh:212-222 said "Consider re-running with --bypass-admin" whenever BYPASS_ADMIN != "true" under clud-bug-logmind. With the new default flipped to ON, that branch now only fires when the user EXPLICITLY passed --no-bypass-admin — telling them to "re-run with --bypass-admin" contradicts their stated opt-out intent. Reworded to acknowledge the opt-out, explain the consequence (self-mod deadlocks), and offer the re-run as a fallback "if you change your mind."

**Alternatives considered:** Suppress the message entirely when --no-bypass-admin was passed. Rejected: the consequence (self-mod PR deadlocks) is important to surface so the user knows what they opted into.

**Implications:**
- Closes the bot loose end; PR #13 becomes truly clean ship.

---
