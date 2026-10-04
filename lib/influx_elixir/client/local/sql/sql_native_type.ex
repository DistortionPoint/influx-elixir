defmodule InfluxElixir.Client.Local.SQLNativeType do
  @moduledoc false
  # DataFusion's `NativeType` for an Arrow type, as its planning errors name it (verified
  # against InfluxDB 3 Core): the three string types are `String`, a timestamp is
  # `Timestamp(Nanosecond, None)`, and any other type is its own name.

  @struct ~r/\AStruct\("value": (.+), "time": Timestamp\(ns\)\)\z/

  @doc "DataFusion's NativeType for an Arrow type, as its messages name it."
  @spec native(binary()) :: binary()
  def native("Struct(" <> _fields = type) do
    case Regex.run(@struct, type) do
      [_all, value] ->
        "Struct(LogicalFields([#{logical("value", native(value))}, " <>
          "#{logical("time", "Timestamp(Nanosecond, None)")}]))"

      nil ->
        type
    end
  end

  def native("Utf8"), do: "String"
  def native("Dictionary(Int32, Utf8)"), do: "String"
  def native("Utf8View"), do: "String"
  def native("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"
  def native(type), do: type

  @spec logical(binary(), binary()) :: binary()
  defp logical(name, native) do
    ~s|LogicalField { name: "#{name}", logical_type: LogicalType(Native(#{native}), #{native}), | <>
      "nullable: true }"
  end
end
