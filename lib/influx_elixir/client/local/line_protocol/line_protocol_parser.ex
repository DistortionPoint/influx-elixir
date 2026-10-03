defmodule InfluxElixir.Client.Local.LineProtocolParser do
  @moduledoc false
  # Line protocol parser for `InfluxElixir.Client.Local`.
  #
  # Turns a line-protocol payload into point maps, honouring the escaping rules
  # of the format (escaped spaces, commas, equals signs, backslashes and quotes)
  # and the write precision. Each line is parsed on its own so a caller can
  # store the good lines and report the bad ones, which is what InfluxDB 3
  # does ("partial write of line protocol occurred").
  #
  # Per-line rules verified against InfluxDB 3 Core: an integer must fit in
  # 64 bits (`u` marks an unsigned one), `time` is a reserved column, and a
  # key cannot be both a tag and a field on one line.
  #
  # The two engines do not parse alike, and each is parsed as it parses, so
  # that a line they refuse is refused with their words:
  #
  #   * InfluxDB 3 (`:v3`) reads `series SP+ fields [SP+ timestamp] SP*`; what
  #     is left is "Could not parse entire line. Found trailing content" and
  #     a first field that does not parse is "No fields were provided". The
  #     grammar is in the comments above `parse_v3/2`.
  #   * InfluxDB 2 (`:v2`) is a port of Go's `models.ParsePoints` scanners
  #     (`scanKey`, `scanFields`, `scanNumber`, `scanBoolean`, `scanTime`),
  #     whose errors name the scanner that failed: `invalid field format`,
  #     `missing field value`, `invalid number`, `bad timestamp`, ... See
  #     `parse_v2/2`.

  alias InfluxElixir.Client.Local.{
    LineProtocolError,
    LineProtocolEscape,
    LineProtocolNumber,
    LineProtocolScanner
  }

  @typedoc """
  A parsed point: fields and tags as string-keyed maps, timestamp in ns.
  `:unreadable` marks a point InfluxDB 2 accepts and then never returns
  (see `InfluxElixir.Client.Local.LineProtocolV2`).
  """
  @type point :: %{
          required(:measurement) => binary(),
          required(:tags) => %{binary() => binary()},
          required(:fields) => %{binary() => term()},
          required(:timestamp) => integer() | nil,
          optional(:unreadable) => true
        }

  @typedoc """
  One rejected line, in the shape InfluxDB 3's partial-write response lists
  (the original line is truncated to 20 characters, as the engine does).
  """
  @type line_error :: %{
          error_message: binary(),
          line_number: pos_integer(),
          original_line: binary(),
          line: binary()
        }

  @typedoc "A line's outcome: the point with its line number and text, or the error."
  @type line_result :: {:ok, point(), pos_integer(), binary()} | {:error, line_error()}

  @typedoc """
  Whose rules apply. InfluxDB 3 refuses a key that is
  both tag and field (and, in the store, `time` as a column); InfluxDB 2
  drops a `time` field silently and lets a
  tag and a field share a name.
  """
  @type dialect :: :v3 | :v2

  @typedoc "The unit numeric timestamps are in; `:auto` guesses it from the magnitude."
  @type precision :: :nanosecond | :microsecond | :millisecond | :second | :auto

  @doc """
  Parses a line-protocol payload line by line.

  Blank lines and `#` comments are skipped. `precision` is a `t:precision/0`:
  a unit scales numeric timestamps to nanoseconds and `:auto` guesses the unit
  from the magnitude as InfluxDB 3 does. A point without a timestamp keeps `nil`; the
  caller assigns the server time.

  A line ends at a newline that is not inside a string field value, found as
  both engines find it (see "Lines" below): a newline inside a quoted
  field value is part of the value.

  Returns `{:error, ...}` only for a payload with no lines at all ("incoming
  write was empty" on the engine); every other problem is a per-line
  `{:error, line_error}` in the list. InfluxDB 3 numbers a line among the
  lines that are not blank or comments and echoes, as `original_line`, the
  physical line with that number in the payload; this parser does both
  (verified), so a comment before a bad line shifts the echo.

  ## Lines

  Both engines find the end of a line with Go's `scanLine`: a backslash
  skips the byte after it (a newline too), the first space starts the
  fields, and a quote toggles string state only when an `=` that no comma
  has closed precedes it (`=` and `,` are counted outside strings). A quote
  in a measurement, a tag or a field key therefore means nothing, and one
  after a field value toggles the state as a quote that opens a string does.
  """
  @spec parse_lines(binary(), precision(), dialect()) ::
          {:ok, [line_result()]} | {:error, map()}
  def parse_lines(text, precision, dialect \\ :v3) do
    context = %{precision: precision, dialect: dialect}

    lines =
      text |> LineProtocolScanner.final_newline_off(dialect) |> LineProtocolScanner.split_lines()

    case LineProtocolScanner.parse_all(lines, text, context) do
      [] -> {:error, %{status: 400, body: "incoming write was empty"}}
      results -> {:ok, results}
    end
  end

  @doc """
  Builds a `t:line_error/0` the way InfluxDB 3 reports one. The full line
  is kept under `:line` for InfluxDB 2's report, which quotes it whole.
  """
  @spec line_error(binary(), pos_integer(), binary()) :: line_error()
  defdelegate line_error(message, number, line), to: LineProtocolError

  @doc """
  Builds the `t:line_error/0` for a schema error. InfluxDB 3 does not echo
  the raw line for those but the line as it parsed it (verified): single
  spaces, floats printed shortest and without an exponent (`2.0` → `2`,
  `1e3` → `1000`), strings unquoted, then cut to 20 characters. Parse
  errors echo the physical line (`parse_lines/3`).
  """
  @spec schema_error(binary(), pos_integer(), binary()) :: line_error()
  defdelegate schema_error(message, number, line), to: LineProtocolError

  @doc """
  The engine's name for a column kind: `iox::column_type::tag` or
  `iox::column_type::field::<integer | uinteger | float | string | boolean>`.
  """
  @spec column_type(:tag | :field, term()) :: binary()
  defdelegate column_type(kind, value), to: LineProtocolNumber

  @doc "InfluxDB 2's name for a field type (`integer`, `unsigned`, `float`, `string`, `boolean`)."
  @spec v2_field_type(binary()) :: binary()
  defdelegate v2_field_type(type), to: LineProtocolNumber

  @doc "Undoes line-protocol escaping in a measurement name (`\\ `, `\\,`, `\\\\`)."
  @spec unescape_measurement(binary()) :: binary()
  defdelegate unescape_measurement(name), to: LineProtocolEscape
end
