defmodule InfluxElixir.Client.Local.SQLRegexGuard do
  @moduledoc false
  # What of a pattern PCRE and the crate read differently for some texts: the double matches
  # with PCRE, so a text one of them reads another way is declined, not answered.

  @typedoc """
  What a compiled pattern can tell about a text without running it: whether a text with a newline
  (`:newline`) or with a character that is not ASCII (`:unicode`) is read another way by PCRE
  and the crate.
  """
  @type t :: %{newline: boolean(), unicode: boolean()}

  @doc """
  What of a pattern PCRE and the crate read differently for some texts, found once when the
  pattern is compiled (not for every row). For a text with a newline: `$`, `\\z` and the `(?m`
  flag, whose ends and starts of lines are not alike; for a text that is not ASCII: `\\w`, `\\d`,
  `\\s`, `\\b` (other sets of characters in the crate) and a case-insensitive match (other
  folding).
  """
  @spec of(Regex.t()) :: t()
  def of(%Regex{source: source} = regex) do
    %{
      newline: String.contains?(source, ["$", "\\z", "(?m"]),
      unicode:
        :caseless in Regex.opts(regex) or
          String.contains?(source, ~w(\\w \\W \\d \\D \\s \\S \\b \\B (?i))
    }
  end

  @doc """
  Whether the double declines to match the text: it is one the pattern's guard says the two
  read differently. This depends on the data, not on the query alone: one row with a newline
  or a character that is not ASCII refuses a query that was answered before it was written.
  """
  @spec differs?(t(), binary()) :: boolean()
  def differs?(%{newline: false, unicode: false}, _text), do: false
  def differs?(%{newline: true, unicode: false}, text), do: newline?(text)

  def differs?(%{newline: false, unicode: true}, text),
    do: not newline?(text) and not ascii?(text)

  def differs?(%{newline: true, unicode: true}, text),
    do: newline?(text) or not ascii?(text)

  @spec newline?(binary()) :: boolean()
  defp newline?(text), do: :binary.match(text, "\n") != :nomatch

  @spec ascii?(binary()) :: boolean()
  defp ascii?(<<byte, rest::binary>>) when byte < 128, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_text), do: false
end
