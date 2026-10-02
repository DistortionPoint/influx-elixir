defmodule InfluxElixir.Client.Local.SQLRow do
  @moduledoc """
  How a stored point's columns read in a SQL query of
  `InfluxElixir.Client.Local`: the value a column has, and the value a
  point sorts, groups and picks on.
  """

  alias InfluxElixir.Client.Local.LineProtocolParser

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: LineProtocolParser.point()

  @doc "The instant `ns` nanoseconds after the epoch as a `DateTime`, or `nil`."
  @spec nanoseconds_to_datetime(integer() | nil) :: DateTime.t() | nil
  def nanoseconds_to_datetime(nil), do: nil
  def nanoseconds_to_datetime(ns), do: DateTime.from_unix!(ns, :nanosecond)

  @doc """
  A column as a row carries it: `time` as a DateTime, a tag or field as
  stored. A tag wins over a field of the same name; `false` is a value, not
  a missing one. A CTE column named `time` that is not a timestamp is a
  field and is read as one.
  """
  @spec column_value(point(), binary()) :: term()
  def column_value(point, "time") do
    case point.fields do
      %{"time" => value} -> value
      _no_time_field -> nanoseconds_to_datetime(point.timestamp)
    end
  end

  def column_value(%{tags: tags, fields: fields}, column) do
    case tags do
      %{^column => value} ->
        value

      _no_tag ->
        case fields do
          %{^column => value} -> value
          _no_field -> nil
        end
    end
  end

  @doc """
  What a point sorts, groups and picks on for a column: `time` by its stored
  nanoseconds (a DateTime has only microseconds), anything else by its
  value. A null sorts last ascending and first descending.
  """
  @spec sort_value(point(), binary()) :: term()
  def sort_value(%{fields: %{"time" => value}}, "time"), do: value
  def sort_value(point, "time"), do: point.timestamp
  def sort_value(point, column), do: column_value(point, column)
end
