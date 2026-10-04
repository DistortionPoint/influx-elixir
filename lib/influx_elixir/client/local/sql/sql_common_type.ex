defmodule InfluxElixir.Client.Local.SQLCommonType do
  @moduledoc false
  # The type that results of a `CASE`, or the arguments of a `COALESCE`,
  # `NULLIF`, `GREATEST` or `LEAST` share (verified against InfluxDB 3 Core).
  # Kept apart from `InfluxElixir.Client.Local.SQLExprType`, which calls it,
  # so that no module waits on another.

  @typedoc "An Arrow type name, `nil` when not known, `:mixed` for a mix that has no type."
  @type type :: binary() | nil | :mixed

  @doc """
  The type the results of a `CASE` (`:case`), the arguments of a `COALESCE`, `GREATEST` or
  `LEAST` (`:coalesce`) or of a `NULLIF` (`:nullif`) share, ignoring the ones not known and
  the `NULL`s: the one type, `Float64` for an `Int64` with a `Float64`, `:mixed` for any other
  mix, `nil` when none is known and `Null` when every one is the null (verified:
  `case when true then null end`, `coalesce(NULL, NULL)` and `greatest(NULL, NULL)` are
  `Null`, `greatest(NULL, 1)` an `Int64`).

  A number with text is plain text in a `CASE`; in the others the text is cast to the number
  (`coalesce('s', u)` is a `UInt64`, and fails when the text is not one); a tag with a number
  is a tag of numbers in the others (`coalesce(host, 1)` is `Dictionary(Int32, Int64)`, which
  has no type here), but the number in a `NULLIF`.
  """
  @spec common([type()], :case | :coalesce | :nullif) :: type()
  def common(types, mode) do
    types
    |> Enum.reject(&(is_nil(&1) or &1 == "Null"))
    |> Enum.map(&family/1)
    |> Enum.uniq()
    |> case do
      [] -> if types != [] and Enum.all?(types, &(&1 == "Null")), do: "Null"
      [single] -> single |> single_type(types) |> text(types, mode, :single)
      families -> families |> mixed(mode) |> text(types, mode, :mixed) |> tag_of(types, mode)
    end
  end

  # The kind of text the results share (verified with `arrow_typeof`): where all are text, a
  # tag among them keeps it (`CASE WHEN ... THEN host ELSE 'x' END` is a tag) except where a
  # `CASE` has the null for a result, which makes plain text of it; a number with text is
  # plain text; and text that any of the results holds as a view stays a view, whatever else
  # is there.
  @tag "Dictionary(Int32, Utf8)"

  @spec text(type(), [type()], :case | :coalesce | :nullif, :single | :mixed) :: type()
  defp text("Utf8", types, mode, shape) do
    cond do
      "Utf8View" in types -> "Utf8View"
      shape == :single and @tag in types and not (mode == :case and "Null" in types) -> @tag
      true -> "Utf8"
    end
  end

  defp text(type, _types, _mode, _shape), do: type

  @numbers ["Int64", "UInt64", "Float64", "Int32", "Int16", "Int8"]

  @doc """
  Whether the types are numbers and text and nothing else (the engine casts one to the other
  when it runs the plan, and the connection closes if a value does not cast).
  """
  @spec number_with_text?([type()]) :: boolean()
  def number_with_text?(types) do
    families = types |> Enum.reject(&(is_nil(&1) or &1 == "Null")) |> Enum.map(&family/1)

    "Utf8" in families and Enum.any?(families, &(&1 in @numbers)) and
      Enum.all?(families, &(&1 == "Utf8" or &1 in @numbers))
  end

  @doc """
  Whether a type is a tag of numbers (`Dictionary(Int32, Int64)`): a number the engine reads
  from text, which has no use here beyond the words of its errors.
  """
  @spec tag_numbers?(type()) :: boolean()
  def tag_numbers?(type),
    do:
      type in [
        "Dictionary(Int32, Int64)",
        "Dictionary(Int32, UInt64)",
        "Dictionary(Int32, Float64)"
      ]

  @doc """
  Whether the types are numbers and nothing else, the null and the ones not known apart.
  """
  @spec numbers?([type()]) :: boolean()
  def numbers?(types) do
    typed = Enum.reject(types, &(is_nil(&1) or &1 == "Null"))
    typed != [] and Enum.all?(typed, &(&1 in @numbers))
  end

  # A column's type, without the dictionary of a tag.
  @spec family(type()) :: binary() | :mixed
  defp family("Dictionary(Int32, Utf8)"), do: "Utf8"
  defp family("Utf8View"), do: "Utf8"
  defp family(type), do: type

  @spec single_type(binary() | :mixed, [type()]) :: type()
  defp single_type("Utf8", _types), do: "Utf8"

  defp single_type(type, _types)
       when type in ["Boolean", "Int64", "UInt64", "Float64"],
       do: type

  defp single_type(_other, _types), do: :mixed

  @doc """
  The type the engine gives the mix, for the errors that name it: as `common/2`, and for
  numbers the double does not combine the type the engine combines them to (`Float64` beside
  a float, `Decimal128` for a signed integer with an unsigned one). The values of such a mix
  are not the double's to compute (`common/2` is `:mixed` for them).
  """
  @spec planned([type()], :case | :coalesce | :nullif) :: type()
  def planned(types, mode) do
    case common(types, mode) do
      :mixed -> numbers_type(types)
      type -> type
    end
  end

  @spec numbers_type([type()]) :: type()
  defp numbers_type(types) do
    typed = types |> Enum.reject(&(is_nil(&1) or &1 == "Null")) |> Enum.uniq()

    cond do
      not numbers?(typed) -> :mixed
      "Float64" in typed -> "Float64"
      "UInt64" in typed and "Int64" in typed -> "Decimal128(?)"
      true -> :mixed
    end
  end

  # A tag among text cast to a number makes a tag of numbers (`coalesce(host, 1)` is a
  # `Dictionary(Int32, Int64)`), which the double does not model.
  @spec tag_of(type(), [type()], :case | :coalesce | :nullif) :: type()
  defp tag_of(number, types, :coalesce) when number in ["Int64", "UInt64", "Float64"] do
    if @tag in types, do: "Dictionary(Int32, #{number})", else: number
  end

  defp tag_of(type, _types, _mode), do: type

  @spec cast_to_number([binary() | :mixed]) :: type()
  defp cast_to_number(numbers) do
    case Enum.sort(numbers) do
      [single] when single in ["Int64", "UInt64", "Float64"] -> single
      ["Float64", "Int64"] -> "Float64"
      _other -> :mixed
    end
  end

  # An unsigned integer beside a signed one is a decimal (the precision is not tracked;
  # verified: `coalesce(n, u)` is a `Decimal128(20, 0)`). Beside a float it is a float, whose
  # values the double does not convert, so it has no type here.
  @spec unsigned_with([binary() | :mixed]) :: type()
  defp unsigned_with(families),
    do: if(Enum.sort(families) == ["Int64", "UInt64"], do: "Decimal128(?)", else: :mixed)

  @spec mixed([binary() | :mixed], :case | :coalesce | :nullif) :: type()
  defp mixed(families, mode) do
    cond do
      Enum.sort(families) == ["Float64", "Int64"] -> "Float64"
      mode == :case and Enum.sort(families) in [["Int64", "Utf8"], ["Float64", "Utf8"]] -> "Utf8"
      mode != :case and "Utf8" in families -> cast_to_number(List.delete(families, "Utf8"))
      mode != :case -> unsigned_with(families)
      true -> :mixed
    end
  end
end
