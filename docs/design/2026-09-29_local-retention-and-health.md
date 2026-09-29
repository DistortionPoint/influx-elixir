# Client.Local: Database Retention and Health Shape

**Date**: 2026-09-29
**Scope**: `Client.Local.create_database/3`, `Client.Local.health/1`
**Issue**: scheduled quality sweep (#24 awaiting a decision)

---

## Problem

**Retention.** `Client.HTTP.create_database/3` sends `retention:` as
InfluxDB 3's `retention_period`. `Client.Local` ignored its options.
Against Core, `retention_period` must be a duration string. The engine
reads it before anything else in the request. Anything that is not a
duration is a 400:

- `serde json error: invalid value: string "1H", expected a duration at line 1 column N`
- `... invalid type: integer 3600, expected a duration ...`

The integer case is the likely mistake, because a v2 bucket's
`retention:` is in seconds. Such a call passed against the double and
failed in production.

Probing 53 values against Core pinned the grammar:

- **Accepted:**
  - one or more `<number><unit>` parts, spaced or not (`1h30m`,
    `1h 30m`, `1h  30m`, ` 1h `);
  - a decimal fraction (`1.5h`) and leading zeros (`01h`);
  - a bare `0`;
  - these units, case-sensitive: `nanos nsec ns usec us µs millis msec
    ms seconds second secs sec s minutes minute mins min m hours hour
    hrs hr h days day d weeks week w months month M years year y`.
- **Refused:** `1`, `1H`, `1D`, `1mon`, `-1h`, `""`, `h`, `1.h`, `.5h`,
  `1e3s`, `1_000s` and `1h,2m`, and the integer, float and boolean types.

**Health.** The double answered `%{"status" => "pass", "version" =>
"local"}` on every profile. Core's `/health` is a plain `OK`, which
`Client.HTTP` reports as `%{"status" => "pass"}`. InfluxDB 2.7 answers
`{"name", "message", "status", "checks", "version", "commit"}`. A test
could rely on `"version"` against the double and fail on InfluxDB 3. The
health contract asserted only `status in ["pass", "ok"]`.

## Decision

- **Retention.** `check_retention/1` runs before the name rules, in the
  engine's order:
  - a `nil` retention is none;
  - a string or atom must match the grammar;
  - booleans, integers and floats are the engine's `invalid type`
    message.

  Each error is a 400 with the engine's body, minus the `at line 1
  column N` suffix, whose position depends on the client's JSON. The
  double keeps no retention, so nothing expires; the docs say so.
- **Health.** `health_body/1` answers per profile: the v3 map, or the
  InfluxDB 2 map with `version` and `commit` set to `"local"`. The
  contract asserts each shape exactly.

## Verification

- The comparison script sends 53 retention values through `Client.HTTP`
  to Core and through `Client.Local`. After the position suffix is
  stripped, none differ.
- The new database-rules contract test passes on Local and on Core: six
  accepted durations are created and dropped, and four refused values
  each give the engine's message. The health contract test passes on
  every Local profile, on Core and on 2.7.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | `check_retention/1`, `health_body/1`, docs |
| `lib/influx_elixir/admin/databases.ex` | `:retention` doc |
| `lib/influx_elixir/client/http.ex` | Helper order: the `request/7` comment sits above `request/7` again |
| `test/support/client_contract.ex` | Tests |
| `usage-rules/testing.md`, `CHANGELOG.md` | Updated |
