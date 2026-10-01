defmodule InfluxElixir.Client.Local.SQLLexer do
  @moduledoc """
  Reads a SQL text as the engine's tokenizer does, before
  `InfluxElixir.Client.Local.SQLParser` looks at it (verified against
  InfluxDB 3 Core):

    * `-- ...` to the end of the line, and `/* ... */` (which nest), are
      comments and leave no trace: a quote inside one opens nothing
    * `'...'` is a string and `"..."` a quoted identifier; inside either, a
      doubled quote is one quote and nothing else has a meaning
    * `$$...$$` and `$tag$...$tag$` are dollar-quoted strings, rewritten as
      ordinary `'...'` literals; `$name` is a placeholder and is kept
    * `;` ends a statement; empty statements are nothing, so a trailing `;`
      is fine

  A text the tokenizer cannot read is its `SQL error: TokenizerError(...)`
  400, naming the line and column (counted in characters) where the
  unterminated string, quoted identifier or dollar-quoted string began, or
  where the text ended for an unterminated comment or a dollar-quoted string
  whose end is missing. A text with no statement is the planner's 400, and
  one with several is the engine's 405.
  """

  alias InfluxElixir.Client.Local.SQLError

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

  defp scan(<<q, rest::binary>> = input, state, chunk) when q in [?', ?"] do
    case take_quoted(rest, q, [q]) do
      {:ok, literal, after_literal} -> scan(after_literal, state, [literal | chunk])
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
      :placeholder -> scan(rest, state, [?$ | chunk])
      {:unterminated, message} -> {:error, at_end(state.whole, message)}
    end
  end

  defp scan(<<c::utf8, rest::binary>>, state, chunk), do: scan(rest, state, [<<c::utf8>> | chunk])

  @spec text(iodata()) :: binary()
  defp text(chunk), do: chunk |> Enum.reverse() |> IO.iodata_to_binary()

  # The text of a '...' or "..." through its closing quote, `acc` holding
  # what was read, reversed; a doubled quote does not close it.
  @spec take_quoted(binary(), char(), iodata()) :: {:ok, binary(), binary()} | :error
  defp take_quoted(<<q, q, rest::binary>>, q, acc), do: take_quoted(rest, q, [q, q | acc])

  defp take_quoted(<<q, rest::binary>>, q, acc),
    do: {:ok, [q | acc] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_quoted(<<c::utf8, rest::binary>>, q, acc),
    do: take_quoted(rest, q, [<<c::utf8>> | acc])

  defp take_quoted(<<>>, _q, _acc), do: :error

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
      [body, after_body] -> {:literal, quote_text(body), after_body}
      [_unterminated] -> {:unterminated, "Unterminated dollar-quoted string"}
    end
  end

  defp dollar(rest) do
    {tag, after_tag} = take_tag(rest, [])

    case after_tag do
      <<?$, body_and_rest::binary>> ->
        case :binary.split(body_and_rest, "$" <> tag <> "$") do
          [body, after_body] -> {:literal, quote_text(body), after_body}
          [_unterminated] -> {:unterminated, "Unterminated dollar-quoted, expected $"}
        end

      _placeholder ->
        :placeholder
    end
  end

  @spec take_tag(binary(), [binary()]) :: {binary(), binary()}
  defp take_tag(<<c::utf8, rest::binary>> = input, acc) do
    char = <<c::utf8>>

    if char == "_" or Regex.match?(~r/\A[\p{L}\p{N}]\z/u, char),
      do: take_tag(rest, [char | acc]),
      else: {acc |> Enum.reverse() |> IO.iodata_to_binary(), input}
  end

  defp take_tag(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  @spec quote_text(binary()) :: binary()
  defp quote_text(body), do: "'" <> String.replace(body, "'", "''") <> "'"

  @spec unterminated(char(), binary(), binary()) :: SQLError.t()
  defp unterminated(?', whole, input),
    do: located(whole, input, "Unterminated string literal")

  defp unterminated(?", whole, input),
    do: located(whole, input, "Expected close delimiter '\"' before EOF.")

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
