defmodule InfluxElixir.ContractCaseTablesTest do
  @moduledoc """
  Keeps the contracts' case tables (`InfluxElixir.Contract.*Cases`) free of a case
  written twice.

  A case is run once per table per tier, so a repeat adds a second run of the same
  statement and no assertion: it reads as coverage and is none. A case is identified
  by what it asks, which is its text, and for the SQL tables the kind of place the
  text stands in as well (`{kind, text}`). Two cases with the same identity and
  different expectations are worse: one of them is wrong on the engine.

  The tables are found by name: every public function without arguments, in every
  module of the application whose name ends in `Cases`, that returns a list.
  The SQL tables (cases of `{kind, text, ...}`) all run over the same fixture, so
  there a case is also unique across tables: a text in two of them is run twice
  against the same rows. The InfluxQL tables (`{text, ...}`) each bring a fixture
  of their own, so there the same text in two tables is two different questions.
  """

  use ExUnit.Case, async: true

  @tables for {:ok, modules} <- [:application.get_key(:influx_elixir, :modules)],
              module <- modules,
              String.ends_with?(Atom.to_string(module), "Cases"),
              {name, 0} <- module.__info__(:functions),
              do: {module, name}

  test "the scan finds the case tables of every cases module" do
    modules = @tables |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    assert length(modules) >= 8
    assert length(@tables) >= 30
  end

  test "no case is written twice in its table" do
    repeated =
      for {module, name} <- @tables,
          {identity, count} <- apply(module, name, []) |> Enum.frequencies_by(&identity/1),
          count > 1,
          do: "#{inspect(module)}.#{name}/0 x#{count}: #{inspect(identity)}"

    assert repeated === []
  end

  test "no SQL case is written in two tables" do
    in_tables =
      for {module, name} <- @tables,
          case_ <- apply(module, name, []),
          {kind, _text} = identity <- [identity(case_)],
          is_atom(kind),
          uniq: true,
          do: {identity, {module, name}}

    repeated =
      for {identity, tables} <- Enum.group_by(in_tables, &elem(&1, 0), &elem(&1, 1)),
          length(tables) > 1,
          do: "#{inspect(identity)} is in #{inspect(Enum.sort(tables))}"

    assert Enum.sort(repeated) === []
  end

  # `{kind, text, ...}` where the first element is the kind of place (an atom),
  # `{text, ...}` where it is the text, or the case itself.
  defp identity({kind, text, _expectation}) when is_atom(kind), do: {kind, text}
  defp identity({kind, text, _tag, _answer}) when is_atom(kind), do: {kind, text}
  defp identity({kind, text, _tag, _status, _body}) when is_atom(kind), do: {kind, text}
  defp identity({text, _expectation}), do: text
  defp identity(other), do: other
end
