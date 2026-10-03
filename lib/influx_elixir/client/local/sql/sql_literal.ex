defmodule InfluxElixir.Client.Local.SQLLiteral do
  @moduledoc false
  # The literals and names of a SQL text, as DataFusion reads them (verified
  # against InfluxDB 3 Core):
  #
  #   * `'...'` is a string, in which a doubled quote is one quote: a quoted
  #     literal is a string, full stop — re-typing `'08338636'` as an integer
  #     would drop the leading zero and change the type
  #   * `"..."` is always an identifier, never a string: `host = "x"` compares
  #     the column `host` with the column `x`
  #   * a bare `true`, `false` or number is typed; anything else bare is a name
  #   * `$name` is a placeholder; a name is word characters in any script
  #
  # The text reaching here has been through `InfluxElixir.Client.Local.SQLLexer`
  # and `InfluxElixir.Client.Local.SQLIdentifiers`, so a double-quoted token
  # that is left holds a name that needs its quotes.

  alias InfluxElixir.Client.Local.SQLMask

  import InfluxElixir.Client.Local.SQLLimits, only: [is_int64: 1, is_uint64: 1]

  @typedoc "A literal or placeholder as the parser keeps it."
  @type value :: number() | binary() | boolean() | {:param, binary()}

  @doc "`text` as a `'...'` literal, a quote doubled."
  @spec quote_text(binary()) :: binary()
  def quote_text(text), do: "'" <> String.replace(text, "'", "''") <> "'"

  @doc "`'it''s'`'s body is the text `it's`."
  @spec unescape(binary()) :: binary()
  def unescape(body), do: String.replace(body, "''", "'")

  @doc "Whether the text is one `'...'` literal, not two joined by an operator."
  @spec string?(binary()) :: boolean()
  def string?(text), do: Regex.match?(~r/\A'x*'\z/u, SQLMask.mask(text))

  @doc "Whether the text is one `\"...\"` identifier."
  @spec identifier?(binary()) :: boolean()
  def identifier?(text), do: Regex.match?(~r/\A"x*"\z/u, SQLMask.mask(text))

  @doc """
  The text between a literal's quotes, with a doubled quote one quote. The
  quotes are one byte each, so the cut is by bytes, as every offset here is.
  """
  @spec body(binary()) :: binary()
  def body(text), do: text |> binary_part(1, byte_size(text) - 2) |> unescape()

  @doc "The name a `\"...\"` identifier holds, a doubled quote one quote."
  @spec identifier_name(binary()) :: binary()
  def identifier_name(text) do
    text |> binary_part(1, byte_size(text) - 2) |> String.replace("\"\"", "\"")
  end

  @doc """
  How the engine words a column name in an error: bare when it is a lower
  case word, otherwise quoted with its quotes doubled.
  """
  @spec render_identifier(binary()) :: binary()
  def render_identifier(name) do
    if Regex.match?(~r/\A(?:[a-z_][a-z0-9_]*)?\z/, name),
      do: name,
      else: ~s|"#{String.replace(name, "\"", "\"\"")}"|
  end

  @doc """
  How the engine words the name of a relation in an error: a reference of
  several lower case words (`iox.m`, `public.iox.m`) as written, any other
  name as `render_identifier/1` words it.
  """
  @spec render_qualifier(binary()) :: binary()
  def render_qualifier(name) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)+\z/, name),
      do: name,
      else: render_identifier(name)
  end

  @doc "The `$name` placeholder's name, or `nil`."
  @spec param_name(binary()) :: binary() | nil
  def param_name(text) do
    case Regex.run(~r/\A\$(\w+)\z/u, text) do
      [_full, name] -> name
      nil -> nil
    end
  end

  @doc "Whether the text is a `$name` placeholder."
  @spec param?(binary()) :: boolean()
  def param?(text), do: param_name(text) != nil

  @doc """
  Whether the text is a string, a boolean or a number, one past the range of
  a double (`1e400`) included.
  """
  @spec literal?(binary()) :: boolean()
  def literal?(text),
    do: string?(text) or text in ["true", "false"] or is_number(coerce(text)) or float?(text)

  @doc """
  A literal as a value: a quoted one is a string, only a bare one is typed,
  `$name` is `{:param, name}`.
  """
  @spec value(binary()) :: value()
  def value(text) do
    cond do
      string?(text) -> body(text)
      text == "true" -> true
      text == "false" -> false
      name = param_name(text) -> {:param, name}
      true -> coerce(text)
    end
  end

  @doc """
  Types a bare literal as the engine does: an integer that fits `Int64` or
  `UInt64`, else a float (an integer past both is the double nearest it, so
  a `UInt64` column compares with `18446744073709551616` as a double), else
  leaves it as a string.
  """
  @spec coerce(binary()) :: number() | binary()
  def coerce(text) do
    case Integer.parse(text) do
      {n, ""} ->
        double_past_integers(n, text)

      _no_int ->
        case Float.parse(text) do
          {f, ""} -> f
          _no_parse -> text
        end
    end
  end

  @spec double_past_integers(integer(), binary()) :: number()
  defp double_past_integers(n, _text) when is_int64(n) or is_uint64(n), do: n

  defp double_past_integers(n, text) do
    case float_value(text) do
      :nonfinite -> n
      value -> value
    end
  end

  @doc """
  The value of a number token (`1.5`, `.5`, `1.`, `1e5`, or digits only), read
  as a Rust `f64` is: correctly rounded, `0.0` on underflow, and `:nonfinite`
  past the largest double, which the engine holds as infinity.
  """
  @spec float_value(binary()) :: float() | :nonfinite
  def float_value(text) do
    normal =
      text
      |> String.replace(~r/^(-?)\./u, "\\g{1}0.")
      |> String.replace(~r/\.(?=[eE]|$)/u, ".0")

    case Float.parse(normal) do
      {value, ""} -> value
      _overflow -> :nonfinite
    end
  end

  @float_literal ~r/^-?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+(?:\.[0-9]*)?[eE][+-]?[0-9]+)$/u

  @doc "Whether the text is a float literal (`1.5`, `.5`, `1e5`); an integer is not."
  @spec float?(binary()) :: boolean()
  def float?(text), do: Regex.match?(@float_literal, text)

  @doc "A float literal's value, with the `{float, rest}` of `Float.parse/1`, or `:error`."
  @spec parse_float(binary()) :: {float(), binary()} | :error
  def parse_float(text) do
    if float?(text),
      do: text |> String.replace(~r/^(-?)\./u, "\\g{1}0.") |> Float.parse(),
      else: :error
  end

  @doc "Whether the text is an integer literal."
  @spec integer?(binary()) :: boolean()
  def integer?(text), do: Regex.match?(~r/^-?[0-9]+$/u, text)
end
