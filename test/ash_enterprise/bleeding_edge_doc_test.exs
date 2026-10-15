defmodule AshEnterprise.BleedingEdgeDocTest do
  @moduledoc """
  Keeps docs/BLEEDING-EDGE.md honest. Someone starting a new application from
  this template reads that page to learn which dependencies are forks or
  unreleased, so a git dependency or an override that is missing from it is a
  maintenance burden nobody was told about.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @doc_path Path.join(@root, "docs/BLEEDING-EDGE.md")
  @lock_path Path.join(@root, "mix.lock")

  setup_all do
    {lock, _binding} = Code.eval_file(@lock_path)

    git_deps =
      for {name, {:git, _url, _sha, _opts}} <- lock, into: MapSet.new(), do: Atom.to_string(name)

    %{doc: File.read!(@doc_path), git_deps: git_deps}
  end

  test "every git dependency in mix.lock is named on the page", %{doc: doc, git_deps: git_deps} do
    missing = Enum.reject(git_deps, &String.contains?(doc, "`#{&1}`"))

    assert missing == [],
           "git dependencies missing from docs/BLEEDING-EDGE.md: #{Enum.join(missing, ", ")}"
  end

  test "every override in mix.exs is named on the page", %{doc: doc} do
    overridden =
      for dep <- Mix.Project.config()[:deps],
          opts = elem(dep, tuple_size(dep) - 1),
          is_list(opts) and Keyword.get(opts, :override, false),
          do: Atom.to_string(elem(dep, 0))

    missing = Enum.reject(overridden, &String.contains?(doc, "`#{&1}`"))

    assert missing == [],
           "overridden dependencies missing from docs/BLEEDING-EDGE.md: #{Enum.join(missing, ", ")}"
  end

  test "every package row in the fork and unreleased tables is still a git dependency",
       %{doc: doc, git_deps: git_deps} do
    [listed_sections | _] = String.split(doc, "\n## 3.")

    listed =
      Regex.scan(~r/^\| `([a-z0-9_]+)` \|/m, listed_sections, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    stale = Enum.reject(listed, &MapSet.member?(git_deps, &1))

    assert stale == [],
           "rows in docs/BLEEDING-EDGE.md for packages that are no longer git dependencies " <>
             "(delete the row or move it): #{Enum.join(stale, ", ")}"
  end
end
