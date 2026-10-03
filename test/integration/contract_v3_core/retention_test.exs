defmodule InfluxElixir.Integration.ContractV3Core.RetentionTest do
  @moduledoc """
  `InfluxElixir.Contract.Retention` (database retention: expired data hidden,
  `SHOW RETENTION POLICIES`) against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.Retention,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core
end
