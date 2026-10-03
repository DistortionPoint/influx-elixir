defmodule InfluxElixir.Integration.ContractV3Core.SqlParserModelledTest do
  @moduledoc """
  The `:modelled` part of `InfluxElixir.Contract.SQLParser`
  (expressions, functions and the engine's errors)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :modelled
end
