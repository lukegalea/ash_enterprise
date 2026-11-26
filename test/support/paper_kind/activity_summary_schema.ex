defmodule AshEnterprise.Test.Paper.ActivitySummary.Schema do
  @moduledoc """
  The SYNTHETIC activity summary's schema: the year, who it is prepared for,
  and per category the entry count and the inflow, outflow and net totals,
  each amount beside its ISO currency code.
  """

  use AshPaper.Schema

  paper do
    key(:activity_summary)
    version(1)

    field :year, :integer, label: [en: "Year"]
    field :entity, :text, label: [en: "Prepared for"], required?: false

    table :totals do
      field :category, :text, label: [en: "Category"]
      field :count, :integer, label: [en: "Entries"]
      field :inflow, :money, currency: [:currency], label: [en: "Inflow"]
      field :outflow, :money, currency: [:currency], label: [en: "Outflow"]
      field :net, :money, currency: [:currency], label: [en: "Net"]
    end
  end
end
