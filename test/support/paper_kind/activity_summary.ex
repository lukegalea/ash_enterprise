defmodule AshEnterprise.Test.Paper.ActivitySummary do
  @moduledoc """
  The SYNTHETIC `activity_summary` document kind the generic paper tests issue
  (`AshEnterprise.Documents.Paper.Kind`): a person's entries for a year,
  totalled per category and currency, as a letter. Nobody's business data.

    * **Subject**: `year` (an integer, 2000–2100).
    * **Source**: the actor's own `AshEnterprise.Test.Paper.Entry` rows, read
      through `:mine` as the actor, in the tenant.
    * **Clause**: `hazard_note`, decided by `paper.clause.hazard_note` over
      `year` and `categories`.
    * **Requirement**: `AshEnterprise.Test.Paper.HazardFollowUp`; answers are
      scoped to the year and hold until the end of the following one.
  """

  use AshEnterprise.Documents.Paper.Kind

  alias AshEnterprise.Documents.Paper.Kind
  alias AshEnterprise.Test.Paper.{Entry, HazardFollowUp}

  require Ash.Query

  @impl Kind
  def key, do: "activity_summary"

  @impl Kind
  def schema, do: __MODULE__.Schema

  @impl Kind
  def default_theme, do: "carlito"

  @impl Kind
  def clause_keys, do: ["hazard_note"]

  @impl Kind
  def decision_inputs(%AshPaper.Payload{} = payload) do
    %{
      "year" => payload.facts["fields"]["year"],
      "categories" => Enum.map(payload.facts["tables"]["totals"] || [], & &1["category"])
    }
  end

  @impl Kind
  def requirement, do: HazardFollowUp

  @impl Kind
  def source(subject, opts), do: totals(subject, opts)

  @impl Kind
  def scope(%AshPaper.Payload{facts: facts}), do: %{"year" => get_in(facts, ["fields", "year"])}

  @impl Kind
  def valid_until(%{"year" => year}) when is_integer(year),
    do: DateTime.new!(Date.new!(year + 2, 1, 1), ~T[00:00:00.000000], "Etc/UTC")

  def valid_until(_scope), do: nil

  @doc "The actor's entries for the subject's year, totalled per category and currency."
  @spec totals(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def totals(subject, opts) do
    with {:ok, year} <- year(Kind.arg(subject, :year)),
         {:ok, entries} <- read(year, opts) do
      {:ok, build(entries, year)}
    end
  end

  @doc """
  The source map for `entries` (anything with `on`, `amount`, `currency` and
  `category`) in `year`: what `source/2` returns for those rows. Fixtures that
  never touch the store (`AshEnterprise.Test.PaperSamples`) build it directly.
  """
  @spec build([map()], integer()) :: map()
  def build(entries, year) do
    in_year = Enum.filter(entries, &(&1.on.year == year))
    %{year: year, entity: nil, totals: rows(in_year)}
  end

  defp year(year) when is_integer(year) and year in 2000..2100, do: {:ok, year}
  defp year(_year), do: {:error, {:invalid_subject, :year}}

  defp read(year, opts) do
    {first, last} = {Date.new!(year, 1, 1), Date.new!(year, 12, 31)}

    Entry
    |> Ash.Query.for_read(:mine, %{}, Keyword.take(opts, [:actor, :tenant]))
    |> Ash.Query.filter(on >= ^first and on <= ^last)
    |> Ash.read()
  end

  defp rows(entries) do
    entries
    |> Enum.group_by(&{&1.category, &1.currency})
    |> Enum.map(fn {{category, currency}, group} ->
      amounts = Enum.map(group, & &1.amount)
      inflow = amounts |> Enum.filter(&Decimal.positive?/1) |> sum()
      outflow = amounts |> Enum.filter(&Decimal.negative?/1) |> sum()

      %{
        category: category,
        currency: currency,
        count: length(group),
        inflow: inflow,
        outflow: outflow,
        net: Decimal.add(inflow, outflow)
      }
    end)
    |> Enum.sort_by(&{&1.currency, Decimal.to_float(&1.net), &1.category})
  end

  defp sum(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)
end
