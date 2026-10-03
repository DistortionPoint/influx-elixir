defmodule InfluxElixir.Integration.ContractV3Enterprise.WriteRulesAtomicTest do
  @moduledoc """
  The `:atomic` part of `InfluxElixir.Contract.WriteRules`
  (accept_partial, no_sync, rendered lines)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :atomic
end
