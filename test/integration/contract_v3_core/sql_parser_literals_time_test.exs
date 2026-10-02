defmodule InfluxElixir.Integration.ContractV3Core.SqlParserLiteralsTimeTest do
  @moduledoc """
  The `:literals_time` part of `InfluxElixir.Contract.SQLParser`
  (literals, constants and every use of time)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :literals_time
end
