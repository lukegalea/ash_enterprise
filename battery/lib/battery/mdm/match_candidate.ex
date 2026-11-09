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

    identity_wheres_to_sql one_golden_pair: "other_golden_id IS NOT NULL"

    check_constraints do
      check_constraint :staged_record_id, "mdm_match_candidates_exactly_one_pairing",
        check: "(staged_record_id IS NULL) <> (other_golden_id IS NULL)",
        message: "a candidate pairs a golden with a staged record or another golden, not both"
    end
  end
end
