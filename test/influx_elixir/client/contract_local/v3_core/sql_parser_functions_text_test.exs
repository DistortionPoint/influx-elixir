defmodule InfluxElixir.ContractLocal.V3Core.SqlParserFunctionsTextTest do
  @moduledoc """
  The `:functions_text` part of `InfluxElixir.Contract.SQLParser`
  (LIMIT, functions, DATE_BIN, text and identifiers)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :functions_text
end
