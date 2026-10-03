defmodule InfluxElixir.ContractLocal.V3Core.SqlScalarCatalogTest do
  @moduledoc """
  The `:catalog` part of `InfluxElixir.Contract.SQLScalar`
  (the parser, SHOW COLUMNS and the information_schema)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :catalog
end
