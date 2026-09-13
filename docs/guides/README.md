# Guides

Consumer-facing guides. Every file here is listed under `extras:` in
`mix.exs` and published to HexDocs alongside the module documentation.

| Guide | Covers |
|---|---|
| [`testing-with-local-client.md`](testing-with-local-client.md) | Using `InfluxElixir.Client.Local` and `InfluxElixir.TestHelper` in a consumer's test suite; profiles, the SQL subset, Flux rows, contract testing |

## Writing a guide

* Kebab-case filename; H1 title, H2 sections.
* Every code example must run. Run it against `Client.Local` (or a real
  engine for HTTP behaviour) before committing — the README's original
  usage example never did, and shipped broken for months.
* When library behaviour changes, the guide changes in the same commit
  (see the "Documentation is first class" rule in `CLAUDE.md`).
* Add the file to `extras:` in `mix.exs` and to the table above.
