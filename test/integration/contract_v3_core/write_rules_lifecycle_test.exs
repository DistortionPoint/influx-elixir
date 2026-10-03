defmodule InfluxElixir.Integration.ContractV3Core.WriteRulesLifecycleTest do
  @moduledoc """
  The `:lifecycle` part of `InfluxElixir.Contract.WriteRules`
  (missing databases, names, deletes, the Core limit)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :lifecycle
end
