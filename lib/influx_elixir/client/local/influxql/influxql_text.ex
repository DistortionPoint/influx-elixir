defmodule InfluxElixir.Client.Local.InfluxQLText do
  @moduledoc false
  # The text of an InfluxQL statement, below the parser that reads it and the
  # checks that judge it:
  #
  #   * the words InfluxQL reserves: a reserved word is no bare identifier, the
  #     engine's parser refuses it in the select list, the `WHERE` and the
  #     `GROUP BY`, and only quotes make it a name
  #   * quoted identifiers and blank text
  #   * the statement with its literals masked, so that a keyword inside one is
  #     no keyword
  #   * the clauses after `FROM`

  alias InfluxElixir.Client.Local.{InfluxQLLex, SQLMask}

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

  @doc """
  The reserved word a text starts with, as `{word, length}`, unless a `::`
  follows (a cast, which the engine reads) or, with `plain: true`, a `(` (a
  call).
  """
  @spec reserved_start(binary(), keyword()) :: {binary(), non_neg_integer()} | nil
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

  @doc "A quoted identifier without its quotes and escapes; any other text as it is."
  @spec unquote_ident(binary()) :: binary()
  def unquote_ident("\"" <> _rest = quoted),
    do: quoted |> String.trim("\"") |> String.replace("\\\"", "\"")

  def unquote_ident(ident), do: ident

  @doc "A number written with no digit before its point (`.5`, `-.5`) with the zero Elixir reads it with."
  @spec leading_zero(binary()) :: binary()
  def leading_zero("-." <> fraction), do: "-0." <> fraction
  def leading_zero("." <> fraction), do: "0." <> fraction
  def leading_zero(text), do: text

  @doc "`nil` for blank text, the trimmed text otherwise."
  @spec blank_to_nil(binary()) :: binary() | nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(text), do: InfluxQLLex.trim_both_blanks(text)

  @doc """
  The statement with the inside of every quoted string, quoted identifier
  and `=~ /regex/` blanked to underscores, byte for byte (spaces would let
  the clause regexes backtrack for ages), so that what is looked for in it
  (`fill(`, `INTO`, `GROUP BY`) is a keyword and not a piece of a value.
  """
  @spec mask_literals(binary()) :: binary()
  def mask_literals(statement) do
    SQLMask.mask(statement,
      blank: ?_,
      doubled: false,
      backslash: true,
      regex: true,
      lenient: true
    )
  end

  @clauses ~r/^\s*(?:WHERE\s+(?<where>.+?))?\s*(?:GROUP\s+BY\s+(?<group>.+?))?\s*(?<fillcall>fill\s*\((?<fill>[^)]*)\))?\s*(?:ORDER\s+BY\s+(?:time\s+(?=ASC|DESC)|(?=ASC\b|DESC\b)|time\b)(?<dir>ASC|DESC)?)?\s*(?:LIMIT\s+(?<limit>\d+))?\s*(?:OFFSET\s+(?<offset>\d+))?\s*(?:SLIMIT\s+(?<slimit>\d+))?\s*(?:SOFFSET\s+(?<soffset>\d+))?\s*(?<tzcall>TZ\s*\(\s*'(?<tz>[^']*)'\s*\))?\s*;?\s*$/is

  @open_operand ~r/(?:[-+*=<>(,~!]|(?<![_\/])\/|\b(?:AND|OR))\s*$/i
  @fill_call ~r/(?<![\w])fill\s*\(/i

  @doc """
  Matches a masked text that ends where an operand is wanted: after an operator, a sign, a
  comma, an opening parenthesis or a connective. A slash is an operator unless it closes a
  regular expression (masked to underscores up to it).
  """
  @spec open_operand() :: Regex.t()
  def open_operand, do: @open_operand

  @doc "Matches the start of a `fill(` call in a masked text."
  @spec fill_call() :: Regex.t()
  def fill_call, do: @fill_call

  @doc """
  The regular expression that cuts what follows `FROM <measurement>` into its

  clauses (`where`, `group`, `fillcall` with its option `fill`, `dir`, `limit`,
  `offset`), run over a masked statement.
  """
  @spec clauses() :: Regex.t()
  def clauses, do: @clauses
end
