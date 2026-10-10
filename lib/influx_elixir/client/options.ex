defmodule InfluxElixir.Client.Options do
  @moduledoc false
  # The reads of caller-supplied terms that every client and the write path share: options
  # are a keyword list or the caller's error, a write body is iodata or the caller's error, a
  # connection holds a default database or does not. None of them raises.

  @doc false
  # A keyword list: the only form options can take.
  @spec keyword?(term()) :: boolean()
  def keyword?(opts), do: is_list(opts) and Keyword.keyword?(opts)

  @doc false
  # The text that iodata stands for (a binary is itself); anything that is not iodata is
  # `:error`, for the caller to name.
  @spec iodata(term()) :: {:ok, binary()} | :error
  def iodata(body) when is_binary(body), do: {:ok, body}

  def iodata(body) when is_list(body) do
    {:ok, IO.iodata_to_binary(body)}
  rescue
    ArgumentError -> :error
  end

  def iodata(_body), do: :error

  @doc false
  # The connection-level default database of a keyword (`Client.HTTP`) or map (`Client.Local`)
  # connection: the callers refuse any other term first.
  @spec database(keyword() | map()) :: binary() | nil
  def database(connection) when is_map(connection), do: Map.get(connection, :database)

  def database(connection) when is_list(connection) do
    if keyword?(connection), do: Keyword.get(connection, :database)
  end
end
