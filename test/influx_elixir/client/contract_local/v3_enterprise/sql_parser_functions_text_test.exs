defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlParserFunctionsTextTest do
  @moduledoc """
  The `:functions_text` part of `InfluxElixir.Contract.SQLParser`
  (LIMIT, functions, DATE_BIN, text and identifiers)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :functions_text
end
