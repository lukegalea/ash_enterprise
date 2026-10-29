defmodule Battery.Mdm.MatchCandidate do
  @moduledoc """
  The macro-generated MatchCandidate on the battery's own base — a scored
  staged↔golden pair awaiting confirmation.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:match_candidate, []}

  # The candidate macro emits the body; the base (repo + table) is ours —
  # and unlike the dep's pure-match fixtures, the battery RUNS this
  # resource, so it carries its postgres block.
  postgres do
    table "mdm_match_candidates"
    repo Battery.Repo
  end
end
