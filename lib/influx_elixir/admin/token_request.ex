defmodule InfluxElixir.Admin.TokenRequest do
  @moduledoc false
  # The request InfluxDB 3 takes to create a token, built once for
  # `Client.HTTP` (which sends it) and `Client.Local` (which answers it as
  # the engine does, positions in its errors included). The bodies are the
  # ones the `influxdb3 create token` CLI sends (captured from Enterprise
  # 3.11.5), keys in the CLI's order:
  #
  #   * no permissions: an admin token,
  #     `POST /api/v3/configure/token/named_admin`
  #     `{"token_name": ..., "expiry_secs": ...}` (Core and Enterprise)
  #   * permissions: a resource token,
  #     `POST /api/v3/enterprise/configure/token`
  #     `{"token_name": ..., "permissions": [...], "expiry_secs": ...}`
  #     (Enterprise only; Core answers 404 `Not found`)

  @admin_path "/api/v3/configure/token/named_admin"
  @resource_path "/api/v3/enterprise/configure/token"

  @typedoc "Which endpoint a request goes to."
  @type kind :: :admin | :resource

  @doc """
  The endpoint kind, its path and the JSON body for a token named `name`.
  `opts` may hold `:permissions` (strings in the CLI's
  `RESOURCE_TYPE:RESOURCE_NAMES:ACTIONS` form, e.g. `"db:db1,db2:read,write"`)
  and `:expiry_secs`. A permission not in that form is
  `{:error, {:invalid_permission, permission}}`, before any request.
  """
  @spec build(binary(), keyword()) ::
          {:ok, {kind(), binary(), binary()}} | {:error, {:invalid_permission, term()}}
  def build(name, opts) do
    expiry = Keyword.get(opts, :expiry_secs)

    case Keyword.get(opts, :permissions, []) do
      [] ->
        {:ok, {:admin, @admin_path, encode([{"token_name", name}, {"expiry_secs", expiry}])}}

      permissions ->
        with {:ok, parsed} <- parse_permissions(permissions) do
          body =
            encode([{"token_name", name}, {"permissions", parsed}, {"expiry_secs", expiry}])

          {:ok, {:resource, @resource_path, body}}
        end
    end
  end

  @spec encode([{binary(), term()}]) :: binary()
  defp encode(pairs), do: Jason.encode!(Jason.OrderedObject.new(pairs))

  @spec parse_permissions([term()]) :: {:ok, [Jason.OrderedObject.t()]} | {:error, term()}
  defp parse_permissions(permissions) do
    permissions
    |> Enum.reduce_while({:ok, []}, fn permission, {:ok, acc} ->
      case parse_permission(permission) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, {:error, {:invalid_permission, permission}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  # `db:db1,db2:read,write` is resource type `db`, names `db1` and `db2`,
  # actions `read` and `write`; every part non-empty.
  @spec parse_permission(term()) :: {:ok, Jason.OrderedObject.t()} | :error
  defp parse_permission(permission) when is_binary(permission) do
    with [type, names, actions] when type != "" <- String.split(permission, ":", parts: 3),
         {:ok, names} <- list(names),
         {:ok, actions} <- list(actions) do
      {:ok,
       Jason.OrderedObject.new([
         {"resource_type", type},
         {"resource_names", names},
         {"actions", actions}
       ])}
    else
      _invalid -> :error
    end
  end

  defp parse_permission(_permission), do: :error

  @spec list(binary()) :: {:ok, [binary()]} | :error
  defp list(text) do
    items = String.split(text, ",")
    if Enum.any?(items, &(&1 == "")), do: :error, else: {:ok, items}
  end
end
