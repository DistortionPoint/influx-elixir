defmodule InfluxElixir.Contract.SQLScalar do
  @moduledoc """
  SQL expression contract tests, run against `InfluxElixir.Client.Local` and
  against a real InfluxDB 3: the values of expressions and functions in the
  select list, the words of the engine's type errors, aggregate expressions and
  `HAVING`, what the parser reads and refuses, and `SHOW COLUMNS` with the
  `information_schema`. Every expectation here was read from a Core.

      use InfluxElixir.Contract.SQLScalar, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn`, `database` and `query_delay`, as for
  `InfluxElixir.ClientContract`. Every test writes its own tables into the
  database the context gives it, so their names are fixed.

  ## Cases

  A case is `{kind, text, expected}`, answered by the tables of
  `InfluxElixir.Contract.SQLScalarCases` and `InfluxElixir.Contract.SQLCatalogCases`.
  The kind says where the text stands in the statement over table `main` (see
  `fixture/0`):

    * `:sel` — `SELECT <text> AS r FROM main ORDER BY time`, the answer the list of `r`
    * `:where` — `SELECT v FROM main WHERE <text> ORDER BY time`, the list of `v`
    * `:order` — `SELECT v FROM main ORDER BY <text>, time`, the list of `v`
    * `:raw` — the text is the statement, the answer its rows

  `expected` is `{:ok, answer}`, `{:error, status, body}` or the client's closed
  connection error. A table named `*_refusable` holds what the double may refuse
  by name (`Client.Local:` and a 400) instead of answering.

  ## Parts

  A module that generates the whole contract is slow to compile, so `part: part`
  generates one slice of it, for a module of its own that compiles and runs in
  parallel with its siblings. Without `:part` everything is generated.

    * `:expressions` — operators, `CASE`, `COALESCE`, unsigned and overflow, item names
    * `:functions` — string and math functions
    * `:errors` — type, arity and value errors
    * `:aggregates` — aggregate expressions, `HAVING`, aliases
    * `:catalog` — the parser, `SHOW COLUMNS`, `information_schema`
  """

  @parts [:expressions, :functions, :errors, :aggregates, :catalog]

  @fixture [
    "main,host=h0,region=r0 n=0i,x=0.0,s=\"s0\",b=true,v=-20i 1700000000000000000",
    "main,host=h1,region=r1 n=1i,x=1.5,s=\"s1\",b=false,v=-10i 1700000030000000000",
    "main,host=h2,region=r0 n=2i,x=3.0,s=\"s2\",b=true,v=0i 1700000060000000000",
    "main,host=h0,region=r1 n=3i,x=4.5,b=false,v=10i 1700000090000000000",
    "main,host=h1,region=r0 n=4i,x=6.0,s=\"s0\",b=true,v=20i 1700000120000000000",
    "main,host=h2,region=r1 x=7.5,s=\"s1\",b=false,v=30i 1700000150000000000",
    "main,host=h0,region=r0 n=6i,x=9.0,s=\"s2\",b=true,v=40i 1700000180000000000",
    "main,host=h1,region=r1 n=7i,b=false,v=50i 1700000210000000000",
    "main,host=h2,region=r0 n=8i,x=12.0,s=\"s0\",b=true,v=60i 1700000240000000000",
    "main,host=h0,region=r1 n=9i,x=13.5,s=\"s1\",b=false,v=70i 1700000270000000000",
    "main,host=h1,region=r0 n=10i,x=15.0,s=\"s2\",b=true,v=80i 1700000300000000000",
    "main,host=h2,region=r1 n=11i,x=16.5,b=false,v=90i 1700000330000000000",
    "mext,host=a u=5u,i=-3i,f=2.5,s=\"Héllo Wörld\",b=true 1700000000000000000",
    "mext,host=b u=18446744073709551615u,i=9223372036854775807i,f=-0.5,s=\"\",b=false 1700000030000000000",
    "mext,host=a u=0u,i=0i,f=1.0e300,s=\"abc\",b=true 1700000060000000000",
    "ping,host=h0 v=1i 1700000000000000000"
  ]

  @doc """
  The lines of the tables the cases read: `main` (twelve points two tags, an
  integer with a gap, a float with a gap, a string with gaps, a boolean and an
  integer that is never null), `mext` (an unsigned, the extremes of `Int64` and
  `Float64`, text with accents and the empty string) and `ping`.
  """
  @spec fixture() :: [binary()]
  def fixture, do: @fixture

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    # SQL is the v3 profiles' query language; v2 has none of it.
    if profile in [:v3_core, :v3_enterprise] do
      tests =
        for {test_part, block} <- test_blocks(), part == :all or part == test_part, do: block

      quote location: :keep do
        (unquote_splicing([helpers(client), checks() | tests]))
      end
    end
  end

  # Every block of tests with the part it belongs to, in order.
  @spec test_blocks() :: [{atom(), Macro.t()}]
  defp test_blocks do
    [
      {:expressions, expression_tests()},
      {:functions, function_tests()},
      {:errors, error_tests()},
      {:aggregates, aggregate_tests()},
      {:catalog, catalog_tests()}
    ]
  end

  @doc """
  The statement of a case and the key of the answer's rows it reads (`nil` for all of
  them).
  """
  @spec statement(atom(), binary()) :: {binary(), binary() | nil}
  def statement(:sel, text), do: {"SELECT #{text} AS r FROM main ORDER BY time", "r"}
  def statement(:where, text), do: {"SELECT v FROM main WHERE #{text} ORDER BY time", "v"}
  def statement(:order, text), do: {"SELECT v FROM main ORDER BY #{text}, time", "v"}
  def statement(:raw, text), do: {text, nil}

  @doc """
  A case as `{kind, text, expected}`, with `expected` as the clients answer: the tables
  write `{kind, text, :ok, rows}`, `{kind, text, :error, status, body}` and
  `{kind, text, :closed}`.
  """
  @spec decode(tuple()) :: {atom(), binary(), term()}
  def decode({kind, text, :ok, rows}), do: {kind, text, {:ok, rows}}
  def decode({kind, text, :error, status, body}), do: {kind, text, {:error, status, body}}

  def decode({kind, text, :closed}),
    do: {kind, text, {:error, {:connection_error, %Mint.TransportError{reason: :closed}}}}

  @doc "Whether an answer is the double's refusal by name."
  @spec refusal?(term()) :: boolean()
  def refusal?({:error, 400, "Client.Local: " <> _reason}), do: true
  def refusal?(_outcome), do: false

  defp helpers(client) do
    quote location: :keep do
      # The tests of a part use some of these; none may warn when unused.
      def ss_fixture(ctx) do
        lines = Enum.join(InfluxElixir.Contract.SQLScalar.fixture(), "\n")

        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, lines,
                   database: ctx.database,
                   precision: :nanosecond
                 )

        InfluxElixir.ClientContract.settle(ctx)
      end

      def ss_local?, do: unquote(client) === InfluxElixir.Client.Local

      def ss_outcome(ctx, kind, text) do
        {sql, key} = InfluxElixir.Contract.SQLScalar.statement(kind, text)

        case unquote(client).query_sql(ctx.conn, sql, database: ctx.database) do
          {:ok, rows} when is_binary(key) -> {:ok, Enum.map(rows, & &1[key])}
          {:ok, _rows} = answer -> answer
          {:error, %{status: status, body: body}} -> {:error, status, body}
          other -> other
        end
      end
    end
  end

  defp checks do
    quote location: :keep do
      # Every case that did not hold, once.
      def ss_check(ctx, cases) do
        InfluxElixir.TestSupport.Check.check_cases(cases, fn entry ->
          {kind, text, expected} = InfluxElixir.Contract.SQLScalar.decode(entry)
          actual = ss_outcome(ctx, kind, text)

          if actual === expected,
            do: :ok,
            else: {:mismatch, %{expected: expected, actual: actual}}
        end)
      end

      # The same, where the double may refuse by name what the engine answers.
      def ss_check_refusable(ctx, cases) do
        InfluxElixir.TestSupport.Check.check_cases(cases, fn entry ->
          {kind, text, expected} = InfluxElixir.Contract.SQLScalar.decode(entry)
          actual = ss_outcome(ctx, kind, text)

          cond do
            actual === expected -> :ok
            ss_local?() and InfluxElixir.Contract.SQLScalar.refusal?(actual) -> :ok
            true -> {:mismatch, %{expected: expected, actual: actual}}
          end
        end)
      end
    end
  end

  defp expression_tests do
    quote location: :keep do
      describe "SQL scalar — contract: operators and expressions" do
        @tag local_divergence: "Local refuses by name some of what the engine answers"
        test "three-valued logic, IN, BETWEEN, LIKE, CASE, COALESCE and arithmetic", ctx do
          ss_fixture(ctx)
          ss_check(ctx, InfluxElixir.Contract.SQLScalarCases.expressions_values())

          ss_check_refusable(
            ctx,
            InfluxElixir.Contract.SQLScalarCases.expressions_values_refusable()
          )
        end

        @tag local_divergence: "Local refuses by name some of what the engine answers"
        test "an item without an alias is named as the engine prints its expression", ctx do
          ss_fixture(ctx)
          ss_check(ctx, InfluxElixir.Contract.SQLScalarCases.expressions_names())

          ss_check_refusable(
            ctx,
            InfluxElixir.Contract.SQLScalarCases.expressions_names_refusable()
          )
        end
      end
    end
  end

  defp function_tests do
    quote location: :keep do
      describe "SQL scalar — contract: string and math functions" do
        @tag local_divergence: "Local refuses by name some of what the engine answers"
        test "lower, upper, length, substr, starts_with, sqrt, ln, log, pow, greatest, least",
             ctx do
          ss_fixture(ctx)
          ss_check(ctx, InfluxElixir.Contract.SQLScalarCases.functions_values())

          ss_check_refusable(
            ctx,
            InfluxElixir.Contract.SQLScalarCases.functions_values_refusable()
          )
        end
      end
    end
  end

  defp error_tests do
    quote location: :keep do
      describe "SQL scalar — contract: the engine's errors" do
        @tag local_divergence: "Local refuses by name some of what the engine answers"
        test "type errors, wrong arities and failures only a value shows", ctx do
          ss_fixture(ctx)
          ss_check(ctx, InfluxElixir.Contract.SQLScalarCases.errors())
          ss_check_refusable(ctx, InfluxElixir.Contract.SQLScalarCases.errors_refusable())
        end
      end
    end
  end

  defp aggregate_tests do
    quote location: :keep do
      describe "SQL scalar — contract: aggregate expressions" do
        @tag local_divergence: "Local refuses by name some of what the engine answers"
        test "expressions of aggregates, HAVING, aliases and groups", ctx do
          ss_fixture(ctx)
          ss_check(ctx, InfluxElixir.Contract.SQLCatalogCases.aggregates())
          ss_check_refusable(ctx, InfluxElixir.Contract.SQLCatalogCases.aggregates_refusable())
        end
      end
    end
  end

  defp catalog_tests do
    quote location: :keep do
      describe "SQL scalar — contract: the parser and the catalog" do
        @tag local_divergence: "Local refuses by name some of what the engine answers"
        test "the statements the parser reads, and its errors for those it does not", ctx do
          ss_fixture(ctx)
          ss_check(ctx, InfluxElixir.Contract.SQLCatalogCases.syntax())
          ss_check_refusable(ctx, InfluxElixir.Contract.SQLCatalogCases.syntax_refusable())
        end

        @tag local_divergence: "Local refuses by name some of what the engine answers"
        test "SHOW TABLES, SHOW COLUMNS and the information_schema", ctx do
          ss_fixture(ctx)
          ss_check(ctx, InfluxElixir.Contract.SQLCatalogCases.catalog())
          ss_check_refusable(ctx, InfluxElixir.Contract.SQLCatalogCases.catalog_refusable())
        end
      end
    end
  end
end
