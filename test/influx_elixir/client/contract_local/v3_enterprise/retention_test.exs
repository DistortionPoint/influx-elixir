defmodule InfluxElixir.ContractLocal.V3Enterprise.RetentionTest do
  @moduledoc """
  `InfluxElixir.Contract.Retention` (database retention: expired data hidden,
  `SHOW RETENTION POLICIES`) against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.Retention,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise
end
