defmodule InfluxElixir.ConnectionSupervisor.Secret do
  @moduledoc false
  # A token on its way through a supervisor's child spec and init argument. Those appear in
  # the error `Supervisor.start_child/2` returns and in the logs of a failed start
  # (stacktraces and child specs print their arguments), so the token travels as a closure:
  # `inspect/1` and Erlang's `~p` both print a function without what it captured, where a
  # struct would print its fields.

  alias InfluxElixir.Client.Options

  @derive {Inspect, only: []}
  defstruct [:reveal]

  @type t :: %__MODULE__{reveal: (-> term())}

  @doc false
  # Hides the `:token` of a connection config (a keyword list, as `start_link/1` checks), of
  # whatever type: a token given as a charlist is still the token, and the child spec of its
  # refused start is printed. A config without one is returned as it is.
  @spec redact(term()) :: term()
  def redact(config) do
    with true <- Options.keyword?(config),
         {:ok, token} when not is_struct(token, __MODULE__) <- Keyword.fetch(config, :token) do
      Keyword.put(config, :token, %__MODULE__{reveal: fn -> token end})
    else
      _unchanged -> config
    end
  end

  @doc false
  # The config as it was before `redact/1`.
  @spec reveal(term()) :: term()
  def reveal(config) do
    with true <- Options.keyword?(config),
         {:ok, %__MODULE__{reveal: reveal}} <- Keyword.fetch(config, :token) do
      Keyword.put(config, :token, reveal.())
    else
      _no_secret -> config
    end
  end
end
