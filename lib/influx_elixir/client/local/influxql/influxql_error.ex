defmodule InfluxElixir.Client.Local.InfluxQLError do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The 400 bodies of the engine's InfluxQL parser, by kind of error and the
  # position it names in the statement as sent, and the planning errors it
  # raises while it rewrites the statement.

  alias InfluxElixir.Client.Local.InfluxQLLex

  @engine_error_prefix "error in InfluxQL statement: parsing error: "

  # What a parse error says, by kind; the position follows as `at pos N`.
  @messages %{
    operand: "invalid conditional expression",
    regex: "invalid conditional, expected regular expression",
    overflow: "unable to parse integer due to overflow",
    duration_overflow: "overflow",
    signed_overflow: "constant overflows signed integer",
    field: "invalid SELECT statement, expected field",
    from: "invalid FROM clause, expected identifier, regular expression or subquery",
    alias: "invalid field alias, expected identifier",
    group: "invalid GROUP BY clause, expected wildcard, TIME, identifier or regular expression",
    order: "invalid ORDER BY, expected ASC, DESC or TIME",
    order_time: "invalid ORDER BY, expected TIME column",
    limit: "invalid LIMIT clause, expected unsigned integer",
    offset: "invalid OFFSET clause, expected unsigned integer",
    slimit: "invalid SLIMIT clause, expected unsigned integer",
    soffset: "invalid SOFFSET clause, expected unsigned integer",
    group_by: "invalid GROUP BY clause, expected BY",
    distinct: "invalid DISTINCT expression, expected identifier",
    unsigned: "unable to parse unsigned integer",
    time_call: "invalid TIME call, expected 1 or 2 arguments",
    time_interval: "invalid TIME call, expected a duration for the interval",
    time_close: "invalid TIME call, expected ')'",
    wildcard_type: "invalid wildcard type specifier, expected TAG or FIELD",
    data_type:
      "invalid data type for tag or field reference, " <>
        "expected float, integer, unsigned, string, boolean, field, tag",
    fill: "invalid FILL option, expected NULL, NONE, PREVIOUS, LINEAR, or a number",
    call:
      "invalid expression, the only valid function calls are 'now' with no arguments, " <>
        "date_part(<literal>, time), or scalar math functions",
    comment: "invalid inline comment, missing closing */",
    unterminated_string: "unterminated string literal",
    unterminated_regex: "unterminated regex literal",
    unary:
      "unexpected unary expression: expected literal integer, float, duration, field, " <>
        "function or parenthesis"
  }

  @doc """
  The body of the parse error of `kind` at `pos` in `whole`, the statement as
  sent. `:nom` is a statement the parser stops reading at `pos` (the rest is
  quoted), `:failure` one it fails to read from `pos` on (always reported at the
  start of the statement, past its blanks).
  """
  @spec syntax_error_body(atom(), non_neg_integer(), binary()) :: binary()
  def syntax_error_body(:nom, pos, whole) do
    # The statement is read from its first character that is no blank: a statement left over
    # whole is left over from there.
    pos = max(pos, leading_blanks(whole))

    @engine_error_prefix <>
      "invalid InfluxQL statement at pos #{pos}. " <>
      "Parsing Error: Nom(#{rust_debug(leftover(whole, pos))}, Tag)"
  end

  def syntax_error_body(:failure, pos, whole) do
    @engine_error_prefix <>
      "invalid InfluxQL statement at pos #{leading_blanks(whole)}. " <>
      "Parsing Failure: Nom(#{rust_debug(leftover(whole, pos))}, Char)"
  end

  def syntax_error_body(kind, pos, _whole),
    do: @engine_error_prefix <> "#{Map.fetch!(@messages, kind)} at pos #{pos}"

  @doc ~S"""
  A string as Rust's `{:?}` writes it, between double quotes, as the engine's errors quote
  the text they stop at: `\0 \t \r \n \\ \"` as such, any other control character, space
  separator (but the space), mark and unassigned character as `\u{hex}`, the rest as it is.
  """
  @spec rust_debug(binary()) :: binary()
  def rust_debug(text) do
    body = for <<cp::utf8 <- text>>, into: "", do: escape_char(cp)
    ~s("#{body}")
  end

  # The characters Rust's `{:?}` writes as `\u{..}`: control, separator and mark characters.
  @escaped ~q/\A[\p{C}\p{Zl}\p{Zp}\p{Zs}\p{Mn}\p{Me}]\z/u

  defp escape_char(0), do: "\\0"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?"), do: "\\\""
  defp escape_char(cp) when cp < 0x20 or cp == 0x7F, do: "\\u{" <> hex(cp) <> "}"
  defp escape_char(cp) when cp < 0x7F, do: <<cp::utf8>>

  defp escape_char(cp) do
    char = <<cp::utf8>>

    if Regex.match?(@escaped, char),
      do: "\\u{" <> hex(cp) <> "}",
      else: char
  end

  defp hex(cp), do: cp |> Integer.to_string(16) |> String.downcase()

  @doc """
  Where in `whole` the text starts that `quoted` (the output of `rust_debug/1`, quotes included)
  is the debug form of, when it is the end of `whole`: the inverse of quoting, read once, from
  the size of the text.
  """
  @spec quoted_start(binary(), binary()) :: non_neg_integer() | nil
  def quoted_start(quoted, whole) do
    text = unquote_debug(binary_part(quoted, 1, byte_size(quoted) - 2), [])
    pos = byte_size(whole) - byte_size(text)
    if pos >= 0 and leftover(whole, pos) == text, do: pos
  end

  # The inverse of `rust_debug/1`, inside its quotes.
  defp unquote_debug(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp unquote_debug(<<"\\0", rest::binary>>, acc), do: unquote_debug(rest, [<<0>> | acc])
  defp unquote_debug(<<"\\t", rest::binary>>, acc), do: unquote_debug(rest, ["\t" | acc])
  defp unquote_debug(<<"\\r", rest::binary>>, acc), do: unquote_debug(rest, ["\r" | acc])
  defp unquote_debug(<<"\\n", rest::binary>>, acc), do: unquote_debug(rest, ["\n" | acc])
  defp unquote_debug(<<"\\\\", rest::binary>>, acc), do: unquote_debug(rest, ["\\" | acc])
  defp unquote_debug(<<"\\\"", rest::binary>>, acc), do: unquote_debug(rest, ["\"" | acc])

  defp unquote_debug(<<"\\u{", rest::binary>>, acc) do
    [hex, after_hex] = String.split(rest, "}", parts: 2)
    unquote_debug(after_hex, [<<String.to_integer(hex, 16)::utf8>> | acc])
  end

  defp unquote_debug(<<c::utf8, rest::binary>>, acc), do: unquote_debug(rest, [<<c::utf8>> | acc])

  # How many blanks (a space, a tab, a carriage return, a line feed) the statement starts with.
  @spec leading_blanks(binary()) :: non_neg_integer()
  defp leading_blanks(whole), do: byte_size(whole) - byte_size(InfluxQLLex.trim_blanks(whole))

  @spec leftover(binary(), non_neg_integer()) :: binary()
  defp leftover(whole, pos), do: binary_part(whole, pos, byte_size(whole) - pos)

  @split_prefix "rewriting statement\ncaused by\nsplit condition\ncaused by\n"

  @doc "The error the engine raises while it rewrites the statement."
  @spec rewrite_error(binary()) :: binary()
  def rewrite_error(message), do: "rewriting statement\ncaused by\n" <> message

  @doc """
  The planning error the engine raises while it splits the `WHERE` from its
  `time` bounds: the engine's wording of `message`.
  """
  @spec split_error(binary()) :: binary()
  def split_error(message), do: @split_prefix <> message

  @doc """
  The message of a `split_error/1` without its frame: `SHOW TAG VALUES`
  answers with the message alone.
  """
  @spec unframe_split(binary()) :: binary()
  def unframe_split(body), do: String.replace_prefix(body, @split_prefix, "")

  @doc """
  The planning error the engine raises while it expands the projection of the
  select list (`message` after its `Error during planning: `).
  """
  @spec expand_error(binary()) :: binary()
  def expand_error(message) do
    "rewriting statement\ncaused by\nexpand projection\ncaused by\n" <>
      "Error during planning: " <> message
  end

  @doc """
  The planning error the engine raises while it gathers what the select list
  asks for: `message` after the engine's `Error during planning: `.
  """
  @spec select_error(binary()) :: binary()
  def select_error(message) do
    "rewriting statement\ncaused by\ngather information about select statement\n" <>
      "caused by\nError during planning: " <> message
  end

  @doc """
  The planning error the engine raises while it finds the offset of a `GROUP BY
  time()` for a quoted offset that is no timestamp: `quoted` is the literal as
  written, quotes included.
  """
  @spec offset_error(binary()) :: binary()
  def offset_error(quoted) do
    "rewriting statement\ncaused by\nfind interval offset\ncaused by\n" <>
      "Error during planning: invalid expression #{rust_debug(quoted)}: " <>
      "#{quoted} is not a valid timestamp"
  end

  @doc "Moves the positions of a parse error body on by `by` bytes."
  @spec shift_position(binary(), non_neg_integer()) :: binary()
  def shift_position(body, by) do
    Regex.replace(~q/at pos (\d+)/, body, fn _match, pos ->
      "at pos #{String.to_integer(pos) + by}"
    end)
  end

  @doc """
  `where_error_body/4` with the position the parser meets the error at (the order of the
  errors of a statement, see `InfluxElixir.Client.Local.InfluxQLCheck.leftmost/2`): the
  position the body names, or for a failure, where the text it quotes starts.
  """
  @spec where_error(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          {non_neg_integer(), binary()}
  def where_error(kind, pos, where_at, whole),
    do: {where_key(kind, pos, where_at, whole), where_error_body(kind, pos, where_at, whole)}

  defp where_key(:where_unparsed, _pos, where_at, _whole), do: where_at
  defp where_key(:reserved_operand, pos, _where_at, whole), do: before_operand(whole, pos)
  defp where_key(:reserved_operator, pos, _where_at, whole), do: before_operand(whole, pos) - 1
  defp where_key(_kind, pos, _where_at, _whole), do: pos

  @doc """
  The body for a `WHERE` the tokens of which stop at `pos`
  , by the `kind`
  `InfluxElixir.Client.Local.InfluxQLTokens` gives: `where_at` is where the
  `WHERE` starts.
  """
  @spec where_error_body(atom(), non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def where_error_body(:where_unparsed, _pos, where_at, whole),
    do: syntax_error_body(:nom, where_at, whole)

  def where_error_body(:reserved_operand, pos, _where_at, whole),
    do: syntax_error_body(:operand, before_operand(whole, pos), whole)

  def where_error_body(:reserved_operator, pos, _where_at, whole),
    do: syntax_error_body(:nom, before_operand(whole, pos) - 1, whole)

  def where_error_body(:reserved_failure, pos, _where_at, whole),
    do: syntax_error_body(:failure, pos, whole)

  def where_error_body(kind, pos, _where_at, whole), do: syntax_error_body(kind, pos, whole)

  @doc """
  The end of the operator before the operand that starts at `pos`:
  whitespace, opening parentheses and unary signs between them are skipped.
  """
  @spec before_operand(binary(), non_neg_integer()) :: non_neg_integer()
  def before_operand(whole, pos) do
    skipped = whole |> binary_part(0, pos) |> String.reverse()
    [spaces] = Regex.run(~q/^[\s(+\-]*/, skipped)
    pos - byte_size(spaces)
  end
end
