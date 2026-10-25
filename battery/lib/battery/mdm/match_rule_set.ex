defmodule Battery.Mdm.MatchRuleSet do
  @moduledoc """
  The macro-generated MatchRuleSet on the battery's own base — match rules
  and survivorship as data.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:match_rule_set, repo: Battery.Repo, table: "mdm_match_rule_sets"}

end
