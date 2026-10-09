defmodule InfluxElixir.Client.Local.Writes do
  @moduledoc false
  # The write path of `InfluxElixir.Client.Local`: precision, request flags and
  # body, the line protocol parser, the stores of both dialects (InfluxDB 3's
  # atomic and partial writes, InfluxDB 2's retention and type cuts) and the
  # engines' error bodies. `Client.Local.write/3` is the public entry point.

  alias InfluxElixir.Client.Local.{
    Body,
    Buckets,
    DatabaseRules,
    LineProtocolParser,
    Scope,
    Store
  }

  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(%{table: table, profile: profile} = conn, payload, opts \\ []) do
    with :ok <- Scope.require_capability(conn, :write),
         {:ok, database} <- Scope.resolve_database(opts, conn),
         # The engine's order (verified): the request's parameters, then
         # the body, then the database.
         {:ok, precision} <- normalize_precision(Keyword.get(opts, :precision), profile),
         {:ok, accept_partial} <- write_flag(opts, :accept_partial, true, profile),
         {:ok, _no_sync} <- write_flag(opts, :no_sync, false, profile),
         {:ok, text} <- Body.read(payload, Keyword.get(opts, :gzip, false) == true, profile),
         :ok <- ensure_database(table, database, profile) do
      case text
           |> LineProtocolParser.parse_lines(precision, dialect(profile))
           |> stamp_untimed() do
        {:ok, lines} when profile != :v2 and not accept_partial ->
          store_lines_atomically(table, database, lines)

        {:ok, lines} ->
          store_lines(table, database, lines, profile)

        # InfluxDB 2 answers 204 to an empty payload; InfluxDB 3 refuses it.
        {:error, _empty} when profile == :v2 ->
          {:ok, :written}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Both engines give every line of one write that has no timestamp the
  # same one, the request's time (verified): untimed lines of one series in
  # one payload are one point, their fields merged and the last write
  # winning.
  @spec stamp_untimed({:ok, [LineProtocolParser.line_result()]} | {:error, term()}) ::
          {:ok, [LineProtocolParser.line_result()]} | {:error, term()}
  defp stamp_untimed({:ok, lines}) do
    now = Store.now_ns()

    {:ok,
     Enum.map(lines, fn
       {:ok, %{timestamp: nil} = point, number, line} ->
         {:ok, %{point | timestamp: now}, number, line}

       other ->
         other
     end)}
  end

  defp stamp_untimed(error), do: error

  # What `HTTP.write/3` plus the engine accept for `:precision`, verified:
  # InfluxDB 3 takes the spellings below verbatim (case-sensitive) and
  # answers 400 to anything else; InfluxDB 2 takes only `ns|us|ms|s`, which
  # `HTTP.write/3` maps the long names onto, and answers 400 to the rest.
  @v3_precisions %{
    "auto" => :auto,
    "s" => :second,
    "second" => :second,
    "ms" => :millisecond,
    "millisecond" => :millisecond,
    "u" => :microsecond,
    "us" => :microsecond,
    "microsecond" => :microsecond,
    "n" => :nanosecond,
    "ns" => :nanosecond,
    "nanosecond" => :nanosecond
  }

  @v2_precisions Map.take(
                   @v3_precisions,
                   ~w(ns nanosecond us microsecond ms millisecond s second)
                 )

  @spec normalize_precision(atom() | binary() | nil, InfluxElixir.Client.Local.profile()) ::
          {:ok, LineProtocolParser.precision()} | {:error, map()}
  defp normalize_precision(nil, _profile), do: {:ok, :nanosecond}

  # A precision that is no word (a map, a tuple) has no spelling the engine could be sent.
  defp normalize_precision(precision, _profile)
       when not (is_atom(precision) or is_binary(precision)),
       do: {:error, %{status: 400, body: "Client.Local: the precision is not a string"}}

  defp normalize_precision(precision, :v2) do
    case Map.fetch(@v2_precisions, to_string(precision)) do
      {:ok, unit} ->
        {:ok, unit}

      :error ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => "invalid",
               "message" => "invalid precision; valid precision units are ns, us, ms, and s"
             })
         }}
    end
  end

  defp normalize_precision(precision, _v3) do
    case Map.fetch(@v3_precisions, to_string(precision)) do
      {:ok, unit} ->
        {:ok, unit}

      :error ->
        {:error,
         %{
           status: 400,
           body:
             "serde error: unknown variant `#{String.replace_invalid(to_string(precision))}`, " <>
               "expected one of `auto`, `s`, " <>
               "`second`, `millisecond`, `ms`, `microsecond`, `u`, `us`, `n`, `nanosecond`, `ns`"
         }}
    end
  end

  @spec dialect(InfluxElixir.Client.Local.profile()) :: LineProtocolParser.dialect()
  defp dialect(:v2), do: :v2
  defp dialect(_v3), do: :v3

  # InfluxDB 3: every accepted line is stored and every rejected one
  # reported ("partial write of line protocol occurred", HTTP 400, one entry
  # per bad line) — a syntax error or a column whose kind conflicts with the
  # measurement's schema drops that line only.
  #
  # InfluxDB 2: a line that fails to parse rejects the whole payload (HTTP
  # 400 `{"code":"invalid","message":"unable to parse '<line>': ..."}`,
  # nothing stored); a field type conflict drops the conflicting lines and
  # answers 422 with the first conflict and `dropped=N`.
  #
  # Both bodies are the engine's JSON so consumer code that reads them can
  # be exercised.
  @spec store_lines(
          Store.t(),
          binary(),
          [LineProtocolParser.line_result()],
          InfluxElixir.Client.Local.profile()
        ) ::
          InfluxElixir.Client.write_result()
  defp store_lines(table, database, lines, :v2) do
    case for({:error, line_error} <- lines, do: line_error) do
      [] -> store_v2_points(table, database, lines)
      errors -> {:error, v2_parse_error(errors)}
    end
  end

  defp store_lines(table, database, lines, _v3) do
    {errors, accepted} = check_v3_lines(table, database, lines)
    Store.store_points(table, database, accepted)
    if errors == [], do: {:ok, :written}, else: {:error, partial_write_error(errors)}
  end

  # Every line that fails to parse is reported, joined by newlines.
  @spec v2_parse_error([map()]) :: map()
  defp v2_parse_error(errors) do
    message =
      Enum.map_join(errors, "\n", fn %{error_message: reason, line: line} ->
        "unable to parse '#{line}': #{reason}"
      end)

    %{status: 400, body: Jason.encode!(%{"code" => "invalid", "message" => message})}
  end

  # The lines InfluxDB 3 accepts, in order, and the errors of those it
  # rejects (newest first): a line is checked against the schema as the lines
  # before it have left it.
  @spec check_v3_lines(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          {[map()], [LineProtocolParser.point()]}
  defp check_v3_lines(table, database, lines) do
    {errors, accepted, _known} =
      Enum.reduce(lines, {[], [], %{}}, fn
        {:error, line_error}, {errors, accepted, known} ->
          {[line_error | errors], accepted, known}

        {:ok, point, number, line}, {errors, accepted, known} ->
          case check_schema(table, database, point, :v3, known) do
            {:ok, known} ->
              {errors, [strip_uint_markers(point) | accepted], known}

            {:error, message} ->
              {[LineProtocolParser.schema_error(message, number, line) | errors], accepted, known}
          end
      end)

    {errors, Enum.reverse(accepted)}
  end

  @spec partial_write_error([map()]) :: map()
  defp partial_write_error(errors) do
    %{
      status: 400,
      body:
        Jason.encode!(%{
          "error" => "partial write of line protocol occurred",
          "data" => errors |> Enum.reverse() |> Enum.map(&Map.delete(&1, :line))
        })
    }
  end

  # InfluxDB 2 maps a payload's points onto shards first and drops the ones
  # older than the bucket's retention (verified): `now - retention` is the
  # lower bound, and a point before it never reaches a shard — it registers
  # no field and is dropped whatever else is wrong with it.
  #
  # The rest are written in groups, one per shard group (verified): a point
  # it drops is counted, and the message it answers with is the first drop
  # of one group that dropped any, counting only that group's drops. The
  # engine's choice among several failing groups varies between identical
  # writes (verified; usually the earliest); the double takes the earliest,
  # whatever order the payload gave the groups in. A point is dropped
  # for a field type that conflicts with the stored one and for having no
  # field but `time`. The retention drops are reported only when no group
  # dropped anything (verified): the group's message replaces them.
  @spec store_v2_points(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          InfluxElixir.Client.write_result()
  defp store_v2_points(table, database, lines) do
    retention = Buckets.retention(table, database)
    shard_ns = Buckets.shard_group_seconds(retention) * 1_000_000_000
    lower_bound = Store.now_ns() - retention * 1_000_000_000

    {failures, expired, accepted, _known} =
      Enum.reduce(lines, {[], [], [], %{}}, fn
        {:ok, %{unreadable: true}, _number, _line}, state ->
          state

        {:ok, %{timestamp: timestamp} = point, _number, _line},
        {failures, expired, accepted, known}
        when retention > 0 and timestamp < lower_bound ->
          {failures, [point | expired], accepted, known}

        {:ok, point, _number, _line}, {failures, expired, accepted, known} ->
          group = Integer.floor_div(point.timestamp, shard_ns)

          case store_v2_point(table, database, point, Buckets.scope(point, group), known) do
            {:ok, known} ->
              {failures, expired, [strip_uint_markers(point) | accepted], known}

            {:dropped, reason, known} ->
              {[{group, reason} | failures], expired, accepted, known}
          end
      end)

    Store.store_points(table, database, Enum.reverse(accepted))

    case {failures, expired} do
      {[], []} ->
        {:ok, :written}

      {[], expired} ->
        v2_retention_result(expired, database, retention, lower_bound)

      {failures, _expired} ->
        v2_write_result(Enum.reverse(failures))
    end
  end

  # InfluxDB 2 types a field per shard group (verified): the same field may
  # be an integer in one week and a float in another. The schema of a group
  # is kept under the measurement and the group, joined by a NUL.
  @spec store_v2_point(Store.t(), binary(), LineProtocolParser.point(), binary(), map()) ::
          {:ok, map()} | {:dropped, term(), map()}
  defp store_v2_point(_table, _database, %{fields: fields} = point, _scope, known)
       when map_size(fields) == 0,
       do: {:dropped, {:invalid_name, point.measurement}, known}

  defp store_v2_point(table, database, point, scope, known) do
    case check_schema(table, database, point, {:v2, scope}, known) do
      {:ok, known} ->
        {:ok, known}

      {:error, conflict} ->
        {:dropped, conflict, known}
    end
  end

  # The 422 for points older than the retention: the count, the oldest and
  # the newest of them (the first one met on a tie) by series key and time,
  # and the lower bound, all as the engine words them (verified).
  @spec v2_retention_result([LineProtocolParser.point()], binary(), pos_integer(), integer()) ::
          InfluxElixir.Client.write_result()
  defp v2_retention_result(expired, database, retention, lower_bound) do
    expired = Enum.reverse(expired)

    oldest =
      Enum.reduce(expired, fn point, kept ->
        if point.timestamp < kept.timestamp, do: point, else: kept
      end)

    newest =
      Enum.reduce(expired, fn point, kept ->
        if point.timestamp > kept.timestamp, do: point, else: kept
      end)

    bound = rfc3339_nano(lower_bound)

    drop = fn which, point ->
      "#{which} point #{series_key(point)} at #{rfc3339_nano(point.timestamp)} dropped because " <>
        "it violates a Retention Policy Lower Bound at #{bound}"
    end

    message =
      "failure writing points to database: partial write: dropped #{length(expired)} points " <>
        "outside retention policy of duration #{go_duration(retention)} - " <>
        "#{drop.("oldest", oldest)}, #{drop.("newest", newest)} dropped=#{length(expired)} " <>
        "for database: #{Buckets.hex_id(database)} for retention policy: autogen"

    {:error,
     %{
       status: 422,
       body: Jason.encode!(%{"code" => "unprocessable entity", "message" => message})
     }}
  end

  # Go's `time.Duration` string for a whole number of seconds of an hour or
  # more: `2h0m0s`.
  @spec go_duration(pos_integer()) :: binary()
  defp go_duration(seconds) do
    "#{div(seconds, 3600)}h#{div(rem(seconds, 3600), 60)}m#{rem(seconds, 60)}s"
  end

  # Go's RFC 3339 with nanoseconds: the fraction only as far as it is not
  # zero.
  @spec rfc3339_nano(integer()) :: binary()
  defp rfc3339_nano(ns) do
    stamp =
      ns
      |> Integer.floor_div(1_000_000_000)
      |> DateTime.from_unix!()
      |> DateTime.to_iso8601()
      |> String.trim_trailing("Z")

    case Integer.mod(ns, 1_000_000_000) do
      0 ->
        stamp <> "Z"

      fraction ->
        digits = fraction |> Integer.to_string() |> String.pad_leading(9, "0")
        stamp <> "." <> String.trim_trailing(digits, "0") <> "Z"
    end
  end

  # A point's series key as the engine prints it: the measurement and the
  # tags sorted by key, with the line protocol's escapes.
  @spec series_key(LineProtocolParser.point()) :: binary()
  defp series_key(point) do
    tags =
      point.tags
      |> Enum.sort()
      |> Enum.map_join(fn {key, value} -> "," <> escape_key(key) <> "=" <> escape_key(value) end)

    String.replace(point.measurement, [",", " "], &("\\" <> &1)) <> tags
  end

  @spec escape_key(binary()) :: binary()
  defp escape_key(text), do: String.replace(text, [",", "=", " "], &("\\" <> &1))

  @spec v2_write_result([{integer(), term()}]) :: InfluxElixir.Client.write_result()
  defp v2_write_result(failures) do
    {earliest, _reason} = Enum.min_by(failures, &elem(&1, 0))
    [first | _rest] = reasons = for {^earliest, reason} <- failures, do: reason

    message =
      "failure writing points to database: partial write: " <>
        v2_drop_reason(first) <> " dropped=#{length(reasons)}"

    {:error,
     %{
       status: 422,
       body: Jason.encode!(%{"code" => "unprocessable entity", "message" => message})
     }}
  end

  @spec v2_drop_reason(term()) :: binary()
  defp v2_drop_reason({:invalid_name, measurement}) do
    ~s|invalid field name: input field "time" on measurement "#{measurement}" is invalid|
  end

  defp v2_drop_reason({field, measurement, existing, got}) do
    ~s|field type conflict: input field "#{field}" on measurement "#{measurement}" is | <>
      "type #{got}, already exists as type #{existing}"
  end

  # v3 Core/Enterprise auto-create databases on write; v2 requires pre-existing
  @spec ensure_database(Store.t(), binary(), InfluxElixir.Client.Local.profile()) ::
          :ok | {:error, term()}
  defp ensure_database(table, database, profile) when profile in [:v3_core, :v3_enterprise] do
    Store.create_database(table, database, &DatabaseRules.check_new(database, &1, profile))
  end

  # v2 writes target buckets, so anything registered via `create_bucket/3` is a
  # valid target. Names seeded through `databases:` at start are accepted too,
  # so a v2 connection can be prepared either way.
  defp ensure_database(table, bucket, :v2) do
    cond do
      Store.bucket?(table, bucket) ->
        :ok

      Store.database?(table, bucket) ->
        :ok

      true ->
        # The engine's answer for a bucket that does not exist (verified).
        {:error,
         %{
           status: 404,
           body:
             Jason.encode!(%{
               "code" => "not found",
               "message" => "bucket \"#{bucket}\" not found"
             })
         }}
    end
  end

  # `accept_partial: false` and `no_sync:` are InfluxDB 3 write parameters

  # (`HTTP.write/3` sends them as `&accept_partial=false`, `&no_sync=true`);
  # the engine refuses anything but `true` / `false` (verified). `no_sync`
  # changes durability only, which the double does not have, so it is
  # accepted and changes nothing. InfluxDB 2's endpoint has neither.
  @spec write_flag(keyword(), atom(), boolean(), InfluxElixir.Client.Local.profile()) ::
          {:ok, boolean()} | {:error, map()}
  defp write_flag(_opts, _key, default, :v2), do: {:ok, default}

  defp write_flag(opts, key, default, _v3) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) ->
        {:ok, value}

      _other ->
        {:error, %{status: 400, body: "serde error: provided string was not `true` or `false`"}}
    end
  end

  # `accept_partial: false` (verified against InfluxDB 3): the first bad
  # line in line order — a parse error or a schema conflict, including one
  # against an earlier line of the same payload — rejects the whole payload
  # and nothing is stored, not even the schema; the body is
  # `{"error": "line protocol parsing error", "data": {one line error}}`.
  # Every line is checked against the stored schema plus the payload's
  # pending columns before anything is written.
  @spec store_lines_atomically(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          InfluxElixir.Client.write_result()
  defp store_lines_atomically(table, database, lines) do
    case first_line_error(table, database, lines) do
      nil ->
        store_lines(table, database, lines, :v3_core)

      line_error ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "error" => "line protocol parsing error",
               "data" => Map.delete(line_error, :line)
             })
         }}
    end
  end

  @spec first_line_error(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          LineProtocolParser.line_error() | nil
  defp first_line_error(table, database, lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn
      {:error, line_error}, _pending ->
        {:halt, {:error, line_error}}

      {:ok, point, number, line}, {:ok, pending} ->
        case dry_check(table, database, point, pending) do
          {:ok, pending} ->
            {:cont, {:ok, pending}}

          {:error, message} ->
            {:halt, {:error, LineProtocolParser.schema_error(message, number, line)}}
        end
    end)
    |> case do
      {:error, line_error} -> line_error
      {:ok, _pending} -> nil
    end
  end

  # The v3 schema checks without registering anything; `pending` holds the
  # kinds the payload's earlier lines would register.
  @spec dry_check(Store.t(), binary(), LineProtocolParser.point(), map()) ::
          {:ok, map()} | {:error, binary()}
  defp dry_check(table, database, point, pending) do
    m = point.measurement

    exists? = fn ->
      Store.table?(table, database, m) or Enum.any?(Map.keys(pending), &match?({^m, _column}, &1))
    end

    with :ok <- reserved_time(point, exists?) do
      point
      |> point_columns(:v3)
      |> Enum.reduce_while({:ok, pending}, fn {column, type}, {:ok, pending} ->
        existing = Map.get(pending, {m, column}) || Store.column_kind(table, database, m, column)

        if existing in [nil, type],
          do: {:cont, {:ok, Map.put(pending, {m, column}, type)}},
          else: {:halt, {:error, conflict(:v3, column, point, existing, type)}}
      end)
    end
  end

  # InfluxDB 3 reserves `time` for the timestamp column. The wording
  # depends on whether the table exists (verified): a new table refuses
  # the line outright, an existing one reports a column-type conflict.
  #
  # `known` holds the kinds this write has already confirmed or registered,
  # `{measurement, column} => kind`: a kind never changes once set, so the
  # store is asked only about a column the write has not met yet.
  @spec check_schema(
          Store.t(),
          binary(),
          LineProtocolParser.point(),
          :v3 | {:v2, binary()},
          map()
        ) ::
          {:ok, map()} | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_schema(table, database, point, :v3, known) do
    case reserved_time(point, fn -> Store.table?(table, database, point.measurement) end) do
      :ok -> check_column_types(table, database, point, :v3, point.measurement, known)
      {:error, _message} = error -> error
    end
  end

  defp check_schema(table, database, point, {:v2, scope}, known),
    do: check_column_types(table, database, point, :v2, scope, known)

  # `table_exists?` is asked only for a point that names `time`.
  @spec reserved_time(LineProtocolParser.point(), (-> boolean())) :: :ok | {:error, binary()}
  defp reserved_time(%{tags: tags, fields: fields}, table_exists?) do
    cond do
      Map.has_key?(tags, "time") ->
        reserved_time_error(table_exists?.(), "iox::column_type::tag")

      Map.has_key?(fields, "time") ->
        reserved_time_error(
          table_exists?.(),
          LineProtocolParser.column_type(:field, Map.fetch!(fields, "time"))
        )

      true ->
        :ok
    end
  end

  @spec reserved_time_error(boolean(), binary()) :: {:error, binary()}
  defp reserved_time_error(table_exists?, got) do
    if table_exists? do
      {:error,
       "invalid column type for column 'time', expected iox::column_type::timestamp, got " <>
         got}
    else
      {:error, "'time' is a reserved column"}
    end
  end

  # The measurement's schema, one ETS object per column so the first writer
  # of a column fixes its kind atomically (`insert_new`) and a concurrent
  # writer never loses a column. InfluxDB 3 types tags and fields in one
  # namespace and reports a conflict with its column-type wording; InfluxDB
  # 2 types fields only and reports `{field, measurement, existing, got}`.
  @spec check_column_types(
          Store.t(),
          binary(),
          LineProtocolParser.point(),
          LineProtocolParser.dialect(),
          binary(),
          map()
        ) :: {:ok, map()} | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_column_types(table, database, point, dialect, m, known) do
    point
    |> point_columns(dialect)
    |> Enum.reduce_while({:ok, known}, fn {column, type}, {:ok, known} ->
      case Map.fetch(known, {m, column}) do
        {:ok, ^type} ->
          {:cont, {:ok, known}}

        {:ok, existing} ->
          {:halt, {:error, conflict(dialect, column, point, existing, type)}}

        :error ->
          case Store.register_column(table, database, m, column, type) do
            :ok ->
              {:cont, {:ok, Map.put(known, {m, column}, type)}}

            {:conflict, existing} ->
              {:halt, {:error, conflict(dialect, column, point, existing, type)}}
          end
      end
    end)
  end

  # The columns a point types, as `{column, kind}`: InfluxDB 3 types tags
  # and fields in one namespace, InfluxDB 2 types fields only.
  @spec point_columns(LineProtocolParser.point(), LineProtocolParser.dialect()) :: [
          {binary(), binary()}
        ]
  defp point_columns(point, dialect) do
    tags =
      if dialect == :v3,
        do:
          Enum.map(point.tags, fn {k, _v} -> {k, LineProtocolParser.column_type(:tag, nil)} end),
        else: []

    tags ++
      Enum.map(point.fields, fn {k, v} -> {k, LineProtocolParser.column_type(:field, v)} end)
  end

  @spec conflict(
          LineProtocolParser.dialect(),
          binary(),
          LineProtocolParser.point(),
          binary(),
          binary()
        ) ::
          binary() | {binary(), binary(), binary(), binary()}
  defp conflict(:v3, column, _point, existing, type),
    do: "invalid column type for column '#{column}', expected #{existing}, got #{type}"

  defp conflict(:v2, column, point, existing, type) do
    {column, point.measurement, LineProtocolParser.v2_field_type(existing),
     LineProtocolParser.v2_field_type(type)}
  end

  # An unsigned integer is stored as the integer; the marker exists for the
  # schema check alone.
  @spec strip_uint_markers(LineProtocolParser.point()) :: LineProtocolParser.point()
  defp strip_uint_markers(point) do
    fields =
      Map.new(point.fields, fn
        {k, {:uint, n}} -> {k, n}
        {k, v} -> {k, v}
      end)

    %{point | fields: fields}
  end
end
