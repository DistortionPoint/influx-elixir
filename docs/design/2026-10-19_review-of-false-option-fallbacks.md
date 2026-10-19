# Review of `false` Option Fallbacks, Boolean Atoms, and Format Encoding

**Date**: 2026-10-19
**Scope**: `InfluxElixir`, `InfluxElixir.Client.Options`, `InfluxElixir.Client.HTTP`, `InfluxElixir.Client.HTTP.Request`, `InfluxElixir.Client.QueryParams`, `InfluxElixir.Client.Local`, `InfluxElixir.Client.Local.Scope`, `InfluxElixir.Client.Local.InfluxQLQuery`, `InfluxElixir.Write.Point`, `InfluxElixir.Write.Writer`, `InfluxElixir.Connection`, `InfluxElixir.ConnectionSupervisor`
**Issue**: scheduled quality sweep

---

## Problem

1. **`||` option fallbacks swallowed `false` instead of validating it**:
   - In Elixir, `false || fallback` evaluates to `fallback`. Several option resolution helpers used `Keyword.get(opts, key) || default`, causing an explicit `false` option to be silently replaced by the connection's default or a valid default instead of being rejected:
     - `Client.HTTP.resolve_database/2` and `Client.Local.Scope.resolve_database/2` used `Keyword.get(opts, :database) || ...`, so `database: false` on a connection with `database: "mydb"` silently queried or wrote to `"mydb"` instead of returning `{:error, %Error{reason: :invalid_database}}`.
     - `InfluxElixir` and `Writer` telemetry metadata helpers used `Keyword.get(opts, :database) || Options.database(connection)`, reporting the connection's default database in telemetry metadata when `database: false` was passed.
     - `Client.HTTP.http_query_sql/3` and `Client.HTTP.influxql_request/3` used `Keyword.get(opts, :format, :json) || :json`, turning `format: false` into `:json` instead of sending `"false"` / rejecting it as an unknown format (`400`).
     - `Client.Local.Scope.query_format/1` used `Keyword.get(opts, :format, :json)` without coalescing `nil`, so `format: nil` returned `{:error, %Error{status: 400}}` on `Client.Local` while `Client.HTTP` defaulted `format: nil` to `:json`.
     - `Client.Local.start/1` used `Keyword.get(opts, :databases) || []` and `Keyword.get(opts, :org) || "local"`, silently accepting `databases: false` and `org: false` instead of raising `ArgumentError`.
     - `Point.new/3` used `fields || %{}` and `Keyword.get(opts, :tags) || %{}`, turning `Point.new("m", false)` or `tags: false` into `%{}` instead of preserving `false` so `LineProtocol.encode/2` returns `{:error, {:invalid_point, point}}`.

2. **Unencodable `:format` values in `Client.HTTP` and `QueryParams` raised instead of returning `{:error, %Error{}}`**:
   - `QueryParams.request_body/4` and `Client.HTTP.influxql_request/3` called `to_string(format)` on non-nil formats, which raises `Protocol.UndefinedError` on tuples/maps/pids (`format: {1}`, `format: self()`) and `ArgumentError` on improper lists (`format: [1 | 2]`).
   - `Client.HTTP.sql_request_body/4` checked `encodable_text(sql)` and `encodable_text(database)` before calling `QueryParams.request_body/4`, but did not check `encodable_text(format)`, so invalid UTF-8 binaries (`format: <<0xFF>>`) raised `Jason.EncodeError` inside `Jason.encode!`.

3. **Boolean atoms (`true` / `false`) treated as registered process names**:
   - In Elixir, `is_atom(false)` and `is_atom(true)` are `true`.
   - `ConnectionSupervisor.start_link/1` accepted `name: false` and `name: true` in its guard (`is_atom(name) and not is_nil(name)`), registering a connection under the literal atom `false` or `true`.
   - `Connection.finch_name/1` and `Client.HTTP.Request.resolve_finch/1` matched `finch when is_atom(finch) and not is_nil(finch)`, routing HTTP requests to a process named `false` or `true` when `finch_name: false` or `name: false` was in the connection map.

4. **`Client.Local.InfluxQLQuery.query_influxql/3` checked `:format` before `:database`**:
   - When `query_influxql/3` was called with both an invalid `database:` (e.g., `database: 123` or `database: <<0xFF>>`) and `SHOW DATABASES` (which does not call `resolve_db/2`) or an unknown `format: :bogus`, `Format.answer/4` ran first, either succeeding on `SHOW DATABASES` despite the invalid `database:` option or returning the format 400 before `:invalid_database`.

