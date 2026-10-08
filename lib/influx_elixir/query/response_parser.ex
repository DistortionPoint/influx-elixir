defmodule InfluxElixir.Query.ResponseParser do
  @moduledoc """
  Parses InfluxDB query responses in JSON, JSONL, InfluxDB 3 CSV and Flux
  annotated CSV formats, and passes Parquet bodies through untouched.

  ## Type Coercion

    * Timestamps → `DateTime.t()` with microsecond precision. JSON carries no
      column types, so this is by shape and by name: any string in InfluxDB 3's
      zone-less timestamp rendering (`2023-11-14T22:13:20[.fraction]`) is a
      timestamp whatever its column is called (`DATE_BIN` aliases,
      `selector_*(...)['time']`, `MAX(time)`); the zoned RFC3339 form is
      decoded only under `time`, `_time`, `_start` and `_stop`, where v2 emits
      it. A *string field* holding exactly that zone-less shape is decoded
      too — store zoned RFC3339 strings if the distinction matters.
    * JSON / JSONL numbers and booleans keep the types Jason decodes
    * Flux CSV cells are typed from the `#datatype` annotation row when the
      query requested one (`double`, `long`, `unsignedLong`, `boolean`,
      `dateTime:RFC3339[Nano]`); InfluxDB 3's `format: :csv` has no
      annotations, so every cell stays a string. An empty cell is left out
      of the row, as a null column is in JSON: CSV writes a null and an
      empty string alike (InfluxDB 3 writes a one-column row's as `""`,
      an empty line to the parser, and that row is `%{}`).
      A newline inside a value is restored: InfluxDB 2's CSV writer sends
      it as `\\r\\n`
  """

  alias NimbleCSV.RFC4180, as: CSV

  @time_keys ~w(time _time _start _stop)

  @doc """
  Parses a response body based on the specified format.

  ## Parameters

    * `body` - response body binary
    * `format` - one of `:json`, `:jsonl`, `:csv` (InfluxDB 3: one header
      row, then one line per row), `:flux_csv` (InfluxDB 2's annotated CSV:
      tables separated by an empty line, each with its own header),
      `:parquet`

  ## Returns

    * `{:ok, [map()]}` — list of row maps (`{:ok, binary()}` for `:parquet`)
    * `{:error, reason}` — parse failure
  """
  @spec parse(binary(), atom()) :: {:ok, [map()] | binary()} | {:error, term()}
  def parse(body, format \\ :json)

  def parse(body, :json) do
    case Jason.decode(body) do
      {:ok, data} when is_list(data) -> rows(data)
      {:ok, data} when is_map(data) -> {:ok, [coerce_types(data)]}
      {:ok, other} -> {:error, {:unexpected_json, other}}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  def parse(body, :jsonl) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, row} when is_map(row) -> {:cont, {:ok, [coerce_types(row) | acc]}}
        {:ok, other} -> {:halt, {:error, {:unexpected_json, other}}}
        {:error, reason} -> {:halt, {:error, {:jsonl_parse_error, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  def parse(body, :csv), do: csv(&parse_csv/1, body)

  def parse(body, :flux_csv), do: csv(&parse_flux_csv/1, body)

  def parse(body, :parquet), do: {:ok, body}

  def parse(_body, format), do: {:error, {:unsupported_format, format}}

  @doc """
  Coerces known value types in a row map.

  Converts timestamp strings to `DateTime` (see "Type Coercion" in the
  moduledoc for which strings count as timestamps); leaves everything else
  as-is.
  """
  @spec coerce_types(map()) :: map()
  def coerce_types(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {key, coerce_value(key, value)} end)
  end

  # Every element of a JSON array of rows must be an object: a proxy's or a
  # truncated body is an error for the caller, not a crash.
  @spec rows(list()) :: {:ok, [map()]} | {:error, term()}
  defp rows(data) do
    if Enum.all?(data, &is_map/1),
      do: {:ok, Enum.map(data, &coerce_types/1)},
      else: {:error, {:unexpected_json, data |> Enum.reject(&is_map/1) |> hd()}}
  end

  # A body CSV cannot read (a quote left open, a stray quote inside a cell) is an error. Text
  # that reads as CSV, an HTML page among it, is rows like any other.
  @spec csv((binary() -> [map()]), binary()) :: {:ok, [map()]} | {:error, term()}
  defp csv(parse, body) do
    {:ok, parse.(body)}
  rescue
    error in NimbleCSV.ParseError -> {:error, {:csv_parse_error, Exception.message(error)}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # InfluxDB 3 renders every timestamp column without a zone
  # ("2023-11-14T22:13:20.123456789"), which `DateTime.from_iso8601/1`
  # rejects; such values are UTC. The JSON body has no schema, so that shape
  # is the only evidence a non-`time` column (a `DATE_BIN` alias, a
  # `selector_*['time']`) is a timestamp at all. v2 Flux timestamps carry a
  # "Z" and are only decoded under the well-known time keys. Fractional
  # seconds beyond microseconds are truncated by the calendar types.
  @datafusion_timestamp ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?$/

  @spec coerce_value(String.t(), term()) :: term()
  defp coerce_value(key, value) when key in @time_keys and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> microsecond_precision(dt)
      {:error, _not_zoned} -> coerce_naive(value)
    end
  end

  defp coerce_value(_key, value) when is_binary(value), do: coerce_naive(value)

  # Structs (`selector_last(v, time)` is `%{"time" => ..., "value" => ...}`)
  # and lists (`array_agg(time)`) are coerced inside too, so a timestamp is
  # a DateTime at any depth — as it is when the Flight transport decodes
  # the same values.
  defp coerce_value(_key, value) when is_map(value) and not is_struct(value),
    do: coerce_types(value)

  defp coerce_value(key, value) when is_list(value), do: Enum.map(value, &coerce_value(key, &1))
  defp coerce_value(_key, value), do: value

  # Only a string shaped `dddd-dd-ddT...` is worth the regex; every other
  # string cell (the common case) is returned after one pattern match.
  @spec coerce_naive(binary()) :: DateTime.t() | binary()
  defp coerce_naive(
         <<_year::binary-size(4), ?-, _month::binary-size(2), ?-, _day::binary-size(2), ?T,
           _rest::binary>> = value
       ) do
    with true <- Regex.match?(@datafusion_timestamp, value),
         {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      naive |> DateTime.from_naive!("Etc/UTC") |> microsecond_precision()
    else
      _not_a_timestamp -> value
    end
  end

  defp coerce_naive(value), do: value

  # Every timestamp the library returns carries microsecond precision, so a
  # value from JSON ("…:20" → precision 0) equals the same instant from
  # Flight or Client.Local (`DateTime.from_unix!/2` → precision 6). Two
  # DateTimes that differ only in precision are not `==`.
  @doc false
  @spec microsecond_precision(DateTime.t()) :: DateTime.t()
  def microsecond_precision(%DateTime{microsecond: {us, _precision}} = dt),
    do: %{dt | microsecond: {us, 6}}

  # InfluxDB 3's CSV is one table: a header row, then one line per row.
  # Every line after the header is a row, even one that reads as empty:
  # the engine writes a one-column row whose value is null or "" as `""`
  # (verified), which NimbleCSV reads as `[""]` — it used to be taken for
  # a table separator, dropping that row and reading the next as a header.
  @spec parse_csv(binary()) :: [map()]
  defp parse_csv(body) do
    case CSV.parse_string(body, skip_headers: false) do
      [header | rows] ->
        columns = Enum.map(header, &{&1, nil})
        Enum.map(rows, &csv_row(columns, &1))

      [] ->
        []
    end
  end

  # Flux annotated CSV: tables are separated by an empty line; each table
  # starts with optional `#`-prefixed annotation rows, then a header row.
  # The first column is the annotation column (empty header) and is dropped.
  # A Flux row always has that column and `result` and `table`, so a line
  # that reads as `[""]` is only ever a separator here.
  # Lines end in CRLF and cells may be quoted — NimbleCSV handles both.
  @spec parse_flux_csv(binary()) :: [map()]
  defp parse_flux_csv(body) do
    body
    |> CSV.parse_string(skip_headers: false)
    |> Enum.chunk_by(&blank_row?/1)
    |> Enum.reject(fn [row | _rest] -> blank_row?(row) end)
    |> Enum.flat_map(&parse_csv_table/1)
  end

  @spec blank_row?([binary()]) :: boolean()
  defp blank_row?([]), do: true
  defp blank_row?([""]), do: true
  defp blank_row?(_row), do: false

  @spec parse_csv_table([[binary()]]) :: [map()]
  defp parse_csv_table(rows) do
    case Enum.split_while(rows, &annotation_row?/1) do
      {annotations, [header | data]} ->
        datatypes = annotation(annotations, "#datatype")
        columns = Enum.zip(header, datatypes ++ List.duplicate(nil, length(header)))
        Enum.map(data, &csv_row(columns, &1))

      {_annotations_only, []} ->
        []
    end
  end

  @spec annotation_row?([binary()]) :: boolean()
  defp annotation_row?([first | _rest]), do: String.starts_with?(first, "#")
  defp annotation_row?(_row), do: false

  # The annotation row's first cell is its name ("#datatype"); the rest line
  # up with the header columns after the annotation column.
  @spec annotation([[binary()]], binary()) :: [binary() | nil]
  defp annotation(rows, name) do
    case Enum.find(rows, fn [first | _rest] -> first == name end) do
      [_name | types] -> [nil | types]
      nil -> []
    end
  end

  @spec csv_row([{binary(), binary() | nil}], [binary()]) :: map()
  defp csv_row(columns, values) do
    columns
    |> Enum.zip(values)
    |> Enum.reject(fn {{name, _type}, value} -> name == "" or value == "" end)
    |> Map.new(fn {{name, type}, value} -> {name, cast(type, name, restore_newlines(value))} end)
  end

  # InfluxDB 2 writes its CSV with Go's csv.Writer in CRLF mode, which
  # turns every "\n" inside a quoted value into "\r\n" (and drops a bare
  # "\r"; verified). Undoing it gives back the stored string — `s="l1\nl2"`
  # reads as "l1\nl2", as Client.Local returns it — for any value that had
  # no "\r" of its own; those the server has already altered.
  @spec restore_newlines(binary()) :: binary()
  defp restore_newlines(value) do
    if :binary.match(value, "\r\n") == :nomatch,
      do: value,
      else: String.replace(value, "\r\n", "\n")
  end

  @spec cast(binary() | nil, binary(), binary()) :: term()
  defp cast("double", _key, value), do: parse_number(Float.parse(value), value)
  defp cast("long", _key, value), do: parse_number(Integer.parse(value), value)
  defp cast("unsignedLong", _key, value), do: parse_number(Integer.parse(value), value)
  defp cast("boolean", _key, "true"), do: true
  defp cast("boolean", _key, "false"), do: false
  defp cast("dateTime:" <> _layout, key, value), do: coerce_value(key, value)
  defp cast(_type, key, value), do: coerce_value(key, value)

  @spec parse_number({number(), binary()} | :error, binary()) :: number() | binary()
  defp parse_number({number, ""}, _raw), do: number
  defp parse_number(_other, raw), do: raw
end
