defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlParserFunctionsTextTest do
  @moduledoc """
  The `:functions_text` part of `InfluxElixir.Contract.SQLParser`
  (LIMIT, functions, DATE_BIN, text and identifiers)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :functions_text
end
