defmodule AshEnterprise.Assistant.Lookups.StewardQueue do
  @moduledoc """
  `Lookup.Duplicate.steward_queue`: the possible duplicates waiting for the person's
  verdict as a data steward — `MatchCandidate.review_queue` as that person
  (pending, review-banded, and only those whose golden record they may
  read), oldest first, at most #{25}.

  Structural facts only (a ref, the match score, how long it has waited,
  whose name and email a merge would keep), plus the two records' names and
  emails **as the person may read them**: each side is loaded through its
  relationship under the reader's policies, so a side they may not read
  comes back empty, never its values.

  Each row's `may_decide` says whether the person may record a verdict at all (the
  steward update grant, `Ash.can?`, no record named); a verdict on one is
  then checked again on that candidate when it is proposed and when it runs.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Mdm.MatchCandidate

  @shown 25

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      MatchCandidate
      |> Ash.Query.for_read(:review_queue, %{}, opts)
      |> Ash.Query.load([
        :staged_label,
        :staged_email,
        :golden_label,
        :golden_email,
        :name_survivor,
        :email_survivor,
        :waiting_since
      ])
      |> Ash.Query.limit(@shown)
      |> Ash.read(opts)
      |> case do
        {:ok, rows} ->
          may_decide? = may_decide?(opts)
          {:ok, Enum.map(rows, &row(&1, may_decide?))}

        error ->
          error
      end
    end)
  end

  defp may_decide?(opts),
    do: Ash.can?({MatchCandidate, :confirm}, opts[:actor], tenant: opts[:tenant])

  defp row(candidate, may_decide?) do
    Support.row(Lookup.Duplicate, %{
      ref: Support.ref(MatchCandidate, candidate),
      incoming: Support.clip(candidate.staged_label, 120),
      incoming_email: Support.clip(candidate.staged_email, 200),
      existing: Support.clip(candidate.golden_label, 120),
      existing_email: Support.clip(candidate.golden_email, 200),
      score: candidate.score && Decimal.to_string(candidate.score),
      merge_keeps_name_of: side(candidate.name_survivor),
      merge_keeps_email_of: side(candidate.email_survivor),
      waiting_since: Support.text(candidate.waiting_since),
      may_decide: may_decide?
    })
  end

  defp side("golden"), do: "existing"
  defp side("staged"), do: "incoming"
  defp side(_other), do: nil
end
