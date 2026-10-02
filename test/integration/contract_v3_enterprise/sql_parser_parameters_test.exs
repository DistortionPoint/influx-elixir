defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlParserParametersTest do
  @moduledoc """
  The `:parameters` part of `InfluxElixir.Contract.SQLParser`
  (bound parameters)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :parameters
end
