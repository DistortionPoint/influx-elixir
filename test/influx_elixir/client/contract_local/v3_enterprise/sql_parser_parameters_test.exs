defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlParserParametersTest do
  @moduledoc """
  The `:parameters` part of `InfluxElixir.Contract.SQLParser`
  (bound parameters)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :parameters
end
