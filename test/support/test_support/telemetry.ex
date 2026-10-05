defmodule InfluxElixir.TestSupport.Telemetry do
  @moduledoc """
  Forwards telemetry events to the test process that attached.

  Handlers are global, so events emitted by other async tests would leak
  in. A handler runs in the emitting process; forwarding only when that is
  the attaching test process keeps each test isolated. Each event arrives
  as `{:telemetry, event, measurements, metadata}`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Attaches a forwarding handler for `events` to the calling test process,
  detached again when the test exits. Returns the handler id.
  """
  @spec attach([[atom()]]) :: String.t()
  def attach(events) when is_list(events) do
    handler_id = "influx-elixir-test-#{inspect(self())}-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(handler_id, events, &__MODULE__.forward_event/4, %{test_pid: self()})

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  @doc false
  @spec forward_event([atom()], map(), map(), %{test_pid: pid()}) :: :ok
  def forward_event(event, measurements, metadata, %{test_pid: test_pid}) do
    if self() === test_pid, do: send(test_pid, {:telemetry, event, measurements, metadata})
    :ok
  end
end
