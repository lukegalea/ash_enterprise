defmodule AshEnterpriseWeb.A2ui.MdmMatchRuleProposalUI do
  @moduledoc """
  Proposed match rules (S1-84): new rule weights learned from the stewards'
  verdicts, each with its replay over those verdicts, for a person to activate
  or reject (`AshEnterprise.Mdm.MatchRuleProposal`).

  A row shows how many pairs would change band and how many changes would undo
  a steward's decision. Its detail shows the replay, the active and proposed
  rules each measured against the stewards, every pair that would move, and
  each rule's weight before and after.

  * **Activate** adopts the proposal: its rules become the active version.
  * **Reject** declines it: the active rules stay.

  Both run as the clicking person, through the proposal's person gate and
  grants, and are shown only while the proposal is proposed. Proposing is the
  platform's (`AshEnterprise.Mdm.propose_match_rules/2`), never this surface's.

  Served at `/app/mdm/match-rules`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Mdm.MatchRuleProposal
    surface_id "mdm_match_rules"
    title "Proposed match rules"
    record_label "match-rule proposal"

    context :proposal do
      resource AshEnterprise.Mdm.MatchRuleProposal
      picker false
    end

    query :default do
      sortable [:created_on, :status, :flips]
      default_sort created_on: :desc
      page_size 25
      max_page_size 50
    end

    component :table do
      fields [:golden_resource, :status, :flips, :created_on]
      read_action :read
      query :default
      row_actions [:activate, :reject]
      select_context :proposal

      row_layout do
        title :golden_resource
        badge :status
        meta [:flips, :created_on]
        columns 2
      end
    end

    component :detail, :proposal_detail do
      context :proposal

      fields [
        :golden_resource,
        :status,
        :flagged,
        :replay_summary,
        :changed_pairs_text,
        :tuning_text,
        :base_rule_set_id,
        :rule_set_id
      ]
    end

    action :activate do
      label "Activate"
      visible_when status: :proposed
    end

    action :reject do
      label "Reject"
      visible_when status: :proposed
    end

    field :golden_resource do
      label "Rules for"
    end

    field :status do
      label "Status"
    end

    field :flips do
      label "Would undo a steward"
    end

    field :created_on do
      label "Proposed"
    end

    field :flagged do
      label "Undoes a steward decision"
    end

    field :replay_summary do
      label "Replay over past verdicts"
    end

    field :changed_pairs_text do
      label "Pairs that would change band"
    end

    field :tuning_text do
      label "Rule weights"
    end

    field :base_rule_set_id do
      label "Active rule set"
    end

    field :rule_set_id do
      label "Proposed rule set"
    end
  end
end
