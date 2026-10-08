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
    SQLDml,
    SQLDmlPlan,
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
    SQLTable,
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
      error = SQLStatement.error(sql) ->
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

  # `SELECT ... INTO name` plans the select and then fails to create the table.
  @spec into_or_rows([map()], binary()) :: {:ok, [map()]} | {:error, SQLError.t()}
  defp into_or_rows(rows, sql) do
    if SQLRewrite.into?(sql),
      do: {:error, SQLError.planning("DDL not supported: CreateMemoryTable")},
      else: {:ok, rows}
  end

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
        rows -> into_or_rows(rows, sql)
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
      else: {:error, SQLTable.iox_not_found(measurement)}
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
          enterprise_delete(table, database, sql, trimmed)

        :delete ->
          {:error, delete_error(table, database, sql)}

        kind when kind in [:insert, :update] ->
          {:error,
           SQLDml.error(
             kind,
             sql,
             Store.measurements(table, database),
             &table_columns(table, database, &1),
             &plan_operand(table, database, &1, &2)
           )}

        {:planning, message} ->
          {:error, %{status: 400, body: "Error during planning: " <> message}}

        {:refusal, message} ->
          {:error, SQLError.refusal(message)}

        :unsupported ->
          {:error, SQLStatement.parser_error(sql) || unsupported(trimmed)}
      end
    end
  end

  # The engine prints the statement it does not run as its parser reads it, keywords in
  # capitals and one space between tokens.
  @spec unsupported(binary()) :: SQLError.t() | map()
  defp unsupported(statement) do
    case SQLStatement.display(statement) do
      {:ok, text} ->
        %{
          status: 405,
          body: "This feature is not implemented: Unsupported SQL statement: " <> text
        }

      :unknown ->
        SQLError.refusal(
          "the statement #{inspect(statement)} is not run: the engine's wording of " <>
            "#{kind_name(statement)} (its keywords in capitals) is not modelled"
        )
    end
  end

  # What the statement is called in a refusal: its first two words, which the double reads to
  # tell the kinds it has no wording for (`MERGE INTO`, `CREATE INDEX`), and for a grant the
  # object or the grantees that it does not read.
  @spec kind_name(binary()) :: binary()
  defp kind_name(statement) do
    case Regex.run(~r/\A\s*([A-Za-z]+)(?:\s+([A-Za-z]+))?/, statement, capture: :all_but_first) do
      [first, second] ->
        "a #{String.upcase(first)} #{String.upcase(second)} statement" <> grant_object(statement)

      [first] ->
        "a #{String.upcase(first)} statement"

      nil ->
        "this statement"
    end
  end

  @spec grant_object(binary()) :: binary()
  defp grant_object(statement) do
    cond do
      not Regex.match?(~r/\A\s*(?:GRANT|REVOKE|DENY)\b/i, statement) ->
        ""

      object = Regex.run(~r/\bON\s+((?:ALL|FUTURE)\s+[A-Za-z]+|[A-Za-z]+)\b/i, statement) ->
        object |> List.last() |> object_phrase(statement)

      Regex.match?(~r/\(\s*\)/, statement) ->
        " with an empty column list"

      true ->
        ""
    end
  end

  @spec object_phrase(binary(), binary()) :: binary()
  defp object_phrase(object, statement) do
    upper = String.upcase(object)

    cond do
      String.starts_with?(upper, ["ALL ", "FUTURE "]) -> " on #{upper}"
      upper in ~w(PROCEDURE WAREHOUSE USER CONNECTION INTEGRATION FUNCTION) -> " on #{upper}"
      Regex.match?(~r/\bPUBLIC\b/i, statement) -> " to PUBLIC beside other grantees or qualified"
      true -> ""
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
    case SQLStatement.error(sql) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  # A name: a word or a quoted one, dotted.
  @object ~S{(?:[\w$]+|"(?:[^"]|"")*")(?:\.(?:[\w$]+|"(?:[^"]|"")*"))*}

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec statement_kinds() :: [{Regex.t(), atom() | {:planning | :refusal, binary()}}]
  defp statement_kinds do
    [
      # Statements the engine answers with rows. The ones the double does
      # not model (EXPLAIN, SHOW TABLES, DESCRIBE) reach its parser and are
      # refused by name there, not reported as unimplemented.
      {~r/^(?i)(?:SELECT|WITH|EXPLAIN|SHOW|DESC|DESCRIBE)\b|^\(/, :query},
      {~r/^(?i)DELETE\b/, :delete},
      {~r/^(?i)VALUES\b/, {:refusal, "a VALUES statement: the double reads no VALUES rows"}},
      {~r/^(?i)FROM\b/,
       {:refusal, "a query that begins with FROM: the engine reads it, this double does not"}},
      {~r/^(?i)SET\s+TIME\s+ZONE\b/,
       {:refusal,
        "SET TIME ZONE: the engine's error for it prints the statement as it parsed it, " <>
          "which the double does not"}},
      {~r/^(?i)INSERT\b/, :insert},
      {~r/^(?i)UPDATE\b/, :update},
      {~r/^(?i)CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\b/,
       {:planning, "DDL not supported: CreateView"}},
      {~r/^(?i)CREATE\s+DATABASE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{@object}\s*;?\s*$/,
       {:planning, "DDL not supported: CreateCatalog"}},
      {~r/^(?i)CREATE\s+SCHEMA\s+(?:IF\s+NOT\s+EXISTS\s+)?#{@object}\s*;?\s*$/,
       {:planning, "DDL not supported: CreateCatalogSchema"}},
      {~r/^(?i)DROP\s+SCHEMA\s+(?:IF\s+EXISTS\s+)?#{@object}(?:\s+(?:CASCADE|RESTRICT))?\s*;?\s*$/,
       {:planning, "DDL not supported: DropCatalogSchema"}},
      {~r/^(?i)(?:CREATE|DROP)\s+(?:DATABASE|SCHEMA)\b/,
       {:refusal,
        "that CREATE or DROP of a database or a schema: the engine's error for it is not modelled"}},
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

  # A table's columns as the engine's schema lists them: sorted, `time` among them.
  @spec table_columns(Store.t(), binary(), binary() | {:numeric, binary()}) :: [binary()]
  defp table_columns(table, database, {:numeric, measurement}) do
    for {^measurement, column, "iox::column_type::field::" <> type} <-
          Store.columns(table, database),
        type in ["integer", "uinteger", "float"],
        do: column
  end

  # The Arrow types of a measurement's columns, `time` among them, as `{name, type}`.
  defp table_columns(table, database, {:types, measurement}) do
    columns =
      for {^measurement, column, kind} <- Store.columns(table, database),
          do: {column, arrow_type(kind)}

    Enum.uniq([{"time", "Timestamp(ns)"} | columns])
  end

  defp table_columns(table, database, measurement) do
    columns = for {^measurement, column, _kind} <- Store.columns(table, database), do: column
    ["time" | columns] |> Enum.uniq() |> Enum.sort()
  end

  @spec arrow_type(binary()) :: binary()
  defp arrow_type("iox::column_type::tag"), do: "Dictionary(Int32, Utf8)"
  defp arrow_type("iox::column_type::field::integer"), do: "Int64"
  defp arrow_type("iox::column_type::field::uinteger"), do: "UInt64"
  defp arrow_type("iox::column_type::field::float"), do: "Float64"
  defp arrow_type("iox::column_type::field::string"), do: "Utf8"
  defp arrow_type("iox::column_type::field::boolean"), do: "Boolean"

  # An operand of an `UPDATE` planned as a select item of the table (see `SQLDmlPlan`).
  @spec plan_operand(Store.t(), binary(), binary() | nil, binary()) ::
          :ok | {:error, term()} | {:refuse, binary()}
  defp plan_operand(table, database, measurement, text) do
    SQLDmlPlan.check(
      measurement,
      text,
      &SQLInformation.fetch(table, database, &1),
      &Store.column_kind(table, database, &1, &2)
    )
  end

  @spec statement_kind(binary()) ::
          :query
          | :delete
          | :insert
          | :update
          | {:planning, binary()}
          | {:refusal, binary()}
          | :unsupported
  defp statement_kind(sql) do
    Enum.find_value(statement_kinds(), :unsupported, fn {pattern, kind} ->
      if Regex.match?(pattern, sql), do: kind
    end)
  end

  # The planner reads a `DELETE` as it reads an `UPDATE`: its table by the same resolver and
  # its `WHERE` against the table's columns (`SQLDml`).
  @spec delete_error(Store.t(), binary(), binary()) :: map()
  defp delete_error(table, database, statement) do
    SQLDml.error(
      :delete,
      statement,
      Store.measurements(table, database),
      &table_columns(table, database, &1),
      &plan_operand(table, database, &1, &2)
    )
  end

  # The parser reads a `DELETE` before any edition plans it: its error for a statement it
  # does not read is the answer wherever the statement would have been run.
  @spec enterprise_delete(Store.t(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp enterprise_delete(table, database, sql, trimmed) do
    case delete_error(table, database, sql) do
      %{body: "SQL error: ParserError" <> _rest} = error ->
        {:error, error}

      _planned ->
        case Regex.run(
               ~r/^(?i)DELETE\s+FROM\s+("[^"]+"|(?:[^\s\\]|\\.)+)(.*)$/s,
               SQLIdentifiers.normalize(trimmed)
             ) do
          [_full, measurement_raw, rest] ->
            execute_delete(table, database, measurement_raw, rest)

          nil ->
            {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}
        end
    end
  end

  @spec delete_target(binary()) :: binary()
  defp delete_target("\"" <> _quoted = raw), do: String.trim(raw, "\"")
  defp delete_target(bare), do: LineProtocolParser.unescape_measurement(bare)

  @spec execute_delete(Store.t(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp execute_delete(table, database, measurement_raw, rest) do
    measurement = delete_target(measurement_raw)

    with {:ok, where} <- SQLParser.parse_where(rest) do
      count =
        Store.delete_points(table, database, measurement, &SQLExecutor.matches_all?(&1, where))

      {:ok, %{"rows_affected" => count}}
    end
  catch
    # A `WHERE` that is no boolean is found per point, as in a query.
    {:query_error, error} -> {:error, error}
  end
end
