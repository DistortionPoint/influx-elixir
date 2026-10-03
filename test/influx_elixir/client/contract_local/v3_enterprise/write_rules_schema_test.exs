defmodule InfluxElixir.ContractLocal.V3Enterprise.WriteRulesSchemaTest do
  @moduledoc """
  The `:schema` part of `InfluxElixir.Contract.WriteRules`
  (column types, parse errors, time, extremes, repeats)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :schema
end
