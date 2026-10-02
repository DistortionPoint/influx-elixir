defmodule InfluxElixir.Client.Local.InfluxQLReserved do
  @moduledoc """
  The words InfluxQL reserves. A reserved word is no bare identifier: the
  engine's parser refuses it in the select list, the `WHERE` and the
  `GROUP BY`, and only quotes make it a name.
  """

  @reserved ~w(
    all alter analyze and any as asc begin by cardinality continuous create database
    databases default delete desc destinations diagnostics distinct drop duration end every
    exact explain field for from grant grants group groups in inf insert into key keys kill
    limit measurement measurements name offset on or order password policies policy
    privileges queries query read replication resample retention revoke select series set
    shard shards show slimit soffset stats subscription subscriptions tag to user users
    values where with write
  )

  @doc "Whether a bare word is one InfluxQL reserves (any case)."
  @spec reserved?(binary()) :: boolean()
  def reserved?(word), do: String.downcase(word) in @reserved

  # The reserved word a text starts with, as `{word, length}`, unless a `::`
  # follows (a cast, which the engine reads) or, with `plain: true`, a `(`
  # (a call).
  @spec reserved_start(binary(), keyword()) :: {binary(), non_neg_integer()} | nil
  @doc false
  def reserved_start(text, opts \\ []) do
    with [_all, word] <- Regex.run(~r/^([A-Za-z_]\w*)(?![\w:])/, text),
         true <- reserved?(word),
         false <- Keyword.get(opts, :plain, false) and called?(text, word) do
      {word, byte_size(word)}
    else
      _other -> nil
    end
  end

  @spec called?(binary(), binary()) :: boolean()
  defp called?(text, word),
    do:
      text
      |> binary_part(byte_size(word), byte_size(text) - byte_size(word))
      |> then(&(&1 =~ ~r/^\s*\(/))
end
