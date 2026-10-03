defmodule InfluxElixir.Client.Local.SQLMask do
  @moduledoc false
  # Reads quoted text out of the way. Every clause of a SQL text is located by a
  # regular expression, and a string literal can hold anything: a comma, `>`,
  # `limit 5`, `from t`. So the text is masked first — the body of each `'...'`
  # or `"..."` becomes filler, byte for byte, the quotes stay — the expression
  # runs over the mask, and what it found is cut out of the original at the same
  # offsets.
  #
  # The options say how a quoted token is read:
  #
  #   * `:blank` — the filler byte (default `?x`)
  #   * `:doubled` — a doubled quote (`'O''Brien'`) is one quote inside the
  #     literal, as in SQL (default `true`); `false` reads `'a''b'` as two
  #     literals, as InfluxQL does
  #   * `:backslash` — a backslash makes the next byte part of the literal,
  #     as in InfluxQL (default `false`)
  #   * `:regex` — a `/.../` that follows `=~` or `!~` is masked too, as an
  #     InfluxQL regular expression (default `false`)
  #   * `:lenient` — an unterminated literal is masked to the end of the text
  #     instead of raising (default `false`; `InfluxElixir.Client.Local.SQLLexer`
  #     refuses such a text first, so SQL never reaches one)

  @typedoc "How `mask/2` reads quoted text."
  @type option ::
          {:blank, byte()}
          | {:doubled, boolean()}
          | {:backslash, boolean()}
          | {:regex, boolean()}
          | {:lenient, boolean()}

  @typep config :: %{
           blank: byte(),
           doubled: boolean(),
           backslash: boolean(),
           regex: boolean(),
           lenient: boolean()
         }

  @doc """
  The text with the inside of every quoted string and quoted identifier
  blanked, byte for byte.
  """
  @spec mask(binary(), [option()]) :: binary()
  def mask(text, opts \\ []) do
    config = %{
      blank: Keyword.get(opts, :blank, ?x),
      doubled: Keyword.get(opts, :doubled, true),
      backslash: Keyword.get(opts, :backslash, false),
      regex: Keyword.get(opts, :regex, false),
      lenient: Keyword.get(opts, :lenient, false)
    }

    text |> scan(config, [], "") |> IO.iodata_to_binary()
  end

  # `last` holds the last two non-blank bytes, for the `=~ /regex/` rule.
  @spec scan(binary(), config(), iodata(), binary()) :: iodata()
  defp scan(<<>>, _config, acc, _last), do: Enum.reverse(acc)

  defp scan(<<q, rest::binary>>, config, acc, _last) when q in [?', ?"],
    do: literal(rest, q, config, acc, 0)

  defp scan(<<?/, rest::binary>>, %{regex: true} = config, acc, last) when last in ["=~", "!~"],
    do: literal(rest, ?/, config, acc, 0)

  defp scan(<<byte, rest::binary>>, config, acc, last),
    do: scan(rest, config, [byte | acc], next_last(config, last, byte))

  @spec next_last(config(), binary(), byte()) :: binary()
  defp next_last(%{regex: false}, _last, _byte), do: ""
  defp next_last(_config, last, byte) when byte in [?\s, ?\t, ?\n, ?\r], do: last

  defp next_last(_config, last, byte) do
    joined = last <> <<byte>>
    binary_part(joined, max(byte_size(joined) - 2, 0), min(byte_size(joined), 2))
  end

  # The body of a literal opened by `delimiter`, `blanks` bytes so far.
  @spec literal(binary(), byte(), config(), iodata(), non_neg_integer()) :: iodata()
  defp literal(<<>>, delimiter, %{lenient: true} = config, acc, blanks),
    do: scan(<<>>, config, [filler(config, blanks), delimiter | acc], "")

  defp literal(<<>>, delimiter, _config, _acc, _blanks),
    do:
      raise(
        ArgumentError,
        "unterminated #{<<delimiter>>} literal: SQLLexer.scrub/1 must run first"
      )

  defp literal(<<?\\, _byte, rest::binary>>, delimiter, %{backslash: true} = config, acc, blanks),
    do: literal(rest, delimiter, config, acc, blanks + 2)

  defp literal(<<d, d, rest::binary>>, d, %{doubled: true} = config, acc, blanks)
       when d in [?', ?"],
       do: literal(rest, d, config, acc, blanks + 2)

  defp literal(<<d, rest::binary>>, d, config, acc, blanks),
    do: scan(rest, config, [d, filler(config, blanks), d | acc], "")

  defp literal(<<_byte, rest::binary>>, delimiter, config, acc, blanks),
    do: literal(rest, delimiter, config, acc, blanks + 1)

  @spec filler(config(), non_neg_integer()) :: binary()
  defp filler(%{blank: blank}, width), do: String.duplicate(<<blank>>, width)

  @doc """
  `Regex.run/2` over the masked text, with the captures cut from `text` (an
  unmatched optional group is `""`); `nil` when the pattern does not match.
  """
  @spec run(Regex.t(), binary()) :: [binary()] | nil
  def run(pattern, text) do
    case Regex.run(pattern, mask(text), return: :index) do
      nil -> nil
      indexes -> Enum.map(indexes, &cut(text, &1))
    end
  end

  @doc """
  A masked text with the `FROM` that is not a clause's blanked: one inside
  parentheses (`EXTRACT(minute FROM time)`) and the one of `IS [NOT] DISTINCT
  FROM`. Offsets are those of the text.
  """
  @spec hide_inner_from(binary()) :: binary()
  def hide_inner_from(masked) do
    masked
    |> hide_in_parentheses(0, [])
    |> IO.iodata_to_binary()
    |> then(
      &Regex.replace(~r/\b(IS\s+(?:NOT\s+)?DISTINCT\s+)FROM\b/iu, &1, fn _all, head ->
        head <> "xxxx"
      end)
    )
  end

  @spec hide_in_parentheses(binary(), non_neg_integer(), iodata()) :: iodata()
  defp hide_in_parentheses(<<>>, _depth, acc), do: Enum.reverse(acc)

  defp hide_in_parentheses(<<?(, rest::binary>>, depth, acc),
    do: hide_in_parentheses(rest, depth + 1, [?( | acc])

  defp hide_in_parentheses(<<?), rest::binary>>, depth, acc),
    do: hide_in_parentheses(rest, max(depth - 1, 0), [?) | acc])

  defp hide_in_parentheses(<<word::binary-size(4), rest::binary>> = text, depth, acc)
       when depth > 0 do
    if String.upcase(word) == "FROM" and boundary?(acc) and not word_start?(rest),
      do: hide_in_parentheses(rest, depth, ["xxxx" | acc]),
      else: skip_byte(text, depth, acc)
  end

  defp hide_in_parentheses(text, depth, acc), do: skip_byte(text, depth, acc)

  defp skip_byte(<<byte, rest::binary>>, depth, acc),
    do: hide_in_parentheses(rest, depth, [byte | acc])

  @spec boundary?(iodata()) :: boolean()
  defp boundary?([]), do: true
  defp boundary?([byte | _acc]) when is_integer(byte), do: not word_byte?(byte)
  defp boundary?(_other), do: true

  @spec word_start?(binary()) :: boolean()
  defp word_start?(<<byte, _rest::binary>>), do: word_byte?(byte)
  defp word_start?(<<>>), do: false

  @spec word_byte?(byte()) :: boolean()
  defp word_byte?(byte), do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_

  @doc "The text a `{start, length}` capture covers, or `\"\"` for a group that did not match."
  @spec cut(binary(), {integer(), non_neg_integer()}) :: binary()
  def cut(_text, {-1, _length}), do: ""
  def cut(text, {start, length}), do: binary_part(text, start, length)

  @doc "Splits at the commas outside parentheses and string literals."
  @spec split_commas(binary()) :: [binary()]
  def split_commas(str) do
    commas = str |> mask() |> comma_positions(0, 0, [])
    {last, parts} = Enum.reduce(commas, {0, []}, &cut_before(&1, &2, str))
    Enum.reverse([binary_part(str, last, byte_size(str) - last) | parts])
  end

  @spec cut_before(non_neg_integer(), {non_neg_integer(), [binary()]}, binary()) ::
          {non_neg_integer(), [binary()]}
  defp cut_before(at, {from, parts}, str),
    do: {at + 1, [binary_part(str, from, at - from) | parts]}

  @spec comma_positions(binary(), non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          [non_neg_integer()]
  defp comma_positions(<<>>, _at, _depth, acc), do: Enum.reverse(acc)

  defp comma_positions(<<?,, rest::binary>>, at, 0, acc),
    do: comma_positions(rest, at + 1, 0, [at | acc])

  defp comma_positions(<<?(, rest::binary>>, at, depth, acc),
    do: comma_positions(rest, at + 1, depth + 1, acc)

  defp comma_positions(<<?), rest::binary>>, at, depth, acc),
    do: comma_positions(rest, at + 1, max(depth - 1, 0), acc)

  defp comma_positions(<<_byte, rest::binary>>, at, depth, acc),
    do: comma_positions(rest, at + 1, depth, acc)

  @doc """
  Splits `str` at the parenthesis that closes the one already opened;
  parentheses inside a quoted literal do not count.
  """
  @spec balanced(binary()) :: {:ok, binary(), binary()} | :error
  def balanced(str) do
    case closing_paren(mask(str), 1, 0) do
      nil -> :error
      at -> {:ok, binary_part(str, 0, at), binary_part(str, at + 1, byte_size(str) - at - 1)}
    end
  end

  @spec closing_paren(binary(), pos_integer(), non_neg_integer()) :: non_neg_integer() | nil
  defp closing_paren(<<>>, _depth, _at), do: nil
  defp closing_paren(<<?), _rest::binary>>, 1, at), do: at
  defp closing_paren(<<?), rest::binary>>, depth, at), do: closing_paren(rest, depth - 1, at + 1)
  defp closing_paren(<<?(, rest::binary>>, depth, at), do: closing_paren(rest, depth + 1, at + 1)
  defp closing_paren(<<_byte, rest::binary>>, depth, at), do: closing_paren(rest, depth, at + 1)
end
