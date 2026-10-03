defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlParserModelledTest do
  @moduledoc """
  The `:modelled` part of `InfluxElixir.Contract.SQLParser`
  (expressions, functions and the engine's errors)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :modelled
end
