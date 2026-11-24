defmodule InfluxElixir.Client.Local.SQLTokenizer do
  @moduledoc false
  # The tokens of a SQL text as the engine's tokenizer reads them, for
  # `InfluxElixir.Client.Local.SQLSyntax`, and the statements of a text.
  #
  # A token is `{kind, printed, upper, line, column}`: its kind (`:word`, `:quoted`, `:string`,
  # `:number`, `:literal`, `:placeholder`, `:symbol` or `:eof`), the text the engine's error
  # messages print for it, that text in upper case, and the line and column it starts at,
  # counted in characters. A text this tokenizer does not read (a token it does not know, an
  # unterminated string or comment) gives `:bail`, and leaves the text to the rest of the
  # double.

  alias InfluxElixir.Client.Local.{InfluxQLLex, SQLIdentifiers, SQLLexer}

  @typedoc "A token: kind, printed, upper case, line, column."
  @type token :: {atom(), binary(), binary(), pos_integer(), pos_integer()}

  @typedoc "The tokens of a text, the last one the end of the text."
  @type tokens :: [token()]

  @symbols [
    "<=>",
    "==",
    "=>",
    "!~~*",
    "!~~",
    "~~*",
    "~~",
    "!~*",
    "//",
    "<>",
    "!=",
    "<=",
    ">=",
    "||",
    "~*",
    "!~",
    "<<",
    ">>",
    "::",
    "->",
    "(",
    ")",
    ",",
    ".",
    "*",
    "+",
    "-",
    "/",
    "%",
    "=",
    "<",
    ">",
    "~",
    "&",
    "|",
    "^",
    "[",
    "]",
    ":"
  ]

  @typedoc """
  What the tokenizer makes of a text: its tokens, `:bail` for a text it does not read, or the
  character that is not a letter, a digit or a symbol of the engine's tokenizer, in a name or on
  its own outside quotes (the engine's parser error for it is not modelled).
  """
  @type result :: {:ok, tokens()} | :bail | {:unread, binary()}

  @typedoc "A line and a column, each from 1."
  @type position :: {pos_integer(), pos_integer()}

  @doc """
  The tokens of a text, or `:bail` when it holds one this tokenizer does not read. The text
  starts at `at`: a statement after the first is read where it stands in the whole text.
  """
  @spec tokenize(binary(), position()) :: {:ok, tokens()} | :bail
  def tokenize(sql, at \\ {1, 1}) do
    case scan(sql, at) do
      {:unread, _char} -> :bail
      read -> read
    end
  end

  @doc """
  The same, but a character beyond ASCII that is no letter (a name with a digit of another
  script, a symbol the engine's tokenizer reads as a character) is told apart from a text that is
  not read at all.
  """
  @spec scan(binary(), position()) :: result()
  def scan(sql, {line, column} \\ {1, 1}) do
    if String.valid?(sql), do: tokenize(sql, line, column, []), else: :bail
  end

  @doc """
  Whether a token is a hexadecimal number (`0x1F`), which the engine reads as a binary value.
  """
  @spec hex?(token()) :: boolean()
  def hex?({:literal, "X'" <> _digits, _upper, _line, _col}), do: true
  def hex?(_token), do: false

  @doc """
  The statements of a text, in order and end to end. A `;` inside a string, a
  quoted name, a comment or a dollar-quoted string ends nothing.
  """
  @spec split(binary()) :: [binary()]
  def split(sql), do: split(sql, 0, 0, [])

  defp split(sql, pos, start, acc) when pos >= byte_size(sql),
    do: Enum.reverse([piece(sql, start, pos) | acc])

  defp split(sql, pos, start, acc) do
    rest = binary_part(sql, pos, byte_size(sql) - pos)

    case rest do
      <<?;, _after::binary>> ->
        split(sql, pos + 1, pos + 1, [piece(sql, start, pos + 1) | acc])

      <<q, quoted::binary>> when q in [?', ?", ?`] ->
        split(sql, skip_quoted(sql, q, quoted), start, acc)

      <<"--", _after::binary>> ->
        split(sql, skip_line(sql, pos + 2), start, acc)

      <<"/*", after_open::binary>> ->
        split(sql, skip_comment(sql, after_open), start, acc)

      <<?$, _after::binary>> ->
        split(sql, skip_dollar(sql, pos, rest), start, acc)

      <<e, ?', body::binary>> when e in [?E, ?e] ->
        if word_before?(sql, pos),
          do: split(sql, pos + 1, start, acc),
          else: split(sql, skip_escaped(sql, pos + 2, body), start, acc)

      _other ->
        split(sql, pos + 1, start, acc)
    end
  end

  defp piece(sql, start, stop), do: binary_part(sql, start, stop - start)

  # The position after the quote that closes a quoted token, a doubled quote one inside.
  defp skip_quoted(sql, q, quoted) do
    case SQLIdentifiers.take_quoted(quoted, q) do
      {:ok, _body, rest} -> byte_size(sql) - byte_size(rest)
      :error -> byte_size(sql)
    end
  end

  defp skip_line(sql, pos) do
    case :binary.match(sql, "\n", scope: {pos, byte_size(sql) - pos}) do
      {at, _length} -> at
      :nomatch -> byte_size(sql)
    end
  end

  defp skip_comment(sql, body) do
    case SQLLexer.skip_block(body) do
      {:ok, rest} -> byte_size(sql) - byte_size(rest)
      :error -> byte_size(sql)
    end
  end

  # A dollar-quoted string, or the position after a placeholder's `$`.
  defp skip_dollar(sql, pos, <<?$, after_dollar::binary>> = rest) do
    case dollar_string(rest, after_dollar) do
      {:ok, raw} -> pos + byte_size(raw)
      :none -> pos + 1
      :bail -> byte_size(sql)
    end
  end

  defp word_before?(_sql, 0), do: false

  defp word_before?(sql, pos) do
    case sql |> binary_part(0, pos) |> String.last() do
      <<c::utf8>> -> SQLIdentifiers.word_char?(c)
      _other -> false
    end
  end

  # The position after the closing quote of an escape string whose body starts at `pos`.
  defp skip_escaped(sql, pos, body) do
    case SQLLexer.escaped(body) do
      {:ok, _text, rest} -> byte_size(sql) - byte_size(rest)
      :error -> byte_size(sql)
    end
    |> max(pos)
  end

  # ---------------------------------------------------------------------------
  # Tokens: `{kind, printed, upper, line, column}`
  # ---------------------------------------------------------------------------

  @spec tokenize(binary(), pos_integer(), pos_integer(), tokens()) :: result()
  defp tokenize(<<>>, line, col, acc),
    do: {:ok, Enum.reverse([{:eof, "EOF", "EOF", line, col} | acc])}

  defp tokenize(<<?;, _rest::binary>>, line, col, acc),
    do: tokenize(<<>>, line, col + 1, [{:symbol, ";", ";", line, col} | acc])

  defp tokenize(<<?\n, rest::binary>>, line, _col, acc), do: tokenize(rest, line + 1, 1, acc)

  defp tokenize(<<c, rest::binary>>, line, col, acc) when c in [?\s, ?\t, ?\r],
    do: tokenize(rest, line, col + 1, acc)

  defp tokenize(<<"--", rest::binary>>, line, col, acc) do
    case :binary.split(rest, "\n") do
      [_comment] -> tokenize(<<>>, line, col, acc)
      [_comment, after_line] -> tokenize(after_line, line + 1, 1, acc)
    end
  end

  defp tokenize(<<"/*", rest::binary>>, line, col, acc),
    do: block_comment(rest, 1, line, col + 2, acc)

  defp tokenize(<<mark, rest::binary>> = text, line, col, acc) when mark in [?', ?", ?`],
    do: quoted(text, rest, mark, if(mark == ?', do: :string, else: :quoted), line, col, acc)

  defp tokenize(<<c::utf8, _rest::binary>> = text, line, col, acc) do
    cond do
      SQLIdentifiers.number_start?(text) -> number(text, line, col, acc)
      SQLIdentifiers.word_start?(c) -> word(text, line, col, acc)
      c == ?$ -> placeholder(text, line, col, acc)
      true -> symbol(text, line, col, acc)
    end
  end

  @spec block_comment(binary(), pos_integer(), pos_integer(), pos_integer(), tokens()) ::
          result()
  defp block_comment(<<"*/", rest::binary>>, 1, line, col, acc),
    do: tokenize(rest, line, col + 2, acc)

  defp block_comment(<<"*/", rest::binary>>, depth, line, col, acc),
    do: block_comment(rest, depth - 1, line, col + 2, acc)

  defp block_comment(<<"/*", rest::binary>>, depth, line, col, acc),
    do: block_comment(rest, depth + 1, line, col + 2, acc)

  defp block_comment(<<?\n, rest::binary>>, depth, line, _col, acc),
    do: block_comment(rest, depth, line + 1, 1, acc)

  defp block_comment(<<_c::utf8, rest::binary>>, depth, line, col, acc),
    do: block_comment(rest, depth, line, col + 1, acc)

  defp block_comment(_end_of_text, _depth, _line, _col, _acc), do: :bail

  # A string or a quoted identifier, its doubled quotes one quote inside. It
  # prints as the engine's tokenizer prints it: the text between the quotes,
  # undoubled, in the quotes.
  @spec quoted(binary(), binary(), byte(), atom(), pos_integer(), pos_integer(), tokens()) ::
          result()
  defp quoted(text, rest, mark, kind, line, col, acc) do
    case SQLIdentifiers.take_quoted(rest, mark) do
      {:ok, raw_body, after_quote} ->
        raw = binary_part(text, 0, byte_size(text) - byte_size(after_quote))
        printed = SQLIdentifiers.printed_quoted(raw_body, mark)
        raw_token(text, raw, kind, printed, line, col, acc)

      :error ->
        :bail
    end
  end

  @doc "The line and column after `text`, which starts at `{line, col}`."
  @spec advance(position(), binary()) :: position()
  def advance({line, col}, text) do
    case :binary.split(text, "\n", [:global]) do
      [single] -> {line, col + characters(single)}
      parts -> {line + length(parts) - 1, characters(List.last(parts)) + 1}
    end
  end

  @spec characters(binary()) :: non_neg_integer()
  defp characters(text), do: text |> String.codepoints() |> length()

  # `0x1F` is a binary value to the engine, printed `X'1F'`, which the double refuses by
  # name once the text reads; any other number prints as written, with its `L`.
  @spec number(binary(), pos_integer(), pos_integer(), tokens()) :: result()
  defp number(text, line, col, acc) do
    case SQLIdentifiers.take_number(text) do
      {"0x" <> digits = raw, _rest} ->
        raw_token(text, raw, :literal, "X'" <> digits <> "'", line, col, acc)

      {literal, _rest} ->
        emit(text, literal, :number, line, col, acc)
    end
  end

  # A token of the text as written, which may span lines, printed as the engine prints it.
  @spec raw_token(binary(), binary(), atom(), binary(), pos_integer(), pos_integer(), tokens()) ::
          result()
  defp raw_token(text, raw, kind, printed, line, col, acc) do
    {next_line, next_col} = advance({line, col}, raw)
    token = {kind, printed, printed, line, col}
    tokenize(InfluxQLLex.rest_after(text, raw), next_line, next_col, [token | acc])
  end

  # A one-letter word directly before a quote prefixes a string: `E'..'` is read (it prints
  # decoded, `E'a'b'` for `E'a''b'`), `N'..'` and the others are not.
  @spec word(binary(), pos_integer(), pos_integer(), tokens()) :: result()
  defp word(text, line, col, acc) do
    {literal, after_word} = SQLIdentifiers.take_span(text, true)

    cond do
      char = not_a_letter(literal) ->
        {:unread, char}

      String.length(literal) == 1 and String.starts_with?(after_word, "'") ->
        if literal in ["E", "e"],
          do: escape_string(text, after_word, line, col, acc),
          else: :bail

      true ->
        emit(text, literal, :word, line, col, acc)
    end
  end

  # A character of a word beyond ASCII that is no letter (`a٣`, `a` and a combining mark): the
  # engine's tokenizer ends the word before it and the parser errs at it, where the double's
  # name reads on (a digit of any script goes on a word). The double does not model that error.
  @spec not_a_letter(binary()) :: binary() | nil
  defp not_a_letter(literal) do
    unless SQLIdentifiers.ascii?(literal) do
      Enum.find(String.codepoints(literal), fn <<c::utf8>> ->
        c >= 128 and not SQLIdentifiers.word_start?(c)
      end)
    end
  end

  # A character the tokenizer has no symbol for: beyond ASCII it is the engine's parser error,
  # which the double does not model, and not a text to read on.
  @spec unread(binary()) :: result()
  defp unread(<<c::utf8, _rest::binary>>) when c >= 128, do: {:unread, <<c::utf8>>}
  defp unread(_text), do: :bail

  @spec escape_string(binary(), binary(), pos_integer(), pos_integer(), tokens()) ::
          result()
  defp escape_string(text, <<?', body::binary>>, line, col, acc) do
    case SQLLexer.escaped(body) do
      {:ok, decoded, rest} ->
        raw = binary_part(text, 0, byte_size(text) - byte_size(rest))
        raw_token(text, raw, :literal, "E'" <> decoded <> "'", line, col, acc)

      :error ->
        :bail
    end
  end

  @spec placeholder(binary(), pos_integer(), pos_integer(), tokens()) ::
          result()
  defp placeholder(<<?$, rest::binary>> = text, line, col, acc) do
    case dollar_string(text, rest) do
      {:ok, raw} ->
        raw_token(text, raw, :literal, raw, line, col, acc)

      :none ->
        literal = binary_part(text, 0, 1 + SQLIdentifiers.span_length(rest))
        emit(text, literal, :placeholder, line, col, acc)

      :bail ->
        :bail
    end
  end

  # `$$..$$` and `$tag$..$tag$`, as written.
  @spec dollar_string(binary(), binary()) :: {:ok, binary()} | :none | :bail
  defp dollar_string(text, after_dollar) do
    size = SQLIdentifiers.span_length(after_dollar)

    case after_dollar do
      <<_tag::binary-size(size), ?$, _rest::binary>> ->
        open = binary_part(text, 0, size + 2)

        case :binary.split(InfluxQLLex.rest_after(text, open), open) do
          [body, _after] -> {:ok, open <> body <> open}
          [_unterminated] -> :bail
        end

      _no_close ->
        :none
    end
  end

  @spec symbol(binary(), pos_integer(), pos_integer(), tokens()) :: result()
  defp symbol(text, line, col, acc) do
    case Enum.find(@symbols, &String.starts_with?(text, &1)) do
      nil -> unread(text)
      "!=" -> emit(text, "!=", :symbol, line, col, acc, "<>")
      symbol -> emit(text, symbol, :symbol, line, col, acc)
    end
  end

  @spec emit(
          binary(),
          binary(),
          atom(),
          pos_integer(),
          pos_integer(),
          tokens(),
          binary() | nil
        ) :: result()
  defp emit(text, literal, kind, line, col, acc, printed \\ nil) do
    token = {kind, printed || literal, String.upcase(literal), line, col}

    tokenize(InfluxQLLex.rest_after(text, literal), line, col + String.length(literal), [
      token | acc
    ])
  end
end
