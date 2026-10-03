defmodule InfluxElixir.Integration.ContractV3Enterprise.WriteRulesSchemaTest do
  @moduledoc """
  The `:schema` part of `InfluxElixir.Contract.WriteRules`
  (column types, parse errors, time, extremes, repeats)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :schema
end
