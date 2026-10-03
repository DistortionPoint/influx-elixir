defmodule InfluxElixir.Client.Local.InfluxQLTyped do
  @moduledoc false
  # A field compared with a literal by the types of the two, as the engine
  # compares them, and a bare field as the whole condition.

  alias InfluxElixir.Client.Local.{InfluxQLArithmetic, InfluxQLSql, SQLLimits}

  require SQLLimits

  # ---------------------------------------------------------------------------
  # Typed comparisons
  #
  # The engine compares a field with a literal by the field's type
  # (verified, for every operator):
  #
  #   * a literal of another kind than the field (a boolean or string
  #     against a number, a number against a boolean or string) is false for
  #     every row, not an error
  #   * an integer beyond the signed range (up to the unsigned) is an
  #     unsigned literal: an integer field is compared as unsigned (a
  #     negative value as 2^64 + value - 1, the lowest integer as null), an
  #     unsigned or float field
  #     as it is, a boolean field is the planning error "Cannot infer common
  #     argument type"
  #   * a negative integer against an unsigned field is 2^64 + n - 1
  #     (`u > -1` is false for all but the largest)
  #   * an unsigned field against a boolean is the same planning error;
  #     against a string, a string field against a big integer and a tag
  #     against a big integer, the engine compares as text: refused by name
  #   * a bare field as the whole condition is a planning error (after the
  #     LIMIT is checked) naming the field's type; inside `AND` / `OR` it is
  #     refused
  # ---------------------------------------------------------------------------

  @typedoc "The type of a field, as the engine plans it."
  @type field_type :: :integer | :unsigned | :float | :string | :boolean

  @arrow_types %{
    integer: "Int64",
    unsigned: "UInt64",
    float: "Float64",
    string: "Utf8",
    boolean: "Boolean",
    tag: "Dictionary(Int32, Utf8)"
  }

  @comparison_ops ["=", "!=", "<>", "<", "<=", ">", ">="]
  @flipped_ops %{
    "=" => "=",
    "!=" => "!=",
    "<>" => "<>",
    "<" => ">",
    "<=" => ">=",
    ">" => "<",
    ">=" => "<="
  }

  # How a comparison is answered: the SQL of a field against a literal, typed
  # by the two; a comparison of numbers with an unsigned field in it that the
  # SQL engine does not read as the engine does, as a check on a column of its
  # own (`InfluxElixir.Client.Local.InfluxQLArithmetic.column/1`) that the SQL
  # reads, so that `AND`, `OR` and parentheses combine it with the rest; any
  # other as written.
  @spec plan_comparison(list(), {MapSet.t(binary()), map()}) ::
          {binary(), [{binary(), InfluxQLArithmetic.check()}]}
  @doc false
  def plan_comparison(tokens, {tags, types}) do
    with nil <- typed_comparison(tokens, tags, types),
         :unsupported <- InfluxQLArithmetic.compile(tokens, types) do
      {plain(tokens, tags, types), []}
    else
      :written -> {plain(tokens, tags, types), []}
      sql when is_binary(sql) -> {sql, []}
      {:ok, check} -> check_sql(check)
    end
  end

  @spec check_sql(InfluxQLArithmetic.check()) ::
          {binary(), [{binary(), InfluxQLArithmetic.check()}]}
  defp check_sql(check) do
    column = InfluxQLArithmetic.column(check)
    {"#{column} = true", [{column, check}]}
  end

  @spec plain(list(), MapSet.t(binary()), map()) :: binary()
  defp plain(tokens, tags, types) do
    strings = for {name, :string} <- types, into: MapSet.new(), do: name

    tokens
    |> InfluxQLSql.drop_unary_plus([])
    |> InfluxQLSql.rewrite(tags, strings, [])
    |> Enum.join(" ")
  end

  @spec typed_comparison(list(), MapSet.t(binary()), map()) :: binary() | :written | nil
  defp typed_comparison(tokens, tags, types) do
    with {name, op, literal, flipped?} <- comparison_parts(tokens),
         type when type != nil <- field_kind(name, tags, types),
         literal when literal != nil <- literal_kind(literal) do
      op = if flipped?, do: Map.fetch!(@flipped_ops, op), else: op
      typed_sql(type, literal, InfluxQLSql.ident_sql(name), op, flipped?)
    else
      _untyped -> nil
    end
  end

  @spec field_kind(binary(), MapSet.t(binary()), map()) :: atom() | nil
  defp field_kind(name, tags, types) do
    if MapSet.member?(tags, name), do: :tag, else: Map.get(types, name)
  end

  # `name op literal` and `literal op name`, the literal a number (signed),
  # a boolean or a string.
  @spec comparison_parts(list()) :: {binary(), binary(), list(), boolean()} | nil
  defp comparison_parts([{:ident, name}, {:op, op} | literal]) when op in @comparison_ops,
    do: {name, op, literal, false}

  defp comparison_parts(tokens) when length(tokens) in [3, 4] do
    case Enum.split(tokens, -2) do
      {literal, [{:op, op}, {:ident, name}]} when op in @comparison_ops ->
        {name, op, literal, true}

      _other ->
        nil
    end
  end

  defp comparison_parts(_tokens), do: nil

  @spec literal_kind(list()) ::
          {:integer, integer()} | :float | :boolean | :string | :expression | nil
  defp literal_kind([{:raw, sign}, {:number, _text} = number]) when sign in ["-", "+"],
    do: signed_kind(sign, number)

  defp literal_kind([{:number, _text} = number]), do: signed_kind("+", number)
  defp literal_kind([{:str, _content}]), do: :string

  defp literal_kind([{:raw, word}]) do
    if String.upcase(word) in ["TRUE", "FALSE"], do: :boolean
  end

  defp literal_kind(tokens) do
    if Enum.all?(tokens, &constant_token?/1), do: constant_kind(tokens)
  end

  defp constant_token?({:number, _text}), do: true
  defp constant_token?({:raw, text}), do: text in ["+", "-", "*", "/", "(", ")"]
  defp constant_token?(_token), do: false

  # A constant of numbers, `+ - *` and parentheses is folded before it is
  # compared, as the engine does; anything else numeric (`/`, an
  # overflow) is `:expression`, which the caller refuses.
  @spec constant_kind(list()) :: {:integer, integer()} | :float | :expression
  defp constant_kind(tokens) do
    case fold_sum(tokens) do
      {value, []} when is_float(value) ->
        :float

      {value, []}
      when is_integer(value) and value >= -SQLLimits.int64_max() - 1 and
             value <= SQLLimits.int64_max() ->
        {:integer, value}

      _unfoldable ->
        :expression
    end
  end

  defp fold_sum(tokens) do
    with {value, rest} <- fold_product(tokens),
         do: fold_more(rest, value, ["+", "-"], &fold_product/1)
  end

  defp fold_product(tokens) do
    with {value, rest} <- fold_factor(tokens), do: fold_more(rest, value, ["*"], &fold_factor/1)
  end

  defp fold_more([{:raw, op} | rest] = tokens, left, ops, next) do
    if op in ops do
      case next.(rest) do
        {right, after_right} -> fold_more(after_right, apply_op(op, left, right), ops, next)
        :error -> :error
      end
    else
      {left, tokens}
    end
  end

  defp fold_more(tokens, left, _ops, _next), do: {left, tokens}

  defp apply_op("+", left, right), do: left + right
  defp apply_op("-", left, right), do: left - right
  defp apply_op("*", left, right), do: left * right

  defp fold_factor([{:raw, "-"} | rest]) do
    with {value, after_value} <- fold_factor(rest), do: {-value, after_value}
  end

  defp fold_factor([{:raw, "+"} | rest]), do: fold_factor(rest)

  defp fold_factor([{:raw, "("} | rest]) do
    case fold_sum(rest) do
      {value, [{:raw, ")"} | after_group]} -> {value, after_group}
      _unbalanced -> :error
    end
  end

  defp fold_factor([{:number, text} | rest]) do
    case Integer.parse(text) do
      {n, ""} -> {n, rest}
      _fraction -> {text |> number_text() |> String.to_float(), rest}
    end
  end

  defp fold_factor(_tokens), do: :error

  defp number_text("." <> _fraction = text), do: "0" <> text
  defp number_text(text), do: text

  defp signed_kind(sign, {:number, text}) do
    case Integer.parse(text) do
      {n, ""} -> {:integer, if(sign == "-", do: -n, else: n)}
      _fraction -> :float
    end
  end

  # The SQL for a field of `type` against `literal`, or `nil` to leave the
  # comparison as written.
  @spec typed_sql(atom(), term(), binary(), binary(), boolean()) :: binary() | :written | nil
  defp typed_sql(type, literal, column, op, flipped?) do
    case decide(type, literal, op) do
      :plain -> :written
      :check -> nil
      :never -> "(#{column} IS NULL AND #{column} IS NOT NULL)"
      {:unsigned, n} -> "#{column} #{op} #{n}"
      :wrap -> wrapped_sql(column, op, literal)
      :mismatch -> mismatch(type, literal, op, flipped?)
      :refuse -> throw({:refused, "unsupported InfluxQL (#{refusal(type, literal)})"})
    end
  end

  # Booleans and strings have equality only: an ordering is false for all.
  @spec decide(atom(), term(), binary()) ::
          :plain | :check | :never | :wrap | :mismatch | :refuse | {:unsigned, non_neg_integer()}
  defp decide(type, kind, op) when type in [:boolean, :string] and op in ["<", "<=", ">", ">="] do
    if decide(type, kind, "=") == :plain, do: :never, else: decide(type, kind, "=")
  end

  defp decide(:float, :expression, _op), do: :plain
  defp decide(_type, :expression, _op), do: :refuse
  defp decide(:integer, {:integer, n}, _op) when n > SQLLimits.int64_max(), do: :wrap
  defp decide(:integer, kind, _op) when kind == :float or is_tuple(kind), do: :plain
  defp decide(:float, kind, _op) when kind == :float or is_tuple(kind), do: :plain

  defp decide(:unsigned, {:integer, n}, _op) when n == -9_223_372_036_854_775_808,
    do: :refuse

  defp decide(:unsigned, {:integer, n}, _op) when n < 0,
    do: {:unsigned, n + SQLLimits.uint64_max()}

  defp decide(:unsigned, {:integer, _n}, _op), do: :plain
  defp decide(:unsigned, :float, _op), do: :check
  defp decide(:unsigned, :boolean, _op), do: :mismatch
  defp decide(:unsigned, :string, _op), do: :refuse
  defp decide(:boolean, :boolean, _op), do: :plain
  defp decide(:boolean, {:integer, n}, _op) when n > SQLLimits.int64_max(), do: :mismatch
  defp decide(:string, :string, _op), do: :plain
  defp decide(:string, {:integer, n}, _op) when n > SQLLimits.int64_max(), do: :refuse
  defp decide(:tag, {:integer, n}, _op) when n > SQLLimits.int64_max(), do: :refuse
  defp decide(:tag, :string, _op), do: :plain
  defp decide(_type, _literal, _op), do: :never

  # An integer field against an unsigned literal `n` (verified): a
  # non-negative value is itself, a negative one `2^64 + value - 1`, and the
  # lowest 64-bit integer is null. With `m = n - 2^64 + 1` (negative) a
  # negative value therefore compares as `value` against `m`, a non-negative
  # one is below `n`.
  @spec wrapped_sql(binary(), binary(), {:integer, integer()}) :: binary()
  defp wrapped_sql(column, op, {:integer, n}) do
    m = n - SQLLimits.uint64_max()

    negative =
      "(#{column} < 0 AND #{column} > -9223372036854775808 AND #{column} #{op} #{m})"

    if op in ["=", ">", ">="], do: negative, else: "(#{column} >= 0 OR #{negative})"
  end

  @spec mismatch(atom(), term(), binary(), boolean()) :: no_return()
  defp mismatch(type, literal, op, flipped?) do
    field = Map.fetch!(@arrow_types, type)
    other = if literal == :boolean, do: "Boolean", else: "UInt64"
    {left, right} = if flipped?, do: {other, field}, else: {field, other}
    op = if flipped?, do: Map.fetch!(@flipped_ops, op), else: op
    op = if op == "<>", do: "!=", else: op

    throw(
      {:refused,
       {:engine,
        "Error during planning: Cannot infer common argument type for comparison " <>
          "operation #{left} #{op} #{right}"}}
    )
  end

  @spec refusal(atom(), term()) :: binary()
  defp refusal(_type, :expression), do: "a field compared with a constant expression"
  defp refusal(:unsigned, :string), do: "an unsigned field compared with a string"

  defp refusal(:unsigned, _literal),
    do: "an unsigned field compared with the lowest 64-bit integer"

  defp refusal(_type, _literal), do: "a string compared with an integer beyond 64 bits signed"

  # A bare field (or tag) as the whole condition: the engine's planning
  # error, raised after the LIMIT. Inside `AND` / `OR` it is refused.
  @spec bare_condition(tuple(), {MapSet.t(binary()), map()}) :: binary() | nil
  @doc false
  def bare_condition({:group, node}, ctx), do: bare_condition(node, ctx)

  def bare_condition({:cmp, tokens}, {tags, types}) do
    case tokens |> strip_parens() |> bare_field(tags, types) do
      nil -> nil
      :boolean -> nil
      type -> bare_error(type)
    end
  end

  def bare_condition({kind, nodes}, ctx) when kind in [:and, :or] do
    if Enum.any?(nodes, &bare_member?(&1, ctx)),
      do: throw({:refused, "unsupported InfluxQL (a bare non-boolean field inside AND/OR)"})

    nil
  end

  def bare_condition(_node, _ctx), do: nil

  @spec bare_field(list(), MapSet.t(binary()), map()) :: atom() | nil
  defp bare_field([{:ident, name}], tags, types), do: field_kind(name, tags, types)
  defp bare_field(_tokens, _tags, _types), do: nil

  @spec strip_parens(list()) :: list()
  defp strip_parens([{:raw, "("} | rest] = tokens) do
    case Enum.split(rest, -1) do
      {inside, [{:raw, ")"}]} -> strip_parens(inside)
      _other -> tokens
    end
  end

  defp strip_parens(tokens), do: tokens

  defp bare_member?({:group, node}, ctx), do: bare_member?(node, ctx)

  defp bare_member?({:cmp, tokens}, {tags, types}),
    do: bare_field(strip_parens(tokens), tags, types) not in [nil, :boolean]

  defp bare_member?({kind, nodes}, ctx) when kind in [:and, :or],
    do: Enum.any?(nodes, &bare_member?(&1, ctx))

  defp bare_member?(_node, _ctx), do: false

  @spec bare_error(atom()) :: binary()
  defp bare_error(type) do
    "type_coercion\ncaused by\nError during planning: Cannot infer common argument type " <>
      "for logical boolean operation Boolean AND #{Map.fetch!(@arrow_types, type)}"
  end
end
