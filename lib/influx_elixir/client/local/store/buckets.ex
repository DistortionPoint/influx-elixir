defmodule InfluxElixir.Client.Local.Buckets do
  @moduledoc false
  # What the InfluxDB 2 profile of `InfluxElixir.Client.Local` derives from a
  # bucket: its retention, the length of its shard groups, the scope a
  # measurement's columns are registered under in one of them, and the
  # bucket's id.

  alias InfluxElixir.Client.Local.{LineProtocolParser, Store}

  @doc """
  The scope a point's columns are registered under: its measurement and its
  shard group, as a field's type is fixed per shard group.
  """
  @spec scope(LineProtocolParser.point(), integer()) :: binary()
  def scope(point, group), do: point.measurement <> <<0>> <> Integer.to_string(group)

  @doc """
  How long a bucket's shard groups are: a week when its retention is none or at
  least 180 days, a day from two days, an hour below (verified against InfluxDB 2).
  """
  @spec shard_group_seconds(non_neg_integer()) :: pos_integer()
  def shard_group_seconds(retention) when retention == 0 or retention >= 15_552_000, do: 604_800
  def shard_group_seconds(retention) when retention >= 172_800, do: 86_400
  def shard_group_seconds(_retention), do: 3_600

  @doc "The retention of a bucket in seconds, 0 (infinite) for one that is not registered."
  @spec retention(Store.t(), binary()) :: non_neg_integer()
  def retention(table, bucket) do
    case Store.bucket(table, bucket) do
      %{retention: seconds} -> seconds
      _unregistered -> 0
    end
  end

  @doc """
  InfluxDB 2's ids are 16 hex digits; these are derived from the name, so
  they stay the same across calls and connections.
  """
  @spec hex_id(binary()) :: binary()
  def hex_id(name) do
    :crypto.hash(:sha256, name) |> binary_part(0, 8) |> Base.encode16(case: :lower)
  end
end
