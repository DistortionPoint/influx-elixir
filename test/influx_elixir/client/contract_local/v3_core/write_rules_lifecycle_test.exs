defmodule InfluxElixir.ContractLocal.V3Core.WriteRulesLifecycleTest do
  @moduledoc """
  The `:lifecycle` part of `InfluxElixir.Contract.WriteRules`
  (missing databases, names, deletes, the Core limit)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :lifecycle
end
