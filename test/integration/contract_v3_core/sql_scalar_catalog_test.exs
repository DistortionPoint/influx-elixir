defmodule InfluxElixir.Integration.ContractV3Core.SqlScalarCatalogTest do
  @moduledoc """
  The `:catalog` part of `InfluxElixir.Contract.SQLScalar`
  (the parser, SHOW COLUMNS and the information_schema)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :catalog
end
