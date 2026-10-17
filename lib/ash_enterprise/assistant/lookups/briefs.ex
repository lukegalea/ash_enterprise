defmodule AshEnterprise.Assistant.Lookups.Briefs do
  @moduledoc """
  `Lookup.morning_briefs`: the person's most recent morning briefs, newest
  first, as `MorningBrief.read` returns them (their own, self-service). The
  draft is rendered on read from its events (`draft_text`), so an erased
  event reads as `[shredded]` here as everywhere else.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Assistant.Lookups.Support

  @impl true
  def run(input, _opts, context) do
    Support.gated(input, context, fn opts ->
      days = Support.limit(input.arguments[:days], 3, 14)

      MorningBrief
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.sort(brief_date: :desc, inserted_at: :desc)
      |> Ash.Query.limit(days)
      |> Ash.Query.load([:headline, :summary, :draft_text])
      |> Ash.read(opts)
      |> case do
        {:ok, briefs} -> {:ok, %{"count" => length(briefs), "briefs" => Enum.map(briefs, &row/1)}}
        error -> error
      end
    end)
  end

  defp row(brief) do
    %{
      "ref" => Support.ref(MorningBrief, brief),
      "day" => brief.headline,
      "status" => brief.status,
      "summary" => Support.text(brief.summary),
      "text" => brief.draft_text && String.slice(Support.text(brief.draft_text), 0, 1500)
    }
    |> Support.compact()
  end
end
