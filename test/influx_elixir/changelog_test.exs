defmodule InfluxElixir.ChangelogTest do
  # Every published version has a dated heading over the entries it shipped
  # (#22: 0.1.22 through 0.1.31 were published with everything under
  # [Unreleased]). The publish job writes the heading; this fails the next
  # CI run if it ever stops, or if a version is bumped by hand without one.
  use ExUnit.Case, async: true

  @changelog Path.expand("../../CHANGELOG.md", __DIR__)

  defp headings do
    for [_full, name] <- Regex.scan(~r/^## \[([^\]]+)\]/m, File.read!(@changelog)), do: name
  end

  test "the version in mix.exs has a dated heading" do
    version = Mix.Project.config()[:version]

    assert File.read!(@changelog) =~
             ~r/^## \[#{Regex.escape(version)}\] - \d{4}-\d{2}-\d{2}$/m,
           "CHANGELOG.md has no `## [#{version}] - YYYY-MM-DD` heading"
  end

  test "[Unreleased] comes first, then each version once, newest first" do
    assert ["Unreleased" | versions] = headings()
    parsed = Enum.map(versions, &Version.parse!/1)

    assert parsed == Enum.sort(parsed, {:desc, Version})
    assert parsed == Enum.uniq(parsed)
  end
end
