defmodule InfluxElixir.ContractLocal.V3Core.RetentionTest do
  @moduledoc """
  `InfluxElixir.Contract.Retention` (database retention: expired data hidden,
  `SHOW RETENTION POLICIES`) against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.Retention,
    client: InfluxElixir.Client.Local,
    profile: :v3_core
end
