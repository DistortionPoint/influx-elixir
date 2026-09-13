# <Title: what changes and where>

**Date**: YYYY-MM-DD
**Scope**: <modules / files affected>
**Issue**: <GitHub #n, or "scheduled quality sweep">
**Supersedes**: <earlier design doc, if any>

---

## Problem

What is wrong or missing, with evidence. For a reported issue, say how the
report was verified against the code — and against a real InfluxDB where the
claim is about server behaviour (see the Docker one-liners in
`docs/design/README.md`). Never restate a report as fact without checking.

## Design

The change, and the alternatives rejected. Name the public functions,
types and options that change. Call out anything a consumer must update.

## Files Modified

| File | Change |
|------|--------|
| `lib/...` | |
| `test/...` | |
| `CHANGELOG.md` | |

## Verification

The exact commands run and their outcome: `mix test`, `mix credo --strict`,
`mix dialyzer`, `mix format --check-formatted`, and the integration suite
against the real engine when the change touches client fidelity.
