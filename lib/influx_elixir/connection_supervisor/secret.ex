defmodule InfluxElixir.ConnectionSupervisor.Secret do
  @moduledoc false
  # A token on its way through a supervisor's child spec and init argument. Those appear in
  # the error `Supervisor.start_child/2` returns and in the logs of a failed start
  # (stacktraces and child specs print their arguments), so the token travels as a closure:
  # `inspect/1` and Erlang's `~p` both print a function without what it captured, where a
  # struct would print its fields.

  @derive {Inspect, only: []}
  defstruct [:reveal]

  @type t :: %__MODULE__{reveal: (-> binary())}

  @doc false
  # Hides the `:token` of a connection config (a keyword list, as `start_link/1` checks); a
  # config without one is returned as it is.
  @spec redact(keyword()) :: keyword()
  def redact(config) do
    case Keyword.fetch(config, :token) do
      {:ok, token} when is_binary(token) ->
        Keyword.put(config, :token, %__MODULE__{reveal: fn -> token end})

      _no_token ->
        config
    end
  end

  @doc false
  # The config as it was before `redact/1`.
  @spec reveal(keyword()) :: keyword()
  def reveal(config) do
    case Keyword.fetch(config, :token) do
      {:ok, %__MODULE__{reveal: reveal}} -> Keyword.put(config, :token, reveal.())
      _no_secret -> config
    end
  end
end
