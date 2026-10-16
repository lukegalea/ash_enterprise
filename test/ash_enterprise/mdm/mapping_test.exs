defmodule AshEnterprise.Mdm.MappingTest do
  @moduledoc """
  MDM-1 host half: the macro-generated Mapping on the platform base —
  draft -> validate with tenancy, and the activation gate: a system actor
  is refused (`:activate` is a person's decision, ADR 0054 §ActorContext),
  and a person activates *through the platform grant union* — the actor is
  a seeded tenant admin, so personhood AND privilege are both exercised.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.Mapping
  alias AshEnterprise.Platform.Seeder

  setup do
    # A real tenant: organization, root business unit, Administrator role,
    # and an admin user — so the activation test exercises the actual grant
    # union rather than a policy shortcut.
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Mdm Mapping Test #{System.unique_integer([:positive])}",
        unique_name: "mdm-mapping-#{System.unique_integer([:positive])}"
      )

    {:ok, org: organization.id, admin: admin}
  end

  describe "draft/validate" do
    test "a valid mapping validates under tenancy", %{org: org} do
      mapping = draft_host_mapping!(org, [])

      assert mapping.content_hash == AshMdm.Mapping.ContentHash.hash!(person_rules())

      validated = validate_host_mapping!(mapping, org)

      assert validated.status == :validated
      assert %{"errors" => [], "warnings" => []} = stringify(validated.validation_findings)
    end

    test "an incomplete mapping stays a draft with findings", %{org: org} do
      mapping =
        draft_host_mapping!(org,
          field_rules: [
            %{"path" => "Email", "target" => "email", "op" => "identity", "args" => %{}}
          ]
        )

      validated = validate_host_mapping!(mapping, org)

      assert validated.status == :draft

      assert Enum.any?(
               stringify(validated.validation_findings)["errors"],
               &(&1["check"] == "unaccounted_target")
             )
    end
  end

  describe "activation gate" do
    test "a system actor is forbidden to activate", %{org: org} do
      mapping = draft_host_mapping!(org, [])
      validated = validate_host_mapping!(mapping, org)

      # Both system actor kinds: the seeded actor (replay/automation) and
      # `ai` (an attribution label with no authority, ADR 0043). Without
      # these the gate is unproven — a nil actor is refused by the grant
      # check even if the person-only policy were bypassed.
      for actor <- [
            AshEnterprise.Platform.SystemActor.replay(),
            AshEnterprise.Platform.SystemActor.ai()
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 validated
                 |> Ash.Changeset.for_update(:activate, %{activation_note: "nope"},
                   tenant: org,
                   actor: actor,
                   authorize?: true
                 )
                 |> Ash.update(tenant: org, actor: actor, authorize?: true)
      end
    end

    test "a person with a grant activates and the predecessor retires", %{org: org, admin: admin} do
      v1 = draft_host_mapping!(org, [])
      v1 = activate_host_mapping!(v1, org, admin)

      v2 =
        Mapping
        |> Ash.Changeset.for_create(:create_version, %{
          from_mapping_id: v1.id,
          direction: :ingress,
          source: v1.source,
          stream: v1.stream,
          target_resource: v1.target_resource,
          field_rules: person_rules(),
          observed_schema: %{}
        })
        |> Ash.create!(tenant: org, authorize?: false)

      v2 = activate_host_mapping!(v2, org, admin)

      assert Ash.reload!(v2, tenant: org, authorize?: false).status == :active
      assert Ash.reload!(v1, tenant: org, authorize?: false).status == :retired
    end
  end
end
