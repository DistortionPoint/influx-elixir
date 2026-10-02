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
