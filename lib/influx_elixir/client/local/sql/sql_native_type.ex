defmodule InfluxElixir.Client.Local.SQLNativeType do
  @moduledoc false
  # DataFusion's `NativeType` for an Arrow type, as its planning errors name it (verified
  # against InfluxDB 3 Core): the three string types are `String`, a timestamp is
  # `Timestamp(Nanosecond, None)`, and any other type is its own name.

  @doc "DataFusion's NativeType for an Arrow type, as its messages name it."
  @spec native(binary()) :: binary()
  def native("Utf8"), do: "String"
  def native("Dictionary(Int32, Utf8)"), do: "String"
  def native("Utf8View"), do: "String"
  def native("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"
  def native(type), do: type
end
