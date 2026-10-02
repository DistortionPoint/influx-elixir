defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlParserNamesSelectTest do
  @moduledoc """
  The `:names_select` part of `InfluxElixir.Contract.SQLParser`
  (unaliased and grouped names, field lists, CTEs)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :names_select
end
