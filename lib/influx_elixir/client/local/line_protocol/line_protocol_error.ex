defmodule InfluxElixir.Client.Local.LineProtocolError do
  @moduledoc false
  # The errors of a line, as each engine reports them: the partial-write entry of
  # InfluxDB 3, and for a schema error the line as the engine renders it.

  alias InfluxElixir.Client.Local.{
    Format,
    LineProtocolEscape,
    LineProtocolParser,
    LineProtocolV3
  }

  @typep line_error :: LineProtocolParser.line_error()

  @doc """
  Builds a `t:line_error/0` the way InfluxDB 3 reports one. The full line
  is kept under `:line` for InfluxDB 2's report, which quotes it whole.
  """
  @spec line_error(binary(), pos_integer(), binary()) :: line_error()
  def line_error(message, number, line) do
    %{error_message: message, line_number: number, original_line: echo(line), line: line}
  end

  # What InfluxDB 3 echoes of a line: without the `\r` of a CRLF ending (one
  # inside the line stays, verified), cut to 20 characters.
  @spec echo(binary()) :: binary()
  @doc false
  def echo(line), do: line |> String.replace_suffix("\r", "") |> cut()

  @spec cut(binary()) :: binary()
  @doc false
  def cut(line), do: String.slice(line, 0, 20)

  @doc """
  Builds the `t:line_error/0` for a schema error. InfluxDB 3 does not echo
  the raw line for those but the line as it parsed it (verified): single
  spaces, floats printed shortest and without an exponent (`2.0` → `2`,
  `1e3` → `1000`), strings unquoted, then cut to 20 characters. Parse
  errors echo the physical line (`parse_lines/3`).
  """
  @spec schema_error(binary(), pos_integer(), binary()) :: line_error()
  def schema_error(message, number, line) do
    %{line_error(message, number, line) | original_line: line |> render_line() |> echo()}
  end

  # The engine's rendering of a line that parsed: the series, the fields and
  # the timestamp, joined by single spaces. A name is written as it was, with
  # an `=` or `,` it held unescaped escaped, a string as its raw text and a
  # number as it parsed prints. The line is read by the grammar that
  # accepted it.
  @spec render_line(binary()) :: binary()
  defp render_line(line) do
    trimmed = LineProtocolEscape.trim_leading_blanks(line)

    with {:ok, measurement, tags, after_series} <- LineProtocolV3.v3_series(trimmed),
         fields_text = LineProtocolV3.skip_spaces(after_series),
         {:ok, _fields, rest} <- LineProtocolV3.v3_fields(fields_text),
         {:ok, timestamp} <- LineProtocolV3.v3_timestamp(rest) do
      consumed = binary_part(fields_text, 0, byte_size(fields_text) - byte_size(rest))

      series =
        measurement <>
          Enum.map_join(tags, fn {key, value} ->
            "," <> escape_raw(key, ?,) <> "=" <> escape_raw(value, ?=)
          end)

      Enum.join([series, render_fields(consumed, []) | List.wrap(timestamp)], " ")
    else
      _unparsed -> line
    end
  end

  # The fields of text the grammar has accepted, as `key=value` joined by commas.
  @spec render_fields(binary(), [binary()]) :: binary()
  defp render_fields("", shown), do: shown |> Enum.reverse() |> Enum.join(",")

  defp render_fields(text, shown) do
    key_size = LineProtocolV3.key_end(text)
    <<key::binary-size(key_size), ?=, value::binary>> = text
    {rendered, rest} = render_field_value(value)
    entry = escape_raw(key, ?,) <> "=" <> rendered

    case rest do
      <<?,, next::binary>> -> render_fields(next, [entry | shown])
      _end -> render_fields("", [entry | shown])
    end
  end

  @spec render_field_value(binary()) :: {binary(), binary()}
  defp render_field_value(<<?", text::binary>>) do
    raw_size = LineProtocolV3.quote_end(text)
    <<raw::binary-size(raw_size), ?", rest::binary>> = text
    {raw, rest}
  end

  defp render_field_value(text) do
    {:ok, value, rest} = LineProtocolV3.v3_value(text)
    {render_value(value), rest}
  end

  # `name` with each `char` that no backslash escapes escaped.
  @spec escape_raw(binary(), byte()) :: binary()
  defp escape_raw(name, char), do: escape_raw(name, char, <<>>)

  defp escape_raw(<<?\\, c, rest::binary>>, char, acc),
    do: escape_raw(rest, char, <<acc::binary, ?\\, c>>)

  defp escape_raw(<<char, rest::binary>>, char, acc),
    do: escape_raw(rest, char, <<acc::binary, ?\\, char>>)

  defp escape_raw(<<c, rest::binary>>, char, acc), do: escape_raw(rest, char, <<acc::binary, c>>)
  defp escape_raw(<<>>, _char, acc), do: acc

  @spec render_value(term()) :: binary()
  defp render_value({:uint, n}), do: "#{n}u"
  defp render_value(n) when is_integer(n), do: "#{n}i"
  # Rust's `f64` Display, which the planner's literals share.
  defp render_value(f) when is_float(f), do: Format.render_decimal(f)
  defp render_value(value), do: to_string(value)
end
