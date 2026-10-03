defmodule InfluxElixir.Integration.ContractV3Enterprise.RetentionTest do
  @moduledoc """
  `InfluxElixir.Contract.Retention` (database retention: expired data hidden,
  `SHOW RETENTION POLICIES`) against the real server of the `:v3_enterprise`
  profile.

  Enterprise retention is unverified. Every expectation of the contract was read
  from InfluxDB 3 Core, and no Enterprise server has run it: this module only
  wires the contract up (it is excluded by tag, and `Client.Local` already runs
  the same contract for the profile). The first run against an Enterprise server
  decides whether its retention reads as Core's does.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.Retention,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise
end
