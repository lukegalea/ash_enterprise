defmodule AshEnterprise.Mdm.SourceRankUnavailable do
  @moduledoc """
  A merge of two golden records under a survivorship policy that ranks by
  source. A golden record has no per-field source lineage, so there is
  nothing to rank: the fold would tie and the survivor would win without
  anyone having decided that. The merge is refused instead.

  `used_by` names where the policy uses the strategy: `"default"`, or the
  attribute names.
  """

  use Splode.Error, fields: [:rule_set_id, :used_by], class: :invalid

  def message(%{rule_set_id: id, used_by: used_by}) do
    "the survivorship policy of match rule set #{id} uses source_rank " <>
      "(#{Enum.join(used_by, ", ")}), but a golden record has no per-field source " <>
      "lineage to rank; the merge is refused"
  end
end
