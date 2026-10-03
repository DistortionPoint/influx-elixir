defmodule InfluxElixir.Client.Local.FluxQuery do
  @moduledoc false
  # The Flux path of `InfluxElixir.Client.Local` (InfluxDB 2): the query parsed
  # and run by `InfluxElixir.Client.Local.Flux` over the points of the bucket,
  # cut as the engine cuts a field written with different types in different
  # shard groups. `Client.Local.query_flux/3` is the public entry point.

  alias InfluxElixir.Client.Local.{Buckets, Flux, LineProtocolParser, Scope, Store}

  @type point_map :: LineProtocolParser.point()

  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(%{table: table} = conn, flux, _opts \\ []) do
    with :ok <- Scope.require_capability(conn, :query_flux),
         {:ok, query} <- flux_parse(flux),
         :ok <- flux_bucket_exists(table, query.bucket) do
      points = Store.points_in_db(table, query.bucket, Flux.measurements(query))

      case Flux.run(query, flux_typed(table, query, points)) do
        {:ok, rows} -> {:ok, rows}
        {:error, message} -> {:error, flux_error(400, "invalid", message)}
      end
    end
  end

  # A field written with different types in different shard groups reads
  # as the type of the earliest group the range touches, up to the first
  # later group of another type: that group and every group after it are
  # not returned, whatever their type (verified). The cut is per measurement
  # and field, across all tag sets. A bucket's shard groups are as long as
  # its retention makes them.
  @spec flux_typed(Store.t(), Flux.query(), [point_map()]) :: [point_map()]
  defp flux_typed(table, %{bucket: bucket} = query, points) do
    {start_ns, stop_ns} = Flux.range(query)
    shard_ns = Buckets.shard_group_seconds(Buckets.retention(table, bucket)) * 1_000_000_000

    touched =
      for point <- points,
          group = Integer.floor_div(point.timestamp, shard_ns),
          group * shard_ns < stop_ns and (group + 1) * shard_ns > start_ns,
          do: {point, group}

    case flux_cutoffs(table, bucket, touched) do
      cutoffs when map_size(cutoffs) == 0 ->
        Enum.map(touched, &elem(&1, 0))

      cutoffs ->
        for {point, group} <- touched,
            fields = flux_typed_fields(point, group, cutoffs),
            map_size(fields) > 0,
            do: %{point | fields: fields}
    end
  end

  # `{measurement, field} => group`: the first group that is not read. The
  # store is asked for the kind of a field once per measurement, group and
  # field, not once per point.
  @spec flux_cutoffs(Store.t(), binary(), [{point_map(), integer()}]) :: %{
          {binary(), binary()} => integer()
        }
  defp flux_cutoffs(table, bucket, touched) do
    kinds =
      Enum.reduce(touched, %{}, fn {point, group}, kinds ->
        Enum.reduce(point.fields, kinds, fn {field, _value}, kinds ->
          key = {point.measurement, field, group}

          if is_map_key(kinds, key) do
            kinds
          else
            kind = Store.column_kind(table, bucket, Buckets.scope(point, group), field)
            Map.put(kinds, key, kind)
          end
        end)
      end)

    kinds
    |> Enum.group_by(&series_of_kind/1, &group_and_kind/1)
    |> Enum.reduce(%{}, fn {series, group_kinds}, cutoffs ->
      [{_group, first} | later] = Enum.sort(group_kinds)

      case Enum.find(later, fn {_group, kind} -> kind != first end) do
        {group, _kind} -> Map.put(cutoffs, series, group)
        nil -> cutoffs
      end
    end)
  end

  @spec series_of_kind({{binary(), binary(), integer()}, term()}) :: {binary(), binary()}
  defp series_of_kind({{measurement, field, _group}, _kind}), do: {measurement, field}
  @spec group_and_kind({{binary(), binary(), integer()}, term()}) :: {integer(), term()}
  defp group_and_kind({{_measurement, _field, group}, kind}), do: {group, kind}

  @spec flux_typed_fields(point_map(), integer(), map()) :: map()
  defp flux_typed_fields(point, group, cutoffs) do
    Map.filter(point.fields, fn {field, _value} ->
      case Map.fetch(cutoffs, {point.measurement, field}) do
        {:ok, cutoff} -> group < cutoff
        :error -> true
      end
    end)
  end

  @spec flux_parse(binary()) :: {:ok, Flux.query()} | {:error, map()}
  defp flux_parse(flux) do
    # The clock untimed points are stamped with, plus a nanosecond: `stop`
    # is exclusive and the clock can read the same value for a write and
    # the query right after it, which on a real server never happen at
    # the same instant.
    case Flux.parse(flux, Store.now_ns() + 1) do
      {:ok, query} -> {:ok, query}
      {:error, message} -> {:error, flux_error(400, "invalid", message)}
    end
  end

  @spec flux_bucket_exists(Store.t(), binary()) :: :ok | {:error, map()}
  defp flux_bucket_exists(table, bucket) do
    if Store.bucket?(table, bucket) or Store.database?(table, bucket),
      do: :ok,
      else:
        {:error,
         flux_error(
           404,
           "not found",
           "failed to initialize execute state: could not find bucket \"#{bucket}\""
         )}
  end

  @spec flux_error(pos_integer(), binary(), binary()) :: map()
  defp flux_error(status, code, message),
    do: %{status: status, body: Jason.encode!(%{"code" => code, "message" => message})}
end
