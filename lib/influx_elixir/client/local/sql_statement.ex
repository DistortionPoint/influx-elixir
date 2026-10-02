defmodule InfluxElixir.Client.Local.SQLStatement do
  @moduledoc """
  What the engine's SQL parser says of a statement that is not one it reads
  (verified against InfluxDB 3 Core): a first word, number, string or `*` that
  starts no statement is the parser error

      SQL error: ParserError("Expected: an SQL statement, found: FOO at Line: 1, Column: 1")

  with status 400, `found` naming the token as written and the position the
  line and column of its first character (a tab or a space is one column).
  A word that starts a statement the engine reads but does not run is not this
  error (`ALTER`, `TRUNCATE` and the rest are its 405 and its planning errors).
  """

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

  @token ~r/\A(?:([\p{L}_][\p{L}\p{N}_$]*)|(\d+(?:\.\d+)?)|('(?:[^']|'')*')|(\*|,|@@))/u

  @doc """
  The parser error for a statement that starts with a token no statement
  starts with, or `nil` when it is not that.
  """
  @spec parser_error(binary()) :: SQLError.t() | nil
  def parser_error(sql) do
    {space, rest} = split_space(sql)

    with [token | groups] <- Regex.run(@token, rest),
         true <- not statement_word?(groups) do
      {line, column} = position(space)

      SQLError.parser(
        "Expected: an SQL statement, found: #{token} at Line: #{line}, Column: #{column}"
      )
    else
      _a_statement_or_not_a_token -> nil
    end
  end

  @spec split_space(binary()) :: {binary(), binary()}
  defp split_space(sql) do
    [space] = Regex.run(~r/\A[ \t\r\n]*/, sql)
    {space, binary_part(sql, byte_size(space), byte_size(sql) - byte_size(space))}
  end

  @spec statement_word?([binary()]) :: boolean()
  defp statement_word?([word | _rest]) when word != "",
    do: String.upcase(word) in @statement_words

  defp statement_word?(_not_a_word), do: false

  # The line and column of the first character after `space`.
  @spec position(binary()) :: {pos_integer(), pos_integer()}
  defp position(space) do
    lines = String.split(space, "\n")
    {length(lines), String.length(List.last(lines)) + 1}
  end
end
