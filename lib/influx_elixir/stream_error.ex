defmodule InfluxElixir.StreamError do
  @moduledoc """
  Raised while consuming a streaming query result when the request cannot
  produce rows.

  Streaming query functions such as `InfluxElixir.query_sql_stream/3` return
  an `Enumerable.t()`, so they cannot return an `{:error, reason}` tuple the
  way `InfluxElixir.query_sql/3` does. Instead, error classes are surfaced by
  raising this exception at consumption time — the moment the stream is
  enumerated — so failures are never silently swallowed as "zero rows".

  ## Kinds

    * `:no_database` — no database was resolved from opts or the connection
    * `:http_status` — the server responded with a non-success status; the
      `:status` and `:body` fields carry the response
    * `:transport` — a Finch/Mint transport error occurred; `:reason` carries it
    * `:decode` — a JSONL line could not be decoded as JSON; `:reason` carries
      the decode error

  ## Example

      try do
        conn
        |> InfluxElixir.query_sql_stream("SELECT * FROM cpu")
        |> Enum.to_list()
      rescue
        e in InfluxElixir.StreamError ->
          Logger.error("stream failed: " <> Exception.message(e))
          {:error, e}
      end
  """

  @type kind :: :no_database | :http_status | :transport | :decode

  @type t :: %__MODULE__{
          kind: kind(),
          status: non_neg_integer() | nil,
          body: term(),
          reason: term(),
          message: String.t()
        }

  defexception kind: :transport, status: nil, body: nil, reason: nil, message: nil

  @impl true
  def exception(opts) do
    kind = Keyword.get(opts, :kind, :transport)
    status = Keyword.get(opts, :status)
    body = Keyword.get(opts, :body)
    reason = Keyword.get(opts, :reason)

    %__MODULE__{
      kind: kind,
      status: status,
      body: body,
      reason: reason,
      message: build_message(kind, status, body, reason)
    }
  end

  @spec build_message(kind(), non_neg_integer() | nil, term(), term()) :: String.t()
  defp build_message(:no_database, _status, _body, _reason) do
    "no database specified for streaming query: pass `database:` in opts " <>
      "or set `:database` on the connection"
  end

  defp build_message(:http_status, status, body, _reason) do
    "streaming query failed with HTTP status #{status}: #{format_body(body)}"
  end

  defp build_message(:transport, _status, _body, reason) do
    "streaming query transport error: #{inspect(reason)}"
  end

  defp build_message(:decode, _status, _body, reason) do
    "failed to decode JSONL row in streaming response: #{inspect(reason)}"
  end

  @spec format_body(term()) :: String.t()
  defp format_body(body) when is_binary(body), do: body
  defp format_body(body), do: inspect(body)
end
