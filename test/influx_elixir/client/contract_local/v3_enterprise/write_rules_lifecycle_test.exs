defmodule InfluxElixir.ContractLocal.V3Enterprise.WriteRulesLifecycleTest do
  @moduledoc """
  The `:lifecycle` part of `InfluxElixir.Contract.WriteRules`
  (missing databases, names, deletes, the Core limit)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :lifecycle
end
