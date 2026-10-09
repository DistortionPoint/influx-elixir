defmodule InfluxElixir.Client.Local.InfluxQLText do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
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

  alias InfluxElixir.Client.Local.{InfluxQLBlankRegex, InfluxQLLex, SQLMask}

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
    with [_all, word] <- Regex.run(~q/^([A-Za-z_]\w*)(?![\w:])/, text),
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
      |> then(&(&1 =~ ~q/^\s*\(/))

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

  # The character sets of a keyword directly against the character after it. Each is defined
  # here once and used by every reader of the text (verified against InfluxDB 3 Core 3.10.1,
  # each character after each keyword), so that one cannot be fixed and another forgotten:
  #
  #   * `operator_glue`: the characters of an operator or a parenthesis. A keyword that takes a
  #     word after it still reads as the keyword before these (`GROUP BY(`, `ON*`, `AS/`,
  #     `SHOW TAG KEYS(`); before any other character that is no blank it is another word
  #   * `operand_open`: the characters a `WHERE` may stand directly against, because a
  #     condition may start with them
  #   * `item_end`: the characters a select item may end with directly against `FROM` (`*`,
  #     `)`, a quote or the slash that closes a regular expression)
  @operator_glue ~w[( ) * , = / + - < > ! % & | ^]
  @operator_glue_escaped Regex.escape(Enum.join(@operator_glue))
  @operator_glue_class "[" <> @operator_glue_escaped <> "]"
  @operand_open_chars "(+\\-"
  @operand_open_class "[" <> @operand_open_chars <> "]"
  @item_end_class "[*)\"'/]"

  @doc "The characters of an operator or a parenthesis, one binary each (see above)."
  @spec operator_glue() :: [binary()]
  def operator_glue, do: @operator_glue

  @doc "`operator_glue/0` as a bracket class of a regular expression."
  @spec operator_glue_class() :: binary()
  def operator_glue_class, do: @operator_glue_class

  @doc "`operator_glue/0` escaped, for the inside of a bracket class."
  @spec operator_glue_chars() :: binary()
  def operator_glue_chars, do: @operator_glue_escaped

  @doc "The characters a condition may start with, as the inside of a bracket class."
  @spec operand_open_chars() :: binary()
  def operand_open_chars, do: @operand_open_chars

  @doc "The characters a condition may start with, as a bracket class."
  @spec operand_open_class() :: binary()
  def operand_open_class, do: @operand_open_class

  @doc "The characters a select item may end with directly against `FROM`, as a bracket class."
  @spec item_end_class() :: binary()
  def item_end_class, do: @item_end_class

  @from_keyword Regex.compile!(
                  InfluxQLBlankRegex.blank_pattern(
                    "(?:\\s|(?<=" <> @item_end_class <> "))FROM(?![\\w])"
                  ),
                  "i"
                )
  @from_keyword_blanks Regex.compile!(
                         InfluxQLBlankRegex.blank_pattern(
                           "(?:\\s|(?<=" <> @item_end_class <> "))FROM(?![\\w])\\s*"
                         ),
                         "i"
                       )

  @doc """
  The `FROM` that ends a select list: one after a blank, or directly against the end of an
  item (`*FROM`, `)FROM`, `"a"FROM`, `'a'FROM`, `/re/FROM`). Every reader of the list uses it,
  so that they find the same keyword.
  """
  @spec from_keyword() :: Regex.t()
  def from_keyword, do: @from_keyword

  @doc "`from_keyword/0` with the blanks after the keyword."
  @spec from_keyword_blanks() :: Regex.t()
  def from_keyword_blanks, do: @from_keyword_blanks

  @clauses ~q/^\s*(?:WHERE(?:\s+|(?=#{@operand_open_class}))(?<where>.+?))?\s*(?:GROUP\s+BY\s+(?<group>.+?))?\s*(?<fillcall>fill\s*\((?<fill>[^)]*)\))?\s*(?:ORDER\s+BY\s+(?:time\s+(?=ASC|DESC)|(?=ASC\b|DESC\b)|time\b)(?<dir>ASC|DESC)?)?\s*(?:LIMIT\s+(?<limit>\d+))?\s*(?:OFFSET\s+(?<offset>\d+))?\s*(?:SLIMIT\s+(?<slimit>\d+))?\s*(?:SOFFSET\s+(?<soffset>\d+))?\s*(?<tzcall>TZ\s*\(\s*'(?<tz>[^']*)'\s*\))?\s*;?\s*$/is

  @open_operand ~q/(?:[-+*=<>(,~!]|(?<![_\/])\/|\b(?:AND|OR))\s*$/i
  @fill_call ~q/(?<![\w])fill\s*\(/i

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
