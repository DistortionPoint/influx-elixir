defmodule InfluxElixir.Integration.ContractV3Enterprise.WriteRulesLifecycleTest do
  @moduledoc """
  The `:lifecycle` part of `InfluxElixir.Contract.WriteRules`
  (missing databases, names, deletes, the Core limit)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :lifecycle
end
