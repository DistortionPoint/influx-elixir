# `Client.HTTP` Pool Checkout Timeout

**Date**: 2026-09-11
**Scope**: `InfluxElixir.Client.HTTP` request and streaming paths, `InfluxElixir.Config`
**Issue**: GitHub #14

---

## Verification of the report

The issue claimed `do_request/6` passes only `receive_timeout` to Finch, so
Finch's hard default `pool_timeout` of 5 s always applies. Checked:

* `lib/influx_elixir/client/http.ex` — `Finch.request(request, finch_name,
  receive_timeout: timeout)`; the streaming producer's `Finch.stream/5` call
  did the same. No option named `pool_timeout` existed anywhere in `lib/`.
* `deps/finch/lib/finch/http1/pool.ex:55` —
  `pool_timeout = Keyword.get(opts, :pool_timeout, 5_000)`.

So a request that has to wait on checkout fails with a transport `:timeout`
after 5 s no matter what `:timeout` (receive) says. Real issue.

## Design

* `resolve_pool_timeout/2` mirrors `resolve_timeout/2`:
  `opts[:pool_timeout]` → `connection[:pool_timeout]` → `5_000`. The default
  stays Finch's so nothing changes for callers who do not configure it; the
  bug was that it could not be configured at all.
* `finch_opts/2` builds `[receive_timeout: ..., pool_timeout: ...]` and is
  used by `do_request/6` and by the streaming producer, so
  `query_sql_stream/3` honours both bounds too.
* `Config` gains `:pool_timeout`; the facade and HTTP moduledocs describe the
  precedence and that the checkout bound applies before the receive bound.

## Verification against a real engine

The integration suite starts a dedicated Finch pool of size 1 against
InfluxDB 3 Core, holds its only connection with a `Finch.stream/5` whose
chunk callback sleeps, and then issues `query_sql/3`:

* `pool_timeout: 100, timeout: 180_000` → `{:error, {:connection_error, _}}`
  within a second (the receive timeout never had a say);
* `pool_timeout: 10_000` → waits for the holder to finish and returns the row.

No mocking: the starvation is a real pool with a real blocked connection.

The first run of that test found a second bug the report did not mention:
Finch 0.21 does not *return* an error on checkout timeout — its HTTP/1 pool
catches NimblePool's exit and re-raises a `RuntimeError` ("Finch was unable
to provide a connection within the timeout …"). That exception escaped
`query_sql/3`, breaking the tagged-tuple contract. `do_request/6` now rescues
it and `classify_finch_error/1` maps the checkout message to `:pool_timeout`,
so callers get `{:error, {:connection_error, :pool_timeout}}`; in the
streaming path the producer's crash reason is classified the same way and
raised as `StreamError{kind: :transport, reason: :pool_timeout}`. The test
asserts both.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/http.ex` | `resolve_pool_timeout/2`, `finch_opts/2`, streaming path, moduledoc |
| `lib/influx_elixir/config.ex` | `:pool_timeout` |
| `lib/influx_elixir.ex` | option documented on `query_sql/3` |
| `test/influx_elixir/client/http_test.exs` | precedence tests |
| `test/integration/contract_v3_core_test.exs` | starved-pool tests |
| `CHANGELOG.md` | Fixed entry |
