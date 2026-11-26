defmodule AshEnterprise.Test.Paper.ActivitySummaryBrief.Schema do
  @moduledoc """
  The SYNTHETIC one-page activity summary: the year and each category's net.
  Same source and same letter layout as the full summary, so what differs
  between the two is exactly what the schemas name.
  """

  use AshPaper.Schema

  paper do
    key(:activity_summary_brief)
    version(1)

    field :year, :integer, label: [en: "Year"]

    table :totals do
      field :category, :text, label: [en: "Category"]
      field :net, :money, currency: [:currency], label: [en: "Net"]
    end
  end
end