## Design

- **`Options.database/2`**: Added `Options.database(opts, connection)` which only falls back to `Options.database(connection)` when `Keyword.get(opts, :database)` is `nil`. Used in `InfluxElixir`, `Writer`, and `Client.HTTP.resolve_database/2`.
- **`Client.Local.Scope`**: Updated `resolve_database/2` to fall back to `Map.get(conn, :database)` only when `Keyword.get(opts, :database)` is `nil`, and updated `query_format/1` so `nil` defaults to `:json` while `false` is preserved and rejected with status 400 (`unknown format: false`).
- **`Client.Local.InfluxQLQuery`**: Validated `request_database(opts, conn)` via `Scope.resolve_database/2` before `Format.answer/4`.
- **`Client.HTTP` and `QueryParams`**:
  - Added `query_format/1` (`nil -> :json`, `format -> format`).
  - Checked `encodable_text(format)` in `sql_request_body/4`.
  - Converted atom formats with `Atom.to_string/1` in `QueryParams.request_body/4` and `Client.HTTP.influxql_request/3`, leaving non-atom values for `encodable_text/1` to reject with `{:error, %Error{reason: {:unencodable_body, ...}}}`.
- **`Client.Local.start/1` and `Point.new/3`**: Replaced `||` with `case ... do nil -> default; value -> value end`.
- **`ConnectionSupervisor`, `Connection`, and `Client.HTTP.Request`**: Guarded process-name atoms with `not in [nil, true, false]`.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/options.ex` | Add `Options.database/2` falling back only on `nil` |
| `lib/influx_elixir.ex` | Use `Options.database/2` in `query_span/3` |
| `lib/influx_elixir/write/writer.ex` | Use `Options.database/2` in `write_body/3` |
| `lib/influx_elixir/write/point.ex` | Preserve non-`nil` `fields` and `:tags` in `Point.new/3` |
| `lib/influx_elixir/client/http.ex` | Preserve `format: false`, validate `encodable_text(format)`, convert atom formats via `Atom.to_string/1`, and use `Options.database/2` |
| `lib/influx_elixir/client/http/request.ex` | Exclude `true` and `false` in `resolve_finch/1` |
| `lib/influx_elixir/client/query_params.ex` | Convert atom formats with `Atom.to_string/1` instead of `to_string/1` |
| `lib/influx_elixir/client/local.ex` | Default `:databases` and `:org` only when `nil` |
| `lib/influx_elixir/client/local/shared/scope.ex` | Default `:database` and `:format` only when `nil` |
| `lib/influx_elixir/client/local/influxql/influxql_query.ex` | Validate `database:` option before `Format.answer/4` |
| `lib/influx_elixir/connection_supervisor.ex` | Reject `name: false` and `name: true` in `start_link/1` |
| `lib/influx_elixir/connection.ex` | Exclude `true` and `false` in `finch_name/1` |
| `test/influx_elixir/client/local/invalid_utf8_test.exs` | Pin `database: false` and `SHOW DATABASES` with invalid `database:` |
| `test/influx_elixir/client/local/format_test.exs` | Pin `format: nil` and `format: false` across SQL and InfluxQL |
| `test/influx_elixir/client/local/lifecycle_admin_test.exs` | Pin `databases: false` and `org: false` in `Client.Local.start/1` |
| `test/influx_elixir/client/http_robustness_test.exs` | Pin unencodable `format:` values and `database: false` in `Client.HTTP` |
| `test/influx_elixir/write/point_test.exs` | Pin `Point.new/3` with `fields = false` and `tags: false` |
| `test/influx_elixir/connection_test.exs` | Pin `Connection.finch_name/1` with `finch_name: false` and `finch_name: true` |
| `test/influx_elixir/connection_supervisor_test.exs` | Pin `name: false` and `name: true` refusal |
| `docs/design/README.md` | Index this review document |
| `CHANGELOG.md` | Record fixes under `[Unreleased]` |

## Verification

- `mix compile --warnings-as-errors`
- `MIX_ENV=test mix compile --force --warnings-as-errors`
- `mix format --check-formatted`
- `mix credo --strict`
- `mix dialyzer`
- `mix sobelow --config`
- `MIX_ENV=test mix test --cover`
