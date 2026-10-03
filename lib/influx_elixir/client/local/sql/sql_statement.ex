defmodule InfluxElixir.Client.Local.SQLStatement do
  @moduledoc false
  # What the engine's SQL parser says of a statement that is not one it reads
  # (verified against InfluxDB 3 Core).
  #
  # A first token that starts no statement is the parser error
  #
  #     SQL error: ParserError("Expected: an SQL statement, found: FOO at Line: 1, Column: 1")
  #
  # with status 400, `found` naming the token as the engine's tokenizer prints
  # it (`0x1f` is `X'1f'`, `b'1'` is `B'1'`, `'a''b'` is `'a'b'`, `1e5` and `@@x`
  # as written) and the position the line and column of its first character: a
  # tab or a space is one column, and a comment before it counts. A first token
  # the double does not know the engine's printing of is refused by name.
  #
  # A word that starts a statement the engine reads but does not run is not
  # this error (`ALTER`, `TRUNCATE` and the rest are its 405 and its planning
  # errors); alone, or with only a `;` after it, it is the parser's
  # `Expected: <what it needs>, found: EOF` (or `found: ; at Line: 1, Column: n`),
  # the 405 or the planning error of a statement that needs nothing more
  # (`BEGIN`, `COMMIT`, `SHOW`).

  alias InfluxElixir.Client.Local.SQLError

  # The words a statement of the engine's parser may start with (every one
  # of them was checked: none is `Expected: an SQL statement`).
  @statement_words ~w(
    ALTER ANALYZE ASSERT ATTACH BEGIN CACHE CALL CLOSE COMMENT COMMIT COPY CREATE DEALLOCATE
    DECLARE DELETE DENY DESC DESCRIBE DETACH DISCARD DROP END EXEC EXECUTE EXPLAIN EXPORT FETCH
    FLUSH FROM GRANT IF INSERT INSTALL KILL LOAD MERGE MSCK OPEN OPTIMIZE PRAGMA PREPARE PRINT
    RAISERROR RELEASE RENAME REPLACE RETURN REVOKE ROLLBACK SAVEPOINT SELECT SET SHOW START
    TRUNCATE UNCACHE UNLOAD UPDATE USE VACUUM VALUES WHILE WITH
  )

  # What each statement word, alone, needs next (the parser's `Expected: ...`).
  @needs %{
    "ALTER" =>
      "one of VIEW or TYPE or TABLE or INDEX or ROLE or POLICY or CONNECTOR or ICEBERG or SCHEMA",
    "ANALYZE" => "identifier",
    "ASSERT" => "an expression",
    "ATTACH" => "an expression",
    "CACHE" => "identifier",
    "CALL" => "identifier",
    "CLOSE" => "identifier",
    "COMMENT" => "ON",
    "COPY" => "identifier",
    "CREATE" => "an object type after CREATE",
    "DEALLOCATE" => "identifier",
    "DECLARE" => "identifier",
    "DELETE" => "identifier",
    "DENY" => "a privilege keyword",
    "DESC" => "identifier",
    "DESCRIBE" => "identifier",
    "DETACH" => "identifier",
    "DISCARD" => "ALL, PLANS, SEQUENCES, TEMP or TEMPORARY after DISCARD",
    "DROP" =>
      "CONNECTOR, DATABASE, EXTENSION, FUNCTION, INDEX, POLICY, PROCEDURE, ROLE, SCHEMA, SECRET, SEQUENCE, STAGE, TABLE, TRIGGER, TYPE, VIEW, MATERIALIZED VIEW or USER after DROP",
    "EXEC" => "identifier",
    "EXECUTE" => "identifier",
    "EXPLAIN" => "an SQL statement",
    "EXPORT" => "DATA",
    "FETCH" => "a value",
    "FLUSH" =>
      "BINARY LOGS, ENGINE LOGS, ERROR LOGS, GENERAL LOGS, HOSTS, LOGS, PRIVILEGES, OPTIMIZER_COSTS,RELAY LOGS [FOR CHANNEL channel], SLOW LOGS, STATUS, USER_RESOURCES",
    "FROM" => "identifier",
    "GRANT" => "a privilege keyword",
    "IF" => "an expression",
    "INSERT" => "identifier",
    "INSTALL" => "identifier",
    "KILL" => "literal int",
    "LOAD" => "identifier",
    "MERGE" => "identifier",
    "MSCK" => "TABLE",
    "OPEN" => "identifier",
    "OPTIMIZE" => "TABLE",
    "PRAGMA" => "identifier",
    "PREPARE" => "identifier",
    "PRINT" => "an expression",
    "RAISERROR" => "(",
    "RELEASE" => "identifier",
    "RENAME" => "KEYWORD `TABLE` after RENAME",
    "REPLACE" => "identifier",
    "REVOKE" => "a privilege keyword",
    "SAVEPOINT" => "identifier",
    "SELECT" => "an expression",
    "SET" => "identifier",
    "START" => "TRANSACTION",
    "TRUNCATE" => "identifier",
    "UNCACHE" => "TABLE",
    "UNLOAD" => "(",
    "UPDATE" => "identifier",
    "USE" => "identifier",
    "VALUES" => "(",
    "WHILE" => "an expression",
    "WITH" => "identifier"
  }

  # The statement words that need nothing more, and the engine's answer.
  @complete %{
    "BEGIN" => {405, "This feature is not implemented: Unsupported SQL statement: BEGIN"},
    "COMMIT" => {400, "Error during planning: Statement not supported: TransactionEnd"},
    "END" => {405, "This feature is not implemented: COMMIT AND END not supported"},
    "RETURN" => {405, "This feature is not implemented: Unsupported SQL statement: RETURN"},
    "ROLLBACK" => {400, "Error during planning: Statement not supported: TransactionEnd"},
    "SHOW" =>
      {400, "Error during planning: '' is not a variable which can be viewed with 'SHOW'"},
    "VACUUM" => {405, "This feature is not implemented: Unsupported SQL statement: VACUUM"}
  }

  # The tokens of the engine's tokenizer that can start a text, in the order it
  # reads them, each with the text it prints for one. A prefixed string is
  # printed with its prefix in capitals and its quotes undoubled; a hexadecimal
  # number as `X'<digits>'`.
  @prefixed ~r/\A([Uu]&|[NEXBRnexbr])'((?:[^']|'')*)'/u
  @hex ~r/\A0x([0-9a-fA-F]*)/
  @number ~r/\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/
  @single ~r/\A'((?:[^']|'')*)'/u
  @double ~r/\A"((?:[^"]|"")*)"/u
  @backtick ~r/\A`([^`]*)`/u
  @dollar_string ~r/\A(?:\$\$.*?\$\$|\$([A-Za-z_]\w*)\$.*?\$\1\$)/su
  @placeholder ~r/\A\$\w*/u
  @at ~r/\A@@?[\p{L}\p{N}_$]*/u
  @hash ~r/\A(?:##|#\w*)/u
  @word ~r/\A[\p{L}_][\p{L}\p{N}_$]*/u
  @symbols [
    "<>",
    "<=",
    ">=",
    "!=",
    "||",
    "->",
    "=>",
    "&&",
    "::",
    "*",
    ",",
    "?",
    "%",
    "+",
    "-",
    "/",
    "=",
    "<",
    ">",
    ".",
    ")",
    "~",
    "!",
    "\\",
    "^",
    "|",
    "&",
    "{",
    "}",
    "[",
    "]",
    ":"
  ]
  @symbol_char ~r/\A[-<>=!~|&:+*\/%^@#?.\\]/

  @doc """
  The parser error for a statement that starts with a token no statement
  starts with, `nil` when it starts with a statement word or a `(`, or the
  refusal of a first token whose printing is not known.
  """
  @spec parser_error(binary()) :: SQLError.t() | nil
  def parser_error(sql) do
    {blank, rest} = split_blank(sql)

    cond do
      not String.valid?(rest) or rest == "" or String.starts_with?(rest, "(") ->
        nil

      statement_word?(rest) ->
        nil

      true ->
        case printed(rest) do
          {:ok, token} ->
            {line, column} = position(blank)

            SQLError.parser(
              "Expected: an SQL statement, found: #{token} at Line: #{line}, Column: #{column}"
            )

          :unknown ->
            SQLError.refusal(
              "a statement that starts with #{inspect(String.first(rest))}: the engine's " <>
                "parser error for it is not modelled"
            )
        end
    end
  end

  # The words the engine prints in capitals when it names a statement it does not run
  # (the keywords of the statements above, and the words that follow them).
  @display_words @statement_words ++
                   ~w(TABLE TRANSACTION COLUMN ADD INT ALL ON TO LOGS SAVEPOINT CURSOR FOR IS AS
                      MATERIALIZED VIEW DATA)

  @doc """
  A statement the engine does not run as it names it in its error: the keywords in capitals
  and one space between the words. A statement of words only is written so; one with
  punctuation or a literal is written as it stands when its keywords already are in capitals,
  else `:unknown`.
  """
  @spec display(binary()) :: {:ok, binary()} | :unknown
  def display(statement) do
    text = statement |> String.trim() |> String.replace_suffix(";", "") |> String.trim()

    cond do
      Regex.match?(~r/\A[A-Za-z_][\w$]*(?:\s+[A-Za-z_][\w$]*)*\z/, text) ->
        {:ok, text |> String.split() |> Enum.map_join(" ", &display_word/1) |> release()}

      Enum.all?(Regex.scan(~r/[A-Za-z_][\w$]*/, text), fn [word] ->
        word == String.upcase(word) or String.upcase(word) not in @display_words
      end) ->
        {:ok, text}

      true ->
        :unknown
    end
  end

  @spec display_word(binary()) :: binary()
  defp display_word(word) do
    upper = String.upcase(word)
    if upper in @display_words, do: upper, else: word
  end

  # `RELEASE s` is named `RELEASE SAVEPOINT s`.
  @spec release(binary()) :: binary()
  defp release("RELEASE SAVEPOINT" <> _name = text), do: text
  defp release("RELEASE " <> name), do: "RELEASE SAVEPOINT " <> name
  defp release(text), do: text

  @doc """
  The engine's answer to a statement word with nothing after it but a `;`
  (`UPDATE`, `GRANT;`): the parser's error for the end of the text, or the
  answer of a statement that needs nothing more. `nil` for any other text.
  """
  @spec bare_error(binary()) :: SQLError.t() | nil
  def bare_error(sql) do
    {blank, rest} = split_blank(sql)

    with true <- String.valid?(rest),
         [word, tail] <- Regex.run(~r/\A([A-Za-z]+)(\s*;?\s*)\z/, rest, capture: :all_but_first),
         upper = String.upcase(word),
         true <- upper in @statement_words do
      bare(upper, String.length(blank), String.length(word), tail)
    else
      _not_bare -> nil
    end
  end

  @spec bare(binary(), non_neg_integer(), non_neg_integer(), binary()) :: SQLError.t() | nil
  defp bare(word, _blank, _length, _tail) when is_map_key(@complete, word) do
    {status, body} = Map.fetch!(@complete, word)
    %{status: status, body: body}
  end

  defp bare(word, blank, length, tail) do
    case Map.fetch(@needs, word) do
      {:ok, needs} -> SQLError.parser("Expected: #{needs}, found: #{found(blank, length, tail)}")
      :error -> nil
    end
  end

  # `EOF`, or the `;` that ends the text, at its line and column.
  @spec found(non_neg_integer(), non_neg_integer(), binary()) :: binary()
  defp found(blank, length, tail) do
    case :binary.match(tail, ";") do
      :nomatch ->
        "EOF"

      {at, _length} ->
        {line, column} =
          position(String.duplicate(" ", blank + length) <> binary_part(tail, 0, at))

        "; at Line: #{line}, Column: #{column}"
    end
  end

  # The leading whitespace and comments, and what follows them.
  @spec split_blank(binary()) :: {binary(), binary()}
  defp split_blank(sql), do: blank(sql, 0)

  @spec blank(binary(), non_neg_integer()) :: {binary(), binary()}
  defp blank(sql, taken) do
    case skip(binary_part(sql, taken, byte_size(sql) - taken)) do
      0 ->
        {binary_part(sql, 0, taken), binary_part(sql, taken, byte_size(sql) - taken)}

      skipped ->
        blank(sql, taken + skipped)
    end
  end

  # The bytes of one whitespace character or comment at the start of `text`.
  @spec skip(binary()) :: non_neg_integer()
  defp skip(<<c, _rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: 1

  defp skip(<<"--", rest::binary>>) do
    case :binary.match(rest, "\n") do
      {at, _length} -> 2 + at + 1
      :nomatch -> 2 + byte_size(rest)
    end
  end

  defp skip(<<"/*", rest::binary>>), do: block(rest, 1, 2)
  defp skip(_text), do: 0

  @spec block(binary(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp block(<<"*/", _rest::binary>>, 1, taken), do: taken + 2
  defp block(<<"*/", rest::binary>>, depth, taken), do: block(rest, depth - 1, taken + 2)
  defp block(<<"/*", rest::binary>>, depth, taken), do: block(rest, depth + 1, taken + 2)
  defp block(<<_byte, rest::binary>>, depth, taken), do: block(rest, depth, taken + 1)
  defp block(<<>>, _depth, taken), do: taken

  @spec statement_word?(binary()) :: boolean()
  defp statement_word?(rest) do
    case Regex.run(@word, rest) do
      [word] -> String.upcase(word) in @statement_words
      nil -> false
    end
  end

  # The first token of `rest` as the engine prints it, or `:unknown`.
  @spec printed(binary()) :: {:ok, binary()} | :unknown
  defp printed(rest) do
    Enum.find_value(
      [
        &prefixed/1,
        &hex/1,
        &number/1,
        &quoted(&1, @single, "'"),
        &quoted(&1, @double, "\""),
        &backtick/1,
        &simple(&1, @dollar_string),
        &simple(&1, @placeholder),
        &simple(&1, @at),
        &simple(&1, @hash),
        &simple(&1, @word),
        &symbol/1
      ],
      :unknown,
      & &1.(rest)
    )
  end

  @spec prefixed(binary()) :: {:ok, binary()} | nil
  defp prefixed(rest) do
    case Regex.run(@prefixed, rest) do
      [_all, prefix, body] ->
        if String.upcase(prefix) == "E" and String.contains?(body, "\\"),
          do: nil,
          else: {:ok, String.upcase(prefix) <> "'" <> String.replace(body, "''", "'") <> "'"}

      nil ->
        nil
    end
  end

  @spec hex(binary()) :: {:ok, binary()} | nil
  defp hex(rest) do
    case Regex.run(@hex, rest) do
      [_all, digits] -> {:ok, "X'#{digits}'"}
      nil -> nil
    end
  end

  @spec number(binary()) :: {:ok, binary()} | nil
  defp number(rest), do: simple(rest, @number)

  @spec quoted(binary(), Regex.t(), binary()) :: {:ok, binary()} | nil
  defp quoted(rest, pattern, quote_mark) do
    case Regex.run(pattern, rest) do
      [_all, body] ->
        {:ok,
         quote_mark <> String.replace(body, quote_mark <> quote_mark, quote_mark) <> quote_mark}

      nil ->
        nil
    end
  end

  @spec backtick(binary()) :: {:ok, binary()} | nil
  defp backtick(rest) do
    case Regex.run(@backtick, rest) do
      [token, _body] -> {:ok, token}
      nil -> nil
    end
  end

  @spec simple(binary(), Regex.t()) :: {:ok, binary()} | nil
  defp simple(rest, pattern) do
    case Regex.run(pattern, rest) do
      [token | _groups] -> {:ok, token}
      nil -> nil
    end
  end

  # An operator or a punctuation mark the tokenizer prints as written (`!=` as
  # `<>`), when no character follows that could make it a longer operator the
  # double does not know.
  @spec symbol(binary()) :: {:ok, binary()} | nil
  defp symbol(rest) do
    case Enum.find(Enum.sort_by(@symbols, &(-String.length(&1))), &String.starts_with?(rest, &1)) do
      nil ->
        nil

      symbol ->
        tail = binary_part(rest, byte_size(symbol), byte_size(rest) - byte_size(symbol))

        cond do
          Regex.match?(@symbol_char, tail) -> nil
          symbol == "!=" -> {:ok, "<>"}
          true -> {:ok, symbol}
        end
    end
  end

  # The line and column of the first character after `blank`.
  @spec position(binary()) :: {pos_integer(), pos_integer()}
  defp position(blank) do
    lines = String.split(blank, "\n")
    {length(lines), String.length(List.last(lines)) + 1}
  end
end
