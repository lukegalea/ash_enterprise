defmodule AshEnterpriseWeb.A2ui.RuleSetRevisionUI do
  @moduledoc """
  A2UI surface over rule set revisions — the browse half of "rules as data":
  which layer a rule set sits in, what lifecycle state it is in, and the
  content hash that findings pin.

  The rule *text* lives in `rules_json` (the serialized `AshRules.Ir.Bundle`);
  a JSON blob column in a table row reads as noise, and the drill-down
  belongs in a follow-up detail surface.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshCompliance.Resources.RuleSetRevision
    surface_id "compliance-rule-sets"

    query :default do
      sortable [:name, :layer, :status]
      page_size 25
    end

    component :table do
      fields [:name, :layer, :status, :revision, :combining, :content_hash]
      read_action :read
      query :default

      row_layout do
        title :name
        badge :status
        meta [:layer, :revision, :combining]
        columns 1
      end
    end
  end
end
