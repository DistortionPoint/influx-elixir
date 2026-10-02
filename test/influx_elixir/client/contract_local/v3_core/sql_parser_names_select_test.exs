defmodule InfluxElixir.ContractLocal.V3Core.SqlParserNamesSelectTest do
  @moduledoc """
  The `:names_select` part of `InfluxElixir.Contract.SQLParser`
  (unaliased and grouped names, field lists, CTEs)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :names_select
end
