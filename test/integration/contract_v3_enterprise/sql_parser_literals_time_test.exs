defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlParserLiteralsTimeTest do
  @moduledoc """
  The `:literals_time` part of `InfluxElixir.Contract.SQLParser`
  (literals, constants and every use of time)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :literals_time
end
