# Twenty-Second Review: Client Connection & Option Guards

- **Date**: 2026-10-20
- **Status**: Implemented

## Context

A sweep across `InfluxElixir.Client.HTTP`, `InfluxElixir.Flight.Client`,
`InfluxElixir.Write.Writer`, `InfluxElixir.Write.BatchWriter`,
`InfluxElixir.ConnectionSupervisor`, `InfluxElixir.Admin.TokenRequest`,
`InfluxElixir.Client.Local`, `InfluxElixir.Client.Local.Admin`, and
`InfluxElixir.Client.Local.SQLRewrite` checked every entry point where
malformed connections, non-keyword option lists, or unencodable JSON terms
could raise instead of returning a tagged `{:error, reason}` tuple.

## Findings & Fixes

1. **`InfluxElixir.Write.Writer.resolve/1` accepted non-keyword lists.**
   `defp resolve(connection) when is_list(connection) or is_map(connection)`
   let charlists (`~c"localhost"`), non-pair lists (`[1, 2]`), and improper
   lists (`[:a | :b]`) pass into the client, where `Keyword.get/3` raised
   `FunctionClauseError`. `Writer.resolve/1` now requires `Options.keyword?/1`
   for list connections, matching `InfluxElixir.connection?/1`.
2. **`InfluxElixir.Client.HTTP` had no connection guard.**
   `Client.Local` guards every callback with `live/2`, whereas calling
   `Client.HTTP` with a `Client.Local` map (`%{table: ...}`) or any
   non-keyword term raised `FunctionClauseError` in `Keyword.get/3`.
   `Request.connection/1` now validates `Options.keyword?(connection)` at the
   entry of every `Client.HTTP` callback (`init_connection/1`, `write/3`,
   `query_sql/3`, `query_sql_stream/3`, `execute_sql/3`, `query_influxql/3`,
   `query_flux/3`, and all database, bucket, token, and health callbacks),
   returning `{:error, {:invalid_connection, connection}}` (or raising
   `InfluxElixir.StreamError` on enumeration for `query_sql_stream/3`).
3. **`InfluxElixir.Flight.Client.query/3` raised on non-map connections,
   non-keyword `opts`, or invalid `:port` / `:flight_port`.**
   `Flight.Client.query/3` called `Keyword.get(opts, :timeout)` before
   checking `Options.keyword?(opts)`, and interpolated `connection[:port]`
   into `"#{host}:#{port}"` without checking that `:port` is an integer in
   `1..65_535`. `Flight.Client.query/3` now checks `is_map(connection)`,
   `Options.keyword?(opts)`, and `check_port/1` (`nil` defaults to `443`,
   `1..65_535` is accepted, anything else returns
   `{:error, {:invalid_port, port}}`), and `Client.HTTP.flight_query_sql/3`
   defaults `:flight_port` only when `nil` so `flight_port: false` is rejected.
4. **`TokenRequest.encode/1` and `Client.Local.Admin.retention/2` did not
   rescue `Jason.encode/1` raises.**
   `Jason.encode/1` raises `FunctionClauseError` or `Protocol.UndefinedError`
   on improper lists (`[1 | 2]`) or maps with tuple keys (`%{{1, 2} => 3}`).
   Both functions now rescue `[FunctionClauseError, Protocol.UndefinedError,
   Jason.EncodeError, ArgumentError]` and return
   `{:error, {:unencodable_body, message}}`, matching `Request.json_body/1`
   and `QueryParams`.
5. **`Client.Local` raised on tampered connection maps or non-keyword
   `init_connection/1` configs.**
   `Client.Local.live/2` matched `%{table: table}` without checking
   `:profile`, `:org`, or `:database`, so `%{table: conn.table}` without
   `:profile` raised `KeyError` in `Scope.supports?/2` and `org: 123` raised
   `ArgumentError` in `:crypto.hash/2`. `live/2`, `supports?/2`, `stop/1`, and
   `init_connection/1` now validate the connection map and keyword config
   without raising.
6. **`BatchWriter` and `ConnectionSupervisor` crashed on non-keyword
   `batch_writer:` options or boolean `:finch_name`.**
   `BatchWriter.start_link/1` and `BatchWriter.child_spec/1` now guard
   `Options.keyword?(opts)`, and `ConnectionSupervisor.children/4` checks
   `Options.keyword?(batch_opts)` before `Keyword.merge/2` and ignores boolean
   or non-atom `:finch_name` values just like `Request.resolve_finch/1`.
7. **`Client.Local.SQLRewrite.drop_space/2` had duplicate identical clauses.**
   `defp drop_space(blank, [{:space, _text} | _more] = more), do: blank ++ more`
   bound `more` to the full list including the leading space. Fixed to
   `defp drop_space(blank, [{:space, _text} | more]), do: blank ++ more`.
