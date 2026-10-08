defmodule InfluxElixir.Client.Local.SQLRegexCost do
  @moduledoc false
  # What a regular expression costs the crate to compile, accumulated by the one reader of the
  # pattern (`InfluxElixir.Client.Local.SQLRustRegex`) as it reads: this module holds
  # arithmetic only and never looks at the pattern, so it cannot disagree with the reader about
  # where an atom ends.
  #
  # The crate compiles a repetition by copying what it repeats, and gives up on a pattern whose
  # copies exceed its limit: on Core `(a{1000}){1000}`, `\w{1000}` and `(.{1000}){100}` close the
  # connection instead of answering (verified), and PCRE answers them. A pattern is costed (a
  # character 1, `.` and a negated class 20, a class 4, `\w`, `\d`, `\s`, `\pL` and their kin
  # 1200, a group the sum of what it holds, a repetition the product of its count and the cost
  # of what it repeats) and one above `@max_cost` is not read. The weights are fitted to what
  # Core did, not the crate's: every pattern probed that it answered costs less than the
  # bound or at it (`(a{500}){500}` 250,000; `\w{200}` and `\pL{200}` 240,000;
  # `(.{100}){100}` 200,000; `[a-z]{10000}`), and every one it closed the connection on costs
  # more (`(a{600}){600}` 360,000; `(a{300}){1000}` 300,000; `\w{300}` and `\pL{300}` 360,000;
  # `(.{200}){100}` 400,000; `(\pL{50}){10}` 600,000; `(\w{20}){20}` 480,000). Between the two
  # the bound is a guess, and what is above it is refused, not answered.
  #
  # The state is the cost of the atoms of the sequence read so far (`total`), the cost of the
  # atom last read, which a quantifier may still multiply (`unit`), and the states of the
  # sequences the open groups stand in (`outer`).

  @max_cost 250_000

  @too_big "a repetition so large that the crate may refuse to compile the pattern"

  @type t :: %__MODULE__{total: non_neg_integer(), unit: non_neg_integer(), outer: [t()]}
  defstruct total: 0, unit: 0, outer: []

  @doc "The state before the first character."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "An atom of the given weight was read; what stood before it can no longer be repeated."
  @spec atom(t(), non_neg_integer()) :: t()
  def atom(%__MODULE__{total: total, unit: unit} = cost, weight),
    do: %{cost | total: total + unit, unit: weight}

  @doc "A quantifier repeats the last atom up to `times` times (a repeat of none costs one)."
  @spec repeat(t(), non_neg_integer()) :: t()
  def repeat(%__MODULE__{unit: unit} = cost, times), do: %{cost | unit: unit * max(times, 1)}

  @doc "An alternation bar: the alternatives add up, and the bar itself costs nothing."
  @spec alternate(t()) :: t()
  def alternate(cost), do: atom(cost, 0)

  @doc "A group opens: what is inside it is costed on its own."
  @spec open(t()) :: t()
  def open(cost), do: %__MODULE__{outer: [cost | cost.outer]}

  @doc "The group closes and counts as one atom of the sum of what it held."
  @spec close(t()) :: t()
  def close(%__MODULE__{total: total, unit: unit, outer: [outer | _rest]}),
    do: atom(outer, total + unit)

  @doc "The weight of a class: the base of its kind, or that of `\\w` and kin if it holds one."
  @spec class([binary()], boolean()) :: non_neg_integer()
  def class(items, negated?), do: class_weight(items, if(negated?, do: 20, else: 4))

  defp class_weight(["\\", escape | rest], base) do
    if escape in ~w(p P d D w W s S), do: class_weight(rest, 1200), else: class_weight(rest, base)
  end

  defp class_weight([_item | rest], base), do: class_weight(rest, base)
  defp class_weight([], base), do: base

  @doc "The weight of an escape that stands for a character, a set or a property."
  @spec escape(binary()) :: non_neg_integer()
  def escape(letter) when letter in ~w(p P d D w W s S), do: 1200
  def escape(_letter), do: 1

  @doc "The weight of a character that is not an escape: `.` is a large set."
  @spec character(binary()) :: non_neg_integer()
  def character("."), do: 20
  def character(_char), do: 1

  @doc "Whether the pattern, read to its end, is one the double declines to compile."
  @spec verdict(t()) :: :ok | {:unknown, binary()}
  def verdict(%__MODULE__{total: total, unit: unit}) do
    if total + unit > @max_cost, do: {:unknown, @too_big}, else: :ok
  end
end
