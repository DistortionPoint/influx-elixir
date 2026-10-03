defmodule InfluxElixir.ContractLocal.V3Core.WriteRulesAtomicTest do
  @moduledoc """
  The `:atomic` part of `InfluxElixir.Contract.WriteRules`
  (accept_partial, no_sync, rendered lines)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :atomic
end
