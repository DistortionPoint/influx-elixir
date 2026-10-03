defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlParserModelledTest do
  @moduledoc """
  The `:modelled` part of `InfluxElixir.Contract.SQLParser`
  (expressions, functions and the engine's errors)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :modelled
end
