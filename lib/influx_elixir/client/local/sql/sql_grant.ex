defmodule InfluxElixir.Client.Local.SQLGrant do
  @moduledoc false
  # How the engine names a `GRANT`, `REVOKE` or `DENY` it does not run, in its 405
  # `Unsupported SQL statement: ...` (verified against InfluxDB 3 Core): its keywords in
  # capitals, the names as written, one space between the parts, and these parts in this
  # order:
  #
  #     GRANT p[, p] [ON object] TO grantee[, grantee]
  #           [WITH GRANT OPTION] [AS name] [GRANTED BY name]
  #     REVOKE p[, p] [ON object] FROM grantee[, grantee]
  #           [GRANTED BY name] [CASCADE | RESTRICT]
  #     DENY p ON object TO grantee[, grantee] [CASCADE | RESTRICT] [AS name]
  #
  # where a privilege `p` is `ALL [PRIVILEGES]` alone or one word, with a column list for
  # `SELECT`, `INSERT`, `UPDATE` and `REFERENCES`; an object is a name list, `TABLE` and a
  # name list (which prints as the names alone), `SCHEMA`, `DATABASE`, `SEQUENCE`, `VIEW` or
  # `FUNCTION` and a name list, or `ALL TABLES | SEQUENCES | FUNCTIONS IN SCHEMA` and a name
  # list; a grantee is a name, a string or a word, with `ROLE`, `GROUP` or `USER` before it
  # (the engine writes `PUBLIC`, as the last grantee only, with a space after it). Any other
  # shape is not worded: the engine reads more kinds of object (`PROCEDURE`, `WAREHOUSE`,
  # `USER`, `INTEGRATION`, `CONNECTION`, `FUTURE ...`, `ALL VIEWS IN SCHEMA`, ...) than the
  # double has worded, and a `FUNCTION` takes one name and arguments, so these are refused by
  # name, and so is the parser error of a statement that has one.

  alias InfluxElixir.Client.Local.{SQLDdl, SQLError, SQLTokenizer}

  # The privileges these statements take (every other word is where the parser expects a
  # privilege keyword).
  @privileges ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER CREATE USAGE CONNECT
    EXECUTE TEMPORARY MODIFY MONITOR)
  @column_privileges ~w(SELECT INSERT UPDATE REFERENCES)
  @object_kinds ~w(SCHEMA DATABASE SEQUENCE VIEW)
  @all_kinds ~w(TABLES SEQUENCES FUNCTIONS)
  @error_kinds ["FUNCTION" | @object_kinds]
  @grantee_kinds ~w(ROLE GROUP USER SHARE APPLICATION)
  # The words after `ON` that begin an object the double has not worded, and what may follow
  # `ALL` for one (the engine reads them as an object, and it prints them differently).
  @unworded_objects ~w(PROCEDURE WAREHOUSE USER INTEGRATION CONNECTION FUTURE)
  @unworded_all ~w(VIEWS MATERIALIZED EXTERNAL)

  @doc "Whether a word (in capitals) is a privilege the parser reads (`ROLE r` is one)."
  @spec privilege?(binary()) :: boolean()
  def privilege?(word), do: word in ["ALL", "ROLE"] or word in @privileges

  @doc "Whether the tokens begin with a privilege the parser reads (`DATABASE ROLE r` is one)."
  @spec privilege_start?([SQLTokenizer.token()]) :: boolean()
  def privilege_start?([{:word, _p, "DATABASE", _l, _c}, {:word, _p2, "ROLE", _l2, _c2} | _rest]),
    do: true

  def privilege_start?([{:word, _p, word, _l, _c} | _rest]), do: privilege?(word)
  def privilege_start?(_tokens), do: false

  @doc "The engine's name for a statement of these, or `:unknown`."
  @spec display(binary()) :: {:ok, binary()} | :unknown
  def display(text) do
    with {:ok, tokens} <- SQLTokenizer.tokenize(text),
         [{:word, _p, verb, _l, _c} | rest] <- Enum.reject(tokens, &SQLDdl.end_of?/1),
         {:ok, privileges, rest} <- privileges(rest),
         {:ok, object, rest} <- object(rest),
         true <- object != "" or verb != "DENY",
         {:ok, direction, rest} <- direction(verb, rest),
         {:ok, grantees, rest} <- grantees(rest),
         {:ok, tail, []} <- tail(verb, rest) do
      {:ok,
       [verb, privileges, object, direction, grantees | tail]
       |> Enum.reject(&(&1 == ""))
       |> Enum.join(" ")}
    else
      _unread -> :unknown
    end
  end

  @doc """
  The parser's error for a statement of these that stops where it wants a keyword (`TO` or
  `FROM`, a name) or goes on past its end, `nil` for any other text.
  """
  @spec error(binary()) :: SQLError.t() | nil
  def error(text) do
    with {:ok, tokens} <- SQLTokenizer.tokenize(text),
         [{:word, _p, verb, _l, _c} | rest] <- tokens,
         true <- verb in ["GRANT", "REVOKE", "DENY"],
         {:ok, _privileges, rest} <- privileges(rest) do
      case object(rest) do
        {:ok, "", [token | _more]} when verb == "DENY" -> denied(token)
        {:ok, _object, rest} -> after_object(verb, rest)
        :error -> object_error(rest)
        :refuse -> nil
      end
    else
      {:bad, token} -> identifier_error(token)
      {:keyword, token} -> SQLDdl.expected("a privilege keyword", token)
      _unread -> nil
    end
  end

  # `DENY` over no object: the position is that of the token after the privileges.
  @spec denied(SQLTokenizer.token()) :: SQLError.t()
  defp denied({:eof, _printed, _upper, _line, _col}),
    do: SQLError.parser("DENY statements must specify an object")

  defp denied({_kind, _printed, _upper, line, col}) do
    SQLError.parser("DENY statements must specify an object at Line: #{line}, Column: #{col}")
  end

  # The object after `ON` that does not read: the parser wants a name at its first bad token.
  @spec object_error([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp object_error([{:word, _p, "ON", _l, _c} | rest]) do
    names =
      case rest do
        [
          {:word, _p2, "ALL", _l2, _c2},
          {:word, _p3, kind, _l3, _c3},
          {:word, _p4, "IN", _l4, _c4},
          {:word, _p5, "SCHEMA", _l5, _c5} | more
        ]
        when kind in @all_kinds ->
          more

        [{:word, _p2, "TABLE", _l2, _c2} | more] ->
          more

        [{:word, _p2, kind, _l2, _c2} | more] when kind in @error_kinds ->
          more

        _plain ->
          rest
      end

    case bad_name(names) do
      nil -> nil
      token -> SQLDdl.expected("identifier", token)
    end
  end

  defp object_error(_tokens), do: nil

  @spec bad_name([SQLTokenizer.token()]) :: SQLTokenizer.token() | nil
  defp bad_name([{kind, _p, _u, _l, _c} | rest]) when kind in [:word, :quoted],
    do: after_part(rest)

  defp bad_name([token | _rest]), do: token
  defp bad_name([]), do: nil

  @spec after_part([SQLTokenizer.token()]) :: SQLTokenizer.token() | nil
  defp after_part([{:symbol, mark, _u, _l, _c} | more]) when mark in [".", ","],
    do: bad_name(more)

  defp after_part(_rest), do: nil

  @spec after_object(binary(), [SQLTokenizer.token()]) ::
          SQLError.t() | nil
  defp after_object(verb, [next | _more] = rest) do
    case direction(verb, rest) do
      {:ok, _direction, rest} -> after_direction(verb, rest)
      :error -> SQLDdl.expected(if(verb == "REVOKE", do: "FROM", else: "TO"), next)
    end
  end

  defp after_object(_verb, []), do: nil

  @spec after_direction(binary(), [SQLTokenizer.token()]) ::
          SQLError.t() | nil
  defp after_direction(_verb, []), do: nil

  defp after_direction(verb, rest) do
    case grantees(rest) do
      {:ok, _grantees, rest} ->
        with {:ok, _tail, [next | _more]} <- tail(verb, rest), false <- SQLDdl.end_of?(next) do
          SQLDdl.expected("end of statement", next)
        else
          {:bad, token} -> identifier_error(token)
          _valid -> nil
        end

      {:bad, token} ->
        identifier_error(token)

      :refuse ->
        nil
    end
  end

  # The parser wants a name at `token`. It says so for a symbol, a number or the end of the
  # text; for any other token the double has not read what it says.
  @spec identifier_error(SQLTokenizer.token()) :: SQLError.t() | nil
  defp identifier_error({kind, _printed, _upper, _line, _col} = token)
       when kind in [:symbol, :number, :eof],
       do: SQLDdl.expected("identifier", token)

  defp identifier_error(_token), do: nil

  @spec privileges([SQLTokenizer.token()]) ::
          {:ok, binary(), [SQLTokenizer.token()]}
          | :error
          | {:bad, SQLTokenizer.token()}
          | {:keyword, SQLTokenizer.token()}
  defp privileges([{:word, _p, "ALL", _l, _c}, {:word, _p2, "PRIVILEGES", _l2, _c2} | rest]),
    do: {:ok, "ALL PRIVILEGES", rest}

  defp privileges([{:word, _p, "ALL", _l, _c} | rest]), do: {:ok, "ALL", rest}
  defp privileges(tokens), do: privilege_list(tokens, [])

  @spec privilege_list([SQLTokenizer.token()], [binary()]) ::
          {:ok, binary(), [SQLTokenizer.token()]}
          | :error
          | {:bad, SQLTokenizer.token()}
          | {:keyword, SQLTokenizer.token()}
  defp privilege_list([{:word, _p, word, _l, _c} | rest], found) when word in @privileges do
    with {:ok, columns, rest} <- columns(word, rest),
         do: more_privileges([word <> columns | found], rest)
  end

  # `DATABASE ROLE r`, like `ROLE r` below.
  defp privilege_list(
         [{:word, _p, "DATABASE", _l, _c}, {:word, _p2, "ROLE", _l2, _c2} | rest],
         found
       ) do
    case grantee_name(rest) do
      {:ok, name, rest} -> more_privileges(["DATABASE ROLE " <> name | found], rest)
      {:bad, _token} = bad -> bad
    end
  end

  # `ROLE r`: a role is a privilege here, with a name.
  defp privilege_list([{:word, _p, "ROLE", _l, _c} | rest], found) do
    case grantee_name(rest) do
      {:ok, name, rest} -> more_privileges(["ROLE " <> name | found], rest)
      {:bad, _token} = bad -> bad
    end
  end

  # After a comma the parser wants a privilege, and says so at the token that is none.
  defp privilege_list([{kind, _p, _u, _l, _c} = token | _rest], [_found | _more])
       when kind in [:word, :quoted, :string, :number, :symbol],
       do: {:keyword, token}

  defp privilege_list(_tokens, _found), do: :error

  @spec more_privileges([binary()], [SQLTokenizer.token()]) ::
          {:ok, binary(), [SQLTokenizer.token()]}
          | :error
          | {:bad, SQLTokenizer.token()}
          | {:keyword, SQLTokenizer.token()}
  defp more_privileges(found, [{:symbol, ",", _p, _l, _c} | more]),
    do: privilege_list(more, found)

  defp more_privileges(found, rest), do: {:ok, found |> Enum.reverse() |> Enum.join(", "), rest}

  @spec columns(binary(), [SQLTokenizer.token()]) ::
          {:ok, binary(), [SQLTokenizer.token()]} | :error
  defp columns(word, [{:symbol, "(", _p, _l, _c} | rest]) when word in @column_privileges do
    case name_list(rest, []) do
      {:ok, names, [{:symbol, ")", _p2, _l2, _c2} | rest]} -> {:ok, " (" <> names <> ")", rest}
      _other -> :error
    end
  end

  defp columns(_word, rest), do: {:ok, "", rest}

  # `ON ...`, or nothing. `:refuse` for an object the double has not worded.
  @spec object([SQLTokenizer.token()]) ::
          {:ok, binary(), [SQLTokenizer.token()]} | :error | :refuse
  # `FUTURE` before `TO` or `FROM` is a name (`GRANT SELECT ON future TO u`, verified).
  defp object(
         [
           {:word, _p, "ON", _l, _c},
           {:word, _p2, "FUTURE", _l2, _c2},
           {:word, _p3, to, _l3, _c3} | _rest
         ] = tokens
       )
       when to in ["TO", "FROM"],
       do: object_names(tl(tokens))

  defp object([{:word, _p, "ON", _l, _c}, {:word, _p2, word, _l2, _c2} | _rest])
       when word in @unworded_objects,
       do: :refuse

  defp object([
         {:word, _p, "ON", _l, _c},
         {:word, _p2, "ALL", _l2, _c2},
         {:word, _p3, word, _l3, _c3} | _rest
       ])
       when word in @unworded_all,
       do: :refuse

  defp object([{:word, _p, "ON", _l, _c} | rest]), do: object_names(rest)
  defp object(rest), do: {:ok, "", rest}

  @spec object_names([SQLTokenizer.token()]) ::
          {:ok, binary(), [SQLTokenizer.token()]} | :error | :refuse
  defp object_names([
         {:word, _p, "ALL", _l, _c},
         {:word, _p2, kind, _l2, _c2},
         {:word, _p3, "IN", _l3, _c3},
         {:word, _p4, "SCHEMA", _l4, _c4} | rest
       ])
       when kind in @all_kinds do
    with {:ok, names, rest} <- name_list(rest, []),
         do: {:ok, "ON ALL #{kind} IN SCHEMA #{names}", rest}
  end

  defp object_names([{:word, _p, "TABLE", _l, _c} | rest]), do: plain_names(rest)

  # A function takes one name and, in the engine's text, arguments: that is not worded.
  defp object_names([{:word, _p, "FUNCTION", _l, _c} | rest]) do
    case dotted(rest) do
      {:ok, _name, [{:symbol, mark, _p2, _l2, _c2} | _more]} when mark in [",", "("] -> :refuse
      {:ok, name, rest} -> {:ok, "ON FUNCTION " <> name, rest}
      _no_name -> :error
    end
  end

  defp object_names([{:word, _p, kind, _l, _c} | rest]) when kind in @object_kinds do
    with {:ok, names, rest} <- name_list(rest, []), do: {:ok, "ON #{kind} #{names}", rest}
  end

  defp object_names(tokens), do: plain_names(tokens)

  @spec plain_names([SQLTokenizer.token()]) :: {:ok, binary(), [SQLTokenizer.token()]} | :error
  defp plain_names(tokens) do
    with {:ok, names, rest} <- name_list(tokens, []), do: {:ok, "ON " <> names, rest}
  end

  # `a.b, c`: names as written, joined by a comma and a space.
  @spec name_list([SQLTokenizer.token()], [binary()]) ::
          {:ok, binary(), [SQLTokenizer.token()]} | :error
  defp name_list(tokens, found) do
    case dotted(tokens) do
      {:ok, name, rest} ->
        found = [name | found]

        case rest do
          [{:symbol, ",", _p, _l, _c} | more] ->
            name_list(more, found)

          _end ->
            {:ok, found |> Enum.reverse() |> Enum.join(", "), rest}
        end

      _no_name ->
        :error
    end
  end

  # The token the parser wants a name at, when there is none, is `{:bad, token}`.
  @spec dotted([SQLTokenizer.token()]) ::
          {:ok, binary(), [SQLTokenizer.token()]} | {:bad, SQLTokenizer.token()} | :refuse
  defp dotted([{kind, printed, _u, _l, _c} | rest]) when kind in [:word, :quoted] do
    case rest do
      [{:symbol, ".", _p, _l2, _c2} | more] ->
        with {:ok, tail, rest} <- dotted(more), do: {:ok, printed <> "." <> tail, rest}

      _end_of_name ->
        {:ok, printed, rest}
    end
  end

  defp dotted([token | _rest]), do: {:bad, token}
  defp dotted([]), do: :refuse

  @spec direction(binary(), [SQLTokenizer.token()]) ::
          {:ok, binary(), [SQLTokenizer.token()]} | :error
  defp direction("REVOKE", [{:word, _p, "FROM", _l, _c} | rest]), do: {:ok, "FROM", rest}

  defp direction(verb, [{:word, _p, "TO", _l, _c} | rest]) when verb in ["GRANT", "DENY"],
    do: {:ok, "TO", rest}

  defp direction(_verb, _tokens), do: :error

  @typep named_or_not :: {:ok, binary(), [SQLTokenizer.token()]} | {:bad, SQLTokenizer.token()}

  @spec grantees([SQLTokenizer.token()]) :: named_or_not() | :refuse
  defp grantees(tokens), do: grantee_list(tokens, [])

  @spec grantee_list([SQLTokenizer.token()], [binary()]) :: named_or_not() | :refuse
  defp grantee_list(tokens, found) do
    with {:ok, grantee, rest} <- grantee(tokens) do
      found = [grantee | found]

      case rest do
        [{:symbol, ",", _p, _l, _c} | more] ->
          grantee_list(more, found)

        _end ->
          {:ok, found |> Enum.reverse() |> Enum.join(", "), rest}
      end
    end
  end

  # A grantee may be written with `ROLE`, `GROUP` or `USER` before it, which then wants a
  # name. `PUBLIC` is the engine's own and ends the list (`PUBLIC, x` is not read by it).
  @spec grantee([SQLTokenizer.token()]) :: named_or_not() | :refuse
  defp grantee([{:word, _p, "PUBLIC", _l, _c}, {:symbol, mark, _p2, _l2, _c2} | _rest])
       when mark in [",", "."],
       do: :refuse

  defp grantee([{:word, _p, "PUBLIC", _l, _c} | rest]), do: {:ok, "PUBLIC ", rest}

  # `DATABASE ROLE d` and `APPLICATION ROLE a` are kinds of grantee of two words.
  defp grantee([{:word, _p, first, _l, _c}, {:word, _p2, "ROLE", _l2, _c2}, next | rest])
       when first in ["DATABASE", "APPLICATION"] do
    with {:ok, name, rest} <- grantee_name([next | rest]),
         do: {:ok, first <> " ROLE " <> name, rest}
  end

  defp grantee([{:word, _p, kind, _l, _c}, next | rest]) when kind in @grantee_kinds do
    with {:ok, name, rest} <- grantee_name([next | rest]), do: {:ok, kind <> " " <> name, rest}
  end

  defp grantee(tokens), do: grantee_name(tokens)

  @spec grantee_name([SQLTokenizer.token()]) :: named_or_not()
  defp grantee_name([{:string, printed, _u, _l, _c} | rest]), do: {:ok, printed, rest}
  defp grantee_name(tokens), do: dotted(tokens)

  # What may follow the grantees, in the order the parser reads it.
  @spec tail(binary(), [SQLTokenizer.token()]) ::
          {:ok, [binary()], [SQLTokenizer.token()]} | {:bad, SQLTokenizer.token()}
  defp tail("GRANT", tokens) do
    with {:ok, option, tokens} <- grant_option(tokens),
         {:ok, grantor, tokens} <- named(tokens, "AS"),
         {:ok, granted, tokens} <- granted_by(tokens),
         do: {:ok, option ++ grantor ++ granted, tokens}
  end

  defp tail("REVOKE", tokens) do
    with {:ok, granted, tokens} <- granted_by(tokens),
         {:ok, cascade, tokens} <- cascade(tokens),
         do: {:ok, granted ++ cascade, tokens}
  end

  defp tail("DENY", tokens) do
    with {:ok, cascade, tokens} <- cascade(tokens),
         {:ok, grantor, tokens} <- named(tokens, "AS"),
         do: {:ok, cascade ++ grantor, tokens}
  end

  @spec grant_option([SQLTokenizer.token()]) :: {:ok, [binary()], [SQLTokenizer.token()]}
  defp grant_option([
         {:word, _p, "WITH", _l, _c},
         {:word, _p2, "GRANT", _l2, _c2},
         {:word, _p3, "OPTION", _l3, _c3} | rest
       ]),
       do: {:ok, ["WITH", "GRANT", "OPTION"], rest}

  defp grant_option(tokens), do: {:ok, [], tokens}

  @spec named([SQLTokenizer.token()], binary()) ::
          {:ok, [binary()], [SQLTokenizer.token()]} | {:bad, SQLTokenizer.token()}
  defp named([{:word, _p, word, _l, _c}, {kind, printed, _u, _l2, _c2} | more], word)
       when kind in [:word, :quoted, :string],
       do: {:ok, [word, printed], more}

  defp named([{:word, _p, word, _l, _c}, token | _more], word), do: {:bad, token}
  defp named(tokens, _word), do: {:ok, [], tokens}

  @spec granted_by([SQLTokenizer.token()]) ::
          {:ok, [binary()], [SQLTokenizer.token()]} | {:bad, SQLTokenizer.token()}
  defp granted_by([
         {:word, _p, "GRANTED", _l, _c},
         {:word, _p2, "BY", _l2, _c2},
         {kind, printed, _u, _l3, _c3} | rest
       ])
       when kind in [:word, :quoted, :string],
       do: {:ok, ["GRANTED", "BY", printed], rest}

  defp granted_by([{:word, _p, "GRANTED", _l, _c}, {:word, _p2, "BY", _l2, _c2}, token | _rest]),
    do: {:bad, token}

  defp granted_by(tokens), do: {:ok, [], tokens}

  @spec cascade([SQLTokenizer.token()]) :: {:ok, [binary()], [SQLTokenizer.token()]}
  defp cascade(tokens) do
    case SQLDdl.cascade(tokens) do
      {:ok, word, rest} -> {:ok, [word], rest}
      :none -> {:ok, [], tokens}
    end
  end
end
