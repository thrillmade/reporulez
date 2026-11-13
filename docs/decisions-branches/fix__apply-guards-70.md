← back to [docs/timeline.md](../timeline.md)

## 2026-11-13 13:45 - bin/apply.sh is a dry run by default and shares one comparison with apply-org.sh (#70)

**Reasoning:** apply.sh changed a repository's settings, wrote .github/dependabot.yml into it and replaced its ruleset with the checked-in preset, with no comparison. The live per-repository rulesets were extended by hand and carry more bypass actors than the presets, so a plain re-run would have stripped them. The organisation path already had a comparison that labels every difference as tightens, weakens or removes bypass and refuses what it cannot prove safe. That comparison now lives in bin/ruleset-compare.sh and both scripts source it, so there is one implementation to review and test.

**Alternatives considered:** Copy the comparison into apply.sh. Rejected: two copies drift, and the second would go unreviewed., Update the presets to match live and keep apply.sh as a blind replace. Rejected: the live copies disagree with each other, all four presets share one ruleset name so a live copy cannot be attributed to a preset, and a preset that falls behind again would strip actors again.

**Implications:**
- Nothing is written without --apply: not the repository settings, not .github/dependabot.yml, not the ruleset. Every read and every refusal happens before the first write.
- With --apply alone only a provable tightening is written. A weakening needs --allow-weakening; removing or narrowing a live bypass actor needs --allow-bypass-removal. An unusable live read is exit 2 with no write.
- A write that itself fails stops the run and names what was already written. That is the one way a run can still end half-applied.
- No preset changed. Making the presets follow live needs a decision first: a distinct ruleset name per preset, or a marker in the ruleset.
- The dependabot template apply.sh writes carries no target-branch. Whether it should is a separate change.
- Known limit, as on the organisation path: there is no precondition between the live read and the write.

---

