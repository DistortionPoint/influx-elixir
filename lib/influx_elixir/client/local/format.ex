defmodule InfluxElixir.Client.Local.Format do
  @moduledoc """
  Answers a query's `format:` option for `InfluxElixir.Client.Local` as
  `Client.HTTP` answers it from InfluxDB 3 (verified against Core):

    * `:json` / `:jsonl` (the default) — the rows as they are
    * `:csv` — the rows as the engine's CSV parses: every value a string,
      rendered as the engine renders it (`1.5` → `"1.5"`, `1.0e16` →
      `"1e16"`, `true` → `"true"`), an empty value absent like a null one;
      timestamps stay `DateTime`s. The engine cannot write a nested value
      (`array_agg`, a `selector_*` struct) as CSV: it has sent `200` and
      closes the connection, so the answer is the same
      `{:connection_error, %Mint.TransportError{reason: :closed}}`
    * `:parquet` — refused by name: the double holds no Parquet writer
    * `:pretty` / `:json_lines` and their string forms — the engine accepts
      them but the client cannot parse them: `{:unsupported_format, format}`
    * anything else — the engine's 400 for an unknown variant, ending in the
      ` at line 1 column N` of its JSON parser: N is the byte, in the request
      body `Client.HTTP` sends (`{"db":"<database>","format":"<format>",...}`,
      keys in that order), where the format's string ends. It depends on the
      database name, which `answer/4` takes.

  The engine reads the request's fields in that order, `db`, `format`,
  `params`, `q`, before it plans the query: an unknown format is its 400
  whatever the query, as is the refusal of `:parquet` here, and after it a
  parameter that is a JSON object or array (`answer/4`, which names the byte
  where the engine's parser stops). The other formats are answered from the
  query's result.
  """

  alias InfluxElixir.Client.QueryParams

  @engine_formats ~w(parquet csv pretty json json_lines jsonl)

  @doc """
  Runs the query (`run` returns `{:ok, rows}` or an error) and answers in
  `format`, or with the error `Client.HTTP` returns for that format.

  `database` is the one the request names, or `nil` when it names none
  (`Client.HTTP` then leaves `db` out of the body); the position in an
  unknown format's error counts the body's bytes. `params` are the query's
  parameters as `InfluxElixir.Client.QueryParams.normalize/1` returns them.
  """
  @spec answer(
          term(),
          (-> {:ok, [map()]} | {:error, term()}),
          binary() | nil,
          QueryParams.t()
        ) :: {:ok, [map()]} | {:error, term()}
  def answer(format, run, database, params \\ %{}) do
    with :ok <- accept(format, database),
         :ok <- check_params(params, format, database),
         {:ok, rows} <- run.() do
      render(rows, format)
    end
  end

  @spec accept(term(), binary() | nil) :: :ok | {:error, map()}
  defp accept(:parquet, _database) do
    {:error,
     %{
       status: 400,
       body:
         "Client.Local: format: :parquet is not supported by the test double; " <>
           "cover Parquet in the integration tier"
     }}
  end

  defp accept(format, database) do
    if to_string(format) in @engine_formats,
      do: :ok,
      else: {:error, %{status: 400, body: unknown_variant(format, database)}}
  end

  @doc """
  The engine's 400 for the request's parameters, or `:ok`. The engine reads
  a parameter as null, boolean, number or string, and its parser stops at the
  first object or array, at the end of that value, or one byte on when the
  value is the last parameter (the closing brace is read with it); at the end
  of a number it cannot read (`number out of range`). The position counts the
  bytes of the body `Client.HTTP` sends, which `database` and `format` (`nil`
  when the request carries none) shape.
  """
  @spec check_params(QueryParams.t(), term(), binary() | nil) :: :ok | {:error, map()}
  def check_params(params, format, database) do
    entries = Map.to_list(params)

    case Enum.find_index(entries, fn {_name, value} -> QueryParams.problem(value) != nil end) do
      nil ->
        :ok

      index ->
        {_name, value} = Enum.at(entries, index)
        kept = Enum.take(entries, index + 1)
        read = byte_size(request_head(format, database)) + byte_size(encode_entries(kept))
        last? = index == length(entries) - 1
        {:error, %{status: 400, body: params_error(QueryParams.problem(value), read, last?)}}
    end
  end

  @spec params_error(QueryParams.problem(), pos_integer(), boolean()) :: binary()
  defp params_error(:out_of_range, at, _last?),
    do: "serde json error: number out of range at line 1 column #{at}"

  defp params_error(container, at, last?),
    do: unsupported_param(container, if(last?, do: at + 1, else: at))

  @spec unsupported_param(:object | :array, pos_integer()) :: binary()
  defp unsupported_param(:object, at) do
    "serde json error: JSON objects are not supported as query parameters. " <>
      "Expected null, boolean, number, or string at line 1 column #{at}"
  end

  defp unsupported_param(:array, at) do
    "serde json error: JSON arrays are not supported as query parameters. " <>
      "Expected null, boolean, number, or string. at line 1 column #{at}"
  end

  # `{"db":"<database>","format":"<format>","params":{` as `Client.HTTP`
  # writes the start of the request body; a request with no format (an
  # `execute_sql`) has no `format` key.
  @spec request_head(term(), binary() | nil) :: binary()
  defp request_head(format, database) do
    db = if database, do: ~s|"db":#{Jason.encode!(database)},|, else: ""
    format = if format, do: ~s|"format":#{Jason.encode!(to_string(format))},|, else: ""
    "{" <> db <> format <> ~s|"params":{|
  end

  @spec encode_entries([{binary(), term()}]) :: binary()
  defp encode_entries(entries),
    do:
      Enum.map_join(entries, ",", fn {name, value} ->
        Jason.encode!(name) <> ":" <> Jason.encode!(value)
      end)

  @spec render([map()], term()) :: {:ok, [map()]} | {:error, term()}
  defp render(rows, format) when format in [:json, :jsonl], do: {:ok, rows}
  defp render(rows, :csv), do: csv(rows)

  # `format: "csv"` still has the engine write CSV — and fail on a nested
  # value — before the client finds it cannot parse the string format.
  defp render(rows, format) do
    with {:ok, _rows} <- if(format == "csv", do: csv(rows), else: {:ok, rows}) do
      {:error, {:unsupported_format, format}}
    end
  end

  # The parser stops where the format's string ends; the body `Client.HTTP`
  # builds is that string's prefix, closed, minus its closing brace.
  @spec unknown_variant(term(), binary() | nil) :: binary()
  defp unknown_variant(format, database) do
    expected = Enum.map_join(@engine_formats, ", ", &"`#{&1}`")
    body = if database, do: %{"db" => database}, else: %{}
    request = Jason.encode!(Map.put(body, "format", to_string(format)))

    "serde json error: unknown variant `#{format}`, expected one of #{expected} " <>
      "at line 1 column #{byte_size(request) - 1}"
  end

  @spec csv([map()]) :: {:ok, [map()]} | {:error, term()}
  defp csv(rows) do
    if Enum.any?(rows, &nested?/1),
      do: {:error, {:connection_error, %Mint.TransportError{reason: :closed}}},
      else: {:ok, Enum.map(rows, &csv_row/1)}
  end

  @spec nested?(map()) :: boolean()
  defp nested?(row),
    do: Enum.any?(row, fn {_key, value} -> is_list(value) or plain_map?(value) end)

  @spec plain_map?(term()) :: boolean()
  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  # A CSV cell has no null: an empty string and a null are both an empty
  # cell, which the parser leaves out of the row.
  @spec csv_row(map()) :: map()
  defp csv_row(row) do
    for {key, value} <- row, value != "", into: %{}, do: {key, csv_value(value)}
  end

  @spec csv_value(term()) :: term()
  defp csv_value(value) when is_float(value), do: render_float(value)
  defp csv_value(value) when is_integer(value), do: Integer.to_string(value)
  defp csv_value(value) when is_boolean(value), do: Atom.to_string(value)
  defp csv_value(value), do: value

  @doc """
  A float as the engine's CSV writes it: positional notation, with `.0`
  when there is no fraction, for `1.0e-5 <= |x| < 1.0e16`; otherwise the
  shortest digits with an exponent and no `.0` (`1e16`, `1.5e-7`,
  `5e-324`). Erlang's `:short` renders `1.0e15` and `1.0e-5` instead.
  """
  @spec render_float(float()) :: binary()
  def render_float(value), do: signed(value, &render_abs/1)

  @doc """
  A float as the planner prints a `Float64` literal, and as the engine writes
  a field in line protocol: positional notation, the shortest digits that
  read back, no `.0` for a whole number (`1`, `0.1`, `100000000000000000000`,
  `0.0000001`; negative zero is `-0`).
  """
  @spec render_decimal(float()) :: binary()
  def render_decimal(value), do: signed(value, &decimal_abs/1)

  @spec signed(float(), ({binary(), integer()} -> binary())) :: binary()
  defp signed(value, render) do
    sign = if match?(<<1::1, _rest::63>>, <<value::float>>), do: "-", else: ""
    sign <> render.(digits(abs(value)))
  end

  # The value as {digits, point}: 0.<digits> × 10^point, digits without
  # leading or trailing zeros ("" for zero).
  @spec digits(float()) :: {binary(), integer()}
  defp digits(value) do
    {mantissa, exponent} =
      case String.split(:erlang.float_to_binary(value, [:short]), "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    [whole, fraction] = String.split(mantissa, ".")
    all = whole <> fraction
    significant = String.trim_leading(all, "0")
    point = byte_size(whole) + exponent - (byte_size(all) - byte_size(significant))
    {String.trim_trailing(significant, "0"), point}
  end

  @spec decimal_abs({binary(), integer()}) :: binary()
  defp decimal_abs({"", _point}), do: "0"
  defp decimal_abs({digits, point}), do: positional(digits, point)

  @spec render_abs({binary(), integer()}) :: binary()
  defp render_abs({"", _point}), do: "0.0"

  defp render_abs({digits, point}) when point in -4..16 do
    text = positional(digits, point)
    if String.contains?(text, "."), do: text, else: text <> ".0"
  end

  defp render_abs({<<first, rest::binary>>, point}) do
    mantissa = if rest == "", do: <<first>>, else: <<first, ?.>> <> rest
    "#{mantissa}e#{point - 1}"
  end

  # `0.<digits> × 10^point` without an exponent or a trailing `.0`.
  @spec positional(binary(), integer()) :: binary()
  defp positional(digits, point) do
    size = byte_size(digits)

    cond do
      point <= 0 -> "0." <> String.duplicate("0", -point) <> digits
      point >= size -> digits <> String.duplicate("0", point - size)
      true -> binary_part(digits, 0, point) <> "." <> binary_part(digits, point, size - point)
    end
  end
end
