defmodule InfluxElixir.Client.Local.InfluxQL do
  @moduledoc """
  The InfluxQL `SELECT` subset `InfluxElixir.Client.Local` answers, shaped
  the way InfluxDB 3 answers it (verified against the engine; see
  `docs/design/2026-09-23_local-influxql.md`).

  InfluxQL is not SQL with other keywords. Every row carries
  `"iox::measurement"` and `"time"`; rows come back in time order; a row with
  no selected field value is dropped; an unknown column or measurement is an
  empty result, not an error; aggregates are named after the function
  (`mean`, `count`, ...) and put `time` at the lower bound the `WHERE`
  gives `time` (the epoch when it gives none), except a lone selector
  (`MAX`, `MIN`, `FIRST`, `LAST`), which returns its point's time and tags;
  `LIMIT` and `OFFSET` apply per `GROUP BY` series.

  This module is the entry point; the work is in modules of its own, which
  are pure: `InfluxElixir.Client.Local.InfluxQLParser` turns the statement
  into a query map (its checks are `InfluxQLCheck`, `InfluxQLSelectCheck`
  and `InfluxQLParens`, its words `InfluxQLReserved`, its errors
  `InfluxQLError`), `InfluxQLWhere` plans the `WHERE` (`InfluxQLTokens`,
  `InfluxQLTyped`, `InfluxQLArithmetic`, `InfluxQLTime`, `InfluxQLSql`),
  `InfluxQLRun` shapes the rows the caller has already filtered with the
  statement's `WHERE` clause (Client.Local runs it through its SQL engine)
  and put in time order, and `InfluxQLShow` answers `SHOW TAG VALUES`.

  `WHERE` follows InfluxQL, not SQL (`where_plan/3`): a missing tag is the
  empty string (`host != 'a'` keeps points without `host`, `host = ''`
  finds them), `=~ /re/` and `!~ /re/` are unanchored matches on tags and
  false on fields, `<`/`>` on a tag is false, durations (`now() - 30m`)
  are intervals, double-quoted identifiers are exact, and `NOT` is a name
  like any other (`WHERE not = 7` compares a field called `not`; another
  word right after it is left over). Compared with `time` (in any case), a
  bare integer or a duration is an offset from the epoch in nanoseconds
  (`time >= 2`, `time > 0s`, `time > 1s - 999999999ns`), `!=` and `<>` are
  the engine's planning error, and a float is refused. A quoted time is read
  by the engine's planner: one it cannot read is `'a' is not a valid
  timestamp`, one that does not fit 64-bit nanoseconds `timestamp out of
  range`; `time` standing alone is the planner's 500 ("expected an element
  on stack", "invalid expr stack") or a type error in parentheses. The
  engine pulls `time` comparisons out of the whole `WHERE` as if they were
  joined by `AND`, so one inside an `OR` is refused by name. `SHOW TAG
  VALUES [FROM m] WITH KEY = | != | =~ | !~ | IN (...)` [WHERE ...] lists
  values as the engine does, over the last 24 hours unless the `WHERE`
  bounds `time` (`parse_show_tag_values/1`).

  A reserved word (`reserved?/1`) is no bare identifier: the engine's parse
  errors for it, for a reserved word where an operand is wanted (after a
  binary operator, first in a call), for a parenthesis left open, closed
  twice or empty, for `GROUP BY time` without a call, and for a select list,
  `FROM`, `WHERE`, `GROUP BY`, `ORDER BY`, `LIMIT` or a statement after a
  `;` that stops short, are positioned in the text as sent and read with the
  statement's own offset. A field is compared with a literal by the types of
  the two (`b = 1` is false for every row, `u > -1` wraps the `-1`, an
  integer past the signed range compares as unsigned); an unsigned field in
  arithmetic makes it unsigned and wrapping (`u * -1 < 0` is never true:
  `-1` is cast to `2^64 - 2`, `-u` is `u * -1`), an integer field compared
  with an unsigned one is cast to unsigned, and a `SUM` wraps at the range
  of its type (`InfluxQLArithmetic`). `LIMIT` and `OFFSET` beyond the signed
  64-bit range are the planning error and beyond the unsigned a parse error.

  The select list is planned as the engine plans it: a constant item
  (`SELECT 1`, `true`, `'a'`) has "no variable" in it, a function of a
  constant expects "a field argument", and the columns are named as the
  engine names them: a name taken twice is `name_1`, an item called `time`
  is `time_1` beside the time column that leads the answer, a selected
  `time` is that leading column (named by its alias) and no field of its
  own (`InfluxQLNames`, `InfluxQLLiteral`).

  Refused by name, rather than answered wrongly: `GROUP BY time(...)` (the
  engine fills every empty bucket), `GROUP BY` a tag called `time`, `fill()`,
  `INTO`, `SLIMIT`/`SOFFSET`, subqueries, `GROUP BY *`, functions other than
  `MEAN SUM COUNT MIN MAX FIRST LAST`, `F(*)` other than `COUNT(*)`, plain
  columns beside anything but a single selector, `*` beside other items,
  select items that end up with the same name, arithmetic in the select
  list, several measurements in `FROM`, sub-second durations in `now() -
  ...`, `LIMIT` / `OFFSET` on `SHOW TAG VALUES`, an unsigned field
  compared with a string, a string field or a tag compared with an integer
  past the signed range, a field compared with a constant the double cannot
  fold, an unsigned arithmetic comparison inside `OR`, a bare non-boolean
  field inside `AND` / `OR`, a quoted time in a form the double does not
  tell from the engine's, `DISTINCT`, and a statement after a `;` that the
  double does not read. A keyword inside a quoted string, quoted identifier
  or regular expression is not one: `WHERE k = 'into'` is answered.
  """

  alias InfluxElixir.Client.Local.{
    InfluxQLArithmetic,
    InfluxQLError,
    InfluxQLLiteral,
    InfluxQLParser,
    InfluxQLReserved,
    InfluxQLRun,
    InfluxQLShow,
    InfluxQLWhere
  }

  @max_signed 9_223_372_036_854_775_807

  @max_signed 9_223_372_036_854_775_807

  @typedoc "A select item: every column, a column, or a function of a column."
  @type item ::
          :star
          | {:column, binary(), binary()}
          | {:aggregate, binary(), binary() | :star, binary() | nil}

  @typedoc "A parsed `SELECT`."
  @type query :: %{
          items: [item()],
          measurement: binary(),
          where: binary() | nil,
          group_by: [binary()],
          descending: boolean(),
          limit: non_neg_integer() | nil,
          offset: non_neg_integer()
        }

  @typedoc """
  A bound on `time`: nanoseconds since the epoch, or an offset from the
  query's `now()`.
  """
  @type bound :: integer() | {:now, integer()}

  @typedoc """
  A `WHERE` as the caller's SQL, with the lower bounds its `time` comparisons
  give and the `checks` (`keep?/2`) for the comparisons the SQL cannot make.
  """
  @type where_plan :: %{
          sql: binary(),
          lowers: [bound()],
          checks: [InfluxElixir.Client.Local.InfluxQLArithmetic.check()],
          idents: MapSet.t(binary()),
          deferred: binary() | nil
        }

  @typedoc "The type of a field, as the engine plans it."
  @type field_type :: :integer | :unsigned | :float | :string | :boolean

  @typedoc "Which tag keys a `SHOW TAG VALUES` lists."
  @type key_filter ::
          {:eq, binary()} | {:ne, binary()} | {:in, [binary()]} | {:regex, Regex.t(), boolean()}

  @doc """
  Parses an InfluxQL `SELECT`. Returns `{:error, message}` for syntax the
  engine rejects and for the constructs listed in the moduledoc.
  """
  @spec parse(binary()) :: {:ok, query()} | {:error, binary() | {:engine, binary()}}
  defdelegate parse(statement), to: InfluxQLParser

  @doc """
  Shapes `rows` — the measurement's points already filtered by the
  statement's `WHERE`, as SQL row maps with `"time"`, **in time order** —
  into the engine's answer. `tags` names the measurement's tag columns;
  everything else but `time` is a field.

  Options:

    * `:lower` - the lower bound (nanoseconds) the `WHERE` gives `time`;
      an aggregate row is stamped with it, and with the epoch without one
      (verified: `WHERE time >= 2` answers `mean` at 2 ns, `WHERE time < 3`
      at the epoch; with `GROUP BY` every series carries it)
    * `:fields` - the measurement's field names, when `LIMIT` or `OFFSET`
      need them (they are read from the rows otherwise)
  """
  @spec run(query(), [map()], MapSet.t(binary()), keyword()) :: [map()]
  defdelegate run(query, rows, tags, opts \\ []), to: InfluxQLRun

  @doc """
  Rewrites an InfluxQL `WHERE` into the caller's SQL, given the
  measurement's tag columns, with the column names the `WHERE` mentions and
  the lower bounds it puts on `time`:
  `time >= x` and `time = x` give `x`, `time > x` gives `x + 1`, upper
  bounds give none. An aggregate over a lower bound is stamped with the
  greatest of them (`run/4`). `types` maps each field to its type: a
  comparison of a field with a literal follows the engine's rules for the
  two types (see `InfluxElixir.Client.Local.InfluxQLTyped`). `deferred` is the engine's
  error for a bare field as the whole condition, which it raises after it has
  checked `LIMIT` and `OFFSET`. `checks` are the comparisons of numbers with
  an unsigned field in them, which follow the engine's casts and wrap (see
  `InfluxElixir.Client.Local.InfluxQLArithmetic`) and which the SQL engine
  cannot make: the caller keeps the rows that satisfy `keep?/2`.
  `{:error, message}` for what the double refuses by name;
  `{:error, {:engine, body}}` for what the engine itself answers with a 400,
  `{:error, {:engine, status, body}}` with another status.
  """
  @spec where_plan(binary(), MapSet.t(binary()), %{binary() => field_type()}) ::
          {:ok, where_plan()}
          | {:error, binary() | {:engine, binary()} | {:engine, pos_integer(), binary()}}
  defdelegate where_plan(where, tags, types \\ %{}), to: InfluxQLWhere

  @doc """
  The engine's planning error for the first select item that is a constant
  or a function of one, `:ok` when there is none.
  """
  @spec check_items([item()]) :: :ok | {:error, {:engine, binary()}}
  defdelegate check_items(items), to: InfluxQLLiteral

  @doc """
  Whether a row satisfies the `checks` of a `where_plan/3`: the comparisons
  the SQL the `WHERE` is rewritten into cannot make as the engine does.
  """
  @spec keep?([InfluxElixir.Client.Local.InfluxQLArithmetic.check()], map()) :: boolean()
  defdelegate keep?(checks, row), to: InfluxQLArithmetic

  @doc """
  The message of the engine's `WHERE` planning error without its frame, as
  `SHOW TAG VALUES` answers it.
  """
  @spec unframe_split(binary()) :: binary()
  defdelegate unframe_split(body), to: InfluxQLError

  @doc "Whether a bare word is one InfluxQL reserves (any case)."
  @spec reserved?(binary()) :: boolean()
  defdelegate reserved?(word), to: InfluxQLReserved

  @doc """
  Parses `SHOW TAG VALUES [FROM m] WITH KEY = k | != k | =~ /re/ | !~ /re/ |
  IN (k, ...) [WHERE ...]`, or `nil` when the statement is not one.
  `LIMIT` and `OFFSET` are refused by name: the engine applies them per
  measurement in an order the double does not reproduce.
  """
  @spec parse_show_tag_values(binary()) ::
          nil
          | {:ok, %{measurement: binary() | nil, keys: key_filter(), where: binary() | nil}}
          | {:error, binary() | {:engine, binary()}}
  defdelegate parse_show_tag_values(statement), to: InfluxQLShow

  @doc "Whether a tag key is one a `key_filter/0` lists."
  @spec key_listed?(binary(), key_filter()) :: boolean()
  defdelegate key_listed?(key, filter), to: InfluxQLShow

  @doc "Whether a `WHERE` names `time`: then it, not the default window, bounds the rows."
  @spec mentions_time?(binary() | nil) :: boolean()
  defdelegate mentions_time?(where), to: InfluxQLShow

  @doc """
  The engine's planning error for a `LIMIT` or `OFFSET` beyond the signed
  64-bit range (`LIMIT` first), or `:ok`. It is raised only for a measurement
  that exists.
  """
  @spec check_window(query()) :: :ok | {:error, {:engine, binary()}}
  def check_window(%{limit: limit, offset: offset}) do
    cond do
      is_integer(limit) and limit > @max_signed ->
        {:error, {:engine, "Error during planning: limit out of range"}}

      offset > @max_signed ->
        {:error, {:engine, "Error during planning: offset out of range"}}

      true ->
        :ok
    end
  end
end
