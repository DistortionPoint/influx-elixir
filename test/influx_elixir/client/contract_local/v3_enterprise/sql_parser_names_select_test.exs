defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlParserNamesSelectTest do
  @moduledoc """
  The `:names_select` part of `InfluxElixir.Contract.SQLParser`
  (unaliased and grouped names, field lists, CTEs)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :names_select
end
