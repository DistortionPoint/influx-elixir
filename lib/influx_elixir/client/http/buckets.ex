defmodule InfluxElixir.Client.HTTP.Buckets do
  @moduledoc false
  # The InfluxDB 2 bucket calls of `InfluxElixir.Client.HTTP` (`api_version: :v2`).

  alias InfluxElixir.Client.HTTP.Request

  # InfluxDB 2 answers at most 100 buckets a page (20 by default), so the pages are
  # read until one is short (verified).
  @bucket_page 100

  @doc false
  @spec create(keyword(), term(), keyword()) :: :ok | {:error, term()}
  def create(connection, name, opts) do
    retention = Keyword.get(opts, :retention, 0)

    with {:ok, org} <- resolve_org_id(connection, opts),
         {:ok, %Finch.Response{}} <-
           Request.post_json(
             connection,
             "/api/v2/buckets",
             Map.merge(org, %{
               "name" => name,
               "retentionRules" => [%{"everySeconds" => retention}]
             }),
             opts,
             [200, 201]
           ) do
      :ok
    else
      # Creating a bucket that already exists is idempotent, matching
      # Client.Local and the 409 handling in create_database/3.
      {:error, %{status: 422, body: resp_body}} = error ->
        if String.contains?(to_string(resp_body), "already exists"), do: :ok, else: error

      error ->
        error
    end
  end

  # v2 buckets belong to an org by ID, not name. `opts[:org_id]` wins;
  # otherwise the ID is looked up from the connection's `:org` name. Without
  # either, no `orgID` is sent and the server's 400 is the answer: a lookup of
  # the empty name lists every org the token can read (verified), and its first
  # would be a guess.
  @spec resolve_org_id(keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  defp resolve_org_id(connection, opts) do
    case {Keyword.get(opts, :org_id), Request.conn_val(connection, :org, "")} do
      {nil, org} when org in [nil, ""] -> {:ok, %{}}
      {nil, org} -> lookup_org_id(connection, org, opts)
      {org_id, _org} -> {:ok, %{"orgID" => org_id}}
    end
  end

  @spec lookup_org_id(keyword(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  defp lookup_org_id(connection, org, opts) do
    with :ok <- Request.url_values(org: org),
         {:ok, %Finch.Response{body: body}} <-
           Request.get(connection, "/api/v2/orgs?org=#{Request.query_value(org)}", [200], opts),
         {:ok, %{"orgs" => [%{"id" => id} | _rest]}} when is_binary(id) and id != "" <-
           Request.decode_json(body) do
      {:ok, %{"orgID" => id}}
    else
      {:ok, _no_orgs} -> {:error, {:org_not_found, org}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(connection) do
    with {:ok, org_query} <- org_param(connection),
         do: list_pages(connection, 0, org_query, [])
  end

  @spec list_pages(keyword(), non_neg_integer(), binary(), [[map()]]) ::
          {:ok, [map()]} | {:error, term()}
  defp list_pages(connection, offset, org_query, pages) do
    path = "/api/v2/buckets?limit=#{@bucket_page}&offset=#{offset}" <> org_query

    with {:ok, %Finch.Response{body: resp_body}} <- Request.get(connection, path, [200]),
         {:ok, %{"buckets" => page} = body} when is_list(page) <-
           Request.decode_json(resp_body) do
      cond do
        not Enum.all?(page, &is_map/1) ->
          {:error, {:unexpected_response, body}}

        length(page) == @bucket_page ->
          list_pages(connection, offset + @bucket_page, org_query, [page | pages])

        true ->
          {:ok, [page | pages] |> Enum.reverse() |> Enum.concat()}
      end
    else
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _reason} = error -> error
    end
  end

  # Buckets are named per org: without the connection's org a name (or a
  # listing) spans every org the token can read, and `delete_bucket/2`
  # deleted another org's bucket of the same name (verified).
  @spec org_param(keyword()) :: {:ok, binary()} | {:error, term()}
  defp org_param(connection) do
    case Request.conn_val(connection, :org, "") do
      org when org in [nil, ""] ->
        {:ok, ""}

      org ->
        with :ok <- Request.url_values(org: org) do
          {:ok, "&org=" <> Request.query_value(org)}
        end
    end
  end

  @doc false
  @spec delete(keyword(), term()) :: :ok | {:error, term()}
  def delete(connection, bucket) do
    with :ok <- Request.url_values(bucket: bucket),
         {:ok, bucket_id} <- resolve_bucket_id(connection, to_string(bucket)),
         {:ok, _response} <-
           Request.request(
             :delete,
             Request.base_url(connection) <> "/api/v2/buckets/#{Request.path_segment(bucket_id)}",
             Request.auth_headers(connection),
             nil,
             connection,
             [],
             [200, 204]
           ) do
      :ok
    end
  end

  # The v2 API deletes by 16-hex bucket ID, while Client.Local deletes by
  # name. Accept either so callers can pass the name against both clients. A
  # name is looked up first: `deadbeefdeadbeef` is a name a bucket may have.
  @spec resolve_bucket_id(keyword(), binary()) :: {:ok, binary()} | {:error, term()}
  defp resolve_bucket_id(connection, bucket) do
    case lookup_bucket_id(connection, bucket) do
      {:error, %{status: 404, body: "bucket not found: " <> _name}} = not_found ->
        if String.match?(bucket, ~r/^[0-9a-f]{16}$/), do: {:ok, bucket}, else: not_found

      found_or_error ->
        found_or_error
    end
  end

  @spec lookup_bucket_id_error(binary()) :: {:error, term()}
  defp lookup_bucket_id_error(name),
    do: {:error, %{status: 404, body: "bucket not found: #{name}"}}

  @spec lookup_bucket_id(keyword(), binary()) :: {:ok, binary()} | {:error, term()}
  defp lookup_bucket_id(connection, name) do
    # Scoped to an org, the server answers a missing name with a 404 of its
    # own rather than an empty list; both are this client's "not found". A
    # 404 for the org itself is passed on as the server's answer.
    with {:ok, org_query} <- org_param(connection),
         path = "/api/v2/buckets?name=#{Request.query_value(name)}" <> org_query,
         {:ok, %Finch.Response{body: body}} <- Request.get(connection, path, [200]),
         {:ok, %{"buckets" => [%{"id" => id} | _rest]}} when is_binary(id) and id != "" <-
           Request.decode_json(body) do
      {:ok, id}
    else
      {:ok, _no_buckets} ->
        lookup_bucket_id_error(name)

      {:error, %{status: 404, body: body}} = error ->
        if bucket_not_found?(body), do: lookup_bucket_id_error(name), else: error

      {:error, _reason} = error ->
        error
    end
  end

  @spec bucket_not_found?(binary()) :: boolean()
  defp bucket_not_found?(body) do
    match?({:ok, %{"message" => "bucket " <> _rest}}, Jason.decode(body))
  end
end
