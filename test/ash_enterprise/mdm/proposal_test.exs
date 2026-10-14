defmodule AshEnterprise.Mdm.ProposalTest do
  @moduledoc """
  MDM-8: a proposal against an unseen schema produces valid field rules for
  at least the deterministic columns, drafts only — nothing activates
  without a person.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.{Mapping, Proposal}
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup do
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Proposal #{System.unique_integer([:positive])}",
        unique_name: "proposal-#{System.unique_integer([:positive])}"
      )

    %{org: organization.id, admin: admin}
  end

  defp mapping_proposal!(org, mapping_id) do
    AshEnterprise.Mdm.MappingProposal
    |> Ash.Query.filter(mapping_id == ^mapping_id)
    |> Ash.read_one!(tenant: org, authorize?: false)
  end

  test "a proposal drafts rules for the deterministic columns and stays a draft", %{org: org} do
    observed = %{"Email" => %{}, "Full Name" => %{}, "Frob" => %{}}

    assert {:ok, draft} = Proposal.propose(org, "AshEnterprise.Canonical.Person", observed)

    assert draft.status == :draft
    assert draft.source == "ai_proposal"

    targets = Enum.map(draft.field_rules, & &1["target"])
    assert "email" in targets
    assert "name" in targets

    # The proposal is retained on its own row — the mapping lifecycle never
    # touches it.
    proposal = mapping_proposal!(org, draft.id)
    assert proposal.stage == :deterministic_only

    # The draft validates (the deterministic columns account the golden).
    validated =
      draft
      |> Ash.Changeset.for_update(:validate, %{}, tenant: org, authorize?: false)
      |> Ash.update!(tenant: org, authorize?: false)

    assert validated.status == :validated

    # Nothing activates without a person actor: nil actor is refused.
    assert {:error, %Ash.Error.Forbidden{}} =
             validated
             |> Ash.Changeset.for_update(:activate, %{activation_note: "nope"},
               tenant: org,
               authorize?: true
             )
             |> Ash.update(tenant: org, authorize?: true)
  end

  test "an LLM refusal is retained and the deterministic floor still lands", %{org: org} do
    Application.put_env(:ash_enterprise, :mdm_proposal_llm, {__MODULE__, :refuse, []})

    on_exit(fn -> Application.delete_env(:ash_enterprise, :mdm_proposal_llm) end)

    assert {:ok, draft} =
             Proposal.propose(org, "AshEnterprise.Canonical.Person", %{
               "Email" => %{},
               "Full Name" => %{}
             })

    proposal = mapping_proposal!(org, draft.id)
    assert proposal.stage == :llm_refused
    assert length(draft.field_rules) == 2

    # Retained even after the draft is validated (the lifecycle overwrites
    # validation_findings; the proposal row is not the lifecycle's).
    validate_host_mapping!(draft, org)

    assert mapping_proposal!(org, draft.id).stage ==
             :llm_refused
  end

  def refuse(_manifest), do: {:error, "the model declined"}
end
