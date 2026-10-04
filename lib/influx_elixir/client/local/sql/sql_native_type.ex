defmodule InfluxElixir.Client.Local.SQLNativeType do
  @moduledoc false
  # DataFusion's `NativeType` for an Arrow type, as its planning errors name it (verified
  # against InfluxDB 3 Core): the three string types are `String`, a timestamp is
  # `Timestamp(Nanosecond, None)`, and any other type is its own name. Also the one place that
  # tells a selector's struct from any other type, so that no module needs another to ask.

  @struct ~r/\AStruct\("value": (.+), "time": Timestamp\(ns\)\)\z/

  @doc "Whether an Arrow type is a struct (the result of a selector), which has no common type."
  @spec struct?(binary() | nil | :mixed) :: boolean()
  def struct?(type), do: is_binary(type) and String.starts_with?(type, "Struct(")

  @doc "DataFusion's NativeType for an Arrow type, as its messages name it."
  @spec native(binary()) :: binary()
  def native(type) do
    if struct?(type), do: native_struct(type), else: native_plain(type)
  end

  @spec native_struct(binary()) :: binary()
  defp native_struct(type) do
    case Regex.run(@struct, type) do
      [_all, value] ->
        "Struct(LogicalFields([#{logical("value", native(value))}, " <>
          "#{logical("time", "Timestamp(Nanosecond, None)")}]))"

      nil ->
        type
    end
  end

  @spec native_plain(binary()) :: binary()
  defp native_plain("Utf8"), do: "String"
  defp native_plain("Dictionary(Int32, Utf8)"), do: "String"
  defp native_plain("Utf8View"), do: "String"
  defp native_plain("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"
  defp native_plain(type), do: type

  @spec logical(binary(), binary()) :: binary()
  defp logical(name, native) do
    ~s|LogicalField { name: "#{name}", logical_type: LogicalType(Native(#{native}), #{native}), | <>
      "nullable: true }"
  end
end
