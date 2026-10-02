defmodule InfluxElixir.ContractLocal.V3Core.SqlParserParametersTest do
  @moduledoc """
  The `:parameters` part of `InfluxElixir.Contract.SQLParser`
  (bound parameters)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :parameters
end
