defmodule InfluxElixir.Integration.ContractV3Core.WriteRulesSchemaTest do
  @moduledoc """
  The `:schema` part of `InfluxElixir.Contract.WriteRules`
  (column types, parse errors, time, extremes, repeats)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :schema
end
