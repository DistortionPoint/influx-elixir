defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlParserLiteralsTimeTest do
  @moduledoc """
  The `:literals_time` part of `InfluxElixir.Contract.SQLParser`
  (literals, constants and every use of time)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :literals_time
end
