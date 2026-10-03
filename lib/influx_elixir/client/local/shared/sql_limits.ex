defmodule InfluxElixir.Client.Local.SQLLimits do
  @moduledoc false
  # The ends of the engine's integer and float types, in one place for the SQL
  # modules of `InfluxElixir.Client.Local`.
  #
  # The macros expand to the literal, so they may stand in a pattern or a
  # guard (`require` or `import` this module first):
  #
  #     defp f(int64_min()), do: ...
  #     defp g(n) when n > uint64_max(), do: ...

  @doc "The smallest `Int64`."
  @spec int64_min() :: -9_223_372_036_854_775_808
  defmacro int64_min, do: -9_223_372_036_854_775_808

  @doc "The largest `Int64`."
  @spec int64_max() :: 9_223_372_036_854_775_807
  defmacro int64_max, do: 9_223_372_036_854_775_807

  @doc "The largest `UInt64`."
  @spec uint64_max() :: 18_446_744_073_709_551_615
  defmacro uint64_max, do: 18_446_744_073_709_551_615

  @doc "The largest finite `Float64`."
  @spec float_max() :: float()
  defmacro float_max, do: 1.797_693_134_862_315_7e308

  @doc "Whether the value is an integer an `Int64` holds."
  defguard is_int64(value)
           when is_integer(value) and value >= -9_223_372_036_854_775_808 and
                  value <= 9_223_372_036_854_775_807

  @doc "Whether the value is an integer a `UInt64` holds."
  defguard is_uint64(value)
           when is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615

  @two_64 18_446_744_073_709_551_616

  @doc "The integer, wrapped into `Int64`'s range as two's complement arithmetic does."
  @spec wrap_int64(integer()) :: integer()
  def wrap_int64(value) when is_int64(value), do: value

  def wrap_int64(value),
    do: Integer.mod(value + 9_223_372_036_854_775_808, @two_64) - 9_223_372_036_854_775_808

  @doc "The integer, wrapped into `UInt64`'s range."
  @spec wrap_uint64(integer()) :: non_neg_integer()
  def wrap_uint64(value) when is_uint64(value), do: value
  def wrap_uint64(value), do: Integer.mod(value, @two_64)
end
