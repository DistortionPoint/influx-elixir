defmodule InfluxElixir.TestSupport.Await do
  @moduledoc """
  Waits for a condition the test cannot observe an event for, with a hard
  deadline that fails the test loudly instead of passing by luck or hanging.

  Prefer a message (`assert_receive`) or a monitor wherever the code under
  test sends one; this is for conditions only readable by polling, such as
  a name that is registered again after a restart.

  No outcome depends on the timing here. The condition is checked again and
  again, every few milliseconds, until it holds; the pause between checks only
  spares the scheduler and the deadline only ends a run in which the condition
  never holds, by failing the test. A run that passes would pass with any pause and
  any deadline, however long.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  # The pause between two checks of the condition: a polling interval, not a wait for it.
  @poll_ms 2

  # The one failure bound every test wait shares (`assert_receive`, `Task.await`, `Await.until`,
  # a receive's `after`): far above what a healthy run needs, so it only ever ends a failing
  # one, and below ExUnit's 60 s test timeout, so a hang fails with the wait that named it
  # instead of the generic test timeout.
  @bound_ms 30_000

  @doc """
  The failure bound, in milliseconds, for any wait in a test.

  Never a measurement: it decides nothing about a passing run. A test that must show a
  value LOSING to another (a timeout option beating a default) gives the loser more than
  this bound, so the bound ends the wait first if the wrong value ever applied.
  """
  @spec bound() :: pos_integer()
  def bound, do: @bound_ms

  @doc """
  Calls `fun` until it returns a truthy value, and returns that value.

  Flunks when `deadline_ms` has passed without one. The deadline is a failure
  bound only: far above what a healthy run needs, it never decides whether a
  passing run passes, it only ends a failing one.
  """
  @spec until((-> term()), pos_integer()) :: term()
  def until(fun, deadline_ms \\ @bound_ms) when is_function(fun, 0) do
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
