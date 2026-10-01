defmodule InfluxElixir.OptionalDependencyTest do
  use ExUnit.Case, async: true

  # `decimal` is optional (mix.exs). Matching `%Decimal{}` expands the struct
  # at compile time, so the library failed to compile in a project without
  # it (verified with a scratch consumer). Code must match
  # `%{__struct__: Decimal}` and call Decimal only behind that match.
  @optional_structs ~w(Decimal)

  test "the library never expands a struct of an optional dependency" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          module <- @optional_structs,
          String.contains?(line, "%#{module}{"),
          not String.starts_with?(String.trim_leading(line), "#"),
          do: "#{path}:#{number}"

    assert offenders == []
  end
end
