defmodule InfluxElixir.TestSupport.Await do
  @moduledoc """
  Waits for a condition the test cannot observe an event for, with a hard
  deadline that fails the test loudly instead of passing by luck or hanging.

  Prefer a message (`assert_receive`) or a monitor wherever the code under
  test sends one; this is for conditions only readable by polling, such as
  a name that is registered again after a restart.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @poll_ms 2

  @doc """
  Calls `fun` until it returns a truthy value, and returns that value.

  Flunks when `deadline_ms` has passed without one. The deadline is far
  above what a healthy run needs, so it only ever bounds a failing one.
  """
  @spec until((-> term()), pos_integer()) :: term()
  def until(fun, deadline_ms \\ 5_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline, deadline_ms)
  end

  @spec poll((-> term()), integer(), pos_integer()) :: term()
  defp poll(fun, deadline, deadline_ms) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met within #{deadline_ms} ms")
        else
          Process.sleep(@poll_ms)
          poll(fun, deadline, deadline_ms)
        end

      value ->
        value
    end
  end
end
