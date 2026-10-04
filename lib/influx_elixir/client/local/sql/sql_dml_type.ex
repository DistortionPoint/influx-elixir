defmodule InfluxElixir.Client.Local.SQLDmlType do
  @moduledoc false
  # The data types of a `CAST(operand AS type)` and `operand::type` in an `INSERT`, `UPDATE`
  # or `DELETE`, for `InfluxElixir.Client.Local.SQLDmlExpr` and
  # `InfluxElixir.Client.Local.SQLDmlOperand` (verified against InfluxDB 3 Core). It is the one
  # table of them the DML modules read: the grammar a type is read by, the type the planner
  # makes of it, and the words of its errors.
  #
  # The grammar is the engine's parser's: a name, a size in parentheses for the names that
  # take one (`int(3)`, `varchar(10)`, `decimal(10,2)`; a name that takes none, such as `text`
  # and `date`, ends the type, so the parser wants a `)` where the `(` is), the suffixes
  # `UNSIGNED` and `SIGNED` of an integer, the words of `DOUBLE PRECISION` and
  # `TIMESTAMP [WITH | WITHOUT TIME ZONE]`, and array suffixes (`int[]`, `int[3]`,
  # `array<int>`). Nothing else follows a type: `int array`, `unsigned int` and
  # `int unsigned zerofill` end the type where the parser wants a `)`.
  #
  # What the planner makes of a name is its family and the Arrow type it prints in an error
  # (`Cannot automatically convert Date32 to UInt64`). A word the parser reads as a type and
  # the planner cannot plan is `Unsupported SQL type <WORD>` (405). A word the double has no
  # row for is a refusal: the engine prints some names in capitals and some as they were
  # written, which only the rows know.

  alias InfluxElixir.Client.Local.{SQLDdl, SQLError, SQLTokenizer}

  @typedoc "What the planner treats a type as."
  @type family ::
          :bool
          | :int
          | :uint
          | :float
          | :decimal
          | :str
          | :timestamp
          | :date
          | :clock
          | :interval
          | :binary
          | :list

  @typedoc "A type: its family, the Arrow type the engine prints, and the SQL the double reads."
  @type t ::
          %{family: family(), arrow: binary(), bits: 8 | 16 | 32 | 64 | nil, sql: binary() | nil}
          | {:unsupported, binary()}

  @typep token :: SQLTokenizer.token()
  @typep parsed :: {:ok, t(), [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  @typep base ::
           t()
           | {:integer, pos_integer(), binary()}
           | {:decimal, binary()}
           | {:text, boolean()}
           | {:timestamp}
           | {:time}

  # The integer names and their widths.
  @integers %{
    "TINYINT" => 8,
    "INT2" => 16,
    "SMALLINT" => 16,
    "INT" => 32,
    "INT4" => 32,
    "INTEGER" => 32,
    "INT8" => 64,
    "BIGINT" => 64
  }
  # Words the parser reads as a type that the planner cannot plan, printed in capitals.
  @unplanned ~w(UNSIGNED SIGNED BINARY BLOB JSON UUID BIT MEDIUMINT DATETIME NVARCHAR
                CHARACTER VARBINARY CLOB TINYTEXT LONGTEXT)

  @doc "Reads a type from the tokens, and the tokens after it."
  @spec parse([token()]) :: parsed()
  def parse([{:word, _printed, upper, _l, _c} | rest]) do
    with {:ok, base, rest} <- base(upper, rest),
         {:ok, base, rest} <- sized(base, rest),
         {:ok, base, rest} <- sign(base, rest),
         do: arrays(base, rest)
  end

  def parse([{:quoted, _printed, _u, _l, _c} | _rest]), do: {:refuse, "a quoted type name"}
  def parse([token | _rest]), do: {:error, SQLDdl.expected("a data type name", token)}

  @doc "The engine's error for a type it cannot plan."
  @spec unsupported(binary()) :: map()
  def unsupported(printed),
    do: %{status: 405, body: "This feature is not implemented: Unsupported SQL type " <> printed}

  @doc """
  The SQL the double's own planner reads for a type, or `nil` for a type it has no cast for
  (its casts are the integers of 8 to 64 bits, `DOUBLE` and text).
  """
  @spec local_sql(t()) :: binary() | nil
  def local_sql(%{sql: sql}), do: sql

  # ---------------------------------------------------------------------------
  # The name
  # ---------------------------------------------------------------------------

  @spec base(binary(), [token()]) :: {:ok, base(), [token()]} | {:refuse, binary()}
  defp base(bool, rest) when bool in ["BOOLEAN", "BOOL"], do: {:ok, plain(:bool, "Boolean"), rest}
  defp base("DATE", rest), do: {:ok, plain(:date, "Date32"), rest}
  defp base("BYTEA", rest), do: {:ok, plain(:binary, "Binary"), rest}
  defp base("TIMESTAMPTZ", rest), do: {:ok, plain(:timestamp, "Timestamp(ns)"), rest}
  defp base("TIMESTAMP", rest), do: {:ok, {:timestamp}, rest}
  defp base("TIME", rest), do: {:ok, {:time}, rest}
  defp base("TEXT", rest), do: {:ok, {:text, false}, rest}
  defp base(text, rest) when text in ["VARCHAR", "CHAR", "STRING"], do: {:ok, {:text, true}, rest}

  defp base(decimal, rest) when decimal in ["DECIMAL", "NUMERIC"],
    do: {:ok, {:decimal, decimal}, rest}

  defp base("FLOAT8", rest), do: {:ok, double(), rest}
  defp base(real, rest) when real in ["REAL", "FLOAT4"], do: floating(real, rest)
  defp base("FLOAT", rest), do: floating("FLOAT", rest)

  defp base("DOUBLE", rest) do
    case rest do
      [{:word, _p, "PRECISION", _l, _c} | more] -> floating("DOUBLE PRECISION", more, double())
      _other -> floating("DOUBLE", rest, double())
    end
  end

  defp base("INTERVAL", [{:word, _p, _word, _l, _c} | _rest]),
    do: {:refuse, "an interval type with fields"}

  defp base("INTERVAL", rest), do: {:ok, plain(:interval, "Interval(MonthDayNano)"), rest}

  defp base("ARRAY", [{:symbol, "<", _u, _l, _c} | rest]) do
    with {:ok, inner, [{:symbol, ">", _u2, _l2, _c2} | more]} <- parse(rest),
         true <- is_map(inner) do
      {:ok, plain(:list, "List(#{inner.arrow})"), more}
    else
      _other -> {:refuse, "an array type the double does not read"}
    end
  end

  defp base(upper, rest) when is_map_key(@integers, upper),
    do: {:ok, {:integer, Map.fetch!(@integers, upper), upper}, rest}

  defp base("CHARACTER", [{:word, _p, "VARYING", _l, _c} | rest]),
    do: unplanned("CHARACTER VARYING", rest)

  defp base(upper, rest) when upper in @unplanned, do: unplanned(upper, rest)
  defp base(upper, _rest), do: {:refuse, "the type #{String.downcase(upper)}"}

  # A float name followed by `UNSIGNED` is a name the planner cannot plan; alone it is a float.
  @spec floating(binary(), [token()]) :: {:ok, base(), [token()]} | {:refuse, binary()}
  defp floating(name, rest), do: floating(name, rest, plain(:float, "Float32"))

  @spec floating(binary(), [token()], t()) :: {:ok, base(), [token()]} | {:refuse, binary()}
  defp floating(name, [{:word, _p, "UNSIGNED", _l, _c} | rest], _type),
    do: {:ok, {:unsupported, name <> " UNSIGNED"}, rest}

  defp floating(_name, [{:symbol, "(", _u, _l, _c} | _rest], _type),
    do: {:refuse, "a float type with a size"}

  defp floating(_name, rest, type), do: {:ok, type, rest}

  # A name the planner cannot plan takes no size, but the double does not read one.
  @spec unplanned(binary(), [token()]) :: {:ok, t(), [token()]} | {:refuse, binary()}
  defp unplanned(_name, [{:symbol, "(", _u, _l, _c} | _rest]),
    do: {:refuse, "an unplanned type with a size"}

  defp unplanned(name, [{:word, _p, "VARYING", _l, _c} | _rest]) when name in ["BIT", "CHAR"],
    do: {:refuse, "a type of several words"}

  defp unplanned(name, rest), do: {:ok, {:unsupported, name}, rest}

  @spec plain(family(), binary()) :: t()
  defp plain(family, arrow), do: %{family: family, arrow: arrow, bits: nil, sql: nil}

  @spec double() :: t()
  defp double, do: %{family: :float, arrow: "Float64", bits: nil, sql: "DOUBLE"}

  # ---------------------------------------------------------------------------
  # A size in parentheses
  # ---------------------------------------------------------------------------

  @spec sized(base(), [token()]) ::
          {:ok, t(), [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp sized({:integer, bits, name}, rest) do
    with {:ok, _sizes, rest} <- sizes(rest, 1), do: {:ok, integer(bits, name), rest}
  end

  defp sized({:text, true}, [{:word, _p, "VARYING", _l, _c} | _rest]),
    do: {:refuse, "a type of several words"}

  defp sized({:text, true}, rest) do
    with {:ok, _sizes, rest} <- sizes(rest, 1), do: {:ok, text(), rest}
  end

  defp sized({:text, false}, rest), do: {:ok, text(), rest}

  defp sized({:decimal, name}, [{:word, _p, "UNSIGNED", _l, _c} | rest]),
    do: {:ok, {:unsupported, name <> " UNSIGNED"}, rest}

  defp sized({:decimal, _name}, rest) do
    with {:ok, sizes, rest} <- sizes(rest, 2), do: {:ok, decimal(sizes), rest}
  end

  defp sized({:timestamp}, [{:symbol, "(", _u, _l, _c} | _rest]),
    do: {:refuse, "a timestamp type with a precision"}

  defp sized({:timestamp}, rest), do: {:ok, plain(:timestamp, "Timestamp(ns)"), rest}

  defp sized(
         {:time},
         [
           {:word, _p, "WITH", _l, _c},
           {:word, _p2, "TIME", _l2, _c2},
           {:word, _p3, "ZONE", _l3, _c3} | rest
         ]
       ),
       do: {:ok, {:unsupported, "TIME WITH TIME ZONE"}, rest}

  defp sized(
         {:time},
         [
           {:word, _p, "WITHOUT", _l, _c},
           {:word, _p2, "TIME", _l2, _c2},
           {:word, _p3, "ZONE", _l3, _c3} | rest
         ]
       ),
       do: {:ok, plain(:clock, "Time64(ns)"), rest}

  defp sized({:time}, [{:symbol, "(", _u, _l, _c} | _rest]),
    do: {:refuse, "a time type with a precision"}

  defp sized({:time}, rest), do: {:ok, plain(:clock, "Time64(ns)"), rest}
  defp sized(type, rest), do: {:ok, type, rest}

  # `(n)`, or `(n, m)` where the type takes two numbers.
  @spec sizes([token()], 1 | 2) ::
          {:ok, [binary()], [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp sizes([{:symbol, "(", _u, _l, _c} | rest], most), do: size_list(rest, most, [])
  defp sizes(rest, _most), do: {:ok, [], rest}

  @spec size_list([token()], 1 | 2, [binary()]) ::
          {:ok, [binary()], [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp size_list([{:number, size, _u, _l, _c} | rest], most, found) do
    found = found ++ [size]

    case rest do
      [{:symbol, ")", _u2, _l2, _c2} | more] ->
        {:ok, found, more}

      [{:symbol, ",", _u2, _l2, _c2} | more] when most == 2 and length(found) == 1 ->
        size_list(more, most, found)

      [token | _more] ->
        {:error, SQLDdl.expected(")", token)}
    end
  end

  defp size_list([token | _rest], 2, [_first]), do: {:error, SQLDdl.expected("number", token)}

  defp size_list([token | _rest], _most, _found),
    do: {:error, SQLDdl.expected("literal int", token)}

  @spec integer(8 | 16 | 32 | 64, binary()) :: t()
  defp integer(bits, name),
    do: %{family: :int, arrow: "Int#{bits}", bits: bits, sql: integer_sql(name)}

  @spec integer_sql(binary()) :: binary()
  defp integer_sql(name) when name in ["INT", "INT4", "INTEGER"], do: "INT"
  defp integer_sql(name) when name in ["SMALLINT", "INT2"], do: "SMALLINT"
  defp integer_sql("TINYINT"), do: "TINYINT"
  defp integer_sql(_name), do: "BIGINT"

  @spec text() :: t()
  defp text, do: %{family: :str, arrow: "Utf8", bits: nil, sql: "VARCHAR"}

  @spec decimal([binary()]) :: t()
  defp decimal([]), do: plain(:decimal, "Decimal128(38, 10)")
  defp decimal([precision]), do: plain(:decimal, "Decimal128(#{precision}, 0)")
  defp decimal([precision, scale]), do: plain(:decimal, "Decimal128(#{precision}, #{scale})")

  # ---------------------------------------------------------------------------
  # `UNSIGNED`, `SIGNED`, `WITH TIME ZONE`
  # ---------------------------------------------------------------------------

  @spec sign(t(), [token()]) :: {:ok, t(), [token()]} | {:refuse, binary()}
  defp sign(%{family: :int, bits: bits} = type, [{:word, _p, "UNSIGNED", _l, _c} | rest]),
    do: {:ok, %{type | family: :uint, arrow: "UInt#{bits}", sql: nil}, rest}

  defp sign(%{family: :int} = type, [{:word, _p, "SIGNED", _l, _c} | rest]),
    do: {:ok, type, rest}

  defp sign(%{family: :timestamp} = type, [{:word, _p, zone, _l, _c} | rest])
       when zone in ["WITH", "WITHOUT"] do
    case rest do
      [{:word, _p2, "TIME", _l2, _c2}, {:word, _p3, "ZONE", _l3, _c3} | more] ->
        {:ok, type, more}

      [{:word, _p2, "TIME", _l2, _c2}, token | _more] ->
        {:error, SQLDdl.expected("ZONE", token)}

      [token | _more] ->
        {:error, SQLDdl.expected("TIME", token)}
    end
  end

  defp sign(type, rest), do: {:ok, type, rest}

  # ---------------------------------------------------------------------------
  # Array suffixes
  # ---------------------------------------------------------------------------

  @spec arrays(t(), [token()]) :: parsed()
  defp arrays({:unsupported, _printed} = type, rest), do: {:ok, type, rest}

  defp arrays(type, [{:symbol, "[", _u, _l, _c} | rest]) do
    case rest do
      [{:symbol, "]", _u2, _l2, _c2} | more] ->
        arrays(plain(:list, "List(#{type.arrow})"), more)

      [{:number, size, _u2, _l2, _c2}, {:symbol, "]", _u3, _l3, _c3} | more] ->
        arrays(plain(:list, "FixedSizeList(#{size} x #{type.arrow})"), more)

      [{:number, _size, _u2, _l2, _c2}, token | _more] ->
        {:error, SQLDdl.expected("]", token)}

      [token | _more] ->
        {:error, SQLDdl.expected("]", token)}
    end
  end

  defp arrays(type, rest), do: {:ok, type, rest}
end
