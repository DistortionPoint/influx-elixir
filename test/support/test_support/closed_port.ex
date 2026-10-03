defmodule InfluxElixir.TestSupport.ClosedPort do
  @moduledoc """
  A loopback port that nothing listens on, for a test of a connection failure.

  Port 1 (tcpmux, long obsolete) lies below the range the system hands out
  for port 0 (49152 and up on macOS, 32768 and up on Linux), so no listener
  another async test opens can take it. A port bound and then closed would
  not do: another test's listener can be given the same number before the
  connection is made, and the connection then hangs instead of being
  refused. A connection to port 1 is refused (`:econnrefused`) at once.
  """

  @doc "Returns a port on `127.0.0.1` that nothing listens on."
  @spec port() :: :inet.port_number()
  def port, do: 1
end
