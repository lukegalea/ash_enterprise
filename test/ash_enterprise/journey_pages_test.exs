defmodule AshEnterprise.JourneyPagesTest do
  @moduledoc """
  The guide pages the site publishes (`docs/journeys/<locale>/<journey>.md`, with
  their figures in `site/src/assets/journeys/`) are what `mix ash_journeys.export`
  writes from the approved runs today. Regenerate them with:

      mix ash_journeys.export --out docs/journeys \\
        --figures site/src/assets/journeys --figures-ref ../../../site/src/assets/journeys
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Surfaces
  alias AshJourneys.{Export, Lock}

  @pages "docs/journeys"
  @figures "site/src/assets/journeys"
  @figures_ref "../../../site/src/assets/journeys"

  test "the committed guide pages and figures are the export of the approved runs" do
    modules = Surfaces.guides() |> Enum.map(&elem(&1.journey, 0)) |> Enum.uniq()
    {:ok, declared} = Lock.declared(modules)
    {:ok, export} = Export.pages(File.cwd!(), declared, figures_ref: @figures_ref)

    stale = "is not the export; regenerate it (see this test's moduledoc)"

    for %{path: path, markdown: markdown} <- export.pages do
      assert File.read!(Path.join(@pages, path)) == markdown, "#{path} #{stale}"
    end

    for %{file: file, bytes: bytes} <- export.figures do
      assert File.read!(Path.join(@figures, file)) == bytes, "#{file} #{stale}"
    end

    committed_pages =
      for p <- Path.wildcard(Path.join(@pages, "*/*.md")), do: Path.relative_to(p, @pages)

    committed_figures = for f <- Path.wildcard(Path.join(@figures, "*.png")), do: Path.basename(f)

    assert Enum.sort(committed_pages) == Enum.sort(Enum.map(export.pages, & &1.path))
    assert Enum.sort(committed_figures) == Enum.sort(Enum.map(export.figures, & &1.file))
  end
end
