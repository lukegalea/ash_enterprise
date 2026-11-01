defmodule AshEnterprise.Assistant.Lookups.Briefs do
  @moduledoc """
  `Lookup.Brief.morning_briefs`: the person's most recent morning briefs, newest
  first, as `MorningBrief.read` returns them (their own, self-service). The
  draft is rendered on read from its events (`draft_text`), so an erased
  event reads as `[shredded]` here as everywhere else.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      days = Support.limit(query.arguments[:days], 3, 14)

      MorningBrief
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.sort(brief_date: :desc, inserted_at: :desc)
      |> Ash.Query.limit(days)
      |> Ash.Query.load([:headline, :summary, :draft_text])
      |> Ash.read(opts)
      |> case do
        {:ok, briefs} -> {:ok, Enum.map(briefs, &row/1)}
        error -> error
      end
    end)
  end

  defp row(brief) do
    Support.row(Lookup.Brief, %{
      ref: Support.ref(MorningBrief, brief),
      day: Support.text(brief.headline),
      status: brief.status,
      summary: Support.text(brief.summary),
      text: brief.draft_text && String.slice(Support.text(brief.draft_text), 0, 1500)
    })
  end
end
