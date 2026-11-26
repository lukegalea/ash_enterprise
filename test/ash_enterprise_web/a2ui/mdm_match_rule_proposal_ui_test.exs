defmodule AshEnterpriseWeb.A2ui.MdmMatchRuleProposalUITest do
  @moduledoc """
  The proposed-match-rules surface (`MdmMatchRuleProposalUI`, S1-84) driven
  through ash_a2ui's own handler, as the people who click it: a proposal's row
  and its replay detail, Activate and Reject as the clicking person, and the
  refusal of a person without the update grant.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Mdm
  alias AshEnterprise.Mdm.{Banding, MatchCandidate, MatchRuleProposal, MatchRuleSet}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterpriseWeb.A2ui.MdmMatchRuleProposalUI

  @golden "AshEnterprise.Canonical.Person"

  @rules [
    %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
    %{
      "name" => "name_fuzzy",
      "kind" => "fuzzy",
      "field" => "name",
      "algorithm" => "jaro",
      "weight" => 1.0
    }
  ]

  setup do
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)
    Banding.publish_seed_bands!(Seeder.seed_platform_organization().id)

    admin = tenant!()

    MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{golden_resource: @golden, rules: @rules},
      tenant: admin.tenant,
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:activate, %{}, tenant: admin.tenant, actor: admin.actor)
    |> Ash.update!()

    for {status, email, name, count} <- [
          {:confirmed, "1", "1", 6},
          {:confirmed, "1", "0.5", 6},
          {:rejected, "0", "1", 8},
          {:rejected, "0", "0", 4}
        ],
        _ <- 1..count do
      Ash.Seed.seed!(
        MatchCandidate,
        %{
          organization_id: admin.tenant,
          staged_record_id: Ash.UUID.generate(),
          golden_resource: @golden,
          golden_id: Ash.UUID.generate(),
          score: Decimal.new("0.7"),
          status: status,
          explanation: %{
            "email_exact" => %{"w" => "1.0", "c" => email},
            "name_fuzzy" => %{"w" => "1.0", "c" => name}
          }
        },
        tenant: admin.tenant
      )
    end

    proposal =
      Mdm.propose_match_rules!(@golden, actor: SystemActor.proposer(), tenant: admin.tenant)

    %{admin: admin, proposal: proposal}
  end

  defp rows(person) do
    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(MdmMatchRuleProposalUI,
        actor: person.actor,
        tenant: person.tenant
      )

    value["records"]
  end

  defp detail(person, proposal) do
    state =
      AshA2ui.Info.context_state_for(MdmMatchRuleProposalUI, %{"proposal" => proposal.id},
        actor: person.actor,
        tenant: person.tenant
      )

    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(MdmMatchRuleProposalUI,
        actor: person.actor,
        tenant: person.tenant,
        context_state: state
      )

    get_in(value, ["detail", "proposal"])
  end

  defp invoke(person, action, proposal) do
    AshA2ui.ActionHandler.handle(
      MdmMatchRuleProposalUI,
      AshEnterprise.A2uiMessage.ash_action(MdmMatchRuleProposalUI, "invoke", %{
        "action" => action,
        "recordId" => proposal.id,
        "component" => "table"
      }),
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp status(proposal, admin),
    do: Ash.get!(MatchRuleProposal, proposal.id, tenant: admin.tenant, authorize?: false).status

  test "lists the proposal with its replay", %{admin: admin, proposal: proposal} do
    assert [%{"id" => id} = row] = rows(admin)
    assert id == proposal.id
    assert row["golden_resource"] == @golden
    assert row["flips"] == 0

    detail = detail(admin, proposal)
    assert detail["flagged"] == false
    assert detail["replay_summary"] =~ "14 would change band: 6 toward admit, 8 toward omit"
    assert detail["replay_summary"] =~ "Proposed rules: 12 admit, 0 review, 12 omit"
    assert detail["tuning_text"] =~ "email_exact: 1.0 → 4.6439 (proposed)"
    assert length(String.split(detail["changed_pairs_text"], "\n")) == 14
  end

  test "a person activates it from the surface", %{admin: admin, proposal: proposal} do
    assert {:ok, _messages} = invoke(admin, "activate", proposal)

    assert status(proposal, admin) == :activated

    assert Ash.get!(MatchRuleSet, proposal.rule_set_id, tenant: admin.tenant, authorize?: false).status ==
             :active
  end

  test "a person rejects it from the surface", %{admin: admin, proposal: proposal} do
    assert {:ok, _messages} = invoke(admin, "reject", proposal)
    assert status(proposal, admin) == :rejected
  end

  test "a person without the update grant cannot activate it", %{admin: admin, proposal: proposal} do
    reader = member!(admin, "Proposal reader", [{MatchRuleProposal, :read, :global}])

    assert [_row] = rows(reader)
    assert {:error, _messages} = invoke(reader, "activate", proposal)
    assert status(proposal, admin) == :proposed
  end
end
