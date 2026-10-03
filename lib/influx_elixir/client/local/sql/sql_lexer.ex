defmodule InfluxElixir.Client.Local.SQLLexer do
  @moduledoc false
  # Reads a SQL text as the engine's tokenizer does, before
  # `InfluxElixir.Client.Local.SQLParser` looks at it (verified against
  # InfluxDB 3 Core):
  #
  #   * `-- ...` to the end of the line, and `/* ... */` (which nest), are
  #     comments and leave no trace: a quote inside one opens nothing
  #   * `'...'` is a string and `"..."` or `` `...` `` a quoted identifier; inside either, a
  #     doubled quote is one quote and nothing else has a meaning
  #   * `$$...$$` and `$tag$...$tag$` are dollar-quoted strings, and `E'...'`
  #     or `e'...'` a string with backslash escapes, rewritten as ordinary
  #     `'...'` literals; `$name` is a placeholder and is kept
  #   * `X'...'` is a binary value, which the double refuses by name
  #   * `;` ends a statement; empty statements are nothing, so a trailing `;`
  #     is fine
  #
  # A text the tokenizer cannot read is its `SQL error: TokenizerError(...)`
  # 400, naming the line and column (counted in characters) where the
  # unterminated string, quoted identifier or dollar-quoted string began, or
  # where the text ended for an unterminated comment or a dollar-quoted string
  # whose end is missing. A text with no statement is the planner's 400, and
  # one with several is the engine's 405.

  alias InfluxElixir.Client.Local.{SQLError, SQLIdentifiers, SQLLiteral}

  @typep state :: %{whole: binary(), statements: [binary()]}

  @doc """
  The statement the text holds, with comments removed and dollar-quoted
  strings written as `'...'` literals, or the engine's error.
  """
  @spec scrub(binary()) :: {:ok, binary()} | {:error, SQLError.t()}
  def scrub(sql) do
    if String.valid?(sql) do
      with {:ok, statements} <- scan(sql, %{whole: sql, statements: []}, []) do
        single(statements)
      end
    else
      {:error, SQLError.refusal("the SQL text is not valid UTF-8")}
    end
  end

  @spec single([binary()]) :: {:ok, binary()} | {:error, SQLError.t()}
  defp single(statements) do
    case statements |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] ->
        {:error, SQLError.planning("No SQL statements were provided in the query string")}

      [statement] ->
        {:ok, statement}

      [_first, _second | _more] ->
        {:error,
         %{
           status: 405,
           body:
             "This feature is not implemented: " <>
               "The context currently only supports a single SQL statement"
         }}
    end
  end

  # `chunk` holds the current statement's text, reversed.
  @spec scan(binary(), state(), iodata()) :: {:ok, [binary()]} | {:error, SQLError.t()}
  defp scan(<<>>, state, chunk), do: {:ok, Enum.reverse([text(chunk) | state.statements])}

  defp scan(<<?;, rest::binary>>, state, chunk),
    do: scan(rest, %{state | statements: [text(chunk) | state.statements]}, [])

  defp scan(<<q, rest::binary>> = input, state, chunk) when q in [?', ?", ?`] do
    case SQLIdentifiers.take_quoted(rest, q) do
      {:ok, body, after_literal} -> scan(after_literal, state, [[q, body, q] | chunk])
      :error -> {:error, unterminated(q, state.whole, input)}
    end
  end

  defp scan(<<"--", rest::binary>>, state, chunk),
    do: scan(skip_line(rest), state, [?\s | chunk])

  defp scan(<<"/*", rest::binary>>, state, chunk) do
    case skip_block(rest, 1) do
      {:ok, after_comment} -> scan(after_comment, state, [?\s | chunk])
      :error -> {:error, at_end(state.whole, "Unexpected EOF while in a multi-line comment")}
    end
  end

  defp scan(<<?$, rest::binary>>, state, chunk) do
    case dollar(rest) do
      {:literal, literal, after_literal} -> scan(after_literal, state, [literal | chunk])
      :placeholder -> placeholder(rest, state, chunk)
      {:unterminated, message} -> {:error, at_end(state.whole, message)}
    end
  end

  # A number is read whole (`SQLIdentifiers.take_number/1`), so a letter after it begins a
  # word of its own: `1e'a'` is `1` and the escape string `e'a'`.
  defp scan(<<c, _rest::binary>> = input, state, chunk) when c in ?0..?9 do
    {number, after_number} = SQLIdentifiers.take_number(input)
    scan(after_number, state, [number | chunk])
  end

  defp scan(<<?., d, _rest::binary>> = input, state, chunk) when d in ?0..?9 do
    {number, after_number} = SQLIdentifiers.take_number(input)
    scan(after_number, state, [number | chunk])
  end

  # A word is read whole, so an `E` that ends one (`name'...'`) opens no
  # escape string; `E'` or `e'` at the start of a token does.
  defp scan(<<c::utf8, rest::binary>> = input, state, chunk) do
    if SQLIdentifiers.word_char?(c) do
      {word, after_word} = take_word(input)

      case after_word do
        <<?', body::binary>> when word in ["E", "e"] ->
          escape_string(body, input, state, chunk)

        <<?', body::binary>> when word in ["X", "x"] ->
          hex_string(body, after_word, state, [word | chunk])

        _no_escape_string ->
          scan(after_word, state, [word | chunk])
      end
    else
      scan(rest, state, [<<c::utf8>> | chunk])
    end
  end

  # `$name`: the name is read whole, so a name ending in `e` opens no escape
  # string.
  @spec placeholder(binary(), state(), iodata()) :: {:ok, [binary()]} | {:error, SQLError.t()}
  defp placeholder(rest, state, chunk) do
    {name, after_name} = take_tag(rest, [])
    scan(after_name, state, [name, ?$ | chunk])
  end

  # `E'...'`: a backslash escape is read as the engine's tokenizer reads it
  # (verified): `\b \f \n \r \t`, `\u` and `\U` with exactly 4 or 8 hex
  # digits, `\x` with 1 or 2 hex digits (none leaves a literal `x`), an octal
  # `\N`, `\NN` or `\NNN`; the code of `\x` and of an octal escape must be
  # 1 to 127, of `\u` and `\U` a non-zero scalar value, or the string is
  # unterminated. Any other escaped character stands for itself, and a
  # doubled quote is a quote. The literal is rewritten as a plain `'...'`.
  @spec escape_string(binary(), binary(), state(), iodata()) ::
          {:ok, [binary()]} | {:error, SQLError.t()}
  defp escape_string(body, start, state, chunk) do
    case take_escaped(body, []) do
      {:ok, text, after_literal} ->
        scan(after_literal, state, [SQLLiteral.quote_text(text) | chunk])

      :error ->
        {:error, located(state.whole, start, "Unterminated encoded string literal")}
    end
  end

  # `X'61'` is a binary value to the engine, which compares it byte for byte
  # with a text column and refuses it against a number. The double does not
  # model a binary value and refuses the text by name; an unterminated
  # literal is the tokenizer's error as for any string.
  @spec hex_string(binary(), binary(), state(), iodata()) ::
          {:ok, [binary()]} | {:error, SQLError.t()}
  defp hex_string(body, after_word, state, chunk) do
    case SQLIdentifiers.take_quoted(body, ?') do
      {:ok, _literal, _rest} ->
        {:error,
         SQLError.refusal(
           "a hexadecimal string literal (X'...') is a binary value on the engine, which " <>
             "this double does not model"
         )}

      :error ->
        scan(after_word, state, chunk)
    end
  end

  @doc """
  The text of an escape string whose opening `E'` was read: the characters up
  to the closing quote with the backslash escapes decoded, and what follows the
  quote; `:error` when the string is not closed or an escape is not one.
  """
  @spec escaped(binary()) :: {:ok, binary(), binary()} | :error
  def escaped(body), do: take_escaped(body, [])

  @spec take_escaped(binary(), [binary()]) :: {:ok, binary(), binary()} | :error
  defp take_escaped(<<?', ?', rest::binary>>, acc), do: take_escaped(rest, ["'" | acc])

  defp take_escaped(<<?', rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_escaped(<<?\\, rest::binary>>, acc) do
    with {:ok, char, after_escape} <- escape(rest), do: take_escaped(after_escape, [char | acc])
  end

  defp take_escaped(<<c::utf8, rest::binary>>, acc), do: take_escaped(rest, [<<c::utf8>> | acc])
  defp take_escaped(<<>>, _acc), do: :error

  @spec escape(binary()) :: {:ok, binary(), binary()} | :error
  defp escape(<<?b, rest::binary>>), do: {:ok, <<8>>, rest}
  defp escape(<<?f, rest::binary>>), do: {:ok, <<12>>, rest}
  defp escape(<<?n, rest::binary>>), do: {:ok, "\n", rest}
  defp escape(<<?r, rest::binary>>), do: {:ok, "\r", rest}
  defp escape(<<?t, rest::binary>>), do: {:ok, "\t", rest}
  defp escape(<<?u, rest::binary>>), do: fixed_hex(rest, 4)
  defp escape(<<?U, rest::binary>>), do: fixed_hex(rest, 8)

  defp escape(<<?x, rest::binary>>) do
    case take_digits(rest, 2, &hex_digit?/1, []) do
      {[], _rest} -> {:ok, "x", rest}
      {digits, after_digits} -> ascii_code(digits, 16, after_digits)
    end
  end

  defp escape(<<c, _rest::binary>> = input) when c in ?0..?7 do
    {digits, after_digits} = take_digits(input, 3, &octal?/1, [])
    ascii_code(digits, 8, after_digits)
  end

  defp escape(<<c::utf8, rest::binary>>), do: {:ok, <<c::utf8>>, rest}
  defp escape(<<>>), do: :error

  @spec fixed_hex(binary(), pos_integer()) :: {:ok, binary(), binary()} | :error
  defp fixed_hex(input, count) do
    case take_digits(input, count, &hex_digit?/1, []) do
      {digits, rest} when length(digits) == count -> scalar(digits, rest)
      _short -> :error
    end
  end

  @spec scalar([char()], binary()) :: {:ok, binary(), binary()} | :error
  defp scalar(digits, rest) do
    code = digits |> List.to_string() |> String.to_integer(16)

    if code in 1..0xD7FF or code in 0xE000..0x10FFFF,
      do: {:ok, <<code::utf8>>, rest},
      else: :error
  end

  @spec ascii_code([char()], 8 | 16, binary()) :: {:ok, binary(), binary()} | :error
  defp ascii_code(digits, base, rest) do
    case digits |> List.to_string() |> String.to_integer(base) do
      code when code in 1..127 -> {:ok, <<code>>, rest}
      _outside -> :error
    end
  end

  @spec take_digits(binary(), non_neg_integer(), (byte() -> boolean()), [char()]) ::
          {[char()], binary()}
  defp take_digits(<<c, rest::binary>>, count, digit?, acc) when count > 0 do
    if digit?.(c),
      do: take_digits(rest, count - 1, digit?, [c | acc]),
      else: {Enum.reverse(acc), <<c, rest::binary>>}
  end

  defp take_digits(rest, _count, _digit?, acc), do: {Enum.reverse(acc), rest}

  @spec hex_digit?(byte()) :: boolean()
  defp hex_digit?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  @spec octal?(byte()) :: boolean()
  defp octal?(c), do: c in ?0..?7

  @spec text(iodata()) :: binary()
  defp text(chunk), do: chunk |> Enum.reverse() |> IO.iodata_to_binary()

  # The newline that ends a `--` comment is not part of the comment.
  @spec skip_line(binary()) :: binary()
  defp skip_line(<<?\n, _rest::binary>> = rest), do: rest
  defp skip_line(<<_c::utf8, rest::binary>>), do: skip_line(rest)
  defp skip_line(<<>>), do: <<>>

  @spec skip_block(binary(), pos_integer()) :: {:ok, binary()} | :error
  defp skip_block(<<"*/", rest::binary>>, 1), do: {:ok, rest}
  defp skip_block(<<"*/", rest::binary>>, depth), do: skip_block(rest, depth - 1)
  defp skip_block(<<"/*", rest::binary>>, depth), do: skip_block(rest, depth + 1)
  defp skip_block(<<_c::utf8, rest::binary>>, depth), do: skip_block(rest, depth)
  defp skip_block(<<>>, _depth), do: :error

  # What follows a `$`: `$...$` with an empty tag, `$tag$...$tag$`, or a
  # placeholder.
  @spec dollar(binary()) ::
          {:literal, binary(), binary()} | :placeholder | {:unterminated, binary()}
  defp dollar(<<?$, rest::binary>>) do
    case :binary.split(rest, "$$") do
      [body, after_body] -> {:literal, SQLLiteral.quote_text(body), after_body}
      [_unterminated] -> {:unterminated, "Unterminated dollar-quoted string"}
    end
  end

  defp dollar(rest) do
    {tag, after_tag} = take_tag(rest, [])

    case after_tag do
      <<?$, body_and_rest::binary>> ->
        case :binary.split(body_and_rest, "$" <> tag <> "$") do
          [body, after_body] -> {:literal, SQLLiteral.quote_text(body), after_body}
          [_unterminated] -> {:unterminated, "Unterminated dollar-quoted, expected $"}
        end

      _placeholder ->
        :placeholder
    end
  end

  # A word: the letters, digits and underscores of a name, and the `$` after the first of them
  # (`b$$` is one word, which opens no dollar-quoted string).
  @spec take_word(binary()) :: {binary(), binary()}
  defp take_word(<<first::utf8, rest::binary>>) do
    {tail, after_word} = take_tail(rest, [])
    {<<first::utf8>> <> tail, after_word}
  end

  defp take_tail(<<c::utf8, rest::binary>> = input, acc) do
    if SQLIdentifiers.word_char?(c) or c == ?$,
      do: take_tail(rest, [<<c::utf8>> | acc]),
      else: {acc |> Enum.reverse() |> IO.iodata_to_binary(), input}
  end

  defp take_tail(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  @spec take_tag(binary(), [binary()]) :: {binary(), binary()}
  defp take_tag(<<c::utf8, rest::binary>> = input, acc) do
    if SQLIdentifiers.word_char?(c),
      do: take_tag(rest, [<<c::utf8>> | acc]),
      else: {acc |> Enum.reverse() |> IO.iodata_to_binary(), input}
  end

  defp take_tag(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  @spec unterminated(char(), binary(), binary()) :: SQLError.t()
  defp unterminated(?', whole, input),
    do: located(whole, input, "Unterminated string literal")

  defp unterminated(?", whole, input),
    do: located(whole, input, "Expected close delimiter '\"' before EOF.")

  defp unterminated(?`, whole, input),
    do: located(whole, input, "Expected close delimiter '`' before EOF.")

  # The position of the text `input`, a suffix of `whole`.
  @spec located(binary(), binary(), binary()) :: SQLError.t()
  defp located(whole, input, message) do
    {line, column} = position(binary_part(whole, 0, byte_size(whole) - byte_size(input)))
    SQLError.tokenizer(message, line, column)
  end

  @spec at_end(binary(), binary()) :: SQLError.t()
  defp at_end(whole, message) do
    {line, column} = position(whole)
    SQLError.tokenizer(message, line, column)
  end

  # The line and column (1-based, in characters) just after `text`.
  @spec position(binary()) :: {pos_integer(), pos_integer()}
  defp position(text) do
    lines = :binary.split(text, "\n", [:global])
    {length(lines), length(String.to_charlist(List.last(lines))) + 1}
  end
end
