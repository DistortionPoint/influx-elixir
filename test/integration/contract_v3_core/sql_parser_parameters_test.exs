defmodule InfluxElixir.Integration.ContractV3Core.SqlParserParametersTest do
  @moduledoc """
  The `:parameters` part of `InfluxElixir.Contract.SQLParser`
  (bound parameters)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :parameters
end
