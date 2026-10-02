defmodule InfluxElixir.Integration.ContractV3Core.SqlParserNamesSelectTest do
  @moduledoc """
  The `:names_select` part of `InfluxElixir.Contract.SQLParser`
  (unaliased and grouped names, field lists, CTEs)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :names_select
end
