defmodule AshEnterprise.Test.PaperSamples do
  @moduledoc """
  The fixture documents a layout change is reviewed against
  (the kernel's `MIX_ENV=test mix paper.impact --layout <module>`, an
  `AshPaper.Compare.Samples` named by `config :ash_paper, :impact_samples`):
  SYNTHETIC activity summaries built from hand-made rows
  (`AshEnterprise.Test.PaperEntries`), the way the paper tests build them.
  Nothing here is anyone's data, and nothing reads the database.

  Each sample is what one render needs, frozen: the payload, the theme, the
  host's current layout and the resolved clauses the document carries. A
  sample has no issued digest, so a layout comparison has no baseline to
  reproduce: the host's layout is the baseline.
  """

  @behaviour AshPaper.Compare.Samples

  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Test.PaperEntries

  @note "Hazard follow-up explained: the Hazard rows above were each followed up."

  @doc "The fixture samples: three activity summaries, two of them carrying the hazard note."
  @impl AshPaper.Compare.Samples
  def samples do
    [
      sample("hazard-carlito", hazard_rows(), "carlito", true),
      sample("groceries-caladea", groceries_rows(), "caladea", false),
      sample("many-rows-maplestone", many_rows(), "maplestone", true)
    ]
  end

  @doc "The host's render limits."
  @impl AshPaper.Compare.Samples
  def limits, do: Paper.limits()

  defp sample(id, rows, theme_name, note?) do
    {:ok, schema, layout, _theme} = Paper.definition("activity_summary")
    source = PaperEntries.source(rows, 2025)

    {:ok, payload} =
      AshPaper.Payload.build(schema, source, title: "Activity summary 2025", locale: :en)

    %{
      id: id,
      title: payload.title,
      payload: payload,
      theme: Paper.theme(theme_name),
      layout: layout,
      clauses: if(note?, do: [%{key: "hazard_note", text: @note}], else: []),
      digest: nil
    }
  end

  defp hazard_rows do
    [{"a", "2025-01-02", "-20", "Groceries"}, {"b", "2025-07-15", "-40", "Hazard"}]
  end

  defp groceries_rows do
    [{"a", "2025-01-02", "-20", "Groceries"}, {"b", "2025-03-04", "-5.50", "Groceries"}]
  end

  defp many_rows do
    ~w(Groceries Hazard Transit Utilities Dining Stationery Clothing Gifts)
    |> Enum.with_index(1)
    |> Enum.map(fn {category, i} ->
      {"r#{i}", "2025-0#{rem(i, 9) + 1}-1#{rem(i, 9)}", "-#{i}0.25", category}
    end)
  end
end
