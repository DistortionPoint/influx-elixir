# CHANGELOG Release Headings

**Date**: 2026-09-24
**Scope**: `CHANGELOG.md`, `.github/workflows/ci.yml` publish job, `test/influx_elixir/changelog_test.exs`
**Issue**: #22

---

## Problem

Issue #22 reported that the published 0.1.30 package's `CHANGELOG.md` had
no heading after `[0.1.21]`. Verified, and one release worse by the time
it was read: 0.1.22 through 0.1.31 (ten releases, tags `v0.1.22` …
`v0.1.31`) were all published with their 71 entries under `[Unreleased]`.

Cause: the publish job increments `@version`, publishes to Hex, commits
`mix.exs`, tags and creates a GitHub release. It never touches
`CHANGELOG.md`. The `[0.1.20]` and `[0.1.21]` headings were added by hand
after the fact (`git log -S'## [0.1.21]'`), and that manual step stopped.

## Decision

**Backfill.** For each tag from `v0.1.21` to `v0.1.31`, read the
`[Unreleased]` block of `CHANGELOG.md` at the tag. Each current entry
belongs to the first release whose block contains an entry with the same
first line: that is the release that shipped it. All 71 entries were
placed (none unmatched, none already in 0.1.21) and the rewritten file
has the same entry text, compared line by line. Dates are the release
commits' dates.

| Release | Entries |
|---|---|
| 0.1.22 | 27 |
| 0.1.23 | 6 |
| 0.1.24 | 4 |
| 0.1.25 | 2 |
| 0.1.26 | 8 |
| 0.1.27 | 2 |
| 0.1.28 | 1 |
| 0.1.29 | 1 |
| 0.1.30 | 14 |
| 0.1.31 | 6 |

**Prevention.** A publish-job step after the version bump inserts
`## [x.y.z] - YYYY-MM-DD` under `## [Unreleased]` with `awk`, fails the
release if the heading is not in the file, and runs before
`mix hex.publish` so the package carries it; the release commit adds
`CHANGELOG.md`. `test/influx_elixir/changelog_test.exs` fails CI when the
version in `mix.exs` has no dated heading and when headings are not
`[Unreleased]` followed by unique versions in descending order. Against
the pre-fix file the version check fails, as it should.

A release with no entries gets an empty heading; that is accurate.

## Files Modified

| File | Change |
|------|--------|
| `CHANGELOG.md` | headings for 0.1.22 … 0.1.31 |
| `.github/workflows/ci.yml` | "Date the CHANGELOG release" step; `CHANGELOG.md` in the release commit |
| `test/influx_elixir/changelog_test.exs` | New |

## Verification

```bash
mix test test/influx_elixir/changelog_test.exs
grep -n '^## \[' CHANGELOG.md
# the step, run locally against a copy:
awk -v heading="## [0.1.32] - 2026-09-25" '{ print } $0 == "## [Unreleased]" && !done { print ""; print heading; done = 1 }' CHANGELOG.md | sed -n 8,12p
```
