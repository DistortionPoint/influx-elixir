defmodule InfluxElixir.Write.Point do
  @moduledoc """
  Point struct representing a single InfluxDB data point.

  Contains measurement name, tags, fields, and optional timestamp.

  ## Fields

    * `:measurement` - measurement name (required, string)
    * `:tags` - tag key-value pairs (optional, `%{String.t() => String.t()}`)
    * `:fields` - field key-value pairs (required, at least one)
    * `:timestamp` - point timestamp (optional, server assigns if nil)
  """

  @type field_value :: integer() | float() | String.t() | boolean()

  @type t :: %__MODULE__{
          measurement: String.t(),
          tags: %{String.t() => String.t()},
          fields: %{String.t() => field_value()},
          timestamp: DateTime.t() | integer() | nil
        }

  @enforce_keys [:measurement, :fields]
  defstruct [:measurement, :timestamp, tags: %{}, fields: %{}]

  @doc """
  Creates a new Point struct.

  ## Parameters

    * `measurement` - measurement name (string)
    * `fields` - field key-value pairs (map)
    * `opts` - optional keyword list:
      * `:tags` - tag key-value pairs (default: `%{}`)
      * `:timestamp` - point timestamp (default: `nil`)

  ## Examples

      iex> InfluxElixir.Write.Point.new("cpu", %{"value" => 0.64})
      %InfluxElixir.Write.Point{
        measurement: "cpu",
        fields: %{"value" => 0.64},
        tags: %{},
        timestamp: nil
      }

      iex> InfluxElixir.Write.Point.new("cpu", %{"value" => 0.64},
      ...>   tags: %{"host" => "server01"},
      ...>   timestamp: 1_630_424_257_000_000_000
      ...> )
      %InfluxElixir.Write.Point{
        measurement: "cpu",
        fields: %{"value" => 0.64},
        tags: %{"host" => "server01"},
        timestamp: 1_630_424_257_000_000_000
      }
  """
  @spec new(String.t(), %{String.t() => field_value()}, keyword()) :: t()
  def new(measurement, fields, opts \\ []) do
    %__MODULE__{
      measurement: measurement,
      fields: fields,
      tags: Keyword.get(opts, :tags, %{}),
      timestamp: Keyword.get(opts, :timestamp)
    }
  end
end
