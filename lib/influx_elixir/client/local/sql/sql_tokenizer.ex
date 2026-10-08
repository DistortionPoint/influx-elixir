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

  alias InfluxElixir.Client.Local.{SQLIdentifiers, SQLLexer}

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

  @doc "The tokens of a text, or `:bail` when it holds one this tokenizer does not read."
  @spec tokenize(binary()) :: {:ok, tokens()} | :bail
  def tokenize(sql) do
    case scan(sql) do
      {:unread, _char} -> :bail
      read -> read
    end
  end

  @doc """
  The same, but a character beyond ASCII that is no letter (a name with a digit of another
  script, a symbol the engine's tokenizer reads as a character) is told apart from a text that is
  not read at all.
  """
  @spec scan(binary()) :: result()
  def scan(sql), do: tokenize(sql, 1, 1, [])

  @doc """
  Whether a token is a hexadecimal number (`0x1F`), which the engine reads as a binary value.
  """
  @spec hex?(token()) :: boolean()
  def hex?({:literal, "X'" <> _digits, _upper, _line, _col}), do: true
  def hex?(_token), do: false

  @doc """
  The text with every character but a newline blank, so a statement keeps its line and column
  in the whole text.
  """
  @spec blank(binary()) :: binary()
  def blank(text), do: Regex.replace(~r/[^\n]/u, text, " ")

  @doc """
  The statements of a text, each with the byte at which it starts. A `;` inside a string, a
  quoted name, a comment or a dollar-quoted string ends nothing.
  """
  @spec split(binary()) :: [{non_neg_integer(), binary()}]
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

      <<"/*", _after::binary>> ->
        split(sql, skip_comment(sql, pos + 2, 1), start, acc)

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

  defp piece(sql, start, stop), do: {start, binary_part(sql, start, stop - start)}

  # The position after the quote that closes a quoted token, a doubled quote one inside.
  defp skip_quoted(sql, q, quoted) do
    case SQLIdentifiers.take_quoted(quoted, q) do
      {:ok, _body, rest} -> byte_size(sql) - byte_size(rest)
      :error -> byte_size(sql)
    end
  end

  defp skip_line(sql, pos) when pos >= byte_size(sql), do: byte_size(sql)

  defp skip_line(sql, pos) do
    case :binary.match(sql, "\n", scope: {pos, byte_size(sql) - pos}) do
      {at, _length} -> at
      :nomatch -> byte_size(sql)
    end
  end

  defp skip_comment(sql, pos, _depth) when pos >= byte_size(sql), do: byte_size(sql)

  defp skip_comment(sql, pos, depth) do
    case binary_part(sql, pos, min(2, byte_size(sql) - pos)) do
      "*/" -> if depth == 1, do: pos + 2, else: skip_comment(sql, pos + 2, depth - 1)
      "/*" -> skip_comment(sql, pos + 2, depth + 1)
      _other -> skip_comment(sql, pos + 1, depth)
    end
  end

  # A dollar-quoted string, or the position after a placeholder's `$`.
  defp skip_dollar(sql, pos, rest) do
    case Regex.run(~r/\A\$([\p{L}\p{N}_]*)\$/u, rest) do
      [open, _tag] ->
        after_open = pos + byte_size(open)

        case :binary.match(sql, open, scope: {after_open, byte_size(sql) - after_open}) do
          {at, length} -> at + length
          :nomatch -> byte_size(sql)
        end

      nil ->
        pos + 1
    end
  end

  defp word_before?(_sql, 0), do: false
  defp word_before?(sql, pos), do: Regex.match?(~r/[\p{L}\p{N}_]/u, last_character(sql, pos))

  defp last_character(sql, pos) do
    sql |> binary_part(0, pos) |> String.last() |> Kernel.||("")
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

  defp tokenize(<<?', rest::binary>> = text, line, col, acc),
    do: quoted(text, rest, ?', :string, line, col, acc)

  defp tokenize(<<?", rest::binary>> = text, line, col, acc),
    do: quoted(text, rest, ?", :quoted, line, col, acc)

  defp tokenize(<<?`, rest::binary>> = text, line, col, acc),
    do: quoted(text, rest, ?`, :quoted, line, col, acc)

  defp tokenize(<<c::utf8, _rest::binary>> = text, line, col, acc) do
    cond do
      c in ?0..?9 or (c == ?. and digit_next?(text)) -> number(text, line, col, acc)
      SQLIdentifiers.word_start?(c) -> word(text, line, col, acc)
      c == ?$ -> placeholder(text, line, col, acc)
      true -> symbol(text, line, col, acc)
    end
  end

  defp tokenize(_invalid, _line, _col, _acc), do: :bail

  @spec digit_next?(binary()) :: boolean()
  defp digit_next?(<<?., d, _rest::binary>>), do: d in ?0..?9
  defp digit_next?(_text), do: false

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
        body = String.replace(raw_body, <<mark, mark>>, <<mark>>)
        raw = binary_part(text, 0, byte_size(text) - byte_size(after_quote))
        printed = <<mark>> <> body <> <<mark>>
        {next_line, next_col} = advance(raw, line, col)
        tokenize(after_quote, next_line, next_col, [{kind, printed, printed, line, col} | acc])

      :error ->
        :bail
    end
  end

  # The line and column after `text`, which starts at `line`, `col`.
  @spec advance(binary(), pos_integer(), pos_integer()) :: {pos_integer(), pos_integer()}
  defp advance(text, line, col) do
    case String.split(text, "\n") do
      [single] -> {line, col + String.length(single)}
      parts -> {line + length(parts) - 1, String.length(List.last(parts)) + 1}
    end
  end

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
    {next_line, next_col} = advance(raw, line, col)
    token = {kind, printed, printed, line, col}
    tokenize(binary_tail(text, raw), next_line, next_col, [token | acc])
  end

  # A one-letter word directly before a quote prefixes a string: `E'..'` is read (it prints
  # decoded, `E'a'b'` for `E'a''b'`), `N'..'` and the others are not.
  @spec word(binary(), pos_integer(), pos_integer(), tokens()) :: result()
  defp word(text, line, col, acc) do
    literal = binary_part(text, 0, word_length(text, 0))
    after_word = binary_tail(text, literal)

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
    if byte_size(literal) == String.length(literal) do
      nil
    else
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

  # The bytes of the word at the start of `text` (a letter or `_`, then letters, digits, `_`
  # and `$`). Read by walking the bytes: a regex over the whole rest of the text validates all
  # of it as UTF-8 at every word, which makes a long statement cost the square of its length.
  @spec word_length(binary(), non_neg_integer()) :: non_neg_integer()
  defp word_length(<<c::utf8, rest::binary>>, size) do
    if SQLIdentifiers.word_char?(c) or c == ?$,
      do: word_length(rest, size + byte_size(<<c::utf8>>)),
      else: size
  end

  defp word_length(_end_or_invalid, size), do: size

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

  @spec binary_tail(binary(), binary()) :: binary()
  defp binary_tail(text, literal),
    do: binary_part(text, byte_size(literal), byte_size(text) - byte_size(literal))

  @spec placeholder(binary(), pos_integer(), pos_integer(), tokens()) ::
          result()
  defp placeholder(text, line, col, acc) do
    case dollar_string(text) do
      {:ok, raw} ->
        raw_token(text, raw, :literal, raw, line, col, acc)

      :none ->
        case text do
          <<?$, rest::binary>> ->
            literal = binary_part(text, 0, 1 + tag_length(rest, 0))
            emit(text, literal, :placeholder, line, col, acc)

          _no_dollar ->
            :bail
        end

      :bail ->
        :bail
    end
  end

  # `$$..$$` and `$tag$..$tag$`, as written.
  @spec dollar_string(binary()) :: {:ok, binary()} | :none | :bail
  defp dollar_string(<<?$, after_dollar::binary>> = text) do
    size = tag_length(after_dollar, 0)

    case after_dollar do
      <<_tag::binary-size(size), ?$, _rest::binary>> ->
        open = binary_part(text, 0, size + 2)

        case :binary.split(binary_tail(text, open), open) do
          [body, _after] -> {:ok, open <> body <> open}
          [_unterminated] -> :bail
        end

      _no_close ->
        :none
    end
  end

  defp dollar_string(_text), do: :none

  # The bytes of the tag or name at the start of `text`: letters, digits and `_` of any script.
  # Walked, not matched: a regex over the whole rest of the text validates all of it as UTF-8
  # at every `$`, which costs the square of the statement's length in placeholders.
  @spec tag_length(binary(), non_neg_integer()) :: non_neg_integer()
  defp tag_length(<<c::utf8, rest::binary>>, size) do
    if SQLIdentifiers.word_char?(c),
      do: tag_length(rest, size + byte_size(<<c::utf8>>)),
      else: size
  end

  defp tag_length(_end_or_invalid, size), do: size

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
    tokenize(binary_tail(text, literal), line, col + String.length(literal), [token | acc])
  end
end
