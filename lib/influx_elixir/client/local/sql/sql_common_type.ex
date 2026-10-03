defmodule InfluxElixir.Client.Local.SQLCommonType do
  @moduledoc false
  # The type that results of a `CASE`, or the arguments of a `COALESCE`,
  # `NULLIF`, `GREATEST` or `LEAST` share (verified against InfluxDB 3 Core).
  # Kept apart from `InfluxElixir.Client.Local.SQLExprType` and
  # `InfluxElixir.Client.Local.SQLFunctions`, which call the modules that need
  # this, so that none of them waits on another.

  @typedoc "An Arrow type name, `nil` when not known, `:mixed` for a mix that has no type."
  @type type :: binary() | nil | :mixed

  @doc """
  The type the results of a `CASE` (`:case`) or the arguments of a `COALESCE`
  or `NULLIF` (`:coalesce`) share, ignoring the ones not known: the one
  type, `Float64` for an `Int64` with a `Float64`, `Utf8` for a number with
  text in a `CASE`, `:mixed` for any other mix, `nil` when none is known.
  """
  @spec common([type()], :case | :coalesce) :: type()
  def common(types, mode) do
    types
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&family/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      [single] -> single_type(single, types)
      families -> mixed(families, mode)
    end
    |> viewed(types)
  end

  # Text that any of the results holds as a view stays a view.
  @spec viewed(type(), [type()]) :: type()
  defp viewed("Utf8", types), do: if("Utf8View" in types, do: "Utf8View", else: "Utf8")
  defp viewed(type, _types), do: type

  # A column's type, without the dictionary of a tag.
  @spec family(type()) :: binary() | :mixed
  defp family("Dictionary(Int32, Utf8)"), do: "Utf8"
  defp family("Utf8View"), do: "Utf8"
  defp family(type), do: type

  @spec single_type(binary() | :mixed, [type()]) :: type()
  defp single_type("Utf8", _types), do: "Utf8"
  defp single_type(type, _types) when type in ["Boolean", "Int64", "Float64"], do: type
  defp single_type(_other, _types), do: :mixed

  @spec mixed([binary() | :mixed], :case | :coalesce) :: type()
  defp mixed(families, mode) do
    cond do
      Enum.sort(families) == ["Float64", "Int64"] -> "Float64"
      mode == :case and Enum.sort(families) in [["Int64", "Utf8"], ["Float64", "Utf8"]] -> "Utf8"
      true -> :mixed
    end
  end
end
