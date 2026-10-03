defmodule InfluxElixir.Integration.ContractV3Core.WriteRulesAtomicTest do
  @moduledoc """
  The `:atomic` part of `InfluxElixir.Contract.WriteRules`
  (accept_partial, no_sync, rendered lines)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :atomic
end
