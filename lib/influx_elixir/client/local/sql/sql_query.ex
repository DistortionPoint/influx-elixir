defmodule InfluxElixir.Client.Local.SQLQuery do
  @moduledoc false
  # The SQL path of `InfluxElixir.Client.Local`: `query_sql/3`,
  # `query_sql_stream/3` and `execute_sql/3` (SELECT, DELETE and the
  # refusals the engine gives other statements). `Client.Local` is the
  # public facade and carries the documentation.

  alias InfluxElixir.Client.{Local, QueryParams}

  alias InfluxElixir.Client.Local.{
    Format,
    LineProtocolParser,
    Scope,
    SQLError,
    SQLExecutor,
    SQLIdentifiers,
    SQLInformation,
    SQLLexer,
    SQLParser,
    SQLRewrite,
    SQLShow,
    SQLStatement,
    SQLSyntax,
    Store
  }

  @type conn :: Local.conn()

  @spec query_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_sql(conn, sql, opts \\ []) do
    with :ok <- Scope.require_capability(conn, :query_sql),
         {:ok, database} <- Scope.resolve_database(opts, conn),
         {:ok, params} <- QueryParams.normalize(Keyword.get(opts, :params, %{})) do
      answer_sql(conn, database, sql, params, opts)
    end
  end

  # The engine answers query_sql and execute_sql from the same endpoint:
  # a statement that is not a query gets execute_sql's answer. A text its
  # tokenizer cannot read is answered after the request's format and
  # parameters, as its parser reads the text last.
  @spec answer_sql(conn(), binary(), binary(), QueryParams.t(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp answer_sql(%{table: table} = conn, database, sql, params, opts) do
    case SQLLexer.scrub(sql) do
      {:ok, statement} ->
        answer_statement(conn, {database, sql, statement}, params, opts)

      {:error, reason} ->
        Format.answer(
          Scope.query_format(opts),
          fn ->
            with :ok <- Scope.database_exists(table, database),
                 do: {:error, parsed(sql, reason)}
          end,
          database,
          params
        )
    end
  end

  @spec answer_statement(conn(), {binary(), binary(), binary()}, QueryParams.t(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp answer_statement(%{table: table} = conn, {database, sql, statement}, params, opts) do
    cond do
      error = SQLStatement.bare_error(sql) ->
        Format.answer(
          Scope.query_format(opts),
          fn -> with :ok <- Scope.database_exists(table, database), do: {:error, error} end,
          database,
          params
        )

      statement_kind(statement) == :query ->
        Format.answer(
          Scope.query_format(opts),
          fn -> query_database(table, database, {sql, statement}, params) end,
          database,
          params
        )

      true ->
        execute_sql(conn, sql, opts)
    end
  end

  # A text the double refuses to read (a hexadecimal string) that the engine
  # tokenizes and then fails to parse as a statement is that parser error.
  @spec parsed(binary(), SQLError.t()) :: SQLError.t()
  defp parsed(sql, %{status: 400, body: "Client.Local: " <> _rest} = refusal),
    do: SQLStatement.parser_error(sql) || refusal

  # Several statements are the engine's 405 once each of them reads.
  defp parsed(sql, %{status: 405} = several) do
    case SQLSyntax.check_statements(sql) do
      :ok -> several
      {:error, _error} = parse_error -> elem(parse_error, 1)
    end
  end

  defp parsed(_sql, error), do: error

  @spec query_database(Store.t(), binary(), {binary(), binary()}, QueryParams.t()) ::
          InfluxElixir.Client.query_result()
  defp query_database(table, database, {original, statement}, params) do
    # The parser's error names the line and column of the text as it was written, comments
    # and all; the text the lexer rewrote (dollar-quoted and escape strings) is read as
    # rewritten, by `SQLParser`.
    with :ok <- Scope.database_exists(table, database),
         :ok <- written_syntax(original),
         do: run_query(table, database, statement, params)
  end

  @spec written_syntax(binary()) :: :ok | {:error, SQLError.t()}
  defp written_syntax(original), do: SQLSyntax.check_statements(original)

  @spec run_query(Store.t(), binary(), binary(), QueryParams.t()) ::
          InfluxElixir.Client.query_result()
  defp run_query(table, database, sql, params) do
    with {:ok, text} <- show(table, database, SQLRewrite.apply(sql)),
         {:ok, query} <- SQLParser.parse_select(text) do
      case SQLExecutor.run(
             query,
             &SQLInformation.fetch(table, database, &1),
             QueryParams.engine_values(params),
             &Store.column_kind(table, database, &1, &2)
           ) do
        {:error, _reason} = err -> err
        rows -> {:ok, rows}
      end
    end
  end

  # `SHOW TABLES` and `SHOW COLUMNS` are the queries the engine runs for them.
  @spec show(Store.t(), binary(), binary()) :: {:ok, binary()} | {:error, SQLError.t()}
  defp show(table, database, sql) do
    case SQLShow.rewrite(sql) do
      :nomatch -> {:ok, sql}
      {:error, _error} = error -> error
      {:ok, query, nil} -> {:ok, query}
      {:ok, query, measurement} -> exists(table, database, measurement, query)
    end
  end

  @spec exists(Store.t(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, SQLError.t()}
  defp exists(table, database, measurement, query) do
    if Store.table?(table, database, measurement),
      do: {:ok, query},
      else: {:error, SQLError.planning("table 'public.iox.#{measurement}' not found")}
  end

  @spec query_sql_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_sql_stream(conn, sql, opts \\ []) do
    case Scope.require_capability(conn, :query_sql_stream) do
      :ok ->
        case query_sql(conn, sql, Keyword.delete(opts, :format)) do
          {:ok, rows} -> Stream.map(rows, & &1)
          {:error, reason} -> InfluxElixir.StreamError.stream(stream_error_opts(reason))
        end

      {:error, :unsupported_operation} ->
        InfluxElixir.StreamError.stream(kind: :unsupported, reason: :unsupported_operation)
    end
  end

  # Maps a `query_sql/3` error reason to `InfluxElixir.StreamError` options,
  # mirroring how `Client.HTTP` classifies the same failures. Query errors that
  # a real InfluxDB surfaces as an HTTP status (bad SQL, missing table) map to
  # `:http_status`; a missing database maps to `:no_database`.
  @spec stream_error_opts(term()) :: keyword()
  defp stream_error_opts(%{status: status, body: body}),
    do: [kind: :http_status, status: status, body: body]

  defp stream_error_opts(:no_database_specified), do: [kind: :no_database]

  defp stream_error_opts(reason), do: [kind: :transport, reason: reason]

  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map() | [map()]} | {:error, term()}
  def execute_sql(%{table: table, profile: profile} = conn, sql, opts \\ []) do
    with :ok <- Scope.require_capability(conn, :execute_sql),
         {:ok, database} <- Scope.resolve_database(opts, conn),
         {:ok, params} <- QueryParams.normalize(Keyword.get(opts, :params, %{})),
         :ok <- Format.check_params(params, nil, database),
         :ok <- Scope.database_exists(table, database),
         {:ok, trimmed} <- scrubbed(sql),
         :ok <- bare_statement(sql) do
      case statement_kind(trimmed) do
        :query ->
          query_sql(conn, sql, opts)

        # The statement follows SQL's identifier rules, as a SELECT does:
        # `DELETE FROM "Cpu" WHERE "Host" = 'a'`.
        :delete when profile == :v3_enterprise ->
          case Regex.run(
                 ~r/^(?i)DELETE\s+FROM\s+("[^"]+"|(?:[^\s\\]|\\.)+)(.*)$/s,
                 SQLIdentifiers.normalize(trimmed)
               ) do
            [_full, measurement_raw, rest] ->
              execute_delete(table, database, measurement_raw, rest)

            nil ->
              {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}
          end

        :delete ->
          {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}

        {:planning, message} ->
          {:error, %{status: 400, body: "Error during planning: " <> message}}

        {:refusal, message} ->
          {:error, SQLError.refusal(message)}

        :unsupported ->
          {:error,
           SQLStatement.parser_error(sql) ||
             %{
               status: 405,
               body: "This feature is not implemented: Unsupported SQL statement: " <> trimmed
             }}
      end
    end
  end

  @spec scrubbed(binary()) :: {:ok, binary()} | {:error, SQLError.t()}
  defp scrubbed(sql) do
    case SQLLexer.scrub(sql) do
      {:ok, _statement} = ok -> ok
      {:error, reason} -> {:error, parsed(sql, reason)}
    end
  end

  @spec bare_statement(binary()) :: :ok | {:error, SQLError.t()}
  defp bare_statement(sql) do
    case SQLStatement.bare_error(sql) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec statement_kinds() :: [{Regex.t(), atom() | {:planning | :refusal, binary()}}]
  defp statement_kinds do
    [
      # Statements the engine answers with rows. The ones the double does
      # not model (EXPLAIN, SHOW TABLES, DESCRIBE) reach its parser and are
      # refused by name there, not reported as unimplemented.
      {~r/^(?i)(?:SELECT|WITH|EXPLAIN|SHOW|DESCRIBE)\b|^\(/, :query},
      {~r/^(?i)DELETE\b/, :delete},
      {~r/^(?i)VALUES\b/, {:refusal, "a VALUES statement: the double reads no VALUES rows"}},
      {~r/^(?i)INSERT\b/, {:planning, "DML not supported: Insert Into"}},
      {~r/^(?i)UPDATE\b/, {:planning, "DML not supported: Update"}},
      {~r/^(?i)CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\b/,
       {:planning, "DDL not supported: CreateView"}},
      {~r/^(?i)CREATE\s+(?:DATABASE|SCHEMA)\b/, {:planning, "DDL not supported: CreateCatalog"}},
      {~r/^(?i)CREATE\s+TABLE\b/, {:planning, "DDL not supported: CreateMemoryTable"}},
      {~r/^(?i)DROP\s+VIEW\b/, {:planning, "DDL not supported: DropView"}},
      {~r/^(?i)DROP\s+TABLE\b/, {:planning, "DDL not supported: DropTable"}},
      {~r/^(?i)(?:COMMIT|ROLLBACK)\s*;?\s*$/,
       {:planning, "Statement not supported: TransactionEnd"}},
      {~r/^(?i)START\s+TRANSACTION\s*;?\s*$/,
       {:planning, "Statement not supported: TransactionStart"}},
      {~r/^(?i)SET\s+[\w.]+\s*(?:=|TO\b)\s*\S/,
       {:planning, "Statement not supported: SetVariable"}},
      {~r/^(?i)PREPARE\s+\w+\s+AS\s+\S/, {:planning, "Statement not supported: Prepare"}},
      {~r/^(?i)DEALLOCATE\s+\w+\s*;?\s*$/, {:planning, "Statement not supported: Deallocate"}},
      {~r/^(?i)EXEC(?:UTE)?\s+\w+\s*(?:\([^)]*\))?\s*;?\s*$/,
       {:planning, "Statement not supported: Execute"}}
    ]
  end

  @spec statement_kind(binary()) ::
          :query | :delete | {:planning, binary()} | {:refusal, binary()} | :unsupported
  defp statement_kind(sql) do
    Enum.find_value(statement_kinds(), :unsupported, fn {pattern, kind} ->
      if Regex.match?(pattern, sql), do: kind
    end)
  end

  @spec execute_delete(Store.t(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp execute_delete(table, database, measurement_raw, rest) do
    measurement =
      case measurement_raw do
        "\"" <> _quoted -> String.trim(measurement_raw, "\"")
        bare -> LineProtocolParser.unescape_measurement(bare)
      end

    with {:ok, where} <- SQLParser.parse_where(rest) do
      count =
        Store.delete_points(table, database, measurement, &SQLExecutor.matches_all?(&1, where))

      {:ok, %{"rows_affected" => count}}
    end
  end
end
