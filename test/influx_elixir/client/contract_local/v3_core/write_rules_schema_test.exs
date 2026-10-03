defmodule InfluxElixir.ContractLocal.V3Core.WriteRulesSchemaTest do
  @moduledoc """
  The `:schema` part of `InfluxElixir.Contract.WriteRules`
  (column types, parse errors, time, extremes, repeats)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :schema
end
