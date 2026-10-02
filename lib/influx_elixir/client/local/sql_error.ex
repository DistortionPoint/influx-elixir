defmodule InfluxElixir.Client.Local.SQLError do
  @moduledoc """
  The error maps `InfluxElixir.Client.Local` answers a SQL query with: the
  engine's own words under the engine's status, and the `Client.Local:`
  refusal for what the double declines to model.

  Every constructor returns `%{status: status, body: body}`, the shape
  `Client.HTTP` returns for a non-success response.
  """

  @typedoc "An HTTP-style error answer."
  @type t :: %{status: pos_integer(), body: binary()}

  @doc """
  The refusal of a query the double does not model. The `Client.Local: `
  prefix tells a reader that the double, not InfluxDB, declined.
  """
  @spec refusal(binary()) :: t()
  def refusal(message), do: %{status: 400, body: "Client.Local: " <> message}

  @doc "The engine's planning error, `Error during planning: <message>`."
  @spec planning(binary()) :: t()
  def planning(message), do: %{status: 400, body: "Error during planning: " <> message}

  @doc """
  A planning error found by the type coercion pass, which the engine wraps
  as `type_coercion\\ncaused by\\nError during planning: <message>`.
  """
  @spec coercion(binary()) :: t()
  def coercion(message),
    do: %{status: 400, body: "type_coercion\ncaused by\nError during planning: " <> message}

  @doc """
  The engine's SQL tokenizer error at a position: `SQL error:
  TokenizerError("<message> at Line: <line>, Column: <column>")`.
  """
  @spec tokenizer(binary(), pos_integer(), pos_integer()) :: t()
  def tokenizer(message, line, column) do
    # The engine prints the error with Rust's Debug format, which escapes a
    # `"` or `\` inside the message (verified: `'\"'`).
    debug = message |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

    %{
      status: 400,
      body: ~s|SQL error: TokenizerError("#{debug} at Line: #{line}, Column: #{column}")|
    }
  end

  @doc """
  An error the optimizer's `simplify_expressions` pass raises while it folds
  a constant (an unparseable timestamp string, an invalid regular
  expression): `Optimizer rule 'simplify_expressions' failed\\ncaused by\\n<message>`,
  status 500. It comes after the planner's own errors.
  """
  @spec simplify(binary()) :: t()
  def simplify(message),
    do: %{
      status: 500,
      body: "Optimizer rule 'simplify_expressions' failed\ncaused by\n" <> message
    }

  @doc """
  The Arrow kernel's error for the negation of the smallest integer of a type
  that the engine's interval analysis meets while it reads a `WHERE`'s
  constants, status 500. `text` is the integer, as printed (`-9223372036854775808`).
  """
  @spec overflow(binary()) :: t()
  def overflow(text),
    do: %{status: 500, body: "Arrow error: Arithmetic overflow: Overflow happened on: - " <> text}

  @doc """
  What `Client.HTTP` returns when the engine fails a query after it has sent
  `200`: it closes the connection mid-response. An integer divided by zero,
  an overflowing `abs`, a cast that cannot be performed and a bin of zero
  width fail this way.
  """
  @spec closed() :: {:connection_error, Mint.TransportError.t()}
  def closed, do: {:connection_error, %Mint.TransportError{reason: :closed}}

  @doc """
  The physical planner's error for a `WHERE` whose conjuncts on `time` leave
  no instant (`time > X AND time < X`), status 500.
  """
  @spec empty_range() :: t()
  def empty_range do
    %{
      status: 500,
      body:
        "External error: unexpected: provided filters on time column did not produce a " <>
          "valid set of boundaries"
    }
  end

  @doc """
  The engine's internal error for a `WHERE` that leaves a numeric column an
  empty interval (status 500), as raised for the first conjunct of the
  filter: a lower bound reads `lhs:Null, rhs:<type>`, an upper bound
  `lhs:<type>, rhs:Null`, and an `=` is the `intersectable` variant with a
  null on the left.
  """
  @spec interval(atom(), :int64 | :uint64 | :float64) :: t()
  def interval(op, type) do
    {verb, sides} =
      case op do
        :eq -> {"intersectable", "lhs:Null, rhs:#{interval_type(type)}"}
        op when op in [:gt, :gte] -> {"comparable", "lhs:Null, rhs:#{interval_type(type)}"}
        _upper -> {"comparable", "lhs:#{interval_type(type)}, rhs:Null"}
      end

    %{
      status: 500,
      body:
        "Internal error: Only intervals with the same data type are #{verb}, #{sides}.\n" <>
          "This issue was likely caused by a bug in DataFusion's code. Please help us to " <>
          "resolve this by filing a bug report in our issue tracker: " <>
          "https://github.com/apache/datafusion/issues"
    }
  end

  @spec interval_type(:int64 | :uint64 | :float64) :: binary()
  defp interval_type(:int64), do: "Int64"
  defp interval_type(:uint64), do: "UInt64"
  defp interval_type(:float64), do: "Float64"

  @doc """
  The engine's internal error for a BETWEEN whose operand and bound have no
  common type (a type coercion error, status 500).
  """
  @spec between_coercion(binary(), binary()) :: t()
  def between_coercion(operand_type, bound_type) do
    %{
      status: 500,
      body:
        "type_coercion\ncaused by\nInternal error: Failed to coerce types #{operand_type} and " <>
          "#{bound_type} in BETWEEN expression.\nThis issue was likely caused by a bug in " <>
          "DataFusion's code. Please help us to resolve this by filing a bug report in our " <>
          "issue tracker: https://github.com/apache/datafusion/issues"
    }
  end
end
