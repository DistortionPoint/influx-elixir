defmodule InfluxElixir.Client.Local.SQLDmlInsert do
  @moduledoc false
  # The planner's answer to an `INSERT`, which it never runs (verified against InfluxDB 3 Core
  # 3.10.1), for `InfluxElixir.Client.Local.SQLDml`. The steps are the planner's, in its order:
  #
  #   1. the parser reads the statement: `INSERT [INTO] [TABLE] name [(column, ...)] source`,
  #      the source a `VALUES` list, a `SELECT`, a `WITH`, a `TABLE name` or a parenthesized one
  #   2. a `RETURNING` clause is refused (`Insert-returning clause not supported`)
  #   3. the table is looked up (`SQLDmlName.lookup/2`)
  #   4. the columns listed are checked in order: one the table lacks is `No field named
  #      <name>. Valid fields are ...`, one listed twice `Schema contains duplicate unqualified
  #      field name`
  #   5. the source is planned:
  #        * `VALUES`: a cell that is a placeholder with no number is `Can't parse
  #          placeholder`; then each cell is read in order, row by row (an unknown function, a
  #          name, which no cell has a table for: `No field named f.`, a type the planner
  #          cannot plan); then the rows are counted against the columns; then column by
  #          column each cell is typed, as a select item is, and cast to the column's type,
  #          which fails for a few pairs (`Execution error: type mismatch and can't cast`)
  #        * `SELECT items [FROM table]`: the table; each item read as an operand of that table
  #          (the errors of several items are one error of the planner, `read_items/3`); that no
  #          two items have the same name (`SQLDmlItem`); each item typed, and what typing its
  #          top does not reach (`project_items/2`); that no column of the table is named as an
  #          item; the count of the items against the columns (`Column count doesn't match
  #          insert query!`); each item's conversion to its column (`Cannot automatically
  #          convert`)
  #        * `TABLE name` is `Query TABLE name not implemented yet`
  #   6. `DML not supported: Insert Into`
  #
  # A source whose planning the double does not model (a `WITH`, a union, a select with a
  # clause) is a refusal by name once the steps before it have passed.

  alias InfluxElixir.Client.Local.{SQLDdl, SQLDml, SQLDmlExpr, SQLDmlItem, SQLDmlName}
  alias InfluxElixir.Client.Local.{SQLDmlOperand, SQLError, SQLTokenizer}

  @query_body "SELECT, VALUES, or a subquery in the query body"

  @typep token :: SQLTokenizer.token()

  # The token that ends a statement: the end of the text, or its `;`.
  defguardp is_end(kind, upper) when kind == :eof or (kind == :symbol and upper == ";")

  @typep source ::
           {:values, [[SQLDmlExpr.cell()]]}
           | {:select, SQLDmlExpr.select()}
           | {:table, binary()}
           | {:unmodelled, binary()}
           | :default_values

  @typedoc "What the parser reads of an `INSERT`."
  @type parsed :: %{
          reference: [binary()],
          partitioned: boolean(),
          listed: [{binary(), boolean()}] | nil,
          source: source(),
          trailing: [token()]
        }

  @doc """
  The answer to an `INSERT` from the tokens after the keyword and the token that ends it.
  """
  @spec error([token()], token(), SQLDml.env()) :: SQLError.t() | map()
  def error(tokens, stop, env) do
    with {:ok, parsed} <- parse(tokens, stop),
         :ok <- SQLDmlName.arity(parsed.reference),
         :ok <- partitioned(parsed.partitioned),
         :ok <- default_values(parsed.source),
         :ok <- returning(parsed.trailing) do
      planned(parsed.reference, parsed.listed, continued(parsed.source, parsed.trailing), env)
    else
      {:error, error} -> error
      {:refuse, why} -> SQLDml.not_modelled(:insert, why)
    end
  end

  @doc """
  What the parser reads of an `INSERT` from the tokens after the keyword and the token that ends
  it: its errors are the parser's own, which a statement that is followed by another has before
  it is planned.
  """
  @spec parse([token()], token()) ::
          {:ok, parsed()} | {:error, SQLError.t() | map()} | {:refuse, binary()}
  def parse([{:word, _p, word, _l, _c} | _rest], _stop)
      when word in ["OVERWRITE", "OR", "IGNORE"],
      do: {:refuse, "that spelling"}

  def parse(tokens, stop) do
    with {:ok, reference, rest} <- SQLDmlName.reference(skip_keywords(tokens)),
         {:ok, partitioned, rest} <- partition(rest ++ [stop]),
         {:ok, listed, rest} <- column_list(rest),
         {:ok, source, trailing} <- source(rest, listed, stop),
         {:ok, trailing} <- SQLDmlExpr.query_suffix(trailing),
         :ok <- trailing_syntax(trailing) do
      {:ok,
       %{
         reference: reference,
         partitioned: partitioned,
         listed: listed,
         source: source,
         trailing: trailing
       }}
    end
  end

  # `INTO` and then `TABLE` may precede the name.
  @spec skip_keywords([token()]) :: [token()]
  defp skip_keywords([{:word, _p, "INTO", _l, _c} | rest]), do: skip_table(rest)
  defp skip_keywords(tokens), do: skip_table(tokens)

  @spec skip_table([token()]) :: [token()]
  defp skip_table([{:word, _p, "TABLE", _l, _c} | rest]), do: rest
  defp skip_table(tokens), do: tokens

  # ---------------------------------------------------------------------------
  # Reading the statement
  # ---------------------------------------------------------------------------

  # `PARTITION (expr, ...)` between the table and the columns or the source.
  @spec partition([token()]) ::
          {:ok, boolean(), [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp partition([
         {:word, _p, "PARTITION", _l, _c} | [{:symbol, "(", _u, _l2, _c2} | _more] = rest
       ]) do
    with {:ok, true, rest} <- SQLDmlExpr.table_args(rest), do: {:ok, true, rest}
  end

  defp partition(tokens), do: {:ok, false, tokens}

  # The columns an insert lists (`nil` for none, as `()` is a parse error), as the names the
  # table knows them by and whether each was quoted, and the tokens after them. A parenthesis
  # that opens a query is the source, not a list.
  @spec column_list([token()]) ::
          {:ok, [{binary(), boolean()}] | nil, [token()]} | {:error, SQLError.t()}
  defp column_list([{:symbol, "(", _u, _l, _c}, {:word, _p, word, _l2, _c2} | _rest] = source)
       when word in ["SELECT", "WITH"],
       do: {:ok, nil, source}

  defp column_list([{:symbol, "(", _u, _l, _c} | rest]), do: listed(rest, [])
  defp column_list(source), do: {:ok, nil, source}

  @spec listed([token()], [{binary(), boolean()}]) ::
          {:ok, [{binary(), boolean()}], [token()]} | {:error, SQLError.t()}
  defp listed([{:word, printed, _u, _l, _c} | rest], found),
    do: listed_next(rest, [{String.downcase(printed), false} | found])

  defp listed([{:quoted, printed, _u, _l, _c} | rest], found) do
    name = printed |> String.slice(1..-2//1) |> String.replace("\"\"", "\"")
    listed_next(rest, [{name, true} | found])
  end

  defp listed([{:string, printed, _u, _l, _c} | rest], found) do
    name = printed |> String.slice(1..-2//1) |> String.replace("''", "'")
    listed_next(rest, [{name, true} | found])
  end

  defp listed([token | _rest], _found), do: {:error, SQLDdl.expected("identifier", token)}

  @spec listed_next([token()], [{binary(), boolean()}]) ::
          {:ok, [{binary(), boolean()}], [token()]} | {:error, SQLError.t()}
  defp listed_next([{:symbol, ",", _u, _l, _c} | rest], found), do: listed(rest, found)

  defp listed_next([{:symbol, ")", _u, _l, _c} | rest], found),
    do: {:ok, Enum.reverse(found), rest}

  defp listed_next([token | _rest], _found), do: {:error, SQLDdl.expected(")", token)}

  # What the parser says of the text after the table and its column list, and the source.
  @spec source([token()], term(), token()) ::
          {:ok, source(), [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp source([{kind, _p, upper, _l, _c} = token], _listed, _stop) when is_end(kind, upper),
    do: {:error, SQLDdl.expected(@query_body, token)}

  defp source([{:word, _p, "VALUES", _l, _c} | rest], _listed, _stop) do
    with {:ok, rows, trailing} <- SQLDmlExpr.rows(rest), do: {:ok, {:values, rows}, trailing}
  end

  defp source([{:word, _p, "SELECT", _l, _c} | rest], _listed, _stop) do
    with {:ok, select} <- SQLDmlExpr.select(rest), do: {:ok, {:select, select}, select.rest}
  end

  defp source([{:word, _p, "WITH", _l, _c} | rest], _listed, _stop), do: with_head(rest)

  defp source([{:word, _p, "TABLE", _l, _c} | rest], _listed, stop), do: table_source(rest, stop)

  defp source(
         [{:word, _p, "DEFAULT", _l, _c}, {:word, _p2, "VALUES", _l2, _c2} | _end],
         nil,
         _stop
       ),
       do: {:ok, :default_values, []}

  defp source([{:symbol, "(", _u, _l, _c} | _rest] = tokens, listed, stop),
    do: parenthesized(tokens, listed, stop)

  defp source([{kind, _printed, _u, _l, _c} = token | _rest], _listed, _stop)
       when kind in [:word, :number, :string],
       do: {:error, SQLDdl.expected(@query_body, token)}

  defp source(_tokens, _listed, _stop),
    do: {:refuse, "an insert whose source the double does not read"}

  # `WITH name AS (`: what the parser says before the body; the body is not read.
  @spec with_head([token()]) ::
          {:ok, source(), [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp with_head([{:word, _p, name, _l, _c} | rest]) when name not in ["RECURSIVE"] do
    case rest do
      [{:word, _p2, "AS", _l2, _c2}, {:symbol, "(", _u, _l3, _c3} | _more] ->
        {:ok, {:unmodelled, "an insert whose source is a WITH"}, []}

      [{:word, _p2, "AS", _l2, _c2}, token | _more] ->
        {:error, SQLDdl.expected("(", token)}

      [{:symbol, "(", _u, _l2, _c2} | _more] ->
        {:refuse, "a WITH with a column list"}

      [token | _more] ->
        {:error, SQLDdl.expected("AS", token)}
    end
  end

  defp with_head(_tokens), do: {:refuse, "a WITH the double does not read"}

  @spec table_source([token()], token()) ::
          {:ok, source(), [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp table_source([{:word, printed, _u, _l, _c}, next | more], _stop) do
    case trailing_syntax([next | more]) do
      :ok -> {:ok, {:table, printed}, [next | more]}
      {:error, _error} -> {:refuse, "a TABLE source that goes on"}
    end
  end

  defp table_source([token], _stop), do: {:error, SQLDdl.expected("Table name", token)}
  defp table_source(_tokens, _stop), do: {:refuse, "a TABLE source the double does not read"}

  # `( query )` is the query; one that does not close is the parser's error.
  @spec parenthesized([token()], term(), token()) ::
          {:ok, source(), [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp parenthesized([_open | rest], listed, stop) do
    case closing(rest, 0, []) do
      {:ok, inner, trailing} ->
        with {:ok, source, [_end]} <- source(inner ++ [stop], listed, stop),
             do: {:ok, source, trailing}

      :none ->
        {:refuse, "a parenthesized source that does not close"}
    end
  end

  @spec closing([token()], non_neg_integer(), [token()]) ::
          {:ok, [token()], [token()]} | :none
  defp closing([], _depth, _found), do: :none

  defp closing([{:symbol, ")", _u, _l, _c} | rest], 0, found),
    do: {:ok, Enum.reverse(found), rest}

  defp closing([{:symbol, ")", _u, _l, _c} = token | rest], depth, found),
    do: closing(rest, depth - 1, [token | found])

  defp closing([{:symbol, "(", _u, _l, _c} = token | rest], depth, found),
    do: closing(rest, depth + 1, [token | found])

  defp closing([token | rest], depth, found), do: closing(rest, depth, [token | found])

  # What follows the source: nothing, or the words that go on a query or an insert, which the
  # planner reads (`RETURNING` is its error, the rest is not modelled). Anything else is the
  # parser's error.
  @continuing ~w(RETURNING ON AS PARTITION ORDER FETCH UNION EXCEPT INTERSECT FOR
                 WHERE GROUP HAVING WINDOW FROM JOIN INNER LEFT RIGHT FULL CROSS NATURAL USING
                 QUALIFY SET SETTINGS)

  @spec trailing_syntax([token()]) :: :ok | {:error, SQLError.t()}
  defp trailing_syntax([]), do: :ok

  defp trailing_syntax([{:word, _p, upper, _l, _c} | _rest]) when upper in @continuing, do: :ok

  defp trailing_syntax([{kind, _p, upper, _l, _c}]) when is_end(kind, upper), do: :ok

  defp trailing_syntax([token | _rest]),
    do: {:error, SQLDdl.expected("end of statement", token)}

  @spec partitioned(boolean()) :: :ok | {:error, SQLError.t()}
  defp partitioned(true), do: {:error, SQLError.planning("Partitioned inserts not yet supported")}
  defp partitioned(false), do: :ok

  # `INSERT INTO t DEFAULT VALUES` is refused as the statement is read, before the table is.
  @spec default_values(source()) :: :ok | {:error, SQLError.t()}
  defp default_values(:default_values),
    do: {:error, SQLError.planning("Inserts without a source not supported")}

  defp default_values(_source), do: :ok

  @spec returning([token()]) :: :ok | {:error, SQLError.t()}
  defp returning([
         {:word, _p, "ON", _l, _c},
         {:word, _p2, "CONFLICT", _l2, _c2},
         {:word, _p3, "DO", _l3, _c3},
         {:word, _p4, "NOTHING", _l4, _c4} | _rest
       ]),
       do: {:error, SQLError.planning("Insert-on clause not supported")}

  defp returning([{:word, _p, "RETURNING", _l, _c} | _rest]),
    do: {:error, SQLError.planning("Insert-returning clause not supported")}

  defp returning([{:word, _p, "AS", _l, _c}, {kind, _p2, _u, _l2, _c2} | rest])
       when kind in [:word, :quoted] do
    case rest do
      [{:word, _p3, "RETURNING", _l3, _c3} | _more] ->
        {:error, SQLError.planning("Insert-returning clause not supported")}

      [{kind, _p3, upper, _l3, _c3}] when is_end(kind, upper) ->
        {:error, SQLError.planning("Inserts with an alias not supported")}

      _other ->
        :ok
    end
  end

  defp returning(_tokens), do: :ok

  # A source that goes on with a clause the double does not read is planned no further than the
  # table and its columns.
  @spec continued(source(), [token()]) :: source()
  defp continued(source, []), do: source

  defp continued(source, [{kind, _p, upper, _l, _c}]) when is_end(kind, upper), do: source

  defp continued(_source, _trailing),
    do: {:unmodelled, "an insert with a clause after its source"}

  # ---------------------------------------------------------------------------
  # Planning
  # ---------------------------------------------------------------------------

  @spec planned([binary()], term(), source(), SQLDml.env()) :: SQLError.t() | map()
  defp planned(reference, listed, source, env) do
    with {:ok, table} <- SQLDmlName.lookup(reference, env.tables),
         {columns, types} = SQLDml.table_schema(table, env),
         {:ok, targets} <- targets(listed, columns),
         :ok <- plan_source(source, Enum.map(targets, &types[&1]), env) do
      SQLDml.dml(:insert)
    else
      {:error, error} -> error
      {:refuse, why} -> SQLDml.not_modelled(:insert, why)
    end
  end

  # The columns the source's values go to, in order: the ones listed (checked one by one), or
  # all of the table's.
  @spec targets([{binary(), boolean()}] | nil, [binary()]) ::
          {:ok, [binary()]} | {:error, map()} | {:refuse, binary()}
  defp targets(nil, columns), do: {:ok, columns}

  defp targets(listed, columns) do
    Enum.reduce_while(listed, {:ok, []}, fn {name, quoted?}, {:ok, seen} ->
      cond do
        name in seen -> {:halt, {:error, duplicate(name)}}
        name in columns -> {:cont, {:ok, seen ++ [name]}}
        true -> {:halt, unknown(name, quoted?, columns)}
      end
    end)
  end

  @spec duplicate(binary()) :: map()
  defp duplicate(name),
    do: %{
      status: 500,
      body: "Schema error: Schema contains duplicate unqualified field name " <> name
    }

  # A quoted name that a column has in lower case gets the planner's hint on case.
  @spec unknown(binary(), boolean(), [binary()]) :: {:error, map()} | {:refuse, binary()}
  defp unknown(name, false, columns),
    do: {:error, SQLDmlName.no_field(SQLDmlName.quote_ident(name), name, nil, columns)}

  defp unknown(name, true, columns) do
    cond do
      name == String.downcase(name) and SQLDmlName.quote_ident(name) == name ->
        {:error, SQLDmlName.no_field(name, name, nil, columns)}

      String.downcase(name) in columns and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) ->
        {:error, SQLDmlName.case_hint(name, columns)}

      true ->
        {:refuse, "a quoted column name the double does not print"}
    end
  end

  @spec plan_source(source(), [binary() | nil], SQLDml.env()) ::
          :ok | {:error, map()} | {:refuse, binary()}
  defp plan_source({:unmodelled, why}, _types, _env), do: {:refuse, why}

  defp plan_source({:table, name}, _types, _env) do
    {:error,
     %{
       status: 405,
       body: "This feature is not implemented: Query TABLE #{name} not implemented yet"
     }}
  end

  defp plan_source({:values, rows}, types, env), do: plan_values(rows, types, env)
  defp plan_source({:select, select}, types, env), do: plan_select(select, types, env)

  # ---------------------------------------------------------------------------
  # VALUES
  # ---------------------------------------------------------------------------

  @spec plan_values([[SQLDmlExpr.cell()]], [binary() | nil], SQLDml.env()) ::
          :ok | {:error, map()} | {:refuse, binary()}
  defp plan_values(rows, types, env) do
    ctx = SQLDml.empty_context(env)

    with :ok <- placeholders(rows, length(types)),
         rows = Enum.map(rows, &Enum.map(&1, fn cell -> numbered(cell) end)),
         :ok <- read_cells(rows, ctx),
         :ok <- row_lengths(rows, length(types)) do
      type_cells(rows, types, ctx)
    end
  end

  # A placeholder alone in a cell is parsed as the number of the column it stands for before
  # the rows are planned: by the position of its cell, then by its text.
  @spec placeholders([[SQLDmlExpr.cell()]], non_neg_integer()) :: :ok | {:error, map()}
  defp placeholders(rows, fields) do
    rows
    |> Enum.flat_map(&Enum.with_index/1)
    |> Enum.reduce_while(:ok, fn
      {{:bare_placeholder, text}, index}, :ok ->
        case placeholder(text, index, fields) do
          nil -> {:cont, :ok}
          message -> {:halt, {:error, SQLError.planning(message)}}
        end

      {_cell, _index}, :ok ->
        {:cont, :ok}
    end)
  end

  @spec placeholder(binary(), non_neg_integer(), non_neg_integer()) :: binary() | nil
  defp placeholder(text, index, fields) do
    cond do
      not Regex.match?(~r/\A\$[0-9]+\z/, text) ->
        "Can't parse placeholder: " <> text

      String.to_integer(binary_part(text, 1, byte_size(text) - 1)) > 18_446_744_073_709_551_615 ->
        "Can't parse placeholder: " <> text

      index >= fields ->
        "Placeholder $#{index + 1} refers to a non existent column"

      true ->
        nil
    end
  end

  # What the planner makes of a placeholder that stands alone: a parameter, or the error of
  # index zero.
  @spec numbered(SQLDmlExpr.cell()) :: SQLDmlExpr.cell()
  defp numbered({:bare_placeholder, text}) do
    if Regex.match?(~r/\A\$0+\z/, text), do: {:zero_param, text}, else: {:param, text}
  end

  defp numbered(cell), do: cell

  @spec read_cells([[SQLDmlExpr.cell()]], SQLDmlOperand.ctx()) :: SQLDmlOperand.check()
  defp read_cells(rows, ctx) do
    rows
    |> Enum.concat()
    |> Enum.reduce_while(:ok, fn
      {:opaque, why}, :ok ->
        {:halt, {:refuse, why}}

      cell, :ok ->
        with :ok <- SQLDmlOperand.eager(cell, ctx), :ok <- SQLDmlOperand.lazy(cell, ctx) do
          {:cont, :ok}
        else
          failure -> {:halt, failure}
        end
    end)
  end

  @spec row_lengths([[SQLDmlExpr.cell()]], non_neg_integer()) :: :ok | {:error, map()}
  defp row_lengths(rows, expected) do
    case rows
         |> Enum.with_index()
         |> Enum.find(fn {row, _index} -> length(row) != expected end) do
      nil ->
        :ok

      {row, index} ->
        {:error,
         SQLError.planning(
           "Inconsistent data length across values list: got #{length(row)} values in row " <>
             "#{index} but expected #{expected}"
         )}
    end
  end

  # Column by column, each cell is typed and then cast to the column's type.
  @spec type_cells([[SQLDmlExpr.cell()]], [binary() | nil], SQLDmlOperand.ctx()) ::
          SQLDmlOperand.check()
  defp type_cells(rows, target_types, ctx) do
    rows
    |> Enum.zip_with(& &1)
    |> Enum.zip(target_types)
    |> Enum.reduce_while(:ok, fn {cells, target}, :ok ->
      case type_column(cells, target, ctx) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  @spec type_column([SQLDmlExpr.ast()], binary() | nil, SQLDmlOperand.ctx()) ::
          SQLDmlOperand.check()
  defp type_column(cells, target, ctx) do
    Enum.reduce_while(cells, :ok, fn cell, :ok ->
      with :ok <- SQLDmlOperand.plan_top(cell, ctx),
           :ok <- SQLDmlOperand.convert(cell, target, ctx, :values) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # SELECT
  # ---------------------------------------------------------------------------

  @spec plan_select(SQLDmlExpr.select(), [binary() | nil], SQLDml.env()) ::
          :ok | {:error, map()} | {:refuse, binary()}
  defp plan_select(%{items: items, from: from}, types, env) do
    with {:ok, ctx, columns} <- select_context(from, env),
         expanded = expand(items, columns),
         operands = Enum.map(expanded, &elem(&1, 0)),
         :ok <- read_items(items, ctx, from),
         :ok <- SQLDmlItem.unique(expanded, ctx),
         :ok <- project_items(operands, ctx),
         :ok <- grouped(operands),
         :ok <- SQLDmlItem.ambiguous(expanded, ctx),
         :ok <- same_count(operands, types) do
      convert_items(operands, types, ctx)
    end
  end

  @spec select_context({[binary()], binary() | nil} | nil, SQLDml.env()) ::
          {:ok, SQLDmlOperand.ctx(), [binary()]} | {:error, map()} | {:refuse, binary()}
  defp select_context(nil, env), do: {:ok, SQLDml.empty_context(env), []}

  defp select_context({reference, alias_name}, env) do
    with {:ok, table} <- SQLDmlName.lookup(reference, env.tables) do
      relation = if alias_name, do: [alias_name], else: reference
      ctx = SQLDml.context(table, relation, env)
      {:ok, ctx, ctx.columns}
    end
  end

  # The operands a select list stands for, each with its alias: `*` is each column of the table.
  @spec expand([{:expr, SQLDmlExpr.ast(), SQLDmlExpr.item_alias()} | :star], [binary()]) ::
          [{SQLDmlExpr.ast(), SQLDmlExpr.item_alias()}]
  defp expand(items, columns) do
    Enum.flat_map(items, fn
      {:expr, operand, item_alias} -> [{operand, item_alias}]
      :star -> Enum.map(columns, &{{:ref, [{&1, false}]}, nil})
    end)
  end

  # The planner reads every item of the list and keeps what it finds wrong in each: the names and
  # calls of an item, in the order of the item. One item with fault is that fault. Several are
  # one error of the planner that holds them all, which prints the first and is an internal
  # error (500) unless each is the planner's own (400).
  # A list that calls an aggregate and names a column outside of it is a grouping error of the
  # planner, in words (the grouping of the list, the columns it has) the double does not print:
  # it is refused once the items have been typed, whose errors it does not hide.
  @spec grouped([SQLDmlExpr.ast()]) :: SQLDmlOperand.check()
  defp grouped(operands) do
    if SQLDmlOperand.ungrouped?(operands),
      do: {:refuse, "an aggregate beside a column that is outside of one"},
      else: :ok
  end

  @spec read_items(
          [{:expr, SQLDmlExpr.ast(), SQLDmlExpr.item_alias()} | :star],
          SQLDmlOperand.ctx(),
          term()
        ) :: SQLDmlOperand.check()
  defp read_items(items, ctx, from) do
    items
    |> Enum.map(&read_item(&1, ctx, from))
    |> Enum.reject(&(&1 == :ok))
    |> together()
  end

  @spec read_item(
          {:expr, SQLDmlExpr.ast(), SQLDmlExpr.item_alias()} | :star,
          SQLDmlOperand.ctx(),
          term()
        ) :: SQLDmlOperand.check()
  defp read_item(:star, _ctx, nil),
    do: {:error, SQLError.planning("SELECT * with no tables specified is not valid")}

  defp read_item(:star, _ctx, _from), do: :ok

  defp read_item({:expr, operand, _alias}, ctx, _from) do
    with :ok <- SQLDmlOperand.eager(operand, ctx), do: SQLDmlOperand.lazy(operand, ctx)
  end

  @spec together([SQLDmlOperand.check()]) :: SQLDmlOperand.check()
  defp together([]), do: :ok
  defp together([single]), do: single
  defp together([{:refuse, _why} = refusal | _more]), do: refusal

  defp together([{:error, first} | more] = failures) do
    case Enum.find(more, &match?({:refuse, _why}, &1)) do
      {:refuse, _why} = refusal ->
        if SQLDmlOperand.unknown_function?(refusal),
          do: {:error, together_status(first, failures)},
          else: refusal

      nil ->
        {:error, together_status(first, failures)}
    end
  end

  # The first message, with the status of the planner's own errors (400) only when all are.
  @spec together_status(map(), [SQLDmlOperand.check()]) :: map()
  defp together_status(first, failures) do
    own? = Enum.all?(failures, &planner_error?/1)
    %{first | status: if(own?, do: 400, else: 500)}
  end

  defp planner_error?({:error, %{status: 400}}), do: true
  defp planner_error?(failure), do: SQLDmlOperand.unknown_function?(failure)

  # The planner builds the projection item by item: it types the item, then what the item holds
  # that typing its top did not reach (what a cast holds, whether a value can be null), before it
  # counts the items against the columns.
  @spec project_items([SQLDmlExpr.ast()], SQLDmlOperand.ctx()) :: SQLDmlOperand.check()
  defp project_items(operands, ctx) do
    Enum.reduce_while(operands, :ok, fn operand, :ok ->
      with :ok <- SQLDmlOperand.plan_top(operand, ctx),
           :ok <- SQLDmlOperand.deep(operand, ctx),
           :ok <- SQLDmlOperand.late(operand, ctx) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end)
  end

  @spec same_count([SQLDmlExpr.ast()], [binary() | nil]) :: :ok | {:error, map()}
  defp same_count(operands, targets) do
    if length(operands) == length(targets),
      do: :ok,
      else: {:error, SQLError.planning("Column count doesn't match insert query!")}
  end

  @spec convert_items([SQLDmlExpr.ast()], [binary() | nil], SQLDmlOperand.ctx()) ::
          SQLDmlOperand.check()
  defp convert_items(operands, types, ctx) do
    operands
    |> Enum.zip(types)
    |> Enum.reduce_while(:ok, fn {operand, target}, :ok ->
      case SQLDmlOperand.convert(operand, target, ctx, :planning) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end
end
