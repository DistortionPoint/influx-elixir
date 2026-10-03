defmodule InfluxElixir.ContractLocal.V3Enterprise.WriteRulesAtomicTest do
  @moduledoc """
  The `:atomic` part of `InfluxElixir.Contract.WriteRules`
  (accept_partial, no_sync, rendered lines)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.WriteRules,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :atomic
end
