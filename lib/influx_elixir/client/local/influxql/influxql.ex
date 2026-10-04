defmodule InfluxElixir.Client.Local.InfluxQL do
  @moduledoc false
  # The InfluxQL `SELECT` subset `InfluxElixir.Client.Local` answers, shaped
  # the way InfluxDB 3 answers it (verified against the engine; see
  # `docs/design/2026-09-23_local-influxql.md`).
  #
  # InfluxQL is not SQL with other keywords. Every row carries
  # `"iox::measurement"` and `"time"`; rows come back in time order; a row with
  # no selected field value is dropped; an unknown column or measurement is an
  # empty result, not an error; aggregates are named after the function
  # (`mean`, `count`, ...) and put `time` at the lower bound the `WHERE`
  # gives `time` (the epoch when it gives none), except a lone selector
  # (`MAX`, `MIN`, `FIRST`, `LAST`), which returns its point's time and tags;
  # `LIMIT` and `OFFSET` apply per `GROUP BY` series.
  #
  # This module is the entry point; the work is in modules of its own, which
  # are pure: `InfluxElixir.Client.Local.InfluxQLParser` turns the statement
  # into a query map (its checks are `InfluxQLCheck`, `InfluxQLSelectCheck`
  # and `InfluxQLParens`, its words `InfluxQLText`, its dimensions `InfluxQLGroup`,
  # its regular expressions `InfluxQLRegex`, its errors
  # `InfluxQLError`), `InfluxQLWhere` plans the `WHERE` (`InfluxQLTokens`,
  # `InfluxQLTyped`, `InfluxQLArithmetic`, `InfluxQLTime`, `InfluxQLSql`),
  # `InfluxQLRun` shapes the rows the caller has already filtered with the
  # statement's `WHERE` clause (Client.Local runs it through its SQL engine)
  # and put in time order, and `InfluxQLShowParser` reads the `SHOW` statements
  # that `InfluxQLShow` and `InfluxQLQuery` answer.
  #
  # `WHERE` follows InfluxQL, not SQL (`where_plan/3`): a missing tag is the
  # empty string (`host != 'a'` keeps points without `host`, `host = ''`
  # finds them), `=~ /re/` and `!~ /re/` are unanchored matches on tags and string
  # fields (the engine's backslash rules: `\b` is the letter `b`) and false on
  # numbers, `<`/`>` on a tag is false, durations (`now() - 30m`)
  # are intervals, double-quoted identifiers are exact, and `NOT` is a name
  # like any other (`WHERE not = 7` compares a field called `not`; another
  # word right after it is left over). Compared with `time` (in any case), a
  # bare integer or a duration is an offset from the epoch in nanoseconds
  # (`time >= 2`, `time > 0s`, `time > 1s - 999999999ns`), `!=` and `<>` are
  # the engine's planning error, and a float is refused. A quoted time is read
  # by the engine's planner: one it cannot read is `'a' is not a valid
  # timestamp`, one that does not fit 64-bit nanoseconds `timestamp out of
  # range`; `time` standing alone is the planner's 500 ("expected an element
  # on stack", "invalid expr stack") or a type error in parentheses. The
  # engine pulls `time` comparisons out of the whole `WHERE` as if they were
  # joined by `AND`, so one inside an `OR` is refused by name. `SHOW TAG
  # VALUES [FROM m] WITH KEY = | != | =~ | !~ | IN (...)` [WHERE ...] lists
  # values as the engine does, over the last 24 hours unless the `WHERE`
  # bounds `time` (`InfluxElixir.Client.Local.InfluxQLShowParser`).
  #
  # A reserved word (`reserved?/1`) is no bare identifier: the engine's parse
  # errors for it, for a reserved word where an operand is wanted (after a
  # binary operator, first in a call), for a parenthesis left open, closed
  # twice or empty, for `GROUP BY time` without a call, and for a select list,
  # `FROM`, `WHERE`, `GROUP BY`, `ORDER BY`, `LIMIT` or a statement after a
  # `;` that stops short, are positioned in the text as sent and read with the
  # statement's own offset. A field is compared with a literal by the types of
  # the two (`b = 1` is false for every row, `u > -1` wraps the `-1`, an
  # integer past the signed range compares as unsigned); an unsigned field in
  # arithmetic makes it unsigned and wrapping (`u * -1 < 0` is never true:
  # `-1` is cast to `2^64 - 2`, `-u` is `u * -1`), an integer field compared
  # with an unsigned one is cast to unsigned, and a `SUM` wraps at the range
  # of its type (`InfluxQLArithmetic`). `LIMIT` and `OFFSET` beyond the signed
  # 64-bit range are the planning error and beyond the unsigned a parse error.
  #
  # The select list is planned as the engine plans it: a constant item
  # (`SELECT 1`, `true`, `'a'`) has "no variable" in it, a function of a
  # constant expects "a field argument", and the columns are named as the
  # engine names them: a name taken twice is `name_1`, an item called `time`
  # is `time_1` beside the time column that leads the answer, a selected
  # `time` is that leading column (named by its alias) and no field of its
  # own (`InfluxQLNames`, `InfluxQLLiteral`).
  #
  # `GROUP BY time(every[, offset])` answers a row for every bucket of the
  # range the `WHERE` bounds (from the first point to `now()` without bounds),
  # with `fill(null | none | previous | linear | n)` (`InfluxQLGroup`,
  # `InfluxQLBuckets`); `median`, `spread`, `stddev` and `count(distinct(f))`
  # join the aggregates (`InfluxQLAggregate`); arithmetic in the select list
  # (`usage + 1`, `-n`, `sum(n) / count(n)`, `n::float`) is computed as the
  # engine types it (`InfluxQLExpr`); `now()` and durations in a `time`
  # comparison fold with quoted times (`InfluxQLTimeExpr`); and the checks of
  # the select list the engine plans are `InfluxQLPlan`.
  #
  # Also answered (see `docs/design/2026-10-02_influxql-planner-and-module-split.md`):
  # `GROUP BY` as the engine's parser reads it (`InfluxQLGroup`: `*`, `/re/`,
  # fields, the first `time()`, its errors at their positions), `fill()` over
  # the buckets that hold points, `/* */` comments, `SLIMIT` (405), `tz('UTC')`,
  # `percentile`, `mode`, `top`, `bottom`, `integral`, the math functions, the
  # transforms of fields and of aggregates (`InfluxQLTransform`: a float that
  # overflows is a null in the row, an integer wraps), `F(*)` (`count`, `mode` and
  # `elapsed` take every field), `*::field`, `/re/` columns and `FROM` lists
  # (`InfluxQLWild`), the planning errors of a duration or window the engine
  # refuses (`InfluxQLExpr`, `InfluxQLPlan`), booleans in `first`/`last`/`min`/`max`,
  # and the `SHOW` statements (`InfluxQLShowParser`, `InfluxQLShowClauses`,
  # `InfluxQLShowCondition`).
  #
  # Refused by name, rather than answered wrongly: `INTO`, subqueries, `tz()`
  # of a zone other than UTC, `mode()` of values equally often there, `GROUP BY`
  # a tag called `time` or a field the select list reads, `fill(linear)` on a
  # text or boolean column (and with a `count` over an empty bucket) and
  # `fill(previous)` with a `count` while the first bucket is empty (the engine
  # breaks the connection), a series of more than `local_influxql_max_rows`,
  # transforms over points that share a time, `elapsed()` or `integral()` over
  # buckets, `percentile` or `top` in arithmetic, `distinct(f)` of a field (the
  # engine lists the values in the order of its hash), columns beside a selector
  # in a `GROUP BY time`, `*` beside other items, select items that end up with
  # the same name, a remainder by zero, a negative fraction cast to an integer,
  # an expression of constants, one that mixes aggregates and fields, the
  # spread of negative values, an unsigned field compared with a string, a
  # string field or a tag compared with an integer past the signed range, a
  # field compared with a constant the double cannot fold, a bare non-boolean
  # field inside `AND` / `OR`, a quoted time in a form the double does not tell
  # from the engine's, a regular expression with `\\u` or a back reference, and
  # a statement after a `;` that the double does not read. A keyword inside a
  # quoted string, quoted identifier or regular expression is not one:
  # `WHERE k = 'into'` is answered.

  alias InfluxElixir.Client.Local.{
    InfluxQLArithmetic,
    InfluxQLError,
    InfluxQLParser,
    InfluxQLPlan,
    InfluxQLRun,
    InfluxQLShow,
    InfluxQLText,
    InfluxQLWhere,
    SQLLimits
  }

  require SQLLimits

  @typedoc "A select item: every column, a column, or a function of a column."
  @type item ::
          :star
          | {:column, binary(), binary()}
          | {:literal, binary()}
          | {:expr, InfluxElixir.Client.Local.InfluxQLExpr.ast(), binary() | nil}
          | {:multi, binary(), binary(), [binary()], pos_integer(), binary() | nil}
          | {:planning_error, binary()}
          | {:aggregate, binary(),
             binary() | :star | {:distinct, binary()} | {:literal, binary()}, binary() | nil}

  @typedoc "A parsed `SELECT`."
  @type query :: %{
          items: [item()],
          measurement: binary(),
          sources: [{:name | :regex, binary()}],
          where: binary() | nil,
          group_by: [binary()],
          group_time: nil | {integer(), integer()},
          fill: InfluxElixir.Client.Local.InfluxQLBuckets.fill(),
          descending: boolean(),
          limit: non_neg_integer() | nil,
          offset: non_neg_integer(),
          rewrite_error: binary() | nil
        }

  @typedoc """
  A bound on `time`: nanoseconds since the epoch (`now()` is read when the
  `WHERE` is planned).
  """
  @type bound :: integer()

  @typedoc """
  A `WHERE` as the caller's SQL, with the lower bounds its `time` comparisons
  give and the `checks` for the comparisons the SQL cannot make: each is
  `{column, check}`; the SQL reads the `column`, which the caller fills with
  `holds?/2` over every point.
  """
  @type where_plan :: %{
          sql: binary(),
          lowers: [bound()],
          uppers: [bound()],
          checks: [{binary(), check()}],
          idents: MapSet.t(binary()),
          deferred: {pos_integer(), binary()} | nil
        }

  @typedoc "A comparison of numbers the SQL cannot make; see `where_plan/0`."
  @type check :: InfluxQLArithmetic.check()

  @typedoc "The type of a field, as the engine plans it."
  @type field_type :: :integer | :unsigned | :float | :string | :boolean

  @typedoc "Which tag keys a `SHOW TAG VALUES` lists."
  @type key_filter ::
          {:eq, binary()} | {:ne, binary()} | {:in, [binary()]} | {:regex, Regex.t(), boolean()}

  @doc """
  Parses an InfluxQL `SELECT`. Returns `{:error, message}` for syntax the
  engine rejects and for the constructs listed in the moduledoc.
  """
  @spec parse(binary()) ::
          {:ok, query()}
          | {:error, binary() | {:engine, binary()} | {:engine, pos_integer(), binary()}}
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
  cannot make: the SQL reads each one's column, which the caller fills with
  `holds?/2` over the point.
  `{:error, message}` for what the double refuses by name;
  `{:error, {:engine, body}}` for what the engine itself answers with a 400,
  `{:error, {:engine, status, body}}` with another status.
  """
  @spec where_plan(binary(), MapSet.t(binary()), %{binary() => field_type()}, keyword()) ::
          {:ok, where_plan()}
          | {:error, binary() | {:engine, binary()} | {:engine, pos_integer(), binary()}}
  defdelegate where_plan(where, tags, types \\ %{}, opts \\ []), to: InfluxQLWhere

  @doc """
  The engine's planning error for a select list (a constant, `distinct()`
  beside another item, `GROUP BY time` without an aggregate, a column beside
  an aggregate), `:ok` when there is none, `{:error, message}` for a list
  the double refuses by name.
  """
  @spec plan_select(query(), %{binary() => field_type()}, MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()} | {:engine, pos_integer(), binary()} | binary()}
  defdelegate plan_select(query, types, tags), to: InfluxQLPlan, as: :check

  @doc """
  The engine's planning error that comes first, while it rewrites the
  statement: a wildcard it cannot expand, then the offset of a `GROUP BY time()`
  it cannot read. `:ok` when there is none.
  """
  @spec early_error(query()) :: :ok | {:error, {:engine, binary()}}
  defdelegate early_error(query), to: InfluxQLPlan

  @doc """
  Whether a row (field name to value) satisfies a check of a `where_plan/3`:
  a comparison the SQL the `WHERE` is rewritten into cannot make as the
  engine does.
  """
  @spec holds?(check(), map()) :: boolean()
  defdelegate holds?(check, row), to: InfluxQLArithmetic

  @doc """
  The message of the engine's `WHERE` planning error without its frame, as
  `SHOW TAG VALUES` answers it.
  """
  @spec unframe_split(binary()) :: binary()
  defdelegate unframe_split(body), to: InfluxQLError

  @doc """
  How far before the range the points of a query are scanned, in nanoseconds:
  one bucket for the transforms of a `GROUP BY time` that compare with the
  bucket before, none otherwise.
  """
  @spec lookback(query()) :: {:ok, non_neg_integer()} | {:error, binary()}
  defdelegate lookback(query), to: InfluxQLRun

  @doc "Whether a bare word is one InfluxQL reserves (any case)."

  @spec reserved?(binary()) :: boolean()
  defdelegate reserved?(word), to: InfluxQLText

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
      is_integer(limit) and limit > SQLLimits.int64_max() ->
        {:error, {:engine, "Error during planning: limit out of range"}}

      offset > SQLLimits.int64_max() ->
        {:error, {:engine, "Error during planning: offset out of range"}}

      true ->
        :ok
    end
  end
end
