defmodule InfluxElixir.ContractLocal.V3Core.SqlParserModelledTest do
  @moduledoc """
  The `:modelled` part of `InfluxElixir.Contract.SQLParser`
  (expressions, functions and the engine's errors)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :modelled
end
