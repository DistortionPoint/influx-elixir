defmodule InfluxElixir.ContractLocal.V3Core.SqlParserLiteralsTimeTest do
  @moduledoc """
  The `:literals_time` part of `InfluxElixir.Contract.SQLParser`
  (literals, constants and every use of time)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :literals_time
end
